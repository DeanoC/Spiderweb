# Changelog

All notable changes to this project are documented in this file.

## 0.5.3 - 2026-03-26

### Venom Trust Policy
- Added explicit bundle-signing key policy states in Spiderweb so revoked keys and keys without managed-local bundle trust are rejected even if the signature bytes are otherwise valid.
- Added dedicated negative-path signature tests covering tampered payloads, revoked keys, and wrong-purpose keys.
- Re-pinned Spiderweb’s managed bundle dependency to the published signed `SpiderVenoms v0.5.7` assets across Linux `arm64`, Linux `x86_64`, and macOS `arm64`.

## 0.5.2 - 2026-03-26

### Venom Trust
- Added real managed-bundle signature verification in Spiderweb’s local-node supervisor, including digest validation, trusted signing-key lookup, and signed-manifest checks before rendering or staging local venom metadata.
- Re-pinned published Spiderweb packaging and install flows to `SpiderVenoms v0.5.6`, the first fully signed cross-platform managed-bundle release line.

## 0.5.1 - 2026-03-26

### Release and Versioning
- Standardized the public Spiderweb release line on `0.5.1` after the internal `0.5.0` cut was treated as a busted pre-release.
- Added maintainer tooling and CI checks so Zig metadata, runtime strings, and the macOS app version stay in sync.
- Added a tag-driven Linux release workflow that builds the archive, smoke-tests an installed-artifact boot, and publishes the release assets.

### Venom Packaging and Installed Runtime
- Completed the managed-local venom extraction so SpiderVenoms owns the bundle payload and Spiderweb consumes installed bundle artifacts.
- Added Linux release packaging for `share/spiderweb/templates` and `share/spidervenoms/bundles/managed-local`.
- Pinned Spiderweb packaging and install flows to the published `SpiderVenoms v0.5.2` release assets, with explicit source fallback for unsupported development architectures.
- Documented the `src/venoms` boundary so `fs` remains a base/runtime capability, control-plane surfaces stay in Spiderweb, and transitional compatibility code is called out clearly.
- Verified the release-style install and boot flow end to end in Ubuntu before publishing artifacts.

## 0.3.2 - 2026-03-19

### Windows Mounts and Remote Namespace
- Moved the Windows mount path onto the shared native mount helper/library flow used by the newer high-performance mount stack.
- Added `spiderweb-fs-helper.exe` to the Windows install/build flow and taught the WinFsp client to launch it with fallback to the legacy in-process path.
- Verified remote Windows namespace mounts against a live Spiderweb server, including routed read/write and a real WinFsp OS mount.

### Windows Build and Runtime Cleanup
- Removed the extracted `ziggy-memory-store` persistence path from Spiderweb and switched the control plane to the in-memory startup path.
- Dropped stale `sandbox_enabled` gating and old `mount_*_v2` namespace control branches that no longer match the current workspace-first model.
- Updated the pinned `zwasm` branch and local wrapper so the full `zig build` succeeds on Windows.
### Remote Connectivity and Packaging
- Fixed remote workspace status and mount graph endpoint URLs so routed `/fs` operations no longer leak `127.0.0.1` to other machines.
- Defaulted new and upgraded installs to LAN-reachable server binds and surfaced that reachability clearly in the macOS app.
- Kept the macOS packaged filesystem repair path self-contained so installed builds do not depend on a local Xcode checkout.

## 0.3.1 - 2026-03-13

### External Agent Machine Independence
- Closed the strict external-agent machine-independence path for the Spiderweb + external Codex E2E harness.
- Added namespace-backed terminal execution so bridged shell commands see the same `/meta`, `/projects`, `/services`, `/shared_data`, and `/nodes` surfaces as the attached agent.
- Fixed mounted venom control-file behavior to commit buffered writes on close, which makes normal append/close writer behavior reliable for service control files.
- Added bridge-runtime helper shims and stricter usage-report parsing so release-backed runs can distinguish real host leakage from local bridge-runtime execution.
- Release-backed strict live runs now report `reliability_ok=true`, `workspace_bootstrap_ok=true`, and `machine_independence_ok=true`.

### Runtime Convergence

### Runtime Convergence
- Converged Spiderweb’s built-in namespace surfaces onto the shared `spiderweb_node` runtime path, including the in-process FS host and embeddable `spiderweb_fs` facade.
- Removed repo-local FS runtime ownership by replacing legacy `src/fs_node_*` and related adapter surfaces with compatibility shims over the shared runtime modules.

### Venoms and Discovery
- Promoted Venom naming to the primary discovery surface across docs and templates.
- Added and documented Venom-first indexes at `/global/venoms/VENOMS.json` and `/nodes/<node_id>/venoms/*` while retaining legacy service aliases for compatibility.
- Moved the node service catalog model into shared `SpiderProtocol` runtime code so Spiderweb and standalone nodes project the same catalog contract.

### Chat, Jobs, Events, and Thoughts
- Unified chat/job execution behind a shared runtime executor and removed split execution behavior between session and local-fs paths.
- Added structured job telemetry for terminal job completion, `/global/events` waits, and `/global/thoughts/*` projection so sessions no longer reparse job logs on demand.
- Moved `ChatJobIndex` into shared `spiderweb_node` runtime code and left Spiderweb’s local import path as a compatibility shim.

## 0.3.0 - 2026-02-22

### Protocol and Contract
- Unified v2 parser contract is now strict:
  - `channel` is required
  - `type` must match the selected channel namespace
  - legacy/implicit compatibility envelopes are rejected
- Added protocol contract tests in `SpiderProtocol` for canonical v2 control/acheron naming and strict envelope validation.

### Control Plane, Projects, and Nodes
- Local spiderweb filesystem node remains protocol-identical to external nodes and is surfaced as a standard project mount endpoint.
- Workspace mount payloads now include `fs_auth_token` for FS session auth propagation.
- Added project-scoped topology delta push events (`control.workspace_topology_delta`) in addition to full refresh events (`control.workspace_topology`).

### Filesystem Routing and Auth
- Added optional FS session auth on `/fs` via `auth_token` in `acheron.t_fs_hello`.
- Added `spiderweb-fs-node --auth-token` and `SPIDERWEB_FS_NODE_AUTH_TOKEN` for auth enforcement on standalone nodes.
- Router now propagates per-endpoint auth token during HELLO negotiation (initial + health probes + event pumps).

### Observability and Health
- Metrics HTTP endpoint now serves:
  - `/metrics` as Prometheus text format
  - `/metrics.json` as JSON (backward-compatible JSON surface retained)
- Added `/livez` and `/readyz` health endpoints.

### Tooling and Integration
- Added `spiderweb-control` CLI for control-plane operations with automatic `control.version` + `control.connect` negotiation.
- Added dedicated integration test wrappers:
  - `test-distributed-workspace-encrypted.sh` (`SPIDERWEB_CONTROL_STATE_KEY_HEX`)
  - `test-distributed-workspace-operator-token.sh` (`SPIDERWEB_CONTROL_OPERATOR_TOKEN`)
- Added operator-token deny/allow assertions into distributed test flow (`ASSERT_OPERATOR_TOKEN_GATE=1`).
- Added long-running soak/chaos harness: `test-distributed-soak-chaos.sh`.

### Docs
- Updated migration guidance in `docs/protocols/spiderweb-fs-migration.md`.
- Updated `README.md` and `test-env/README.md` for auth, metrics, health, and new test targets.
