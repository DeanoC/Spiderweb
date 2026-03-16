# Spiderweb FSKit Prototype

Expose an existing path as its own file system by using the FSKit framework.

## Overview

This is the working Apple sample, transplanted into `Spiderweb` and gradually rebranded.

The app and extension are now Spiderweb-branded, but this stage intentionally preserves the working sample mount activation shape:

- the mount type is still `passthrough`
- the filesystem bundle path is still `/Library/Filesystems/passthrough.fs`
- the filesystem now presents itself to macOS and Finder as `Spiderweb`
- the Apple-managed sample bundle identifiers remain in place for now

After running and installing the prototype, you can use a Terminal command like `mount -t passthrough ~/Documents ~/passthrough-fs` to present the contents of your Documents directory as another file system, mounted at `passthrough-fs`.
The `-t passthrough` flag still tells `mount` to use the preserved sample filesystem type.

This checkout now also has an in-place Spiderweb experiment that keeps the same `passthrough` mount flow.

- If the mounted resource is a local directory, the original sample behavior is unchanged.
- If the mounted resource is a JSON file, the extension treats it as a Spiderweb mount request and serves a read-only Spiderweb namespace through the same FSKit sample extension.

Example:

```bash
mount -t passthrough /path/to/spiderweb-request.json ~/spiderweb-native
```

The Spiderweb experiment now has a fail-fast layer to reduce reboot-worthy hangs while the read path is still being debugged:

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

For more information, see the full article, [Building a passthrough file system](https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system).
