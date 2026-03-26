#!/bin/bash
# Automated installer smoke test for Spiderweb.
# Usage: ./test-env/test-install.sh [auto|release|source]

set -euo pipefail

INSTALL_MODE="${1:-auto}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

require_cmd() {
    local cmd="$1"
    if command -v "$cmd" >/dev/null 2>&1; then
        log_success "$cmd found"
    else
        log_error "$cmd not found"
        exit 1
    fi
}

assert_file_contains() {
    local file="$1"
    local needle="$2"
    if grep -Fq -- "$needle" "$file"; then
        return 0
    fi
    log_error "Expected to find '$needle' in $file"
    cat "$file"
    exit 1
}

json_query_first() {
    local file="$1"
    local filter="$2"
    jq -r "$filter" "$file" | awk 'NF { print; exit }'
}

run_control_op() {
    local output_file="$1"
    local operation="$2"
    local payload="${3:-}"
    (
        cd "$RUNTIME_CWD"
        if [[ -n "$payload" ]]; then
            HOME="$TEST_HOME" PATH="$INSTALL_DIR:$PATH" \
                "$INSTALL_DIR/spiderweb-control" \
                --url "ws://127.0.0.1:${SERVER_PORT}/" \
                --auth-token "$access_token" \
                "$operation" \
                "$payload" >"$output_file"
        else
            HOME="$TEST_HOME" PATH="$INSTALL_DIR:$PATH" \
                "$INSTALL_DIR/spiderweb-control" \
                --url "ws://127.0.0.1:${SERVER_PORT}/" \
                --auth-token "$access_token" \
                "$operation" >"$output_file"
        fi
    )
}

cleanup() {
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "=========================================="
echo "Spiderweb Installer Smoke Test"
echo "=========================================="
echo "Install mode: $INSTALL_MODE"
echo "=========================================="
echo ""

case "$INSTALL_MODE" in
    auto|release|source)
        ;;
    *)
        log_error "Install mode must be one of: auto, release, source"
        exit 1
        ;;
esac

log_info "Checking host prerequisites..."
require_cmd curl
require_cmd jq
require_cmd git
require_cmd sqlite3
require_cmd bwrap
require_cmd fusermount3
if [[ "$INSTALL_MODE" == "source" ]]; then
    require_cmd zig
fi

if [[ "$OSTYPE" == "linux-gnu"* ]] || [[ -f /etc/debian_version ]]; then
    log_success "Linux environment detected"
else
    log_warn "Non-Debian Linux detected; installer may still work"
fi

TEST_ROOT="$(mktemp -d /tmp/spiderweb-install-test.XXXXXX)"
TEST_HOME="$TEST_ROOT/home"
INSTALL_DIR="$TEST_HOME/.local/bin"
REPO_DIR="$TEST_HOME/.local/share/ziggy-spiderweb"
RUNTIME_CWD="$TEST_ROOT/runtime"
WORKSPACE_ROOT="$TEST_ROOT/workspace"
STATE_DIR="$RUNTIME_CWD/.spiderweb-state"
SERVER_PORT="${SPIDERWEB_TEST_PORT:-28790}"
INSTALL_LOG="$TEST_ROOT/install.log"
SERVER_LOG="$TEST_ROOT/server.log"

mkdir -p "$TEST_HOME" "$RUNTIME_CWD" "$WORKSPACE_ROOT/agents"

log_info "Running install.sh in isolated HOME: $TEST_HOME"
(
    cd "$REPO_ROOT"
    for maybe_empty_var in SPIDERWEB_GIT_REF SPIDERWEB_REPO_DIR SPIDERWEB_REPO_URL SPIDERWEB_RELEASE_ARCHIVE_URL SPIDERWEB_RELEASE_VERSION; do
        if [[ -z "${!maybe_empty_var:-}" ]]; then
            unset "$maybe_empty_var"
        fi
    done
    export HOME="$TEST_HOME"
    export PATH="$INSTALL_DIR:$PATH"
    export SPIDERWEB_NON_INTERACTIVE=1
    export SPIDERWEB_INSTALL_SOURCE="$INSTALL_MODE"
    export SPIDERWEB_INSTALL_ZSS=0
    export SPIDERWEB_INSTALL_SYSTEMD=0
    export SPIDERWEB_START_AFTER_INSTALL=0
    if [[ "$INSTALL_MODE" == "source" ]]; then
        export SPIDERWEB_REPO_DIR="$REPO_ROOT"
    elif [[ "$INSTALL_MODE" == "release" && -z "${SPIDERWEB_RELEASE_ARCHIVE_URL:-}" ]]; then
        case "$(uname -m)" in
            x86_64|amd64)
                export SPIDERWEB_RELEASE_ARCHIVE_URL="https://github.com/DeanoC/Spiderweb/releases/latest/download/spiderweb-linux-x86_64.tar.gz"
                export SPIDERWEB_RELEASE_VERSION="latest"
                ;;
            *)
                log_error "Release mode needs SPIDERWEB_RELEASE_ARCHIVE_URL on unsupported architecture $(uname -m)"
                exit 1
                ;;
        esac
    fi
    bash ./install.sh
) >"$INSTALL_LOG" 2>&1

cat "$INSTALL_LOG"

for bin in spiderweb spiderweb-config spiderweb-control spiderweb-fs-mount spiderweb-fs-node spiderweb-local-node; do
    if [[ -x "$INSTALL_DIR/$bin" ]]; then
        log_success "Installed binary present: $bin"
    else
        log_error "Missing installed binary: $INSTALL_DIR/$bin"
        exit 1
    fi
done

installed_bundle_release="$(cd "$(dirname "$INSTALL_DIR")" && pwd)/share/spidervenoms/bundles/managed-local/release.json"
if [[ -f "$installed_bundle_release" ]]; then
    log_success "Installed managed bundle present: $installed_bundle_release"
else
    log_error "Missing installed managed bundle: $installed_bundle_release"
    exit 1
fi

installed_templates_dir="$(cd "$(dirname "$INSTALL_DIR")" && pwd)/share/spiderweb/templates"
if [[ -d "$installed_templates_dir" ]]; then
    log_success "Installed runtime templates present: $installed_templates_dir"
else
    log_error "Missing installed runtime templates: $installed_templates_dir"
    exit 1
fi

resolved_source="$(sed -n 's/^Install source: //p' "$INSTALL_LOG" | tail -n1)"
if [[ -z "$resolved_source" ]]; then
    log_error "Could not determine resolved install source from installer output"
    exit 1
fi
log_success "Installer resolved to: $resolved_source"

if [[ "$INSTALL_MODE" == "auto" ]] && [[ "$(uname -m)" == "x86_64" ]] && [[ "$resolved_source" != "release" ]]; then
    log_error "Expected auto mode to prefer release on x86_64, got: $resolved_source"
    exit 1
fi

log_info "Verifying installed CLIs respond..."
(
    cd "$RUNTIME_CWD"
    "$INSTALL_DIR/spiderweb-config" >/tmp/spiderweb-config-usage.txt 2>&1 || true
    "$INSTALL_DIR/spiderweb-control" >/tmp/spiderweb-control-usage.txt 2>&1 || true
    "$INSTALL_DIR/spiderweb-fs-mount" >/tmp/spiderweb-fs-mount-usage.txt 2>&1 || true
)
head -n 5 /tmp/spiderweb-config-usage.txt
head -n 5 /tmp/spiderweb-control-usage.txt
head -n 5 /tmp/spiderweb-fs-mount-usage.txt

log_info "Configuring installed runtime to use only installed assets..."
CONFIG_PATH="$(
    cd "$RUNTIME_CWD" &&
    HOME="$TEST_HOME" PATH="$INSTALL_DIR:$PATH" "$INSTALL_DIR/spiderweb-config" config path
)"
if [[ ! -f "$CONFIG_PATH" ]]; then
    log_error "Could not resolve Spiderweb config path"
    exit 1
fi
tmp_config_path="$TEST_ROOT/config.json"
test_registry_source_url="${SPIDERWEB_TEST_REGISTRY_SOURCE_URL:-}"
if [[ -n "$test_registry_source_url" ]]; then
    log_info "Overriding registry source for smoke: $test_registry_source_url"
fi
jq \
    --arg bind "127.0.0.1" \
    --argjson port "$SERVER_PORT" \
    --arg spider_root "$WORKSPACE_ROOT" \
    --arg state_dir "$STATE_DIR" \
    --arg assets_dir "$installed_templates_dir" \
    --arg bundle_release "$installed_bundle_release" \
    --arg registry_source "$test_registry_source_url" \
    '
    .server.bind = $bind |
    .server.port = $port |
    .runtime.spider_web_root = $spider_root |
    .runtime.state_directory = $state_dir |
    .runtime.assets_dir = $assets_dir |
    .runtime.local_node.bundle_release_path = $bundle_release |
    (if $registry_source != "" then
        .runtime.venom_registry.enabled = true |
        .runtime.venom_registry.source_url = $registry_source |
        .runtime.venom_registry.default_channel = "stable"
     else
        .
     end)
    ' "$CONFIG_PATH" >"$tmp_config_path"
mv "$tmp_config_path" "$CONFIG_PATH"

log_info "Starting installed spiderweb on port $SERVER_PORT"
(
    cd "$RUNTIME_CWD"
    HOME="$TEST_HOME" PATH="$INSTALL_DIR:$PATH" "$INSTALL_DIR/spiderweb" >"$SERVER_LOG" 2>&1 &
    echo $! >"$TEST_ROOT/server.pid"
    wait
) &
launcher_pid=$!
server_pid_file="$TEST_ROOT/server.pid"
ready_pid_file=0
for _ in $(seq 1 40); do
    if [[ -s "$server_pid_file" ]]; then
        ready_pid_file=1
        break
    fi
    sleep 0.1
done
if [[ "$ready_pid_file" != "1" ]]; then
    log_error "Timed out waiting for server pid file"
    exit 1
fi
SERVER_PID="$(cat "$server_pid_file")"
disown "$launcher_pid" 2>/dev/null || true

log_info "Waiting for auth tokens and control plane to become ready..."
ready=0
for _ in $(seq 1 60); do
    access_token="$(
        cd "$RUNTIME_CWD" &&
        HOME="$TEST_HOME" PATH="$INSTALL_DIR:$PATH" "$INSTALL_DIR/spiderweb-config" auth status --reveal 2>/dev/null |
            sed -n 's/^  access_token: //p' | tail -n1 | tr -d '\r'
    )"
    if [[ -n "$access_token" ]] && \
        HOME="$TEST_HOME" PATH="$INSTALL_DIR:$PATH" "$INSTALL_DIR/spiderweb-control" --url "ws://127.0.0.1:${SERVER_PORT}/" --auth-token "$access_token" workspace_list >"$TEST_ROOT/workspace_list.json" 2>/dev/null; then
        ready=1
        break
    fi
    sleep 0.5
done
if [[ "$ready" != "1" ]]; then
    log_error "Installed spiderweb did not become ready"
    (
        cd "$RUNTIME_CWD"
        HOME="$TEST_HOME" PATH="$INSTALL_DIR:$PATH" "$INSTALL_DIR/spiderweb-config" auth status --reveal || true
    )
    tail -n 80 "$SERVER_LOG" || true
    exit 1
fi
(
    cd "$RUNTIME_CWD"
    HOME="$TEST_HOME" PATH="$INSTALL_DIR:$PATH" "$INSTALL_DIR/spiderweb-config" auth status --reveal > /tmp/spiderweb-install-auth.txt
)
head -n 5 /tmp/spiderweb-install-auth.txt
log_success "Access token available from installed spiderweb-config"
log_success "Installed spiderweb is serving control requests"

log_info "Exercising hosted registry discovery and update flow..."
run_control_op "$TEST_ROOT/packages_catalog.json" packages_catalog '{"channel":"stable"}'

latest_terminal_version="$(json_query_first "$TEST_ROOT/packages_catalog.json" '.. | objects | select(.package_id? == "terminal" and .registry_release_version?) | .registry_release_version')"
latest_browser_version="$(json_query_first "$TEST_ROOT/packages_catalog.json" '.. | objects | select(.package_id? == "browser" and .registry_release_version?) | .registry_release_version')"

if [[ -z "$latest_terminal_version" || -z "$latest_browser_version" ]]; then
    log_error "Failed to extract hosted registry versions from packages_catalog"
    cat "$TEST_ROOT/packages_catalog.json"
    exit 1
fi
if [[ "$latest_terminal_version" == "0.5.7" || "$latest_browser_version" == "0.5.7" ]]; then
    log_error "Hosted registry did not advertise a newer release than the seeded 0.5.7 fixtures"
    cat "$TEST_ROOT/packages_catalog.json"
    exit 1
fi
log_success "Hosted registry reports terminal@$latest_terminal_version and browser@$latest_browser_version"

OLD_TERMINAL_RELEASE='{"release":{"package_id":"terminal","release_version":"0.5.7","channel":"stable","digest":"sha256:terminal057","signature":{"alg":"test","sig":"terminal057"},"trust":{"source":"test"},"package":{"venom_id":"terminal","kind":"terminal","version":"1","release_version":"0.5.7","categories":["terminal","exec"],"host_roles":["node"],"binding_scopes":["workspace"],"runtime_kind":"native","requirements":{},"capabilities":{"invoke":true},"ops":{"model":"namespace"},"runtime":{"type":"native_proc"},"permissions":{"default":"deny-by-default"},"schema":{"model":"namespace"}}}}'
run_control_op "$TEST_ROOT/packages_install_terminal_old.json" packages_install "$OLD_TERMINAL_RELEASE"
assert_file_contains "$TEST_ROOT/packages_install_terminal_old.json" '"release_version":"0.5.7"'

run_control_op "$TEST_ROOT/packages_updates_terminal.json" packages_updates
assert_file_contains "$TEST_ROOT/packages_updates_terminal.json" '"package_id":"terminal"'
assert_file_contains "$TEST_ROOT/packages_updates_terminal.json" "\"latest_release_version\":\"$latest_terminal_version\""
assert_file_contains "$TEST_ROOT/packages_updates_terminal.json" '"update_available":true'

run_control_op "$TEST_ROOT/packages_update_terminal.json" packages_update '{"venom_id":"terminal","activate":true}'
assert_file_contains "$TEST_ROOT/packages_update_terminal.json" "\"target_release_version\":\"$latest_terminal_version\""
assert_file_contains "$TEST_ROOT/packages_update_terminal.json" '"installed":true'
assert_file_contains "$TEST_ROOT/packages_update_terminal.json" '"changed":true'

run_control_op "$TEST_ROOT/packages_get_terminal.json" packages_get '{"venom_id":"terminal"}'
assert_file_contains "$TEST_ROOT/packages_get_terminal.json" "\"active_release_version\":\"$latest_terminal_version\""
assert_file_contains "$TEST_ROOT/packages_get_terminal.json" '"update_available":false'

OLD_BROWSER_RELEASE='{"release":{"package_id":"browser","release_version":"0.5.7","channel":"stable","digest":"sha256:browser057","signature":{"alg":"test","sig":"browser057"},"trust":{"source":"test"},"package":{"venom_id":"browser-main","kind":"browser","version":"1","release_version":"0.5.7","categories":["browser"],"host_roles":["node"],"binding_scopes":["workspace"],"runtime_kind":"native","requirements":{"host_capabilities":["managed_browser"]},"capabilities":{"invoke":true,"observe":true,"act":true},"ops":{"model":"namespace"},"runtime":{"type":"native_proc"},"permissions":{"default":"deny-by-default"},"schema":{"model":"browser-observe-act-v1"}}}}'
run_control_op "$TEST_ROOT/packages_install_browser_old.json" packages_install "$OLD_BROWSER_RELEASE"
assert_file_contains "$TEST_ROOT/packages_install_browser_old.json" '"package_id":"browser"'
assert_file_contains "$TEST_ROOT/packages_install_browser_old.json" '"release_version":"0.5.7"'

run_control_op "$TEST_ROOT/packages_update_all_preview.json" packages_update_all '{"apply":false,"packages":["browser"]}'
assert_file_contains "$TEST_ROOT/packages_update_all_preview.json" '"candidate_count":1'
assert_file_contains "$TEST_ROOT/packages_update_all_preview.json" '"preview_count":1'
assert_file_contains "$TEST_ROOT/packages_update_all_preview.json" "\"target_release_version\":\"$latest_browser_version\""

run_control_op "$TEST_ROOT/packages_update_all_apply.json" packages_update_all '{"apply":true,"activate":true,"packages":["browser"]}'
assert_file_contains "$TEST_ROOT/packages_update_all_apply.json" '"updated_count":1'
assert_file_contains "$TEST_ROOT/packages_update_all_apply.json" "\"target_release_version\":\"$latest_browser_version\""

run_control_op "$TEST_ROOT/packages_get_browser.json" packages_get '{"venom_id":"browser"}'
assert_file_contains "$TEST_ROOT/packages_get_browser.json" "\"active_release_version\":\"$latest_browser_version\""
assert_file_contains "$TEST_ROOT/packages_get_browser.json" '"update_available":false'
log_success "Hosted registry install/update/switch flows passed"

log_info "Creating a smoke-test workspace..."
(
    cd "$RUNTIME_CWD"
    HOME="$TEST_HOME" PATH="$INSTALL_DIR:$PATH" \
        "$INSTALL_DIR/spiderweb-control" \
        --url "ws://127.0.0.1:${SERVER_PORT}/" \
        --auth-token "$access_token" \
        workspace_create \
        '{"name":"Install Smoke","vision":"Installer smoke test"}' >"$TEST_ROOT/workspace_create.json"
)

workspace_id="$(jq -r '.payload.workspace.id // .payload.workspace_id // .payload.id // empty' "$TEST_ROOT/workspace_create.json")"
if [[ -z "$workspace_id" ]]; then
    log_error "Failed to extract workspace ID from workspace_create response"
    cat "$TEST_ROOT/workspace_create.json"
    exit 1
fi
log_success "Created workspace: $workspace_id"

log_info "Exercising installed spiderweb-fs-mount without an OS mount..."
(
    cd "$RUNTIME_CWD"
    HOME="$TEST_HOME" PATH="$INSTALL_DIR:$PATH" \
        "$INSTALL_DIR/spiderweb-fs-mount" \
        --workspace-url "ws://127.0.0.1:${SERVER_PORT}/" \
        --workspace-id "$workspace_id" \
        --auth-token "$access_token" \
        readdir / >"$TEST_ROOT/fs_root.json"
)

cat "$TEST_ROOT/fs_root.json"
if jq -e '.ents | length > 0' "$TEST_ROOT/fs_root.json" >/dev/null 2>&1; then
    log_success "Filesystem smoke returned namespace entries"
else
    log_error "Filesystem smoke did not return entries"
    exit 1
fi

echo ""
echo "=========================================="
log_success "Installer smoke test passed"
echo "Artifacts:"
echo "  $TEST_ROOT"
echo "=========================================="
