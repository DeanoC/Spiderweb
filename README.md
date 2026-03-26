# Spiderweb 🕸️

[![CI](https://github.com/DeanoC/Spiderweb/actions/workflows/ci.yml/badge.svg)](https://github.com/DeanoC/Spiderweb/actions/workflows/ci.yml)
[![Zig](https://img.shields.io/badge/Zig-0.15.0-orange.svg)](https://ziglang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Spiderweb is a **workspace host + distributed RPC filesystem** for AI agents. It provides the mounted workspace, nodes, a small public venom set, and the control plane. The agent process itself lives outside Spiderweb and uses the mounted workspace as its contract.

Built in Zig. The Spiderweb workspace host runs on Linux and macOS. The standalone `spiderweb-fs-mount` client has real local mount backends on Linux, Windows, and macOS. On macOS, `--mount-backend auto` now prefers the native `FSKit` backend under `platform/macos` when it is installed and ready, while `macFUSE` remains the explicit fallback. The native path uses a sample-derived pure Swift app/extension runtime with timeout/fail-fast protection, browse/read support across the namespace, and read-write support on mounted export paths such as `/nodes/local/fs`.

## Vision

Spiderweb’s goal is to make agent systems feel like they are navigating a filesystem instead of stitching together bespoke APIs. The current external-agent contract centers on the mounted workspace plus three canonical roots:
- `/.spiderweb/control/*` for workspace composition and runtime/package control
- `/.spiderweb/catalog/*` for discovery and metadata
- `/.spiderweb/venoms/{terminal,git,search_code}` for public capabilities

In short: **Spiderweb hosts the namespace; external runtimes operate through it**.

If that resonates, start with:
- `docs/overview.md`
- `docs/README.md`
- `CODEX_EXTERNAL_AGENT.md` for the current non-Spider-Monkey external-worker path

![Spiderweb](Spiderweb.png)

## Quick Start

### Workspace-First External Worker Flow

This is the current product path.

```bash
# Build Spiderweb
git clone --recurse-submodules https://github.com/DeanoC/Spiderweb.git
cd Spiderweb
zig build

# Optional: inspect or install the native macOS FSKit app/extension
./zig-out/bin/spiderweb-config config fs-extension-status

# Check the local control auth tokens used by spiderweb-control/spiderweb-fs-mount
./zig-out/bin/spiderweb-config auth status --reveal

# Start Spiderweb
./zig-out/bin/spiderweb

# Create a mountable workspace
./zig-out/bin/spiderweb-control \
  --auth-token <admin-token> \
  workspace_up \
  '{"name":"Demo","vision":"Mounted workspace demo","template_id":"dev","activate":false}'

# Mount that workspace into the local filesystem
./zig-out/bin/spiderweb-fs-mount \
  --workspace-url ws://127.0.0.1:18790/ \
  --workspace-id <workspace-id> \
  --auth-token <admin-or-user-token> \
  mount /mnt/spiderweb-demo

# Inspect a workspace-bound venom directly over the control socket
./zig-out/bin/spiderweb-control \
  --auth-token <admin-or-user-token> \
  --workspace-id <workspace-id> \
  mount_file_read \
  '{"path":"/.spiderweb/venoms/computer/health.json","offset":0,"length":4096}'

# macOS local mount example (auto prefers native FSKit when ready)
./zig-out/bin/spiderweb-fs-mount \
  --workspace-url ws://127.0.0.1:18790/ \
  --workspace-id <workspace-id> \
  --auth-token <admin-or-user-token> \
  mount /Volumes/spiderweb-demo

# Start an external worker against the mounted folder
../SpiderMonkey/zig-out/bin/spider-monkey \
  run \
  --agent-id spider-monkey \
  --worker-id spider-monkey-a \
  --workspace-root /mnt/spiderweb-demo
```

## Standalone Mount Client

`spiderweb-fs-mount` can now run as a standalone client on machines that do not host Spiderweb locally. Real local mount backends are currently supported on Linux, Windows, and macOS.

On macOS:
- `--mount-backend auto` prefers the native FSKit path when the app/extension is installed and ready, and falls back to macFUSE only when native is unavailable.
- `native` is the first-party FSKit path under `platform/macos`, with the app/extension bundle serving the namespace directly in Swift. The current checkpoint supports browse/read across the namespace, plus read-write operations on mounted export paths such as `/nodes/local/fs`, and includes timeout/fail-fast guards so bad paths fail quickly instead of wedging the mount.
- `fuse` is the legacy fallback path and still requires macFUSE 5.x.
- `spiderweb-config config install-fs-extension` / `fs-extension-status` manage the native app bundle once it has been built.
- for end-user distribution on normal SIP-enabled Macs, package the native runtime as a signed/notarized `.pkg`; see [platform/macos/RELEASE.md](/Users/deanocalver/Documents/Spider/Spiderweb/platform/macos/RELEASE.md)
- a free Xcode Personal Team is not enough for live native mounts; the bundle also needs macOS development provisioning profiles that authorize the FSKit and App Group entitlements
- on this macOS 26.3.1 machine we have seen `macFUSE` fail with `extensionKit` / `File system named macfuse not found` even after reinstall, approval, and reboot, so treat it as a fallback-of-last-resort rather than the development target
- the current native FSKit mount still comes up as `noowners`, so `chown`/owner-group changes are not supported
- advisory file locks currently work within the mounted Spiderweb view, but are not mirrored back to the underlying host path or other non-FSKit clients
- if a file has already been seen through the mount and is then edited directly on the underlying host path, the mounted view may continue to serve stale data for that file until it is reopened or the mount is remounted; mount-local workflows are unaffected

- `--workspace-url <ws-url>` keeps the existing routed `/fs` mount mode.
- `--namespace-url <ws-url>` connects to the main Spiderweb websocket and mounts the full namespace (`/.spiderweb`, `/agents`, `/nodes`).
- In namespace mode, node-backed filesystem subtrees discovered from workspace topology still route through `/fs`, so regular file mutation keeps working under mounted workspace exports.
- Session-only synthetic paths support `stat`, `readdir`, `read`, and writes to existing writable files. `create`, `unlink`, `mkdir`, `rmdir`, `rename`, and `truncate` return unsupported errors on those paths.

Build only the standalone client:

```bash
zig build fs-mount
zig build test-fs-mount
```

Installers:

- Linux: `./install-fs-mount.sh`
- Windows: `powershell -ExecutionPolicy Bypass -File .\install-fs-mount.ps1`
- Smoke harnesses: `./scripts/acheron-namespace-smoke.sh` and `powershell -ExecutionPolicy Bypass -File .\scripts\acheron-namespace-smoke.ps1`

Examples:

```bash
# Existing routed-FS mode
./zig-out/bin/spiderweb-fs-mount --workspace-url ws://127.0.0.1:18790/ mount /mnt/spiderweb

# macOS routed-FS mode (auto prefers native FSKit when ready)
./zig-out/bin/spiderweb-fs-mount --workspace-url ws://127.0.0.1:18790/ mount /Volumes/spiderweb

# Full namespace mode
./zig-out/bin/spiderweb-fs-mount --namespace-url ws://127.0.0.1:18790/ --workspace-id ws-demo mount /mnt/spiderweb

# macOS full namespace mode (auto prefers native FSKit when ready)
./zig-out/bin/spiderweb-fs-mount --namespace-url ws://127.0.0.1:18790/ --workspace-id ws-demo mount /Volumes/spiderweb

# Namespace smoke harness (low-level commands, optional real mount when SMOKE_USE_OS_MOUNT=1)
SPIDERWEB_WORKSPACE_ID=ws-demo ./scripts/acheron-namespace-smoke.sh
```

This flow has been smoke-tested with:
- `spiderweb`
- `spiderweb-control workspace_up`
- `spiderweb-control workspace_list`
- `spiderweb-fs-mount ... readdir /`

### What Spiderweb Owns

- Workspace creation, topology, control-plane metadata, and workspace tokens.
- Mounted namespace projection through the filesystem mount contract.
- Control substrate under `/.spiderweb/control/*`:
  - workspace home and mounts/binds
  - package lifecycle
  - runtime attach/heartbeat/detach
- Discovery metadata under `/.spiderweb/catalog/*`
- Public capability venoms under `/.spiderweb/venoms/{terminal,git,search_code}`
- Durable per-agent home allocation inside a workspace.
- Ephemeral runtime-node projection and liveness tracking for attached external runtimes.
- Supervision of the internal `spiderweb-local-node` companion process that exports `/nodes/local/fs` plus the local `terminal`, `git`, and `search_code` providers.

### What External Workers Own

- Model/provider configuration and credentials.
- Private loopback services such as runtime-owned `memory` and `sub_brains`.
- Task execution through the mounted workspace plus any runtime-private loopback services they choose to expose.
- Their own process lifecycle outside Spiderweb.

## Notes

- If `runtime.spider_web_root` is empty, Spiderweb uses its current working directory as the default local workspace root.
- If `runtime.spider_web_root` is set, relative runtime paths such as `agents`, `templates`, and `sandbox_fs_mount_bin` are resolved from that root instead of the process launch cwd.
- `spiderweb-config auth path` and `auth status` now resolve auth tokens from the local runtime context instead of assuming an embedded AI setup.
- The happy path no longer uses Mother/system bootstrap or provider setup inside Spiderweb.
- Spider Monkey is the first external worker for this model, but the intent is broader: any agent that can work against a filesystem can use a mounted Spiderweb workspace.
