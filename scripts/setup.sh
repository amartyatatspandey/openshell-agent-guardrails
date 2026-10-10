#!/usr/bin/env bash
# Build the demo image and register a fake GitHub provider. Idempotent.
# The token value is not a credential. OpenShell must not be pointed at a real token for this demo.
set -euo pipefail

ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)"
IMAGE="${IMAGE:-openshell-guardrails-agent:dev}"
PROVIDER="${PROVIDER:-demo-github}"
PROFILE_URL="${PROFILE_URL:-https://raw.githubusercontent.com/NVIDIA/OpenShell/v0.1.3/providers/github.yaml}"
FAKE_TOKEN="${FAKE_TOKEN:-FAKE_NOT_A_REAL_TOKEN}"

echo "building ${IMAGE}"
docker build -t "${IMAGE}" -f "${ROOT}/image/Dockerfile" "${ROOT}/image"

echo "importing GitHub provider profile (fake-token demo)"
if openshell profile import --url "${PROFILE_URL}"; then
  echo "imported GitHub profile from ${PROFILE_URL}"
else
  echo "profile import returned non-zero; continuing if the github profile is already present"
fi

if openshell provider get "${PROVIDER}" >/dev/null 2>&1; then
  echo "provider ${PROVIDER} already exists"
else
  openshell provider create \
    --name "${PROVIDER}" \
    --type github \
    --credential "GITHUB_TOKEN=${FAKE_TOKEN}"
  echo "created provider ${PROVIDER} with a placeholder token"
fi

echo "setup complete"
