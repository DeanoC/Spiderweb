#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$MACOS_DIR/../.." && pwd)"
PROJECT_SPEC="$MACOS_DIR/project.yml"
PROJECT_PATH="$MACOS_DIR/SpiderwebFSKit.xcodeproj"
DERIVED_DATA_PATH="$MACOS_DIR/build/DerivedData"
GENERATED_CONFIG_DIR="$MACOS_DIR/build/generated"
STAGED_OUTPUT_DIR="$MACOS_DIR/build/install-source"
APP_ENTITLEMENTS_TEMPLATE="$MACOS_DIR/Config/SpiderwebFSKit.entitlements.in"
EXTENSION_ENTITLEMENTS_TEMPLATE="$MACOS_DIR/Config/SpiderwebFSKitExtension.entitlements.in"
FILESYSTEM_BUNDLE_TEMPLATE="$MACOS_DIR/Config/spiderweb.fs-Info.plist"
MOUNT_HELPER_SOURCE="$MACOS_DIR/Sources/SpiderwebFSMountHelper/main.swift"
APP_ENTITLEMENTS_PATH="$GENERATED_CONFIG_DIR/SpiderwebFSKit.entitlements"
EXTENSION_ENTITLEMENTS_PATH="$GENERATED_CONFIG_DIR/SpiderwebFSKitExtension.entitlements"
APP_BUNDLE_ID="com.deanoc.spiderweb.fskit.app"
EXTENSION_BUNDLE_ID="com.deanoc.spiderweb.fskit.app.extension"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/SpiderwebFSKit.app"
STAGED_ARCHIVE_PATH="$STAGED_OUTPUT_DIR/SpiderwebFSKit.install-source.zip"
FILESYSTEM_BUNDLE_NAME="spiderweb.fs"
MOUNT_HELPER_NAME="mount_spiderweb"
MOUNT_HELPER_BUILD_DIR="$MACOS_DIR/build/mount-helper"
MOUNT_HELPER_PATH="$MOUNT_HELPER_BUILD_DIR/$MOUNT_HELPER_NAME"
FILESYSTEM_BUNDLE_PATH="$STAGED_OUTPUT_DIR/$FILESYSTEM_BUNDLE_NAME"
FILESYSTEM_BUNDLE_ARCHIVE_PATH="$STAGED_OUTPUT_DIR/$FILESYSTEM_BUNDLE_NAME.install-source.zip"
APP_PROFILE_DEST="$APP_PATH/Contents/embedded.provisionprofile"
EXTENSION_PROFILE_DEST="$APP_PATH/Contents/Extensions/SpiderwebFSKitExtension.appex/Contents/embedded.provisionprofile"
RUNTIME_READY_MANIFEST="$APP_PATH/Contents/Resources/SpiderwebFSKit.runtime-ready"
DEVELOPMENT_TEAM="${SPIDERWEB_FSKIT_DEVELOPMENT_TEAM:-}"
CODE_SIGN_IDENTITY_NAME="${SPIDERWEB_FSKIT_CODE_SIGN_IDENTITY:-Apple Development}"
LOGIN_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
APP_PROFILE_PATH="${SPIDERWEB_FSKIT_APP_PROFILE:-}"
EXTENSION_PROFILE_PATH="${SPIDERWEB_FSKIT_EXTENSION_PROFILE:-}"

if [[ -z "${DEVELOPER_DIR:-}" && -x "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

if ! command -v xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  echo "xcodebuild is required. Install full Xcode 16+ and select it with xcode-select." >&2
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required to generate platform/macos/SpiderwebFSKit.xcodeproj." >&2
  echo "Install it with Homebrew: brew install xcodegen" >&2
  exit 1
fi

if [[ -z "$DEVELOPMENT_TEAM" ]]; then
  DEVELOPMENT_TEAM="$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null | awk -F'= ' '/teamID = / {gsub(/["; ]/, "", $2); print $2; exit}')"
fi

if [[ -z "$DEVELOPMENT_TEAM" ]]; then
  echo "No Xcode development team was found. Sign into Xcode and ensure a team is available, or set SPIDERWEB_FSKIT_DEVELOPMENT_TEAM." >&2
  exit 1
fi

render_entitlements_template() {
  local template_path="$1"
  local output_path="$2"
  sed \
    -e "s/__DEVELOPMENT_TEAM__/${DEVELOPMENT_TEAM}/g" \
    -e "s/__APP_BUNDLE_ID__/${APP_BUNDLE_ID}/g" \
    -e "s/__EXTENSION_BUNDLE_ID__/${EXTENSION_BUNDLE_ID}/g" \
    "$template_path" >"$output_path"
}

profile_field() {
  local profile_path="$1"
  local plist_key="$2"
  local tmp_plist
  tmp_plist="$(mktemp)"
  security cms -D -i "$profile_path" >"$tmp_plist"
  /usr/libexec/PlistBuddy -c "Print :${plist_key}" "$tmp_plist" 2>/dev/null || true
  rm -f "$tmp_plist"
}

install_provisioning_profile() {
  local source_path="$1"
  local uuid
  local install_dir="${HOME}/Library/MobileDevice/Provisioning Profiles"
  local installed_path

  uuid="$(profile_field "$source_path" "UUID")"
  if [[ -z "$uuid" ]]; then
    echo "Could not read UUID from provisioning profile: $source_path" >&2
    exit 1
  fi

  mkdir -p "$install_dir"
  installed_path="$install_dir/${uuid}.provisionprofile"
  cp "$source_path" "$installed_path"
  xattr -d com.apple.quarantine "$installed_path" >/dev/null 2>&1 || true
  xattr -d com.apple.metadata:kMDItemWhereFroms "$installed_path" >/dev/null 2>&1 || true
  printf '%s\n' "$installed_path"
}

find_profile_for_bundle_id() {
  local bundle_id="$1"
  local expected_app_id="${DEVELOPMENT_TEAM}.${bundle_id}"
  local candidate
  local app_id

  shopt -s nullglob
  for candidate in \
    "${HOME}"/Library/MobileDevice/Provisioning\ Profiles/*.provisionprofile \
    "${HOME}"/Library/MobileDevice/Provisioning\ Profiles/*.mobileprovision \
    "${HOME}"/Downloads/*.provisionprofile \
    "${HOME}"/Downloads/*.mobileprovision; do
    [[ -f "$candidate" ]] || continue
    app_id="$(profile_field "$candidate" "Entitlements:com.apple.application-identifier")"
    if [[ "$app_id" == "$expected_app_id" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

if [[ -z "$APP_PROFILE_PATH" ]]; then
  APP_PROFILE_PATH="$(find_profile_for_bundle_id "$APP_BUNDLE_ID" || true)"
fi

if [[ -z "$EXTENSION_PROFILE_PATH" ]]; then
  EXTENSION_PROFILE_PATH="$(find_profile_for_bundle_id "$EXTENSION_BUNDLE_ID" || true)"
fi

if [[ -z "$APP_PROFILE_PATH" || ! -f "$APP_PROFILE_PATH" ]]; then
  echo "No provisioning profile found for ${APP_BUNDLE_ID}. Download it from Apple or set SPIDERWEB_FSKIT_APP_PROFILE." >&2
  exit 1
fi

if [[ -z "$EXTENSION_PROFILE_PATH" || ! -f "$EXTENSION_PROFILE_PATH" ]]; then
  echo "No provisioning profile found for ${EXTENSION_BUNDLE_ID}. Download it from Apple or set SPIDERWEB_FSKIT_EXTENSION_PROFILE." >&2
  exit 1
fi

APP_PROFILE_PATH="$(install_provisioning_profile "$APP_PROFILE_PATH")"
EXTENSION_PROFILE_PATH="$(install_provisioning_profile "$EXTENSION_PROFILE_PATH")"

mkdir -p "$MACOS_DIR/build"
mkdir -p "$GENERATED_CONFIG_DIR"
mkdir -p "$STAGED_OUTPUT_DIR"
mkdir -p "$MOUNT_HELPER_BUILD_DIR"
render_entitlements_template "$APP_ENTITLEMENTS_TEMPLATE" "$APP_ENTITLEMENTS_PATH"
render_entitlements_template "$EXTENSION_ENTITLEMENTS_TEMPLATE" "$EXTENSION_ENTITLEMENTS_PATH"
xcodegen generate --spec "$PROJECT_SPEC"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme SpiderwebFSKit \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY_NAME" \
  CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
  build

# Xcode mutates the generated entitlements while producing its `.xcent` files.
# Restore the checked-in templates before the final manual re-sign pass so the
# app bundle keeps the intended App Group / FSKit entitlements.
render_entitlements_template "$APP_ENTITLEMENTS_TEMPLATE" "$APP_ENTITLEMENTS_PATH"
render_entitlements_template "$EXTENSION_ENTITLEMENTS_TEMPLATE" "$EXTENSION_ENTITLEMENTS_PATH"

mkdir -p "$(dirname "$RUNTIME_READY_MANIFEST")"
: >"$RUNTIME_READY_MANIFEST"
cp "$APP_PROFILE_PATH" "$APP_PROFILE_DEST"
cp "$EXTENSION_PROFILE_PATH" "$EXTENSION_PROFILE_DEST"
xattr -d com.apple.quarantine "$APP_PROFILE_DEST" >/dev/null 2>&1 || true
xattr -d com.apple.metadata:kMDItemWhereFroms "$APP_PROFILE_DEST" >/dev/null 2>&1 || true
xattr -d com.apple.quarantine "$EXTENSION_PROFILE_DEST" >/dev/null 2>&1 || true
xattr -d com.apple.metadata:kMDItemWhereFroms "$EXTENSION_PROFILE_DEST" >/dev/null 2>&1 || true

if [[ "$CODE_SIGN_IDENTITY_NAME" == "Apple Development" ]]; then
  RESOLVED_CODE_SIGN_IDENTITY="$(
    security find-certificate -a -c 'Apple Development' -Z "$LOGIN_KEYCHAIN" 2>/dev/null |
      awk -v team="$DEVELOPMENT_TEAM" '
        /^SHA-1 hash:/ { sha = $3 }
        /"subj"<blob>=/ {
          if (index($0, team) > 0) {
            print sha
            exit
          }
        }
      '
  )"
  if [[ -z "$RESOLVED_CODE_SIGN_IDENTITY" ]]; then
    RESOLVED_CODE_SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'\"' '/Apple Development/ {print $2; exit}')"
  fi
  if [[ -n "$RESOLVED_CODE_SIGN_IDENTITY" ]]; then
    CODE_SIGN_IDENTITY_NAME="$RESOLVED_CODE_SIGN_IDENTITY"
  fi
fi

codesign --force --sign "$CODE_SIGN_IDENTITY_NAME" --entitlements "$EXTENSION_ENTITLEMENTS_PATH" "$APP_PATH/Contents/Extensions/SpiderwebFSKitExtension.appex"
codesign --force --sign "$CODE_SIGN_IDENTITY_NAME" --entitlements "$APP_ENTITLEMENTS_PATH" "$APP_PATH"

xcrun swiftc \
  -target arm64-apple-macos15.4 \
  -O \
  -o "$MOUNT_HELPER_PATH" \
  "$MOUNT_HELPER_SOURCE"
codesign --force --sign "$CODE_SIGN_IDENTITY_NAME" "$MOUNT_HELPER_PATH"

rm -rf "$FILESYSTEM_BUNDLE_PATH"
mkdir -p "$FILESYSTEM_BUNDLE_PATH/Contents/Resources"
cp "$FILESYSTEM_BUNDLE_TEMPLATE" "$FILESYSTEM_BUNDLE_PATH/Contents/Info.plist"
cp "$MOUNT_HELPER_PATH" "$FILESYSTEM_BUNDLE_PATH/Contents/Resources/$MOUNT_HELPER_NAME"
chmod 755 "$FILESYSTEM_BUNDLE_PATH/Contents/Resources/$MOUNT_HELPER_NAME"
codesign --force --sign "$CODE_SIGN_IDENTITY_NAME" "$FILESYSTEM_BUNDLE_PATH/Contents/Resources/$MOUNT_HELPER_NAME"
codesign --force --sign "$CODE_SIGN_IDENTITY_NAME" "$FILESYSTEM_BUNDLE_PATH"

rm -rf "$STAGED_OUTPUT_DIR/SpiderwebFSKit.install-source"
rm -f "$STAGED_ARCHIVE_PATH"
ditto -c -k --keepParent "$APP_PATH" "$STAGED_ARCHIVE_PATH"
rm -f "$FILESYSTEM_BUNDLE_ARCHIVE_PATH"
ditto -c -k --keepParent "$FILESYSTEM_BUNDLE_PATH" "$FILESYSTEM_BUNDLE_ARCHIVE_PATH"

# Keep PlugInKit focused on the staged signed bundle and avoid UI confusion from
# the transient Xcode build product still living under DerivedData.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP_PATH" >/dev/null 2>&1 || true
pluginkit -r "$APP_PATH/Contents/Extensions/SpiderwebFSKitExtension.appex" >/dev/null 2>&1 || true
rm -rf "$APP_PATH"

echo "$STAGED_ARCHIVE_PATH"
