#!/usr/bin/env bash
# Stub only. Do not add out-of-policy commands here.
# A separate, operator-supplied copy of this script performs the probes.
# This committed file only reports that those probes are not present.
set -euo pipefail

printf '%s\n' "add probes: scenarios/run_all.sh is a stub. Replace it with the operator-supplied probe script. verify.sh only observes and reports what the sandbox denied."
printf '%s\n' "For each kernel-only control (kind=exit-code in expected_events.tsv), the probe script must print a line: PROBE <id> BLOCKED"
exit 2
