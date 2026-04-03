#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MACOS_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/spidervenoms-release.sh"
SPIDERVENOMS_REPO_DIR="${SPIDERVENOMS_REPO_DIR:-$REPO_ROOT/../SpiderVenoms}"
SPIDERVENOMS_SOURCE_MODE="${SPIDERVENOMS_SOURCE_MODE:-auto}"
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
  actual_sha="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
  [[ "$actual_sha" == "$expected_sha" ]] || fail "SpiderVenoms archive SHA256 mismatch: expected $expected_sha got $actual_sha"
}

verify_remote_checksum_pin() {
  local os="$1"
  local arch="$2"
  [[ -n "$(spidervenoms_release_sha256_for_platform "$os" "$arch" 2>/dev/null || true)" ]] || return 0
  spidervenoms_verify_pinned_checksum_file "$os" "$arch" || fail "SpiderVenoms pinned checksum validation failed for ${os}/${arch}"
}

extract_archive() {
  local archive_path="$1"
  local extract_dir="$2"
  mkdir -p "$extract_dir"
  tar -xzf "$archive_path" -C "$extract_dir"
}

copy_spidervenoms_share_tree() {
  local source_root="$1"
  local build_root="$2"
  local source_share_dir="$source_root/share/spidervenoms"
  local target_share_dir="$build_root/share/spidervenoms"

  [[ -d "$source_share_dir" ]] || fail "SpiderVenoms bundle directory missing: $source_share_dir"
  mkdir -p "$build_root/share"
  rm -rf "$target_share_dir"
  cp -R "$source_share_dir" "$target_share_dir"
}

stage_spidervenoms_bundle() {
  local build_root="$1"
  local release_url=""
  local release_sha=""
  local extract_root="$build_root/.spidervenoms-release"

  if [[ "$SPIDERVENOMS_SOURCE_MODE" != "source" ]]; then
    release_url="$(spidervenoms_release_url_for_platform macos "$HOST_ARCH" 2>/dev/null || true)"
    release_sha="$(spidervenoms_release_sha256_for_platform macos "$HOST_ARCH" 2>/dev/null || true)"
    if [[ -n "$release_url" ]]; then
      local archive_path="$build_root/$(basename "$release_url")"
      verify_remote_checksum_pin macos "$HOST_ARCH"
      download_archive "$release_url" "$archive_path"
      verify_archive_sha256 "$archive_path" "$release_sha"
      extract_archive "$archive_path" "$extract_root"
      local source_share_dir
      source_share_dir="$(find "$extract_root" -type d -path '*/share/spidervenoms' 2>/dev/null | head -n1 || true)"
      [[ -n "$source_share_dir" ]] || fail "published SpiderVenoms artifact missing share/spidervenoms"
      copy_spidervenoms_share_tree "$(dirname "$(dirname "$source_share_dir")")" "$build_root"
      return 0
    fi
    [[ "$SPIDERVENOMS_SOURCE_MODE" != "release" ]] || fail "no published SpiderVenoms asset is pinned for macos/$HOST_ARCH"
  fi

  [[ -f "$SPIDERVENOMS_REPO_DIR/build.zig" ]] || fail "SpiderVenoms checkout not found at $SPIDERVENOMS_REPO_DIR"
  (
    cd "$SPIDERVENOMS_REPO_DIR"
    zig build bundle --release=safe --prefix "$build_root"
  )
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

profile_bundle_id() {
  local profile_path="$1"
  local app_identifier
  app_identifier="$(profile_field "$profile_path" 'Entitlements:com.apple.application-identifier' 2>/dev/null || true)"
  app_identifier="${app_identifier#*.}"
  printf '%s' "$app_identifier"
}

profile_name_lower() {
  local profile_path="$1"
  profile_field "$profile_path" Name 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

find_installed_profile_for_bundle_id() {
  local bundle_id="$1"
  local profiles_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
  local profile_path
  local best_path=""
  local fallback_path=""

  [[ -d "$profiles_dir" ]] || return 1

  while IFS= read -r profile_path; do
    [[ -n "$profile_path" ]] || continue
    if [[ "$(profile_bundle_id "$profile_path")" != "$bundle_id" ]]; then
      continue
    fi

    if [[ -z "$fallback_path" ]]; then
      fallback_path="$profile_path"
    fi

    local lowered_name
    lowered_name="$(profile_name_lower "$profile_path")"
    if [[ "$lowered_name" == *devid* || "$lowered_name" == *"developer id"* ]]; then
      best_path="$profile_path"
      break
    fi
  done < <(find "$profiles_dir" -maxdepth 1 -name '*.provisionprofile' | sort)

  if [[ -n "$best_path" ]]; then
    printf '%s\n' "$best_path"
    return 0
  fi
  if [[ -n "$fallback_path" ]]; then
    printf '%s\n' "$fallback_path"
    return 0
  fi
  return 1
}

resolve_profile_path() {
  local explicit_path="${1:-}"
  local bundle_id="$2"
  local env_name="$3"

  if [[ -n "$explicit_path" ]]; then
    printf '%s\n' "$explicit_path"
    return 0
  fi

  if resolved="$(find_installed_profile_for_bundle_id "$bundle_id")"; then
    printf '%s\n' "$resolved"
    return 0
  fi

  fail "no provisioning profile found for ${bundle_id}; set ${env_name} explicitly if auto-discovery is insufficient"
}

install_profile() {
  local profile_path="$1"
  local uuid
  uuid="$(profile_field "$profile_path" UUID)"
  local dest_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
  local dest_path="$dest_dir/$uuid.provisionprofile"
  mkdir -p "$dest_dir"
  if [[ "$profile_path" != "$dest_path" ]]; then
    cp "$profile_path" "$dest_path"
  fi
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
  mkdir -p "$payload_root/usr/local/bin" "$payload_root/usr/local/share"
  rm -rf "$build_root"
  mkdir -p "$build_root"

  (
    cd "$REPO_ROOT"
    zig build install --release=safe --prefix "$build_root"
  )
  stage_spidervenoms_bundle "$build_root"

  local binary
  for binary in "${ZIG_BINARIES[@]}"; do
    cp "$build_root/bin/$binary" "$payload_root/usr/local/bin/$binary"
    chmod 755 "$payload_root/usr/local/bin/$binary"
    codesign --force --sign "$SPIDERWEB_MACOS_DEVELOPER_ID_APPLICATION" --timestamp --options runtime \
      "$payload_root/usr/local/bin/$binary"
  done

  rm -rf "$payload_root/usr/local/share/spidervenoms"
  cp -R "$build_root/share/spidervenoms" "$payload_root/usr/local/share/spidervenoms"
  while IFS= read -r bundle_binary; do
    chmod 755 "$bundle_binary"
    codesign --force --sign "$SPIDERWEB_MACOS_DEVELOPER_ID_APPLICATION" --timestamp --options runtime \
      "$bundle_binary"
  done < <(find "$payload_root/usr/local/share/spidervenoms" -type f -path '*/bin/*')
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
require_command curl

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
if [[ -n "${SPIDERWEB_MACOS_APP_PROFILE:-}" || -n "${SPIDERWEB_MACOS_EXTENSION_PROFILE:-}" ]]; then
  app_profile_path="$(resolve_profile_path "${SPIDERWEB_MACOS_APP_PROFILE:-}" "$APP_BUNDLE_ID" SPIDERWEB_MACOS_APP_PROFILE)"
  extension_profile_path="$(resolve_profile_path "${SPIDERWEB_MACOS_EXTENSION_PROFILE:-}" "$EXTENSION_BUNDLE_ID" SPIDERWEB_MACOS_EXTENSION_PROFILE)"
else
  app_profile_path="$(resolve_profile_path "" "$APP_BUNDLE_ID" SPIDERWEB_MACOS_APP_PROFILE)"
  extension_profile_path="$(resolve_profile_path "" "$EXTENSION_BUNDLE_ID" SPIDERWEB_MACOS_EXTENSION_PROFILE)"
fi
app_profile_name="$(install_profile "$app_profile_path")"
extension_profile_name="$(install_profile "$extension_profile_path")"
echo "==> Using provisioning profiles"
echo "    App: $app_profile_name"
echo "    Extension: $extension_profile_name"
write_export_options "$export_options_plist" "$app_profile_name" "$extension_profile_name"

echo "==> Building Spiderweb CLI binaries for host architecture ($HOST_ARCH)"
build_host_zig_binaries "$work_root/zig-host" "$payload_root"

echo "==> Running macOS quickstart regression"
bash "$MACOS_DIR/scripts/quickstart-regression.sh"

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
mkdir -p "$payload_root/Applications" "$payload_root/Library/Filesystems" "$payload_root/usr/local/bin" "$payload_root/usr/local/share" "$scripts_root"
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
rm -rf "$app_resources_dir/spidervenoms"
cp -R "$payload_root/usr/local/share/spidervenoms" "$app_resources_dir/spidervenoms"
for binary in "${ZIG_BINARIES[@]}"; do
  cp "$payload_root/usr/local/bin/$binary" "$app_resources_dir/$binary"
  chmod 755 "$app_resources_dir/$binary"
  codesign --force --sign "$SPIDERWEB_MACOS_DEVELOPER_ID_APPLICATION" --timestamp --options runtime \
    "$app_resources_dir/$binary"
done
while IFS= read -r bundle_binary; do
  chmod 755 "$bundle_binary"
  codesign --force --sign "$SPIDERWEB_MACOS_DEVELOPER_ID_APPLICATION" --timestamp --options runtime \
    "$bundle_binary"
done < <(find "$app_resources_dir/spidervenoms" -type f -path '*/bin/*')
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
while IFS= read -r bundle_binary; do
  codesign --verify --strict "$bundle_binary"
done < <(find "$payload_root/usr/local/share/spidervenoms" -type f -path '*/bin/*')

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
