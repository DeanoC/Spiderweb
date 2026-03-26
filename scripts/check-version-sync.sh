#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

version="$(sed -n 's/.*\.version = "\(.*\)",/\1/p' "$REPO_ROOT/build.zig.zon" | head -n1)"
[[ -n "$version" ]] || {
  echo "error: could not read version from build.zig.zon" >&2
  exit 1
}

expect_contains() {
  local file="$1"
  local pattern="$2"
  if ! rg -q --fixed-strings "$pattern" "$file"; then
    echo "error: version mismatch in $file" >&2
    echo "expected to find: $pattern" >&2
    exit 1
  fi
}

expect_contains "$REPO_ROOT/src/main.zig" "Spiderweb v${version} - Workspace Host for OpenClaw Protocol"
expect_contains "$REPO_ROOT/src/main.zig" "Starting Spiderweb v${version} (Workspace Host)"

marketing_versions="$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' "$REPO_ROOT/platform/macos/SpiderwebFSKit.xcodeproj/project.pbxproj" | sort -u)"
if [[ "$marketing_versions" != "$version" ]]; then
  echo "error: macOS MARKETING_VERSION does not match build.zig.zon" >&2
  echo "expected: $version" >&2
  echo "actual: $marketing_versions" >&2
  exit 1
fi

first_changelog_version="$(sed -n 's/^## \([0-9][0-9.]*\) -.*/\1/p' "$REPO_ROOT/CHANGELOG.md" | head -n1)"
if [[ "$first_changelog_version" != "$version" ]]; then
  echo "error: top changelog version does not match build.zig.zon" >&2
  echo "expected: $version" >&2
  echo "actual: ${first_changelog_version:-<missing>}" >&2
  exit 1
fi

echo "version sync ok: $version"
