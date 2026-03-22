#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_SCRIPT="$ROOT_DIR/test-env/test-external-codex-workspace-macos.sh"

exec env \
    SPIDERWEB_E2E_SCENARIO=smoke \
    CODEX_MODEL_REASONING_EFFORT="${CODEX_MODEL_REASONING_EFFORT:-medium}" \
    bash "$HARNESS_SCRIPT"
