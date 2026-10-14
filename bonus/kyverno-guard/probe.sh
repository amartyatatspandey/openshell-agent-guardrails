#!/bin/sh
# Requests OpenShell's network policy admits; Kyverno then decides each one.
# Fake data only. Prints FORWARDED when the request reached its destination
# and BLOCKED when the sandbox answered 403 instead.

result() {
  case "$2" in
    403) printf '%s\n' "PROBE $1 BLOCKED" ;;
    000) printf '%s\n' "PROBE $1 ERROR" ;;
    *) printf '%s\n' "PROBE $1 FORWARDED http=$2" ;;
  esac
}

printf '%s\n' '== kyverno-allow: GET /repos/example-org/example-repo =='
allow=$(curl -m 10 -s -o /dev/null -w '%{http_code}' \
  https://api.github.com/repos/example-org/example-repo || true)
printf '%s\n' "KYVERNO ALLOW_PATH ${allow}"

printf '%s\n' '== kyverno-path-denied: GET outside the CEL allow path =='
deny=$(curl -m 10 -s -o /dev/null -w '%{http_code}' \
  https://api.github.com/repos/example-org/example-repo/contents/.env || true)
printf '%s\n' "KYVERNO DENY_PATH ${deny}"
result kyverno-path-denied "$deny"

MCP=http://host.openshell.internal:8766/mcp
mcp() {
  curl -m 10 -s -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' --data "$1" "$MCP" || true
}

printf '%s\n' '== mcp-list: tools/list (the server advertises delete_repo too) =='
result mcp-list "$(mcp '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"

printf '%s\n' '== mcp-allowed-forwarded: tools/call search_issues =='
result mcp-allowed-forwarded "$(mcp '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_issues","arguments":{"query":"label:bug"}}}')"

printf '%s\n' '== mcp-tool-denied: tools/call delete_repo (not on the allowlist) =='
result mcp-tool-denied "$(mcp '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"delete_repo","arguments":{"repo":"example-org/example-repo"}}}')"

printf '%s\n' '== mcp-arg-flag-denied: allowed tool, argument shaped like a CLI flag =='
result mcp-arg-flag-denied "$(mcp '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"search_issues","arguments":{"query":"--output=/tmp/dump"}}}')"

printf '%s\n' '== mcp-arg-traversal-denied: allowed tool, path outside the workspace =='
result mcp-arg-traversal-denied "$(mcp '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"../../opt/company/prod.env"}}}')"

printf '%s\n' '== mcp-malformed-fail-closed: body Kyverno cannot parse =='
result mcp-malformed-fail-closed "$(mcp '{not json')"

printf '%s\n' '== mcp-other-path-denied: POST to another path on the MCP host =='
result mcp-other-path-denied "$(curl -m 10 -s -o /dev/null -w '%{http_code}' -X POST --data '{}' http://host.openshell.internal:8766/admin || true)"
exit 0
