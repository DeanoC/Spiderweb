# Spiderweb FSKit

Expose an existing path as its own file system by using the FSKit framework.

## Overview

This is the working Apple FSKit sample, transplanted into `Spiderweb` and then converted into the native Spiderweb mount path.

The app and extension are now Spiderweb-branded, and this stage keeps the working sample runtime shape while exposing a Spiderweb wrapper around the known-good sample mount activation path:

- the user-facing mount command is now `mount -t spiderweb ...`
- the filesystem bundle path is now `/Library/Filesystems/spiderweb.fs`
- the filesystem presents itself to macOS and Finder as `Spiderweb`
- the app and extension bundle identifiers now live under `com.deanoc.spiderweb.fskit.*`
- the internal FSKit short name is now `spiderweb`

After running and installing the native mount, you can use a Terminal command like `mount -t spiderweb /path/to/spiderweb-request.json ~/spiderweb-native`.
The `-t spiderweb` flag tells `mount` to use the Spiderweb filesystem bundle installed into `/Library/Filesystems`, and the mounted resource must be a Spiderweb request JSON.

This checkout now has an in-place Spiderweb native mount that keeps the proven sample-derived FSKit runtime while exposing it as `spiderweb` to macOS.

- The mounted resource is a Spiderweb request JSON.
- The extension treats that file as a Spiderweb mount request and serves the Spiderweb namespace through the same FSKit runtime.
- Browse/read works across the projected namespace.
- Mutating filesystem operations currently work on mounted export paths such as `/nodes/local/fs`.
- Symbolic link creation now works on writable mounted exports; hard links remain unsupported.
- Owner/group changes are still unsupported on the native macOS mount because the volume is currently mounted as `noowners`.
- Advisory locks currently only apply inside the mounted Spiderweb view; they are not mirrored back to the underlying host path.
- If a file has already been seen through the mount and is then edited directly on the underlying host path, macOS may continue serving stale contents or mode for that file until it is reopened or the mount is remounted.

Example:

```bash
mount -t spiderweb /path/to/spiderweb-request.json ~/spiderweb-native
```

The Spiderweb experiment now has a fail-fast layer to reduce reboot-worthy hangs while the deeper path semantics are still being debugged:

- `SPIDERWEB_FSKIT_TIMEOUT_MS`
  Per-operation timeout for Spiderweb bridge calls. Default: `2000`.
- `SPIDERWEB_FSKIT_FAIL_FAST_MS`
  Cooldown for a path after a timeout. Repeated access to the same stalled path fails fast during this window instead of re-entering the backend. Default: `10000`.

The request file uses the existing Spiderweb native request shape:

```json
{
  "schema": 1,
  "volume_name": "spiderweb-demo",
  "launch_config": {
    "schema": 1,
    "mountpoint": "/Users/example/spiderweb-demo",
    "workspace_sync_interval_ms": 5000,
    "namespace_keepalive_interval_ms": 60000,
    "endpoints": [],
    "namespace": {
      "namespace_url": "ws://127.0.0.1:18790/",
      "auth_token": "sw-admin_...",
      "project_id": "proj-1",
      "agent_id": "external-...",
      "session_key": "mount-..."
    }
  }
}
```

For background on Apple’s starting point, see [Building a passthrough file system](https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system).

For shipping Spiderweb to a normal SIP-enabled Mac, see the release packaging guide in [RELEASE.md](/Users/deanocalver/Documents/Spider/Spiderweb/platform/macos/RELEASE.md).
For the planned end-user installer and first-run flow, see [INSTALLER_UX.md](/Users/deanocalver/Documents/Spider/Spiderweb/platform/macos/INSTALLER_UX.md).

## Quickstart Regression

Run the onboarding regression checks with:

```bash
./platform/macos/scripts/quickstart-regression.sh
```

That script compiles a temporary Swift harness against `SpiderwebAppController.swift` and verifies the quickstart state machine behaviors that are easy to regress:

- switching presets resets the targeted workspace and drive
- persisted blocked quickstart state resumes cleanly on relaunch
- unrelated workspaces are not accidentally adopted during resume
- already-mounted native drive errors are treated as satisfied only when the drive is actually active

The default Spiderweb first-run preset now uses the dedicated `just_try_it` workspace template instead of the broader `dev` template, so onboarding stays intentionally minimal even if the development template grows over time.
