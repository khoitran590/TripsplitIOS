#!/usr/bin/env bash

set -euo pipefail

supabase_bin="${SUPABASE_BIN:-supabase}"
docker_bin="${DOCKER_BIN:-docker}"

require_command() {
  local candidate="$1"
  local label="$2"
  if [[ "$candidate" == */* ]]; then
    if [[ ! -x "$candidate" ]]; then
      echo "error: $label was not found or is not executable at '$candidate'." >&2
      exit 1
    fi
  elif ! command -v "$candidate" >/dev/null 2>&1; then
    echo "error: $label is unavailable. Install it and ensure '$candidate' is on PATH." >&2
    exit 1
  fi
}

require_command "$supabase_bin" "Supabase CLI"
require_command "$docker_bin" "Docker-compatible CLI"

if ! "$docker_bin" info >/dev/null 2>&1; then
  cat >&2 <<'MESSAGE'
error: the Docker-compatible container runtime is not reachable.
Start Docker Desktop, OrbStack, Colima, or Rancher Desktop, then retry.
For this project's current Colima setup, run: colima start
MESSAGE
  exit 1
fi
