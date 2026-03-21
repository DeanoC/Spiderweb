#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_SCRIPT="$ROOT_DIR/test-env/test-external-codex-workspace.sh"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "[FAIL] native macOS external Codex E2E requires Darwin" >&2
    exit 1
fi

exec env \
    SPIDERWEB_E2E_VARIANT=macos-native \
    TRACE_BACKEND="${TRACE_BACKEND:-none}" \
    bash "$HARNESS_SCRIPT"
