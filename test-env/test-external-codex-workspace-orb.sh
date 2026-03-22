#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_SCRIPT="$ROOT_DIR/test-env/test-external-codex-workspace.sh"
ORB_MACHINE="${ORB_MACHINE:-}"
ORB_USER="${ORB_USER:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }

build_orb_env_list() {
    local -a names=(
        BIND_ADDR
        SPIDERWEB_PORT
        LOCAL_WORKSPACE_NODE_PORT
        REMOTE_NODE_PORT
        SPIDERWEB_E2E_SCENARIO
        CODEX_MODE
        CODEX_LAUNCH_CMD
        TRACE_BACKEND
        KEEP_TEMP
        CODEX_BIN
        CODEX_CLI_VERSION
        CODEX_AUTH_MODE
        CODEX_API_KEY_ENV
        CODEX_HOME_DIR
        CODEX_MODEL
        CODEX_MODEL_REASONING_EFFORT
        EXTERNAL_AGENT_ID
        CODEX_TIMEOUT_SECONDS
        CODEX_IDLE_TIMEOUT_SECONDS
        CODEX_JSON_EVENTS
        CODEX_USE_PTY
        CODEX_DISABLE_COLLABORATION_MODES
        CODEX_DISABLE_APPS
        CODEX_DISABLE_SHELL_SNAPSHOT
        CODEX_ALLOW_HOST_CODEX_HOME
        CODEX_ENABLE_TERMINAL_BRIDGE
        CODEX_ENABLE_GIT_BRIDGE
        CODEX_INSTALL_IF_MISSING
        SPIDERWEB_INSTALL_SOURCE
        SPIDERWEB_RELEASE_VERSION
        SPIDERWEB_RELEASE_ARCHIVE_URL
        SPIDERWEB_RELEASE_ARCHIVE_SHA256
        OUTPUT_DIR
        OPENAI_API_KEY
    )
    if [[ -n "${CODEX_API_KEY_ENV:-}" ]]; then
        names+=("$CODEX_API_KEY_ENV")
    fi

    local result=""
    local seen=":"
    local existing="${ORBENV:-}"
    if [[ -n "$existing" ]]; then
        local IFS=':'
        local -a existing_names=($existing)
        local name
        for name in "${existing_names[@]}"; do
            [[ -z "$name" ]] && continue
            if [[ "$seen" == *":$name:"* ]]; then
                continue
            fi
            seen+="$name:"
            if [[ -n "$result" ]]; then
                result+=":"
            fi
            result+="$name"
        done
    fi

    local name
    for name in "${names[@]}"; do
        [[ -z "$name" ]] && continue
        if [[ "$seen" == *":$name:"* ]]; then
            continue
        fi
        seen+="$name:"
        if [[ -n "$result" ]]; then
            result+=":"
        fi
        result+="$name"
    done

    printf '%s' "$result"
}

run_linux_harness_locally() {
    exec bash "$HARNESS_SCRIPT"
}

run_linux_harness_via_orb() {
    if ! command -v orbctl >/dev/null 2>&1; then
        log_fail "OrbStack is required on macOS for this wrapper (missing: orbctl)"
        exit 1
    fi

    local output_dir="${OUTPUT_DIR:-$ROOT_DIR/test-env/out/external-codex-workspace-orb-$(date +%Y%m%d-%H%M%S)}"
    local orb_env
    orb_env="$(build_orb_env_list)"

    local -a cmd=(orbctl run --path --workdir "$ROOT_DIR")
    if [[ -n "$ORB_MACHINE" ]]; then
        cmd+=(--machine "$ORB_MACHINE")
    fi
    if [[ -n "$ORB_USER" ]]; then
        cmd+=(--user "$ORB_USER")
    fi
    cmd+=(bash test-env/test-external-codex-workspace.sh)

    log_info "Running Linux external Codex E2E in Orb"
    OUTPUT_DIR="$output_dir" ORBENV="$orb_env" TRACE_BACKEND="${TRACE_BACKEND:-none}" "${cmd[@]}"
}

platform="$(uname -s)"
case "$platform" in
    Linux)
        run_linux_harness_locally
        ;;
    Darwin)
        run_linux_harness_via_orb
        ;;
    *)
        log_fail "unsupported host platform: $platform"
        exit 1
        ;;
esac
