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

## Runtime infrastructure moved out of this directory

The non-venom runtime helpers that used to live here now live under
`src/runtime/`:

- `src/runtime/mcp_client.zig`
- `src/runtime/fs/`
- `src/runtime/terminal_namespace.zig`
- `src/runtime/git_namespace.zig`

`src/runtime/fs/` is especially important to classify correctly: it is part of
Spiderweb's base filesystem/runtime capability surface and compatibility layer,
not a published first-party venom bundle to extract into `SpiderVenoms`.

`src/runtime/terminal_namespace.zig` and `src/runtime/git_namespace.zig` follow
the same rule: they are Spiderweb session/runtime compatibility adapters that
project namespace files onto local runtime behavior. They are not the
long-term home of first-party terminal or git capability ownership.

## Current extraction guidance

- Keep `packages`, `home`, `runtimes`, `mounts`, `workspaces`, and `events` in Spiderweb.
- Keep `src/runtime/fs` as runtime/base-capability ownership, with generic node behavior continuing to move into SpiderNode where appropriate.
- Continue treating terminal and git namespace support as transitional compatibility code under `src/runtime/` until the remaining local namespace/session assumptions are removed.
- Do not add new first-party capability venom implementations to this directory.
