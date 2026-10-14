#!/usr/bin/env bash
# Grade an OpenShell sandbox audit log against expected_events.tsv.
# Observes and reports. Does not perform out-of-policy actions.
set -euo pipefail

ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)"
EVENTS="${EVENTS:-${ROOT}/expected_events.tsv}"
SCENARIO="${ROOT}/scenarios/run_all.sh"
IMAGE="${IMAGE:-openshell-guardrails-agent:dev}"
POLICY="${POLICY:-${ROOT}/policies/openshell/agent-policy.yaml}"
PROVIDER="${PROVIDER:-demo-github}"
DEFAULT_SANDBOX="${SANDBOX_NAME:-guardrails-demo}"

usage() {
  cat <<'EOF'
usage: ./verify.sh [--sandbox NAME]

Every mode first runs scripts/policy-gate.sh on POLICY (Developer plane:
openshell-prover containment proof + review signature). Default mode then
creates sandbox NAME (default: guardrails-demo) from the demo image, policy,
and fake-token provider, runs scenarios/run_all.sh inside it, waits 2
seconds, and grades the audit log. If the gate refuses the policy, no
sandbox is created and every row fails.

--sandbox NAME   Re-check an existing sandbox. Does not create one and does
                 not run probes.

VERIFY_LOG_FILE  Grade this file instead of `openshell logs`. Offline mode:
                 no sandbox is created and scenarios/run_all.sh is not run.

Exit 0 only when every expected_events.tsv row is PASS.
Exit 1 when one or more rows FAIL.
Exit 2 when probes are missing, or the arguments are wrong.
EOF
}

strip_ansi() {
  # CSI color sequences from `openshell logs` (ESC [ ... letter).
  sed -E $'s/\033\\[[0-9;]*[[:alpha:]]//g'
}

sandbox_name=""
recheck=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --sandbox)
      if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
        echo "--sandbox requires a name" >&2
        usage >&2
        exit 2
      fi
      sandbox_name="$2"
      recheck=1
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ ! -f "$EVENTS" ]; then
  echo "missing ${EVENTS}" >&2
  exit 2
fi

corpus=""
log_corpus=""
scenario_rc=0

# Developer plane, before anything runs: is this policy proven inside the
# operator boundary, and is it the exact text someone reviewed and signed?
set +e
gate_out="$(bash "${ROOT}/scripts/policy-gate.sh" "$POLICY" 2>&1)"
gate_rc=$?
set -e
echo "----- policy gate (Developer plane) -----"
printf '%s\n' "$gate_out"
echo

if [ -n "${VERIFY_LOG_FILE:-}" ]; then
  if [ ! -f "$VERIFY_LOG_FILE" ]; then
    echo "VERIFY_LOG_FILE does not exist: ${VERIFY_LOG_FILE}" >&2
    exit 2
  fi
  log_corpus="$(strip_ansi <"$VERIFY_LOG_FILE")"
else
  if [ "$recheck" -eq 1 ]; then
    log_corpus="$(openshell logs "$sandbox_name" --since 10m --source sandbox 2>&1 | strip_ansi)"
  elif [ "$gate_rc" -ne 0 ]; then
    echo "policy gate refused ${POLICY#"${ROOT}/"}: no sandbox created"
    sandbox_name="not created"
  else
    if [ ! -f "$SCENARIO" ]; then
      echo "add probes: ${SCENARIO} is missing. Add the operator-supplied probe script. verify.sh only observes and reports denials."
      exit 2
    fi
    if [ ! -s "$SCENARIO" ]; then
      echo "add probes: ${SCENARIO} is empty."
      exit 2
    fi
    name="$DEFAULT_SANDBOX"
    # A sandbox from a previous run keeps its name; remove only this demo sandbox.
    openshell sandbox delete "$name" >/dev/null 2>&1 || true
    b64="$(base64 <"$SCENARIO" | tr -d '\n')"
    # base64 alphabet has no single quotes. The container is Ubuntu and has coreutils base64.
    inner="printf '%s' '${b64}' | base64 -d > /tmp/run_all.sh && sh /tmp/run_all.sh"
    scenario_out="$(mktemp)"
    trap 'rm -f "$scenario_out"' EXIT
    set +e
    openshell sandbox create \
      --name "$name" \
      --from "$IMAGE" \
      --policy "$POLICY" \
      --provider "$PROVIDER" \
      --no-tty \
      -- sh -c "$inner" >"$scenario_out" 2>&1
    scenario_rc=$?
    set -e
    sleep 2
    audit="$(openshell logs "$name" --since 10m --source sandbox 2>&1 | strip_ansi || true)"
    scenario_text="$(strip_ansi <"$scenario_out")"
    log_corpus="${audit}
${scenario_text}"
    sandbox_name="$name"
    if [ "$scenario_rc" -eq 2 ]; then
      printf '%s\n' "$scenario_text"
      echo "add probes: scenarios/run_all.sh exited 2. The committed script does not run probes."
    fi
    if [ "${DEMO:-0}" = "1" ]; then
      echo "----- inside the sandbox: what the agent attempted -----"
      printf '%s\n' "$scenario_text" | grep -E '^(== |PROBE )' || true
      echo
      echo "----- OpenShell audit log: what the sandbox denied -----"
      printf '%s\n' "$audit" | grep -E 'DENIED|FINDING:' \
        | sed -E 's/^\[[0-9.]+\] \[sandbox\] \[OCSF *\] \[ocsf\] //' || true
      echo
    fi
  fi
fi

corpus="${gate_out}
${log_corpus}"

printf '%s\n' "sandbox: ${sandbox_name:-offline}"
printf '%s\n' "ID                         PLANE      DOMAIN      KIND        RESULT  CONTROL"
printf '%s\n' "-------------------------  ---------  ----------  ----------  ------  -------"

fail_count=0
pass_count=0
row_count=0

# Record what was graded, for scripts/evidence.sh: every row's result and the
# exact line that matched it.
RUN_DIR="${ROOT}/.out/last-run"
mkdir -p "$RUN_DIR"
printf '%s\n' "$corpus" >"${RUN_DIR}/corpus.log"
printf '%s\n' "$gate_out" >"${RUN_DIR}/gate.txt"
{
  printf 'policy=%s\n' "${POLICY#"${ROOT}/"}"
  printf 'events=%s\n' "${EVENTS#"${ROOT}/"}"
  printf 'sandbox=%s\n' "${sandbox_name:-offline}"
  printf 'mode=%s\n' "$([ -n "${VERIFY_LOG_FILE:-}" ] && echo "offline:${VERIFY_LOG_FILE#"${ROOT}/"}" || { [ "$recheck" -eq 1 ] && echo recheck || echo live; })"
} >"${RUN_DIR}/meta.txt"
: >"${RUN_DIR}/matrix.tsv"

while IFS="$(printf '\t')" read -r id control plane domain kind pattern; do
  [ -n "$id" ] || continue
  case "$id" in
    \#*) continue ;;
    id) continue ;;
  esac
  row_count=$((row_count + 1))
  result="FAIL"
  matched=""
  if matched="$(printf '%s\n' "$corpus" | grep -E -m 1 -e "$pattern")"; then
    result="PASS"
  elif [ "$kind" = "exit-code" ] && matched="$(printf '%s\n' "$corpus" | grep -E -m 1 -e "PROBE ${id} BLOCKED")"; then
    result="PASS"
  else
    matched=""
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$plane" "$domain" "$kind" "$result" "$matched" >>"${RUN_DIR}/matrix.tsv"
  if [ "$result" = "PASS" ]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
  fi
  printf '%-25s  %-9s  %-10s  %-10s  %-6s  %s\n' "$id" "$plane" "$domain" "$kind" "$result" "$control"
done <"$EVENTS"

printf '%s\n' "${pass_count} PASS, ${fail_count} FAIL (${row_count} rows)"

if [ "$row_count" -eq 0 ]; then
  echo "expected_events.tsv has no data rows" >&2
  exit 2
fi

if [ "$scenario_rc" -eq 2 ]; then
  exit 2
fi
if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
exit 0
