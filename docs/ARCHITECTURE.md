# Architecture

OpenShell **v0.1.3** runs the agent in a sandbox. The gateway on this laptop is `https://localhost:17670` (Homebrew service on macOS). The sandbox is created from image `openshell-guardrails-agent:dev` with `policies/openshell/agent-policy.yaml` and provider `demo-github`, and only after that policy passes the policy gate.

On Docker Desktop for Mac, **Settings > Resources > Network > Enable host networking** must be on. `scripts/preflight.sh` reads `HostNetworkingEnabled` from `~/Library/Group Containers/group.com.docker/settings-store.json`. If it is off, sandbox creation fails with `Startup configuration fetch failed`. Preflight prints that path and does not edit the file. Docker must be 28 or newer.

## Pieces

```
operator laptop
  make preflight  -> docker, host networking, openshell v0.1.3, status Connected,
                     openshell-prover, ssh-keygen
  make setup      -> docker build, profile import, fake provider
  make verify     -> scripts/policy-gate.sh <policy>
                       boundary signature (openshell-boundary)
                       openshell-prover check --boundary org-boundary.yaml -> within_boundary
                       policy signature (openshell-policy)
                     sandbox create --policy --provider --no-tty   (only if the gate accepts)
                     scenarios/run_all.sh inside the sandbox
                     sleep 2
                     openshell logs <name> --since 10m --source sandbox
                     expected_events.tsv (12 rows) -> .out/last-run/
  make evidence   -> verify, then .out/evidence/evidence-<UTC>.json (+ .sig)
  make approval-demo -> denials -> OpenShell proposals -> scripts/approval-gate.sh
  make kyverno    -> kyverno-authz + kyverno-guard + fake MCP server, gateway middleware,
                     bonus probes, bonus/expected_bonus.tsv (10 rows)
```

The image (`image/Dockerfile`) is Ubuntu 24.04 plus `curl`, `python3`, and `dnsutils`, and a world-readable file `/opt/company/prod.env` whose contents are fake. Unix permissions would allow every user to read it. A denial of that read is Landlock, not mode bits.

The provider credential is the literal `GITHUB_TOKEN=FAKE_NOT_A_REAL_TOKEN`. OpenShell's model is that the agent does not receive the real secret to spend anywhere: the gateway adds a provider credential only on a request whose host, port, and path match the provider profile. A sandbox network allow does not widen that binding.

## What is enforced where

| Control | Enforcer | Evidence the grader reads |
| --- | --- | --- |
| Policy within the operator boundary | `openshell-prover` (solver), before the sandbox exists | `POLICY-GATE boundary within_boundary` |
| Policy is the reviewed text | `ssh-keygen -Y verify` against `policies/allowed_signers` | `POLICY-GATE signature valid` |
| Egress, DNS, metadata address, L7 method, binary identity, credential binding | OpenShell supervisor / policy engine, recorded as OCSF shorthand | `openshell logs --source sandbox`; extended regex in `expected_events.tsv` |
| Filesystem (`landlock.compatibility: hard_requirement`) | Kernel Landlock | Not in the gateway log stream. Row `fs-secret-denied` is `kind=exit-code`. |
| Non-root (`run_as_user: "1000"`) | Process credentials at start | No matching denial line. Row `priv-nonroot-denied` is `kind=exit-code`. |
| Approving a proposed rule | `scripts/approval-gate.sh`: prover against the boundary, then a person | `openshell rule get <sandbox>` status, `.out/approval/decisions.txt` |
| MCP tool and argument rules (bonus) | `kyverno-authz` CEL, enforced by OpenShell middleware | `engine:middleware … middleware_denied:kyverno_guard:<reason>` |

For an `exit-code` row, `scenarios/run_all.sh` prints `PROBE <id> BLOCKED` only when it observed the denial. If the action unexpectedly succeeds it prints `PROBE <id> NOT-BLOCKED`, and the row fails. Every attempt uses fake data and placeholder destinations.

`./verify.sh --sandbox NAME` only reads the log (or `VERIFY_LOG_FILE` when that variable is set). It does not create a sandbox and does not run probes; the policy gate still runs. `EVENTS` and `POLICY` select another expectations table and policy, which is how the Kyverno bonus reuses the grader. ANSI color codes are stripped before matching.

## Policy gate

The boundary (`policies/boundary/org-boundary.yaml`) is the operator's ceiling for every agent policy in the repo: Landlock as a hard requirement, uid/gid 1000, read-only REST only, curl as the only network binary, three named hosts, and `POST /mcp` on the local MCP server. It is wider than `agent-policy.yaml`, so a policy can grow inside it without the operator, but not past it.

`openshell-prover` covers the domains `filesystem, network_l4, network_rest, process, landlock`. On a widening it returns `exceeds_boundary` (exit 1) with a counterexample: a concrete request or setting the candidate allows and the boundary does not. On a shape it cannot reason about it returns `unsupported` (exit 3) with a reason code, for example:

- `unresolved_workdir`, if `include_workdir` is true
- `unresolved_filesystem_path`, for a new write path
- `unsupported_policy_shape`, for network middleware

The gate treats `unsupported` as a refusal. It removes the `network_middlewares` block before proving the Kyverno policy, because middleware only runs on traffic the network policy already admitted.

There are two signatures with two namespaces, so neither can stand in for the other: `openshell-boundary` (operator, on the boundary) and `openshell-policy` (reviewer, on each policy). `make policy-sign` will not sign a policy the prover cannot place inside the boundary. `make policy-tamper` shows eight edits refused, including one inside the boundary (only the signature catches it) and one where the boundary and policy are widened together (only the boundary signature catches it).

## Approval gate

OpenShell 0.1.3 analyses denials and proposes rules, for example `allow_example_com_443`, with `Endpoints: example.com:443 [L4]`, `Binaries: /usr/bin/curl`, and its own check line, "prover: no new findings". The approval gate reads each pending chunk, appends exactly what the proposal would allow to the current policy under `.out/approval/`, and proves that against the signed boundary:

- Outside the boundary: `openshell rule reject --chunk-id … --reason "outside operator boundary: exceeds_boundary raw l4 to example.com:443"`.
- Inside the boundary: a person answers y/N at a terminal. Without one, the proposal stays pending.

A proposal is raw L4 access, while the boundary grants read-only REST. So even for a host the boundary names, the proposal is wider than the operator allows, and the gate says so and points at the narrower rule the boundary would accept.

## Evidence bundle

`verify.sh` writes `.out/last-run/`: the graded corpus, the gate output, run metadata, and `matrix.tsv` (row, result, the exact matching line). `scripts/evidence.sh` turns that into JSON. Rows are chained as `h_i = sha256(h_{i-1} \t id \t result \t evidence)`, starting from `sha256("openshell-guardrails-evidence-v1")`. The bundle is signed in namespace `openshell-evidence`. `scripts/evidence-verify.sh` recomputes the chain, checks the signature, and compares the recorded file hashes with the repo.

## MCP firewall (bonus)

```
agent (curl, uid 1000)
  -> OpenShell proxy: host.openshell.internal:8766, L7 rule allows only POST /mcp   (else engine:l7 deny)
  -> middleware kyverno-guard (PRE_CREDENTIALS, on_error: fail_closed), gRPC :50061
       rebuilds the request as raw HTTP/1.1
  -> kyverno-authz v0.4.0, HTTP :9081, --nested-request
       mcp-tool-guard.yaml: json.Unmarshal(string(object.attributes.body))
         tools/call name not in [search_issues, read_file]  -> mcp_tool_denied
         any string argument starting with "-"               -> mcp_arg_flag_injection
         "path" argument containing ".." or starting "/"     -> mcp_arg_path_traversal
         body not JSON                                       -> evaluation error -> fail closed
  -> 200: forwarded to the fake MCP server on 127.0.0.1:8766
     403: OpenShell denies and logs Kyverno's reason; the server never sees it
```

`host.openshell.internal` is OpenShell's name for the host. Policy DNS maps it to `127.0.0.1` through a synthetic address, so the fake server never listens beyond loopback.

## Planes

Agents act after admission, so an admission webhook never sees the `curl`, the DELETE, or the read of `prod.env`.

- **Developer.** The policy gate: a containment proof against the operator boundary and a reviewer signature, both before `sandbox create`. Graded as two rows. The approval gate extends the same proof to widenings the agent itself asks for.
- **Agent.** Default-deny egress, policy DNS, metadata address, binary identity, secret file, non-root. Access and security.
- **MCP.** The GitHub provider and the read-only L7 rule: credential binding, DELETE, POST. In the bonus, per-tool and per-argument decisions on MCP calls. Access and security.

Cost (spend, quotas) is an AIControls domain and is not measured here. Compliance evidence here is the signed bundle; it is not a retention system.

## Coverage against the MCP control categories in arXiv:2511.20920

Errico, Ngiam and Sojan (*Securing the Model Context Protocol (MCP): Risks, Controls, and Governance*, Nov 2025) group MCP controls into five categories behind one gateway, and name fail-open versus fail-closed as a key decision. This repo's position against each:

| Category | Here | Not here |
| --- | --- | --- |
| AuthN / AuthZ | Credential bound to host/port/path; the agent holds only a placeholder (`credential_endpoint_mismatch`). Per-tool allowlist on MCP calls. | Per-user OAuth 2.1, RBAC per user. One fake provider. |
| Provenance | OCSF audit log from OpenShell; evidence bundle with the exact line per control, hash-chained and signed. | Shipping to a SIEM, retention tiers, redaction. |
| Sandboxing | Landlock (hard requirement), non-root, default-deny egress, binary identity, no host credentials in the sandbox. | Resource quotas. The MCP server itself runs on the host (it is fake). |
| Inline policy enforcement | Kyverno CEL per tool and per argument, before credentials, fail-closed; OpenShell L7 method/path rules. | DLP or secret scanning of payloads, response inspection, rate limits. |
| Centralized governance | Operator boundary with a containment proof; reviewer signatures; proposals rejected by proof; a tool advertised later (`delete_repo`) is still not callable. | Private registry, SBOMs, signed server builds. |

## What a fleet product would add

`make kyverno` attaches `kyverno-guard` to `api.github.com` and the local MCP endpoint through a separate policy, `policies/openshell/agent-policy-kyverno.yaml`. That is a second decision on traffic OpenShell already allowed, and the policy gate proves that policy too. Nirmata Runtime is still the place the same intent would be enforced across nodes. This repo does not wire Nirmata Runtime. OpenShell v0.1.3 remains a single-box alpha runtime.
