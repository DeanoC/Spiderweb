#!/usr/bin/env bash
# Installer-first external Codex E2E scenario:
# - install Spiderweb into an isolated temp HOME via install.sh
# - start Spiderweb on Linux with an internal runtime root
# - attach a clean standalone workspace node and a separate remote data node
# - compose a workspace with canonical /nodes/local/fs and /shared_data mounts
# - namespace-mount the workspace
# - run a separate plain Codex CLI against the mounted workspace
# - validate the generated Python text adventure and emit usage reports

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSET_DIR="$ROOT_DIR/test-env/codex-assets"
HOST_HOME_DIR="${HOME:-}"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"

SPIDERWEB_PORT="${SPIDERWEB_PORT-}"
LOCAL_WORKSPACE_NODE_PORT="${LOCAL_WORKSPACE_NODE_PORT-}"
REMOTE_NODE_PORT="${REMOTE_NODE_PORT-}"

SPIDERWEB_E2E_VARIANT="${SPIDERWEB_E2E_VARIANT:-linux}"
SPIDERWEB_E2E_SCENARIO="${SPIDERWEB_E2E_SCENARIO:-game}"
CODEX_MODE="${CODEX_MODE:-auto}"
CODEX_LAUNCH_CMD="${CODEX_LAUNCH_CMD:-}"
TRACE_BACKEND="${TRACE_BACKEND:-}"
KEEP_TEMP="${KEEP_TEMP:-0}"
CODEX_BIN="${CODEX_BIN:-}"
CODEX_CLI_VERSION="${CODEX_CLI_VERSION:-0.111.0}"
CODEX_AUTH_MODE="${CODEX_AUTH_MODE:-auto}"
CODEX_API_KEY_ENV="${CODEX_API_KEY_ENV:-OPENAI_API_KEY}"
CODEX_HOME_DIR="${CODEX_HOME_DIR:-$HOST_HOME_DIR}"
CODEX_MODEL="${CODEX_MODEL:-}"
CODEX_MODEL_REASONING_EFFORT="${CODEX_MODEL_REASONING_EFFORT:-low}"
EXTERNAL_AGENT_ID="${EXTERNAL_AGENT_ID:-codex}"
CODEX_TIMEOUT_SECONDS="${CODEX_TIMEOUT_SECONDS:-900}"
CODEX_IDLE_TIMEOUT_SECONDS="${CODEX_IDLE_TIMEOUT_SECONDS:-0}"
CODEX_JSON_EVENTS="${CODEX_JSON_EVENTS:-1}"
CODEX_USE_PTY="${CODEX_USE_PTY:-1}"
CODEX_DISABLE_COLLABORATION_MODES="${CODEX_DISABLE_COLLABORATION_MODES:-1}"
CODEX_DISABLE_APPS="${CODEX_DISABLE_APPS:-1}"
CODEX_DISABLE_SHELL_SNAPSHOT="${CODEX_DISABLE_SHELL_SNAPSHOT:-1}"
CODEX_ALLOW_HOST_CODEX_HOME="${CODEX_ALLOW_HOST_CODEX_HOME:-1}"
CODEX_ENABLE_TERMINAL_BRIDGE="${CODEX_ENABLE_TERMINAL_BRIDGE:-1}"
CODEX_ENABLE_GIT_BRIDGE="${CODEX_ENABLE_GIT_BRIDGE:-1}"
CODEX_INSTALL_IF_MISSING="${CODEX_INSTALL_IF_MISSING:-1}"
SPIDERWEB_INSTALL_SOURCE="${SPIDERWEB_INSTALL_SOURCE:-auto}"
SPIDERWEB_RELEASE_VERSION="${SPIDERWEB_RELEASE_VERSION:-}"
SPIDERWEB_RELEASE_ARCHIVE_URL="${SPIDERWEB_RELEASE_ARCHIVE_URL:-}"
SPIDERWEB_RELEASE_ARCHIVE_SHA256="${SPIDERWEB_RELEASE_ARCHIVE_SHA256:-}"
MANUAL_EXIT_CODE=20
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/spiderweb-external-codex-workspace-${SPIDERWEB_E2E_VARIANT}-${SPIDERWEB_E2E_SCENARIO}-$(date +%Y%m%d-%H%M%S)-$$}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }

is_linux_variant() {
    [[ "$SPIDERWEB_E2E_VARIANT" == "linux" ]]
}

is_macos_native_variant() {
    [[ "$SPIDERWEB_E2E_VARIANT" == "macos-native" ]]
}

require_bin() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_fail "required command not found: $1"
        exit 1
    fi
}

required_spiderweb_bins=(
    spiderweb
    spiderweb-config
    spiderweb-control
    spiderweb-fs-mount
    spiderweb-fs-node
    spiderweb-local-node
    spiderweb-local-service
)

run_with_timeout() {
    local seconds="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" "$@"
    else
        "$@"
    fi
}

pick_free_port() {
    python3 - <<'PY'
import socket

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
}

json_field() {
    local json="$1"
    local filter="$2"
    jq -er "$filter" <<<"$json"
}

shell_quote() {
    printf '%q' "$1"
}

ensure_supported_host() {
    local platform
    platform="$(uname -s)"
    case "$SPIDERWEB_E2E_VARIANT" in
        linux)
            if [[ "$platform" != "Linux" ]]; then
                log_fail "this harness currently supports Linux only (found: $platform). On macOS, use test-env/test-external-codex-workspace-orb.sh or test-env/test-external-codex-workspace-macos.sh"
                exit 1
            fi
            ;;
        macos-native)
            if [[ "$platform" != "Darwin" ]]; then
                log_fail "the native macOS harness requires Darwin (found: $platform)"
                exit 1
            fi
            ;;
        *)
            log_fail "unsupported SPIDERWEB_E2E_VARIANT: $SPIDERWEB_E2E_VARIANT"
            exit 1
            ;;
    esac
}

SPIDERWEB_PID=""
LOCAL_WORKSPACE_NODE_PID=""
REMOTE_NODE_PID=""
MOUNT_PID=""
PROJECT_ID=""
PROJECT_TOKEN=""
SPIDERWEB_AUTH_TOKEN=""
LOCAL_WORKSPACE_NODE_ID=""
REMOTE_NODE_ID=""
CODEX_RESOLVED_BIN=""
CODEX_RESOLVED_VERSION=""
CODEX_SELECTED_AUTH_MODE=""
CODEX_EFFECTIVE_HOME=""
CODEX_FAILURE_REASON=""
CODEX_RUN_STATE="not_started"
CODEX_LAUNCH_SOURCE=""
declare -a CODEX_ENV_BASE=()
declare -a CODEX_ALLOWED_BRIDGE_EXECS=()
RUN_STARTED_AT_UTC=""
CODEX_LAUNCH_STARTED_AT_UTC=""
CODEX_BOOTSTRAP_COMPLETE_AT_UTC=""
CODEX_BOOTSTRAP_COMPLETE_SOURCE=""
CODEX_FIRST_WORKSPACE_WRITE_AT_UTC=""
CODEX_FIRST_WORKSPACE_WRITE_PATH=""
VALIDATION_STARTED_AT_UTC=""

cleanup() {
    local exit_code=$?

    if [[ -n "${MOUNT_POINT:-}" && -d "${MOUNT_POINT:-}" ]]; then
        if is_linux_variant; then
            if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$MOUNT_POINT"; then
                fusermount3 -u "$MOUNT_POINT" >/dev/null 2>&1 || true
            fi
        elif is_macos_native_variant; then
            if command -v diskutil >/dev/null 2>&1; then
                diskutil unmount force "$MOUNT_POINT" >/dev/null 2>&1 || true
            fi
        fi
    fi

    if [[ -n "${MOUNT_PID:-}" ]]; then
        kill "$MOUNT_PID" >/dev/null 2>&1 || true
        wait "$MOUNT_PID" >/dev/null 2>&1 || true
    fi
    if [[ -n "${REMOTE_NODE_PID:-}" ]]; then
        kill "$REMOTE_NODE_PID" >/dev/null 2>&1 || true
        wait "$REMOTE_NODE_PID" >/dev/null 2>&1 || true
    fi
    if [[ -n "${LOCAL_WORKSPACE_NODE_PID:-}" ]]; then
        kill "$LOCAL_WORKSPACE_NODE_PID" >/dev/null 2>&1 || true
        wait "$LOCAL_WORKSPACE_NODE_PID" >/dev/null 2>&1 || true
    fi
    if [[ -n "${SPIDERWEB_PID:-}" ]]; then
        kill "$SPIDERWEB_PID" >/dev/null 2>&1 || true
        wait "$SPIDERWEB_PID" >/dev/null 2>&1 || true
    fi

    if [[ "$KEEP_TEMP" == "1" ]]; then
        log_info "Preserved temporary workspace at ${TEST_TMP_DIR:-<unset>}"
    elif [[ -n "${TEST_TMP_DIR:-}" && -d "${TEST_TMP_DIR:-}" ]]; then
        rm -rf "$TEST_TMP_DIR"
    fi

    exit "$exit_code"
}
trap cleanup EXIT

ensure_supported_host
require_bin jq
require_bin python3
require_bin bash
if is_linux_variant; then
    require_bin fusermount3
fi

if [[ -z "$TRACE_BACKEND" ]]; then
    # Linux runs default to strace for extra mount/client debugging. Native
    # macOS runs fall back to "none" because strace is not available there.
    if is_linux_variant; then
        TRACE_BACKEND="strace"
    else
        TRACE_BACKEND="none"
    fi
fi

if [[ -z "$SPIDERWEB_PORT" ]]; then
    SPIDERWEB_PORT="$(pick_free_port)"
fi
if [[ -z "$LOCAL_WORKSPACE_NODE_PORT" ]]; then
    LOCAL_WORKSPACE_NODE_PORT="$(pick_free_port)"
fi
if [[ -z "$REMOTE_NODE_PORT" ]]; then
    REMOTE_NODE_PORT="$(pick_free_port)"
fi

mkdir -p "$OUTPUT_DIR" "$OUTPUT_DIR/logs" "$OUTPUT_DIR/snapshots"
RUN_STARTED_AT_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

TEST_TMP_DIR="$(mktemp -d)"
TEMP_HOME="$TEST_TMP_DIR/home"
REPO_BUILD_INSTALL_DIR="$ROOT_DIR/zig-out/bin"
SIGNED_APP_RESOURCE_DIR="/Applications/Spiderweb.app/Contents/Resources"
if is_macos_native_variant; then
    INSTALL_DIR="$REPO_BUILD_INSTALL_DIR"
else
    INSTALL_DIR="$TEMP_HOME/.local/bin"
    PATH="$INSTALL_DIR:$PATH"
    export PATH
fi
mkdir -p "$TEMP_HOME"
if ! is_macos_native_variant; then
    mkdir -p "$INSTALL_DIR"
fi

INSTALL_LOG="$OUTPUT_DIR/logs/install.log"
SPIDERWEB_LOG="$OUTPUT_DIR/logs/spiderweb.log"
LOCAL_WORKSPACE_NODE_LOG="$OUTPUT_DIR/logs/local-workspace-node.log"
REMOTE_NODE_LOG="$OUTPUT_DIR/logs/remote-node.log"
MOUNT_LOG="$OUTPUT_DIR/logs/namespace-mount.log"
CODEX_STDOUT_LOG="$OUTPUT_DIR/logs/codex.stdout.log"
CODEX_STDERR_LOG="$OUTPUT_DIR/logs/codex.stderr.log"
CODEX_PTY_LOG="$OUTPUT_DIR/logs/codex.pty.log"
CODEX_INSTALL_LOG="$OUTPUT_DIR/logs/codex-install.log"
CODEX_AUTH_LOG="$OUTPUT_DIR/logs/codex-auth.log"
CODEX_EVENT_SUMMARY="$OUTPUT_DIR/codex_exec_summary.json"
CODEX_PROGRESS_TIMELINE="$OUTPUT_DIR/codex_progress_timeline.json"

SPIDERWEB_CONFIG_FILE="$TEST_TMP_DIR/spiderweb.json"
LTM_DIR="$TEST_TMP_DIR/ltm"
SPIDERWEB_RUNTIME_ROOT="$TEST_TMP_DIR/spiderweb-runtime"
WORKSPACE_EXPORT_ROOT="$TEST_TMP_DIR/workspace-export"
REMOTE_EXPORT_ROOT="$TEST_TMP_DIR/remote-export"
MOUNT_POINT="$TEST_TMP_DIR/mount"
MOUNT_WORKSPACE_PATH="$MOUNT_POINT/nodes/local/fs"
CODEX_PROGRESS_WORKSPACE_PATH="$WORKSPACE_EXPORT_ROOT"
PROMPT_FILE="$OUTPUT_DIR/codex_prompt.txt"
HANDOFF_DIR="$OUTPUT_DIR/codex_handoff"
VALIDATION_OUTPUT="$OUTPUT_DIR/game_validation.json"
USAGE_JSON="$OUTPUT_DIR/codex_usage_report.json"
USAGE_MD="$OUTPUT_DIR/codex_usage_report.md"
BOOTSTRAP_JSON="$OUTPUT_DIR/bootstrap_provenance.json"
STRACE_PREFIX="$OUTPUT_DIR/logs/codex.strace"
VALIDATOR_SRC="$ASSET_DIR/validate_text_adventure.py"
PARSER_SRC="$ASSET_DIR/parse_codex_usage_report.py"
CODEX_EVENT_SUMMARY_SRC="$ASSET_DIR/summarize_codex_exec_json.py"
CONTROL_URL="ws://$BIND_ADDR:$SPIDERWEB_PORT/"
CODEX_RUNTIME_ROOT="$TEST_TMP_DIR/codex-runtime"
CODEX_NPM_PREFIX="$CODEX_RUNTIME_ROOT/npm-prefix"
CODEX_ISOLATED_HOME="$CODEX_RUNTIME_ROOT/home"
CODEX_XDG_CONFIG_HOME="$CODEX_RUNTIME_ROOT/xdg-config"
CODEX_XDG_CACHE_HOME="$CODEX_RUNTIME_ROOT/xdg-cache"
CODEX_XDG_DATA_HOME="$CODEX_RUNTIME_ROOT/xdg-data"
CODEX_XDG_STATE_HOME="$CODEX_RUNTIME_ROOT/xdg-state"
CODEX_BRIDGE_DIR="$CODEX_RUNTIME_ROOT/bridge"
CODEX_BRIDGE_COMMON_SRC="$ASSET_DIR/spiderweb_bridge_common.py"
CODEX_BRIDGE_SHELL_SRC="$ASSET_DIR/spiderweb_terminal_shell.py"
CODEX_BRIDGE_GIT_SRC="$ASSET_DIR/spiderweb_git_shim.py"
CODEX_STDIN_LAUNCHER_SRC="$ASSET_DIR/codex_exec_stdin_launcher.py"
CODEX_BRIDGE_LSB_RELEASE_SRC="$ASSET_DIR/spiderweb_lsb_release.py"
CODEX_BRIDGE_GETCONF_SRC="$ASSET_DIR/spiderweb_getconf.py"
CODEX_BRIDGE_COMMON="$CODEX_BRIDGE_DIR/spiderweb_bridge_common.py"
CODEX_BRIDGE_SHELL="$CODEX_BRIDGE_DIR/spiderweb-terminal-shell"
CODEX_BRIDGE_GIT="$CODEX_BRIDGE_DIR/git"
CODEX_STDIN_LAUNCHER="$CODEX_BRIDGE_DIR/codex-exec-stdin-launcher"
CODEX_BRIDGE_PYTHON="$CODEX_BRIDGE_DIR/python3"
CODEX_BRIDGE_NODE="$CODEX_BRIDGE_DIR/node"
CODEX_BRIDGE_SETSID="$CODEX_BRIDGE_DIR/setsid"
CODEX_BRIDGE_LSB_RELEASE="$CODEX_BRIDGE_DIR/lsb_release"
CODEX_BRIDGE_GETCONF="$CODEX_BRIDGE_DIR/getconf"

case "$SPIDERWEB_E2E_SCENARIO" in
    game)
        SCENARIO_NAME="game"
        PROMPT_TEMPLATE="$ASSET_DIR/external_codex_game_prompt.txt"
        VALIDATOR_SRC="$ASSET_DIR/validate_text_adventure.py"
        WORKSPACE_VALIDATOR_BASENAME="validate_game.py"
        VALIDATION_OUTPUT="$OUTPUT_DIR/game_validation.json"
        PROJECT_UP_NAME="External Codex Text Adventure"
        PROJECT_UP_VISION="Installer-first external Codex workspace validation"
        ;;
    smoke)
        SCENARIO_NAME="smoke"
        PROMPT_TEMPLATE="$ASSET_DIR/external_codex_smoke_prompt.txt"
        VALIDATOR_SRC="$ASSET_DIR/validate_workspace_smoke.py"
        WORKSPACE_VALIDATOR_BASENAME="validate_smoke.py"
        VALIDATION_OUTPUT="$OUTPUT_DIR/smoke_validation.json"
        PROJECT_UP_NAME="External Codex Smoke"
        PROJECT_UP_VISION="Fast external Codex bootstrap and write smoke validation"
        ;;
    *)
        log_fail "unsupported SPIDERWEB_E2E_SCENARIO: $SPIDERWEB_E2E_SCENARIO"
        exit 1
        ;;
esac
CODEX_EXEC_PATH=""
AGENT_HOME_TARGET_ROOT="$WORKSPACE_EXPORT_ROOT/.spiderweb/agents/$EXTERNAL_AGENT_ID/home"
AGENT_HOME_MOUNT_ROOT="$MOUNT_WORKSPACE_PATH/.spiderweb/agents/$EXTERNAL_AGENT_ID/home"
AGENT_HOME_TARGET_XDG_CONFIG="$AGENT_HOME_TARGET_ROOT/.config"
AGENT_HOME_TARGET_XDG_CACHE="$AGENT_HOME_TARGET_ROOT/.cache"
AGENT_HOME_TARGET_XDG_DATA="$AGENT_HOME_TARGET_ROOT/.local/share"
AGENT_HOME_TARGET_XDG_STATE="$AGENT_HOME_TARGET_ROOT/.local/state"
AGENT_HOME_TARGET_TMP="$AGENT_HOME_TARGET_ROOT/tmp"

AUTH_TOKENS_FILE="$LTM_DIR/auth_tokens.json"
mkdir -p \
    "$LTM_DIR" \
    "$SPIDERWEB_RUNTIME_ROOT/agents" \
    "$SPIDERWEB_RUNTIME_ROOT/templates" \
    "$WORKSPACE_EXPORT_ROOT" \
    "$REMOTE_EXPORT_ROOT" \
    "$MOUNT_POINT" \
    "$CODEX_RUNTIME_ROOT"

build_usage_report() {
    local skipped_reason="${1-}"
    local -a cmd=(
        python3 "$PARSER_SRC"
        --strace-prefix "$STRACE_PREFIX"
        --workspace-root "$MOUNT_WORKSPACE_PATH"
        --mount-root "$MOUNT_POINT"
        --artifact-root "$OUTPUT_DIR"
        --project-id "${PROJECT_ID:-unknown}"
        --mode "$CODEX_MODE"
        --mounted-services "$OUTPUT_DIR/snapshots/mounted_services.json"
        --venom-packages "$OUTPUT_DIR/snapshots/venom_packages.json"
        --repo-root "$ROOT_DIR"
        --codex-event-log "$CODEX_STDOUT_LOG"
        --json-output "$USAGE_JSON"
        --markdown-output "$USAGE_MD"
    )
    if [[ -d "$CODEX_RUNTIME_ROOT" ]]; then
        cmd+=(--allowed-runtime-root "$CODEX_RUNTIME_ROOT")
    fi
    if [[ -d "$AGENT_HOME_TARGET_ROOT" ]]; then
        cmd+=(--allowed-runtime-root "$AGENT_HOME_TARGET_ROOT")
    fi
    for bridge_exec in "${CODEX_ALLOWED_BRIDGE_EXECS[@]}"; do
        if [[ -n "$bridge_exec" ]]; then
            cmd+=(--allowed-bridge-exec "$bridge_exec")
        fi
    done
    if [[ "$CODEX_ALLOW_HOST_CODEX_HOME" == "1" && -n "$CODEX_HOME_DIR" && -d "$CODEX_HOME_DIR/.codex" ]]; then
        cmd+=(--allowed-host-write-prefix "$CODEX_HOME_DIR/.codex")
    fi
    if [[ -n "$skipped_reason" ]]; then
        cmd+=(--skipped-reason "$skipped_reason")
    fi
    "${cmd[@]}"
    jq '.bootstrap_provenance' "$USAGE_JSON" > "$BOOTSTRAP_JSON"
}

write_skip_outputs() {
    local reason="$1"
    build_usage_report "$reason"

    python3 - "$VALIDATION_OUTPUT" "$reason" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = {
    "ok": False,
    "reason": sys.argv[2],
    "skipped": True,
    "validation_ok": False,
}
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

write_codex_runtime_snapshot() {
    jq -cn \
        --arg bin "${CODEX_RESOLVED_BIN:-}" \
        --arg version "${CODEX_RESOLVED_VERSION:-}" \
        --arg requested_auth "$CODEX_AUTH_MODE" \
        --arg selected_auth "${CODEX_SELECTED_AUTH_MODE:-}" \
        --arg effective_home "${CODEX_EFFECTIVE_HOME:-}" \
        --arg external_agent_id "$EXTERNAL_AGENT_ID" \
        --arg launch_source "${CODEX_LAUNCH_SOURCE:-}" \
        --arg runtime_root "$CODEX_RUNTIME_ROOT" \
        --arg existing_home "$CODEX_HOME_DIR" \
        --arg mounted_home "$AGENT_HOME_MOUNT_ROOT" \
        --arg configured_model "$CODEX_MODEL" \
        --arg configured_reasoning_effort "$CODEX_MODEL_REASONING_EFFORT" \
        --arg timeout_seconds "$CODEX_TIMEOUT_SECONDS" \
        --arg idle_timeout_seconds "$CODEX_IDLE_TIMEOUT_SECONDS" \
        --arg json_events "$CODEX_JSON_EVENTS" \
        --arg use_pty "$CODEX_USE_PTY" \
        --arg disable_collaboration_modes "$CODEX_DISABLE_COLLABORATION_MODES" \
        --arg disable_apps "$CODEX_DISABLE_APPS" \
        --arg disable_shell_snapshot "$CODEX_DISABLE_SHELL_SNAPSHOT" \
        --arg allow_host_codex_home "$CODEX_ALLOW_HOST_CODEX_HOME" \
        --arg launch_cmd_custom "$CODEX_LAUNCH_CMD" \
        '{
            codex_bin: $bin,
            codex_version: $version,
            requested_auth_mode: $requested_auth,
            selected_auth_mode: $selected_auth,
            effective_home: $effective_home,
            external_agent_id: $external_agent_id,
            launch_source: $launch_source,
            codex_runtime_root: $runtime_root,
            existing_login_home: $existing_home,
            mounted_agent_home: $mounted_home,
            configured_model: ($configured_model | if . == "" then null else . end),
            configured_reasoning_effort: ($configured_reasoning_effort | if . == "" then null else . end),
            timeout_seconds: ($timeout_seconds | tonumber),
            idle_timeout_seconds: ($idle_timeout_seconds | tonumber),
            json_events: ($json_events == "1"),
            use_pty: ($use_pty == "1"),
            disable_collaboration_modes: ($disable_collaboration_modes == "1"),
            disable_apps: ($disable_apps == "1"),
            disable_shell_snapshot: ($disable_shell_snapshot == "1"),
            allow_host_codex_home: ($allow_host_codex_home == "1"),
            custom_launch_cmd: ($launch_cmd_custom | if . == "" then null else . end)
        }' > "$OUTPUT_DIR/snapshots/codex_runtime.json"
}

file_mtime_utc() {
    python3 - "$1" <<'PY'
from datetime import datetime, timezone
from pathlib import Path
import sys

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(1)
timestamp = path.stat().st_mtime
if timestamp <= 1:
    raise SystemExit(2)
dt = datetime.fromtimestamp(timestamp, tz=timezone.utc)
print(dt.strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

workspace_first_write_info() {
    python3 - "$CODEX_PROGRESS_WORKSPACE_PATH" "$WORKSPACE_VALIDATOR_BASENAME" <<'PY'
from datetime import datetime, timezone
from pathlib import Path
import sys

workspace = Path(sys.argv[1])
skip = {"AGENTS.md", sys.argv[2]}
best = None

if workspace.exists():
    for entry in workspace.rglob("*"):
        if ".spiderweb" in entry.parts:
            continue
        if entry.name in skip:
            continue
        try:
            stat = entry.stat()
        except FileNotFoundError:
            continue
        rel = entry.relative_to(workspace)
        candidate = (stat.st_mtime, str(rel))
        if best is None or candidate < best:
            best = candidate

if best is None:
    raise SystemExit(1)

dt = datetime.fromtimestamp(best[0], tz=timezone.utc)
print(dt.strftime("%Y-%m-%dT%H:%M:%SZ"))
print(best[1])
PY
}

write_codex_progress_timeline() {
    jq -cn \
        --arg run_started "${RUN_STARTED_AT_UTC:-}" \
        --arg codex_launch_started "${CODEX_LAUNCH_STARTED_AT_UTC:-}" \
        --arg bootstrap_complete "${CODEX_BOOTSTRAP_COMPLETE_AT_UTC:-}" \
        --arg bootstrap_source "${CODEX_BOOTSTRAP_COMPLETE_SOURCE:-}" \
        --arg first_workspace_write "${CODEX_FIRST_WORKSPACE_WRITE_AT_UTC:-}" \
        --arg first_workspace_write_path "${CODEX_FIRST_WORKSPACE_WRITE_PATH:-}" \
        --arg validation_started "${VALIDATION_STARTED_AT_UTC:-}" \
        --arg updated_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{
            run_started_at_utc: ($run_started | if . == "" then null else . end),
            codex_launch_started_at_utc: ($codex_launch_started | if . == "" then null else . end),
            bootstrap_complete_at_utc: ($bootstrap_complete | if . == "" then null else . end),
            bootstrap_complete_source: ($bootstrap_source | if . == "" then null else . end),
            first_workspace_write_at_utc: ($first_workspace_write | if . == "" then null else . end),
            first_workspace_write_path: ($first_workspace_write_path | if . == "" then null else . end),
            validation_started_at_utc: ($validation_started | if . == "" then null else . end),
            updated_at_utc: $updated_at
        }' > "$CODEX_PROGRESS_TIMELINE"
}

observe_codex_progress() {
    local changed=0
    local first_write_info
    local home_result_path="$MOUNT_WORKSPACE_PATH/.spiderweb/services/home/result.json"

    if [[ -z "$CODEX_BOOTSTRAP_COMPLETE_AT_UTC" && -f "$home_result_path" ]] && jq -e '.ok == true' "$home_result_path" >/dev/null 2>&1; then
        CODEX_BOOTSTRAP_COMPLETE_AT_UTC="$(file_mtime_utc "$home_result_path" || true)"
        if [[ -n "$CODEX_BOOTSTRAP_COMPLETE_AT_UTC" ]]; then
            CODEX_BOOTSTRAP_COMPLETE_SOURCE="./.spiderweb/services/home/result.json"
        else
            CODEX_BOOTSTRAP_COMPLETE_AT_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
            CODEX_BOOTSTRAP_COMPLETE_SOURCE="./.spiderweb/services/home/result.json (observed)"
        fi
        changed=1
    fi

    if [[ -z "$CODEX_FIRST_WORKSPACE_WRITE_AT_UTC" ]]; then
        first_write_info="$(workspace_first_write_info 2>/dev/null || true)"
        if [[ -n "$first_write_info" ]]; then
            CODEX_FIRST_WORKSPACE_WRITE_AT_UTC="$(sed -n '1p' <<<"$first_write_info")"
            CODEX_FIRST_WORKSPACE_WRITE_PATH="$(sed -n '2p' <<<"$first_write_info")"
            changed=1
        fi
    fi

    if [[ "$changed" == "1" ]]; then
        write_codex_progress_timeline
    fi
}

write_codex_progress_timeline

handoff_intro() {
    case "$CODEX_RUN_STATE" in
        not_started)
            printf '%s\n' "This run stopped before live Codex execution."
            ;;
        running)
            printf '%s\n' "This run reached live Codex execution, but Codex did not finish successfully."
            ;;
        completed)
            printf '%s\n' "Codex finished running, but the overall E2E did not pass validation/reporting."
            ;;
        *)
            printf '%s\n' "This run preserved a handoff bundle after an incomplete external Codex attempt."
            ;;
    esac
}

write_handoff_bundle() {
    local reason="$1"
    mkdir -p "$HANDOFF_DIR"
    cp "$PROMPT_FILE" "$HANDOFF_DIR/PROMPT.txt"
    if [[ -f "$OUTPUT_DIR/snapshots/AGENTS.md" ]]; then
        cp "$OUTPUT_DIR/snapshots/AGENTS.md" "$HANDOFF_DIR/AGENTS.md"
    fi
    cp "$OUTPUT_DIR/snapshots/protocol.json" "$HANDOFF_DIR/protocol.json"
    cp "$OUTPUT_DIR/snapshots/agent_bootstrap_quickref.json" "$HANDOFF_DIR/agent_bootstrap_quickref.json"
    cp "$OUTPUT_DIR/snapshots/mounted_services.json" "$HANDOFF_DIR/mounted_services.json"
    cp "$OUTPUT_DIR/snapshots/workspace_status.json" "$HANDOFF_DIR/workspace_status.json"
    cp "$OUTPUT_DIR/snapshots/venom_packages.json" "$HANDOFF_DIR/venom_packages.json"
    cp "$OUTPUT_DIR/snapshots/agent_bootstrap.json" "$HANDOFF_DIR/agent_bootstrap.json"
    if [[ -f "$OUTPUT_DIR/snapshots/codex_runtime.json" ]]; then
        cp "$OUTPUT_DIR/snapshots/codex_runtime.json" "$HANDOFF_DIR/codex_runtime.json"
    fi
    if [[ -f "$BOOTSTRAP_JSON" ]]; then
        cp "$BOOTSTRAP_JSON" "$HANDOFF_DIR/bootstrap_provenance.json"
    fi
    if [[ -f "$CODEX_EVENT_SUMMARY" ]]; then
        cp "$CODEX_EVENT_SUMMARY" "$HANDOFF_DIR/codex_exec_summary.json"
    fi
    if [[ -f "$CODEX_PROGRESS_TIMELINE" ]]; then
        cp "$CODEX_PROGRESS_TIMELINE" "$HANDOFF_DIR/codex_progress_timeline.json"
    fi

    local codex_summary_lines=""
    if [[ -f "$CODEX_EVENT_SUMMARY" ]]; then
        codex_summary_lines="$(jq -r '
            [
                "- Codex JSON events captured: \(.json_events_detected)",
                "- Codex event count: \(.event_count)",
                "- Last observed event: \(.last_event.type // "none")",
                "- Last completed item: \(.last_completed_item.type // "none")",
                "- Inferred stall stage: \(.stall_stage // "unknown")",
                (if .last_agent_message then "- Last agent message: " + (.last_agent_message | gsub("[\\r\\n]+"; " ") | .[0:220]) else empty end)
            ] | .[]' "$CODEX_EVENT_SUMMARY")"
    fi

    cat > "$HANDOFF_DIR/README.md" <<EOF
# Codex Handoff

$(handoff_intro)

- Reason: $reason
- Mode: $CODEX_MODE
- Project ID: ${PROJECT_ID:-unknown}
- Namespace mount root during the run: $MOUNT_POINT
- Writable project path inside the mount: $MOUNT_WORKSPACE_PATH
- Namespace metadata directory: $MOUNT_POINT/meta
- Project metadata directory: $MOUNT_POINT/projects/${PROJECT_ID:-unknown}/meta
- Remote shared-data directory: $MOUNT_POINT/shared_data
- Bootstrap contract metadata: $MOUNT_POINT/projects/${PROJECT_ID:-unknown}/meta/agent_bootstrap.json
- Bootstrap quick reference: $MOUNT_POINT/projects/${PROJECT_ID:-unknown}/meta/agent_bootstrap_quickref.json
- Codex auth mode selected: ${CODEX_SELECTED_AUTH_MODE:-unresolved}
- Codex binary: ${CODEX_RESOLVED_BIN:-unresolved}
- Codex stdout log: $CODEX_STDOUT_LOG
- Codex stderr log: $CODEX_STDERR_LOG
- Codex PTY transcript: $CODEX_PTY_LOG

${codex_summary_lines}

Rerun a strict live test with the default launcher:

\`\`\`bash
CODEX_MODE=live \\
CODEX_AUTH_MODE=api_key \\
OPENAI_API_KEY=... \\
bash test-env/test-external-codex-workspace.sh
\`\`\`

Optional custom launch templates may use these placeholders:

- \`{codex_bin}\`
- \`{workspace_root}\`
- \`{namespace_root}\`
- \`{namespace_meta_dir}\`
- \`{project_meta_dir}\`
- \`{shared_data_dir}\`
- \`{prompt_file}\`
- \`{artifact_dir}\`

If you need the temporary environment to stay live for a manual handoff, rerun with \`KEEP_TEMP=1\`.
EOF
}

wait_for_control_ready() {
    for _ in $(seq 1 180); do
        if [[ -f "$AUTH_TOKENS_FILE" ]]; then
            SPIDERWEB_AUTH_TOKEN="$(jq -r '.access_token // empty' "$AUTH_TOKENS_FILE" 2>/dev/null || true)"
            if [[ -n "${SPIDERWEB_AUTH_TOKEN:-}" ]]; then
                export SPIDERWEB_AUTH_TOKEN
                if run_with_timeout 3 "$INSTALL_DIR/spiderweb-control" \
                    --url "$CONTROL_URL" \
                    --auth-token "$SPIDERWEB_AUTH_TOKEN" \
                    node_list >/dev/null 2>&1; then
                    return 0
                fi
            fi
        fi
        sleep 0.1
    done
    return 1
}

control_call() {
    local op="$1"
    local payload="${2-}"
    local output
    if [[ -n "$payload" ]]; then
        output="$(run_with_timeout 8 "$INSTALL_DIR/spiderweb-control" --url "$CONTROL_URL" --auth-token "$SPIDERWEB_AUTH_TOKEN" "$op" "$payload" 2>&1)" || {
            echo "$output" >&2
            return 1
        }
    else
        output="$(run_with_timeout 8 "$INSTALL_DIR/spiderweb-control" --url "$CONTROL_URL" --auth-token "$SPIDERWEB_AUTH_TOKEN" "$op" 2>&1)" || {
            echo "$output" >&2
            return 1
        }
    fi
    printf '%s\n' "$output"
}

wait_for_node_join() {
    local node_name="$1"
    local result_var="$2"
    local reply node_id
    for _ in $(seq 1 180); do
        reply="$(control_call node_list)" || {
            sleep 0.2
            continue
        }
        node_id="$(jq -r --arg node_name "$node_name" '.payload.nodes[]? | select(.node_name == $node_name) | .node_id' <<<"$reply" | head -n1)"
        if [[ -n "$node_id" ]]; then
            printf -v "$result_var" '%s' "$node_id"
            return 0
        fi
        sleep 0.2
    done
    return 1
}

wait_for_workspace_mounts() {
    local reply
    for _ in $(seq 1 180); do
        reply="$(control_call workspace_status "$(jq -cn --arg project_id "$PROJECT_ID" '{project_id: $project_id}')")" || {
            sleep 0.2
            continue
        }
        if jq -e '
            (((.payload.actual_mounts // []) + (.payload.mounts // [])) | map(.mount_path) | index("/nodes/local/fs")) != null and
            (((.payload.actual_mounts // []) + (.payload.mounts // [])) | map(.mount_path) | index("/shared_data")) != null
        ' >/dev/null <<<"$reply"; then
            printf '%s\n' "$reply" > "$OUTPUT_DIR/snapshots/workspace_status.control.json"
            return 0
        fi
        sleep 0.2
    done
    return 1
}

probe_path_kind_quick() {
    local kind="$1"
    local path="$2"
    local timeout_secs=1
    if is_macos_native_variant; then
        timeout_secs=5
    fi

    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_secs" python3 - "$kind" "$path" <<'PY' >/dev/null 2>&1
import os
import sys

kind = sys.argv[1]
path = sys.argv[2]
if kind == "file":
    raise SystemExit(0 if os.path.isfile(path) else 1)
if kind == "dir":
    raise SystemExit(0 if os.path.isdir(path) else 1)
raise SystemExit(2)
PY
        return $?
    fi

    python3 - "$kind" "$path" "$timeout_secs" <<'PY' >/dev/null 2>&1
import os
import signal
import sys

kind = sys.argv[1]
path = sys.argv[2]
timeout_secs = int(sys.argv[3])

def on_alarm(_signum, _frame):
    raise TimeoutError()

signal.signal(signal.SIGALRM, on_alarm)
signal.alarm(timeout_secs)
try:
    if kind == "file":
        raise SystemExit(0 if os.path.isfile(path) else 1)
    if kind == "dir":
        raise SystemExit(0 if os.path.isdir(path) else 1)
    raise SystemExit(2)
except TimeoutError:
    raise SystemExit(124)
finally:
    signal.alarm(0)
PY
}

wait_for_namespace_mount() {
    local deadline=$((SECONDS + 45))
    local probe_timeout_secs=2
    if is_macos_native_variant; then
        deadline=$((SECONDS + 90))
        probe_timeout_secs=8
    fi

    while (( SECONDS < deadline )); do
        if python3 - "$MOUNT_POINT" "$MOUNT_WORKSPACE_PATH" "$PROJECT_ID" "$probe_timeout_secs" <<'PY' >/dev/null 2>&1
import signal
import sys
from pathlib import Path

mount_point = Path(sys.argv[1])
workspace_path = Path(sys.argv[2])
project_id = sys.argv[3]
timeout_secs = int(sys.argv[4])

required_dirs = [
    workspace_path,
    mount_point / "shared_data",
]
required_files = [
    mount_point / "meta" / "protocol.json",
    mount_point / "projects" / project_id / "meta" / "agent_bootstrap_quickref.json",
    workspace_path / ".spiderweb" / "protocol.json",
    workspace_path / ".spiderweb" / "shared_data" / "world_seed.json",
]

def on_alarm(_signum, _frame):
    raise TimeoutError()

signal.signal(signal.SIGALRM, on_alarm)
signal.alarm(timeout_secs)
try:
    if not mount_point.is_dir():
        raise SystemExit(1)
    list(mount_point.iterdir())
    for path in required_dirs:
        if not path.is_dir():
            raise SystemExit(1)
    list(workspace_path.iterdir())
    for path in required_files:
        if not path.is_file():
            raise SystemExit(1)
    raise SystemExit(0)
except TimeoutError:
    raise SystemExit(124)
finally:
    signal.alarm(0)
PY
        then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

probe_directory_listing_quick() {
    local path="$1"
    local timeout_secs=2
    if is_macos_native_variant; then
        timeout_secs=8
    fi
    python3 - "$path" "$timeout_secs" <<'PY'
import signal
import sys
from pathlib import Path

path = Path(sys.argv[1])
timeout_secs = int(sys.argv[2])

def on_alarm(_signum, _frame):
    raise TimeoutError()

signal.signal(signal.SIGALRM, on_alarm)
signal.alarm(timeout_secs)
try:
    next(path.iterdir(), None)
except TimeoutError:
    raise SystemExit(124)
except Exception:
    raise SystemExit(1)
finally:
    signal.alarm(0)
PY
}

assert_seeded_workspace_layout() {
    local path="$1"
    python3 - "$path" "$WORKSPACE_VALIDATOR_BASENAME" <<'PY'
import sys
from pathlib import Path

workspace = Path(sys.argv[1])
expected = [".spiderweb", "AGENTS.md", sys.argv[2]]
entries = sorted(item.name for item in workspace.iterdir())
if entries != expected:
    raise SystemExit(f"expected clean workspace entries {expected}, found {entries}")
PY
}

assert_attached_workspace_layout() {
    local path="$1"
    python3 - "$path" "$WORKSPACE_VALIDATOR_BASENAME" <<'PY'
import sys
from pathlib import Path

workspace = Path(sys.argv[1])
expected = [".spiderweb", "AGENTS.md", sys.argv[2]]
entries = sorted(item.name for item in workspace.iterdir())
if entries != expected:
    raise SystemExit(f"expected attached workspace entries {expected}, found {entries}")
managed = workspace / ".spiderweb"
required = [
    managed / "protocol.json",
    managed / "agent_bootstrap_quickref.json",
    managed / "agent_bootstrap.json",
    managed / "workspace_status.json",
    managed / "mounted_services.json",
    managed / "venom_packages.json",
    managed / "services" / "home" / "control" / "ensure.json",
    managed / "services" / "mounts" / "control" / "bind.json",
    managed / "local_venoms" / "home" / "control" / "ensure.json",
    managed / "shared_data" / "world_seed.json",
    managed / "shared_data" / "items_seed.json",
    managed / "shared_data" / "puzzle_seed.json",
]
missing = [str(path.relative_to(workspace)) for path in required if not path.is_file()]
if missing:
    raise SystemExit(f"missing local bootstrap files: {missing}")
PY
}

inject_codex_cli_workarounds() {
    local cmd="$1"

    if [[ -n "$CODEX_MODEL" && "$cmd" != *" -m "* && "$cmd" != *" --model "* ]]; then
        cmd="${cmd/ exec / exec -m $(shell_quote "$CODEX_MODEL") }"
    fi
    if [[ -n "$CODEX_MODEL_REASONING_EFFORT" && "$cmd" != *"model_reasoning_effort"* ]]; then
        cmd="${cmd/ exec / exec -c model_reasoning_effort=$(shell_quote "$CODEX_MODEL_REASONING_EFFORT") }"
    fi
    if [[ "$CODEX_DISABLE_COLLABORATION_MODES" == "1" && "$cmd" != *"--disable collaboration_modes"* ]]; then
        cmd="${cmd/ exec / exec --disable collaboration_modes }"
    fi
    if [[ "$CODEX_DISABLE_APPS" == "1" && "$cmd" != *"--disable apps"* ]]; then
        cmd="${cmd/ exec / exec --disable apps }"
    fi
    if [[ "$CODEX_DISABLE_SHELL_SNAPSHOT" == "1" && "$cmd" != *"--disable shell_snapshot"* ]]; then
        cmd="${cmd/ exec / exec --disable shell_snapshot }"
    fi
    if [[ "$CODEX_JSON_EVENTS" == "1" && "$cmd" != *" --json"* ]]; then
        cmd="${cmd/ exec / exec --json }"
    fi

    printf '%s' "$cmd"
}

render_prompt() {
    python3 - "$PROMPT_TEMPLATE" "$PROMPT_FILE" \
        "$PROJECT_ID" \
        "$MOUNT_POINT" \
        "$MOUNT_POINT/services" \
        "$MOUNT_POINT/meta" \
        "$MOUNT_POINT/projects/$PROJECT_ID/meta" \
        "$MOUNT_WORKSPACE_PATH" \
        "$MOUNT_POINT/shared_data" <<'PY'
from pathlib import Path
import sys

template_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
replacements = {
    "__PROJECT_ID__": sys.argv[3],
    "__MOUNT_ROOT__": sys.argv[4],
    "__SERVICE_ROOT__": sys.argv[5],
    "__NAMESPACE_META_DIR__": sys.argv[6],
    "__PROJECT_META_DIR__": sys.argv[7],
    "__WORKSPACE_ROOT__": sys.argv[8],
    "__SHARED_DATA_DIR__": sys.argv[9],
}

text = template_path.read_text(encoding="utf-8")
for key, value in replacements.items():
    text = text.replace(key, value)
output_path.write_text(text, encoding="utf-8")
PY
}

write_workspace_seed_files() {
    cp "$VALIDATOR_SRC" "$WORKSPACE_EXPORT_ROOT/$WORKSPACE_VALIDATOR_BASENAME"
    chmod +x "$WORKSPACE_EXPORT_ROOT/$WORKSPACE_VALIDATOR_BASENAME"
}

write_workspace_agents_file() {
    python3 - "$WORKSPACE_EXPORT_ROOT/AGENTS.md" "$PROJECT_ID" "$SCENARIO_NAME" "$WORKSPACE_VALIDATOR_BASENAME" <<'PY'
from pathlib import Path
import sys

output_path = Path(sys.argv[1])
project_id = sys.argv[2]
scenario = sys.argv[3]
validator_name = sys.argv[4]

if scenario == "game":
    task_block = f"""- If the user asks for the standard text-adventure task, completion means:
  - write `game.py`, `game_manifest.json`, `walkthrough.txt`, and `README.md` in the current directory
  - keep the lantern behind all seeded puzzle gates and do not leave alternate exits or shortcuts that bypass a required seeded puzzle
  - run `python3 -m py_compile game.py`
  - run `python3 game.py < walkthrough.txt`
  - run `python3 {validator_name} --workspace . --shared-data ./.spiderweb/shared_data --output game_validation.json`
  - if a validation step fails, fix the project files and rerun only the failed step
  - if a file-write command times out or fails partway through, check exactly which target files landed and then rewrite only the missing or incomplete files cleanly
  - a `0` exit code from the walkthrough or validator means the step succeeded, even if stdout contains prompts like `> `
  - do not stop after partial outputs; finish when all required files exist and validation succeeds"""
    rewrite_rules = """- If `game.py` fails compile or walkthrough validation, delete and recreate `game.py` from scratch before retrying. If a regenerated `game.py` still fails compile, replace it with another full rewrite immediately instead of inspecting the broken file tail or attempting partial edits.
- Once `python3 -m py_compile game.py` succeeds, do not rewrite `game.py` again unless the walkthrough or validator exits non-zero.
- Treat `python3 game.py < walkthrough.txt` as successful when it exits with code `0`, even if stdout contains repeated input prompts such as `> `.
- Treat `python3 {validator_name} --workspace . --shared-data ./.spiderweb/shared_data --output game_validation.json` as successful when it exits with code `0`.""".replace("{validator_name}", validator_name)
else:
    task_block = f"""- If the user asks for the fast Spiderweb smoke task, completion means:
  - write `smoke_result.json`, `smoke_notes.txt`, and `README.md` in the current directory
  - include the exact shared-data input paths in `smoke_result.json`
  - keep the writes small and deterministic; this is a bootstrap/write smoke, not a game task
  - run `python3 {validator_name} --workspace . --shared-data ./.spiderweb/shared_data --output smoke_validation.json`
  - if validation fails, fix only the required output files and rerun the validator
  - finish when all required files exist and validation succeeds"""
    rewrite_rules = f"""- Treat `python3 {validator_name} --workspace . --shared-data ./.spiderweb/shared_data --output smoke_validation.json` as successful when it exits with code `0`."""

managed = f"""# AGENTS.md

<!-- SPIDERWEB:BEGIN MANAGED -->
## Spiderweb Workspace Rules

You are working inside a Spiderweb-mounted workspace.

Read order:
1. Read this `AGENTS.md` first and treat it as mandatory workspace guidance.
2. Treat the current working directory as the mounted project write root for this session. Then read only these required files, in order:
   - `./.spiderweb/protocol.json`
   - `./.spiderweb/agent_bootstrap_quickref.json`
   - `./.spiderweb/agent_bootstrap.json`
   - `./.spiderweb/shared_data/world_seed.json`
   - `./.spiderweb/shared_data/items_seed.json`
   - `./.spiderweb/shared_data/puzzle_seed.json`

Bootstrap rules:
- Prefer `./.spiderweb/services/*` paths over fallback local venom locations.
- If `./.spiderweb/services/home/control/ensure.json` succeeds once, treat home bootstrap as complete.
- If `agent_bootstrap_quickref.json` says `all_required_services_present=true`, do not keep probing `./.spiderweb/services/*` and move directly into implementation.
- If required services are missing, repair them through `./.spiderweb/services/mounts/control/bind.json` using the machine-readable bootstrap metadata.
- Keep project writes inside the current directory `.` unless the user explicitly asks otherwise.
- When creating or fixing a project file, rewrite the whole file in one pass instead of appending partial repair fragments.
- If you need to create multiple files, write them in separate commands so one long shell command cannot partially fail the whole set.
{rewrite_rules}
- Do not rerun either validation command through nested shell wrappers or alternate redirection forms unless the command itself failed.
- Preserve existing workspace support files such as `./{validator_name}`.
- Do not run broad scans such as `find`, `rg --files`, or recursive `ls` across `services/`, `projects/`, or `meta/`. Read only the exact listed files directly.
- Do not climb out of this directory with `..` to discover Spiderweb paths. Use the local Spiderweb-managed `./.spiderweb/` projection instead.

Namespace facts:
- Current working directory: `.`
- This file: `./AGENTS.md`
- Project write root: `.`
- Spiderweb-managed entrypoint root: `./.spiderweb`
- Shared data root: `./.spiderweb/shared_data`
- Service root: `./.spiderweb/services`
- Fallback local venom root: `./.spiderweb/local_venoms`
- Machine bootstrap metadata:
  - `./.spiderweb/agent_bootstrap_quickref.json`
  - `./.spiderweb/agent_bootstrap.json`
- Future Spiderweb-managed artifacts may appear under `./.spiderweb/`.

Task source:
- The concrete task comes from the user prompt, not from `TASK.md`.
- After the required reads above, begin implementation and validation immediately unless a required service is genuinely missing.
{task_block}

Do not:
- Invent old metadata field names when the current JSON already defines the contract.
- Create symlink hacks or duplicate bootstrap files outside `./.spiderweb/`.
<!-- SPIDERWEB:END MANAGED -->

## User Notes

Add any persistent workspace-specific instructions, goals, or missions below this heading.
"""

output_path.write_text(managed, encoding="utf-8")
PY
}

seed_agent_runtime_home() {
    mkdir -p \
        "$AGENT_HOME_TARGET_ROOT" \
        "$AGENT_HOME_TARGET_ROOT/.config" \
        "$AGENT_HOME_TARGET_ROOT/.cache" \
        "$AGENT_HOME_TARGET_ROOT/.local/share" \
        "$AGENT_HOME_TARGET_ROOT/.local/state" \
        "$AGENT_HOME_TARGET_ROOT/tmp"
}

setup_spiderweb_runtime_root() {
    cp -R "$ROOT_DIR/templates/." "$SPIDERWEB_RUNTIME_ROOT/templates/"
}

install_bridge_runtime() {
    local node_bin=""
    mkdir -p "$CODEX_BRIDGE_DIR"
    cp "$CODEX_BRIDGE_COMMON_SRC" "$CODEX_BRIDGE_COMMON"
    cp "$CODEX_BRIDGE_SHELL_SRC" "$CODEX_BRIDGE_SHELL"
    cp "$CODEX_BRIDGE_GIT_SRC" "$CODEX_BRIDGE_GIT"
    cp "$CODEX_STDIN_LAUNCHER_SRC" "$CODEX_STDIN_LAUNCHER"
    cp "$CODEX_BRIDGE_LSB_RELEASE_SRC" "$CODEX_BRIDGE_LSB_RELEASE"
    cp "$CODEX_BRIDGE_GETCONF_SRC" "$CODEX_BRIDGE_GETCONF"
    ln -sf "$(command -v python3)" "$CODEX_BRIDGE_PYTHON"
    node_bin="$(command -v node 2>/dev/null || command -v nodejs 2>/dev/null || true)"
    if [[ -z "$node_bin" ]]; then
        log_fail "node is required to run the pinned Codex CLI inside the isolated mounted environment"
        exit 1
    fi
    ln -sf "$node_bin" "$CODEX_BRIDGE_NODE"
    if command -v setsid >/dev/null 2>&1; then
        cat > "$CODEX_BRIDGE_SETSID" <<EOF
#!/usr/bin/env sh
exec "$(command -v setsid)" "\$@"
EOF
    else
        cat > "$CODEX_BRIDGE_SETSID" <<'EOF'
#!/usr/bin/env python3
import os
import sys

if len(sys.argv) < 2:
    raise SystemExit("usage: setsid <command> [args...]")

os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])
EOF
    fi
    chmod +x \
        "$CODEX_BRIDGE_COMMON" \
        "$CODEX_BRIDGE_SHELL" \
        "$CODEX_BRIDGE_GIT" \
        "$CODEX_STDIN_LAUNCHER" \
        "$CODEX_BRIDGE_SETSID" \
        "$CODEX_BRIDGE_LSB_RELEASE" \
        "$CODEX_BRIDGE_GETCONF"
    CODEX_EXEC_PATH="$CODEX_BRIDGE_DIR:$INSTALL_DIR:/usr/local/bin:/usr/bin:/bin"

    CODEX_ALLOWED_BRIDGE_EXECS=()
    CODEX_ALLOWED_BRIDGE_EXECS+=("$CODEX_STDIN_LAUNCHER")
    CODEX_ALLOWED_BRIDGE_EXECS+=("$CODEX_BRIDGE_PYTHON")
    CODEX_ALLOWED_BRIDGE_EXECS+=("$CODEX_BRIDGE_NODE")
    CODEX_ALLOWED_BRIDGE_EXECS+=("$CODEX_BRIDGE_SETSID")
    CODEX_ALLOWED_BRIDGE_EXECS+=("$CODEX_BRIDGE_LSB_RELEASE")
    CODEX_ALLOWED_BRIDGE_EXECS+=("$CODEX_BRIDGE_GETCONF")
    if [[ "$CODEX_ENABLE_TERMINAL_BRIDGE" == "1" ]]; then
        CODEX_ALLOWED_BRIDGE_EXECS+=("$CODEX_BRIDGE_SHELL")
    fi
    if [[ "$CODEX_ENABLE_GIT_BRIDGE" == "1" ]]; then
        CODEX_ALLOWED_BRIDGE_EXECS+=("$CODEX_BRIDGE_GIT")
    fi
}

prepare_mounted_codex_home() {
    mkdir -p \
        "$AGENT_HOME_TARGET_ROOT" \
        "$AGENT_HOME_TARGET_ROOT/.config" \
        "$AGENT_HOME_TARGET_ROOT/.cache" \
        "$AGENT_HOME_TARGET_ROOT/.local/share" \
        "$AGENT_HOME_TARGET_ROOT/.local/state" \
        "$AGENT_HOME_TARGET_ROOT/tmp"
}

write_mounted_codex_config() {
    local target_codex_dir="$AGENT_HOME_TARGET_ROOT/.codex"
    mkdir -p "$target_codex_dir"
    cat > "$target_codex_dir/config.toml" <<'EOF'
check_for_update_on_startup = false
project_doc_max_bytes = 0
project_root_markers = []
allow_login_shell = false

[skills.bundled]
enabled = false
EOF
}

sync_existing_login_into_mounted_home() {
    if [[ -z "$CODEX_HOME_DIR" || ! -d "$CODEX_HOME_DIR/.codex" ]]; then
        log_fail "mounted_login requested, but no .codex directory exists in CODEX_HOME_DIR"
        return 1
    fi
    rm -rf "$AGENT_HOME_TARGET_ROOT/.codex"
    mkdir -p "$AGENT_HOME_TARGET_ROOT/.codex"

    local source_codex_dir="$CODEX_HOME_DIR/.codex"
    local target_codex_dir="$AGENT_HOME_TARGET_ROOT/.codex"
    local copied_any=0
    local candidate
    for candidate in auth.json version.json; do
        if [[ -f "$source_codex_dir/$candidate" ]]; then
            cp "$source_codex_dir/$candidate" "$target_codex_dir/$candidate"
            copied_any=1
        fi
    done

    if [[ "$copied_any" != "1" ]]; then
        log_fail "mounted_login requested, but no usable Codex auth files were found under $source_codex_dir"
        return 1
    fi

    write_mounted_codex_config
}

resolve_candidate_codex_bin() {
    if [[ -n "$CODEX_BIN" ]]; then
        if [[ ! -x "$CODEX_BIN" ]]; then
            log_fail "CODEX_BIN is not executable: $CODEX_BIN"
            exit 1
        fi
        printf '%s\n' "$CODEX_BIN"
        return 0
    fi

    local on_path
    on_path="$(command -v codex 2>/dev/null || true)"
    if [[ -n "$on_path" ]]; then
        printf '%s\n' "$on_path"
        return 0
    fi

    if [[ -x "$HOST_HOME_DIR/.npm-global/bin/codex" ]]; then
        printf '%s\n' "$HOST_HOME_DIR/.npm-global/bin/codex"
        return 0
    fi

    return 1
}

codex_version_of() {
    local bin="$1"
    "$bin" --version 2>/dev/null | awk '{print $NF}' | tail -n1
}

install_pinned_codex() {
    require_bin npm
    mkdir -p "$CODEX_NPM_PREFIX"
    log_info "Installing pinned Codex CLI @openai/codex@$CODEX_CLI_VERSION into isolated prefix..."
    if ! npm install --no-fund --no-audit --prefix "$CODEX_NPM_PREFIX" "@openai/codex@$CODEX_CLI_VERSION" >"$CODEX_INSTALL_LOG" 2>&1; then
        log_fail "failed installing @openai/codex@$CODEX_CLI_VERSION"
        tail -n 120 "$CODEX_INSTALL_LOG" || true
        return 1
    fi

    CODEX_RESOLVED_BIN="$CODEX_NPM_PREFIX/node_modules/.bin/codex"
    if [[ ! -x "$CODEX_RESOLVED_BIN" ]]; then
        log_fail "isolated Codex installation did not produce an executable binary"
        return 1
    fi
    CODEX_RESOLVED_VERSION="$(codex_version_of "$CODEX_RESOLVED_BIN")"
    CODEX_LAUNCH_SOURCE="installed"
    return 0
}

ensure_codex_cli() {
    if [[ "$CODEX_MODE" == "manual" ]]; then
        return 0
    fi

    if [[ -n "$CODEX_BIN" ]]; then
        CODEX_RESOLVED_BIN="$CODEX_BIN"
        CODEX_RESOLVED_VERSION="$(codex_version_of "$CODEX_RESOLVED_BIN")"
        CODEX_LAUNCH_SOURCE="explicit"
        return 0
    fi

    local candidate=""
    local candidate_version=""
    candidate="$(resolve_candidate_codex_bin || true)"
    if [[ -n "$candidate" ]]; then
        candidate_version="$(codex_version_of "$candidate")"
    fi

    if [[ -n "$candidate" && "$candidate_version" == "$CODEX_CLI_VERSION" ]]; then
        CODEX_RESOLVED_BIN="$candidate"
        CODEX_RESOLVED_VERSION="$candidate_version"
        CODEX_LAUNCH_SOURCE="detected"
        return 0
    fi

    if [[ "$CODEX_INSTALL_IF_MISSING" == "1" ]]; then
        install_pinned_codex
        return $?
    fi

    if [[ -z "$candidate" ]]; then
        log_fail "no Codex CLI found and CODEX_INSTALL_IF_MISSING=0"
        return 1
    fi

    log_fail "found Codex CLI $candidate_version at $candidate, but expected $CODEX_CLI_VERSION and auto-install is disabled"
    return 1
}

configure_codex_env() {
    local auth_mode="$1"
    local home_dir="$2"
    local xdg_config_home="$CODEX_XDG_CONFIG_HOME"
    local xdg_cache_home="$CODEX_XDG_CACHE_HOME"
    local xdg_data_home="$CODEX_XDG_DATA_HOME"
    local xdg_state_home="$CODEX_XDG_STATE_HOME"
    local tmp_dir="$CODEX_RUNTIME_ROOT/tmp"

    if [[ "$auth_mode" == "api_key" || "$auth_mode" == "mounted_login" ]]; then
        xdg_config_home="$AGENT_HOME_TARGET_XDG_CONFIG"
        xdg_cache_home="$AGENT_HOME_TARGET_XDG_CACHE"
        xdg_data_home="$AGENT_HOME_TARGET_XDG_DATA"
        xdg_state_home="$AGENT_HOME_TARGET_XDG_STATE"
        tmp_dir="$AGENT_HOME_TARGET_TMP"
    fi

    mkdir -p "$tmp_dir" "$xdg_config_home" "$xdg_cache_home" "$xdg_data_home" "$xdg_state_home"

    CODEX_ENV_BASE=(
        env
        HOME="$home_dir"
        XDG_CONFIG_HOME="$xdg_config_home"
        XDG_CACHE_HOME="$xdg_cache_home"
        XDG_DATA_HOME="$xdg_data_home"
        XDG_STATE_HOME="$xdg_state_home"
        TMPDIR="$tmp_dir"
        PYTHONPYCACHEPREFIX="$tmp_dir/pycache"
        PATH="$CODEX_EXEC_PATH"
        PWD="$MOUNT_WORKSPACE_PATH"
        GIT_CEILING_DIRECTORIES="$MOUNT_POINT"
        GIT_DISCOVERY_ACROSS_FILESYSTEM=0
        GIT_CONFIG_NOSYSTEM=1
        GIT_CONFIG_GLOBAL=/dev/null
    )
    if [[ "$CODEX_ENABLE_TERMINAL_BRIDGE" == "1" ]]; then
        CODEX_ENV_BASE+=(
            SHELL="$CODEX_BRIDGE_SHELL"
            SPIDERWEB_TERMINAL_CREATE_PATH="$MOUNT_POINT/services/terminal/control/create.json"
            SPIDERWEB_TERMINAL_EXEC_PATH="$MOUNT_POINT/services/terminal/control/exec.json"
            SPIDERWEB_TERMINAL_CLOSE_PATH="$MOUNT_POINT/services/terminal/control/close.json"
            SPIDERWEB_TERMINAL_STATUS_PATH="$MOUNT_POINT/services/terminal/status.json"
            SPIDERWEB_TERMINAL_RESULT_PATH="$MOUNT_POINT/services/terminal/result.json"
            SPIDERWEB_TERMINAL_LOCK_PATH="$CODEX_RUNTIME_ROOT/terminal-bridge.lock"
            SPIDERWEB_TERMINAL_TIMEOUT_MS=120000
            SPIDERWEB_MOUNT_WORKSPACE_ROOT="$MOUNT_WORKSPACE_PATH"
            SPIDERWEB_HOST_WORKSPACE_ROOT="$WORKSPACE_EXPORT_ROOT"
            SPIDERWEB_NAMESPACE_WORKSPACE_ROOT=/nodes/local/fs
        )
    fi
    if [[ "$CODEX_ENABLE_GIT_BRIDGE" == "1" ]]; then
        CODEX_ENV_BASE+=(
            SPIDERWEB_GIT_STATUS_PATH="$MOUNT_POINT/services/git/status.json"
            SPIDERWEB_GIT_RESULT_PATH="$MOUNT_POINT/services/git/result.json"
            SPIDERWEB_GIT_STATUS_CONTROL_PATH="$MOUNT_POINT/services/git/control/status.json"
            SPIDERWEB_GIT_DIFF_RANGE_PATH="$MOUNT_POINT/services/git/control/diff_range.json"
            SPIDERWEB_GIT_LOCK_PATH="$CODEX_RUNTIME_ROOT/git-bridge.lock"
            SPIDERWEB_GIT_TIMEOUT_MS=30000
            SPIDERWEB_MOUNT_WORKSPACE_ROOT="$MOUNT_WORKSPACE_PATH"
            SPIDERWEB_NAMESPACE_WORKSPACE_ROOT=/nodes/local/fs
        )
    fi
}

existing_login_available() {
    if [[ -z "$CODEX_HOME_DIR" ]]; then
        return 1
    fi
    env HOME="$CODEX_HOME_DIR" "$CODEX_RESOLVED_BIN" login status >/dev/null 2>&1
}

mounted_login_available() {
    existing_login_available && [[ -d "$CODEX_HOME_DIR/.codex" ]]
}

setup_codex_auth() {
    if [[ "$CODEX_MODE" == "manual" ]]; then
        return 0
    fi

    local requested_mode="$CODEX_AUTH_MODE"
    local api_key="${!CODEX_API_KEY_ENV-}"

    case "$requested_mode" in
        auto)
            if [[ -n "$api_key" ]]; then
                requested_mode="api_key"
            elif mounted_login_available; then
                requested_mode="mounted_login"
            elif existing_login_available; then
                requested_mode="existing_login"
            else
                log_fail "no Codex auth available: set $CODEX_API_KEY_ENV or provide a working login in CODEX_HOME_DIR"
                return 1
            fi
            ;;
        api_key)
            if [[ -z "$api_key" ]]; then
                log_fail "CODEX_AUTH_MODE=api_key requires $CODEX_API_KEY_ENV"
                return 1
            fi
            ;;
        existing_login)
            if ! existing_login_available; then
                log_fail "CODEX_AUTH_MODE=existing_login requested, but no working login was found in CODEX_HOME_DIR"
                return 1
            fi
            ;;
        mounted_login)
            if ! mounted_login_available; then
                log_fail "CODEX_AUTH_MODE=mounted_login requested, but no working login with a .codex directory was found in CODEX_HOME_DIR"
                return 1
            fi
            ;;
        *)
            log_fail "unsupported CODEX_AUTH_MODE: $requested_mode"
            return 1
            ;;
    esac

    if [[ "$requested_mode" == "api_key" ]]; then
        prepare_mounted_codex_home
        CODEX_SELECTED_AUTH_MODE="api_key"
        CODEX_EFFECTIVE_HOME="$AGENT_HOME_TARGET_ROOT"
        configure_codex_env "$CODEX_SELECTED_AUTH_MODE" "$CODEX_EFFECTIVE_HOME"

        if ! printf '%s\n' "$api_key" | "${CODEX_ENV_BASE[@]}" "$CODEX_RESOLVED_BIN" login --with-api-key >"$CODEX_AUTH_LOG" 2>&1; then
            log_fail "failed authenticating Codex with API key"
            tail -n 120 "$CODEX_AUTH_LOG" || true
            return 1
        fi
    elif [[ "$requested_mode" == "mounted_login" ]]; then
        prepare_mounted_codex_home
        sync_existing_login_into_mounted_home
        CODEX_SELECTED_AUTH_MODE="mounted_login"
        CODEX_EFFECTIVE_HOME="$AGENT_HOME_TARGET_ROOT"
        configure_codex_env "$CODEX_SELECTED_AUTH_MODE" "$CODEX_EFFECTIVE_HOME"

        if ! "${CODEX_ENV_BASE[@]}" "$CODEX_RESOLVED_BIN" login status >"$CODEX_AUTH_LOG" 2>&1; then
            log_fail "Codex login status failed in mounted login mode"
            tail -n 120 "$CODEX_AUTH_LOG" || true
            return 1
        fi
    else
        CODEX_SELECTED_AUTH_MODE="existing_login"
        CODEX_EFFECTIVE_HOME="$CODEX_HOME_DIR"
        configure_codex_env "$CODEX_SELECTED_AUTH_MODE" "$CODEX_EFFECTIVE_HOME"

        if ! "${CODEX_ENV_BASE[@]}" "$CODEX_RESOLVED_BIN" login status >"$CODEX_AUTH_LOG" 2>&1; then
            log_fail "Codex login status failed in existing login mode"
            tail -n 120 "$CODEX_AUTH_LOG" || true
            return 1
        fi
    fi

    write_codex_runtime_snapshot
    return 0
}

default_codex_launch_cmd() {
    printf '%s' '{codex_bin} exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox --ephemeral --color never --add-dir {namespace_meta_dir} --add-dir {project_meta_dir} --add-dir {shared_data_dir} --add-dir {artifact_dir} -C {workspace_root} -o {artifact_dir}/codex_last_message.txt -'
}

render_codex_launch_command() {
    local artifact_dir="$OUTPUT_DIR/codex_artifacts"
    mkdir -p "$artifact_dir"

    local cmd="$CODEX_LAUNCH_CMD"
    if [[ -z "$cmd" ]]; then
        cmd="$(default_codex_launch_cmd)"
        CODEX_LAUNCH_SOURCE="${CODEX_LAUNCH_SOURCE:-default}"
    else
        CODEX_LAUNCH_SOURCE="${CODEX_LAUNCH_SOURCE:-custom}"
    fi

    cmd="${cmd//\{codex_bin\}/$(shell_quote "$CODEX_RESOLVED_BIN")}"
    cmd="${cmd//\{workspace_root\}/$(shell_quote "$MOUNT_WORKSPACE_PATH")}"
    cmd="${cmd//\{namespace_root\}/$(shell_quote "$MOUNT_POINT")}"
    cmd="${cmd//\{namespace_meta_dir\}/$(shell_quote "$MOUNT_POINT/meta")}"
    cmd="${cmd//\{project_meta_dir\}/$(shell_quote "$MOUNT_POINT/projects/$PROJECT_ID/meta")}"
    cmd="${cmd//\{shared_data_dir\}/$(shell_quote "$MOUNT_POINT/shared_data")}"
    cmd="${cmd//\{prompt_file\}/$(shell_quote "$PROMPT_FILE")}"
    cmd="${cmd//\{artifact_dir\}/$(shell_quote "$artifact_dir")}"
    cmd="$(inject_codex_cli_workarounds "$cmd")"

    write_codex_runtime_snapshot
    printf '%s' "$cmd"
}

progress_fingerprint() {
    python3 - "$CODEX_PROGRESS_WORKSPACE_PATH" "$CODEX_STDOUT_LOG" "$CODEX_STDERR_LOG" "$CODEX_PTY_LOG" "$WORKSPACE_VALIDATOR_BASENAME" <<'PY'
from pathlib import Path
import sys
import os

workspace = Path(sys.argv[1])
stdout_log = Path(sys.argv[2])
stderr_log = Path(sys.argv[3])
pty_log = Path(sys.argv[4])
skip_files = {"AGENTS.md", sys.argv[5]}

count = 0
latest = 0
if workspace.exists():
    for root, dirs, files in os.walk(workspace, topdown=True):
        dirs[:] = [name for name in dirs if name != ".spiderweb"]
        root_path = Path(root)
        for name in dirs:
            if name in skip_files:
                continue
            entry = root_path / name
            try:
                stat = entry.stat()
            except FileNotFoundError:
                continue
            count += 1
            latest = max(latest, stat.st_mtime_ns)
        for name in files:
            if name in skip_files:
                continue
            entry = root_path / name
            try:
                stat = entry.stat()
            except FileNotFoundError:
                continue
            count += 1
            latest = max(latest, stat.st_mtime_ns)

stdout_size = stdout_log.stat().st_size if stdout_log.exists() else 0
stderr_size = stderr_log.stat().st_size if stderr_log.exists() else 0
pty_size = pty_log.stat().st_size if pty_log.exists() else 0
print(f"{count}:{latest}:{stdout_size}:{stderr_size}:{pty_size}")
PY
}

kill_process_group() {
    local pgid="$1"
    kill -TERM -- "-$pgid" >/dev/null 2>&1 || true
    sleep 1
    kill -KILL -- "-$pgid" >/dev/null 2>&1 || true
}

monitor_codex_process() {
    local runner_pid="$1"
    local start_ts last_progress_ts now_ts
    local last_fingerprint current_fingerprint

    start_ts="$(date +%s)"
    last_progress_ts="$start_ts"
    last_fingerprint=""

    while kill -0 "$runner_pid" >/dev/null 2>&1; do
        now_ts="$(date +%s)"
        current_fingerprint="$(progress_fingerprint)"
        if [[ "$current_fingerprint" != "$last_fingerprint" ]]; then
            last_fingerprint="$current_fingerprint"
            last_progress_ts="$now_ts"
        fi
        observe_codex_progress

        if (( CODEX_TIMEOUT_SECONDS > 0 && now_ts - start_ts >= CODEX_TIMEOUT_SECONDS )); then
            CODEX_FAILURE_REASON="codex_timeout_after_${CODEX_TIMEOUT_SECONDS}s"
            kill_process_group "$runner_pid"
            break
        fi
        if (( CODEX_IDLE_TIMEOUT_SECONDS > 0 && now_ts - last_progress_ts >= CODEX_IDLE_TIMEOUT_SECONDS )); then
            CODEX_FAILURE_REASON="codex_idle_after_${CODEX_IDLE_TIMEOUT_SECONDS}s"
            kill_process_group "$runner_pid"
            break
        fi
        sleep 2
    done
}

summarize_codex_events() {
    python3 "$CODEX_EVENT_SUMMARY_SRC" \
        --events-log "$CODEX_STDOUT_LOG" \
        --stderr-log "$CODEX_STDERR_LOG" \
        --transcript-log "$CODEX_PTY_LOG" \
        --output "$CODEX_EVENT_SUMMARY"
}

run_live_codex() {
    case "$TRACE_BACKEND" in
        strace)
            require_bin strace
            ;;
        none)
            ;;
        *)
            log_fail "unsupported TRACE_BACKEND: $TRACE_BACKEND"
            exit 1
            ;;
    esac
    if [[ "$CODEX_USE_PTY" == "1" ]]; then
        require_bin script
    fi

    local cmd
    cmd="$(render_codex_launch_command)"
    CODEX_RUN_STATE="running"
    CODEX_FAILURE_REASON=""
    CODEX_LAUNCH_STARTED_AT_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    write_codex_progress_timeline

    : >"$CODEX_STDOUT_LOG"
    : >"$CODEX_STDERR_LOG"
    rm -f "$CODEX_PTY_LOG" "$CODEX_EVENT_SUMMARY"

    local quoted_cmd
    quoted_cmd="$(shell_quote "$cmd")"
    local codex_target_shell=""
    if [[ "$CODEX_ENABLE_TERMINAL_BRIDGE" == "1" ]]; then
        codex_target_shell="$CODEX_BRIDGE_SHELL"
    fi

    if [[ "$CODEX_USE_PTY" == "1" ]]; then
        local pty_inner_cmd
        pty_inner_cmd="$(shell_quote "$CODEX_STDIN_LAUNCHER") $(shell_quote "$PROMPT_FILE") $quoted_cmd"
        local quoted_pty_inner_cmd
        quoted_pty_inner_cmd="$(shell_quote "$pty_inner_cmd")"
        local -a pty_launch_cmd
        if is_macos_native_variant; then
            pty_launch_cmd=(script -q "$CODEX_PTY_LOG" /bin/bash -lc "$pty_inner_cmd")
        else
            pty_launch_cmd=(script -qefc "bash -lc $quoted_pty_inner_cmd" "$CODEX_PTY_LOG")
        fi
        if [[ "$TRACE_BACKEND" == "strace" ]]; then
            (
                cd "$MOUNT_WORKSPACE_PATH"
                "${CODEX_ENV_BASE[@]}" \
                    SHELL=/bin/bash \
                    CODEX_STDIN_LAUNCHER_SHELL=/bin/bash \
                    CODEX_TARGET_SHELL="$codex_target_shell" \
                    GIT_DIR= \
                    GIT_WORK_TREE= \
                    "$CODEX_BRIDGE_SETSID" \
                    strace -ff -s 4096 -e trace=%file,%process -o "$STRACE_PREFIX" \
                    "${pty_launch_cmd[@]}" >"$CODEX_STDOUT_LOG" 2>"$CODEX_STDERR_LOG"
            ) &
        else
            (
                cd "$MOUNT_WORKSPACE_PATH"
                "${CODEX_ENV_BASE[@]}" \
                    SHELL=/bin/bash \
                    CODEX_STDIN_LAUNCHER_SHELL=/bin/bash \
                    CODEX_TARGET_SHELL="$codex_target_shell" \
                    GIT_DIR= \
                    GIT_WORK_TREE= \
                    "$CODEX_BRIDGE_SETSID" \
                    "${pty_launch_cmd[@]}" >"$CODEX_STDOUT_LOG" 2>"$CODEX_STDERR_LOG"
            ) &
        fi
    else
        if [[ "$TRACE_BACKEND" == "strace" ]]; then
            (
                cd "$MOUNT_WORKSPACE_PATH"
                "${CODEX_ENV_BASE[@]}" \
                    SHELL=/bin/bash \
                    CODEX_STDIN_LAUNCHER_SHELL=/bin/bash \
                    CODEX_TARGET_SHELL="$codex_target_shell" \
                    GIT_DIR= \
                    GIT_WORK_TREE= \
                    "$CODEX_BRIDGE_SETSID" \
                    strace -ff -s 4096 -e trace=%file,%process -o "$STRACE_PREFIX" \
                    "$CODEX_STDIN_LAUNCHER" "$PROMPT_FILE" "$cmd" >"$CODEX_STDOUT_LOG" 2>"$CODEX_STDERR_LOG"
            ) &
        else
            (
                cd "$MOUNT_WORKSPACE_PATH"
                "${CODEX_ENV_BASE[@]}" \
                    SHELL=/bin/bash \
                    CODEX_STDIN_LAUNCHER_SHELL=/bin/bash \
                    CODEX_TARGET_SHELL="$codex_target_shell" \
                    GIT_DIR= \
                    GIT_WORK_TREE= \
                    "$CODEX_BRIDGE_SETSID" \
                    "$CODEX_STDIN_LAUNCHER" "$PROMPT_FILE" "$cmd" >"$CODEX_STDOUT_LOG" 2>"$CODEX_STDERR_LOG"
            ) &
        fi
    fi
    local runner_pid="$!"

    monitor_codex_process "$runner_pid"

    set +e
    wait "$runner_pid"
    CODEX_EXIT_CODE=$?
    set -e
    observe_codex_progress
    summarize_codex_events

    if [[ "$CODEX_EXIT_CODE" -ne 0 ]]; then
        local failure_reason="${CODEX_FAILURE_REASON:-codex_exit_$CODEX_EXIT_CODE}"
        write_handoff_bundle "$failure_reason"
        write_skip_outputs "$failure_reason"
        log_fail "Codex command failed with exit code $CODEX_EXIT_CODE"
        tail -n 120 "$CODEX_STDERR_LOG" || true
        exit 1
    fi

    CODEX_RUN_STATE="completed"
}

run_spiderweb_installer() {
    local install_source="$1"
    local release_url="$2"
    local release_version="$3"

    if [[ "$install_source" == "release" && -z "$release_version" ]]; then
        log_fail "SPIDERWEB_RELEASE_VERSION is required when SPIDERWEB_INSTALL_SOURCE=release"
        return 1
    fi

    HOME="$TEMP_HOME" \
    PATH="$PATH" \
    SPIDERWEB_NON_INTERACTIVE=1 \
    SPIDERWEB_INSTALL_DIR="$INSTALL_DIR" \
    SPIDERWEB_REPO_DIR="$ROOT_DIR" \
    SPIDERWEB_INSTALL_ZSS=0 \
    SPIDERWEB_INSTALL_SYSTEMD=0 \
    SPIDERWEB_INSTALL_SOURCE="$install_source" \
    SPIDERWEB_RELEASE_ARCHIVE_URL="$release_url" \
    SPIDERWEB_RELEASE_ARCHIVE_SHA256="$SPIDERWEB_RELEASE_ARCHIVE_SHA256" \
    SPIDERWEB_RELEASE_VERSION="$release_version" \
    SPIDERWEB_START_AFTER_INSTALL=0 \
    bash "$ROOT_DIR/install.sh" >"$INSTALL_LOG" 2>&1
}

first_missing_spiderweb_bin_in() {
    local bin_dir="$1"
    local bin
    for bin in "${required_spiderweb_bins[@]}"; do
        if [[ ! -x "$bin_dir/$bin" ]]; then
            printf '%s' "$bin"
            return 0
        fi
    done
    return 1
}

clear_installed_spiderweb_bins() {
    local bin
    for bin in "${required_spiderweb_bins[@]}"; do
        rm -f "$INSTALL_DIR/$bin"
    done
}

install_spiderweb_harness_binaries() {
    if is_macos_native_variant; then
        log_info "Building Spiderweb binaries from the current checkout for native macOS E2E..."
        (
            cd "$ROOT_DIR"
            zig build
        ) >"$INSTALL_LOG" 2>&1 || {
            tail -n 200 "$INSTALL_LOG" || true
            return 1
        }

        local missing_bin=""
        if missing_bin="$(first_missing_spiderweb_bin_in "$REPO_BUILD_INSTALL_DIR")"; then
            log_fail "repo build did not produce expected binary in zig-out/bin: $missing_bin"
            tail -n 200 "$INSTALL_LOG" || true
            return 1
        fi

        if [[ ! -x "$SIGNED_APP_RESOURCE_DIR/spiderweb-config" ]]; then
            log_fail "installed Spiderweb app is missing signed FSKit resources"
            tail -n 200 "$INSTALL_LOG" || true
            return 1
        fi

        log_pass "repo build completed and native runtime will use current checkout binaries with signed app FSKit resources"
        return 0
    fi

    local requested_source="$SPIDERWEB_INSTALL_SOURCE"

    log_info "Running installer into isolated HOME..."
    if ! run_spiderweb_installer "$requested_source" "$SPIDERWEB_RELEASE_ARCHIVE_URL" "$SPIDERWEB_RELEASE_VERSION"; then
        if [[ "$requested_source" != "auto" ]]; then
            tail -n 200 "$INSTALL_LOG" || true
            return 1
        fi
        log_info "Auto installer path failed; retrying with source build for current checkout..."
        clear_installed_spiderweb_bins
        run_spiderweb_installer "source" "" "" || {
            tail -n 200 "$INSTALL_LOG" || true
            return 1
        }
    fi

    local missing_bin=""
    if missing_bin="$(first_missing_spiderweb_bin_in "$INSTALL_DIR")"; then
        if [[ "$requested_source" != "auto" ]]; then
            log_fail "installer did not produce expected binary: $missing_bin"
            tail -n 200 "$INSTALL_LOG" || true
            return 1
        fi

        log_info "Auto installer result is missing '$missing_bin'; retrying with source build for current checkout..."
        clear_installed_spiderweb_bins
        run_spiderweb_installer "source" "" "" || {
            tail -n 200 "$INSTALL_LOG" || true
            return 1
        }

        if missing_bin="$(first_missing_spiderweb_bin_in "$INSTALL_DIR")"; then
            log_fail "source installer still did not produce expected binary: $missing_bin"
            tail -n 200 "$INSTALL_LOG" || true
            return 1
        fi
    fi

    log_pass "installer completed and produced required binaries"
}

ensure_macos_native_mount_ready() {
    if ! is_macos_native_variant; then
        return 0
    fi

    local status_output=""
    status_output="$("$INSTALL_DIR/spiderweb-config" config fs-extension-status 2>&1)" || {
        printf '%s\n' "$status_output" >>"$INSTALL_LOG"
        log_fail "could not read native FS extension status"
        return 1
    }
    printf '%s\n' "$status_output" >>"$INSTALL_LOG"

    if ! grep -q 'ready:[[:space:]]*yes' <<<"$status_output"; then
        log_fail "native macOS FS extension is not ready; run install-fs-extension for the current build before rerunning the harness"
        return 1
    fi
}

install_spiderweb_harness_binaries
ensure_macos_native_mount_ready

setup_spiderweb_runtime_root
cp "$ASSET_DIR/shared_data/"* "$REMOTE_EXPORT_ROOT/"
write_workspace_seed_files
seed_agent_runtime_home
log_pass "seeded a clean local workspace export root"

cat > "$SPIDERWEB_CONFIG_FILE" <<EOF
{
  "provider": {
    "name": "openai",
    "model": "gpt-4o-mini"
  },
  "runtime": {
    "default_agent_id": "default",
    "state_directory": "$LTM_DIR",
    "state_db_filename": "runtime-state.db",
    "spider_web_root": "$SPIDERWEB_RUNTIME_ROOT",
    "local_node": {
      "export_path": "$WORKSPACE_EXPORT_ROOT"
    }
  }
}
EOF

log_info "Starting Spiderweb on $CONTROL_URL ..."
(
    cd "$ROOT_DIR"
    HOME="$TEMP_HOME" \
    SPIDERWEB_CONFIG="$SPIDERWEB_CONFIG_FILE" \
    "$INSTALL_DIR/spiderweb" \
    --bind "$BIND_ADDR" \
    --port "$SPIDERWEB_PORT" >>"$SPIDERWEB_LOG" 2>&1
) &
SPIDERWEB_PID="$!"

if ! wait_for_control_ready; then
    log_fail "Spiderweb did not become ready"
    tail -n 200 "$SPIDERWEB_LOG" || true
    exit 1
fi
log_pass "Spiderweb control plane is ready"

LOCAL_INVITE_RESP="$(control_call node_invite_create)"
LOCAL_INVITE_TOKEN="$(json_field "$LOCAL_INVITE_RESP" '.payload.invite_token')"

log_info "Starting clean local workspace node ..."
HOME="$TEMP_HOME" \
"$INSTALL_DIR/spiderweb-fs-node" \
    --bind "$BIND_ADDR" \
    --port "$LOCAL_WORKSPACE_NODE_PORT" \
    --export "workspace=$WORKSPACE_EXPORT_ROOT:rw" \
    --control-url "$CONTROL_URL" \
    --control-auth-token "$SPIDERWEB_AUTH_TOKEN" \
    --pair-mode invite \
    --invite-token "$LOCAL_INVITE_TOKEN" \
    --node-name "codex-local-workspace-node" \
    --state-file "$TEST_TMP_DIR/local-workspace-node-state.json" >"$LOCAL_WORKSPACE_NODE_LOG" 2>&1 &
LOCAL_WORKSPACE_NODE_PID="$!"

if ! wait_for_node_join "codex-local-workspace-node" LOCAL_WORKSPACE_NODE_ID; then
    log_fail "clean local workspace node did not join Spiderweb"
    tail -n 200 "$LOCAL_WORKSPACE_NODE_LOG" || true
    exit 1
fi
log_pass "clean local workspace node joined as $LOCAL_WORKSPACE_NODE_ID"

REMOTE_INVITE_RESP="$(control_call node_invite_create)"
REMOTE_INVITE_TOKEN="$(json_field "$REMOTE_INVITE_RESP" '.payload.invite_token')"

log_info "Starting standalone remote shared-data node ..."
HOME="$TEMP_HOME" \
"$INSTALL_DIR/spiderweb-fs-node" \
    --bind "$BIND_ADDR" \
    --port "$REMOTE_NODE_PORT" \
    --export "shared=$REMOTE_EXPORT_ROOT:rw" \
    --control-url "$CONTROL_URL" \
    --control-auth-token "$SPIDERWEB_AUTH_TOKEN" \
    --pair-mode invite \
    --invite-token "$REMOTE_INVITE_TOKEN" \
    --node-name "codex-remote-node" \
    --state-file "$TEST_TMP_DIR/remote-node-state.json" >"$REMOTE_NODE_LOG" 2>&1 &
REMOTE_NODE_PID="$!"

if ! wait_for_node_join "codex-remote-node" REMOTE_NODE_ID; then
    log_fail "standalone remote node did not join Spiderweb"
    tail -n 200 "$REMOTE_NODE_LOG" || true
    exit 1
fi
log_pass "remote shared-data node joined as $REMOTE_NODE_ID"

PROJECT_UP_PAYLOAD="$(jq -cn \
    --arg name "$PROJECT_UP_NAME" \
    --arg vision "$PROJECT_UP_VISION" \
    --arg template_id "dev" \
    --arg local_node "$LOCAL_WORKSPACE_NODE_ID" \
    --arg remote_node "$REMOTE_NODE_ID" \
    '{
        name: $name,
        vision: $vision,
        template_id: $template_id,
        activate: true,
        desired_mounts: [
            {mount_path: "/nodes/local/fs", node_id: $local_node, export_name: "workspace"},
            {mount_path: "/shared_data", node_id: $remote_node, export_name: "shared"}
        ]
    }'
)"
PROJECT_UP_RESP="$(control_call project_up "$PROJECT_UP_PAYLOAD")"
PROJECT_ID="$(json_field "$PROJECT_UP_RESP" '.payload.project_id')"
PROJECT_TOKEN="$(jq -r '.payload.project_token // empty' <<<"$PROJECT_UP_RESP")"
printf '%s\n' "$PROJECT_UP_RESP" > "$OUTPUT_DIR/snapshots/project_up.json"
write_workspace_agents_file
assert_seeded_workspace_layout "$WORKSPACE_EXPORT_ROOT"
log_pass "seeded workspace AGENTS contract for project $PROJECT_ID"

if ! wait_for_workspace_mounts; then
    log_fail "workspace mounts did not converge for /nodes/local/fs and /shared_data"
    exit 1
fi
log_pass "workspace topology converged for project $PROJECT_ID"

log_info "Mounting namespace ..."
MOUNT_BACKEND_ARGS=()
MOUNT_HOME="$TEMP_HOME"
if is_macos_native_variant; then
    MOUNT_BACKEND_ARGS+=(--mount-backend native)
    MOUNT_HOME="$HOST_HOME_DIR"
fi
HOME="$MOUNT_HOME" \
"$INSTALL_DIR/spiderweb-fs-mount" \
    --namespace-url "$CONTROL_URL" \
    --workspace-id "$PROJECT_ID" \
    --auth-token "$SPIDERWEB_AUTH_TOKEN" \
    --agent-id codex \
    --session-key e2e \
    "${MOUNT_BACKEND_ARGS[@]}" \
    mount "$MOUNT_POINT" >"$MOUNT_LOG" 2>&1 &
MOUNT_PID="$!"

if ! wait_for_namespace_mount; then
    log_fail "namespace mount did not become ready"
    tail -n 200 "$MOUNT_LOG" || true
    exit 1
fi
if ! probe_directory_listing_quick "$MOUNT_WORKSPACE_PATH"; then
    log_fail "namespace mount root is present but workspace listing is not ready"
    tail -n 200 "$MOUNT_LOG" || true
    exit 1
fi
log_pass "namespace mount is ready"

cp "$MOUNT_POINT/meta/protocol.json" "$OUTPUT_DIR/snapshots/protocol.json"
cp "$MOUNT_POINT/projects/$PROJECT_ID/meta/agent_bootstrap_quickref.json" "$OUTPUT_DIR/snapshots/agent_bootstrap_quickref.json"
cp "$MOUNT_POINT/projects/$PROJECT_ID/meta/mounted_services.json" "$OUTPUT_DIR/snapshots/mounted_services.json"
cp "$MOUNT_POINT/projects/$PROJECT_ID/meta/workspace_status.json" "$OUTPUT_DIR/snapshots/workspace_status.json"
cp "$MOUNT_POINT/projects/$PROJECT_ID/meta/venom_packages.json" "$OUTPUT_DIR/snapshots/venom_packages.json"
cp "$MOUNT_POINT/projects/$PROJECT_ID/meta/agent_bootstrap.json" "$OUTPUT_DIR/snapshots/agent_bootstrap.json"
cp "$MOUNT_WORKSPACE_PATH/AGENTS.md" "$OUTPUT_DIR/snapshots/AGENTS.md"

if [[ ! -d "$MOUNT_WORKSPACE_PATH" || ! -d "$MOUNT_POINT/shared_data" ]]; then
    log_fail "mounted namespace is missing /nodes/local/fs or /shared_data"
    exit 1
fi
assert_attached_workspace_layout "$MOUNT_WORKSPACE_PATH"
log_pass "preflight discovery files, mount paths, and clean workspace layout are present"

render_prompt
install_bridge_runtime

if [[ "$CODEX_MODE" == "manual" ]]; then
    write_handoff_bundle "manual_mode_requested"
    write_skip_outputs "manual_mode_requested"
    log_info "manual handoff bundle written to $HANDOFF_DIR"
    exit "$MANUAL_EXIT_CODE"
fi

if ! ensure_codex_cli; then
    if [[ "$CODEX_MODE" == "auto" ]]; then
        write_handoff_bundle "codex_cli_unavailable"
        write_skip_outputs "codex_cli_unavailable"
        log_info "auto mode fell back to handoff because Codex CLI could not be prepared"
        exit "$MANUAL_EXIT_CODE"
    fi
    exit 1
fi
log_pass "Codex CLI prepared at $CODEX_RESOLVED_BIN ($CODEX_RESOLVED_VERSION)"

if ! setup_codex_auth; then
    if [[ "$CODEX_MODE" == "auto" ]]; then
        write_handoff_bundle "codex_auth_unavailable"
        write_skip_outputs "codex_auth_unavailable"
        log_info "auto mode fell back to handoff because Codex auth could not be prepared"
        exit "$MANUAL_EXIT_CODE"
    fi
    exit 1
fi
log_pass "Codex auth prepared using $CODEX_SELECTED_AUTH_MODE"

run_live_codex

VALIDATION_STARTED_AT_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
write_codex_progress_timeline
python3 "$MOUNT_WORKSPACE_PATH/$WORKSPACE_VALIDATOR_BASENAME" \
    --workspace "$MOUNT_WORKSPACE_PATH" \
    --shared-data "$MOUNT_POINT/shared_data" \
    --output "$VALIDATION_OUTPUT"

build_usage_report

if ! jq -e '.ok == true' "$VALIDATION_OUTPUT" >/dev/null 2>&1; then
    write_handoff_bundle "${SCENARIO_NAME}_validation_failed"
    log_fail "$SCENARIO_NAME validation failed"
    cat "$VALIDATION_OUTPUT"
    exit 1
fi

if ! jq -e '.reliability_ok == true' "$USAGE_JSON" >/dev/null 2>&1; then
    write_handoff_bundle "usage_reliability_failed"
    log_fail "usage report detected disallowed writes outside the mounted workspace/runtime allowlist"
    cat "$USAGE_JSON"
    exit 1
fi

if ! jq -e '.workspace_bootstrap_ok == true' "$USAGE_JSON" >/dev/null 2>&1; then
    write_handoff_bundle "workspace_bootstrap_failed"
    log_fail "external agent did not complete the required in-workspace bootstrap contract"
    cat "$USAGE_JSON"
    exit 1
fi

if ! jq -e '.machine_independence_ok == true' "$USAGE_JSON" >/dev/null 2>&1; then
    log_info "run passed reliability and workspace bootstrap, but machine-independence gaps are still present"
fi

log_pass "external Codex workspace scenario completed successfully"
