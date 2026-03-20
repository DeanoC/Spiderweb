#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MACOS_DIR/../.." && pwd)"
PROJECT_PATH="$MACOS_DIR/SpiderwebFSKit.xcodeproj"
SCHEME="SpiderwebFSKit"
VERSION_DEFAULT="$(sed -n 's/.*\.version = \"\(.*\)\",/\1/p' "$REPO_ROOT/build.zig.zon" | head -n1)"
OUT_DIR_DEFAULT="$MACOS_DIR/dist"
APP_NAME="Spiderweb.app"
APP_BUNDLE_ID="com.deanoc.spiderweb.fskit.app"
EXTENSION_BUNDLE_ID="com.deanoc.spiderweb.fskit.app.extension"
FILESYSTEM_BUNDLE_NAME="spiderweb.fs"
FILESYSTEM_BUNDLE_ID="com.deanoc.spiderweb.filesystems.fs.spiderweb"
FILESYSTEM_HELPER_NAME="mount_spiderweb"
MACOS_MIN_TARGET="15.4"

REQUIRED_ENV=(
  SPIDERWEB_MACOS_TEAM_ID
  SPIDERWEB_MACOS_DEVELOPER_ID_APPLICATION
  SPIDERWEB_MACOS_DEVELOPER_ID_INSTALLER
)

ZIG_BINARIES=(
  spiderweb
  spiderweb-config
  spiderweb-control
  spiderweb-fs-mount
  spiderweb-fs-node
  spiderweb-local-node
  spiderweb-local-service
)
HOST_ARCH="$(uname -m)"

usage() {
  cat <<'EOF'
Build a signed macOS Spiderweb release package for distribution outside the Mac App Store.

Usage:
  package-spiderweb-macos-release.sh [--version <version>] [--out-dir <dir>] [--skip-notarize]

Required environment:
  SPIDERWEB_MACOS_TEAM_ID
  SPIDERWEB_MACOS_DEVELOPER_ID_APPLICATION
  SPIDERWEB_MACOS_DEVELOPER_ID_INSTALLER

Optional environment:
  SPIDERWEB_MACOS_APP_PROFILE
    Path to the Developer ID provisioning profile for com.deanoc.spiderweb.fskit.app
  SPIDERWEB_MACOS_EXTENSION_PROFILE
    Path to the Developer ID provisioning profile for com.deanoc.spiderweb.fskit.app.extension
  SPIDERWEB_MACOS_NOTARY_PROFILE
    Keychain profile name to use with `xcrun notarytool submit --keychain-profile`
  DEVELOPER_DIR
    Full Xcode developer dir. Defaults to /Applications/Xcode.app/Contents/Developer when present.

Outputs:
  <out-dir>/Spiderweb-macos-<version>.pkg
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  printf '%s' "$value"
}

write_build_metadata() {
  local output_path="$1"
  local git_commit
  local git_short_commit
  local git_dirty
  local built_at_utc

  git_commit="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  git_short_commit="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD)"
  if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    git_dirty=true
  else
    git_dirty=false
  fi
  built_at_utc="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  cat >"$output_path" <<EOF
{
  "version": "$version",
  "gitCommit": "$git_commit",
  "gitShortCommit": "$git_short_commit",
  "gitDirty": $git_dirty,
  "builtAtUTC": "$built_at_utc"
}
EOF
}

profile_field() {
  local profile_path="$1"
  local field_name="$2"
  local plist_path
  plist_path="$(mktemp /tmp/spiderweb-profile.XXXXXX.plist)"
  security cms -D -i "$profile_path" >"$plist_path"
  /usr/libexec/PlistBuddy -c "Print :$field_name" "$plist_path"
  rm -f "$plist_path"
}

install_profile() {
  local profile_path="$1"
  local uuid
  uuid="$(profile_field "$profile_path" UUID)"
  local dest_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
  mkdir -p "$dest_dir"
  cp "$profile_path" "$dest_dir/$uuid.provisionprofile"
  profile_field "$profile_path" Name
}

write_export_options() {
  local plist_path="$1"
  local app_profile_name="${2:-}"
  local extension_profile_name="${3:-}"
  local provisioning_block=""
  local signing_style="automatic"
  local signing_certificate_block=""

  if [[ -n "$app_profile_name" && -n "$extension_profile_name" ]]; then
    signing_style="manual"
    provisioning_block=$(
      cat <<EOF
	<key>provisioningProfiles</key>
	<dict>
		<key>$(xml_escape "$APP_BUNDLE_ID")</key>
		<string>$(xml_escape "$app_profile_name")</string>
		<key>$(xml_escape "$EXTENSION_BUNDLE_ID")</key>
		<string>$(xml_escape "$extension_profile_name")</string>
	</dict>
EOF
    )
    signing_certificate_block=$(
      cat <<EOF
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
EOF
    )
  fi

  cat >"$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>${signing_style}</string>
	<key>teamID</key>
	<string>$(xml_escape "$SPIDERWEB_MACOS_TEAM_ID")</string>
	<key>stripSwiftSymbols</key>
	<true/>
${signing_certificate_block}
${provisioning_block}
</dict>
</plist>
EOF
}

build_host_zig_binaries() {
  local build_root="$1"
  local payload_root="$2"
  mkdir -p "$payload_root/usr/local/bin"
  rm -rf "$build_root"
  mkdir -p "$build_root"

  (
    cd "$REPO_ROOT"
    zig build install --release=safe --prefix "$build_root"
  )

  local binary
  for binary in "${ZIG_BINARIES[@]}"; do
    cp "$build_root/bin/$binary" "$payload_root/usr/local/bin/$binary"
    chmod 755 "$payload_root/usr/local/bin/$binary"
    codesign --force --sign "$SPIDERWEB_MACOS_DEVELOPER_ID_APPLICATION" --timestamp --options runtime \
      "$payload_root/usr/local/bin/$binary"
  done
}

build_signed_filesystem_bundle() {
  local work_root="$1"
  local bundle_root="$work_root/$FILESYSTEM_BUNDLE_NAME"
  local resources_dir="$bundle_root/Contents/Resources"
  local helper_src="$MACOS_DIR/FilesystemBundle/SpiderwebFSMountHelper.swift"
  local info_template="$MACOS_DIR/FilesystemBundle/filesystem-bundle-Info.plist"

  rm -rf "$bundle_root"
  mkdir -p "$resources_dir"
  cp "$info_template" "$bundle_root/Contents/Info.plist"

  xcrun swiftc -target "${HOST_ARCH}-apple-macos${MACOS_MIN_TARGET}" -O -o "$resources_dir/$FILESYSTEM_HELPER_NAME" "$helper_src"
  chmod 755 "$resources_dir/$FILESYSTEM_HELPER_NAME"

  codesign --force --sign "$SPIDERWEB_MACOS_DEVELOPER_ID_APPLICATION" --timestamp --options runtime \
    "$resources_dir/$FILESYSTEM_HELPER_NAME"
  codesign --force --sign "$SPIDERWEB_MACOS_DEVELOPER_ID_APPLICATION" --timestamp \
    "$bundle_root"

  printf '%s\n' "$bundle_root"
}

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

require_command xcrun
require_command xcodebuild
require_command pkgbuild
require_command codesign
require_command lipo
require_command security
require_command zig
require_command python3
require_command git

version="$VERSION_DEFAULT"
out_dir="$OUT_DIR_DEFAULT"
skip_notarize=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:?missing value for --version}"
      shift 2
      ;;
    --out-dir)
      out_dir="${2:?missing value for --out-dir}"
      shift 2
      ;;
    --skip-notarize)
      skip_notarize=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

for var_name in "${REQUIRED_ENV[@]}"; do
  [[ -n "${!var_name:-}" ]] || fail "missing required environment variable: $var_name"
done

mkdir -p "$out_dir"

work_root="$(mktemp -d /tmp/spiderweb-macos-release.XXXXXX)"
trap 'rm -rf "$work_root"' EXIT

archive_path="$work_root/Spiderweb.xcarchive"
export_dir="$work_root/export"
payload_root="$work_root/payload"
scripts_root="$work_root/pkg-scripts"
component_plist="$work_root/Component.plist"
pkg_path="$out_dir/Spiderweb-macos-${version}.pkg"
export_options_plist="$work_root/ExportOptions.plist"

app_profile_name=""
extension_profile_name=""
if [[ -n "${SPIDERWEB_MACOS_APP_PROFILE:-}" && -z "${SPIDERWEB_MACOS_EXTENSION_PROFILE:-}" ]]; then
  fail "SPIDERWEB_MACOS_EXTENSION_PROFILE is required when SPIDERWEB_MACOS_APP_PROFILE is set"
fi
if [[ -z "${SPIDERWEB_MACOS_APP_PROFILE:-}" && -n "${SPIDERWEB_MACOS_EXTENSION_PROFILE:-}" ]]; then
  fail "SPIDERWEB_MACOS_APP_PROFILE is required when SPIDERWEB_MACOS_EXTENSION_PROFILE is set"
fi
if [[ -n "${SPIDERWEB_MACOS_APP_PROFILE:-}" ]]; then
  app_profile_name="$(install_profile "$SPIDERWEB_MACOS_APP_PROFILE")"
fi
if [[ -n "${SPIDERWEB_MACOS_EXTENSION_PROFILE:-}" ]]; then
  extension_profile_name="$(install_profile "$SPIDERWEB_MACOS_EXTENSION_PROFILE")"
fi
write_export_options "$export_options_plist" "$app_profile_name" "$extension_profile_name"

echo "==> Building Spiderweb CLI binaries for host architecture ($HOST_ARCH)"
build_host_zig_binaries "$work_root/zig-host" "$payload_root"

echo "==> Archiving Spiderweb.app"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$archive_path" \
  DEVELOPMENT_TEAM="$SPIDERWEB_MACOS_TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  MARKETING_VERSION="$version" \
  ONLY_ACTIVE_ARCH=NO \
  archive

echo "==> Exporting Developer ID-signed Spiderweb.app"
xcodebuild \
  -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_dir" \
  -exportOptionsPlist "$export_options_plist"

[[ -d "$export_dir/$APP_NAME" ]] || fail "expected exported app at $export_dir/$APP_NAME"

echo "==> Building signed spiderweb.fs bundle"
filesystem_bundle_path="$(build_signed_filesystem_bundle "$work_root")"
filesystem_bundle_zip="$work_root/spiderweb.fs.install-source.zip"
ditto -c -k --keepParent "$filesystem_bundle_path" "$filesystem_bundle_zip"

echo "==> Staging installer payload"
mkdir -p "$payload_root/Applications" "$payload_root/Library/Filesystems" "$payload_root/usr/local/bin" "$scripts_root"
ditto "$export_dir/$APP_NAME" "$payload_root/Applications/$APP_NAME"
ditto "$filesystem_bundle_path" "$payload_root/Library/Filesystems/$FILESYSTEM_BUNDLE_NAME"
cp "$MACOS_DIR/Packaging/preinstall" "$scripts_root/preinstall"
cp "$MACOS_DIR/Packaging/postinstall" "$scripts_root/postinstall"
chmod 755 "$scripts_root/preinstall"
chmod 755 "$scripts_root/postinstall"

echo "==> Embedding Spiderweb CLI tools into Spiderweb.app"
app_resources_dir="$payload_root/Applications/$APP_NAME/Contents/Resources"
mkdir -p "$app_resources_dir"
cp "$filesystem_bundle_zip" "$app_resources_dir/spiderweb.fs.install-source.zip"
for binary in "${ZIG_BINARIES[@]}"; do
  cp "$payload_root/usr/local/bin/$binary" "$app_resources_dir/$binary"
  chmod 755 "$app_resources_dir/$binary"
  codesign --force --sign "$SPIDERWEB_MACOS_DEVELOPER_ID_APPLICATION" --timestamp --options runtime \
    "$app_resources_dir/$binary"
done
write_build_metadata "$app_resources_dir/build-info.json"
codesign --force --sign "$SPIDERWEB_MACOS_DEVELOPER_ID_APPLICATION" --timestamp --options runtime \
  --preserve-metadata=entitlements,requirements,flags,runtime \
  "$payload_root/Applications/$APP_NAME"

pkgbuild --analyze --root "$payload_root" "$component_plist"
python3 - "$component_plist" <<'PY'
import plistlib
import sys
from pathlib import Path

plist_path = Path(sys.argv[1])

with plist_path.open('rb') as fh:
    components = plistlib.load(fh)

for component in components:
    root_path = component.get("RootRelativeBundlePath")
    if root_path == "Applications/Spiderweb.app":
        component["BundleIsRelocatable"] = False
        component["BundleHasStrictIdentifier"] = True
        component["BundleIsVersionChecked"] = True
        component["BundleOverwriteAction"] = "upgrade"
    elif root_path == "Library/Filesystems/spiderweb.fs":
        component["BundleIsVersionChecked"] = True
        component["BundleOverwriteAction"] = "upgrade"

with plist_path.open('wb') as fh:
    plistlib.dump(components, fh)
PY

echo "==> Verifying signatures"
codesign --verify --deep --strict "$payload_root/Applications/$APP_NAME"
codesign --verify --deep --strict "$payload_root/Library/Filesystems/$FILESYSTEM_BUNDLE_NAME"
for binary in "${ZIG_BINARIES[@]}"; do
  codesign --verify --strict "$payload_root/usr/local/bin/$binary"
done

echo "==> Building signed installer package"
rm -f "$pkg_path"
pkgbuild \
  --root "$payload_root" \
  --scripts "$scripts_root" \
  --component-plist "$component_plist" \
  --identifier "$FILESYSTEM_BUNDLE_ID.pkg" \
  --ownership recommended \
  --version "$version" \
  --install-location "/" \
  --sign "$SPIDERWEB_MACOS_DEVELOPER_ID_INSTALLER" \
  "$pkg_path"

if [[ $skip_notarize -eq 0 && -n "${SPIDERWEB_MACOS_NOTARY_PROFILE:-}" ]]; then
  echo "==> Notarizing installer package"
  xcrun notarytool submit "$pkg_path" --keychain-profile "$SPIDERWEB_MACOS_NOTARY_PROFILE" --wait
  echo "==> Stapling installer package"
  xcrun stapler staple "$pkg_path"
fi

echo "==> Final package"
echo "$pkg_path"
