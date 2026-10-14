.PHONY: help setup preflight verify demo clean kyverno kyverno-stop policy-gate policy-sign policy-tamper

IMAGE ?= openshell-guardrails-agent:dev
PROVIDER ?= demo-github
SANDBOX_NAME ?= guardrails-demo

help:
	@printf '%s\n' \
	  'setup      Build the sandbox image and register the fake GitHub provider' \
	  'preflight  Check Docker >= 28, macOS host networking, OpenShell v0.1.3' \
	  'verify     Create the sandbox, run probes if present, print the PASS/FAIL matrix' \
	  'demo       verify, plus the agent attempts and the raw audit-log denials' \
	  'kyverno    Bonus: Kyverno decides GitHub paths and MCP tool calls, OpenShell enforces (10 graded rows)' \
	  'kyverno-stop  Remove that registration and stop the bonus processes' \
	  'policy-gate   Prove agent-policy.yaml is inside the operator boundary and check its review signature' \
	  'policy-sign   Re-sign reviewed policies (refuses anything outside the boundary)' \
	  'policy-tamper Edit copies of the policy (and the boundary) eight ways; the gate refuses every one' \
	  'clean      Delete the guardrails-demo sandbox'

preflight:
	bash scripts/preflight.sh

setup: preflight
	bash scripts/setup.sh

verify: preflight
	IMAGE='$(IMAGE)' PROVIDER='$(PROVIDER)' SANDBOX_NAME='$(SANDBOX_NAME)' bash verify.sh

demo: preflight
	DEMO=1 IMAGE='$(IMAGE)' PROVIDER='$(PROVIDER)' SANDBOX_NAME='$(SANDBOX_NAME)' bash verify.sh

kyverno: preflight
	bash scripts/kyverno-bonus.sh

kyverno-stop:
	bash scripts/kyverno-stop.sh

clean:
	openshell sandbox delete $(SANDBOX_NAME)

policy-gate:
	bash scripts/policy-gate.sh

policy-sign:
	bash scripts/policy-sign.sh

policy-tamper:
	bash scripts/policy-tamper.sh
