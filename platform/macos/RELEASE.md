# macOS Release Packaging

This release path is for shipping Spiderweb to a normal SIP-enabled Mac as a signed, notarized installer package.

For the intended end-user setup experience after install, see [INSTALLER_UX.md](/Users/deanocalver/Documents/Spider/Spiderweb/platform/macos/INSTALLER_UX.md).

## Release model

Use a flat `.pkg`, not a drag-and-drop app bundle.

Why:

- Spiderweb needs to install `Spiderweb.app` into `/Applications`
- the native filesystem wrapper bundle must live in `/Library/Filesystems/spiderweb.fs`
- the CLI binaries belong in a standard executable location such as `/usr/local/bin`
- a signed installer package is the normal macOS distribution path for writing into those system locations on a regular Mac with SIP enabled

The package should be:

- signed with a `Developer ID Installer` certificate
- notarized with `notarytool`
- stapled before release

The app, extension, filesystem bundle, helper, and CLI binaries inside the package should be signed with a `Developer ID Application` identity.

## Apple requirements

Spiderweb’s native macOS mount uses an FSKit file system extension, so the release build needs Apple capabilities as well as code signing:

- `com.deanoc.spiderweb.fskit.app`
- `com.deanoc.spiderweb.fskit.app.extension`
- `FSKit Module` enabled for the extension App ID
- Developer ID provisioning profiles for the app and extension, because this is an advanced capability being distributed outside the Mac App Store

Apple references:

- [Supported capabilities (macOS)](https://developer.apple.com/help/account/reference/supported-capabilities-macos)
- [Create Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- [Provisioning with managed capabilities](https://developer.apple.com/help/account/reference/provisioning-with-managed-capabilities/)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)

## What the package installs

The release package stages:

- `/Applications/Spiderweb.app`
- `/Library/Filesystems/spiderweb.fs`
- `/usr/local/bin/spiderweb`
- `/usr/local/bin/spiderweb-config`
- `/usr/local/bin/spiderweb-control`
- `/usr/local/bin/spiderweb-fs-mount`
- `/usr/local/bin/spiderweb-fs-node`

The postinstall step also registers the FSKit app and filesystem bundle with `pluginkit` and `lsregister`.

## Build the package

The scripted release entrypoint is:

```bash
cd /Users/deanocalver/Documents/Spider/Spiderweb
SPIDERWEB_MACOS_TEAM_ID="TEAMID1234" \
SPIDERWEB_MACOS_DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID1234)" \
SPIDERWEB_MACOS_DEVELOPER_ID_INSTALLER="Developer ID Installer: Your Name (TEAMID1234)" \
SPIDERWEB_MACOS_APP_PROFILE="/path/to/Spiderweb_DeveloperID.provisionprofile" \
SPIDERWEB_MACOS_EXTENSION_PROFILE="/path/to/SpiderwebFSKitExtension_DeveloperID.provisionprofile" \
SPIDERWEB_MACOS_NOTARY_PROFILE="spiderweb-notary" \
./platform/macos/scripts/package-spiderweb-macos-release.sh
```

Optional flags:

- `--version <version>`
- `--out-dir <dir>`
- `--skip-notarize`

By default the script:

- builds the Zig CLI payload for the current host architecture
- archives and exports `Spiderweb.app` for `developer-id` distribution
- builds a signed `spiderweb.fs` wrapper bundle
- builds a signed flat installer package
- notarizes and staples the package when `SPIDERWEB_MACOS_NOTARY_PROFILE` is set

Current note:

- the first scripted release path packages the CLI tools and filesystem helper for the architecture of the Mac running the release build
- that means build on Apple Silicon for Apple Silicon distribution, or build on Intel for Intel distribution
- a fully universal CLI release is still future work

The default output path is:

```text
platform/macos/dist/Spiderweb-macos-<version>.pkg
```

## Expected install UX on a user Mac

After opening the notarized installer package on a regular Mac:

1. The installer copies the app, filesystem bundle, and CLI tools into place.
2. The installer launches `Spiderweb.app`, which provides the menu bar app, setup flow, and saved-mount UI.
3. The user enables `Spiderweb file system` in:
   `System Settings -> General -> Login Items & Extensions -> File System Extensions`
4. The user optionally installs the Spiderweb user service:
   `spiderweb-config config install-service`
5. The user mounts with:
   `spiderweb-fs-mount --mount-backend native ...`

No SIP changes should be required.

## Current known native-mount limitations

The package ships the same native runtime that is already working in development:

- out-of-band host edits to an already-seen file can remain stale until reopen or remount
- owner/group changes are unsupported because the current FSKit volume mounts as `noowners`
- hard links are unsupported
- advisory locks are mount-local only
