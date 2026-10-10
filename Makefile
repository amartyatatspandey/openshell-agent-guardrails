.PHONY: help setup preflight verify demo clean

IMAGE ?= openshell-guardrails-agent:dev
PROVIDER ?= demo-github
SANDBOX_NAME ?= guardrails-demo

help:
	@printf '%s\n' \
	  'setup      Build the sandbox image and register the fake GitHub provider' \
	  'preflight  Check Docker >= 28, macOS host networking, OpenShell v0.1.3' \
	  'verify     Create the sandbox, run probes if present, print the PASS/FAIL matrix' \
	  'demo       Same path as verify, for the narrated walkthrough' \
	  'clean      Delete the guardrails-demo sandbox'

preflight:
	bash scripts/preflight.sh

setup: preflight
	bash scripts/setup.sh

verify: preflight
	IMAGE='$(IMAGE)' PROVIDER='$(PROVIDER)' SANDBOX_NAME='$(SANDBOX_NAME)' bash verify.sh

demo: verify

clean:
	openshell sandbox delete $(SANDBOX_NAME)
