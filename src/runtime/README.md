# Runtime Surfaces

This directory holds Spiderweb runtime and integration code that is not itself
a first-party venom surface.

Current ownership here:

- `mcp_client.zig`: MCP stdio bridge client logic used by `spiderweb-mcp-bridge`
- `fs/`: base filesystem/runtime plumbing, cache policy, mount glue, and
  SpiderNode-backed compatibility shims

These files may support venoms, but they are not the extracted first-party
capability venoms owned by `SpiderVenoms`.
