# OpenShell agent guardrails

An agent that has already been admitted keeps acting. Those later actions never pass back through a Kubernetes admission webhook. This repo is a single-machine demonstration that NVIDIA OpenShell **v0.1.3** can still deny them: default-deny egress, policy DNS, the cloud-metadata address, GitHub writes, the wrong binary, a planted world-readable secret, and a non-root process. `scenarios/run_all.sh` makes one small, labelled attempt per control inside the sandbox, using only fake data and placeholder destinations. `verify.sh` then reads OpenShell's own audit log and prints a PASS/FAIL matrix, so every result comes from the sandbox, not from the script.

Before any sandbox exists, the policy itself is checked. `openshell-prover` (shipped with OpenShell 0.1.3) must **prove** the policy is contained in an operator-owned boundary, and the policy must be byte-for-byte the text a reviewer signed. Those are the two Developer-plane rows, so `make verify` grades **12 rows**.

The audience is the governance question AIControls asks across three planes (Developer, Agent, MCP) and four domains (access, cost, security, compliance). OpenShell is the kernel-enforced box. AIControls is the fleet. This demo does not pretend they are the same product.

A walkthrough deck with an interactive architecture map is in [`deck/slideshow.html`](deck/slideshow.html).

## Prerequisites

- Docker **28** or newer, daemon running.
- OpenShell **v0.1.3**, exactly (it includes `openshell-prover`):

  ```sh
  curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | OPENSHELL_VERSION=v0.1.3 sh
  ```

  On macOS the installer uses a Homebrew service. The local gateway is `https://localhost:17670`. `openshell status` should report Connected.
- **Docker Desktop on macOS: enable host networking.** Path: **Settings > Resources > Network > Enable host networking**. If that toggle is off, `openshell sandbox create` fails with `Startup configuration fetch failed`. `make preflight` reads `~/Library/Group Containers/group.com.docker/settings-store.json` key `HostNetworkingEnabled` and prints that path. It never changes the setting.
- `ssh-keygen` (OpenSSH), for review signatures. Verifying needs only the public key already in `policies/allowed_signers`.
- No real tokens. Setup registers provider `demo-github` with `GITHUB_TOKEN=FAKE_NOT_A_REAL_TOKEN`.

## Quickstart

```sh
make setup           # image openshell-guardrails-agent:dev, GitHub profile, fake provider
make verify          # preflight, policy gate, sandbox, probes, 12-row PASS/FAIL matrix
make demo            # same, plus the agent's attempts and the raw audit-log denials
make policy-tamper   # eight edited policies, eight refusals, with the prover's counterexamples
make approval-demo   # OpenShell proposes rules from denials; proposals outside the boundary are rejected by proof
make evidence        # verify, then a signed, hash-chained evidence bundle in .out/evidence/
make clean           # openshell sandbox delete guardrails-demo
```

`make help` lists every target. The Kyverno bonus (`make kyverno`, `make kyverno-stop`) is below.

`make verify` runs `scenarios/run_all.sh` inside the sandbox; it prints a `== <id>: <control> ==` label before each attempt. For the two kernel-only rows (`fs-secret-denied`, `priv-nonroot-denied`) it prints `PROBE <id> BLOCKED` only when it actually observed the permission error, and `PROBE <id> NOT-BLOCKED` otherwise. OpenShell does not send Landlock denials to `openshell logs --source sandbox`. See `policies/openshell/README.md`.

Grade a log you already have, without creating a sandbox (the policy gate still runs):

```sh
./verify.sh --sandbox guardrails-demo
VERIFY_LOG_FILE=tests/fixtures/observed-live.log ./verify.sh --sandbox demo
```

Exit 0 means every row in `expected_events.tsv` matched. Any FAIL row exits 1. A missing probe script exits 2. If the policy gate refuses the policy, no sandbox is created and the run fails.

## What each control is for

These are classes of incident, not write-ups of a particular breach. The plane is where AIControls would consume the evidence. The domain is the AIControls domain the control belongs to. Cost (quotas, model spend) is a real AIControls domain and is not exercised here.

| ID | Incident class | Plane | Domain | What denied it |
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
| `policy-within-boundary` | Policy widened past what the operator allows | Developer | compliance | `openshell-prover` proves containment in `policies/boundary/org-boundary.yaml` |
| `policy-signature-valid` | Unreviewed policy change | Developer | compliance | `ssh-keygen -Y verify` against `policies/allowed_signers` |

## Developer plane: proven, then signed

`scripts/policy-gate.sh` runs before every sandbox and prints greppable `POLICY-GATE` lines:

1. The operator boundary must carry the operator's signature (namespace `openshell-boundary`). If the boundary could be widened unnoticed, the proof below would mean nothing.
2. `openshell-prover check --boundary policies/boundary/org-boundary.yaml <policy>` must return `within_boundary`. Anything else, including `unsupported`, is a refusal.
3. The policy must match its `.sig` from the reviewer key in `policies/allowed_signers` (namespace `openshell-policy`).

`make policy-tamper` edits copies under `.out/tamper/`, keeps the old signature, and runs the gate on each:

```
CASE            PROVER             SIGNATURE  WHY
new-host        exceeds_boundary   invalid    counterexample: GET example.com:443/
read-write      exceeds_boundary   invalid    counterexample: PUT httpbin.org:443/
root            exceeds_boundary   invalid    counterexample: run_as_user 1000 -> 0
landlock-soft   exceeds_boundary   invalid    counterexample: compatibility hard_requirement -> best_effort
other-binary    exceeds_boundary   invalid    counterexample: GET api.github.com:443/ via /usr/bin/python3.12
write-path      unsupported        invalid    unresolved_filesystem_path: filesystem write containment for '/opt' ...
in-boundary     within_boundary    invalid    prover passes; bytes differ from the reviewed policy
both-widened    not run            -          boundary untrusted
8/8 edited policies refused
```

The prover answers the operator's question (could this policy ever allow more than the ceiling?). The signature answers the reviewer's (is this the text someone actually read?). `in-boundary` shows why both are needed. The solver picks the counterexample, so the method it shows can differ between runs.

What the prover cannot do in 0.1.3, and how the gate treats it:

- It cannot reason about an unresolved image workdir, so both policies set `include_workdir: false`.
- A new write path outside the boundary's list comes back `unsupported`. The gate refuses it (fail closed).
- It reports network middleware as an unsupported shape. The gate proves the Kyverno policy with its `network_middlewares` block removed: middleware runs only on traffic the network policy already admitted, so it can add denials but never allow more.

`make policy-sign` re-signs after a reviewed edit and refuses to sign anything outside the boundary. To take over review, put your own public key in `policies/allowed_signers` and set `POLICY_REVIEW_KEY`. In a real deployment the operator and the reviewer hold different keys. This demo uses one.

## Approval stays inside the boundary

OpenShell 0.1.3 turns denied requests into pending rule proposals (`openshell rule get <sandbox> --status pending`). Its own check reported "no new findings" for a proposal letting curl reach `example.com`. `scripts/approval-gate.sh` composes each proposal onto the sandbox policy and proves the result against the signed boundary:

- Outside the boundary, or unprovable: rejected with `openshell rule reject`. The counterexample is the reason.
- Inside the boundary: a person decides at a terminal (y/N). Without a terminal it stays pending. Nothing is approved automatically.

`make approval-demo` runs it in its own sandbox, `guardrails-approval`. The agent tries `example.com` and `raw.githubusercontent.com`. OpenShell proposes raw L4 access to each, and both are rejected by proof. For the second, the gate points out that the boundary does allow a narrower rule (read-only REST, curl). That change belongs in `agent-policy.yaml`, where `make policy-sign` proves it again.

## Evidence

`make evidence` runs `make verify` and writes `.out/evidence/evidence-<UTC>.json`. The bundle holds:

- OpenShell, prover and Docker versions, plus the image ID
- SHA-256 of the policy, its signature, the boundary, `expected_events.tsv`, the probe script and the grader
- the policy-gate output and the prover's JSON
- every graded row with the exact log line that proved it

The rows are hash-chained in grading order, and the bundle is signed with the review key (namespace `openshell-evidence`). `make evidence-verify` checks the signature and the chain, and reports any repo file that changed since the run. Changing one row's result breaks both the signature and the chain at that row.

## Kyverno bonus: Kyverno decides, OpenShell enforces

`make kyverno` wires a bonus that `make verify` does not grade, and grades it with the same `verify.sh` against `bonus/expected_bonus.tsv` (10 rows). OpenShell admits a request first. Then, before provider credentials are injected, supervisor middleware `kyverno-guard` (`bonus/kyverno-guard/main.go`) forwards the raw request to `kyverno-authz` v0.4.0. That server evaluates CEL `ValidatingPolicy` rules and answers allow or deny, and OpenShell enforces the answer and logs it.

- **GitHub path rule** (`github-read-path.yaml`): only `GET`/`HEAD` of `/repos/example-org/example-repo` on `api.github.com`; anything else is `kyverno_path_denied`.
- **MCP tool-call firewall** (`mcp-tool-guard.yaml`): a fake MCP server (`bonus/mcp-demo/server.py`, canned results, `127.0.0.1` only) is reached from the sandbox as `host.openshell.internal`. OpenShell's L7 rules admit only `POST /mcp` on that host. Kyverno parses the JSON-RPC body and decides per tool and per argument:
  - a tool outside the allowlist → `mcp_tool_denied`. The server advertises `delete_repo` in `tools/list`; it still can't be called.
  - a flag-shaped argument to an allowed tool → `mcp_arg_flag_injection`
  - a path argument with `..` or a leading `/` → `mcp_arg_path_traversal`
  - a body Kyverno cannot parse → the evaluation fails and OpenShell denies it (`on_error: fail_closed`, logged `failed:true … middleware_failed`)

  The server's own log shows that only `tools/list` and the allowed `search_issues` call arrived.

OpenShell's audit log records each decision, for example `HTTP:POST [MED] DENIED POST http://host.openshell.internal:8766/mcp [policy:mcp_demo engine:middleware] [… reason:middleware_denied:kyverno_guard:mcp_tool_denied]`. A captured run is in `tests/fixtures/observed-kyverno-bonus.log`.

Two kyverno-authz v0.4.0 behaviours shaped this, both found by testing:

- A policy that returns `http.Allowed()` decides the request. With two policies loaded, the GitHub rule's allow was overriding the MCP rule's deny. Each policy is now scoped with `matchConditions` to its own traffic.
- A policy that fails to compile loads as nothing and allows everything, with no error. That includes `apiVersion: policies.kyverno.io/v1` (the current docs) instead of `v1alpha1`, and CEL that calls `mcp.Parse`, which v0.4.0 does not have. Before touching the gateway, `make kyverno` proves both rules deny.

Bonus prerequisites: macOS with the Homebrew OpenShell install (the scripts edit `/opt/homebrew/var/openshell/gateway.toml` and use `brew services`), Go 1.24 or newer to build `kyverno-guard`, Python 3 for the fake MCP server, and the core prerequisites above. The scripts back up the gateway config, and `make kyverno-stop` restores it byte for byte, stops all three processes and deletes the bonus sandbox. Until then, an OpenShell restart needs `kyverno-guard` listening on `127.0.0.1:50061`, because the gateway refuses to start when a registered middleware is down.

## What this is not

- **Single-box enforcement.** One gateway, one Docker host, one sandbox. A denial here is not a fleet policy.
- **OpenShell is alpha.** This demo pins **v0.1.3**. Log lines and CLI flags match that release's documented shorthand (`NET:`, `HTTP:`, `FINDING:`). Do not treat the project as a finished control plane. In 0.1.3, `openshell logs` keeps only about the last 50 lines per sandbox, which limits how many probes one run can grade.
- **Request-side only.** The middleware sees requests, not responses. Prompt injection carried in a tool's response or tool description is not inspected here; the sandbox limits what an injected agent can then do.
- **Not the cost domain, not retention.** No spend limits or rate limits. The evidence bundle is tamper-evident but stays on this machine.
- **AIControls governs fleets.** Developer, Agent, and MCP governance, across access, cost, security, and compliance, are a product surface for many clusters and agents. This repository only shows the runtime denials and policy checks a fleet product would want as evidence. It does not ship AIControls, and it does not claim a Nirmata product ingests these logs today.

`docs/ARCHITECTURE.md` maps the pieces, what is enforced where, and how the controls line up with the five control categories in Errico, Ngiam and Sojan, *Securing the Model Context Protocol (MCP): Risks, Controls, and Governance* (arXiv:2511.20920).

## How this extends with Nirmata Runtime

Nirmata Runtime is the fleet form of the same intent: default-deny egress, no link-local metadata address, read-only tool APIs, no secret file, non-root. This repository does not wire that product. The PASS/FAIL matrix and the evidence bundle are the local proof those controls should keep producing, and the boundary proof is the check a fleet would run before any policy, or any approved widening, reaches a node.
