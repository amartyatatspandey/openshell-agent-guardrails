#!/usr/bin/env bash
# Read-only environment checks for the OpenShell v0.1.3 demo.
# Prints a fix for each failure. Never changes Docker or OpenShell settings.
set -euo pipefail

failures=0
PINNED_VERSION="v0.1.3"
HOST_NET_UI="Docker Desktop > Settings > Resources > Network > Enable host networking"

note() {
  printf '%s\n' "$*"
}

fail() {
  printf 'FAIL: %s\n' "$*"
  failures=$((failures + 1))
}

ok() {
  printf 'ok: %s\n' "$*"
}

check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    fail "docker is not on PATH. Install Docker 28 or newer and start the daemon."
    return 0
  fi
  local version
  if ! version="$(docker version --format '{{.Server.Version}}' 2>/dev/null)"; then
    fail "docker is installed but the daemon is not reachable. Start Docker and rerun make preflight."
    return 0
  fi
  local major="${version%%.*}"
  case "$major" in
    ''|*[!0-9]*)
      fail "could not parse the Docker server version '${version}'. Need Docker >= 28."
      return 0
      ;;
  esac
  if [ "$major" -lt 28 ]; then
    fail "Docker server ${version} is older than 28. Upgrade Docker, then rerun make preflight."
    return 0
  fi
  ok "docker server ${version}"
}

check_host_networking() {
  if [ "$(uname -s)" != "Darwin" ]; then
    note "host networking: the Docker Desktop toggle applies to macOS. On this OS it is not checked."
    note "If you are on Docker Desktop for Mac, turn on: ${HOST_NET_UI}"
    note "Without it, sandbox create fails with: Startup configuration fetch failed"
    return 0
  fi
  local settings="${HOME}/Library/Group Containers/group.com.docker/settings-store.json"
  if [ ! -f "$settings" ]; then
    fail "cannot read HostNetworkingEnabled (missing ${settings})."
    note "Fix: ${HOST_NET_UI}"
    note "Without it, sandbox create fails with: Startup configuration fetch failed"
    return 0
  fi
  if grep -E -q '"HostNetworkingEnabled"[[:space:]]*:[[:space:]]*true' "$settings"; then
    ok "Docker Desktop HostNetworkingEnabled is true"
    return 0
  fi
  fail "Docker Desktop host networking is off (HostNetworkingEnabled is not true)."
  note "Fix: ${HOST_NET_UI}"
  note "Without it, sandbox create fails with: Startup configuration fetch failed"
  note "This check does not change Docker settings."
}

check_openshell() {
  if ! command -v openshell >/dev/null 2>&1; then
    fail "openshell is not on PATH."
    note "Install the pinned release (do not use a floating main build):"
    note "  curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | OPENSHELL_VERSION=${PINNED_VERSION} sh"
    note "macOS Homebrew: the installer registers a service. The local gateway listens on https://localhost:17670."
    return 0
  fi
  local version_out
  version_out="$(openshell version 2>/dev/null || openshell --version 2>/dev/null || true)"
  case "$version_out" in
    *v0.1.3*)
      ok "openshell ${PINNED_VERSION}"
      ;;
    *)
      fail "openshell is installed but not ${PINNED_VERSION} (got: ${version_out:-no version output})."
      note "Reinstall the pin:"
      note "  curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | OPENSHELL_VERSION=${PINNED_VERSION} sh"
      ;;
  esac
  local status_out
  status_out="$(openshell status 2>&1 || true)"
  case "$status_out" in
    *Connected*)
      ok "openshell status is Connected"
      ;;
    *)
      fail "openshell status is not Connected."
      printf '%s\n' "$status_out"
      note "macOS: start the Homebrew service so the gateway on https://localhost:17670 comes up, then rerun openshell status."
      note "Reinstall if the CLI is present but the gateway never connects:"
      note "  curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | OPENSHELL_VERSION=${PINNED_VERSION} sh"
      ;;
  esac
}

note "OpenShell guardrails preflight (read-only, pin ${PINNED_VERSION})"
check_docker
check_host_networking
check_openshell

if [ "$failures" -ne 0 ]; then
  note "${failures} check(s) failed. Fix the items above and rerun. Nothing was changed."
  exit 1
fi
note "preflight passed"
exit 0
