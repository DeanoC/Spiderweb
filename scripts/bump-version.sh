#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  bump-version.sh [--patch]
  bump-version.sh --minor --explicit
  bump-version.sh --major --explicit
  bump-version.sh --set <X.Y.Z> [--explicit]

Defaults to a patch bump.

Rules:
  - patch bumps are the default path
  - minor/major bumps require --explicit
  - this script updates the canonical repo version touchpoints
EOF
}

mode="patch"
explicit=0
set_version=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --patch)
      mode="patch"
      shift
      ;;
    --minor)
      mode="minor"
      shift
      ;;
    --major)
      mode="major"
      shift
      ;;
    --set)
      [[ $# -ge 2 ]] || {
        echo "error: --set requires a value" >&2
        exit 1
      }
      mode="set"
      set_version="$2"
      shift 2
      ;;
    --explicit)
      explicit=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

current_version="$(sed -n 's/.*\.version = "\(.*\)",/\1/p' "$REPO_ROOT/build.zig.zon" | head -n1)"
[[ "$current_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || {
  echo "error: unsupported current version: $current_version" >&2
  exit 1
}

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"

case "$mode" in
  patch)
    next_version="${major}.${minor}.$((patch + 1))"
    ;;
  minor)
    [[ "$explicit" == "1" ]] || {
      echo "error: minor bumps require --explicit" >&2
      exit 1
    }
    next_version="${major}.$((minor + 1)).0"
    ;;
  major)
    [[ "$explicit" == "1" ]] || {
      echo "error: major bumps require --explicit" >&2
      exit 1
    }
    next_version="$((major + 1)).0.0"
    ;;
  set)
    [[ "$set_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
      echo "error: --set expects X.Y.Z" >&2
      exit 1
    }
    if [[ "$set_version" != "${major}.${minor}.$((patch + 1))" && "$explicit" != "1" ]]; then
      echo "error: non-default version jumps require --explicit" >&2
      exit 1
    fi
    next_version="$set_version"
    ;;
esac

echo "Updating Spiderweb version: $current_version -> $next_version"

python3 - "$REPO_ROOT" "$current_version" "$next_version" <<'PY'
import pathlib
import re
import sys

repo = pathlib.Path(sys.argv[1])
current = sys.argv[2]
new = sys.argv[3]

files = {
    repo / "build.zig.zon": [(re.compile(r'(\.version = ")([^"]+)(")'), r'\g<1>' + new + r'\g<3>')],
    repo / "src/main.zig": [
        (re.compile(r'Spiderweb v[0-9]+\.[0-9]+\.[0-9]+ - Workspace Host for OpenClaw Protocol'), f"Spiderweb v{new} - Workspace Host for OpenClaw Protocol"),
        (re.compile(r'Starting Spiderweb v[0-9]+\.[0-9]+\.[0-9]+ \(Workspace Host\)'), f"Starting Spiderweb v{new} (Workspace Host)"),
    ],
    repo / "platform/macos/SpiderwebFSKit.xcodeproj/project.pbxproj": [
        (re.compile(r'(MARKETING_VERSION = )([0-9]+\.[0-9]+\.[0-9]+)(;)'), r'\g<1>' + new + r'\g<3>')
    ],
}

for path, replacements in files.items():
    text = path.read_text()
    updated = text
    for pattern, repl in replacements:
        updated = pattern.sub(repl, updated)
    path.write_text(updated)
PY

"$SCRIPT_DIR/check-version-sync.sh"

cat <<EOF
Next steps:
  1. Update the top CHANGELOG.md entry to ${next_version} if needed.
  2. Commit the version bump.
  3. Tag the release as v${next_version} when ready.
EOF
