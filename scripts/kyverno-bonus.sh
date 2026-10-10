#!/usr/bin/env bash
# Start kyverno-authz and kyverno-guard, register the middleware, and probe it.
# Does not change policies/openshell/agent-policy.yaml, so make verify stays on
# the ten-row matrix.
set -euo pipefail

ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)"
AUTHZ_IMAGE="${AUTHZ_IMAGE:-ghcr.io/kyverno/kyverno-authz:v0.4.0}"
AUTHZ_NAME="${AUTHZ_NAME:-kyverno-authz-guardrails}"
AUTHZ_URL="${KYVERNO_AUTHZ_URL:-http://127.0.0.1:9081/}"
GUARD_ADDR="${LISTEN_ADDR:-127.0.0.1:50061}"
SANDBOX_NAME="${KYVERNO_SANDBOX_NAME:-guardrails-kyverno}"
IMAGE="${IMAGE:-openshell-guardrails-agent:dev}"
POLICY="${ROOT}/policies/openshell/agent-policy-kyverno.yaml"
PID_FILE="${ROOT}/bonus/kyverno-guard/kyverno-guard.pid"
BIN="${ROOT}/bonus/kyverno-guard/bin/kyverno-guard"
LOG_FILE="${ROOT}/bonus/kyverno-guard/kyverno-guard.log"
GATEWAY_CONFIG="${OPENSHELL_GATEWAY_CONFIG:-/opt/homebrew/var/openshell/gateway.toml}"
BEGIN_MARK="# BEGIN kyverno-guard"
END_MARK="# END kyverno-guard"

if [ ! -f "$GATEWAY_CONFIG" ]; then
  echo "gateway config not found: ${GATEWAY_CONFIG}" >&2
  exit 1
fi

echo "starting ${AUTHZ_NAME} from ${AUTHZ_IMAGE}"
docker rm -f "$AUTHZ_NAME" >/dev/null 2>&1 || true
docker run -d --name "$AUTHZ_NAME" \
  -p 127.0.0.1:9081:9081 \
  -v "${ROOT}/bonus/kyverno-guard/policy:/data/policies:ro" \
  "$AUTHZ_IMAGE" \
  serve http authz-server \
  --kube-policy-source=false \
  --external-policy-source=file://data/policies \
  --nested-request \
  --server-address=:9081 >/dev/null

ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if curl -fsS -m 2 -o /dev/null -X POST "$AUTHZ_URL" \
    --data-binary $'GET /repos/example-org/example-repo HTTP/1.1\r\nHost: api.github.com\r\nContent-Length: 0\r\n\r\n'; then
    ready=1
    break
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "kyverno-authz did not accept the allow-path probe" >&2
  docker logs "$AUTHZ_NAME" >&2 || true
  exit 1
fi

deny_body="$(curl -sS -m 5 -D /tmp/kyverno-deny.hdr -o /tmp/kyverno-deny.body -X POST "$AUTHZ_URL" \
  --data-binary $'GET /repos/example-org/example-repo/contents/.env HTTP/1.1\r\nHost: api.github.com\r\nContent-Length: 0\r\n\r\n' || true)"
deny_code="$(awk 'BEGIN { code = "" } /^HTTP\// { code = $2 } END { print code }' /tmp/kyverno-deny.hdr)"
if [ "$deny_code" != "403" ] || [ "$(tr -d '\r\n' </tmp/kyverno-deny.body)" != "kyverno_path_denied" ]; then
  echo "kyverno-authz deny probe returned HTTP ${deny_code:-none} body=$(tr -d '\r\n' </tmp/kyverno-deny.body)" >&2
  docker logs "$AUTHZ_NAME" >&2 || true
  exit 1
fi
rm -f /tmp/kyverno-deny.hdr /tmp/kyverno-deny.body
unset deny_body

if [ -f "$PID_FILE" ]; then
  old="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$old" ]; then
    kill "$old" >/dev/null 2>&1 || true
    sleep 1
  fi
fi
if nc -z 127.0.0.1 50061 >/dev/null 2>&1; then
  echo "port 50061 is already in use; stop that process (make kyverno-stop) and retry" >&2
  exit 1
fi
echo "building kyverno-guard"
( cd "${ROOT}/bonus/kyverno-guard" && go build -o "$BIN" . )
echo "starting kyverno-guard on ${GUARD_ADDR}"
# nohup + a real binary: the server outlives this shell, and the PID file names
# the server itself, so make kyverno-stop can stop it.
KYVERNO_AUTHZ_URL="$AUTHZ_URL" LISTEN_ADDR="$GUARD_ADDR" nohup "$BIN" >>"$LOG_FILE" 2>&1 &
echo $! >"$PID_FILE"
guard_ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  if nc -z 127.0.0.1 50061 >/dev/null 2>&1; then
    guard_ready=1
    break
  fi
  sleep 1
done
if [ "$guard_ready" -ne 1 ]; then
  echo "kyverno-guard did not listen on ${GUARD_ADDR}" >&2
  cat "$LOG_FILE" >&2 || true
  exit 1
fi

staged="$(mktemp)"
cp "$GATEWAY_CONFIG" "$staged"
if ! grep -q "$BEGIN_MARK" "$staged"; then
  cat >>"$staged" <<EOF
${BEGIN_MARK}
[[openshell.supervisor.middleware]]
name = "kyverno-guard"
grpc_endpoint = "http://127.0.0.1:50061"
allow_insecure_transport = true
max_payload_bytes = 262144
timeout = "2s"
${END_MARK}
EOF
fi

echo "validating gateway config"
/opt/homebrew/opt/openshell/bin/openshell-gateway --config "$staged" config preflight
cp "$GATEWAY_CONFIG" "${GATEWAY_CONFIG}.bak-kyverno"
cp "$staged" "$GATEWAY_CONFIG"
rm -f "$staged"

echo "restarting openshell so it loads kyverno-guard"
brew services restart openshell
connected=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if openshell status 2>&1 | grep -q 'Connected'; then
    connected=1
    break
  fi
  sleep 1
done
if [ "$connected" -ne 1 ]; then
  echo "openshell did not return to Connected" >&2
  openshell status >&2 || true
  exit 1
fi

echo "running the Kyverno path probe in ${SANDBOX_NAME}"
openshell sandbox delete "$SANDBOX_NAME" >/dev/null 2>&1 || true
b64="$(base64 <"${ROOT}/bonus/kyverno-guard/probe.sh" | tr -d '\n')"
inner="printf '%s' '${b64}' | base64 -d > /tmp/kyverno-probe.sh && sh /tmp/kyverno-probe.sh"
probe_out="$(mktemp)"
set +e
openshell sandbox create \
  --name "$SANDBOX_NAME" \
  --from "$IMAGE" \
  --policy "$POLICY" \
  --provider "${PROVIDER:-demo-github}" \
  --no-tty \
  -- sh -c "$inner" | tee "$probe_out"
create_rc=$?
set -e
sleep 2
printf '%s\n' "----- sandbox log -----"
openshell logs "$SANDBOX_NAME" --since 10m --source sandbox 2>&1 | sed -E $'s/\033\\[[0-9;]*[[:alpha:]]//g' | grep -E 'engine:middleware|kyverno_path_denied|FINDING:CREATE' || true
allow_line="$(grep 'KYVERNO ALLOW_PATH ' "$probe_out" || true)"
deny_line="$(grep 'KYVERNO DENY_PATH ' "$probe_out" || true)"
rm -f "$probe_out"
printf '%s\n' "allow: ${allow_line:-missing}"
printf '%s\n' "deny: ${deny_line:-missing}"
case "$allow_line" in
  *" 403"|*" 000"|"") echo "allow path was not forwarded" >&2; exit 1 ;;
esac
case "$deny_line" in
  *" 403") ;;
  *) echo "deny path was not blocked by Kyverno" >&2; exit 1 ;;
esac
if [ "$create_rc" -ne 0 ]; then
  echo "sandbox create exited ${create_rc}" >&2
  exit "$create_rc"
fi
echo "kyverno bonus wired"
