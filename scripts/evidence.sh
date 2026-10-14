#!/usr/bin/env bash
# Package the last verify.sh run as a tamper-evident evidence bundle:
# versions, file hashes, the policy-gate result, and every graded row with the
# exact log line that proved it, hash-chained in order and signed.
# Read-only apart from .out/evidence/.
set -euo pipefail

ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)"
RUN_DIR="${ROOT}/.out/last-run"
OUT_DIR="${ROOT}/.out/evidence"
KEY="${POLICY_REVIEW_KEY:-${HOME}/.ssh/openshell_policy_review}"
IMAGE="${IMAGE:-openshell-guardrails-agent:dev}"

if [ ! -f "${RUN_DIR}/matrix.tsv" ]; then
  echo "no graded run in ${RUN_DIR#"${ROOT}/"}; run make verify first" >&2
  exit 2
fi
mkdir -p "$OUT_DIR"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
bundle="${OUT_DIR}/evidence-${stamp}.json"

export EV_ROOT="$ROOT" EV_RUN="$RUN_DIR" EV_BUNDLE="$bundle" EV_STAMP="$stamp"
export EV_OPENSHELL="$(openshell --version 2>/dev/null | head -1 || true)"
export EV_PROVER="$( (openshell-prover --version || /opt/homebrew/opt/openshell/bin/openshell-prover --version) 2>/dev/null | head -1 || true)"
export EV_DOCKER="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
export EV_IMAGE="$IMAGE"
export EV_IMAGE_ID="$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || true)"
export EV_COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
export EV_DIRTY="$(git -C "$ROOT" status --porcelain 2>/dev/null | grep -v '^?? ' | wc -l | tr -d ' ')"

python3 - <<'PY'
import hashlib, json, os, pathlib

root = pathlib.Path(os.environ["EV_ROOT"])
run = pathlib.Path(os.environ["EV_RUN"])
meta = dict(l.split("=", 1) for l in (run / "meta.txt").read_text().splitlines() if "=" in l)

def sha(path):
    p = root / path
    return hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else None

policy = meta.get("policy", "policies/openshell/agent-policy.yaml")
files = [policy, policy + ".sig", "policies/boundary/org-boundary.yaml",
         "policies/boundary/org-boundary.yaml.sig", "policies/allowed_signers",
         meta.get("events", "expected_events.tsv"), "scenarios/run_all.sh", "verify.sh",
         "scripts/policy-gate.sh"]

# Hash chain over the graded rows, in grading order. Changing, dropping or
# reordering any row changes every hash after it and the final head.
head = hashlib.sha256(b"openshell-guardrails-evidence-v1").hexdigest()
rows = []
for line in (run / "matrix.tsv").read_text().splitlines():
    rid, plane, domain, kind, result, matched = (line.split("\t") + [""] * 6)[:6]
    link = "\t".join([head, rid, result, matched]).encode()
    head = hashlib.sha256(link).hexdigest()
    rows.append({"id": rid, "plane": plane, "domain": domain, "kind": kind,
                 "result": result, "evidence": matched, "chain": head})

prover_path = root / ".out/policy-gate/prover.json"
bundle = {
    "schema": "openshell-guardrails-evidence/v1",
    "generated_at": os.environ["EV_STAMP"],
    "repo_commit": os.environ["EV_COMMIT"] or None,
    "repo_uncommitted_changes": int(os.environ["EV_DIRTY"] or 0),
    "run": meta,
    "versions": {"openshell": os.environ["EV_OPENSHELL"] or None,
                 "openshell_prover": os.environ["EV_PROVER"] or None,
                 "docker_server": os.environ["EV_DOCKER"] or None},
    "image": {"ref": os.environ["EV_IMAGE"], "id": os.environ["EV_IMAGE_ID"] or None},
    "files_sha256": {f: sha(f) for f in files},
    "policy_gate": {"output": (run / "gate.txt").read_text().splitlines(),
                    "prover": json.loads(prover_path.read_text()) if prover_path.exists() else None},
    "rows": rows,
    "chain_head": head,
    "verdict": {"pass": sum(r["result"] == "PASS" for r in rows),
                "fail": sum(r["result"] != "PASS" for r in rows),
                "rows": len(rows)},
}
pathlib.Path(os.environ["EV_BUNDLE"]).write_text(json.dumps(bundle, indent=2) + "\n")
v = bundle["verdict"]
print(f"evidence: {v['pass']} PASS, {v['fail']} FAIL ({v['rows']} rows), chain head {head[:16]}…")
PY

if [ -f "$KEY" ]; then
  ssh-keygen -q -Y sign -f "$KEY" -n openshell-evidence "$bundle"
  echo "signed:   ${bundle#"${ROOT}/"}.sig"
else
  echo "unsigned: no review key at ${KEY} (set POLICY_REVIEW_KEY to sign)"
fi
echo "bundle:   ${bundle#"${ROOT}/"}"
echo "check:    bash scripts/evidence-verify.sh ${bundle#"${ROOT}/"}"
