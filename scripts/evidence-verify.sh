#!/usr/bin/env bash
# Check an evidence bundle: its signature, its hash chain, and whether the
# repo files it names still have the hashes it recorded.
# Exit 0 when the chain holds and any signature present is valid (file drift
# is reported, not fatal).
set -euo pipefail

ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)"
bundle="${1:?usage: scripts/evidence-verify.sh .out/evidence/evidence-<stamp>.json}"
[ -f "$bundle" ] || bundle="${ROOT}/${bundle}"

ok=1
if [ -f "${bundle}.sig" ] && ssh-keygen -Y verify -f "${ROOT}/policies/allowed_signers" \
    -I openshell-policy-review -n openshell-evidence -s "${bundle}.sig" <"$bundle" >/dev/null 2>&1; then
  echo "signature: valid (openshell-policy-review)"
elif [ -f "${bundle}.sig" ]; then
  echo "signature: INVALID (the bundle changed after it was signed)"
  ok=0
else
  # Bundles made without the review key (anyone but the reviewer) are unsigned.
  # The chain still catches edits; it cannot prove who produced the bundle.
  echo "signature: none (made without the review key; the chain is checked, authorship is not)"
fi

EV_ROOT="$ROOT" python3 - "$bundle" <<'PY' || ok=0
import hashlib, json, os, pathlib, sys
b = json.loads(pathlib.Path(sys.argv[1]).read_text())
root = pathlib.Path(os.environ["EV_ROOT"])
head = hashlib.sha256(b"openshell-guardrails-evidence-v1").hexdigest()
for i, r in enumerate(b["rows"]):
    head = hashlib.sha256("\t".join([head, r["id"], r["result"], r["evidence"]]).encode()).hexdigest()
    if head != r["chain"]:
        print(f"chain:     BROKEN at row {i + 1} ({r['id']})")
        sys.exit(1)
if head != b["chain_head"]:
    print("chain:     BROKEN at the head")
    sys.exit(1)
v = b["verdict"]
print(f"chain:     intact, {len(b['rows'])} rows, {v['pass']} PASS / {v['fail']} FAIL")
drift = [f for f, h in b["files_sha256"].items()
         if h and (not (root / f).exists() or hashlib.sha256((root / f).read_bytes()).hexdigest() != h)]
print("files:     unchanged since the run" if not drift else "files:     changed since the run: " + ", ".join(drift))
PY

[ "$ok" -eq 1 ]
