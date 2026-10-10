# OpenShell agent guardrails

An agent that has already been admitted keeps acting. Those later actions never pass back through a Kubernetes admission webhook. This repo is a single-machine demonstration that NVIDIA OpenShell **v0.1.3** can still deny them: default-deny egress, policy DNS, the cloud-metadata address, GitHub writes, the wrong binary, a planted world-readable secret, and a non-root process. `scenarios/run_all.sh` makes one small, labelled attempt per control inside the sandbox, using only fake data and placeholder destinations. `verify.sh` then reads OpenShell's own audit log and prints a PASS/FAIL matrix, so every result comes from the sandbox, not from the script.

The audience is the governance question AIControls asks across three planes (Developer, Agent, MCP) and four domains (access, cost, security, compliance). OpenShell is the kernel-enforced box. AIControls is the fleet. This demo does not pretend they are the same product.

## Prerequisites

- Docker **28** or newer, daemon running.
- OpenShell **v0.1.3**, exactly:

  ```sh
  curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | OPENSHELL_VERSION=v0.1.3 sh
  ```

  On macOS the installer uses a Homebrew service. The local gateway is `https://localhost:17670`. `openshell status` should report Connected.
- **Docker Desktop on macOS: enable host networking.** Path: **Settings > Resources > Network > Enable host networking**. If that toggle is off, `openshell sandbox create` fails with `Startup configuration fetch failed`. `make preflight` reads `~/Library/Group Containers/group.com.docker/settings-store.json` key `HostNetworkingEnabled` and prints that path. It never changes the setting.
- No real tokens. Setup registers provider `demo-github` with `GITHUB_TOKEN=FAKE_NOT_A_REAL_TOKEN`.

## Quickstart

```sh
make setup    # image openshell-guardrails-agent:dev, GitHub profile, fake provider
make verify   # preflight, sandbox, probes, PASS/FAIL matrix
make demo     # same as verify
make clean    # openshell sandbox delete guardrails-demo
```

`make help` lists `setup`, `preflight`, `verify`, `demo`, and `clean`.

`make verify` runs `scenarios/run_all.sh` inside the sandbox; it prints a `== <id>: <control> ==` label before each attempt. For the two kernel-only rows (`fs-secret-denied`, `priv-nonroot-denied`) it prints `PROBE <id> BLOCKED` only when it actually observed the permission error, and `PROBE <id> NOT-BLOCKED` otherwise. OpenShell does not send Landlock denials to `openshell logs --source sandbox`. See `policies/openshell/README.md`.

Grade a log you already have, without creating a sandbox:

```sh
./verify.sh --sandbox guardrails-demo
VERIFY_LOG_FILE=tests/fixtures/observed-live.log ./verify.sh --sandbox demo
```

Exit 0 means every row in `expected_events.tsv` matched. Any FAIL row exits 1. A missing probe script exits 2.

## What each control is for

These are classes of incident, not write-ups of a particular breach. The plane is where AIControls would consume the evidence. The domain is the AIControls domain the control belongs to. Cost (quotas, model spend) is a real AIControls domain and is not exercised by this single sandbox.

| ID | Incident class | Plane | Domain | What OpenShell denied |
| --- | --- | --- | --- | --- |
| `cred-unauthorized-endpoint` | Credential leakage from a compromised model or agent | MCP | security | Finding: provider credential used at an unauthorized endpoint |
| `cred-endpoint-mismatch` | Credential leakage from a compromised model or agent | MCP | security | HTTP denial `credential_endpoint_mismatch` |
| `egress-default-deny` | Data exfiltration | Agent | access | `example.com:443` denied, `transparent_tcp_policy_denied` |
| `dns-policy-refuse` | Data exfiltration | Agent | access | `policy_dns_ineligible` |
| `metadata-address-refused` | Cloud-metadata credential theft | Agent | security | `169.254.169.254:80` refused, `transparent_tcp_policy_denied` |
| `l7-delete-denied` | Destructive API writes | MCP | access | `HTTP:DELETE` on `api.github.com`, `engine:l7` |
| `l7-post-denied` | Destructive API writes | MCP | access | `HTTP:POST` on `api.github.com`, `engine:l7` |
| `binary-identity-denied` | Data exfiltration | Agent | access | `/usr/bin/python3.12` to `api.github.com:443` (curl is the allowed binary) |
| `fs-secret-denied` | Secrets sprawl | Agent | security | Landlock denies `/opt/company/prod.env` even though it is mode `0644` |
| `priv-nonroot-denied` | Privilege escalation | Agent | security | Workload stays uid/gid 1000 |

The Developer plane is the review of `policies/openshell/agent-policy.yaml` before a sandbox is created. None of the ten rows are that review; they are runtime evidence for the Agent and MCP planes. `docs/ARCHITECTURE.md` is the picture. `docs/LOOM_SCRIPT.md` is the 7-minute narration.

## What this is not

- **Single-box enforcement.** One gateway, one Docker host, one sandbox. A denial here is not a fleet policy.
- **OpenShell is alpha.** This demo pins **v0.1.3**. Log lines and CLI flags match that release's documented shorthand (`NET:`, `HTTP:`, `FINDING:`). Do not treat the project as a finished control plane.
- **AIControls governs fleets.** Developer, Agent, and MCP governance, across access, cost, security, and compliance, are a product surface for many clusters and agents. This repository only shows the runtime denials a fleet product would want as evidence. It does not ship AIControls, and it does not claim a Nirmata product ingests these logs today.

## How this extends with Kyverno CEL and Nirmata Runtime

Two follow-on steps, stated as a roadmap:

1. **Kyverno CEL (Developer plane).** Admit the sandbox policy as a reviewed artifact. A CEL policy can reject a change that drops `landlock.compatibility: hard_requirement`, switches the process user to root, or opens a network rule that is not read-only. That happens before an agent is scheduled. It does not see the agent's later `curl`. Kyverno validating the YAML is not the same as OpenShell denying a packet.
2. **Nirmata Runtime (Agent and MCP planes, many nodes).** Take the same intent — default-deny egress, no link-local metadata address, read-only tool APIs, no secret file, non-root — and enforce it where the fleet runs, not only inside one OpenShell sandbox on a laptop. The PASS/FAIL matrix in this repo is the local evidence those controls should keep producing.

Cost and compliance at fleet scale (spend limits, retention of the audit trail, who approved a policy change) are out of scope for the shell scripts here. `openshell rule get <sandbox> --status pending` is how a person would see an agent asking for more access. This demo does not approve those requests.
