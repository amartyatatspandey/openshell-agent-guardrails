#!/bin/sh
# One labelled denial attempt per control. Run with POSIX sh (dash).
# Expected failures are ignored so every probe still runs; verify.sh grades the result.

printf '%s\n' '== cred-unauthorized-endpoint: Provider credential blocked at an unauthorized endpoint =='
printf '%s\n' '== cred-endpoint-mismatch: Credential rejected when the request falls outside the provider endpoint binding =='
curl -m 10 -s -o /dev/null \
  -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
  https://httpbin.org/ >/dev/null 2>&1 || true

printf '%s\n' '== egress-default-deny: Default-deny egress to a host that no policy allows =='
curl -m 10 -s -o /dev/null https://example.com/ >/dev/null 2>&1 || true

printf '%s\n' '== dns-policy-refuse: DNS answer refused because the name is not eligible for policy DNS =='
dig +time=3 +tries=1 not-eligible.invalid >/dev/null 2>&1 || true

printf '%s\n' '== metadata-address-refused: Cloud metadata link-local address refused =='
curl -m 10 -s -o /dev/null http://169.254.169.254/ >/dev/null 2>&1 || true

printf '%s\n' '== l7-delete-denied: GitHub DELETE denied by the read-only L7 rule =='
curl -m 10 -s -o /dev/null -X DELETE \
  -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
  https://api.github.com/repos/example-org/example-repo >/dev/null 2>&1 || true

printf '%s\n' '== l7-post-denied: GitHub POST denied by the read-only L7 rule =='
curl -m 10 -s -o /dev/null -X POST \
  -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
  -H 'Content-Type: application/json' \
  --data '{"title":"probe"}' \
  https://api.github.com/repos/example-org/example-repo/issues >/dev/null 2>&1 || true

printf '%s\n' '== binary-identity-denied: python3 denied to api.github.com; only the allowed binary may open that endpoint =='
python3 -c 'import urllib.request; urllib.request.urlopen("https://api.github.com/", timeout=10)' >/dev/null 2>&1 || true

printf '%s\n' '== fs-secret-denied: Read of the world-readable planted secret denied by Landlock (recorded by the supervisor when the log shows it; otherwise the probe line) =='
fs_err=/tmp/probe-fs-secret.err
if cat /opt/company/prod.env >/dev/null 2>"$fs_err"; then
  printf '%s\n' 'PROBE fs-secret-denied NOT-BLOCKED'
elif grep -E -q -e 'Permission denied|Operation not permitted' "$fs_err"; then
  printf '%s\n' 'PROBE fs-secret-denied BLOCKED'
else
  printf '%s\n' 'PROBE fs-secret-denied NOT-BLOCKED'
fi

printf '%s\n' '== priv-nonroot-denied: Privilege gain denied; workload stays non-root (recorded by the supervisor when the log shows it; otherwise the probe line) =='
priv_err=/tmp/probe-priv.err
if python3 -c 'import os; os.setuid(0)' >/dev/null 2>"$priv_err"; then
  printf '%s\n' 'PROBE priv-nonroot-denied NOT-BLOCKED'
elif grep -E -q -e 'Operation not permitted|Permission denied|PermissionError' "$priv_err"; then
  printf '%s\n' 'PROBE priv-nonroot-denied BLOCKED'
else
  printf '%s\n' 'PROBE priv-nonroot-denied NOT-BLOCKED'
fi

rm -f "$fs_err" "$priv_err"
exit 0
