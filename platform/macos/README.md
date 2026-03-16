# SpiderwebFSKit

This directory contains the native macOS FSKit app/extension for Spiderweb's
first-party mount backend.

Current scope:
- containing app bundle: `SpiderwebFSKit.app`
- FSKit extension target: `SpiderwebFSKitExtension`
- native filesystem bundle: `spiderweb.fs`
- Swift mount helper: `mount_spiderweb`
- CLI install hooks: `spiderweb-config config install-fs-extension`

Current status:
- the Zig-side install/status CLI and request file flow are implemented in the
  main repo
- the Swift app/extension runtime is now aligned with the working Apple
  passthrough sample shape: pure Swift, `FSUnaryFileSystem`, request-file
  driven, and focused on the read path first
- the Spiderweb namespace surface is currently read-only in this milestone;
  mutation calls intentionally return read-only errors
- the runtime now includes a fail-fast timeout layer so bad paths time out and
  cool down instead of wedging the whole mount during bring-up
- native auto-selection remains gated until the app bundle has been smoke-tested
  with a paid Apple Developer team that preserves the FSKit and App Group
  entitlements
- Xcode Personal Team / free signing is not sufficient: macOS registers the
  module, but strips the required entitlements and leaves the FSKit module
  disabled

Useful environment knobs while debugging:
- `SPIDERWEB_FSKIT_TIMEOUT_MS`
  Per-operation timeout for Spiderweb bridge calls. Default: `2000`.
- `SPIDERWEB_FSKIT_FAIL_FAST_MS`
  Cooldown for a path after a timeout. Repeated access to the same stalled path
  fails fast during this window instead of re-entering the backend. Default:
  `10000`.

Build flow:
1. Install full Xcode 16+ and select it with `sudo xcode-select -s`.
2. Install `xcodegen`.
3. Create/download macOS development provisioning profiles for:
   - `com.deanoc.spiderweb.fskit.app`
   - `com.deanoc.spiderweb.fskit.app.extension`
4. Run `platform/macos/scripts/build-fskit-app.sh`.
   - the script auto-discovers matching profiles in `~/Downloads` or `~/Library/MobileDevice/Provisioning Profiles`
   - you can override them with `SPIDERWEB_FSKIT_APP_PROFILE` and `SPIDERWEB_FSKIT_EXTENSION_PROFILE`
   - the signed install artifacts are staged at:
     - `platform/macos/build/install-source/SpiderwebFSKit.install-source.zip`
     - `platform/macos/build/install-source/spiderweb.fs.install-source.zip`
   - the script removes the transient `DerivedData` app copy afterward so macOS does not discover a second, stale FSKit bundle
5. Install the resulting app with `./zig-out/bin/spiderweb-config config install-fs-extension`.
6. Check `./zig-out/bin/spiderweb-config config fs-extension-status` and verify
   `app_group_entitlements`, `extension_fs_entitlement`, `app_provisioned`,
   `extension_provisioned`, and `module_enabled` are all `yes`.

Verification flow on a macOS development machine:
1. `platform/macos/scripts/typecheck-fskit-swift.sh`
2. `platform/macos/scripts/build-fskit-app.sh`
3. `./zig-out/bin/spiderweb-config config fs-extension-status`

The native backend is intentionally staged. On machines without a paid Apple
Developer team that preserves those entitlements, `--mount-backend fuse`
remains the reliable macOS path, and `--mount-backend auto` intentionally
sticks to that macFUSE default until the native backend is fully validated.

Current reality from local testing:
- the shipped macOS fallback is still `macFUSE`, because it does not require
  Spiderweb-specific Apple entitlements
- on our current macOS 26.3.1 development machine, `macFUSE` has still been
  flaky even after reinstall, approval, PlugInKit refresh, and reboot
- that means the native backend is now the preferred development target as soon
  as a paid Apple Developer identity is available and preserving the required
  entitlements
