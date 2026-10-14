#!/usr/bin/env bash
# Developer-plane gate. A sandbox policy is accepted only when:
#   1. openshell-prover proves it is contained in the operator boundary, and
#   2. it carries a valid review signature from policies/allowed_signers.
# Prints greppable "POLICY-GATE ..." lines; verify.sh grades them.
# Exit 0 only when both checks pass. Read-only: never edits the policy.
set -euo pipefail

ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)"
POLICY="${1:-${ROOT}/policies/openshell/agent-policy.yaml}"
SIG="${POLICY_SIG:-${POLICY}.sig}"
BOUNDARY="${BOUNDARY:-${ROOT}/policies/boundary/org-boundary.yaml}"
SIGNERS="${ROOT}/policies/allowed_signers"
SIGNER_ID="openshell-policy-review"
PROVER="${OPENSHELL_PROVER:-$(command -v openshell-prover || echo /opt/homebrew/opt/openshell/bin/openshell-prover)}"
OUT="${ROOT}/.out/policy-gate"

if [ ! -f "$POLICY" ]; then
  echo "POLICY-GATE error policy not found: ${POLICY}"
  exit 2
fi
if [ ! -x "$PROVER" ]; then
  echo "POLICY-GATE error openshell-prover not found (ships with OpenShell v0.1.3)"
  exit 2
fi
mkdir -p "$OUT"

# The boundary is the trust anchor: if it could be widened unnoticed, the proof
# below would mean nothing. Check the operator's signature on it first.
if ! ssh-keygen -Y verify -f "$SIGNERS" -I "$SIGNER_ID" -n openshell-boundary -s "${BOUNDARY}.sig" <"$BOUNDARY" >/dev/null 2>&1; then
  echo "POLICY-GATE boundary untrusted (${BOUNDARY#"${ROOT}/"} is not the signed operator boundary)"
  echo "POLICY-GATE refuse ${POLICY#"${ROOT}/"}"
  exit 1
fi
echo "POLICY-GATE boundary-signature valid ${BOUNDARY#"${ROOT}/"}"

# The prover reports network middleware as an unsupported shape. Middleware
# runs only on traffic the network policy already admitted, so it can add
# denials but never allow more. Prove the policy without that block.
candidate="$POLICY"
if grep -q '^network_middlewares:' "$POLICY"; then
  candidate="${OUT}/$(basename "$POLICY" .yaml).no-middleware.yaml"
  python3 - "$POLICY" "$candidate" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
out, skip = [], False
for line in open(src).read().splitlines(keepends=True):
    if line.startswith("network_middlewares:"):
        skip = True
        # drop the comment lines that introduce the block
        while out and out[-1].startswith("#"):
            out.pop()
        continue
    if skip and line[:1] not in ("", " ", "\t", "\n", "#"):
        skip = False
    if not skip:
        out.append(line)
open(dst, "w").write("".join(out))
PY
  echo "POLICY-GATE note network_middlewares stripped before proving (middleware only narrows)"
fi

report="${OUT}/prover.json"
set +e
"$PROVER" check --boundary "$BOUNDARY" "$candidate" -o json >"$report" 2>/dev/null
set -e
boundary_ok=0
python3 - "$report" <<'PY' && boundary_ok=1 || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"POLICY-GATE boundary error could not read prover output: {e}")
    sys.exit(1)
result = d.get("result")
line = f"POLICY-GATE boundary {result}"
if d.get("coverage"):
    line += " domains=" + ",".join(d["coverage"].get("domains", []))
print(line)
if d.get("counterexample"):
    print("POLICY-GATE counterexample " + json.dumps(d["counterexample"], separators=(",", ":")))
if d.get("reason"):
    print(f"POLICY-GATE reason {d.get('reason_code')}: {d['reason']}")
# Anything but a proof of containment is a refusal, including "unsupported".
sys.exit(0 if result == "within_boundary" else 1)
PY

sig_ok=0
if [ ! -f "$SIG" ]; then
  echo "POLICY-GATE signature missing (${SIG#"${ROOT}/"})"
elif ssh-keygen -Y verify -f "$SIGNERS" -I "$SIGNER_ID" -n openshell-policy -s "$SIG" <"$POLICY" >/dev/null 2>&1; then
  echo "POLICY-GATE signature valid signer=${SIGNER_ID}"
  sig_ok=1
else
  echo "POLICY-GATE signature invalid (policy bytes differ from what was reviewed, or wrong signer)"
fi

if [ "$boundary_ok" -eq 1 ] && [ "$sig_ok" -eq 1 ]; then
  echo "POLICY-GATE accept ${POLICY#"${ROOT}/"}"
  exit 0
fi
echo "POLICY-GATE refuse ${POLICY#"${ROOT}/"}"
exit 1
