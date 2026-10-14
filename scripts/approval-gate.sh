#!/usr/bin/env bash
# OpenShell turns denied requests into pending rule proposals. Before anyone
# may approve one, compose it onto the sandbox's policy and prove the result
# against the operator boundary.
#   outside the boundary (or unprovable) -> rejected, with the counterexample
#   inside the boundary                  -> a human decides (y/N); never automatic
# Usage: scripts/approval-gate.sh [SANDBOX]   DRY_RUN=1 to only report.
set -euo pipefail

ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)"
SANDBOX="${1:-guardrails-approval}"
POLICY="${POLICY:-${ROOT}/policies/openshell/agent-policy.yaml}"
BOUNDARY="${BOUNDARY:-${ROOT}/policies/boundary/org-boundary.yaml}"
PROVER="${OPENSHELL_PROVER:-$(command -v openshell-prover || echo /opt/homebrew/opt/openshell/bin/openshell-prover)}"
OUT="${ROOT}/.out/approval"
mkdir -p "$OUT"
: >"${OUT}/decisions.txt"

# The boundary itself must be the signed one, as in the policy gate.
if ! ssh-keygen -Y verify -f "${ROOT}/policies/allowed_signers" -I openshell-policy-review \
    -n openshell-boundary -s "${BOUNDARY}.sig" <"$BOUNDARY" >/dev/null 2>&1; then
  echo "APPROVAL-GATE boundary untrusted; refusing to evaluate proposals" >&2
  exit 1
fi

pending="$(openshell rule get "$SANDBOX" --status pending 2>&1 | sed -E $'s/\033\\[[0-9;]*[[:alpha:]]//g')"
# One TSV line per pending chunk: chunk, rule, endpoints, binaries, openshell's own check.
chunks="$(printf '%s\n' "$pending" | python3 -c '
import re, sys
cur = None
out = []
for raw in sys.stdin:
    line = raw.strip()
    if line.startswith("Chunk:"):
        cur = {"chunk": line.split(":", 1)[1].strip(), "rule": "", "endpoints": "", "binaries": "", "check": ""}
        out.append(cur)
    elif cur is not None and ":" in line:
        key, val = [s.strip() for s in line.split(":", 1)]
        if key == "Rule": cur["rule"] = val
        elif key == "Endpoints": cur["endpoints"] = val
        elif key == "Binaries": cur["binaries"] = val
        elif key in ("Prover", "Application"): cur["check"] = val
for c in out:
    print("\t".join([c["chunk"], c["rule"], c["endpoints"], c["binaries"], c["check"]]))
')"

if [ -z "$chunks" ]; then
  echo "no pending proposals for ${SANDBOX}"
  exit 0
fi

printf '%-10s  %-36s  %-28s  %-17s  %s\n' "CHUNK" "PROPOSAL" "OPENSHELL'S OWN CHECK" "BOUNDARY PROOF" "DECISION"
while IFS="$(printf '\t')" read -r chunk rule endpoints binaries check; do
  [ -n "$chunk" ] || continue
  short="${chunk%%-*}"
  candidate="${OUT}/${short}.yaml"
  # Compose: the current policy plus exactly what the proposal would allow.
  python3 - "$POLICY" "$candidate" "$short" "$endpoints" "$binaries" <<'PY'
import re, sys
src, dst, short, endpoints, binaries = sys.argv[1:6]
eps = re.findall(r"([A-Za-z0-9.\-]+):(\d+)\s*\[(L4|L7)\]", endpoints)
bins = [b.strip() for b in binaries.split(",") if b.strip()]
block = [f"  proposal_{short}:", f"    name: proposal-{short}", "    endpoints:"]
for host, port, _layer in eps:
    block += [f"      - host: {host}", f"        port: {port}"]
block.append("    binaries:")
block += [f"      - path: {b}" for b in bins]
lines = open(src).read().rstrip("\n").split("\n")
# network_policies is the last top-level block in these policies; append to it.
start = next(i for i, l in enumerate(lines) if l.startswith("network_policies:"))
end = next((i for i in range(start + 1, len(lines)) if lines[i][:1] not in ("", " ", "#")), len(lines))
lines[end:end] = block
open(dst, "w").write("\n".join(lines) + "\n")
PY
  set +e
  "$PROVER" check --boundary "$BOUNDARY" "$candidate" -o json >"${candidate%.yaml}.json" 2>/dev/null
  set -e
  read -r result why < <(python3 - "${candidate%.yaml}.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
c = d.get("counterexample") or {}
if c.get("domain") == "network":
    via = f" via {c['binary']}" if c.get("binary") else ""
    if c.get("method"):
        why = f"{c['method']} {c.get('host')}:{c.get('port')}{c.get('path') or ''}{via}"
    else:
        why = f"raw {c.get('protocol') or 'tcp'} to {c.get('host')}:{c.get('port')}{via}"
elif c:
    why = json.dumps(c, separators=(",", ":"))
else:
    why = d.get("reason") or "-"
print(d.get("result"), why)
PY
)
  decision=""
  if [ "$result" != "within_boundary" ]; then
    decision="rejected (${why})"
    if [ "${DRY_RUN:-0}" != "1" ]; then
      openshell rule reject "$SANDBOX" --chunk-id "$chunk" \
        --reason "outside operator boundary: ${result} ${why}" >/dev/null
    fi
  elif [ -t 0 ] && [ "${DRY_RUN:-0}" != "1" ]; then
    printf 'approve %s for %s? [y/N] ' "$rule" "$SANDBOX" >&2
    read -r answer </dev/tty
    if [ "$answer" = "y" ]; then
      openshell rule approve "$SANDBOX" --chunk-id "$chunk" >/dev/null
      decision="approved by a human"
    else
      decision="left pending (human said no)"
    fi
  else
    decision="needs a human (inside the boundary)"
  fi
  printf '%-10s  %-36s  %-28s  %-17s  %s\n' "$short" "${endpoints} ${binaries}" "${check:-none}" "$result" "$decision"
  host_port="$(printf '%s\n' "$endpoints" | sed -nE 's/^([A-Za-z0-9.-]+):([0-9]+).*/\1 \2/p')"
  if [ "$result" != "within_boundary" ] && [ -n "$host_port" ] && \
     awk -v h="${host_port% *}" -v p="${host_port#* }" '$0 ~ "host: "h"$" {f=1} f && $0 ~ "port: "p"$" {print; exit}' "$BOUNDARY" | grep -q .; then
    echo "            hint: the boundary does allow a narrower rule for ${host_port% *} (read-only REST, curl)."
    echo "            Put that in agent-policy.yaml and run make policy-sign; the proof runs again there."
  fi
  printf 'APPROVAL-GATE %s %s %s\n' "$rule" "$result" "${decision%% *}" | tee -a "${OUT}/decisions.txt" >/dev/null
done <<<"$chunks"
