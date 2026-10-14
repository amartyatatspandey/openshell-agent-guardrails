#!/usr/bin/env bash
# Show that an approval cannot take the agent past the operator boundary.
# The agent tries two hosts its policy does not allow; OpenShell denies both
# and proposes rules to allow them; scripts/approval-gate.sh proves each
# proposal against the boundary and rejects what falls outside it.
# Exit 0 when both proposals are rejected with a proof.
set -euo pipefail

ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)"
SANDBOX="${APPROVAL_SANDBOX:-guardrails-approval}"
IMAGE="${IMAGE:-openshell-guardrails-agent:dev}"
POLICY="${ROOT}/policies/openshell/agent-policy.yaml"

bash "${ROOT}/scripts/policy-gate.sh" "$POLICY" >/dev/null || {
  echo "policy gate refused ${POLICY#"${ROOT}/"}; not starting the approval demo" >&2
  exit 1
}

echo "agent attempts two hosts its policy does not name"
openshell sandbox delete "$SANDBOX" >/dev/null 2>&1 || true
openshell sandbox create --name "$SANDBOX" --from "$IMAGE" --policy "$POLICY" --no-tty -- sh -c '
  printf "%s\n" "== approval-1: curl https://example.com/ (outside the boundary) =="
  curl -m 8 -s -o /dev/null -w "http=%{http_code}\n" https://example.com/ || true
  printf "%s\n" "== approval-2: curl raw.githubusercontent.com (boundary allows read-only REST only) =="
  curl -m 8 -s -o /dev/null -w "http=%{http_code}\n" https://raw.githubusercontent.com/example-org/example-repo/main/README.md || true
' 2>&1 | grep -E '^(==|http=)' || true

echo "waiting for OpenShell to propose rules from those denials"
n=0
for _ in $(seq 1 20); do
  n="$(openshell rule get "$SANDBOX" --status pending 2>/dev/null | grep -c 'Chunk:' || true)"
  [ "$n" -ge 2 ] && break
  sleep 2
done
if [ "$n" -lt 2 ]; then
  echo "expected two pending proposals, saw ${n}" >&2
  openshell rule get "$SANDBOX" >&2 || true
  exit 1
fi
echo
bash "${ROOT}/scripts/approval-gate.sh" "$SANDBOX" </dev/null
echo
echo "OpenShell's record:"
openshell rule get "$SANDBOX" 2>&1 | sed -E $'s/\033\\[[0-9;]*[[:alpha:]]//g' | grep -E '^\s+(Rule|Status):' | paste - - | sed -E 's/^ +//'
rejected="$(grep -c ' rejected$' "${ROOT}/.out/approval/decisions.txt" || true)"
echo
echo "${rejected}/2 proposals rejected by proof"
[ "$rejected" -eq 2 ]
