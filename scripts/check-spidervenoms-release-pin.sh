#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/spidervenoms-release.sh"

fail() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

verify_pin() {
  local os="$1"
  local arch="$2"
  local url
  url="$(spidervenoms_release_url_for_platform "$os" "$arch")" || fail "no pinned SpiderVenoms release URL for ${os}/${arch}"
  echo "==> Verifying SpiderVenoms pin for ${os}/${arch}"
  spidervenoms_verify_pinned_checksum_file "$os" "$arch"
  echo "    ${url}"
}

require_command curl

verify_pin linux arm64
verify_pin linux x86_64
verify_pin macos arm64
