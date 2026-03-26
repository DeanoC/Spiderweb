# Venom Boundary Notes

This directory still mixes several different kinds of surfaces. It should not be
treated as "everything here is a first-party venom that belongs in Spiderweb."

## Control-plane surfaces that stay in Spiderweb

These are Spiderweb-owned control substrates or workspace orchestration surfaces:

- `packages.zig`
- `home.zig`
- `runtimes.zig`
- `mounts.zig`
- `workspaces.zig`
- `events.zig`

They project Spiderweb session/control-plane behavior into namespace files and
remain part of the host.

## Legacy compatibility or transitional local capability surfaces

These are older local namespace-backed implementations that overlap with
published first-party capability venoms now owned by `SpiderVenoms`:

- `terminal.zig`
- `git.zig`

They are still used by the compatibility/session layer today, but they should
not be treated as the long-term home of first-party capability behavior.

## Runtime infrastructure, not venom surfaces

These files support venom execution or filesystem plumbing, but they are not
themselves the extracted first-party venom packages:

- `mcp_client.zig`
- `fs/`

`fs/` is especially important to classify correctly: it is part of Spiderweb's
base filesystem/runtime capability surface and compatibility layer, not a
published first-party venom bundle to extract into `SpiderVenoms`.

## Current extraction guidance

- Keep `packages`, `home`, `runtimes`, `mounts`, `workspaces`, and `events` in Spiderweb.
- Keep `fs` as runtime/base-capability ownership, with generic node behavior continuing to move into SpiderNode where appropriate.
- Continue treating `terminal` and `git` in this directory as transitional compatibility code until the remaining local namespace/session assumptions are removed.
- Do not add new first-party capability venom implementations to this directory.
