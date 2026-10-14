#!/usr/bin/env bash
# Sign a reviewed policy. Refuses to sign anything the prover cannot place
# inside the operator boundary, so a signature always implies containment.
# To take over review, put your own public key in policies/allowed_signers and
# point POLICY_REVIEW_KEY at the matching private key.
set -euo pipefail

ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)"
KEY="${POLICY_REVIEW_KEY:-${HOME}/.ssh/openshell_policy_review}"
if [ "$#" -eq 0 ]; then
  set -- "${ROOT}/policies/openshell/agent-policy.yaml" "${ROOT}/policies/openshell/agent-policy-kyverno.yaml"
fi
if [ ! -f "$KEY" ]; then
  echo "review key not found: ${KEY} (set POLICY_REVIEW_KEY)" >&2
  exit 2
fi

for policy in "$@"; do
  # Prove first; a missing or stale signature is expected here, so only the
  # boundary line decides.
  out="$(POLICY_SIG=/dev/null bash "${ROOT}/scripts/policy-gate.sh" "$policy" || true)"
  if ! printf '%s\n' "$out" | grep -q '^POLICY-GATE boundary within_boundary'; then
    printf '%s\n' "$out" | grep -E '^POLICY-GATE (boundary|counterexample|reason)' >&2
    echo "not signing ${policy#"${ROOT}/"}: outside the boundary" >&2
    exit 1
  fi
  rm -f "${policy}.sig"
  ssh-keygen -q -Y sign -f "$KEY" -n openshell-policy "$policy"
  echo "signed ${policy#"${ROOT}/"} -> ${policy#"${ROOT}/"}.sig"
done
