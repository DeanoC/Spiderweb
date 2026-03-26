#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
check_changelog=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-changelog)
      check_changelog=0
      shift
      ;;
    --help|-h)
      cat <<'EOF'
Usage:
  check-version-sync.sh [--skip-changelog]

Checks that the canonical Spiderweb version touchpoints stay in sync.
EOF
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

version="$(sed -n 's/.*\.version = "\(.*\)",/\1/p' "$REPO_ROOT/build.zig.zon" | head -n1)"
[[ -n "$version" ]] || {
  echo "error: could not read version from build.zig.zon" >&2
  exit 1
}

expect_contains() {
  local file="$1"
  local pattern="$2"
  local found=0
  if command -v rg >/dev/null 2>&1; then
    if rg -q --fixed-strings "$pattern" "$file"; then
      found=1
    fi
  else
    if grep -F -q -- "$pattern" "$file"; then
      found=1
    fi
  fi
  if [[ "$found" != "1" ]]; then
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

if [[ "$check_changelog" == "1" ]]; then
  first_changelog_version="$(sed -n 's/^## \([0-9][0-9.]*\) -.*/\1/p' "$REPO_ROOT/CHANGELOG.md" | head -n1)"
  if [[ "$first_changelog_version" != "$version" ]]; then
    echo "error: top changelog version does not match build.zig.zon" >&2
    echo "expected: $version" >&2
    echo "actual: ${first_changelog_version:-<missing>}" >&2
    exit 1
  fi
fi

echo "version sync ok: $version"
