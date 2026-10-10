#!/usr/bin/env bash
# Remove the kyverno-guard gateway registration and stop the bonus processes.
set -euo pipefail

ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)"
AUTHZ_NAME="${AUTHZ_NAME:-kyverno-authz-guardrails}"
PID_FILE="${ROOT}/bonus/kyverno-guard/kyverno-guard.pid"
GATEWAY_CONFIG="${OPENSHELL_GATEWAY_CONFIG:-/opt/homebrew/var/openshell/gateway.toml}"
BEGIN_MARK="# BEGIN kyverno-guard"
END_MARK="# END kyverno-guard"

if [ -f "$PID_FILE" ]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "${pid}" ]; then
    kill "$pid" >/dev/null 2>&1 || true
  fi
  rm -f "$PID_FILE"
fi
docker rm -f "$AUTHZ_NAME" >/dev/null 2>&1 || true

if [ -f "$GATEWAY_CONFIG" ] && grep -q "$BEGIN_MARK" "$GATEWAY_CONFIG"; then
  staged="$(mktemp)"
  awk -v begin="$BEGIN_MARK" -v end="$END_MARK" '
    $0 == begin { skip = 1; next }
    $0 == end { skip = 0; next }
    skip != 1 { print }
  ' "$GATEWAY_CONFIG" >"$staged"
  /opt/homebrew/opt/openshell/bin/openshell-gateway --config "$staged" config preflight
  cp "$staged" "$GATEWAY_CONFIG"
  rm -f "$staged"
  echo "restarting openshell without kyverno-guard"
  brew services restart openshell
fi

echo "kyverno bonus stopped"
