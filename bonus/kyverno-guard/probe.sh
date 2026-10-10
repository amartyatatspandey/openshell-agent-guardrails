#!/bin/sh
# Two GETs that OpenShell's read-only rule admits. Kyverno allows only the first path.
printf '%s\n' '== kyverno-allow: GET /repos/example-org/example-repo =='
allow=$(curl -m 10 -s -o /dev/null -w '%{http_code}' \
  https://api.github.com/repos/example-org/example-repo || true)
printf '%s\n' "KYVERNO ALLOW_PATH ${allow}"

printf '%s\n' '== kyverno-deny: GET outside the CEL allow path =='
deny=$(curl -m 10 -s -o /dev/null -w '%{http_code}' \
  https://api.github.com/repos/example-org/example-repo/contents/.env || true)
printf '%s\n' "KYVERNO DENY_PATH ${deny}"
exit 0
