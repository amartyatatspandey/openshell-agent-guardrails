# Architecture

OpenShell **v0.1.3** runs the agent in a sandbox. The gateway on this laptop is `https://localhost:17670` (Homebrew service on macOS). The sandbox is created from image `openshell-guardrails-agent:dev` with `policies/openshell/agent-policy.yaml` and provider `demo-github`.

On Docker Desktop for Mac, **Settings > Resources > Network > Enable host networking** must be on. `scripts/preflight.sh` reads `HostNetworkingEnabled` from `~/Library/Group Containers/group.com.docker/settings-store.json`. If it is off, sandbox creation fails with `Startup configuration fetch failed`. Preflight prints that path and does not edit the file. Docker must be 28 or newer.

## Pieces

```
operator laptop
  make preflight  -> docker, host networking, openshell v0.1.3, status Connected
  make setup      -> docker build, profile import, fake provider
  make verify     -> sandbox create --policy --provider --no-tty
                     scenarios/run_all.sh inside the sandbox
                     sleep 2
                     openshell logs <name> --since 10m --source sandbox
                     expected_events.tsv
```

The image (`image/Dockerfile`) is Ubuntu 24.04 plus `curl`, `python3`, and `dnsutils`, and a world-readable file `/opt/company/prod.env` whose contents are fake. Unix permissions would allow every user to read it. A denial of that read is Landlock, not mode bits.

The provider credential is the literal `GITHUB_TOKEN=FAKE_NOT_A_REAL_TOKEN`. OpenShell's model is that the agent does not receive the real secret to spend anywhere: the gateway adds a provider credential only on a request whose host, port, and path match the provider profile. A sandbox network allow does not widen that binding.

## What is enforced where

| Control | Enforcer | Visible in `openshell logs --source sandbox` |
| --- | --- | --- |
| Egress, DNS, metadata address, L7 method, binary identity, credential binding | OpenShell supervisor / policy engine, recorded as OCSF shorthand | Yes. `verify.sh` matches the extended regex in `expected_events.tsv`. |
| Filesystem (`landlock.compatibility: hard_requirement`) | Kernel Landlock | No. OpenShell documents filesystem sandbox logs as runtime events that are not pushed to the gateway log stream. Row `fs-secret-denied` is `kind=exit-code`. |
| Non-root (`run_as_user: "1000"`) | Process credentials at start | No matching denial line in the shapes this demo grades. Row `priv-nonroot-denied` is `kind=exit-code`. |

For an `exit-code` row, `scenarios/run_all.sh` prints, only when it observed the denial:

```
PROBE fs-secret-denied BLOCKED
PROBE priv-nonroot-denied BLOCKED
```

`verify.sh` treats that line as a pass. It also accepts the row's regex if a supervisor line is present. If the action unexpectedly succeeds it prints `PROBE <id> NOT-BLOCKED` instead, and the row fails. Every attempt uses fake data and placeholder destinations.

`./verify.sh --sandbox NAME` only reads the log (or `VERIFY_LOG_FILE` when that variable is set). It does not create a sandbox and does not run probes. ANSI color codes are stripped before matching.

## Planes

Agents act after admission, so an admission webhook never sees the `curl`, the DELETE, or the read of `prod.env`.

- **Developer.** Someone reviews `agent-policy.yaml` before `sandbox create`. That is the only Developer-plane artifact in the repo. The matrix does not grade the review itself.
- **Agent.** Default-deny egress, policy DNS, metadata address, binary identity, secret file, non-root. Access and security.
- **MCP.** The GitHub provider and the read-only L7 rule: credential binding, DELETE, POST. Access and security.

Cost (spend, quotas) is an AIControls domain and is not measured here. Compliance evidence in this demo is the local audit log plus the matrix, not a retention system.

Pending policy edits an agent asks for stay pending until a person acts. The CLI for that list is `openshell rule get <name> --status pending`. This demo does not approve rules.

## What a fleet product would add

Kyverno CEL can reject a bad copy of this YAML in git or in a cluster, which is Developer-plane admission of the policy. It still does not see the agent's next request. Nirmata Runtime is the place the same intent (default-deny, no metadata address, read-only tool calls, no secret file, non-root) would be enforced across nodes. This repo does not wire either product to OpenShell. OpenShell v0.1.3 remains a single-box alpha runtime.
