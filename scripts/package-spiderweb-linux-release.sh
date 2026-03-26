#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/spidervenoms-release.sh"
SPIDERVENOMS_REPO_DIR="${SPIDERVENOMS_REPO_DIR:-$REPO_ROOT/../SpiderVenoms}"
SPIDERVENOMS_SOURCE_MODE="${SPIDERVENOMS_SOURCE_MODE:-auto}"
VERSION_DEFAULT="$(sed -n 's/.*\.version = "\(.*\)",/\1/p' "$REPO_ROOT/build.zig.zon" | head -n1)"
OUT_DIR_DEFAULT="$REPO_ROOT/dist"
SPIDERWEB_BINARIES=(
  spiderweb
  spiderweb-config
  spiderweb-control
  spiderweb-fs-mount
  spiderweb-fs-node
  spiderweb-local-node
)

usage() {
  cat <<'EOF'
Build a Linux Spiderweb release archive containing the installed runtime binaries and share assets.

Usage:
  package-spiderweb-linux-release.sh [--version <version>] [--out-dir <dir>]

Outputs:
  <out-dir>/spiderweb-linux-<arch>.tar.gz
  <out-dir>/spiderweb-linux-<arch>.tar.gz.sha256
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

download_archive() {
  local url="$1"
  local output="$2"
  curl -fL "$url" -o "$output"
}

verify_archive_sha256() {
  local archive_path="$1"
  local expected_sha="$2"
  [[ -n "$expected_sha" ]] || return 0

  local actual_sha
  actual_sha="$(sha256sum "$archive_path" | awk '{print $1}')"
  [[ "$actual_sha" == "$expected_sha" ]] || fail "SpiderVenoms archive SHA256 mismatch: expected $expected_sha got $actual_sha"
}

extract_archive() {
  local archive_path="$1"
  local extract_dir="$2"
  mkdir -p "$extract_dir"
  tar -xzf "$archive_path" -C "$extract_dir"
}

copy_spidervenoms_share_tree() {
  local source_root="$1"
  local build_prefix="$2"
  local source_share_dir="$source_root/share/spidervenoms"
  local target_share_dir="$build_prefix/share/spidervenoms"

  [[ -d "$source_share_dir" ]] || fail "SpiderVenoms bundle directory missing: $source_share_dir"
  mkdir -p "$build_prefix/share"
  rm -rf "$target_share_dir"
  cp -R "$source_share_dir" "$target_share_dir"
}

build_spidervenoms_bundle_from_source() {
  local build_prefix="$1"
  [[ -f "$SPIDERVENOMS_REPO_DIR/build.zig" ]] || fail "SpiderVenoms checkout not found at $SPIDERVENOMS_REPO_DIR"
  (
    cd "$SPIDERVENOMS_REPO_DIR"
    zig build install --release=safe --prefix "$build_prefix"
  )
}

stage_spidervenoms_bundle() {
  local build_prefix="$1"
  local release_url=""
  local release_sha=""
  local extract_root="$WORK_ROOT/spidervenoms-release"
  local archive_path="$WORK_ROOT/spidervenoms-managed-local.tar.gz"

  if [[ "$SPIDERVENOMS_SOURCE_MODE" != "source" ]]; then
    release_url="$(spidervenoms_release_url_for_platform linux "$ARCH_LABEL" 2>/dev/null || true)"
    release_sha="$(spidervenoms_release_sha256_for_platform linux "$ARCH_LABEL" 2>/dev/null || true)"
    if [[ -n "$release_url" ]]; then
      echo "==> Downloading SpiderVenoms managed bundle v${spidervenoms_release_version}"
      download_archive "$release_url" "$archive_path"
      verify_archive_sha256 "$archive_path" "$release_sha"
      extract_archive "$archive_path" "$extract_root"
      local source_share_dir
      source_share_dir="$(find "$extract_root" -type d -path '*/share/spidervenoms' 2>/dev/null | head -n1 || true)"
      [[ -n "$source_share_dir" ]] || fail "published SpiderVenoms artifact missing share/spidervenoms"
      copy_spidervenoms_share_tree "$(dirname "$(dirname "$source_share_dir")")" "$build_prefix"
      return 0
    fi
    [[ "$SPIDERVENOMS_SOURCE_MODE" != "release" ]] || fail "no published SpiderVenoms asset is pinned for linux/${ARCH_LABEL}"
  fi

  echo "==> Building SpiderVenoms managed bundle from source"
  build_spidervenoms_bundle_from_source "$build_prefix"
}

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH_LABEL="x86_64" ;;
  aarch64|arm64) ARCH_LABEL="aarch64" ;;
  *) ARCH_LABEL="$ARCH" ;;
esac

VERSION="$VERSION_DEFAULT"
OUT_DIR="$OUT_DIR_DEFAULT"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || fail "--version requires a value"
      VERSION="$2"
      shift 2
      ;;
    --out-dir)
      [[ $# -ge 2 ]] || fail "--out-dir requires a value"
      OUT_DIR="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

require_command zig
require_command tar
require_command sha256sum
require_command curl

WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT

BUILD_PREFIX="$WORK_ROOT/prefix"
ARCHIVE_ROOT="$WORK_ROOT/archive-root"
ARCHIVE_BASENAME="spiderweb-linux-${ARCH_LABEL}"
ARCHIVE_PATH="$OUT_DIR/${ARCHIVE_BASENAME}.tar.gz"
SHA_PATH="${ARCHIVE_PATH}.sha256"

mkdir -p "$BUILD_PREFIX" "$ARCHIVE_ROOT" "$OUT_DIR"

echo "==> Building Spiderweb install prefix"
(
  cd "$REPO_ROOT"
  zig build install --release=safe --prefix "$BUILD_PREFIX"
)

stage_spidervenoms_bundle "$BUILD_PREFIX"

[[ -x "$BUILD_PREFIX/bin/spiderweb" ]] || fail "missing built spiderweb binary"
[[ -f "$BUILD_PREFIX/share/spidervenoms/bundles/managed-local/release.json" ]] || fail "missing managed local venom bundle"
[[ -d "$BUILD_PREFIX/share/spiderweb/templates" ]] || fail "missing Spiderweb runtime templates"

PACKAGE_ROOT="$ARCHIVE_ROOT/$ARCHIVE_BASENAME"
mkdir -p "$PACKAGE_ROOT/bin"
for binary in "${SPIDERWEB_BINARIES[@]}"; do
  [[ -x "$BUILD_PREFIX/bin/$binary" ]] || fail "missing expected Spiderweb binary: $binary"
  cp "$BUILD_PREFIX/bin/$binary" "$PACKAGE_ROOT/bin/$binary"
done
cp -R "$BUILD_PREFIX/share" "$PACKAGE_ROOT/share"

echo "==> Writing release archive"
rm -f "$ARCHIVE_PATH" "$SHA_PATH"
tar -C "$ARCHIVE_ROOT" -czf "$ARCHIVE_PATH" "$ARCHIVE_BASENAME"
(cd "$OUT_DIR" && sha256sum "$(basename "$ARCHIVE_PATH")" >"$(basename "$SHA_PATH")")

echo "Archive: $ARCHIVE_PATH"
echo "SHA256:  $SHA_PATH"
echo "Version: $VERSION"
