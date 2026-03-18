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
RUNTIME_CWD="$REPO_DIR"
SERVER_PORT="${SPIDERWEB_TEST_PORT:-28790}"
INSTALL_LOG="$TEST_ROOT/install.log"
SERVER_LOG="$TEST_ROOT/server.log"

mkdir -p "$TEST_HOME"

log_info "Running install.sh in isolated HOME: $TEST_HOME"
(
    cd "$REPO_ROOT"
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

for bin in spiderweb spiderweb-config spiderweb-control spiderweb-fs-mount spiderweb-fs-node; do
    if [[ -x "$INSTALL_DIR/$bin" ]]; then
        log_success "Installed binary present: $bin"
    else
        log_error "Missing installed binary: $INSTALL_DIR/$bin"
        exit 1
    fi
done

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

log_info "Starting installed spiderweb on port $SERVER_PORT"
(
    cd "$RUNTIME_CWD"
    HOME="$TEST_HOME" PATH="$INSTALL_DIR:$PATH" "$INSTALL_DIR/spiderweb-config" config set-server --bind 127.0.0.1 --port "$SERVER_PORT" >/dev/null
    HOME="$TEST_HOME" PATH="$INSTALL_DIR:$PATH" "$INSTALL_DIR/spiderweb" >"$SERVER_LOG" 2>&1 &
    echo $! >"$TEST_ROOT/server.pid"
    wait
) &
launcher_pid=$!
sleep 0.2
SERVER_PID="$(cat "$TEST_ROOT/server.pid")"
disown "$launcher_pid" 2>/dev/null || true

log_info "Waiting for auth tokens and control plane to become ready..."
ready=0
for _ in $(seq 1 60); do
    admin_token="$(
        cd "$RUNTIME_CWD" &&
        HOME="$TEST_HOME" PATH="$INSTALL_DIR:$PATH" "$INSTALL_DIR/spiderweb-config" auth status --reveal 2>/dev/null |
            sed -n 's/^  admin_token: //p' | tail -n1 | tr -d '\r'
    )"
    if [[ -n "$admin_token" ]] && \
        HOME="$TEST_HOME" PATH="$INSTALL_DIR:$PATH" "$INSTALL_DIR/spiderweb-control" --url "ws://127.0.0.1:${SERVER_PORT}/" --auth-token "$admin_token" workspace_list >"$TEST_ROOT/workspace_list.json" 2>/dev/null; then
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
log_success "Admin token available from installed spiderweb-config"
log_success "Installed spiderweb is serving control requests"

log_info "Creating a smoke-test workspace..."
(
    cd "$RUNTIME_CWD"
    HOME="$TEST_HOME" PATH="$INSTALL_DIR:$PATH" \
        "$INSTALL_DIR/spiderweb-control" \
        --url "ws://127.0.0.1:${SERVER_PORT}/" \
        --auth-token "$admin_token" \
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
        --auth-token "$admin_token" \
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
