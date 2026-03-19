# Spiderweb macOS Installer UX

## Goal

Ship one notarized macOS installer that works on a normal SIP-enabled Mac and gives users a clean setup flow for three real use cases:

1. Run Spiderweb locally on this Mac and mount that local Spiderweb workspace.
2. Install only the native macOS mount support and connect to an existing Spiderweb server.
3. Pair this Mac to a remote Spiderweb and expose its local filesystem as a remote node.

The core rule is:

- the `.pkg` installs system bits
- the app guides setup
- the CLI remains available for power users and automation

## Product Decision

Use **one installer package**, not two.

Why:

- both paths need the same privileged install locations:
  - `/Applications`
  - `/Library/Filesystems`
  - `/usr/local/bin`
- separate packages would fragment docs and support
- the meaningful difference is not what gets copied to disk, but which setup steps the user chooses afterward

So the package should install the full Spiderweb macOS surface, and the first-run app flow should ask what the user wants to do.

## Installed Payload

The macOS installer should install:

- `/Applications/Spiderweb.app`
  - main app / menu bar app / setup UI / status UI
- `/Library/Filesystems/spiderweb.fs`
  - native filesystem bundle
- `/usr/local/bin/spiderweb`
- `/usr/local/bin/spiderweb-config`
- `/usr/local/bin/spiderweb-control`
- `/usr/local/bin/spiderweb-fs-mount`
- `/usr/local/bin/spiderweb-fs-node`

The user-facing product should be a single visible `Spiderweb.app`, with the FSKit host/runtime remaining internal to that shipped app shape.

## Installer Responsibilities

The installer should:

- copy the signed app, filesystem bundle, and CLI tools into place
- register the filesystem bundle and FSKit app with LaunchServices / PlugInKit
- not silently enable the filesystem extension
- not silently install/start the background Spiderweb service
- offer to launch the app when installation completes

The installer should **not** try to complete user-consent steps that macOS owns:

- enabling `Spiderweb file system` in `System Settings -> Login Items & Extensions -> File System Extensions`
- approving any extension-related Settings flow macOS requires

## First-Run App Flow

After install, the app should open a simple setup wizard.

### Step 1: Choose Setup Mode

Present three options:

- `Run Spiderweb on this Mac` (Recommended)
- `Mount an existing Spiderweb`
- `Provide This Mac to a Remote Spiderweb`

Short explanations:

- `Run Spiderweb on this Mac`
  - installs and starts the local Spiderweb background service
  - generates local auth
  - enables this Mac to host workspaces
  - also prepares native Finder/CLI mounts
- `Mount an existing Spiderweb`
  - prepares native macOS mounting only
  - for users connecting to a remote Spiderweb server
- `Provide This Mac to a Remote Spiderweb`
  - installs and starts the local Spiderweb service
  - pairs this Mac to one remote Spiderweb via invite token
  - exposes this Mac's filesystem to that remote Spiderweb

## Path A: Run Spiderweb On This Mac

This is the recommended path for CodexApp / local-agent users.

### Desired flow

1. `Install background service`
   - invoke the equivalent of `spiderweb-config config install-service`
   - show running status inline
2. `Set up local auth`
   - ensure tokens exist
   - show a masked status, with a reveal/copy action for advanced users
3. `Enable Spiderweb file system`
   - show current enablement state
   - button: `Open System Settings`
   - explain that this step is required by macOS
4. `Create first local workspace`
   - offer a default workspace
   - optionally point at a local project directory
5. `Mount local Spiderweb`
   - one-click action for the app path
   - also show the equivalent CLI command
6. `Use with agents`
   - show the mounted path
   - show the `SpiderMonkey` / Codex-oriented path to use

### Success state

The app should end with a simple green status view:

- `Spiderweb service: running`
- `Filesystem extension: enabled`
- `Local workspace: ready`
- `Mount path: ~/Spiderweb/<workspace-name>` or similar

## Path B: Mount An Existing Spiderweb

This is the lightweight path for people who already have a server elsewhere.

### Desired flow

1. `Enable Spiderweb file system`
   - same Settings handoff as Path A
2. `Add connection`
   - fields:
     - server URL
     - project/workspace id
     - auth token
   - allow saving named connections locally
3. `Test connection`
   - verify control-plane reachability and auth
4. `Mount`
   - choose a mountpoint
   - mount via the native `spiderweb` backend

### Success state

- `Filesystem extension: enabled`
- `Connection: verified`
- `Mount path: <user-selected path>`

## “Nice” UX Requirements

### Good defaults

- default local service bind: `127.0.0.1:18790`
- default local mount backend on macOS: native FSKit
- default local mountpoint suggestion:
  - `~/Spiderweb/<workspace-name>`

### No required Terminal usage for normal setup

A normal user should be able to:

- install the package
- choose one of the two setup modes
- enable the extension in Settings
- end up with a running service or a mounted remote workspace

without having to manually type commands.

### Keep the CLI authoritative

Even with a nice app flow:

- the app should call the real CLI/config machinery under the hood
- setup actions should remain scriptable
- the UI should display the equivalent command for advanced users

## Recommended Implementation Shape

### Phase 1: Reuse the current pieces

Use the current package plus current CLI commands, and add a real setup UI on top:

- service install/start:
  - `spiderweb-config config install-service`
- service status:
  - `spiderweb-config config service-status`
- FSKit install:
  - already handled by the package
- FSKit status:
  - `spiderweb-config config fs-extension-status`
- auth status:
  - `spiderweb-config auth status`
- mount:
  - `spiderweb-fs-mount --mount-backend native ...`

This gets us to a polished user experience without redesigning the runtime again.

### Current app scope

The shipped app UX is now a real `Spiderweb.app`:

- setup wizard
- menu bar app
- service status
- mount status
- saved remote connections
- remote node pairing
- known limitations

The FSKit host can remain a helper/internal detail if needed.

## macOS Constraints To Respect

The setup flow must explicitly acknowledge these platform boundaries:

- FSKit enablement requires a user action in System Settings
- owner/group changes are unsupported on the native mount because the volume is currently `noowners`
- advisory locks are mount-local only
- out-of-band edits made directly on the underlying host path to an already-seen file may remain stale until reopen/remount

These should be explained as limitations, not hidden.

## Suggested First Shipping Scope

For the first polished public installer, “nice enough” means:

- notarized `.pkg`
- installs all required binaries and filesystem bundle
- opens the app on completion
- app offers the three-path setup choice
- app can:
  - install/start the local service
  - show auth status
  - deep-link the user into the FSKit enable flow
  - verify readiness
  - mount a local or remote Spiderweb
  - pair this Mac to one remote Spiderweb as a filesystem node
- docs match the real product flow

That is enough for a credible macOS release.

## Recommended Next Tasks

1. Add one-click service start/stop and install/uninstall flows directly in the app.
2. Add auto-remount and saved-mount lifecycle polish.
3. Add remote-node disconnect/delete UX and richer status/error handling.
4. Update the installer to launch the app on completion.
5. Update docs/screenshots to match the two-path setup flow.
