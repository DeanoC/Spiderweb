#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_DIR="$MACOS_DIR/build/passthrough.fs"
BUNDLE_INFO_TEMPLATE="$MACOS_DIR/FilesystemBundle/passthrough.fs-Info.plist"
HELPER_SOURCE="$MACOS_DIR/FilesystemBundle/mount_passthrough.swift"
HELPER_NAME="mount_passthrough"
HELPER_PATH="$BUNDLE_DIR/Contents/Resources/$HELPER_NAME"
INSTALL_ROOT="/Library/Filesystems"
INSTALL_PATH="$INSTALL_ROOT/passthrough.fs"

if [[ -z "${DEVELOPER_DIR:-}" && -x "/Applications/Xcode.app/Contents/Developer/usr/bin/xcrun" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun is required. Install full Xcode and select it with xcode-select." >&2
  exit 1
fi

mkdir -p "$BUNDLE_DIR/Contents/Resources"
cp "$BUNDLE_INFO_TEMPLATE" "$BUNDLE_DIR/Contents/Info.plist"

xcrun swiftc \
  -target arm64-apple-macos15.4 \
  -O \
  -o "$HELPER_PATH" \
  "$HELPER_SOURCE"
chmod 755 "$HELPER_PATH"

codesign --force --sign - "$HELPER_PATH"
codesign --force --sign - "$BUNDLE_DIR"

sudo mkdir -p "$INSTALL_ROOT"
sudo rm -rf "$INSTALL_PATH"
sudo ditto "$BUNDLE_DIR" "$INSTALL_PATH"
sudo chown -R root:wheel "$INSTALL_PATH"

pluginkit -r "$INSTALL_PATH" >/dev/null 2>&1 || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -R -f "$INSTALL_PATH" >/dev/null 2>&1 || true

echo "$INSTALL_PATH"
