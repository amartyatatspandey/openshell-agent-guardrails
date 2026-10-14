#!/usr/bin/env bash
# Edit copies of the reviewed policy the ways a hurried change or an agent's
# own request might, keep the old signature, and show the gate refuses each.
# Works on copies under .out/; the real policy is never touched.
# Exit 0 only when every edited copy is refused.
set -euo pipefail

ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)"
POLICY="${ROOT}/policies/openshell/agent-policy.yaml"
DIR="${ROOT}/.out/tamper"
rm -rf "$DIR"
mkdir -p "$DIR"

# name | what changes | perl substitution applied to the policy
cases=(
  "new-host|reach a host no policy names|s/host: httpbin.org/host: example.com/"
  "read-write|GitHub API becomes writable|s/access: read-only/access: read-write/"
  "root|workload runs as uid 0|s/run_as_user: \"1000\"/run_as_user: \"0\"/"
  "landlock-soft|Landlock may silently downgrade|s/compatibility: hard_requirement/compatibility: best_effort/"
  "other-binary|python3 instead of curl on the GitHub rule|s#- path: /usr/bin/curl#- path: /usr/bin/python3.12#"
  "write-path|agent may write /opt|s#read_write: \\[/tmp, /dev/null\\]#read_write: [/tmp, /dev/null, /opt]#"
  "in-boundary|add a host the boundary allows, without review|s/host: httpbin.org/host: raw.githubusercontent.com/"
)

# One short line per prover finding, for the table.
SUMMARY='
import json, sys
for line in sys.stdin:
    if line.startswith("POLICY-GATE counterexample "):
        c = json.loads(line.split(" ", 2)[2])
        d = c.get("domain")
        if d == "network":
            via = " via " + c["binary"] if c.get("binary") else ""
            print("counterexample: %s %s:%s%s%s" % (c["method"], c["host"], c["port"], c["path"], via))
        elif d in ("process", "landlock"):
            field = c.get("field", "compatibility")
            print("counterexample: %s %s -> %s" % (field, c["boundary"], c["candidate"]))
        else:
            print("counterexample: " + json.dumps(c))
        break
    if line.startswith("POLICY-GATE reason "):
        print(line.split(" ", 2)[2].strip()[:90])
        break
'
refused=0
total=0
printf '%-14s  %-17s  %-9s  %s\n' "CASE" "PROVER" "SIGNATURE" "WHY"
printf '%-14s  %-17s  %-9s  %s\n' "--------------" "-----------------" "---------" "---"
for entry in "${cases[@]}"; do
  IFS='|' read -r name what expr <<<"$entry"
  total=$((total + 1))
  copy="${DIR}/${name}.yaml"
  perl -pe "$expr" "$POLICY" >"$copy"
  if cmp -s "$POLICY" "$copy"; then
    echo "tamper case ${name} did not change the policy" >&2
    exit 2
  fi
  cp "${POLICY}.sig" "${copy}.sig"   # the old review signature, carried over
  set +e
  out="$(bash "${ROOT}/scripts/policy-gate.sh" "$copy" 2>&1)"
  rc=$?
  set -e
  prover="$(printf '%s\n' "$out" | sed -nE 's/^POLICY-GATE boundary ([a-z_]+).*/\1/p')"
  sig="$(printf '%s\n' "$out" | sed -nE 's/^POLICY-GATE signature ([a-z]+).*/\1/p')"
  why="$(printf '%s\n' "$out" | python3 -c "$SUMMARY")"
  [ -n "$why" ] || why="prover passes; bytes differ from the reviewed policy"
  printf '%-14s  %-17s  %-9s  %s\n' "$name" "${prover:-?}" "${sig:-?}" "$why"
  if [ "$rc" -ne 0 ]; then
    refused=$((refused + 1))
  fi
done
echo
echo "${refused}/${total} edited policies refused"
[ "$refused" -eq "$total" ]
