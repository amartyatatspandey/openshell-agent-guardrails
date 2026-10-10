# Sandbox policy

`agent-policy.yaml` is the OpenShell v0.1.3 policy attached at `openshell sandbox create --policy`. It is the artifact a Developer-plane review would admit. The running sandbox enforces it. This directory does not contain probes.

Pinned CLI: OpenShell **v0.1.3**. On Docker Desktop for Mac, **Settings > Resources > Network > Enable host networking** must be on. If it is off, sandbox creation fails with `Startup configuration fetch failed`. Docker 28 or newer is required. `scripts/preflight.sh` checks these and does not change them.

## What the file sets

| Block | Effect | How `verify.sh` sees it |
| --- | --- | --- |
| `network_policies` omitted destinations | Default-deny egress. A connection to `example.com:443` is denied with `transparent_tcp_policy_denied`. | Audit log, `egress-default-deny` |
| Policy DNS | A name that is not eligible is refused with `policy_dns_ineligible`. | Audit log, `dns-policy-refuse` |
| Default-deny network (cloud metadata address) | No network rule allows `169.254.169.254`, so a request to it is refused. The audit log shows `transparent_tcp_policy_denied`. | Audit log, `metadata-address-refused` |
| `github_readonly` | `api.github.com:443` REST, `access: read-only`, `enforcement: enforce`, binary `/usr/bin/curl` only. DELETE and POST are L7 denials (`policy:github_readonly engine:l7`). | Audit log, `l7-delete-denied`, `l7-post-denied` |
| `public_echo` | `httpbin.org:443` REST read-only for `/usr/bin/curl` only. | Same binary allowlist as GitHub |
| Binary allowlist | `/usr/bin/python3.12` opening `api.github.com:443` is denied. The policy names `/usr/bin/curl`. | Audit log, `binary-identity-denied` |
| Provider credential | The demo provider `demo-github` holds `GITHUB_TOKEN=FAKE_NOT_A_REAL_TOKEN`. OpenShell injects that placeholder only for an endpoint the GitHub profile authorizes. Use at any other endpoint is a finding: `Provider credential used at an unauthorized endpoint`, and the HTTP denial reason `credential_endpoint_mismatch`. | Audit log, `cred-unauthorized-endpoint`, `cred-endpoint-mismatch` |
| `filesystem_policy` + `landlock.compatibility: hard_requirement` | `/opt/company/prod.env` is mode `0644` in the image, so Unix permissions would allow the read. Landlock is what denies it. OpenShell's filesystem events are emitted by the sandbox runtime and are **not** pushed to the gateway log stream (`openshell logs --source sandbox`). | `kind=exit-code`. `scenarios/run_all.sh` prints `PROBE fs-secret-denied BLOCKED` only when the read fails with a permission error. `verify.sh` accepts that line. If a future build records the denial in the log, put that extended regex in the pattern column. |
| `process.run_as_user` / `run_as_group` `1000` | The workload is not root. A failed attempt to gain privilege is enforced by the kernel and is not one of the gateway denial lines this demo matches. | `kind=exit-code`. The probe script must print `PROBE priv-nonroot-denied BLOCKED`. |

`openshell rule get <name> --status pending` lists agent-proposed rule changes waiting for a person. This policy file does not auto-approve anything. The demo never approves a pending rule.

`scenarios/run_all.sh` makes one attempt per row above inside the sandbox, so a live run generates these lines. `make verify` grades them.

`agent-policy-kyverno.yaml` is the same sandbox policy plus `network_middlewares.kyverno_guard` on `api.github.com`. `make kyverno` registers the middleware and uses that file. `make verify` does not.
