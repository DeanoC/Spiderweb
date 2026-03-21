# Acheron Layer

This folder contains Spiderweb-owned Acheron glue.

It is responsible for:

- session namespace projection
- control-plane integration
- filesystem-style routing and mounting
- standalone namespace client mounting for `spiderweb-fs-mount`
- client/protocol helpers used by the Acheron surface

It is not the authoritative node runtime implementation.
That lives in `deps/spider-protocol/src/spiderweb_node/`.

If a change is about generic node hosting, namespace drivers, or shared runtime behavior, prefer updating the shared protocol runtime instead of growing this folder.

`spiderweb-fs-mount` has one mounted-filesystem model.

- `--workspace-url` asks Spiderweb control to resolve a workspace and attach a namespace session for it.
- `--namespace-url` starts from an already attached Spiderweb namespace session.

Those are different launch inputs to the same Spiderweb-owned namespace view.
Mount backends must reflect that namespace directly; they must not add client
overlays, path bypasses, or backend-specific synthetic exceptions.
When caching is needed for performance, cache the Spiderweb mount graph and
path results from that namespace view. Do not invent alternate path-resolution
rules per backend.
Session-side workspace mount proxies follow the same rule: if Spiderweb is
proxying a workspace-mounted node export, it should route back through
Spiderweb's routed `/v2/fs/node/<node_id>` authority with the mount auth token
instead of depending on a separate raw node `fs_url` path.

Direct endpoint routing still exists as a standalone protocol utility, but it is
not a Spiderweb workspace path. It must not mount into Spiderweb-owned roots
such as `/nodes`, `/services`, `/shared_data`, `/.spiderweb`, or `/meta`.
