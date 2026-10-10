# Loom narration — OpenShell agent guardrails

**Total runtime: 7:00.** Segments: 0:45 + 0:40 + 0:45 + 0:50 + 2:30 + 0:50 + 0:40.

**Recording note.** The clone ships `scenarios/run_all.sh` as a stub that exits 2. Record `make verify` only after the operator-supplied probe script is in that path, so the matrix can pass. The stub must not be replaced by probes inside this defensive repo. Do not show a real token. The provider value on screen is `FAKE_NOT_A_REAL_TOKEN`. OpenShell is pinned to **v0.1.3**.

## 0:00–0:45 — Agents act after admission

**On screen:** Title card, then a one-line diagram: admission webhook at create time, agent process afterward, no arrow back to the webhook.

**Say:** An admission webhook sees an object when it is created. An agent does its real work after that, in a loop: it reads files, it calls APIs, it follows whatever the model just decided. Those calls never return to the webhook. If the only control you have is admission, you are done before the agent starts. This recording is the next second: a sandbox that can still say no, and a log we can grade.

## 0:45–1:25 — The box we are about to run

**On screen:** `policies/openshell/agent-policy.yaml` and `image/Dockerfile`. Highlight `landlock.compatibility: hard_requirement`, `run_as_user: "1000"`, the GitHub read-only rule, and `/opt/company/prod.env` mode `0644`.

**Say:** The image plants a secret file that any Unix user could read. The policy is default-deny on the network, Landlock as a hard requirement, and a non-root user. GitHub and a public echo host are read-only, and only for curl. The token we attach is a placeholder, `FAKE_NOT_A_REAL_TOKEN`. OpenShell is supposed to add a provider credential only when the host, port, and path match the provider profile. A network allow does not widen that.

## 1:25–2:10 — Prerequisites, including the host-networking trap

**On screen:** `make preflight`. Then, if you have it, Docker Desktop at **Settings > Resources > Network**, with **Enable host networking** on.

**Say:** We pin OpenShell v0.1.3. The installer is the upstream script with `OPENSHELL_VERSION=v0.1.3`. On a Mac the gateway is a Homebrew service at `https://localhost:17670`, and `openshell status` must say Connected. Docker has to be 28 or newer. One macOS-only footgun: Docker Desktop host networking. The setting is Settings, Resources, Network, Enable host networking. Preflight reads `HostNetworkingEnabled` in the Docker Desktop settings store and tells you that path. It does not flip the switch. If the toggle is off, sandbox create dies with `Startup configuration fetch failed`, before any policy runs.

## 2:10–3:00 — `make verify`

**On screen:** Run `make verify`. Leave the PASS/FAIL matrix up. Do not scroll past it yet.

**Say:** `make setup` builds `openshell-guardrails-agent:dev`, imports the GitHub provider profile, and creates provider `demo-github` with the fake token. `make verify` creates the sandbox with that image, this policy, and that provider, runs the probe script inside it, waits two seconds, and reads `openshell logs` for the sandbox source. The script in the sandbox is the only thing that attempts the bad actions. `verify.sh` does not. It strips ANSI codes and compares the log to `expected_events.tsv`. Exit 0 means every row passed. The two kernel rows are different: Landlock filesystem events are not pushed to the gateway log, and the non-root constraint does not show up as one of these denial lines. For those, the probe script prints `PROBE <id> BLOCKED`, and the grader accepts that line.

## 3:00–5:30 — Walk the matrix

**On screen:** The matrix. Pause on each id as it is named. About fifteen seconds each.

**Say:**

- `cred-unauthorized-endpoint`. The log finding is "Provider credential used at an unauthorized endpoint." The placeholder token was presented somewhere the GitHub profile does not authorize. That is credential leakage from a compromised agent, on the MCP plane, in security.
- `cred-endpoint-mismatch`. Separate line: `HTTP:GET` denied, reason `credential_endpoint_mismatch`. OpenShell's docs describe two independent checks, network policy and the credential's endpoint binding, and both must pass. Same incident class.
- `egress-default-deny`. curl to `example.com:443`, `transparent_tcp_policy_denied`. Nothing allowed that host. Data exfiltration, Agent plane, access.
- `dns-policy-refuse`. `NET:REFUSE`, `policy_dns_ineligible`. The name was not eligible for policy DNS, so it was refused locally. Same exfiltration class.
- `metadata-address-refused`. A request to `169.254.169.254:80`, the address cloud VMs use to hand out credentials, is denied with `transparent_tcp_policy_denied`: no network rule allows it. Cloud-metadata credential theft, Agent plane, security.
- `l7-delete-denied`. `HTTP:DELETE` on `api.github.com`, policy `github_readonly`, engine `l7`. Read-only means the method is denied, not just the host. Destructive API writes, MCP plane, access.
- `l7-post-denied`. The same rule on POST. A read-only GitHub binding that still allowed POST would be a different policy. This one does not.
- `binary-identity-denied`. python3.12 to `api.github.com:443` is denied. The rule names `/usr/bin/curl`. Another binary reaching an allowed host is still a deny. Exfiltration with a tool the policy did not name.
- `fs-secret-denied`. The planted env file is world-readable. The pass line is `PROBE fs-secret-denied BLOCKED` because Landlock does not show up in this gateway log. Secrets sprawl. The denial is the kernel, recorded by the probe because the supervisor stream does not carry it.
- `priv-nonroot-denied`. `PROBE priv-nonroot-denied BLOCKED`. The policy runs the workload as uid 1000. Privilege escalation stops at process credentials. Same recording rule as the file read.

## 5:30–6:20 — AIControls planes and domains

**On screen:** The mapping table in the README. Leave cost visible and empty of checkmarks.

**Say:** Three planes. Developer is the policy file, reviewed before the sandbox exists. This matrix does not grade that review; Kyverno CEL is how you would reject a bad YAML later, and that still would not see the agent's next curl. Agent is the runtime of the process: egress, DNS, metadata, which binary, which file, which uid. MCP is the tool credential and the GitHub methods, DELETE and POST. Four domains sit under those planes: access, cost, security, compliance. You just saw access and security. Cost, meaning spend and quotas, is not in this sandbox. Compliance here is only the local log plus this matrix, not a retention program. AIControls is the fleet view of those planes. This laptop is one box.

## 6:20–7:00 — What we are not claiming

**On screen:** The "What this is not" section, then `make clean`.

**Say:** OpenShell v0.1.3 is alpha. One gateway enforced these denials on one Docker host. That is not fleet enforcement. Nirmata Runtime is the roadmap for the same intent across nodes: default-deny, no metadata address, read-only tool calls, no secret file, non-root. We are not saying Nirmata Runtime ingests this log today. We are saying an agent that has passed admission still has to be governed while it acts, and this log is the kind of evidence that governance should be able to grade. `make clean` deletes the demo sandbox.
