#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_DIR="$MACOS_DIR/build/spiderweb.fs"
BUNDLE_INFO_TEMPLATE="$MACOS_DIR/FilesystemBundle/filesystem-bundle-Info.plist"
HELPER_SOURCE="$MACOS_DIR/FilesystemBundle/SpiderwebFSMountHelper.swift"
HELPER_NAME="mount_spiderweb"
HELPER_PATH="$BUNDLE_DIR/Contents/Resources/$HELPER_NAME"
INSTALL_ROOT="/Library/Filesystems"
INSTALL_PATH="$INSTALL_ROOT/spiderweb.fs"
STAGING_ROOT="$(mktemp -d /tmp/spiderweb-fskit-install.XXXXXX)"
STAGED_BUNDLE="$STAGING_ROOT/spiderweb.fs"
ROOT_SCRIPT="$STAGING_ROOT/install-spiderweb-fs.sh"
HOST_ARCH="$(uname -m)"

cleanup() {
  rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

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
  -target "${HOST_ARCH}-apple-macos15.4" \
  -O \
  -o "$HELPER_PATH" \
  "$HELPER_SOURCE"
chmod 755 "$HELPER_PATH"

codesign --force --sign - "$HELPER_PATH"
codesign --force --sign - "$BUNDLE_DIR"

ditto "$BUNDLE_DIR" "$STAGED_BUNDLE"

cat >"$ROOT_SCRIPT" <<EOF
#!/bin/bash
set -euo pipefail
mkdir -p "$INSTALL_ROOT"
rm -rf "$INSTALL_PATH"
ditto "$STAGED_BUNDLE" "$INSTALL_PATH"
chown -R root:wheel "$INSTALL_PATH"
EOF
chmod 755 "$ROOT_SCRIPT"

if sudo -n true >/dev/null 2>&1; then
  sudo /bin/bash "$ROOT_SCRIPT"
else
  /usr/bin/osascript -e "do shell script \"/bin/bash '$ROOT_SCRIPT'\" with administrator privileges"
fi

pluginkit -r "$INSTALL_PATH" >/dev/null 2>&1 || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -R -f "$INSTALL_PATH" >/dev/null 2>&1 || true

echo "$INSTALL_PATH"
