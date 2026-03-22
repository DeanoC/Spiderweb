const std = @import("std");
const builtin = @import("builtin");
const Config = @import("config.zig");
const connection_dispatcher = @import("connection_dispatcher.zig");
const protocol = @import("spider-protocol").protocol;
const runtime_handle_mod = @import("runtime_handle.zig");
const websocket_transport = @import("websocket_transport.zig");
const control_plane_mod = @import("acheron/control_plane.zig");
const acheron_session_mod = @import("acheron/session.zig");
const server_protocol_validation = @import("server_protocol_validation.zig");
const server_control_scope = @import("server_control_scope.zig");
const server_audit_records = @import("server_audit_records.zig");
const server_control_plane_controls = @import("server_control_plane_controls.zig");
const server_control_payloads = @import("server_control_payloads.zig");
const server_mount_graph_io = @import("server_mount_graph_io.zig");
const server_mount_controls = @import("server_mount_controls.zig");
const server_local_node_supervisor = @import("server_local_node_supervisor.zig");
const server_metrics_http = @import("server_metrics_http.zig");
const server_namespace_sessions = @import("server_namespace_sessions.zig");
const server_session_controls = @import("server_session_controls.zig");
const server_session_observer_controls = @import("server_session_observer_controls.zig");
const server_runtime_workers = @import("server_runtime_workers.zig");
const server_session_bindings = @import("server_session_bindings.zig");
const server_workspace_status = @import("server_workspace_status.zig");
const fs_protocol = @import("spiderweb_fs").fs_protocol;
const spiderweb_node = @import("spiderweb_node");
const unified = @import("spider-protocol").unified;
const default_max_agent_runtimes: usize = 64;
const max_agent_id_len: usize = 64;
const max_project_id_len: usize = 128;
const node_venom_event_history_max_default: usize = 1024;
const local_node_export_path_env = "SPIDERWEB_LOCAL_NODE_EXPORT_PATH";
const local_node_export_name_env = "SPIDERWEB_LOCAL_NODE_EXPORT_NAME";
const local_node_export_ro_env = "SPIDERWEB_LOCAL_NODE_EXPORT_RO";
const local_node_fs_url_env = "SPIDERWEB_LOCAL_NODE_FS_URL";
const local_node_name_env = "SPIDERWEB_LOCAL_NODE_NAME";
const local_node_lease_ttl_env = "SPIDERWEB_LOCAL_NODE_LEASE_TTL_MS";
const local_node_heartbeat_ms_env = "SPIDERWEB_LOCAL_NODE_HEARTBEAT_MS";
const local_node_watcher_enabled_env = "SPIDERWEB_LOCAL_NODE_WATCHER_ENABLED";
const local_node_default_name = server_local_node_supervisor.local_node_default_name;
const local_node_ready_timeout_ms: u64 = 10_000;
const local_node_ready_poll_ms: u64 = 100;
const host_actor_id = "spiderweb";
const host_workspace_id = control_plane_mod.host_workspace_id;
const legacy_local_node_mount_agents_self_capabilities = "/global/capabilities";
const legacy_local_node_mount_projects_host_agents_self_capabilities = "/nodes/local/projects/" ++ host_workspace_id ++ "/global/capabilities";
const control_operator_token_env = "SPIDERWEB_CONTROL_OPERATOR_TOKEN";
const control_project_scope_token_env = "SPIDERWEB_CONTROL_PROJECT_SCOPE_TOKEN";
const control_node_scope_token_env = "SPIDERWEB_CONTROL_NODE_SCOPE_TOKEN";
const node_venom_event_history_max_env = "SPIDERWEB_NODE_VENOM_EVENT_HISTORY_MAX";
const metrics_port_env = "SPIDERWEB_METRICS_PORT";
const control_protocol_version = "spiderweb-control";
const acheron_runtime_protocol_version = "acheron-1";
const acheron_node_protocol_version = "spiderweb-fs";
const acheron_node_proto_id: i64 = 2;
const node_tunnel_reply_timeout_ms: i32 = 45_000;
const venom_presence_dispatch_queue_max: usize = 256;
// Each accepted websocket occupies a worker thread for its full lifetime.
// Internal fs-mount/runtime fan-out can exceed 16 steady-state connections,
// which starves new control/gui handshakes and appears as "can't connect".
const min_connection_worker_threads: usize = 64;
const max_mount_graph_materialized_file_bytes: usize = 16 * 1024 * 1024;
const runtime_warmup_stale_timeout_ms: i64 = 30_000;
const runtime_warmup_error_retry_backoff_ms: i64 = 10_000;
const runtime_residency_worker_interval_ms_default: u64 = 1_000;
const session_heartbeat_ttl_ms: i64 = 5 * 60 * 1000;
const agent_heartbeat_ttl_ms: i64 = 5 * 60 * 1000;

fn openFileReadWrite(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openFileAbsolute(path, .{ .mode = .read_write });
    }
    return std.fs.cwd().openFile(path, .{ .mode = .read_write });
}

const parseControlPayloadObject = server_control_payloads.parseControlPayloadObject;
const getRequiredStringField = server_control_payloads.getRequiredStringField;
const getRequiredStringFieldAllowEmpty = server_control_payloads.getRequiredStringFieldAllowEmpty;
const getOptionalStringField = server_control_payloads.getOptionalStringField;
const getOptionalBoolField = server_control_payloads.getOptionalBoolField;
const getOptionalU64Field = server_control_payloads.getOptionalU64Field;
const getOptionalU32Field = server_control_payloads.getOptionalU32Field;
const getOptionalI64Field = server_control_payloads.getOptionalI64Field;
const decodeStandardBase64Owned = server_control_payloads.decodeStandardBase64Owned;
const resetNamespaceSession = server_namespace_sessions.resetNamespaceSession;
const getOrInitNamespaceSessionForBinding = server_namespace_sessions.getOrInitNamespaceSessionForBinding;
const localFsExportRootForNamespace = server_namespace_sessions.localFsExportRootForNamespace;
const initNamespaceSessionForBinding = server_namespace_sessions.initNamespaceSessionForBinding;
const handleMountAttachControl = server_mount_controls.handleMountAttachControl;
const handleMountFileReadControl = server_mount_controls.handleMountFileReadControl;
const handleMountFileWriteControl = server_mount_controls.handleMountFileWriteControl;
const handleMountPathControl = server_mount_controls.handleMountPathControl;
const buildConnectAckPayload = server_session_controls.buildConnectAckPayload;

fn createFileNoTruncate(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.createFileAbsolute(path, .{ .read = true, .truncate = false });
    }
    return std.fs.cwd().createFile(path, .{ .read = true, .truncate = false });
}

fn openOrCreateAppendFile(path: []const u8) !std.fs.File {
    return openFileReadWrite(path) catch |err| switch (err) {
        error.FileNotFound => createFileNoTruncate(path),
        else => err,
    };
}

fn fileSize(path: []const u8) !u64 {
    const file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{ .mode = .read_only })
    else
        try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();
    const stat = try file.stat();
    return stat.size;
}

fn renamePath(old_path: []const u8, new_path: []const u8) !void {
    if (std.fs.path.isAbsolute(old_path) and std.fs.path.isAbsolute(new_path)) {
        try std.fs.renameAbsolute(old_path, new_path);
        return;
    }
    try std.fs.cwd().rename(old_path, new_path);
}

fn parseBoolEnv(allocator: std.mem.Allocator, name: []const u8, default_value: bool) bool {
    const raw = std.process.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return default_value;
    if (std.ascii.eqlIgnoreCase(trimmed, "1") or std.ascii.eqlIgnoreCase(trimmed, "true") or std.ascii.eqlIgnoreCase(trimmed, "yes") or std.ascii.eqlIgnoreCase(trimmed, "on")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "0") or std.ascii.eqlIgnoreCase(trimmed, "false") or std.ascii.eqlIgnoreCase(trimmed, "no") or std.ascii.eqlIgnoreCase(trimmed, "off")) return false;
    return default_value;
}

fn parseUnsignedEnv(allocator: std.mem.Allocator, name: []const u8, default_value: u64) u64 {
    const raw = std.process.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return default_value;
    return std.fmt.parseInt(u64, trimmed, 10) catch default_value;
}

fn pathIsAncestorOrEqual(parent_path_raw: []const u8, child_path_raw: []const u8) bool {
    var parent = std.mem.trim(u8, parent_path_raw, " \t\r\n");
    var child = std.mem.trim(u8, child_path_raw, " \t\r\n");
    if (parent.len == 0 or child.len == 0) return false;

    while (parent.len > 1 and parent[parent.len - 1] == '/') parent = parent[0 .. parent.len - 1];
    while (child.len > 1 and child[child.len - 1] == '/') child = child[0 .. child.len - 1];

    if (std.mem.eql(u8, parent, "/")) return true;
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len == parent.len) return true;
    return child[parent.len] == '/';
}

fn derivePublicFsUrl(allocator: std.mem.Allocator, public_base_url: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, public_base_url, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidArguments;
    if (std.mem.endsWith(u8, trimmed, "/fs")) {
        return allocator.dupe(u8, trimmed);
    }
    const without_trailing = std.mem.trimRight(u8, trimmed, "/");
    return std.fmt.allocPrint(allocator, "{s}/fs", .{without_trailing});
}

fn deriveConnectionWorkspaceUrl(
    allocator: std.mem.Allocator,
    handshake_host: ?[]const u8,
    fallback_workspace_url: ?[]const u8,
) !?[]u8 {
    if (handshake_host) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len > 0) {
            const derived = try std.fmt.allocPrint(allocator, "ws://{s}/", .{trimmed});
            return derived;
        }
    }
    if (fallback_workspace_url) |value| {
        const fallback = try allocator.dupe(u8, value);
        return fallback;
    }
    return null;
}

fn trustedNamespaceMountUrl(
    runtime_workspace_url: ?[]const u8,
    connection_workspace_url: ?[]const u8,
) ?[]const u8 {
    // Helper/probe subprocesses must always use the server's trusted listener URL.
    // The connection authority is only for rewriting payloads we send back to the caller.
    _ = connection_workspace_url;
    return runtime_workspace_url;
}

test "server: rewriteWorkspaceStatusFsUrls rewrites local-only mount endpoints to the connection authority" {
    const allocator = std.testing.allocator;
    const rewritten = try server_workspace_status.rewriteWorkspaceStatusFsUrls(
        allocator,
        "{\"mounts\":[{\"mount_path\":\"/nodes/local/fs\",\"fs_url\":\"ws://127.0.0.1:18790/fs\"}],\"desired_mounts\":[{\"mount_path\":\"/meta\",\"fs_url\":\"ws://127.0.0.1:18790/fs\"}],\"actual_mounts\":[{\"mount_path\":\"/agents\",\"fs_url\":\"ws://127.0.0.1:18790/fs\"}]}",
        "ws://192.168.10.101:18790/",
    );
    defer allocator.free(rewritten);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "\"fs_url\":\"ws://192.168.10.101:18790/fs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "\"desired_mounts\":[{\"mount_path\":\"/meta\",\"fs_url\":\"ws://192.168.10.101:18790/fs\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "\"actual_mounts\":[{\"mount_path\":\"/agents\",\"fs_url\":\"ws://192.168.10.101:18790/fs\"}]") != null);
}

test "server: trustedNamespaceMountUrl ignores connection authority" {
    const trusted = trustedNamespaceMountUrl(
        "ws://127.0.0.1:18790/",
        "wss://attacker.example.com/",
    ) orelse return error.TestExpectedResponse;
    try std.testing.expectEqualStrings("ws://127.0.0.1:18790/", trusted);
}

test "server: namespace local fs export root prefers configured local node export path" {
    var runtime_config: Config.RuntimeConfig = .{};
    runtime_config.spider_web_root = "/fallback/root";
    runtime_config.local_node.export_path = "/configured/export";
    const configured = localFsExportRootForNamespace(runtime_config) orelse return error.TestExpectedResponse;
    try std.testing.expectEqualStrings("/configured/export", configured);

    runtime_config.local_node.export_path = "";
    const fallback = localFsExportRootForNamespace(runtime_config) orelse return error.TestExpectedResponse;
    try std.testing.expectEqualStrings("/fallback/root", fallback);
}

fn warnDeprecatedEmbeddedLocalNodeEnv(allocator: std.mem.Allocator) void {
    const deprecated_vars = [_][]const u8{
        local_node_export_path_env,
        local_node_export_name_env,
        local_node_export_ro_env,
        local_node_fs_url_env,
        local_node_name_env,
        local_node_lease_ttl_env,
        local_node_heartbeat_ms_env,
        local_node_watcher_enabled_env,
    };

    for (deprecated_vars) |env_name| {
        const raw = std.process.getEnvVarOwned(allocator, env_name) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => continue,
            else => {
                std.log.warn("failed reading deprecated {s}: {s}", .{ env_name, @errorName(err) });
                continue;
            },
        };
        defer allocator.free(raw);

        if (std.mem.trim(u8, raw, " \t\r\n").len == 0) continue;
        std.log.warn(
            "{s} is deprecated and ignored; use runtime.local_node in config.json instead",
            .{env_name},
        );
    }
}

fn runRemoteControlOperation(
    allocator: std.mem.Allocator,
    control_url: []const u8,
    operation: []const u8,
    payload_json: []const u8,
) ![]u8 {
    const control_cli_path = try server_local_node_supervisor.resolveSiblingExecutablePath(allocator, "spiderweb-control");
    defer allocator.free(control_cli_path);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            control_cli_path,
            "--url",
            control_url,
            operation,
            payload_json,
        },
        .max_output_bytes = 512 * 1024,
    });
    errdefer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code == 0) return result.stdout;
        },
        else => {},
    }

    const stderr_text = std.mem.trim(u8, result.stderr, " \t\r\n");
    if (stderr_text.len > 0) {
        std.log.warn("remote control operation {s} failed: {s}", .{ operation, stderr_text });
    } else {
        const stdout_text = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (stdout_text.len > 0) {
            std.log.warn("remote control operation {s} failed: {s}", .{ operation, stdout_text });
        } else {
            std.log.warn("remote control operation {s} failed with no output", .{operation});
        }
    }
    allocator.free(result.stdout);
    return error.CommandFailed;
}

fn parseOptionalEnvOwned(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    const raw = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return null,
    };
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}

const NodeTunnelPendingRequest = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    done: bool = false,
    failed: bool = false,
    response_payload: ?[]u8 = null,

    fn deinit(self: *NodeTunnelPendingRequest, allocator: std.mem.Allocator) void {
        if (self.response_payload) |value| allocator.free(value);
        self.* = undefined;
    }
};

const NodeTunnelClient = struct {
    id: u64,
    stream: *std.net.Stream,
    write_mutex: *std.Thread.Mutex,
    allow_invalidations: bool = false,
};

const NodeTunnelEntry = struct {
    stream: ?*std.net.Stream = null,
    write_mutex: ?*std.Thread.Mutex = null,
    generation: u64 = 0,
    next_upstream_tag: u32 = 1,
    next_client_id: u64 = 1,
    pending: std.AutoHashMapUnmanaged(u32, *NodeTunnelPendingRequest) = .{},
    clients: std.ArrayListUnmanaged(NodeTunnelClient) = .{},

    fn deinit(self: *NodeTunnelEntry, allocator: std.mem.Allocator) void {
        var pending_it = self.pending.iterator();
        while (pending_it.next()) |item| {
            var pending = item.value_ptr.*;
            pending.deinit(allocator);
            allocator.destroy(pending);
        }
        self.pending.deinit(allocator);
        self.clients.deinit(allocator);
        self.* = undefined;
    }
};

const NodeTunnelAttachment = struct {
    node_id: []u8,
    generation: u64,

    fn deinit(self: *NodeTunnelAttachment, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
        self.* = undefined;
    }
};

const NodeTunnelRegistry = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    tunnels: std.StringHashMapUnmanaged(*NodeTunnelEntry) = .{},

    fn deinit(self: *NodeTunnelRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.tunnels.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var tunnel = entry.value_ptr.*;
            tunnel.deinit(self.allocator);
            self.allocator.destroy(tunnel);
        }
        self.tunnels.deinit(self.allocator);
    }

    fn attachTunnel(
        self: *NodeTunnelRegistry,
        node_id: []const u8,
        stream: *std.net.Stream,
        write_mutex: *std.Thread.Mutex,
    ) !NodeTunnelAttachment {
        self.mutex.lock();
        defer self.mutex.unlock();

        const tunnel = try self.getOrCreateTunnelLocked(node_id);
        if (tunnel.stream) |previous_stream| {
            if (previous_stream != stream) {
                previous_stream.close();
            }
            self.failAllPendingLocked(tunnel);
        }
        tunnel.stream = stream;
        tunnel.write_mutex = write_mutex;
        tunnel.generation +%= 1;
        if (tunnel.generation == 0) tunnel.generation = 1;
        return .{
            .node_id = try self.allocator.dupe(u8, node_id),
            .generation = tunnel.generation,
        };
    }

    fn detachTunnel(self: *NodeTunnelRegistry, node_id: []const u8, generation: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const tunnel = self.tunnels.get(node_id) orelse return;
        if (tunnel.generation != generation) return;
        tunnel.stream = null;
        tunnel.write_mutex = null;
        self.failAllPendingLocked(tunnel);
        self.removeTunnelIfUnusedLocked(node_id, tunnel);
    }

    fn registerClient(
        self: *NodeTunnelRegistry,
        node_id: []const u8,
        stream: *std.net.Stream,
        write_mutex: *std.Thread.Mutex,
        allow_invalidations: bool,
    ) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const tunnel = self.tunnels.get(node_id) orelse {
            std.log.warn("node tunnel register client failed: node={s} reason=missing_tunnel", .{node_id});
            return error.NodeTunnelUnavailable;
        };
        if (tunnel.stream == null or tunnel.write_mutex == null) {
            std.log.warn("node tunnel register client failed: node={s} reason=inactive_stream generation={d}", .{ node_id, tunnel.generation });
            return error.NodeTunnelUnavailable;
        }

        const client_id = tunnel.next_client_id;
        tunnel.next_client_id +%= 1;
        if (tunnel.next_client_id == 0) tunnel.next_client_id = 1;
        try tunnel.clients.append(self.allocator, .{
            .id = client_id,
            .stream = stream,
            .write_mutex = write_mutex,
            .allow_invalidations = allow_invalidations,
        });
        return client_id;
    }

    fn updateClientInvalidations(
        self: *NodeTunnelRegistry,
        node_id: []const u8,
        client_id: u64,
        allow_invalidations: bool,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const tunnel = self.tunnels.get(node_id) orelse return;
        for (tunnel.clients.items) |*client| {
            if (client.id != client_id) continue;
            client.allow_invalidations = allow_invalidations;
            return;
        }
    }

    fn unregisterClient(self: *NodeTunnelRegistry, node_id: []const u8, client_id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const tunnel = self.tunnels.get(node_id) orelse return;
        for (tunnel.clients.items, 0..) |client, idx| {
            if (client.id != client_id) continue;
            _ = tunnel.clients.swapRemove(idx);
            break;
        }
        self.removeTunnelIfUnusedLocked(node_id, tunnel);
    }

    fn relayRequest(
        self: *NodeTunnelRegistry,
        node_id: []const u8,
        client_tag: u32,
        request_payload: []const u8,
    ) ![]u8 {
        var pending = try self.allocator.create(NodeTunnelPendingRequest);
        pending.* = .{};
        defer {
            pending.deinit(self.allocator);
            self.allocator.destroy(pending);
        }

        var upstream_tag: u32 = 0;
        var stream: ?*std.net.Stream = null;
        var stream_write_mutex: ?*std.Thread.Mutex = null;
        var generation: u64 = 0;

        self.mutex.lock();
        {
            const tunnel = self.tunnels.get(node_id) orelse {
                self.mutex.unlock();
                return error.NodeTunnelUnavailable;
            };
            if (tunnel.stream == null or tunnel.write_mutex == null) {
                self.mutex.unlock();
                return error.NodeTunnelUnavailable;
            }

            upstream_tag = self.nextUpstreamTagLocked(tunnel);
            try tunnel.pending.put(self.allocator, upstream_tag, pending);
            stream = tunnel.stream.?;
            stream_write_mutex = tunnel.write_mutex.?;
            generation = tunnel.generation;
        }
        self.mutex.unlock();

        const rewritten = rewriteAcheronTag(self.allocator, request_payload, upstream_tag) catch |err| {
            self.mutex.lock();
            if (self.tunnels.get(node_id)) |tunnel| {
                if (tunnel.generation == generation) {
                    _ = tunnel.pending.remove(upstream_tag);
                }
            }
            self.mutex.unlock();
            return err;
        };
        defer self.allocator.free(rewritten);

        stream_write_mutex.?.lock();
        const write_result = websocket_transport.writeFrame(stream.?, rewritten, .text);
        stream_write_mutex.?.unlock();
        if (write_result) |_| {} else |err| {
            self.mutex.lock();
            if (self.tunnels.get(node_id)) |tunnel| {
                if (tunnel.generation == generation) {
                    _ = tunnel.pending.remove(upstream_tag);
                    tunnel.stream = null;
                    tunnel.write_mutex = null;
                    self.failAllPendingLocked(tunnel);
                    self.removeTunnelIfUnusedLocked(node_id, tunnel);
                }
            }
            self.mutex.unlock();
            return err;
        }

        const deadline_ns: i128 = std.time.nanoTimestamp() + @as(i128, @intCast(node_tunnel_reply_timeout_ms)) * std.time.ns_per_ms;
        pending.mutex.lock();
        while (!pending.done) {
            const now_ns = std.time.nanoTimestamp();
            if (now_ns >= deadline_ns) {
                pending.failed = true;
                pending.done = true;
                break;
            }
            const remaining_ns: u64 = @intCast(deadline_ns - now_ns);
            pending.cond.timedWait(&pending.mutex, remaining_ns) catch |wait_err| switch (wait_err) {
                error.Timeout => continue,
            };
        }
        const failed = pending.failed;
        const response_payload = pending.response_payload;
        pending.response_payload = null;
        pending.mutex.unlock();

        if (failed or response_payload == null) {
            self.mutex.lock();
            if (self.tunnels.get(node_id)) |tunnel| {
                _ = tunnel.pending.remove(upstream_tag);
            }
            self.mutex.unlock();
            return error.NodeTunnelUnavailable;
        }

        defer self.allocator.free(response_payload.?);
        const response_rewritten = try rewriteAcheronTag(self.allocator, response_payload.?, client_tag);
        return response_rewritten;
    }

    fn dispatchTunnelFrame(
        self: *NodeTunnelRegistry,
        node_id: []const u8,
        generation: u64,
        payload: []const u8,
    ) void {
        var parsed = unified.parseMessage(self.allocator, payload) catch return;
        defer parsed.deinit(self.allocator);
        if (parsed.channel != .acheron) return;
        const frame_type = parsed.acheron_type orelse return;

        if (frame_type == .fs_evt_inval or frame_type == .fs_evt_inval_dir) {
            self.mutex.lock();
            defer self.mutex.unlock();

            const tunnel = self.tunnels.get(node_id) orelse return;
            if (tunnel.generation != generation) return;
            var idx: usize = 0;
            while (idx < tunnel.clients.items.len) {
                const client = tunnel.clients.items[idx];
                if (!client.allow_invalidations) {
                    idx += 1;
                    continue;
                }
                client.write_mutex.lock();
                const write_result = websocket_transport.writeFrame(client.stream, payload, .text);
                client.write_mutex.unlock();
                if (write_result) |_| {} else |_| {
                    _ = tunnel.clients.swapRemove(idx);
                    continue;
                }
                idx += 1;
            }
            return;
        }

        const upstream_tag = parsed.tag orelse return;
        var pending: ?*NodeTunnelPendingRequest = null;
        self.mutex.lock();
        if (self.tunnels.get(node_id)) |tunnel| {
            if (tunnel.generation == generation) {
                if (tunnel.pending.fetchRemove(upstream_tag)) |removed| {
                    pending = removed.value;
                }
            }
        }
        self.mutex.unlock();

        if (pending) |pending_req| {
            const copy = self.allocator.dupe(u8, payload) catch null;
            pending_req.mutex.lock();
            if (copy) |value| {
                pending_req.response_payload = value;
                pending_req.failed = false;
            } else {
                pending_req.failed = true;
            }
            pending_req.done = true;
            pending_req.cond.signal();
            pending_req.mutex.unlock();
        }
    }

    fn getOrCreateTunnelLocked(self: *NodeTunnelRegistry, node_id: []const u8) !*NodeTunnelEntry {
        if (self.tunnels.get(node_id)) |existing| return existing;
        const key = try self.allocator.dupe(u8, node_id);
        errdefer self.allocator.free(key);
        const tunnel = try self.allocator.create(NodeTunnelEntry);
        errdefer self.allocator.destroy(tunnel);
        tunnel.* = .{};
        try self.tunnels.put(self.allocator, key, tunnel);
        return tunnel;
    }

    fn removeTunnelIfUnusedLocked(
        self: *NodeTunnelRegistry,
        node_id: []const u8,
        tunnel: *NodeTunnelEntry,
    ) void {
        if (tunnel.stream != null) return;
        if (tunnel.pending.count() > 0) return;
        if (tunnel.clients.items.len > 0) return;

        if (self.tunnels.fetchRemove(node_id)) |removed| {
            self.allocator.free(removed.key);
            var removed_tunnel = removed.value;
            removed_tunnel.deinit(self.allocator);
            self.allocator.destroy(removed_tunnel);
        }
    }

    fn failAllPendingLocked(self: *NodeTunnelRegistry, tunnel: *NodeTunnelEntry) void {
        _ = self;
        var it = tunnel.pending.iterator();
        while (it.next()) |entry| {
            const pending = entry.value_ptr.*;
            pending.mutex.lock();
            pending.failed = true;
            pending.done = true;
            pending.cond.signal();
            pending.mutex.unlock();
        }
        tunnel.pending.clearRetainingCapacity();
    }

    fn nextUpstreamTagLocked(self: *NodeTunnelRegistry, tunnel: *NodeTunnelEntry) u32 {
        _ = self;
        var attempts: u64 = 0;
        while (attempts < std.math.maxInt(u32)) : (attempts += 1) {
            const candidate = tunnel.next_upstream_tag;
            tunnel.next_upstream_tag +%= 1;
            if (tunnel.next_upstream_tag == 0) tunnel.next_upstream_tag = 1;
            if (candidate == 0) continue;
            if (!tunnel.pending.contains(candidate)) return candidate;
        }
        return 1;
    }
};

const ControlMutationScope = server_control_scope.ControlMutationScope;
const AuditRecord = server_audit_records.AuditRecord;

const NodeRegistration = struct {
    node_id: []u8,
    node_secret: []u8,
};

fn parseNodeRegistrationFromJoinPayload(allocator: std.mem.Allocator, payload_json: []const u8) !NodeRegistration {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    const node_id = parsed.value.object.get("node_id") orelse return error.MissingField;
    if (node_id != .string or node_id.string.len == 0) return error.InvalidPayload;
    const node_secret = parsed.value.object.get("node_secret") orelse return error.MissingField;
    if (node_secret != .string or node_secret.string.len == 0) return error.InvalidPayload;

    return .{
        .node_id = try allocator.dupe(u8, node_id.string),
        .node_secret = try allocator.dupe(u8, node_secret.string),
    };
}

const NodeTunnelHello = struct {
    node_id: []u8,
    node_secret: []u8,

    fn deinit(self: *NodeTunnelHello, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
        allocator.free(self.node_secret);
        self.* = undefined;
    }
};

fn parseNodeTunnelHelloPayload(
    allocator: std.mem.Allocator,
    payload_json: ?[]const u8,
) !NodeTunnelHello {
    _ = try validateFsNodeHelloPayload(allocator, payload_json, null);
    const raw = payload_json orelse return error.MissingField;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidType;
    const node_id_value = parsed.value.object.get("node_id") orelse return error.MissingField;
    if (node_id_value != .string or !isValidNodeIdentifier(node_id_value.string)) return error.InvalidPayload;
    const node_secret_value = parsed.value.object.get("node_secret") orelse return error.MissingField;
    if (node_secret_value != .string or node_secret_value.string.len == 0) return error.InvalidPayload;

    return .{
        .node_id = try allocator.dupe(u8, node_id_value.string),
        .node_secret = try allocator.dupe(u8, node_secret_value.string),
    };
}

fn parseFsHelloAuthToken(allocator: std.mem.Allocator, payload_json: ?[]const u8) !?[]u8 {
    return server_protocol_validation.parseFsHelloAuthToken(allocator, payload_json);
}

fn controlNodeErrorToErrno(err: anyerror) i32 {
    return switch (err) {
        control_plane_mod.ControlPlaneError.NodeNotFound => fs_protocol.Errno.ENOENT,
        control_plane_mod.ControlPlaneError.NodeAuthFailed => fs_protocol.Errno.EACCES,
        else => fs_protocol.Errno.EIO,
    };
}

fn handleNodeTunnelConnection(
    allocator: std.mem.Allocator,
    runtime_registry: *AgentRuntimeRegistry,
    stream: *std.net.Stream,
) !void {
    var attachment: ?NodeTunnelAttachment = null;
    defer if (attachment) |*attached| {
        runtime_registry.node_tunnels.detachTunnel(attached.node_id, attached.generation);
        attached.deinit(allocator);
    };
    var connection_write_mutex: std.Thread.Mutex = .{};

    while (true) {
        var frame = websocket_transport.readFrame(
            allocator,
            stream,
            websocket_transport.default_max_ws_frame_payload_bytes,
        ) catch |err| switch (err) {
            error.EndOfStream, websocket_transport.Error.ConnectionClosed => return,
            else => return err,
        };
        defer frame.deinit(allocator);

        switch (frame.opcode) {
            0x1 => {
                var parsed = unified.parseMessage(allocator, frame.payload) catch |err| {
                    const response = try unified.buildFsrpcFsError(
                        allocator,
                        null,
                        fs_protocol.Errno.EINVAL,
                        @errorName(err),
                    );
                    defer allocator.free(response);
                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                    try writeFrameLocked(stream, &connection_write_mutex, "", .close);
                    return;
                };
                defer parsed.deinit(allocator);

                if (attachment == null) {
                    if (parsed.channel != .acheron or parsed.acheron_type != .fs_t_hello) {
                        const response = try unified.buildFsrpcFsError(
                            allocator,
                            parsed.tag,
                            fs_protocol.Errno.EINVAL,
                            "acheron.t_fs_hello must be negotiated first",
                        );
                        defer allocator.free(response);
                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                        try writeFrameLocked(stream, &connection_write_mutex, "", .close);
                        return;
                    }

                    var hello = parseNodeTunnelHelloPayload(allocator, parsed.payload_json) catch |err| {
                        const response = try unified.buildFsrpcFsError(
                            allocator,
                            parsed.tag,
                            fs_protocol.Errno.EINVAL,
                            @errorName(err),
                        );
                        defer allocator.free(response);
                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                        try writeFrameLocked(stream, &connection_write_mutex, "", .close);
                        return;
                    };
                    defer hello.deinit(allocator);

                    runtime_registry.control_plane.authenticateNodeSession(hello.node_id, hello.node_secret) catch |auth_err| {
                        const response = try unified.buildFsrpcFsError(
                            allocator,
                            parsed.tag,
                            controlNodeErrorToErrno(auth_err),
                            @errorName(auth_err),
                        );
                        defer allocator.free(response);
                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                        try writeFrameLocked(stream, &connection_write_mutex, "", .close);
                        return;
                    };

                    attachment = try runtime_registry.node_tunnels.attachTunnel(
                        hello.node_id,
                        stream,
                        &connection_write_mutex,
                    );

                    const ack_payload = try std.fmt.allocPrint(
                        allocator,
                        "{{\"protocol\":\"{s}\",\"proto\":{d},\"node_id\":\"{s}\"}}",
                        .{ acheron_node_protocol_version, acheron_node_proto_id, attachment.?.node_id },
                    );
                    defer allocator.free(ack_payload);
                    const response = try unified.buildFsrpcResponse(
                        allocator,
                        .fs_r_hello,
                        parsed.tag,
                        ack_payload,
                    );
                    defer allocator.free(response);
                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                    continue;
                }

                if (parsed.channel != .acheron) continue;
                if (parsed.acheron_type == .fs_t_hello) {
                    var hello = parseNodeTunnelHelloPayload(allocator, parsed.payload_json) catch |err| {
                        const response = try unified.buildFsrpcFsError(
                            allocator,
                            parsed.tag,
                            fs_protocol.Errno.EINVAL,
                            @errorName(err),
                        );
                        defer allocator.free(response);
                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                        try writeFrameLocked(stream, &connection_write_mutex, "", .close);
                        return;
                    };
                    defer hello.deinit(allocator);
                    if (!std.mem.eql(u8, hello.node_id, attachment.?.node_id)) {
                        const response = try unified.buildFsrpcFsError(
                            allocator,
                            parsed.tag,
                            fs_protocol.Errno.EACCES,
                            "node_id mismatch for active tunnel",
                        );
                        defer allocator.free(response);
                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                        try writeFrameLocked(stream, &connection_write_mutex, "", .close);
                        return;
                    }
                    runtime_registry.control_plane.authenticateNodeSession(hello.node_id, hello.node_secret) catch |auth_err| {
                        const response = try unified.buildFsrpcFsError(
                            allocator,
                            parsed.tag,
                            controlNodeErrorToErrno(auth_err),
                            @errorName(auth_err),
                        );
                        defer allocator.free(response);
                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                        try writeFrameLocked(stream, &connection_write_mutex, "", .close);
                        return;
                    };
                    const ack_payload = "{\"protocol\":\"spiderweb-fs\",\"proto\":2}";
                    const response = try unified.buildFsrpcResponse(
                        allocator,
                        .fs_r_hello,
                        parsed.tag,
                        ack_payload,
                    );
                    defer allocator.free(response);
                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                    continue;
                }

                runtime_registry.node_tunnels.dispatchTunnelFrame(
                    attachment.?.node_id,
                    attachment.?.generation,
                    frame.payload,
                );
            },
            0x8 => {
                try writeFrameLocked(stream, &connection_write_mutex, "", .close);
                return;
            },
            0x9 => {
                try writeFrameLocked(stream, &connection_write_mutex, frame.payload, .pong);
            },
            0xA => {},
            else => {
                const response = try unified.buildFsrpcFsError(
                    allocator,
                    null,
                    fs_protocol.Errno.EINVAL,
                    "unsupported websocket opcode",
                );
                defer allocator.free(response);
                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
            },
        }
    }
}

fn handleRoutedNodeFsConnection(
    allocator: std.mem.Allocator,
    runtime_registry: *AgentRuntimeRegistry,
    node_id: []const u8,
    stream: *std.net.Stream,
) !void {
    var connection_write_mutex: std.Thread.Mutex = .{};
    var acheron_negotiated = false;
    var connection_client_id: ?u64 = null;
    defer if (connection_client_id) |client_id| {
        runtime_registry.node_tunnels.unregisterClient(node_id, client_id);
    };

    while (true) {
        var frame = websocket_transport.readFrame(
            allocator,
            stream,
            websocket_transport.default_max_ws_frame_payload_bytes,
        ) catch |err| switch (err) {
            error.EndOfStream, websocket_transport.Error.ConnectionClosed => return,
            else => return err,
        };
        defer frame.deinit(allocator);

        switch (frame.opcode) {
            0x1 => {
                var parsed = unified.parseMessage(allocator, frame.payload) catch |err| {
                    const response = try unified.buildFsrpcFsError(
                        allocator,
                        null,
                        fs_protocol.Errno.EINVAL,
                        @errorName(err),
                    );
                    defer allocator.free(response);
                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                    try writeFrameLocked(stream, &connection_write_mutex, "", .close);
                    return;
                };
                defer parsed.deinit(allocator);

                if (parsed.channel != .acheron) {
                    const response = try unified.buildFsrpcFsError(
                        allocator,
                        parsed.tag,
                        fs_protocol.Errno.EINVAL,
                        "wrong websocket endpoint: use / for control protocol",
                    );
                    defer allocator.free(response);
                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                    try writeFrameLocked(stream, &connection_write_mutex, "", .close);
                    return;
                }

                const acheron_type = parsed.acheron_type orelse {
                    const response = try unified.buildFsrpcFsError(
                        allocator,
                        parsed.tag,
                        fs_protocol.Errno.EINVAL,
                        "missing fsrpc message type",
                    );
                    defer allocator.free(response);
                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                    continue;
                };
                const client_tag = parsed.tag orelse {
                    const response = try unified.buildFsrpcFsError(
                        allocator,
                        null,
                        fs_protocol.Errno.EINVAL,
                        "missing request tag",
                    );
                    defer allocator.free(response);
                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                    continue;
                };

                if (!acheron_negotiated) {
                    if (acheron_type != .fs_t_hello) {
                        const response = try unified.buildFsrpcFsError(
                            allocator,
                            parsed.tag,
                            fs_protocol.Errno.EINVAL,
                            "acheron.t_fs_hello must be negotiated first",
                        );
                        defer allocator.free(response);
                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                        try writeFrameLocked(stream, &connection_write_mutex, "", .close);
                        return;
                    }
                    const hello_opts = validateFsNodeHelloPayload(allocator, parsed.payload_json, null) catch |err| {
                        const response = try unified.buildFsrpcFsError(
                            allocator,
                            parsed.tag,
                            fs_protocol.Errno.EINVAL,
                            @errorName(err),
                        );
                        defer allocator.free(response);
                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                        try writeFrameLocked(stream, &connection_write_mutex, "", .close);
                        return;
                    };
                    const auth_token = parseFsHelloAuthToken(allocator, parsed.payload_json) catch |err| {
                        const response = try unified.buildFsrpcFsError(
                            allocator,
                            parsed.tag,
                            fs_protocol.Errno.EINVAL,
                            @errorName(err),
                        );
                        defer allocator.free(response);
                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                        try writeFrameLocked(stream, &connection_write_mutex, "", .close);
                        return;
                    };
                    defer if (auth_token) |token| allocator.free(token);
                    if (auth_token == null) {
                        const response = try unified.buildFsrpcFsError(
                            allocator,
                            parsed.tag,
                            fs_protocol.Errno.EACCES,
                            "missing auth_token in fs hello payload",
                        );
                        defer allocator.free(response);
                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                        try writeFrameLocked(stream, &connection_write_mutex, "", .close);
                        return;
                    }
                    runtime_registry.control_plane.authenticateNodeSession(node_id, auth_token.?) catch |auth_err| {
                        const response = try unified.buildFsrpcFsError(
                            allocator,
                            parsed.tag,
                            controlNodeErrorToErrno(auth_err),
                            @errorName(auth_err),
                        );
                        defer allocator.free(response);
                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                        try writeFrameLocked(stream, &connection_write_mutex, "", .close);
                        return;
                    };

                    connection_client_id = runtime_registry.node_tunnels.registerClient(
                        node_id,
                        stream,
                        &connection_write_mutex,
                        hello_opts.allow_invalidations,
                    ) catch {
                        const response = try unified.buildFsrpcFsError(
                            allocator,
                            parsed.tag,
                            fs_protocol.Errno.EIO,
                            "node tunnel is unavailable",
                        );
                        defer allocator.free(response);
                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                        try writeFrameLocked(stream, &connection_write_mutex, "", .close);
                        return;
                    };
                    acheron_negotiated = true;
                } else if (acheron_type == .fs_t_hello) {
                    const hello_opts = validateFsNodeHelloPayload(allocator, parsed.payload_json, null) catch |err| {
                        const response = try unified.buildFsrpcFsError(
                            allocator,
                            parsed.tag,
                            fs_protocol.Errno.EINVAL,
                            @errorName(err),
                        );
                        defer allocator.free(response);
                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                        try writeFrameLocked(stream, &connection_write_mutex, "", .close);
                        return;
                    };
                    if (connection_client_id) |client_id| {
                        runtime_registry.node_tunnels.updateClientInvalidations(
                            node_id,
                            client_id,
                            hello_opts.allow_invalidations,
                        );
                    }
                }

                const relayed_response = runtime_registry.node_tunnels.relayRequest(
                    node_id,
                    client_tag,
                    frame.payload,
                ) catch |relay_err| {
                    const response = try unified.buildFsrpcFsError(
                        allocator,
                        parsed.tag,
                        fs_protocol.Errno.EIO,
                        @errorName(relay_err),
                    );
                    defer allocator.free(response);
                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                    continue;
                };
                defer allocator.free(relayed_response);
                try writeFrameLocked(stream, &connection_write_mutex, relayed_response, .text);
            },
            0x8 => {
                try writeFrameLocked(stream, &connection_write_mutex, "", .close);
                return;
            },
            0x9 => {
                try writeFrameLocked(stream, &connection_write_mutex, frame.payload, .pong);
            },
            0xA => {},
            else => {
                const response = try unified.buildFsrpcFsError(
                    allocator,
                    null,
                    fs_protocol.Errno.EINVAL,
                    "unsupported websocket opcode",
                );
                defer allocator.free(response);
                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
            },
        }
    }
}

fn stripWsPathQuery(path: []const u8) []const u8 {
    const query_idx = std.mem.indexOfScalar(u8, path, '?') orelse return path;
    return path[0..query_idx];
}

fn isNodeTunnelPath(path: []const u8) bool {
    const normalized = stripWsPathQuery(path);
    return std.mem.eql(u8, normalized, "/v2/node") or std.mem.eql(u8, normalized, "/v2/node/");
}

fn parseNodeFsRoute(path: []const u8) ?[]const u8 {
    const normalized = stripWsPathQuery(path);
    const prefix = "/fs/node/";
    if (!std.mem.startsWith(u8, normalized, prefix)) return null;
    const node_id = normalized[prefix.len..];
    if (!isValidNodeIdentifier(node_id)) return null;
    return node_id;
}

fn isValidNodeIdentifier(node_id: []const u8) bool {
    if (node_id.len == 0 or node_id.len > 128) return false;
    for (node_id) |char| {
        if (std.ascii.isAlphanumeric(char)) continue;
        if (char == '_' or char == '-' or char == '.') continue;
        return false;
    }
    return true;
}

fn rewriteAcheronTag(
    allocator: std.mem.Allocator,
    raw_json: []const u8,
    next_tag: u32,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    const channel_val = parsed.value.object.get("channel") orelse return error.MissingField;
    if (channel_val != .string or !std.mem.eql(u8, channel_val.string, "acheron")) return error.InvalidPayload;
    try parsed.value.object.put("tag", .{ .integer = @as(i64, next_tag) });
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(parsed.value, .{})});
}

const auth_tokens_filename = "auth_tokens.json";

const ConnectionRole = enum {
    access,
};

fn connectionRoleName(role: ConnectionRole) []const u8 {
    return switch (role) {
        .access => "access",
    };
}

const ConnectionPrincipal = struct {
    role: ConnectionRole,
    token_id: []const u8,
};

const SessionAttachState = enum {
    warming,
    ready,
    err,
};

const SessionAttachStateSnapshot = struct {
    state: SessionAttachState = .warming,
    runtime_ready: bool = false,
    mount_ready: bool = false,
    error_code: ?[]u8 = null,
    error_message: ?[]u8 = null,
    updated_at_ms: i64 = 0,

    fn deinit(self: *SessionAttachStateSnapshot, allocator: std.mem.Allocator) void {
        if (self.error_code) |value| allocator.free(value);
        if (self.error_message) |value| allocator.free(value);
        self.* = undefined;
    }
};

const RuntimeWarmupState = struct {
    state: SessionAttachState = .warming,
    runtime_ready: bool = false,
    mount_ready: bool = false,
    error_code: ?[]u8 = null,
    error_message: ?[]u8 = null,
    updated_at_ms: i64 = 0,
    retry_after_ms: i64 = 0,
    in_flight: bool = false,

    fn deinit(self: *RuntimeWarmupState, allocator: std.mem.Allocator) void {
        if (self.error_code) |value| allocator.free(value);
        if (self.error_message) |value| allocator.free(value);
        self.* = undefined;
    }

    fn setWarming(self: *RuntimeWarmupState, allocator: std.mem.Allocator) void {
        if (self.error_code) |value| allocator.free(value);
        if (self.error_message) |value| allocator.free(value);
        self.error_code = null;
        self.error_message = null;
        self.state = .warming;
        self.runtime_ready = false;
        self.mount_ready = false;
        self.updated_at_ms = std.time.milliTimestamp();
        self.retry_after_ms = 0;
    }

    fn setReady(self: *RuntimeWarmupState, allocator: std.mem.Allocator) void {
        if (self.error_code) |value| allocator.free(value);
        if (self.error_message) |value| allocator.free(value);
        self.error_code = null;
        self.error_message = null;
        self.state = .ready;
        self.runtime_ready = true;
        self.mount_ready = true;
        self.updated_at_ms = std.time.milliTimestamp();
        self.retry_after_ms = 0;
    }

    fn setError(self: *RuntimeWarmupState, allocator: std.mem.Allocator, code: []const u8, message: []const u8) !void {
        if (self.error_code) |value| allocator.free(value);
        if (self.error_message) |value| allocator.free(value);
        self.error_code = try allocator.dupe(u8, code);
        errdefer {
            allocator.free(self.error_code.?);
            self.error_code = null;
        }
        self.error_message = try allocator.dupe(u8, message);
        self.state = .err;
        self.runtime_ready = false;
        self.mount_ready = false;
        self.updated_at_ms = std.time.milliTimestamp();
        self.retry_after_ms = self.updated_at_ms + runtime_warmup_error_retry_backoff_ms;
    }

    fn snapshotOwned(self: *const RuntimeWarmupState, allocator: std.mem.Allocator) !SessionAttachStateSnapshot {
        var snapshot = SessionAttachStateSnapshot{
            .state = self.state,
            .runtime_ready = self.runtime_ready,
            .mount_ready = self.mount_ready,
            .updated_at_ms = self.updated_at_ms,
        };
        if (self.error_code) |value| {
            snapshot.error_code = try allocator.dupe(u8, value);
        }
        errdefer if (snapshot.error_code) |value| allocator.free(value);
        if (self.error_message) |value| {
            snapshot.error_message = try allocator.dupe(u8, value);
        }
        return snapshot;
    }
};

const VenomPresenceDispatchJob = struct {
    agent_id: []u8,
    project_id: ?[]u8 = null,
    session_key: []u8,
    venom_id: []u8,
    attached: bool,
    payload_json: []u8,

    fn deinit(self: *VenomPresenceDispatchJob, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_id);
        if (self.project_id) |value| allocator.free(value);
        allocator.free(self.session_key);
        allocator.free(self.venom_id);
        allocator.free(self.payload_json);
        self.* = undefined;
    }

    fn matches(
        self: *const VenomPresenceDispatchJob,
        agent_id: []const u8,
        project_id: ?[]const u8,
        session_key: []const u8,
        venom_id: []const u8,
        attached: bool,
    ) bool {
        return std.mem.eql(u8, self.agent_id, agent_id) and
            optionalStringsEqual(self.project_id, project_id) and
            std.mem.eql(u8, self.session_key, session_key) and
            std.mem.eql(u8, self.venom_id, venom_id) and
            self.attached == attached;
    }
};

const RememberedTarget = struct {
    agent_id: []u8,
    project_id: []u8,

    fn deinit(self: *RememberedTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_id);
        allocator.free(self.project_id);
        self.* = undefined;
    }
};

const SessionHistoryEntry = struct {
    session_key: []u8,
    agent_id: []u8,
    project_id: []u8,
    last_active_ms: i64,
    message_count: u64 = 0,
    summary: ?[]u8 = null,

    fn deinit(self: *SessionHistoryEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.session_key);
        allocator.free(self.agent_id);
        allocator.free(self.project_id);
        if (self.summary) |value| allocator.free(value);
        self.* = undefined;
    }

    fn cloneOwned(self: *const SessionHistoryEntry, allocator: std.mem.Allocator) !SessionHistoryEntry {
        return .{
            .session_key = try allocator.dupe(u8, self.session_key),
            .agent_id = try allocator.dupe(u8, self.agent_id),
            .project_id = try allocator.dupe(u8, self.project_id),
            .last_active_ms = self.last_active_ms,
            .message_count = self.message_count,
            .summary = if (self.summary) |value| try allocator.dupe(u8, value) else null,
        };
    }
};

const AuthTokenStore = struct {
    const PersistedTarget = struct {
        agent_id: ?[]const u8 = null,
        project_id: ?[]const u8 = null,
    };

    const PersistedSessionHistoryEntry = struct {
        session_key: []const u8,
        agent_id: []const u8,
        project_id: []const u8,
        last_active_ms: i64 = 0,
        message_count: u64 = 0,
        summary: ?[]const u8 = null,
    };

    const Persisted = struct {
        schema: u32 = 4,
        access_token: []const u8,
        access_last_target: ?PersistedTarget = null,
        access_session_history: ?[]PersistedSessionHistoryEntry = null,
        updated_at_ms: i64,
    };

    allocator: std.mem.Allocator,
    path: ?[]u8 = null,
    access_token: []u8,
    access_last_target: ?RememberedTarget = null,
    access_session_history: std.ArrayListUnmanaged(SessionHistoryEntry) = .{},
    mutex: std.Thread.Mutex = .{},

    fn init(allocator: std.mem.Allocator, runtime_config: Config.RuntimeConfig) AuthTokenStore {
        var store = AuthTokenStore{
            .allocator = allocator,
            .access_token = allocator.dupe(u8, "") catch @panic("oom"),
        };
        store.loadOrGenerate(runtime_config);
        return store;
    }

    fn deinit(self: *AuthTokenStore) void {
        if (self.path) |value| self.allocator.free(value);
        self.allocator.free(self.access_token);
        if (self.access_last_target) |*target| target.deinit(self.allocator);
        for (self.access_session_history.items) |*entry| entry.deinit(self.allocator);
        self.access_session_history.deinit(self.allocator);
        self.* = undefined;
    }

    fn authenticate(self: *const AuthTokenStore, authorization_header: ?[]const u8) ?ConnectionPrincipal {
        const raw = authorization_header orelse return null;
        const token = parseBearerToken(raw) orelse return null;
        const mutex = @constCast(&self.mutex);
        mutex.lock();
        defer mutex.unlock();
        if (server_control_scope.secureTokenEql(self.access_token, token)) return .{ .role = .access, .token_id = "access" };
        return null;
    }

    fn rotateRoleToken(self: *AuthTokenStore, role: ConnectionRole) ![]u8 {
        _ = role;
        const next = try makeOpaqueToken(self.allocator, "sw-access");
        errdefer self.allocator.free(next);
        const replacement = try self.allocator.dupe(u8, next);
        errdefer self.allocator.free(replacement);

        self.mutex.lock();
        defer self.mutex.unlock();
        const previous = self.access_token;
        self.access_token = replacement;
        self.persistCurrentStateLocked() catch |err| {
            self.access_token = previous;
            self.allocator.free(replacement);
            return err;
        };
        self.allocator.free(previous);
        return next;
    }

    fn rememberedTargetOwned(self: *const AuthTokenStore, role: ConnectionRole) !?RememberedTarget {
        _ = role;
        const mutex = @constCast(&self.mutex);
        mutex.lock();
        defer mutex.unlock();
        const stored = self.access_last_target orelse return null;
        return .{
            .agent_id = try self.allocator.dupe(u8, stored.agent_id),
            .project_id = try self.allocator.dupe(u8, stored.project_id),
        };
    }

    fn setRememberedTarget(self: *AuthTokenStore, role: ConnectionRole, agent_id: []const u8, project_id: []const u8) !void {
        _ = role;
        const next_agent = try self.allocator.dupe(u8, agent_id);
        errdefer self.allocator.free(next_agent);
        const next_project = try self.allocator.dupe(u8, project_id);
        errdefer self.allocator.free(next_project);
        var next_target = RememberedTarget{
            .agent_id = next_agent,
            .project_id = next_project,
        };

        self.mutex.lock();
        defer self.mutex.unlock();

        const slot = &self.access_last_target;
        var previous = slot.*;
        slot.* = next_target;
        self.persistCurrentStateLocked() catch |err| {
            slot.* = previous;
            next_target.deinit(self.allocator);
            return err;
        };
        if (previous) |*value| value.deinit(self.allocator);
    }

    fn clearRememberedTarget(self: *AuthTokenStore, role: ConnectionRole) !void {
        _ = role;
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot = &self.access_last_target;
        var previous = slot.*;
        slot.* = null;
        self.persistCurrentStateLocked() catch |err| {
            slot.* = previous;
            return err;
        };
        if (previous) |*value| value.deinit(self.allocator);
    }

    fn recordSessionActivity(
        self: *AuthTokenStore,
        role: ConnectionRole,
        session_key: []const u8,
        agent_id: []const u8,
        project_id: []const u8,
        message_delta: u64,
    ) !void {
        const max_history_entries: usize = 10;
        _ = role;
        self.mutex.lock();
        defer self.mutex.unlock();

        const history = &self.access_session_history;

        const now_ms = std.time.milliTimestamp();
        _ = self.pruneExpiredSessionHistoryLocked(history, now_ms);
        for (history.items) |*entry| {
            if (std.mem.eql(u8, entry.session_key, session_key) and
                std.mem.eql(u8, entry.agent_id, agent_id) and
                std.mem.eql(u8, entry.project_id, project_id))
            {
                entry.last_active_ms = now_ms;
                entry.message_count += message_delta;
                self.sortSessionHistoryNewestFirst(history);
                self.persistCurrentStateLocked() catch |err| {
                    std.log.warn("failed to persist session history update: {s}", .{@errorName(err)});
                };
                return;
            }
        }

        try history.append(self.allocator, .{
            .session_key = try self.allocator.dupe(u8, session_key),
            .agent_id = try self.allocator.dupe(u8, agent_id),
            .project_id = try self.allocator.dupe(u8, project_id),
            .last_active_ms = now_ms,
            .message_count = message_delta,
            .summary = try std.fmt.allocPrint(
                self.allocator,
                "{s} @ {s}",
                .{ agent_id, project_id },
            ),
        });
        self.sortSessionHistoryNewestFirst(history);
        while (history.items.len > max_history_entries) {
            var removed = history.pop().?;
            removed.deinit(self.allocator);
        }
        self.persistCurrentStateLocked() catch |err| {
            std.log.warn("failed to persist session history append: {s}", .{@errorName(err)});
        };
    }

    pub fn sessionHistoryOwned(
        self: *AuthTokenStore,
        role: ConnectionRole,
        agent_id_filter: ?[]const u8,
        limit: usize,
    ) !std.ArrayListUnmanaged(SessionHistoryEntry) {
        _ = role;
        var out = std.ArrayListUnmanaged(SessionHistoryEntry){};
        errdefer {
            for (out.items) |*entry| entry.deinit(self.allocator);
            out.deinit(self.allocator);
        }

        const effective_limit = if (limit == 0) @as(usize, 10) else limit;
        const mutex = &self.mutex;
        mutex.lock();
        defer mutex.unlock();
        const history = &self.access_session_history;
        const now_ms = std.time.milliTimestamp();
        const pruned = self.pruneExpiredSessionHistoryLocked(history, now_ms);
        if (pruned) {
            self.persistCurrentStateLocked() catch |err| {
                std.log.warn("failed to persist pruned session history: {s}", .{@errorName(err)});
            };
        }
        for (history.items) |*entry| {
            if (agent_id_filter) |filter| {
                if (!std.mem.eql(u8, entry.agent_id, filter)) continue;
            }
            try out.append(self.allocator, try entry.cloneOwned(self.allocator));
            if (out.items.len >= effective_limit) break;
        }
        return out;
    }

    pub fn latestSessionOwned(
        self: *AuthTokenStore,
        role: ConnectionRole,
        agent_id_filter: ?[]const u8,
    ) !?SessionHistoryEntry {
        var history = try self.sessionHistoryOwned(role, agent_id_filter, 1);
        errdefer {
            for (history.items) |*entry| entry.deinit(self.allocator);
            history.deinit(self.allocator);
        }
        if (history.items.len == 0) {
            history.deinit(self.allocator);
            return null;
        }
        const entry = history.orderedRemove(0);
        history.deinit(self.allocator);
        return entry;
    }

    pub fn sessionLastActiveMs(self: *const AuthTokenStore, role: ConnectionRole, session_key: []const u8) ?i64 {
        _ = role;
        const mutex = @constCast(&self.mutex);
        mutex.lock();
        defer mutex.unlock();
        const history = &self.access_session_history;
        var latest: ?i64 = null;
        for (history.items) |*entry| {
            if (!std.mem.eql(u8, entry.session_key, session_key)) continue;
            if (latest == null or entry.last_active_ms > latest.?) latest = entry.last_active_ms;
        }
        return latest;
    }

    fn sortSessionHistoryNewestFirst(self: *AuthTokenStore, history: *std.ArrayListUnmanaged(SessionHistoryEntry)) void {
        _ = self;
        var i: usize = 1;
        while (i < history.items.len) : (i += 1) {
            var j = i;
            while (j > 0 and history.items[j - 1].last_active_ms < history.items[j].last_active_ms) : (j -= 1) {
                const tmp = history.items[j - 1];
                history.items[j - 1] = history.items[j];
                history.items[j] = tmp;
            }
        }
    }

    fn pruneExpiredSessionHistoryLocked(
        self: *AuthTokenStore,
        history: *std.ArrayListUnmanaged(SessionHistoryEntry),
        now_ms: i64,
    ) bool {
        const max_age_ms: i64 = 24 * 60 * 60 * 1000;
        var removed_any = false;
        var idx: usize = 0;
        while (idx < history.items.len) {
            const age_ms = now_ms - history.items[idx].last_active_ms;
            if (age_ms > max_age_ms) {
                var removed = history.orderedRemove(idx);
                removed.deinit(self.allocator);
                removed_any = true;
                continue;
            }
            idx += 1;
        }
        return removed_any;
    }

    fn statusJson(self: *const AuthTokenStore) ![]u8 {
        const mutex = @constCast(&self.mutex);
        mutex.lock();
        defer mutex.unlock();
        const escaped_access = try unified.jsonEscape(self.allocator, self.access_token);
        defer self.allocator.free(escaped_access);
        const path_json = if (self.path) |value| blk: {
            const escaped_path = try unified.jsonEscape(self.allocator, value);
            defer self.allocator.free(escaped_path);
            break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped_path});
        } else try self.allocator.dupe(u8, "null");
        defer self.allocator.free(path_json);
        const access_target_json = if (self.access_last_target) |target| blk: {
            const escaped_agent = try unified.jsonEscape(self.allocator, target.agent_id);
            defer self.allocator.free(escaped_agent);
            const escaped_project = try unified.jsonEscape(self.allocator, target.project_id);
            defer self.allocator.free(escaped_project);
            break :blk try std.fmt.allocPrint(
                self.allocator,
                "{{\"agent_id\":\"{s}\",\"project_id\":\"{s}\"}}",
                .{ escaped_agent, escaped_project },
            );
        } else try self.allocator.dupe(u8, "null");
        defer self.allocator.free(access_target_json);
        return std.fmt.allocPrint(
            self.allocator,
            "{{\"access_token\":\"{s}\",\"path\":{s},\"access_last_target\":{s}}}",
            .{
                escaped_access,
                path_json,
                access_target_json,
            },
        );
    }

    fn loadOrGenerate(self: *AuthTokenStore, runtime_config: Config.RuntimeConfig) void {
        const base_dir = std.mem.trim(u8, runtime_config.state_directory, " \t\r\n");
        const storage_dir = if (base_dir.len == 0) "." else base_dir;
        server_local_node_supervisor.ensureDirectoryExists(storage_dir) catch {};
        self.path = std.fs.path.join(self.allocator, &.{ storage_dir, auth_tokens_filename }) catch null;

        if (self.path) |path| {
            const loaded = self.loadFromPath(path) catch false;
            if (loaded) return;
        }

        const generated_access = makeOpaqueToken(self.allocator, "sw-access") catch return;
        defer self.allocator.free(generated_access);
        const next_access = self.allocator.dupe(u8, generated_access) catch return;
        errdefer self.allocator.free(next_access);

        self.mutex.lock();
        defer self.mutex.unlock();
        const previous_access = self.access_token;
        self.access_token = next_access;
        self.allocator.free(previous_access);
        self.persistCurrentStateLocked() catch |err| {
            std.log.warn("failed to persist generated auth tokens: {s}", .{@errorName(err)});
        };

        std.log.warn("Generated Spiderweb access token (save this now):", .{});
        std.log.warn("  access: {s}", .{self.access_token});
    }

    fn loadFromPath(self: *AuthTokenStore, path: []const u8) !bool {
        const raw = std.fs.cwd().readFileAlloc(self.allocator, path, 64 * 1024) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer self.allocator.free(raw);

        const parsed = try std.json.parseFromSlice(Persisted, self.allocator, raw, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        if (parsed.value.access_token.len == 0) return false;
        const next_access = try self.allocator.dupe(u8, parsed.value.access_token);
        errdefer self.allocator.free(next_access);
        var next_access_target = try copyPersistedTarget(self.allocator, parsed.value.access_last_target);
        errdefer if (next_access_target) |*target| target.deinit(self.allocator);
        var next_access_history = try copyPersistedSessionHistory(
            self.allocator,
            parsed.value.access_session_history,
        );
        errdefer deinitSessionHistoryList(self.allocator, &next_access_history);

        self.mutex.lock();
        defer self.mutex.unlock();
        const previous_access = self.access_token;
        var previous_access_target = self.access_last_target;
        var previous_access_history = self.access_session_history;
        self.access_token = next_access;
        self.access_last_target = next_access_target;
        self.access_session_history = next_access_history;
        self.allocator.free(previous_access);
        if (previous_access_target) |*target| target.deinit(self.allocator);
        deinitSessionHistoryList(self.allocator, &previous_access_history);
        return true;
    }

    fn persistCurrentStateLocked(self: *AuthTokenStore) !void {
        const path = self.path orelse return error.AuthTokenPathUnavailable;
        const access_history = try persistedSessionHistorySlice(
            self.allocator,
            self.access_session_history.items,
        );
        defer if (access_history) |value| self.allocator.free(value);

        const payload = Persisted{
            .schema = 4,
            .access_token = self.access_token,
            .access_last_target = if (self.access_last_target) |value| .{
                .agent_id = value.agent_id,
                .project_id = value.project_id,
            } else null,
            .access_session_history = access_history,
            .updated_at_ms = std.time.milliTimestamp(),
        };
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, payload, .{
            .emit_null_optional_fields = false,
            .whitespace = .indent_2,
        });
        defer self.allocator.free(bytes);

        const file = try std.fs.cwd().createFile(path, .{
            .truncate = true,
            .mode = 0o600,
        });
        defer file.close();
        if (builtin.os.tag != .windows) {
            try file.chmod(0o600);
        }
        try file.writeAll(bytes);
    }

    fn copyPersistedTarget(allocator: std.mem.Allocator, persisted: ?PersistedTarget) !?RememberedTarget {
        const value = persisted orelse return null;
        const agent_id = value.agent_id orelse return null;
        const project_id = value.project_id orelse return null;
        return .{
            .agent_id = try allocator.dupe(u8, agent_id),
            .project_id = try allocator.dupe(u8, project_id),
        };
    }

    fn copyPersistedSessionHistory(
        allocator: std.mem.Allocator,
        persisted: ?[]PersistedSessionHistoryEntry,
    ) !std.ArrayListUnmanaged(SessionHistoryEntry) {
        var out = std.ArrayListUnmanaged(SessionHistoryEntry){};
        errdefer deinitSessionHistoryList(allocator, &out);

        const items = persisted orelse return out;
        for (items) |entry| {
            try out.append(allocator, .{
                .session_key = try allocator.dupe(u8, entry.session_key),
                .agent_id = try allocator.dupe(u8, entry.agent_id),
                .project_id = try allocator.dupe(u8, entry.project_id),
                .last_active_ms = entry.last_active_ms,
                .message_count = entry.message_count,
                .summary = if (entry.summary) |value| try allocator.dupe(u8, value) else null,
            });
        }
        return out;
    }

    fn deinitSessionHistoryList(
        allocator: std.mem.Allocator,
        list: *std.ArrayListUnmanaged(SessionHistoryEntry),
    ) void {
        for (list.items) |*entry| entry.deinit(allocator);
        list.deinit(allocator);
        list.* = .{};
    }

    fn persistedSessionHistorySlice(
        allocator: std.mem.Allocator,
        entries: []const SessionHistoryEntry,
    ) !?[]PersistedSessionHistoryEntry {
        if (entries.len == 0) return null;
        var out = try allocator.alloc(PersistedSessionHistoryEntry, entries.len);
        for (entries, 0..) |entry, idx| {
            out[idx] = .{
                .session_key = entry.session_key,
                .agent_id = entry.agent_id,
                .project_id = entry.project_id,
                .last_active_ms = entry.last_active_ms,
                .message_count = entry.message_count,
                .summary = entry.summary,
            };
        }
        return out;
    }

    fn parseBearerToken(header_value: []const u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, header_value, " \t");
        if (trimmed.len == 0) return null;
        if (std.mem.startsWith(u8, trimmed, "Bearer ")) {
            const token = std.mem.trim(u8, trimmed["Bearer ".len..], " \t");
            if (token.len == 0) return null;
            return token;
        }
        if (std.mem.startsWith(u8, trimmed, "bearer ")) {
            const token = std.mem.trim(u8, trimmed["bearer ".len..], " \t");
            if (token.len == 0) return null;
            return token;
        }
        return trimmed;
    }

    fn makeOpaqueToken(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
        var random_bytes: [24]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        var encoded_buf: [std.base64.url_safe_no_pad.Encoder.calcSize(random_bytes.len)]u8 = undefined;
        const encoded = std.base64.url_safe_no_pad.Encoder.encode(&encoded_buf, &random_bytes);
        return std.fmt.allocPrint(allocator, "{s}_{s}", .{ prefix, encoded });
    }

    pub fn copyAccessToken(self: *AuthTokenStore) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.allocator.dupe(u8, self.access_token);
    }
};

const AgentRuntimeEntry = struct {
    runtime: *runtime_handle_mod.RuntimeHandle,
    project_id: []u8,
    runtime_agent_id: []u8,

    fn deinit(self: *AgentRuntimeEntry, allocator: std.mem.Allocator) void {
        self.runtime.destroy();
        allocator.free(self.project_id);
        allocator.free(self.runtime_agent_id);
        self.* = undefined;
    }
};

fn pathExistsAsDirectory(path: []const u8) !bool {
    if (std.fs.path.isAbsolute(path)) {
        var dir = std.fs.openDirAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer dir.close();
        return true;
    }
    var dir = std.fs.cwd().openDir(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer dir.close();
    return true;
}

fn normalizeControlPath(path: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, path, " \t\r\n");
    const no_leading = std.mem.trimLeft(u8, trimmed, "/");
    return std.mem.trimRight(u8, no_leading, "/");
}

fn pathMatchesControlTarget(path: []const u8, target: []const u8) bool {
    const normalized = normalizeControlPath(path);
    return std.mem.eql(u8, normalized, target);
}

const AgentRuntimeRegistry = struct {
    allocator: std.mem.Allocator,
    runtime_config: Config.RuntimeConfig,
    default_agent_id: []const u8,
    max_runtimes: usize,
    control_plane: control_plane_mod.ControlPlane,
    auth_tokens: AuthTokenStore,
    control_operator_token: ?[]u8 = null,
    control_project_scope_token: ?[]u8 = null,
    control_node_scope_token: ?[]u8 = null,
    local_node_supervisor: ?*server_local_node_supervisor.LocalNodeSupervisor = null,
    node_tunnels: NodeTunnelRegistry,
    workspace_url: ?[]u8 = null,
    mutex: std.Thread.Mutex = .{},
    by_agent: std.StringHashMapUnmanaged(AgentRuntimeEntry) = .{},
    creating_runtime_keys: std.StringHashMapUnmanaged(void) = .{},
    runtime_create_cond: std.Thread.Condition = .{},
    runtime_warmups_mutex: std.Thread.Mutex = .{},
    runtime_warmups: std.StringHashMapUnmanaged(RuntimeWarmupState) = .{},
    runtime_warmup_lifecycle_mutex: std.Thread.Mutex = .{},
    runtime_warmup_lifecycle_cond: std.Thread.Condition = .{},
    runtime_warmup_inflight: usize = 0,
    runtime_warmup_stopping: bool = false,
    venom_presence_worker_thread: ?std.Thread = null,
    venom_presence_worker_stop: bool = false,
    venom_presence_worker_mutex: std.Thread.Mutex = .{},
    venom_presence_worker_cond: std.Thread.Condition = .{},
    venom_presence_jobs: std.ArrayListUnmanaged(VenomPresenceDispatchJob) = .{},
    audit_records_mutex: std.Thread.Mutex = .{},
    audit_records: std.ArrayListUnmanaged(AuditRecord) = .{},
    next_audit_record_id: u64 = 1,
    reconcile_worker_thread: ?std.Thread = null,
    reconcile_worker_stop: bool = false,
    reconcile_worker_mutex: std.Thread.Mutex = .{},
    reconcile_worker_interval_ms: u64 = 250,
    runtime_residency_worker_thread: ?std.Thread = null,
    runtime_residency_worker_stop: bool = false,
    runtime_residency_worker_mutex: std.Thread.Mutex = .{},
    runtime_residency_worker_interval_ms: u64 = runtime_residency_worker_interval_ms_default,

    fn init(
        allocator: std.mem.Allocator,
        runtime_config: Config.RuntimeConfig,
    ) AgentRuntimeRegistry {
        return initWithLimits(allocator, runtime_config, default_max_agent_runtimes);
    }

    fn initWithLimits(
        allocator: std.mem.Allocator,
        runtime_config: Config.RuntimeConfig,
        max_runtimes: usize,
    ) AgentRuntimeRegistry {
        const configured_default = std.mem.trim(u8, runtime_config.default_agent_id, " \t\r\n");
        var effective_default = allocator.dupe(u8, host_actor_id) catch @panic("OOM");
        if (configured_default.len > 0 and !isValidAgentId(configured_default)) {
            std.log.warn(
                "Invalid default_agent_id '{s}', falling back to '{s}'",
                .{ configured_default, host_actor_id },
            );
        } else if (configured_default.len > 0) {
            allocator.free(effective_default);
            effective_default = allocator.dupe(u8, configured_default) catch @panic("OOM");
        }
        const operator_token = parseOptionalEnvOwned(allocator, control_operator_token_env);
        const project_scope_token = parseOptionalEnvOwned(allocator, control_project_scope_token_env);
        const node_scope_token = parseOptionalEnvOwned(allocator, control_node_scope_token_env);
        if (operator_token != null) {
            std.log.info("control-plane operator token enabled via {s}", .{control_operator_token_env});
        }
        if (project_scope_token != null) {
            std.log.info("control-plane project-scope token enabled via {s}", .{control_project_scope_token_env});
        }
        if (node_scope_token != null) {
            std.log.info("control-plane node-scope token enabled via {s}", .{control_node_scope_token_env});
        }
        const history_max_raw = parseUnsignedEnv(
            allocator,
            node_venom_event_history_max_env,
            @as(u64, node_venom_event_history_max_default),
        );
        const history_max: usize = @intCast(@max(@as(u64, 64), @min(history_max_raw, 20_000)));

        const registry: AgentRuntimeRegistry = .{
            .allocator = allocator,
            .runtime_config = runtime_config,
            .default_agent_id = effective_default,
            .max_runtimes = if (max_runtimes == 0) 1 else max_runtimes,
            .control_plane = control_plane_mod.ControlPlane.initWithPersistenceOptions(
                allocator,
                runtime_config.state_directory,
                runtime_config.state_db_filename,
                .{
                    .host_actor_id = host_actor_id,
                    .spider_web_root = runtime_config.spider_web_root,
                    .node_venom_event_history_max = history_max,
                },
            ),
            .auth_tokens = AuthTokenStore.init(allocator, runtime_config),
            .control_operator_token = operator_token,
            .control_project_scope_token = project_scope_token,
            .control_node_scope_token = node_scope_token,
            .node_tunnels = .{ .allocator = allocator },
        };
        return registry;
    }

    fn deinit(self: *AgentRuntimeRegistry) void {
        self.requestVenomPresenceWorkerStop();
        if (self.venom_presence_worker_thread) |thread| {
            thread.join();
            self.venom_presence_worker_thread = null;
        }
        self.venom_presence_worker_mutex.lock();
        for (self.venom_presence_jobs.items) |*job| job.deinit(self.allocator);
        self.venom_presence_jobs.deinit(self.allocator);
        self.venom_presence_jobs = .{};
        self.venom_presence_worker_mutex.unlock();

        self.requestRuntimeResidencyWorkerStop();
        if (self.runtime_residency_worker_thread) |thread| {
            thread.join();
            self.runtime_residency_worker_thread = null;
        }

        self.requestReconcileWorkerStop();
        if (self.reconcile_worker_thread) |thread| {
            thread.join();
            self.reconcile_worker_thread = null;
        }

        self.runtime_warmup_lifecycle_mutex.lock();
        self.runtime_warmup_stopping = true;
        while (self.runtime_warmup_inflight > 0) {
            self.runtime_warmup_lifecycle_cond.wait(&self.runtime_warmup_lifecycle_mutex);
        }
        self.runtime_warmup_lifecycle_mutex.unlock();

        self.mutex.lock();
        const local_node_supervisor_for_shutdown = self.local_node_supervisor;
        self.mutex.unlock();
        if (local_node_supervisor_for_shutdown) |supervisor| {
            supervisor.requestStop();
            supervisor.join();
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.by_agent.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var runtime_entry = entry.value_ptr.*;
            runtime_entry.deinit(self.allocator);
        }
        self.by_agent.deinit(self.allocator);
        var creating_it = self.creating_runtime_keys.iterator();
        while (creating_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.creating_runtime_keys.deinit(self.allocator);
        self.creating_runtime_keys = .{};
        self.runtime_warmups_mutex.lock();
        var warmup_it = self.runtime_warmups.iterator();
        while (warmup_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var warmup = entry.value_ptr.*;
            warmup.deinit(self.allocator);
        }
        self.runtime_warmups.deinit(self.allocator);
        self.runtime_warmups = .{};
        self.runtime_warmups_mutex.unlock();
        if (self.local_node_supervisor) |supervisor| {
            supervisor.deinit();
            self.local_node_supervisor = null;
        }
        if (self.control_operator_token) |token| {
            self.allocator.free(token);
            self.control_operator_token = null;
        }
        if (self.control_project_scope_token) |token| {
            self.allocator.free(token);
            self.control_project_scope_token = null;
        }
        if (self.control_node_scope_token) |token| {
            self.allocator.free(token);
            self.control_node_scope_token = null;
        }
        if (self.workspace_url) |value| {
            self.allocator.free(value);
            self.workspace_url = null;
        }
        self.node_tunnels.deinit();
        self.audit_records_mutex.lock();
        for (self.audit_records.items) |*record| record.deinit(self.allocator);
        self.audit_records.deinit(self.allocator);
        self.audit_records = .{};
        self.next_audit_record_id = 1;
        self.audit_records_mutex.unlock();
        self.control_plane.deinit();
        self.auth_tokens.deinit();
        self.allocator.free(self.default_agent_id);
    }

    fn authenticateConnection(self: *AgentRuntimeRegistry, authorization_header: ?[]const u8) ?ConnectionPrincipal {
        return self.auth_tokens.authenticate(authorization_header);
    }

    pub fn authStatusJson(self: *AgentRuntimeRegistry) ![]u8 {
        return self.auth_tokens.statusJson();
    }

    fn startLocalNodeSupervisor(self: *AgentRuntimeRegistry, bind_addr: []const u8, port: u16) !void {
        if (!self.runtime_config.local_node.enabled) return;

        self.mutex.lock();
        const existing = self.local_node_supervisor;
        self.mutex.unlock();
        if (existing != null) return;

        const control_auth_token = try self.auth_tokens.copyAccessToken();
        defer self.allocator.free(control_auth_token);

        const supervisor = try server_local_node_supervisor.LocalNodeSupervisor.create(
            self.allocator,
            &self.control_plane,
            self.runtime_config,
            bind_addr,
            port,
            control_auth_token,
        );
        errdefer supervisor.deinit();
        try supervisor.start();

        self.pruneLegacyHostCapabilityMounts();

        var installed = false;
        self.mutex.lock();
        if (self.local_node_supervisor == null) {
            self.local_node_supervisor = supervisor;
            installed = true;
        }
        self.mutex.unlock();
        if (!installed) {
            supervisor.requestStop();
            supervisor.join();
            supervisor.deinit();
            return;
        }

        self.waitForPreferredLocalNodeServices(local_node_ready_timeout_ms) catch |err| {
            std.log.warn("local node started but core services are not ready yet: {s}", .{@errorName(err)});
        };
    }

    fn waitForPreferredLocalNodeServices(self: *AgentRuntimeRegistry, timeout_ms: u64) !void {
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (true) {
            if (try self.hasPreferredLocalNodeServices()) return;
            if (std.time.milliTimestamp() >= deadline) return error.TimedOut;
            std.Thread.sleep(local_node_ready_poll_ms * std.time.ns_per_ms);
        }
    }

    fn hasPreferredLocalNodeServices(self: *AgentRuntimeRegistry) !bool {
        for ([_][]const u8{ "fs", "terminal", "git", "search_code" }) |venom_id| {
            var provider = (try self.control_plane.resolvePreferredVenomProvider(
                self.allocator,
                venom_id,
                &.{ local_node_default_name, "local" },
            )) orelse return false;
            defer provider.deinit(self.allocator);
        }
        return true;
    }

    pub fn rotateAuthToken(self: *AgentRuntimeRegistry, role: ConnectionRole) ![]u8 {
        return self.auth_tokens.rotateRoleToken(role);
    }

    const InitialSessionBinding = struct {
        binding: SessionBinding,
    };

    fn dispatchRuntimeAgentControlForTarget(
        self: *AgentRuntimeRegistry,
        agent_id: []const u8,
        project_id: ?[]const u8,
        action: []const u8,
        content_json: []const u8,
    ) !void {
        const runtime = self.getRuntimeForBindingIfReady(agent_id, project_id) orelse
            return error.RuntimeUnavailable;
        defer runtime.release();

        const escaped_content = try unified.jsonEscape(self.allocator, content_json);
        defer self.allocator.free(escaped_content);
        const request_id = try std.fmt.allocPrint(self.allocator, "runtime-control-{d}", .{std.time.nanoTimestamp()});
        defer self.allocator.free(request_id);
        const request_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":\"{s}\",\"type\":\"agent.control\",\"action\":\"{s}\",\"content\":\"{s}\"}}",
            .{ request_id, action, escaped_content },
        );
        defer self.allocator.free(request_json);

        const responses = try runtime.handleMessageFramesWithDebug(request_json, false);
        defer {
            for (responses) |frame| self.allocator.free(frame);
            self.allocator.free(responses);
        }
        if (responses.len == 0) return error.MissingJobResponse;
        if (std.mem.indexOf(u8, responses[0], "\"type\":\"error\"") != null) {
            std.log.warn(
                "runtime agent.control rejected: action={s} agent={s} project={s} response={s}",
                .{
                    action,
                    agent_id,
                    project_id orelse "null",
                    responses[0],
                },
            );
            return error.RuntimeControlRejected;
        }
    }

    fn dispatchRuntimeAgentControl(
        self: *AgentRuntimeRegistry,
        binding: SessionBinding,
        action: []const u8,
        content_json: []const u8,
    ) !void {
        return self.dispatchRuntimeAgentControlForTarget(binding.agent_id, binding.project_id, action, content_json);
    }

    fn enqueueVenomPresenceDispatch(
        self: *AgentRuntimeRegistry,
        binding: SessionBinding,
        session_key: []const u8,
        venom_id: []const u8,
        attached: bool,
        payload_json: []u8,
    ) !void {
        errdefer self.allocator.free(payload_json);

        const owned_agent_id = try self.allocator.dupe(u8, binding.agent_id);
        errdefer self.allocator.free(owned_agent_id);
        const owned_project_id = if (binding.project_id) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_project_id) |value| self.allocator.free(value);
        const owned_session_key = try self.allocator.dupe(u8, session_key);
        errdefer self.allocator.free(owned_session_key);
        const owned_venom_id = try self.allocator.dupe(u8, venom_id);
        errdefer self.allocator.free(owned_venom_id);

        self.venom_presence_worker_mutex.lock();
        defer self.venom_presence_worker_mutex.unlock();

        if (self.venom_presence_worker_stop) return error.ShuttingDown;

        for (self.venom_presence_jobs.items) |*job| {
            if (job.matches(binding.agent_id, binding.project_id, session_key, venom_id, attached)) {
                self.allocator.free(owned_venom_id);
                self.allocator.free(owned_session_key);
                if (owned_project_id) |value| self.allocator.free(value);
                self.allocator.free(owned_agent_id);
                self.allocator.free(payload_json);
                return;
            }
        }

        if (self.venom_presence_jobs.items.len >= venom_presence_dispatch_queue_max) return error.QueueFull;

        try self.venom_presence_jobs.append(self.allocator, .{
            .agent_id = owned_agent_id,
            .project_id = owned_project_id,
            .session_key = owned_session_key,
            .venom_id = owned_venom_id,
            .attached = attached,
            .payload_json = payload_json,
        });
        self.venom_presence_worker_cond.signal();
    }

    pub fn getRuntimeForBindingIfReady(
        self: *AgentRuntimeRegistry,
        agent_id: []const u8,
        project_id: ?[]const u8,
    ) ?*runtime_handle_mod.RuntimeHandle {
        var selected_runtime: ?*runtime_handle_mod.RuntimeHandle = null;
        const runtime_key = runtimeMapKeyForProject(project_id);
        self.mutex.lock();
        if (self.by_agent.getPtr(runtime_key)) |existing| {
            if (std.mem.eql(u8, existing.runtime_agent_id, agent_id)) {
                if (existing.runtime.isHealthy()) {
                    selected_runtime = existing.runtime;
                    selected_runtime.?.retain();
                }
            }
        }
        self.mutex.unlock();
        if (selected_runtime == null) {
            _ = self.dropUnhealthyRuntimeForBinding(
                agent_id,
                project_id,
                "runtime_unhealthy",
                "project runtime became unhealthy",
            );
        }
        return selected_runtime;
    }

    fn dropUnhealthyRuntimeForBinding(
        self: *AgentRuntimeRegistry,
        agent_id: []const u8,
        project_id: ?[]const u8,
        error_code: []const u8,
        error_message: []const u8,
    ) bool {
        var removed_unhealthy: ?RemovedRuntimeEntry = null;
        const runtime_key = runtimeMapKeyForProject(project_id);
        const binding_key = self.runtimeBindingKey(agent_id, project_id) catch null;
        defer if (binding_key) |value| self.allocator.free(value);

        self.mutex.lock();
        if (self.by_agent.getPtr(runtime_key)) |existing| {
            if (std.mem.eql(u8, existing.runtime_agent_id, agent_id) and !existing.runtime.isHealthy()) {
                removed_unhealthy = self.takeUnhealthyRuntimeLocked(runtime_key);
            }
        }
        self.mutex.unlock();

        if (removed_unhealthy) |removed| {
            const health_summary = removed.entry.runtime.healthSummary(self.allocator) catch null;
            defer if (health_summary) |value| self.allocator.free(value);
            std.log.warn(
                "dropping unhealthy ready runtime binding: project={s} agent={s} detail={s}",
                .{
                    project_id orelse "__auto__",
                    removed.entry.runtime_agent_id,
                    health_summary orelse "unavailable",
                },
            );
            if (binding_key) |key| {
                self.markRuntimeWarmupError(key, error_code, error_message);
            }
            self.deinitRemovedRuntime(removed);
            return true;
        }

        return false;
    }

    pub fn publishVenomPresenceForBinding(
        self: *AgentRuntimeRegistry,
        role: ConnectionRole,
        binding: SessionBinding,
        session_key: []const u8,
        venom_id: []const u8,
        attached: bool,
    ) void {
        _ = self;
        _ = role;
        _ = binding;
        _ = session_key;
        _ = venom_id;
        _ = attached;
        // Venom presence sync used to target the embedded runtime. Spiderweb is
        // now a workspace host only, so attached workers discover presence
        // through the mounted namespace rather than runtime-directed control
        // messages.
    }

    fn projectExistsWithRole(self: *AgentRuntimeRegistry, project_id: []const u8, is_admin: bool) bool {
        const escaped_project = unified.jsonEscape(self.allocator, project_id) catch return false;
        defer self.allocator.free(escaped_project);
        const payload = std.fmt.allocPrint(self.allocator, "{{\"project_id\":\"{s}\"}}", .{escaped_project}) catch return false;
        defer self.allocator.free(payload);
        const result = self.control_plane.getProjectWithRole(payload, is_admin) catch return false;
        self.allocator.free(result);
        return true;
    }

    fn firstAgentForProject(self: *AgentRuntimeRegistry, role: ConnectionRole, project_id: []const u8) ?[]u8 {
        const include_primary = role == .access and std.mem.eql(u8, project_id, host_workspace_id);
        return self.control_plane.firstProjectAgent(project_id, include_primary) catch null;
    }

    fn resolvePreferredBindingForRole(self: *AgentRuntimeRegistry, role: ConnectionRole) !?SessionBinding {
        const is_admin = role == .access;
        if (try self.auth_tokens.rememberedTargetOwned(role)) |remembered| {
            defer {
                var owned = remembered;
                owned.deinit(self.allocator);
            }

            if (self.projectExistsWithRole(remembered.project_id, is_admin)) {
                var chosen_agent: ?[]u8 = null;
                if (self.control_plane.agentActiveInProject(remembered.agent_id, remembered.project_id)) {
                    chosen_agent = try self.allocator.dupe(u8, remembered.agent_id);
                } else if (self.firstAgentForProject(role, remembered.project_id)) |fallback| {
                    chosen_agent = fallback;
                } else {
                    chosen_agent = try self.allocator.dupe(u8, remembered.agent_id);
                }

                if (chosen_agent) |agent_id| {
                    return .{
                        .agent_id = agent_id,
                        .actor_type = try self.allocator.dupe(u8, server_session_bindings.defaultActorTypeForRole(role)),
                        .actor_id = try self.allocator.dupe(u8, connectionRoleName(role)),
                        .project_id = try self.allocator.dupe(u8, remembered.project_id),
                        .project_token = null,
                    };
                }
            } else {
                self.auth_tokens.clearRememberedTarget(role) catch {};
            }
        }

        return null;
    }

    fn buildInitialSessionBinding(self: *AgentRuntimeRegistry, role: ConnectionRole) !InitialSessionBinding {
        if (try self.resolvePreferredBindingForRole(role)) |binding| {
            return .{
                .binding = binding,
            };
        }

        return .{
            .binding = .{
                .agent_id = try self.allocator.dupe(u8, self.default_agent_id),
                .actor_type = try self.allocator.dupe(u8, server_session_bindings.defaultActorTypeForRole(role)),
                .actor_id = try self.allocator.dupe(u8, connectionRoleName(role)),
                .project_id = null,
                .project_token = null,
            },
        };
    }

    pub fn rememberPrincipalSession(
        self: *AgentRuntimeRegistry,
        principal: ConnectionPrincipal,
        session_key: []const u8,
        agent_id: []const u8,
        project_id: ?[]const u8,
    ) void {
        const concrete_project = project_id orelse return;
        if (std.mem.eql(u8, concrete_project, host_workspace_id)) return;
        self.auth_tokens.recordSessionActivity(
            principal.role,
            session_key,
            agent_id,
            concrete_project,
            0,
        ) catch |err| {
            std.log.warn("failed to persist session history for {s}: {s}", .{ connectionRoleName(principal.role), @errorName(err) });
        };
        self.auth_tokens.setRememberedTarget(principal.role, agent_id, concrete_project) catch |err| {
            std.log.warn("failed to persist remembered target for {s}: {s}", .{ connectionRoleName(principal.role), @errorName(err) });
        };
    }

    fn startReconcileWorker(self: *AgentRuntimeRegistry) !void {
        self.reconcile_worker_mutex.lock();
        self.reconcile_worker_stop = false;
        self.reconcile_worker_mutex.unlock();
        self.reconcile_worker_thread = try std.Thread.spawn(
            .{},
            server_runtime_workers.reconcileWorkerMain,
            .{self},
        );
    }

    fn startVenomPresenceWorker(self: *AgentRuntimeRegistry) !void {
        self.venom_presence_worker_mutex.lock();
        self.venom_presence_worker_stop = false;
        self.venom_presence_worker_mutex.unlock();
        self.venom_presence_worker_thread = try std.Thread.spawn(
            .{},
            server_runtime_workers.servicePresenceWorkerMain,
            .{self},
        );
    }

    fn startRuntimeResidencyWorker(self: *AgentRuntimeRegistry) !void {
        _ = self;
    }

    fn requestReconcileWorkerStop(self: *AgentRuntimeRegistry) void {
        self.reconcile_worker_mutex.lock();
        self.reconcile_worker_stop = true;
        self.reconcile_worker_mutex.unlock();
    }

    fn requestVenomPresenceWorkerStop(self: *AgentRuntimeRegistry) void {
        self.venom_presence_worker_mutex.lock();
        self.venom_presence_worker_stop = true;
        self.venom_presence_worker_cond.broadcast();
        self.venom_presence_worker_mutex.unlock();
    }

    fn shouldStopReconcileWorker(self: *AgentRuntimeRegistry) bool {
        self.reconcile_worker_mutex.lock();
        defer self.reconcile_worker_mutex.unlock();
        return self.reconcile_worker_stop;
    }

    pub fn runReconcileWorkerLoop(self: *AgentRuntimeRegistry) void {
        while (true) {
            if (self.shouldStopReconcileWorker()) return;

            const maybe_payload = self.control_plane.runReconcileCycle(false) catch |err| {
                std.log.warn("control-plane reconcile worker error: {s}", .{@errorName(err)});
                if (self.shouldStopReconcileWorker()) return;
                std.Thread.sleep(self.reconcile_worker_interval_ms * std.time.ns_per_ms);
                continue;
            };
            if (maybe_payload) |payload| {
                defer self.allocator.free(payload);
            }

            std.Thread.sleep(self.reconcile_worker_interval_ms * std.time.ns_per_ms);
        }
    }

    fn requestRuntimeResidencyWorkerStop(self: *AgentRuntimeRegistry) void {
        self.runtime_residency_worker_mutex.lock();
        self.runtime_residency_worker_stop = true;
        self.runtime_residency_worker_mutex.unlock();
    }

    fn shouldStopRuntimeResidencyWorker(self: *AgentRuntimeRegistry) bool {
        self.runtime_residency_worker_mutex.lock();
        defer self.runtime_residency_worker_mutex.unlock();
        return self.runtime_residency_worker_stop;
    }

    fn ensureActiveRuntimeResidency(self: *AgentRuntimeRegistry, retry_on_error: bool) !void {
        const bindings = try self.control_plane.snapshotActiveProjectBindings(self.allocator, true);
        defer {
            for (bindings) |*binding| binding.deinit(self.allocator);
            self.allocator.free(bindings);
        }

        // Keep the hidden host runtime resident independently of active
        // workspace assignment so internal control-plane provisioning paths
        // remain available even when user-facing routes prefer mounted workspaces.
        if (self.control_plane.hostHasMounts()) {
            var host_attach_state = self.ensureRuntimeWarmup(
                host_actor_id,
                host_workspace_id,
                null,
                retry_on_error,
            ) catch |err| blk: {
                std.log.warn(
                    "host runtime residency warmup failed: agent={s} project={s} err={s}",
                    .{ host_actor_id, host_workspace_id, @errorName(err) },
                );
                break :blk null;
            };
            if (host_attach_state) |*attach_state| attach_state.deinit(self.allocator);
        }

        for (bindings) |binding| {
            if (!self.control_plane.projectHasMounts(binding.project_id)) continue;
            if (std.mem.eql(u8, binding.agent_id, host_actor_id) and
                !std.mem.eql(u8, binding.project_id, host_workspace_id))
            {
                continue;
            }
            if (self.hasHealthyRuntimeForProject(binding.project_id) and
                !self.hasRuntimeForBinding(binding.agent_id, binding.project_id))
            {
                continue;
            }
            var attach_state = self.ensureRuntimeWarmup(
                binding.agent_id,
                binding.project_id,
                null,
                retry_on_error,
            ) catch |err| {
                std.log.warn(
                    "active runtime residency warmup failed: agent={s} project={s} err={s}",
                    .{ binding.agent_id, binding.project_id, @errorName(err) },
                );
                continue;
            };
            attach_state.deinit(self.allocator);
        }
    }

    const RemovedRuntimeEntry = struct {
        key: []const u8,
        entry: AgentRuntimeEntry,
    };

    fn runtimeMapKeyForProject(project_id: ?[]const u8) []const u8 {
        return project_id orelse "__auto__";
    }

    fn takeUnhealthyRuntimeLocked(self: *AgentRuntimeRegistry, runtime_key: []const u8) ?RemovedRuntimeEntry {
        const existing = self.by_agent.getPtr(runtime_key) orelse return null;
        if (existing.runtime.isHealthy()) return null;
        const removed = self.by_agent.fetchRemove(runtime_key) orelse return null;
        return .{
            .key = removed.key,
            .entry = removed.value,
        };
    }

    fn takeRuntimeLocked(self: *AgentRuntimeRegistry, runtime_key: []const u8) ?RemovedRuntimeEntry {
        const removed = self.by_agent.fetchRemove(runtime_key) orelse return null;
        return .{
            .key = removed.key,
            .entry = removed.value,
        };
    }

    fn deinitRemovedRuntime(self: *AgentRuntimeRegistry, removed: RemovedRuntimeEntry) void {
        self.allocator.free(removed.key);
        var entry = removed.entry;
        entry.deinit(self.allocator);
    }

    pub fn getOrCreate(
        self: *AgentRuntimeRegistry,
        agent_id: []const u8,
        requested_project_id: ?[]const u8,
        requested_project_token: ?[]const u8,
    ) !*runtime_handle_mod.RuntimeHandle {
        if (!isValidAgentId(agent_id)) return error.InvalidAgentId;
        const resolved_project_id = try self.resolveProjectId(agent_id, requested_project_id);
        defer self.allocator.free(resolved_project_id);
        const runtime_key = runtimeMapKeyForProject(resolved_project_id);

        var creation_claimed = false;
        while (!creation_claimed) {
            var removed_unhealthy: ?RemovedRuntimeEntry = null;
            var removed_mismatched: ?RemovedRuntimeEntry = null;
            var selected_runtime: ?*runtime_handle_mod.RuntimeHandle = null;
            var should_wait = false;

            self.mutex.lock();
            removed_unhealthy = self.takeUnhealthyRuntimeLocked(runtime_key);
            if (removed_unhealthy == null) {
                if (self.by_agent.getPtr(runtime_key)) |existing| {
                    if (std.mem.eql(u8, existing.runtime_agent_id, agent_id)) {
                        selected_runtime = existing.runtime;
                        selected_runtime.?.retain();
                    } else {
                        removed_mismatched = self.takeRuntimeLocked(runtime_key);
                    }
                }
            }
            if (selected_runtime == null) {
                if (self.creating_runtime_keys.contains(runtime_key)) {
                    should_wait = true;
                } else if (self.by_agent.count() >= self.max_runtimes) {
                    self.mutex.unlock();
                    if (removed_unhealthy) |removed| {
                        std.log.warn(
                            "replacing unhealthy project runtime: project={s} agent={s}",
                            .{ resolved_project_id, removed.entry.runtime_agent_id },
                        );
                        self.deinitRemovedRuntime(removed);
                    }
                    if (removed_mismatched) |removed| {
                        std.log.info(
                            "switching project runtime persona: project={s} from={s} to={s}",
                            .{ resolved_project_id, removed.entry.runtime_agent_id, agent_id },
                        );
                        self.deinitRemovedRuntime(removed);
                    }
                    return error.RuntimeLimitReached;
                } else {
                    const owned_runtime_key = try self.allocator.dupe(u8, runtime_key);
                    errdefer self.allocator.free(owned_runtime_key);
                    try self.creating_runtime_keys.put(self.allocator, owned_runtime_key, {});
                    creation_claimed = true;
                }
            }
            self.mutex.unlock();

            if (removed_unhealthy) |removed| {
                std.log.warn(
                    "replacing unhealthy project runtime: project={s} agent={s}",
                    .{ resolved_project_id, removed.entry.runtime_agent_id },
                );
                self.deinitRemovedRuntime(removed);
            }

            if (removed_mismatched) |removed| {
                std.log.info(
                    "switching project runtime persona: project={s} from={s} to={s}",
                    .{ resolved_project_id, removed.entry.runtime_agent_id, agent_id },
                );
                self.deinitRemovedRuntime(removed);
            }

            if (selected_runtime) |runtime| return runtime;
            if (!should_wait) break;

            self.mutex.lock();
            while (self.creating_runtime_keys.contains(runtime_key)) {
                self.runtime_create_cond.wait(&self.mutex);
            }
            self.mutex.unlock();
        }

        defer {
            self.mutex.lock();
            if (self.creating_runtime_keys.fetchRemove(runtime_key)) |removed| {
                self.allocator.free(removed.key);
            }
            self.runtime_create_cond.broadcast();
            self.mutex.unlock();
        }

        const entry = try self.createRuntimeEntry(
            agent_id,
            resolved_project_id,
            requested_project_token,
        );
        var entry_installed = false;
        errdefer if (!entry_installed) {
            var cleanup = entry;
            cleanup.deinit(self.allocator);
        };

        self.mutex.lock();
        var cleanup_after_unlock: ?AgentRuntimeEntry = null;
        var removed_conflict: ?RemovedRuntimeEntry = null;
        defer {
            self.mutex.unlock();
            if (cleanup_after_unlock) |*cleanup| {
                cleanup.deinit(self.allocator);
            }
            if (removed_conflict) |removed| {
                self.deinitRemovedRuntime(removed);
            }
        }

        if (self.by_agent.getPtr(runtime_key)) |existing| {
            if (std.mem.eql(u8, existing.runtime_agent_id, agent_id)) {
                const runtime = existing.runtime;
                cleanup_after_unlock = entry;
                entry_installed = true;
                runtime.retain();
                return runtime;
            }
            removed_conflict = self.takeRuntimeLocked(runtime_key);
        }

        if (self.by_agent.count() >= self.max_runtimes) return error.RuntimeLimitReached;

        const owned_runtime_key = try self.allocator.dupe(u8, runtime_key);
        errdefer self.allocator.free(owned_runtime_key);

        try self.by_agent.put(self.allocator, owned_runtime_key, entry);
        entry_installed = true;
        const runtime = self.by_agent.getPtr(owned_runtime_key).?.runtime;
        runtime.retain();
        return runtime;
    }

    fn createRuntimeEntry(
        self: *AgentRuntimeRegistry,
        agent_id: []const u8,
        project_id: []const u8,
        project_token: ?[]const u8,
    ) !AgentRuntimeEntry {
        _ = project_token;
        const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
            self.allocator,
            "external_worker_required",
            "external worker required; mount the workspace and start Spider Monkey",
        );
        errdefer runtime_handle.destroy();
        return .{
            .runtime = runtime_handle,
            .project_id = try self.allocator.dupe(u8, project_id),
            .runtime_agent_id = try self.allocator.dupe(u8, agent_id),
        };
    }

    fn resolveProjectId(
        self: *AgentRuntimeRegistry,
        agent_id: []const u8,
        requested_project_id: ?[]const u8,
    ) ![]u8 {
        _ = agent_id;
        if (requested_project_id) |project_id| {
            if (!isValidProjectId(project_id)) return error.InvalidProjectId;
            if (!self.control_plane.projectHasMounts(project_id)) {
                return error.ProjectMountsMissing;
            }
            return self.allocator.dupe(u8, project_id);
        }
        return error.ProjectRequired;
    }

    fn isValidAgentId(agent_id: []const u8) bool {
        if (agent_id.len == 0 or agent_id.len > max_agent_id_len) return false;
        if (std.mem.eql(u8, agent_id, ".")) return false;
        for (agent_id) |char| {
            if (std.ascii.isAlphanumeric(char)) continue;
            if (char == '_' or char == '-') continue;
            return false;
        }
        return true;
    }

    fn isValidProjectId(project_id: []const u8) bool {
        if (project_id.len == 0 or project_id.len > max_project_id_len) return false;
        if (std.mem.eql(u8, project_id, ".") or std.mem.eql(u8, project_id, "..")) return false;
        for (project_id) |char| {
            if (std.ascii.isAlphanumeric(char)) continue;
            if (char == '_' or char == '-' or char == '.') continue;
            return false;
        }
        return true;
    }

    fn hasRuntimeForBinding(self: *AgentRuntimeRegistry, agent_id: []const u8, project_id: ?[]const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const runtime_key = runtimeMapKeyForProject(project_id);
        const existing = self.by_agent.getPtr(runtime_key) orelse return false;
        if (!std.mem.eql(u8, existing.runtime_agent_id, agent_id)) return false;
        return existing.runtime.isHealthy();
    }

    fn hasHealthyRuntimeForProject(self: *AgentRuntimeRegistry, project_id: ?[]const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const runtime_key = runtimeMapKeyForProject(project_id);
        const existing = self.by_agent.getPtr(runtime_key) orelse return false;
        return existing.runtime.isHealthy();
    }

    fn runtimeBindingKey(self: *AgentRuntimeRegistry, agent_id: []const u8, project_id: ?[]const u8) ![]u8 {
        _ = agent_id;
        return self.allocator.dupe(u8, runtimeMapKeyForProject(project_id));
    }

    fn runtimeAttachSnapshotByKey(self: *AgentRuntimeRegistry, binding_key: []const u8) SessionAttachStateSnapshot {
        self.runtime_warmups_mutex.lock();
        defer self.runtime_warmups_mutex.unlock();
        if (self.runtime_warmups.getPtr(binding_key)) |state| {
            return state.snapshotOwned(self.allocator) catch .{
                .state = state.state,
                .runtime_ready = state.runtime_ready,
                .mount_ready = state.mount_ready,
                .updated_at_ms = state.updated_at_ms,
            };
        }
        return .{
            .state = .warming,
            .runtime_ready = false,
            .mount_ready = false,
            .updated_at_ms = std.time.milliTimestamp(),
        };
    }

    fn runtimeAttachSnapshot(self: *AgentRuntimeRegistry, agent_id: []const u8, project_id: ?[]const u8) SessionAttachStateSnapshot {
        _ = agent_id;
        if (project_id) |value| {
            if (self.control_plane.projectHasMounts(value)) {
                return .{
                    .state = .ready,
                    .runtime_ready = true,
                    .mount_ready = true,
                    .updated_at_ms = std.time.milliTimestamp(),
                };
            }
            var snapshot = SessionAttachStateSnapshot{
                .state = .err,
                .runtime_ready = false,
                .mount_ready = false,
                .updated_at_ms = std.time.milliTimestamp(),
            };
            snapshot.error_code = self.allocator.dupe(u8, "project_mounts_missing") catch null;
            snapshot.error_message = self.allocator.dupe(u8, "project has no workspace mounts configured") catch null;
            return snapshot;
        }
        return .{
            .state = .err,
            .runtime_ready = false,
            .mount_ready = false,
            .updated_at_ms = std.time.milliTimestamp(),
            .error_code = self.allocator.dupe(u8, "project_required") catch null,
            .error_message = self.allocator.dupe(u8, "workspace attach requires a project binding") catch null,
        };
    }

    pub fn touchRuntimeAttachState(self: *AgentRuntimeRegistry, agent_id: []const u8, project_id: ?[]const u8) void {
        const binding_key = self.runtimeBindingKey(agent_id, project_id) catch return;
        defer self.allocator.free(binding_key);
        if (project_id) |value| {
            if (self.control_plane.projectHasMounts(value)) {
                self.markRuntimeWarmupReady(binding_key);
            } else {
                self.markRuntimeWarmupError(
                    binding_key,
                    "project_mounts_missing",
                    "project has no workspace mounts configured",
                );
            }
            return;
        }
        self.markRuntimeWarmupError(
            binding_key,
            "project_required",
            "workspace attach requires a project binding",
        );
    }

    const RuntimeWarmupErrorInfo = struct {
        code: []const u8,
        message: []const u8,
    };

    fn mapRuntimeWarmupError(err: anyerror) RuntimeWarmupErrorInfo {
        return switch (err) {
            error.InvalidAgentId => .{
                .code = "invalid_payload",
                .message = "invalid agent_id",
            },
            error.InvalidProjectId => .{
                .code = "invalid_payload",
                .message = "invalid project_id",
            },
            error.RuntimeLimitReached => .{
                .code = "queue_saturated",
                .message = "project runtime limit reached",
            },
            error.ProcessFdQuotaExceeded => .{
                .code = "runtime_resource_exhausted",
                .message = "runtime hit process fd quota",
            },
            error.ProjectRequired => .{
                .code = "project_required",
                .message = "workspace attach requires a project binding",
            },
            error.ProjectMountsMissing => .{
                .code = "project_mounts_missing",
                .message = "project has no workspace mounts configured",
            },
            error.SandboxMountUnavailable => .{
                .code = "sandbox_mount_unavailable",
                .message = "sandbox mount is unavailable",
            },
            error.InvalidSandboxConfig => .{
                .code = "sandbox_invalid_config",
                .message = "sandbox config is invalid",
            },
            error.ProjectResolutionFailed => .{
                .code = "sandbox_mount_unavailable",
                .message = "sandbox project resolution failed",
            },
            else => .{
                .code = "execution_failed",
                .message = @errorName(err),
            },
        };
    }

    fn emitSessionAttachStateDebugEvent(
        self: *AgentRuntimeRegistry,
        binding_key: []const u8,
        state: SessionAttachStateSnapshot,
    ) void {
        _ = self;
        _ = binding_key;
        _ = state;
    }

    fn markRuntimeWarmupReady(self: *AgentRuntimeRegistry, binding_key: []const u8) void {
        var snapshot = SessionAttachStateSnapshot{
            .state = .ready,
            .runtime_ready = true,
            .mount_ready = true,
            .updated_at_ms = std.time.milliTimestamp(),
        };
        defer snapshot.deinit(self.allocator);
        self.runtime_warmups_mutex.lock();
        if (self.runtime_warmups.getPtr(binding_key)) |state| {
            state.setReady(self.allocator);
            state.in_flight = false;
            snapshot.deinit(self.allocator);
            snapshot = state.snapshotOwned(self.allocator) catch .{
                .state = .ready,
                .runtime_ready = true,
                .mount_ready = true,
                .updated_at_ms = std.time.milliTimestamp(),
            };
        } else {
            const owned_key = self.allocator.dupe(u8, binding_key) catch {
                self.runtime_warmups_mutex.unlock();
                self.emitSessionAttachStateDebugEvent(binding_key, snapshot);
                return;
            };
            var state = RuntimeWarmupState{};
            state.setReady(self.allocator);
            state.in_flight = false;
            self.runtime_warmups.put(self.allocator, owned_key, state) catch {
                var cleanup = state;
                cleanup.deinit(self.allocator);
                self.allocator.free(owned_key);
                self.runtime_warmups_mutex.unlock();
                self.emitSessionAttachStateDebugEvent(binding_key, snapshot);
                return;
            };
        }
        self.runtime_warmups_mutex.unlock();
        self.emitSessionAttachStateDebugEvent(binding_key, snapshot);
    }

    fn markRuntimeWarmupError(self: *AgentRuntimeRegistry, binding_key: []const u8, code: []const u8, message: []const u8) void {
        var snapshot = SessionAttachStateSnapshot{
            .state = .err,
            .runtime_ready = false,
            .mount_ready = false,
            .updated_at_ms = std.time.milliTimestamp(),
        };
        snapshot.error_code = self.allocator.dupe(u8, code) catch null;
        snapshot.error_message = self.allocator.dupe(u8, message) catch null;
        defer snapshot.deinit(self.allocator);
        self.runtime_warmups_mutex.lock();
        if (self.runtime_warmups.getPtr(binding_key)) |state| {
            state.setError(self.allocator, code, message) catch {
                if (state.error_code) |value| self.allocator.free(value);
                if (state.error_message) |value| self.allocator.free(value);
                state.error_code = null;
                state.error_message = null;
                state.state = .err;
                state.runtime_ready = false;
                state.mount_ready = false;
                state.updated_at_ms = std.time.milliTimestamp();
            };
            state.in_flight = false;
            snapshot.deinit(self.allocator);
            snapshot = state.snapshotOwned(self.allocator) catch .{
                .state = .err,
                .runtime_ready = false,
                .mount_ready = false,
                .updated_at_ms = std.time.milliTimestamp(),
            };
            if (snapshot.error_code == null) {
                snapshot.error_code = self.allocator.dupe(u8, code) catch null;
            }
            if (snapshot.error_message == null) {
                snapshot.error_message = self.allocator.dupe(u8, message) catch null;
            }
        } else {
            const owned_key = self.allocator.dupe(u8, binding_key) catch {
                self.runtime_warmups_mutex.unlock();
                self.emitSessionAttachStateDebugEvent(binding_key, snapshot);
                return;
            };
            var state = RuntimeWarmupState{};
            state.setError(self.allocator, code, message) catch {
                if (state.error_code) |value| self.allocator.free(value);
                if (state.error_message) |value| self.allocator.free(value);
                state.error_code = null;
                state.error_message = null;
                state.state = .err;
                state.runtime_ready = false;
                state.mount_ready = false;
                state.updated_at_ms = std.time.milliTimestamp();
            };
            state.in_flight = false;
            self.runtime_warmups.put(self.allocator, owned_key, state) catch {
                var cleanup = state;
                cleanup.deinit(self.allocator);
                self.allocator.free(owned_key);
                self.runtime_warmups_mutex.unlock();
                self.emitSessionAttachStateDebugEvent(binding_key, snapshot);
                return;
            };
            if (self.runtime_warmups.getPtr(binding_key)) |inserted| {
                snapshot.deinit(self.allocator);
                snapshot = inserted.snapshotOwned(self.allocator) catch .{
                    .state = .err,
                    .runtime_ready = false,
                    .mount_ready = false,
                    .updated_at_ms = std.time.milliTimestamp(),
                };
                if (snapshot.error_code == null) {
                    snapshot.error_code = self.allocator.dupe(u8, code) catch null;
                }
                if (snapshot.error_message == null) {
                    snapshot.error_message = self.allocator.dupe(u8, message) catch null;
                }
            }
        }
        self.runtime_warmups_mutex.unlock();
        self.emitSessionAttachStateDebugEvent(binding_key, snapshot);
    }

    pub fn beginRuntimeWarmupThread(self: *AgentRuntimeRegistry) !void {
        self.runtime_warmup_lifecycle_mutex.lock();
        defer self.runtime_warmup_lifecycle_mutex.unlock();
        if (self.runtime_warmup_stopping) return error.ShuttingDown;
        self.runtime_warmup_inflight += 1;
    }

    pub fn finishRuntimeWarmupThread(self: *AgentRuntimeRegistry) void {
        self.runtime_warmup_lifecycle_mutex.lock();
        if (self.runtime_warmup_inflight > 0) {
            self.runtime_warmup_inflight -= 1;
        }
        if (self.runtime_warmup_stopping and self.runtime_warmup_inflight == 0) {
            self.runtime_warmup_lifecycle_cond.broadcast();
        } else if (self.runtime_warmup_inflight == 0) {
            self.runtime_warmup_lifecycle_cond.signal();
        }
        self.runtime_warmup_lifecycle_mutex.unlock();
    }

    fn spawnRuntimeWarmupThread(
        self: *AgentRuntimeRegistry,
        binding_key: []const u8,
        agent_id: []const u8,
        project_id: ?[]const u8,
        project_token: ?[]const u8,
    ) !void {
        try server_runtime_workers.spawnRuntimeWarmupThread(
            self,
            binding_key,
            agent_id,
            project_id,
            project_token,
        );
    }

    pub fn ensureRuntimeWarmup(
        self: *AgentRuntimeRegistry,
        agent_id: []const u8,
        project_id: ?[]const u8,
        project_token: ?[]const u8,
        retry_on_error: bool,
    ) !SessionAttachStateSnapshot {
        _ = project_token;
        _ = retry_on_error;
        if (project_id) |value| {
            if (!self.control_plane.projectHasMounts(value)) {
                const binding_key = try self.runtimeBindingKey(agent_id, project_id);
                defer self.allocator.free(binding_key);
                self.markRuntimeWarmupError(
                    binding_key,
                    "project_mounts_missing",
                    "project has no workspace mounts configured",
                );
                return self.runtimeAttachSnapshotByKey(binding_key);
            }
            const binding_key = try self.runtimeBindingKey(agent_id, project_id);
            defer self.allocator.free(binding_key);
            self.markRuntimeWarmupReady(binding_key);
            return self.runtimeAttachSnapshotByKey(binding_key);
        }
        const binding_key = try self.runtimeBindingKey(agent_id, project_id);
        defer self.allocator.free(binding_key);
        self.markRuntimeWarmupError(
            binding_key,
            "project_required",
            "workspace attach requires a project binding",
        );
        return self.runtimeAttachSnapshotByKey(binding_key);
    }

    pub fn getFirstAgentId(self: *AgentRuntimeRegistry) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.by_agent.keyIterator();
        const first = it.next() orelse return null;
        return first.*;
    }

    fn maybeLogDebugFrame(self: *AgentRuntimeRegistry, agent_id: []const u8, payload: []const u8) void {
        _ = self;
        _ = agent_id;
        _ = payload;
    }

    fn appendAuditRecordName(
        self: *AgentRuntimeRegistry,
        agent_id: []const u8,
        control_type_name: []const u8,
        scope: ControlMutationScope,
        correlation_id: ?[]const u8,
        succeeded: bool,
        error_code: ?[]const u8,
    ) void {
        self.audit_records_mutex.lock();
        defer self.audit_records_mutex.unlock();

        while (self.audit_records.items.len >= 2048) {
            var removed = self.audit_records.orderedRemove(0);
            removed.deinit(self.allocator);
        }

        const record = AuditRecord{
            .id = self.next_audit_record_id,
            .timestamp_ms = std.time.milliTimestamp(),
            .agent_id = self.allocator.dupe(u8, agent_id) catch return,
            .control_type = self.allocator.dupe(u8, control_type_name) catch return,
            .scope = scope,
            .correlation_id = if (correlation_id) |value| self.allocator.dupe(u8, value) catch return else null,
            .result = self.allocator.dupe(u8, if (succeeded) "ok" else "error") catch return,
            .error_code = if (error_code) |value| self.allocator.dupe(u8, value) catch return else null,
        };
        self.audit_records.append(self.allocator, record) catch {
            var cleanup = record;
            cleanup.deinit(self.allocator);
            return;
        };
        self.next_audit_record_id +%= 1;
        if (self.next_audit_record_id == 0) self.next_audit_record_id = 1;
    }

    pub fn appendAuditRecord(
        self: *AgentRuntimeRegistry,
        agent_id: []const u8,
        control_type: unified.ControlType,
        scope: ControlMutationScope,
        correlation_id: ?[]const u8,
        succeeded: bool,
        error_code: ?[]const u8,
    ) void {
        self.appendAuditRecordName(
            agent_id,
            unified.controlTypeName(control_type),
            scope,
            correlation_id,
            succeeded,
            error_code,
        );
    }

    pub fn appendSecurityAuditAndDebug(
        self: *AgentRuntimeRegistry,
        agent_id: []const u8,
        control_type: unified.ControlType,
        role: ConnectionRole,
        correlation_id: ?[]const u8,
        event_name: []const u8,
        succeeded: bool,
        error_code: ?[]const u8,
        message: ?[]const u8,
    ) void {
        self.appendAuditRecord(
            agent_id,
            control_type,
            .none,
            correlation_id,
            succeeded,
            error_code,
        );

        const escaped_event = unified.jsonEscape(self.allocator, event_name) catch return;
        defer self.allocator.free(escaped_event);
        const escaped_control_type = unified.jsonEscape(self.allocator, unified.controlTypeName(control_type)) catch return;
        defer self.allocator.free(escaped_control_type);
        const escaped_role = unified.jsonEscape(self.allocator, connectionRoleName(role)) catch return;
        defer self.allocator.free(escaped_role);
        const escaped_result = unified.jsonEscape(self.allocator, if (succeeded) "ok" else "error") catch return;
        defer self.allocator.free(escaped_result);

        const correlation_json = if (correlation_id) |value| blk: {
            const escaped = unified.jsonEscape(self.allocator, value) catch return;
            defer self.allocator.free(escaped);
            break :blk std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped}) catch return;
        } else self.allocator.dupe(u8, "null") catch return;
        defer self.allocator.free(correlation_json);

        const error_json = if (error_code) |value| blk: {
            const escaped = unified.jsonEscape(self.allocator, value) catch return;
            defer self.allocator.free(escaped);
            break :blk std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped}) catch return;
        } else self.allocator.dupe(u8, "null") catch return;
        defer self.allocator.free(error_json);

        const message_json = if (message) |value| blk: {
            const escaped = unified.jsonEscape(self.allocator, value) catch return;
            defer self.allocator.free(escaped);
            break :blk std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped}) catch return;
        } else self.allocator.dupe(u8, "null") catch return;
        defer self.allocator.free(message_json);

        const payload_json = std.fmt.allocPrint(
            self.allocator,
            "{{\"event\":\"{s}\",\"control_type\":\"{s}\",\"role\":\"{s}\",\"result\":\"{s}\",\"correlation_id\":{s},\"error_code\":{s},\"message\":{s},\"ts_ms\":{d}}}",
            .{
                escaped_event,
                escaped_control_type,
                escaped_role,
                escaped_result,
                correlation_json,
                error_json,
                message_json,
                std.time.milliTimestamp(),
            },
        ) catch return;
        defer self.allocator.free(payload_json);

        const debug_json = protocol.buildDebugEvent(
            self.allocator,
            correlation_id orelse "security",
            "control.security",
            payload_json,
        ) catch return;
        defer self.allocator.free(debug_json);
        self.maybeLogDebugFrame(agent_id, debug_json);
    }

    pub fn buildAuditTailPayload(self: *AgentRuntimeRegistry, payload_json: ?[]const u8) ![]u8 {
        return server_audit_records.buildAuditTailPayload(self, payload_json);
    }

    pub fn metricsJson(self: *AgentRuntimeRegistry) ![]u8 {
        return self.control_plane.metricsJson();
    }

    pub fn metricsPrometheus(self: *AgentRuntimeRegistry) ![]u8 {
        return self.control_plane.metricsPrometheus();
    }

    fn pruneLegacyHostCapabilityMounts(self: *AgentRuntimeRegistry) void {
        const legacy_paths = [_][]const u8{
            legacy_local_node_mount_agents_self_capabilities,
            legacy_local_node_mount_projects_host_agents_self_capabilities,
        };
        for (legacy_paths) |mount_path| {
            const removed = self.control_plane.removeHostMount(mount_path, null, null) catch |err| switch (err) {
                else => {
                    std.log.warn(
                        "failed pruning legacy host mount {s}: {s}",
                        .{ mount_path, @errorName(err) },
                    );
                    continue;
                },
            };
            if (!removed) continue;
            std.log.info("pruned legacy host mount path: {s}", .{mount_path});
        }
    }

    pub fn runRuntimeWarmupThread(
        self: *AgentRuntimeRegistry,
        binding_key: []const u8,
        agent_id: []const u8,
        project_id: ?[]const u8,
        project_token: ?[]const u8,
    ) void {
        defer self.finishRuntimeWarmupThread();

        const runtime = self.getOrCreate(
        agent_id,
        project_id,
        project_token,
    ) catch |err| {
        std.log.warn("runtime warmup thread failed: agent={s} project={s} err={s}", .{
            agent_id,
            project_id orelse "__auto__",
            @errorName(err),
        });
        const info = AgentRuntimeRegistry.mapRuntimeWarmupError(err);
        self.markRuntimeWarmupError(
            binding_key,
            info.code,
            info.message,
        );
        return;
    };
    runtime.release();

        self.markRuntimeWarmupReady(binding_key);
    }

    pub fn runServicePresenceWorkerLoop(self: *AgentRuntimeRegistry) void {
        while (true) {
            self.venom_presence_worker_mutex.lock();
            while (self.venom_presence_jobs.items.len == 0 and !self.venom_presence_worker_stop) {
                self.venom_presence_worker_cond.wait(&self.venom_presence_worker_mutex);
            }
            if (self.venom_presence_worker_stop and self.venom_presence_jobs.items.len == 0) {
                self.venom_presence_worker_mutex.unlock();
                return;
            }
            var job = self.venom_presence_jobs.orderedRemove(0);
            self.venom_presence_worker_mutex.unlock();
            defer job.deinit(self.allocator);

            self.dispatchRuntimeAgentControlForTarget(
            job.agent_id,
            job.project_id,
            "venom.event",
            job.payload_json,
        ) catch |err| {
            std.log.warn(
                "service presence sync failed: agent={s} session={s} status={s} err={s}",
                .{
                    job.agent_id,
                    job.session_key,
                    if (job.attached) "attached" else "detached",
                    @errorName(err),
                },
            );
            };
        }
    }

};

fn sessionAttachStateName(state: SessionAttachState) []const u8 {
    return switch (state) {
        .warming => "warming",
        .ready => "ready",
        .err => "error",
    };
}

pub fn run(
    allocator: std.mem.Allocator,
    bind_addr: []const u8,
    port: u16,
    runtime_config: Config.RuntimeConfig,
) !void {
    var runtime_registry = AgentRuntimeRegistry.init(allocator, runtime_config);
    defer runtime_registry.deinit();

    warnDeprecatedEmbeddedLocalNodeEnv(allocator);

    runtime_registry.workspace_url = try server_local_node_supervisor.formatInternalWsUrl(allocator, bind_addr, port, "/");
    try runtime_registry.startVenomPresenceWorker();
    try runtime_registry.startReconcileWorker();

    const metrics_port_raw = parseUnsignedEnv(allocator, metrics_port_env, 0);
    if (metrics_port_raw > 0) {
        if (metrics_port_raw > std.math.maxInt(u16)) {
            std.log.warn("ignoring {s}={d}: out of range", .{ metrics_port_env, metrics_port_raw });
        } else {
            const metrics_port: u16 = @intCast(metrics_port_raw);
            const metrics_address = try std.net.Address.parseIp(bind_addr, metrics_port);
            const listener_ptr = try allocator.create(std.net.Server);
            errdefer allocator.destroy(listener_ptr);
            listener_ptr.* = try metrics_address.listen(.{ .reuse_address = true });
            // Listener intentionally lives for process lifetime; metrics thread owns accept loop.
            errdefer listener_ptr.deinit();

            const metrics_thread = try std.Thread.spawn(
                .{},
                server_metrics_http.runMetricsHttpServer,
                .{ allocator, &runtime_registry, listener_ptr },
            );
            metrics_thread.detach();
            std.log.info(
                "Metrics HTTP endpoint listening at http://{s}:{d}/metrics",
                .{ bind_addr, metrics_port },
            );
        }
    }

    const address = try std.net.Address.parseIp(bind_addr, port);
    var tcp_server = try address.listen(.{ .reuse_address = true });
    defer tcp_server.deinit();

    const configured_connection_workers = runtime_config.connection_worker_threads;
    const effective_connection_workers = @max(configured_connection_workers, min_connection_worker_threads);
    if (effective_connection_workers != configured_connection_workers) {
        std.log.warn(
            "runtime.connection_worker_threads={d} is too low for fsrpc endpoint fan-out; using {d}",
            .{ configured_connection_workers, effective_connection_workers },
        );
    }

    const dispatcher = try connection_dispatcher.ConnectionDispatcher.create(
        allocator,
        effective_connection_workers,
        runtime_config.connection_queue_max,
        workerHandleConnection,
        &runtime_registry,
    );
    defer dispatcher.destroy();

    std.log.info(
        "Runtime websocket server listening at ws://{s}:{d}",
        .{ bind_addr, port },
    );
    runtime_registry.startLocalNodeSupervisor(bind_addr, port) catch |err| {
        std.log.warn("local node supervisor disabled: {s}", .{@errorName(err)});
    };

    while (true) {
        var connection = tcp_server.accept() catch |err| {
            std.log.err("accept failed: {s}", .{@errorName(err)});
            continue;
        };

        const accepted = dispatcher.enqueue(connection.stream) catch |err| {
            std.log.err("failed to enqueue connection: {s}", .{@errorName(err)});
            sendServiceUnavailable(&connection.stream) catch {};
            connection.stream.close();
            continue;
        };
        if (!accepted) {
            sendServiceUnavailable(&connection.stream) catch {};
            connection.stream.close();
        }
    }
}

fn workerHandleConnection(
    allocator: std.mem.Allocator,
    stream: *std.net.Stream,
    ctx: ?*anyopaque,
) !void {
    const runtime_registry: *AgentRuntimeRegistry = @ptrCast(@alignCast(ctx orelse return error.InvalidContext));
    try handleWebSocketConnection(allocator, runtime_registry, stream);
}

fn handleWebSocketConnection(
    allocator: std.mem.Allocator,
    runtime_registry: *AgentRuntimeRegistry,
    stream: *std.net.Stream,
) !void {
    var handshake = try websocket_transport.performHandshakeWithInfo(allocator, stream);
    defer handshake.deinit(allocator);
    const connection_workspace_url = try deriveConnectionWorkspaceUrl(
        allocator,
        handshake.host,
        runtime_registry.workspace_url,
    );
    defer if (connection_workspace_url) |value| allocator.free(value);

    if (std.mem.eql(u8, handshake.path, "/fs")) {
        try sendWebSocketErrorAndClose(
            allocator,
            stream,
            .invalid_envelope,
            "embedded /fs endpoint was removed; use the local node fs_url or /fs/node/<node_id>",
        );
        return;
    }

    if (isNodeTunnelPath(handshake.path)) {
        try handleNodeTunnelConnection(allocator, runtime_registry, stream);
        return;
    }

    const maybe_node_fs_route = parseNodeFsRoute(handshake.path);

    if (maybe_node_fs_route == null) {
        _ = resolveAgentIdFromConnectionPath(handshake.path, runtime_registry.default_agent_id) orelse {
            try sendWebSocketErrorAndClose(allocator, stream, .invalid_envelope, "invalid websocket path");
            return;
        };
    }

    if (maybe_node_fs_route) |node_id| {
        try handleRoutedNodeFsConnection(
            allocator,
            runtime_registry,
            node_id,
            stream,
        );
        return;
    }

    const principal = runtime_registry.authenticateConnection(handshake.authorization) orelse {
        try sendWebSocketErrorAndClose(allocator, stream, .provider_auth_failed, "forbidden");
        return;
    };

    var session_bindings: std.StringHashMapUnmanaged(SessionBinding) = .{};
    defer server_session_bindings.deinitSessionBindings(allocator, &session_bindings);

    var initial_binding = try runtime_registry.buildInitialSessionBinding(principal.role);
    defer initial_binding.binding.deinit(allocator);
    try server_session_bindings.upsertSessionBinding(
        allocator,
        &session_bindings,
        "main",
        initial_binding.binding.agent_id,
        server_session_bindings.defaultActorTypeForRole(principal.role),
        server_session_bindings.defaultActorIdForPrincipal(principal),
        initial_binding.binding.project_id,
        initial_binding.binding.project_token,
    );
    var active_session_key = try allocator.dupe(u8, "main");
    defer allocator.free(active_session_key);
    var control_protocol_negotiated = false;
    var namespace_session: ?acheron_session_mod.Session = null;
    defer resetNamespaceSession(&namespace_session);
    var connection_write_mutex: std.Thread.Mutex = .{};
    const connection_venom_id = try std.fmt.allocPrint(
        allocator,
        "ws.{s}.{d}",
        .{ connectionRoleName(principal.role), std.time.nanoTimestamp() },
    );
    defer allocator.free(connection_venom_id);
    var control_service_attached = false;
    defer {
        if (control_service_attached) {
            if (session_bindings.get(active_session_key)) |binding| {
                runtime_registry.publishVenomPresenceForBinding(
                    principal.role,
                    binding,
                    active_session_key,
                    connection_venom_id,
                    false,
                );
            }
        }
    }

    while (true) {
        var frame = websocket_transport.readFrame(
            allocator,
            stream,
            websocket_transport.default_max_ws_frame_payload_bytes,
        ) catch |err| switch (err) {
            error.EndOfStream, websocket_transport.Error.ConnectionClosed => return,
            else => return err,
        };
        defer frame.deinit(allocator);

        switch (frame.opcode) {
            0x1 => {
                var parsed = unified.parseMessage(allocator, frame.payload) catch |err| {
                    const response = try unified.buildControlError(
                        allocator,
                        null,
                        "unsupported_legacy_api",
                        @errorName(err),
                    );
                    defer allocator.free(response);
                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                    continue;
                };
                defer parsed.deinit(allocator);

                switch (parsed.channel) {
                    .control => {
                        const control_type = parsed.control_type orelse {
                            const response = try unified.buildControlError(
                                allocator,
                                parsed.id,
                                "invalid_type",
                                "missing control type",
                            );
                            defer allocator.free(response);
                            try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                            continue;
                        };

                        if (!control_protocol_negotiated and control_type != .version) {
                            const response = try unified.buildControlError(
                                allocator,
                                parsed.id,
                                "protocol_mismatch",
                                "control.version must be negotiated first",
                            );
                            defer allocator.free(response);
                            try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                            try writeFrameLocked(stream, &connection_write_mutex, "", .close);
                            return;
                        }
                        switch (control_type) {
                            .version => {
                                validateControlVersionPayload(allocator, parsed.payload_json) catch |err| {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "protocol_mismatch",
                                        @errorName(err),
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    try writeFrameLocked(stream, &connection_write_mutex, "", .close);
                                    return;
                                };
                                control_protocol_negotiated = true;
                                const payload = try std.fmt.allocPrint(
                                    allocator,
                                    "{{\"protocol\":\"{s}\",\"acheron_runtime\":\"{s}\",\"acheron_node\":\"{s}\",\"acheron_node_proto\":{d}}}",
                                    .{
                                        control_protocol_version,
                                        acheron_runtime_protocol_version,
                                        acheron_node_protocol_version,
                                        acheron_node_proto_id,
                                    },
                                );
                                defer allocator.free(payload);
                                const response = try unified.buildControlAck(
                                    allocator,
                                    .version_ack,
                                    parsed.id,
                                    payload,
                                );
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                            .connect => {
                                const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                const payload = try buildConnectAckPayload(
                                    allocator,
                                    runtime_registry,
                                    active_binding,
                                    active_session_key,
                                    connection_workspace_url,
                                    principal.role == .access,
                                    control_protocol_version,
                                );
                                defer allocator.free(payload);
                                const response = try unified.buildControlAck(
                                    allocator,
                                    .connect_ack,
                                    parsed.id,
                                    payload,
                                );
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                control_service_attached = true;
                                runtime_registry.publishVenomPresenceForBinding(
                                    principal.role,
                                    active_binding,
                                    active_session_key,
                                    connection_venom_id,
                                    true,
                                );
                                continue;
                            },
                            .ping => {
                                const response = try unified.buildControlAck(
                                    allocator,
                                    .pong,
                                    parsed.id,
                                    "{}",
                                );
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                            .metrics => {
                                if (principal.role != .access) {
                                    const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                    runtime_registry.appendSecurityAuditAndDebug(
                                        active_binding.agent_id,
                                        .metrics,
                                        principal.role,
                                        parsed.correlation_id orelse parsed.id,
                                        "metrics_forbidden",
                                        false,
                                        "forbidden",
                                        "operation requires access token",
                                    );
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "forbidden",
                                        "operation requires access token",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                }
                                const payload = try runtime_registry.metricsJson();
                                defer allocator.free(payload);
                                const response = try unified.buildControlAck(
                                    allocator,
                                    .metrics,
                                    parsed.id,
                                    payload,
                                );
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                            .auth_status => {
                                const auth_status = try server_session_observer_controls.handleAuthStatusControl(
                                    allocator,
                                    runtime_registry,
                                    &session_bindings,
                                    active_session_key,
                                    principal,
                                    parsed.correlation_id orelse parsed.id,
                                );
                                switch (auth_status) {
                                    .ack => |payload| {
                                        defer allocator.free(payload);
                                        const response = try unified.buildControlAck(
                                            allocator,
                                            .auth_status,
                                            parsed.id,
                                            payload,
                                        );
                                        defer allocator.free(response);
                                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    },
                                    .err => |err_payload| {
                                        const response = try unified.buildControlError(
                                            allocator,
                                            parsed.id,
                                            err_payload.code,
                                            err_payload.message,
                                        );
                                        defer allocator.free(response);
                                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    },
                                }
                                continue;
                            },
                            .auth_rotate => {
                                if (principal.role != .access) {
                                    const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                    runtime_registry.appendSecurityAuditAndDebug(
                                        active_binding.agent_id,
                                        .auth_rotate,
                                        principal.role,
                                        parsed.correlation_id orelse parsed.id,
                                        "auth_rotate_forbidden",
                                        false,
                                        "forbidden",
                                        "operation requires access token",
                                    );
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "forbidden",
                                        "operation requires access token",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                }
                                var payload = try parseControlPayloadObject(allocator, parsed.payload_json);
                                defer payload.deinit();
                                if (payload.value != .object) {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "invalid_payload",
                                        "auth_rotate payload must be an object",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                }
                                const rotated = runtime_registry.rotateAuthToken(.access) catch |err| {
                                    const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                    runtime_registry.appendSecurityAuditAndDebug(
                                        active_binding.agent_id,
                                        .auth_rotate,
                                        principal.role,
                                        parsed.correlation_id orelse parsed.id,
                                        "auth_rotate_persist_failed",
                                        false,
                                        "storage_error",
                                        @errorName(err),
                                    );
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "storage_error",
                                        @errorName(err),
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                defer runtime_registry.allocator.free(rotated);
                                const escaped_token = try unified.jsonEscape(allocator, rotated);
                                defer allocator.free(escaped_token);
                                const payload_json = try std.fmt.allocPrint(
                                    allocator,
                                    "{{\"access_token\":\"{s}\"}}",
                                    .{escaped_token},
                                );
                                defer allocator.free(payload_json);
                                const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                runtime_registry.appendSecurityAuditAndDebug(
                                    active_binding.agent_id,
                                    .auth_rotate,
                                    principal.role,
                                    parsed.correlation_id orelse parsed.id,
                                    "auth_rotate_access_success",
                                    true,
                                    null,
                                    null,
                                );
                                const response = try unified.buildControlAck(
                                    allocator,
                                    .auth_rotate,
                                    parsed.id,
                                    payload_json,
                                );
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                            .session_attach => {
                                const session_attach = try server_session_controls.handleSessionAttachControl(
                                    allocator,
                                    runtime_registry,
                                    &session_bindings,
                                    &active_session_key,
                                    &namespace_session,
                                    principal,
                                    connection_venom_id,
                                    control_service_attached,
                                    connection_workspace_url,
                                    parsed.payload_json,
                                );
                                switch (session_attach) {
                                    .ack => |ack_payload| {
                                        defer allocator.free(ack_payload);
                                        const response = try unified.buildControlAck(
                                            allocator,
                                            .session_attach,
                                            parsed.id,
                                            ack_payload,
                                        );
                                        defer allocator.free(response);
                                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    },
                                    .err => |err_payload| {
                                        const response = try unified.buildControlError(
                                            allocator,
                                            parsed.id,
                                            err_payload.code,
                                            err_payload.message,
                                        );
                                        defer allocator.free(response);
                                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    },
                                }
                                continue;
                            },
                            .session_status => {
                                const session_status = try server_session_observer_controls.handleSessionStatusControl(
                                    allocator,
                                    runtime_registry,
                                    &session_bindings,
                                    active_session_key,
                                    principal,
                                    parsed.payload_json,
                                );
                                switch (session_status) {
                                    .ack => |payload_json| {
                                        defer allocator.free(payload_json);
                                        const response = try unified.buildControlAck(
                                            allocator,
                                            .session_status,
                                            parsed.id,
                                            payload_json,
                                        );
                                        defer allocator.free(response);
                                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    },
                                    .err => |err_payload| {
                                        const response = try unified.buildControlError(
                                            allocator,
                                            parsed.id,
                                            err_payload.code,
                                            err_payload.message,
                                        );
                                        defer allocator.free(response);
                                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    },
                                }
                                continue;
                            },
                            .mount_attach => {
                                const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                const payload_json = handleMountAttachControl(
                                    allocator,
                                    runtime_registry,
                                    &namespace_session,
                                    active_binding,
                                    active_session_key,
                                    trustedNamespaceMountUrl(runtime_registry.workspace_url, connection_workspace_url),
                                    connection_workspace_url,
                                    principal.role == .access,
                                    parsed.payload_json,
                                ) catch |err| {
                                    std.log.warn("mount_attach failed: {s}", .{@errorName(err)});
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        mountGraphErrorCode(err),
                                        @errorName(err),
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                defer allocator.free(payload_json);
                                const response = try unified.buildControlAck(
                                    allocator,
                                    .mount_attach,
                                    parsed.id,
                                    payload_json,
                                );
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                            .mount_file_read => {
                                const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                const payload_json = handleMountFileReadControl(
                                    allocator,
                                    runtime_registry,
                                    &namespace_session,
                                    active_binding,
                                    active_session_key,
                                    trustedNamespaceMountUrl(runtime_registry.workspace_url, connection_workspace_url),
                                    principal.role == .access,
                                    parsed.payload_json,
                                ) catch |err| {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        mountGraphErrorCode(err),
                                        @errorName(err),
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                defer allocator.free(payload_json);
                                const response = try unified.buildControlAck(
                                    allocator,
                                    .mount_file_read,
                                    parsed.id,
                                    payload_json,
                                );
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                            .mount_file_write => {
                                const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                const payload_json = handleMountFileWriteControl(
                                    allocator,
                                    runtime_registry,
                                    &namespace_session,
                                    active_binding,
                                    active_session_key,
                                    trustedNamespaceMountUrl(runtime_registry.workspace_url, connection_workspace_url),
                                    principal.role == .access,
                                    parsed.payload_json,
                                ) catch |err| {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        mountGraphErrorCode(err),
                                        @errorName(err),
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                defer allocator.free(payload_json);
                                const response = try unified.buildControlAck(
                                    allocator,
                                    .mount_file_write,
                                    parsed.id,
                                    payload_json,
                                );
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                            .mount_path_readlink => {
                                const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                const payload_json = handleMountPathControl(
                                    allocator,
                                    runtime_registry,
                                    &namespace_session,
                                    active_binding,
                                    active_session_key,
                                    trustedNamespaceMountUrl(runtime_registry.workspace_url, connection_workspace_url),
                                    principal.role == .access,
                                    parsed.payload_json,
                                    .mount_path_readlink,
                                ) catch |err| {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        mountGraphErrorCode(err),
                                        @errorName(err),
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                defer allocator.free(payload_json);
                                const response = try unified.buildControlAck(allocator, .mount_path_readlink, parsed.id, payload_json);
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                            .mount_path_mkdir => {
                                const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                const payload_json = handleMountPathControl(
                                    allocator,
                                    runtime_registry,
                                    &namespace_session,
                                    active_binding,
                                    active_session_key,
                                    trustedNamespaceMountUrl(runtime_registry.workspace_url, connection_workspace_url),
                                    principal.role == .access,
                                    parsed.payload_json,
                                    .mount_path_mkdir,
                                ) catch |err| {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        mountGraphErrorCode(err),
                                        @errorName(err),
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                defer allocator.free(payload_json);
                                const response = try unified.buildControlAck(allocator, .mount_path_mkdir, parsed.id, payload_json);
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                            .mount_path_unlink => {
                                const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                const payload_json = handleMountPathControl(
                                    allocator,
                                    runtime_registry,
                                    &namespace_session,
                                    active_binding,
                                    active_session_key,
                                    trustedNamespaceMountUrl(runtime_registry.workspace_url, connection_workspace_url),
                                    principal.role == .access,
                                    parsed.payload_json,
                                    .mount_path_unlink,
                                ) catch |err| {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        mountGraphErrorCode(err),
                                        @errorName(err),
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                defer allocator.free(payload_json);
                                const response = try unified.buildControlAck(allocator, .mount_path_unlink, parsed.id, payload_json);
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                            .mount_path_rmdir => {
                                const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                const payload_json = handleMountPathControl(
                                    allocator,
                                    runtime_registry,
                                    &namespace_session,
                                    active_binding,
                                    active_session_key,
                                    trustedNamespaceMountUrl(runtime_registry.workspace_url, connection_workspace_url),
                                    principal.role == .access,
                                    parsed.payload_json,
                                    .mount_path_rmdir,
                                ) catch |err| {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        mountGraphErrorCode(err),
                                        @errorName(err),
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                defer allocator.free(payload_json);
                                const response = try unified.buildControlAck(allocator, .mount_path_rmdir, parsed.id, payload_json);
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                            .mount_path_rename => {
                                const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                const payload_json = handleMountPathControl(
                                    allocator,
                                    runtime_registry,
                                    &namespace_session,
                                    active_binding,
                                    active_session_key,
                                    trustedNamespaceMountUrl(runtime_registry.workspace_url, connection_workspace_url),
                                    principal.role == .access,
                                    parsed.payload_json,
                                    .mount_path_rename,
                                ) catch |err| {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        mountGraphErrorCode(err),
                                        @errorName(err),
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                defer allocator.free(payload_json);
                                const response = try unified.buildControlAck(allocator, .mount_path_rename, parsed.id, payload_json);
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                            .mount_path_symlink => {
                                const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                const payload_json = handleMountPathControl(
                                    allocator,
                                    runtime_registry,
                                    &namespace_session,
                                    active_binding,
                                    active_session_key,
                                    trustedNamespaceMountUrl(runtime_registry.workspace_url, connection_workspace_url),
                                    principal.role == .access,
                                    parsed.payload_json,
                                    .mount_path_symlink,
                                ) catch |err| {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        mountGraphErrorCode(err),
                                        @errorName(err),
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                defer allocator.free(payload_json);
                                const response = try unified.buildControlAck(allocator, .mount_path_symlink, parsed.id, payload_json);
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                            .mount_path_setxattr => {
                                const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                const payload_json = handleMountPathControl(
                                    allocator,
                                    runtime_registry,
                                    &namespace_session,
                                    active_binding,
                                    active_session_key,
                                    trustedNamespaceMountUrl(runtime_registry.workspace_url, connection_workspace_url),
                                    principal.role == .access,
                                    parsed.payload_json,
                                    .mount_path_setxattr,
                                ) catch |err| {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        mountGraphErrorCode(err),
                                        @errorName(err),
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                defer allocator.free(payload_json);
                                const response = try unified.buildControlAck(allocator, .mount_path_setxattr, parsed.id, payload_json);
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                            .mount_path_getxattr => {
                                const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                const payload_json = handleMountPathControl(
                                    allocator,
                                    runtime_registry,
                                    &namespace_session,
                                    active_binding,
                                    active_session_key,
                                    trustedNamespaceMountUrl(runtime_registry.workspace_url, connection_workspace_url),
                                    principal.role == .access,
                                    parsed.payload_json,
                                    .mount_path_getxattr,
                                ) catch |err| {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        mountGraphErrorCode(err),
                                        @errorName(err),
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                defer allocator.free(payload_json);
                                const response = try unified.buildControlAck(allocator, .mount_path_getxattr, parsed.id, payload_json);
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                            .mount_path_listxattr => {
                                const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                const payload_json = handleMountPathControl(
                                    allocator,
                                    runtime_registry,
                                    &namespace_session,
                                    active_binding,
                                    active_session_key,
                                    trustedNamespaceMountUrl(runtime_registry.workspace_url, connection_workspace_url),
                                    principal.role == .access,
                                    parsed.payload_json,
                                    .mount_path_listxattr,
                                ) catch |err| {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        mountGraphErrorCode(err),
                                        @errorName(err),
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                defer allocator.free(payload_json);
                                const response = try unified.buildControlAck(allocator, .mount_path_listxattr, parsed.id, payload_json);
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                            .mount_path_removexattr => {
                                const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                const payload_json = handleMountPathControl(
                                    allocator,
                                    runtime_registry,
                                    &namespace_session,
                                    active_binding,
                                    active_session_key,
                                    trustedNamespaceMountUrl(runtime_registry.workspace_url, connection_workspace_url),
                                    principal.role == .access,
                                    parsed.payload_json,
                                    .mount_path_removexattr,
                                ) catch |err| {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        mountGraphErrorCode(err),
                                        @errorName(err),
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                defer allocator.free(payload_json);
                                const response = try unified.buildControlAck(allocator, .mount_path_removexattr, parsed.id, payload_json);
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                            .mount_path_lock => {
                                const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                const payload_json = handleMountPathControl(
                                    allocator,
                                    runtime_registry,
                                    &namespace_session,
                                    active_binding,
                                    active_session_key,
                                    trustedNamespaceMountUrl(runtime_registry.workspace_url, connection_workspace_url),
                                    principal.role == .access,
                                    parsed.payload_json,
                                    .mount_path_lock,
                                ) catch |err| {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        mountGraphErrorCode(err),
                                        @errorName(err),
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                defer allocator.free(payload_json);
                                const response = try unified.buildControlAck(allocator, .mount_path_lock, parsed.id, payload_json);
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                            .mount_path_setattr => {
                                const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                const payload_json = handleMountPathControl(
                                    allocator,
                                    runtime_registry,
                                    &namespace_session,
                                    active_binding,
                                    active_session_key,
                                    trustedNamespaceMountUrl(runtime_registry.workspace_url, connection_workspace_url),
                                    principal.role == .access,
                                    parsed.payload_json,
                                    .mount_path_setattr,
                                ) catch |err| {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        mountGraphErrorCode(err),
                                        @errorName(err),
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                defer allocator.free(payload_json);
                                const response = try unified.buildControlAck(allocator, .mount_path_setattr, parsed.id, payload_json);
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                            .session_resume => {
                                const session_resume = try server_session_controls.handleSessionResumeControl(
                                    allocator,
                                    runtime_registry,
                                    &session_bindings,
                                    &active_session_key,
                                    &namespace_session,
                                    principal,
                                    connection_venom_id,
                                    control_service_attached,
                                    connection_workspace_url,
                                    parsed.payload_json,
                                );
                                switch (session_resume) {
                                    .ack => |ack_payload| {
                                        defer allocator.free(ack_payload);
                                        const response = try unified.buildControlAck(
                                            allocator,
                                            .session_resume,
                                            parsed.id,
                                            ack_payload,
                                        );
                                        defer allocator.free(response);
                                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    },
                                    .err => |err_payload| {
                                        const response = try unified.buildControlError(
                                            allocator,
                                            parsed.id,
                                            err_payload.code,
                                            err_payload.message,
                                        );
                                        defer allocator.free(response);
                                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    },
                                }
                                continue;
                            },
                            .session_list => {
                                const payload_json = try server_session_observer_controls.handleSessionListControl(
                                    allocator,
                                    &session_bindings,
                                    active_session_key,
                                );
                                defer allocator.free(payload_json);
                                const response = try unified.buildControlAck(
                                    allocator,
                                    .session_list,
                                    parsed.id,
                                    payload_json,
                                );
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                            .session_restore => {
                                const session_restore = try server_session_observer_controls.handleSessionRestoreControl(
                                    allocator,
                                    runtime_registry,
                                    principal,
                                    parsed.payload_json,
                                );
                                switch (session_restore) {
                                    .ack => |payload_json| {
                                        defer allocator.free(payload_json);
                                        const response = try unified.buildControlAck(
                                            allocator,
                                            .session_restore,
                                            parsed.id,
                                            payload_json,
                                        );
                                        defer allocator.free(response);
                                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    },
                                    .err => |err_payload| {
                                        const response = try unified.buildControlError(
                                            allocator,
                                            parsed.id,
                                            err_payload.code,
                                            err_payload.message,
                                        );
                                        defer allocator.free(response);
                                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    },
                                }
                                continue;
                            },
                            .session_history => {
                                const session_history = try server_session_observer_controls.handleSessionHistoryControl(
                                    allocator,
                                    runtime_registry,
                                    principal,
                                    parsed.payload_json,
                                );
                                switch (session_history) {
                                    .ack => |payload_json| {
                                        defer allocator.free(payload_json);
                                        const response = try unified.buildControlAck(
                                            allocator,
                                            .session_history,
                                            parsed.id,
                                            payload_json,
                                        );
                                        defer allocator.free(response);
                                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    },
                                    .err => |err_payload| {
                                        const response = try unified.buildControlError(
                                            allocator,
                                            parsed.id,
                                            err_payload.code,
                                            err_payload.message,
                                        );
                                        defer allocator.free(response);
                                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    },
                                }
                                continue;
                            },
                            .session_close => {
                                const session_close = try server_session_controls.handleSessionCloseControl(
                                    allocator,
                                    runtime_registry,
                                    &session_bindings,
                                    &active_session_key,
                                    &namespace_session,
                                    principal,
                                    connection_venom_id,
                                    control_service_attached,
                                    parsed.payload_json,
                                );
                                switch (session_close) {
                                    .ack => |ack_payload| {
                                        defer allocator.free(ack_payload);
                                        const response = try unified.buildControlAck(
                                            allocator,
                                            .session_close,
                                            parsed.id,
                                            ack_payload,
                                        );
                                        defer allocator.free(response);
                                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    },
                                    .err => |err_payload| {
                                        const response = try unified.buildControlError(
                                            allocator,
                                            parsed.id,
                                            err_payload.code,
                                            err_payload.message,
                                        );
                                        defer allocator.free(response);
                                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    },
                                }
                                continue;
                            },
                            .node_invite_create,
                            .node_join_request,
                            .node_join_pending_list,
                            .node_join_approve,
                            .node_join_deny,
                            .node_join,
                            .node_ensure,
                            .node_lease_refresh,
                            .venom_bind,
                            .venom_upsert,
                            .venom_get,
                            .node_list,
                            .node_get,
                            .node_delete,
                            .workspace_create,
                            .workspace_update,
                            .workspace_delete,
                            .workspace_list,
                            .workspace_get,
                            .workspace_template_list,
                            .workspace_template_get,
                            .workspace_mount_set,
                            .workspace_mount_remove,
                            .workspace_mount_list,
                            .workspace_bind_set,
                            .workspace_bind_remove,
                            .workspace_bind_list,
                            .workspace_token_rotate,
                            .workspace_token_revoke,
                            .workspace_activate,
                            .workspace_status,
                            .reconcile_status,
                            .workspace_up,
                            .audit_tail,
                            => {
                                const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                const control_agent_id = active_binding.agent_id;
                                const correlation_id = parsed.correlation_id orelse parsed.id;
                                const control_result = try server_control_plane_controls.handleControlPlaneControl(
                                    allocator,
                                    runtime_registry,
                                    control_type,
                                    control_agent_id,
                                    principal.role == .access,
                                    correlation_id,
                                    parsed.payload_json,
                                    connection_workspace_url,
                                );
                                switch (control_result) {
                                    .ack => |ack| {
                                        defer allocator.free(ack.payload_json);
                                        const response = try unified.buildControlAck(
                                            allocator,
                                            control_type,
                                            parsed.id,
                                            ack.payload_json,
                                        );
                                        defer allocator.free(response);
                                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                        if (ack.request_reconcile) {
                                            runtime_registry.control_plane.requestReconcile();
                                        }
                                    },
                                    .err => |err_payload| {
                                    const response = try buildControlErrorWithCorrelation(
                                        allocator,
                                        parsed.id,
                                        correlation_id,
                                        err_payload.code,
                                        err_payload.message,
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    },
                                }
                                continue;
                            },
                            else => {
                                const response = try unified.buildControlError(
                                    allocator,
                                    parsed.id,
                                    "unsupported",
                                    "unsupported control operation",
                                );
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                        }
                    },
                    .acheron => {
                        if (!control_protocol_negotiated) {
                            const response = try unified.buildFsrpcError(
                                allocator,
                                parsed.tag,
                                "protocol_mismatch",
                                "control.version must be negotiated first",
                            );
                            defer allocator.free(response);
                            try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                            try writeFrameLocked(stream, &connection_write_mutex, "", .close);
                            return;
                        }

                        const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                        if (active_binding.project_id == null) {
                            const response = try unified.buildFsrpcError(
                                allocator,
                                parsed.tag,
                                "external_worker_required",
                                "embedded runtime websocket access is removed; call control.session_attach with a workspace_id before using namespace fsrpc",
                            );
                            defer allocator.free(response);
                            try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                            try writeFrameLocked(stream, &connection_write_mutex, "", .close);
                            return;
                        }

                        if (namespace_session == null) {
                            namespace_session = initNamespaceSessionForBinding(
                                allocator,
                                runtime_registry,
                                active_binding,
                                active_session_key,
                                trustedNamespaceMountUrl(runtime_registry.workspace_url, connection_workspace_url),
                                principal.role == .access,
                            ) catch |err| {
                                const response = try unified.buildFsrpcError(
                                    allocator,
                                    parsed.tag,
                                    "execution_failed",
                                    @errorName(err),
                                );
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            };
                        }

                        const response = try namespace_session.?.handle(&parsed);
                        defer allocator.free(response);
                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                        continue;
                    },
                }
            },
            0x8 => {
                try writeFrameLocked(stream, &connection_write_mutex, "", .close);
                return;
            },
            0x9 => {
                try writeFrameLocked(stream, &connection_write_mutex, frame.payload, .pong);
            },
            0xA => {},
            else => {},
        }
    }
}

fn optionalStringsEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.mem.eql(u8, left.?, right.?);
}

fn validateControlVersionPayload(allocator: std.mem.Allocator, payload_json: ?[]const u8) !void {
    return server_protocol_validation.validateControlVersionPayload(
        allocator,
        payload_json,
        control_protocol_version,
    );
}

fn isControlAdminOnly(control_type: unified.ControlType) bool {
    return switch (control_type) {
        .metrics,
        .auth_status,
        .auth_rotate,
        .node_invite_create,
        .node_join_pending_list,
        .node_join_approve,
        .node_join_deny,
        .node_join,
        .node_ensure,
        .node_lease_refresh,
        .venom_bind,
        .venom_upsert,
        .venom_get,
        .node_list,
        .node_get,
        .node_delete,
        .audit_tail,
        => true,
        else => false,
    };
}

fn sendWebSocketErrorAndClose(
    allocator: std.mem.Allocator,
    stream: *std.net.Stream,
    code: protocol.ErrorCode,
    message: []const u8,
) !void {
    const payload = try protocol.buildErrorWithCode(allocator, "unknown", code, message);
    defer allocator.free(payload);
    try websocket_transport.writeFrame(stream, payload, .text);
    try websocket_transport.writeFrame(stream, "", .close);
}

const FsNodeHelloOptions = server_protocol_validation.FsNodeHelloOptions;

fn validateFsNodeHelloPayloadWithAcceptedTokens(
    allocator: std.mem.Allocator,
    payload_json: ?[]const u8,
    accepted_auth_tokens: ?[]const []const u8,
) !FsNodeHelloOptions {
    return server_protocol_validation.validateFsNodeHelloPayloadWithAcceptedTokens(
        allocator,
        payload_json,
        accepted_auth_tokens,
        acheron_node_protocol_version,
        acheron_node_proto_id,
    );
}

fn validateFsNodeHelloPayload(
    allocator: std.mem.Allocator,
    payload_json: ?[]const u8,
    required_auth_token: ?[]const u8,
) !FsNodeHelloOptions {
    return server_protocol_validation.validateFsNodeHelloPayload(
        allocator,
        payload_json,
        required_auth_token,
        acheron_node_protocol_version,
        acheron_node_proto_id,
    );
}

fn writeFrameLocked(
    stream: *std.net.Stream,
    write_mutex: *std.Thread.Mutex,
    payload: []const u8,
    frame_type: websocket_transport.FrameType,
) !void {
    write_mutex.lock();
    defer write_mutex.unlock();
    try websocket_transport.writeFrame(stream, payload, frame_type);
}

fn isWorkspaceTopologyMutation(control_type: unified.ControlType) bool {
    return switch (control_type) {
        .node_join_request,
        .node_join_approve,
        .node_join_deny,
        .node_join,
        .node_ensure,
        .node_delete,
        .workspace_create,
        .workspace_update,
        .workspace_delete,
        .workspace_bind_set,
        .workspace_bind_remove,
        .workspace_mount_set,
        .workspace_mount_remove,
        .workspace_activate,
        .workspace_up,
        => true,
        else => false,
    };
}

fn buildControlErrorWithCorrelation(
    allocator: std.mem.Allocator,
    id: ?[]const u8,
    correlation_id: ?[]const u8,
    code: []const u8,
    message: []const u8,
) ![]u8 {
    const escaped_code = try unified.jsonEscape(allocator, code);
    defer allocator.free(escaped_code);
    const escaped_message = try unified.jsonEscape(allocator, message);
    defer allocator.free(escaped_message);

    const correlation_json = if (correlation_id) |value| blk: {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(correlation_json);

    if (id) |request_id| {
        const escaped_id = try unified.jsonEscape(allocator, request_id);
        defer allocator.free(escaped_id);
        return std.fmt.allocPrint(
            allocator,
            "{{\"channel\":\"control\",\"type\":\"control.error\",\"id\":\"{s}\",\"ok\":false,\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\",\"correlation_id\":{s}}}}}",
            .{ escaped_id, escaped_code, escaped_message, correlation_json },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"control\",\"type\":\"control.error\",\"ok\":false,\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\",\"correlation_id\":{s}}}}}",
        .{ escaped_code, escaped_message, correlation_json },
    );
}

fn mountGraphErrorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "enoent",
        error.AccessDenied => "eacces",
        error.InvalidPayload => "einval",
        error.InvalidOffset => "einval",
        error.InvalidArgument => "einval",
        error.PathAlreadyExists,
        error.AlreadyExists,
        => "eexist",
        error.NotDir => "enotdir",
        error.IsDir => "eisdir",
        error.ReadOnlyFileSystem => "erofs",
        error.NoData => "enodata",
        error.WouldBlock => "eagain",
        error.Range => "erange",
        error.OperationNotSupported => "enosys",
        else => "eio",
    };
}

fn resolveAgentIdFromConnectionPath(path: []const u8, default_agent_id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, path, "/") or std.mem.startsWith(u8, path, "/?")) {
        return default_agent_id;
    }
    return null;
}

fn sendServiceUnavailable(stream: *std.net.Stream) !void {
    const payload =
        "HTTP/1.1 503 Service Unavailable\r\n" ++
        "Connection: close\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n";
    try stream.writeAll(payload);
}

const WsTestServerCtx = struct {
    allocator: std.mem.Allocator,
    runtime_registry: *AgentRuntimeRegistry,
    listener: *std.net.Server,
    err_name: ?[]u8 = null,

    fn deinit(self: *WsTestServerCtx) void {
        if (self.err_name) |name| self.allocator.free(name);
    }
};

fn runSingleWsConnection(ctx: *WsTestServerCtx) void {
    var connection = ctx.listener.accept() catch |err| {
        ctx.err_name = std.fmt.allocPrint(ctx.allocator, "{s}", .{@errorName(err)}) catch null;
        return;
    };
    defer connection.stream.close();

    handleWebSocketConnection(ctx.allocator, ctx.runtime_registry, &connection.stream) catch |err| {
        ctx.err_name = std.fmt.allocPrint(ctx.allocator, "{s}", .{@errorName(err)}) catch null;
    };
}

fn setAuthTokensForTests(
    runtime_registry: *AgentRuntimeRegistry,
    access_token: []const u8,
) !void {
    const allocator = runtime_registry.allocator;
    allocator.free(runtime_registry.auth_tokens.access_token);
    if (runtime_registry.auth_tokens.access_last_target) |*target| target.deinit(allocator);
    for (runtime_registry.auth_tokens.access_session_history.items) |*entry| entry.deinit(allocator);
    runtime_registry.auth_tokens.access_session_history.deinit(allocator);
    runtime_registry.auth_tokens.access_token = try allocator.dupe(u8, access_token);
    runtime_registry.auth_tokens.access_last_target = null;
    runtime_registry.auth_tokens.access_session_history = .{};
}

fn seedRememberedTargetForTests(
    runtime_registry: *AgentRuntimeRegistry,
    agent_id: []const u8,
) !void {
    const allocator = runtime_registry.allocator;
    const project_up = try runtime_registry.control_plane.projectUp(
        agent_id,
        "{\"name\":\"Access Seed Project\",\"vision\":\"Access Seed Project\",\"activate\":true}",
    );
    defer allocator.free(project_up);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, project_up, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.TestExpectedResult;
    const project_id_value = parsed.value.object.get("project_id") orelse return error.TestExpectedResult;
    if (project_id_value != .string) return error.TestExpectedResult;

    try runtime_registry.auth_tokens.setRememberedTarget(.access, agent_id, project_id_value.string);
}

test "server: workspace template control ops expose dev catalog entries" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();

    const listed = try server_control_plane_controls.handleControlPlaneCommand(
        &runtime_registry,
        .workspace_template_list,
        host_actor_id,
        true,
        null,
        null,
    );
    defer allocator.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"template_id\":\"minimum\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"template_id\":\"dev\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"template_id\":\"github\"") == null);

    const fetched = try server_control_plane_controls.handleControlPlaneCommand(
        &runtime_registry,
        .workspace_template_get,
        host_actor_id,
        true,
        "{\"template_id\":\"dev\"}",
        null,
    );
    defer allocator.free(fetched);
    try std.testing.expect(std.mem.indexOf(u8, fetched, "\"template_id\":\"dev\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetched, "\"bind_path\":\"/services/git\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetched, "\"bind_path\":\"/services/search_code\"") != null);
}

test "server: workspace bind control ops rewrite workspace payload and response fields" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();

    const project_json = try runtime_registry.control_plane.createProject(
        "{\"name\":\"WorkspaceBind\",\"vision\":\"WorkspaceBind\"}",
    );
    defer allocator.free(project_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.TestExpectedResult;
    const project_id_value = parsed.value.object.get("project_id") orelse return error.TestExpectedResult;
    const project_token_value = parsed.value.object.get("project_token") orelse return error.TestExpectedResult;
    if (project_id_value != .string or project_token_value != .string) return error.TestExpectedResult;

    const bind_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"bind_path\":\"/repo\",\"target_path\":\"/nodes/local/fs\"}}",
        .{ project_id_value.string, project_token_value.string },
    );
    defer allocator.free(bind_req);
    const bound = try server_control_plane_controls.handleControlPlaneCommand(
        &runtime_registry,
        .workspace_bind_set,
        host_actor_id,
        false,
        bind_req,
        null,
    );
    defer allocator.free(bound);
    try std.testing.expect(std.mem.indexOf(u8, bound, "\"workspace_id\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bound, "\"project_id\":\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, bound, "\"bind_path\":\"/repo\"") != null);

    const list_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\"}}",
        .{ project_id_value.string, project_token_value.string },
    );
    defer allocator.free(list_req);
    const listed = try server_control_plane_controls.handleControlPlaneCommand(
        &runtime_registry,
        .workspace_bind_list,
        host_actor_id,
        false,
        list_req,
        null,
    );
    defer allocator.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"workspace_id\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"project_id\":\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"target_path\":\"/nodes/local/fs\"") != null);

    const remove_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"bind_path\":\"/repo\"}}",
        .{ project_id_value.string, project_token_value.string },
    );
    defer allocator.free(remove_req);
    const removed = try server_control_plane_controls.handleControlPlaneCommand(
        &runtime_registry,
        .workspace_bind_remove,
        host_actor_id,
        false,
        remove_req,
        null,
    );
    defer allocator.free(removed);
    try std.testing.expect(std.mem.indexOf(u8, removed, "\"workspace_id\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, removed, "\"project_id\":\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, removed, "\"bind_path\":\"/repo\"") == null);
}

test "server: admin initial binding prefers remembered workspace target" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();
    try setAuthTokensForTests(&runtime_registry, "access-secret");

    const project_up = try runtime_registry.control_plane.projectUpWithRole(
        host_actor_id,
        "{\"name\":\"Admin Remembered\",\"vision\":\"Remembered target test\",\"activate\":false}",
        true,
    );
    defer allocator.free(project_up);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, project_up, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.TestExpectedResult;
    const project_id_value = parsed.value.object.get("project_id") orelse return error.TestExpectedResult;
    if (project_id_value != .string or project_id_value.string.len == 0) return error.TestExpectedResult;

    try runtime_registry.auth_tokens.setRememberedTarget(.access, "roger", project_id_value.string);

    const initial = try runtime_registry.buildInitialSessionBinding(.access);
    defer {
        var owned = initial.binding;
        owned.deinit(allocator);
    }
    try std.testing.expectEqualStrings("roger", initial.binding.agent_id);
    try std.testing.expect(initial.binding.project_id != null);
    try std.testing.expectEqualStrings(project_id_value.string, initial.binding.project_id.?);
}

fn readHttpHeadersAlloc(allocator: std.mem.Allocator, stream: *std.net.Stream, max_bytes: usize) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    var buf: [1024]u8 = undefined;
    while (out.items.len < max_bytes) {
        const read_n = try stream.read(&buf);
        if (read_n == 0) return error.EndOfStream;
        try out.appendSlice(allocator, buf[0..read_n]);
        if (std.mem.indexOf(u8, out.items, "\r\n\r\n") != null) {
            return out.toOwnedSlice(allocator);
        }
    }

    return error.HeaderTooLarge;
}

fn writeClientTextFrameMasked(stream: *std.net.Stream, payload: []const u8) !void {
    var header: [10]u8 = undefined;
    var header_len: usize = 2;
    header[0] = 0x81;

    if (payload.len < 126) {
        header[1] = 0x80 | @as(u8, @intCast(payload.len));
    } else if (payload.len < 65536) {
        header[1] = 0x80 | 126;
        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        header_len = 4;
    } else {
        header[1] = 0x80 | 127;
        std.mem.writeInt(u64, header[2..10], payload.len, .big);
        header_len = 10;
    }

    const mask_key = [4]u8{ 0x11, 0x22, 0x33, 0x44 };
    try stream.writeAll(header[0..header_len]);
    try stream.writeAll(&mask_key);

    const masked_payload = try std.heap.page_allocator.alloc(u8, payload.len);
    defer std.heap.page_allocator.free(masked_payload);
    for (payload, 0..) |byte, idx| {
        masked_payload[idx] = byte ^ mask_key[idx % 4];
    }
    try stream.writeAll(masked_payload);
}

const TestServerFrame = struct {
    opcode: u8,
    payload: []u8,

    fn deinit(self: *TestServerFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
    }
};

fn readServerFrame(allocator: std.mem.Allocator, stream: *std.net.Stream) !TestServerFrame {
    var header: [2]u8 = undefined;
    try readExactFromStream(stream, &header);

    const fin = (header[0] & 0x80) != 0;
    if (!fin) return error.UnsupportedFragmentation;

    const opcode = header[0] & 0x0F;
    const masked = (header[1] & 0x80) != 0;
    if (masked) return error.UnexpectedMaskedServerFrame;

    var payload_len: usize = header[1] & 0x7F;
    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        try readExactFromStream(stream, &ext);
        payload_len = std.mem.readInt(u16, &ext, .big);
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        try readExactFromStream(stream, &ext);
        payload_len = @intCast(std.mem.readInt(u64, &ext, .big));
    }

    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    if (payload_len > 0) {
        try readExactFromStream(stream, payload);
    }

    return .{ .opcode = opcode, .payload = payload };
}

fn readExactFromStream(stream: *std.net.Stream, out: []u8) !void {
    var read_total: usize = 0;
    while (read_total < out.len) {
        const read_n = try stream.read(out[read_total..]);
        if (read_n == 0) return error.EndOfStream;
        read_total += read_n;
    }
}

fn performClientHandshake(
    allocator: std.mem.Allocator,
    client: *std.net.Stream,
    path: []const u8,
) !void {
    try performClientHandshakeWithAuthorization(allocator, client, path, null);
}

fn performClientHandshakeWithBearerToken(
    allocator: std.mem.Allocator,
    client: *std.net.Stream,
    path: []const u8,
    token: []const u8,
) !void {
    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header);
    try performClientHandshakeWithAuthorization(allocator, client, path, auth_header);
}

fn performClientHandshakeWithAuthorization(
    allocator: std.mem.Allocator,
    client: *std.net.Stream,
    path: []const u8,
    authorization: ?[]const u8,
) !void {
    const auth_line = if (authorization) |value|
        try std.fmt.allocPrint(allocator, "Authorization: {s}\r\n", .{value})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(auth_line);

    const handshake = try std.fmt.allocPrint(
        allocator,
        "GET {s} HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "{s}" ++
            "\r\n",
        .{ path, auth_line },
    );
    defer allocator.free(handshake);
    try client.writeAll(handshake);

    const handshake_response = try readHttpHeadersAlloc(allocator, client, 16 * 1024);
    defer allocator.free(handshake_response);
    try std.testing.expect(std.mem.indexOf(u8, handshake_response, "101 Switching Protocols") != null);
}

fn fsrpcConnectAndAttach(allocator: std.mem.Allocator, client: *std.net.Stream, connect_id: []const u8) !void {
    try writeClientTextFrameMasked(client, "{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"version\",\"payload\":{\"protocol\":\"spiderweb-control\"}}");
    var version_ack = try readServerFrame(allocator, client);
    defer version_ack.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0x1), version_ack.opcode);
    try std.testing.expect(std.mem.indexOf(u8, version_ack.payload, "\"type\":\"control.version_ack\"") != null);

    const connect_req = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"{s}\"}}",
        .{connect_id},
    );
    defer allocator.free(connect_req);
    try writeClientTextFrameMasked(client, connect_req);

    var connect_ack = try readServerFrame(allocator, client);
    defer connect_ack.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0x1), connect_ack.opcode);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"type\":\"control.connect_ack\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"ok\":true") != null);
}

fn expectLegacyAcheronRejected(allocator: std.mem.Allocator, client: *std.net.Stream) !void {
    try writeClientTextFrameMasked(client, "{\"channel\":\"acheron\",\"type\":\"acheron.t_version\",\"tag\":1,\"msize\":1048576,\"version\":\"acheron-1\"}");
    var rejection = try readServerFrame(allocator, client);
    defer rejection.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, rejection.payload, "\"type\":\"acheron.r_error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rejection.payload, "\"code\":\"external_worker_required\"") != null);

    var close_reply = try readServerFrame(allocator, client);
    defer close_reply.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0x8), close_reply.opcode);
}

const WorkspaceScopeSnapshot = struct {
    workspace_id: []u8,
    workspace_root: []u8,
    mount_paths: std.ArrayListUnmanaged([]u8) = .{},

    fn deinit(self: *WorkspaceScopeSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        allocator.free(self.workspace_root);
        for (self.mount_paths.items) |path| allocator.free(path);
        self.mount_paths.deinit(allocator);
        self.* = undefined;
    }
};

fn parseWorkspaceScopeSnapshotFromControlFrame(
    allocator: std.mem.Allocator,
    frame_payload: []const u8,
) !WorkspaceScopeSnapshot {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, frame_payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.TestExpectedResponse;

    const payload = parsed.value.object.get("payload") orelse return error.TestExpectedResponse;
    if (payload != .object) return error.TestExpectedResponse;

    const workspace_id_value = payload.object.get("workspace_id") orelse return error.TestExpectedResponse;
    if (workspace_id_value != .string or workspace_id_value.string.len == 0) return error.TestExpectedResponse;

    const workspace_value = payload.object.get("workspace") orelse return error.TestExpectedResponse;
    if (workspace_value != .object) return error.TestExpectedResponse;

    const workspace_root_value = workspace_value.object.get("workspace_root") orelse return error.TestExpectedResponse;
    if (workspace_root_value != .string or workspace_root_value.string.len == 0) return error.TestExpectedResponse;

    var snapshot = WorkspaceScopeSnapshot{
        .workspace_id = try allocator.dupe(u8, workspace_id_value.string),
        .workspace_root = try allocator.dupe(u8, workspace_root_value.string),
    };
    errdefer snapshot.deinit(allocator);

    const mounts_value = workspace_value.object.get("mounts") orelse return error.TestExpectedResponse;
    if (mounts_value != .array) return error.TestExpectedResponse;
    for (mounts_value.array.items) |mount_item| {
        if (mount_item != .object) continue;
        const mount_path = mount_item.object.get("mount_path") orelse continue;
        if (mount_path != .string or mount_path.string.len == 0) continue;
        try snapshot.mount_paths.append(allocator, try allocator.dupe(u8, mount_path.string));
    }
    std.mem.sort([]u8, snapshot.mount_paths.items, {}, struct {
        fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    return snapshot;
}

fn extractInternalProjectIdForTests(allocator: std.mem.Allocator, payload_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.TestExpectedResult;
    const project_id_value = parsed.value.object.get("project_id") orelse return error.TestExpectedResult;
    if (project_id_value != .string or project_id_value.string.len == 0) return error.TestExpectedResult;
    return allocator.dupe(u8, project_id_value.string);
}

fn expectWorkspaceScopeSnapshotsEqual(
    lhs: *const WorkspaceScopeSnapshot,
    rhs: *const WorkspaceScopeSnapshot,
) !void {
    try std.testing.expectEqualStrings(lhs.project_id, rhs.project_id);
    try std.testing.expectEqualStrings(lhs.workspace_root, rhs.workspace_root);
    try std.testing.expectEqual(lhs.mount_paths.items.len, rhs.mount_paths.items.len);
    for (lhs.mount_paths.items, rhs.mount_paths.items) |left_path, right_path| {
        try std.testing.expectEqualStrings(left_path, right_path);
    }
}

test "server: base websocket path handles unified control and rejects legacy runtime channels" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();
    try setAuthTokensForTests(&runtime_registry, "access-secret");
    try seedRememberedTargetForTests(&runtime_registry, "user-auth");

    var listener = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true });
    defer listener.deinit();

    var server_ctx = WsTestServerCtx{
        .allocator = allocator,
        .runtime_registry = &runtime_registry,
        .listener = &listener,
    };
    defer server_ctx.deinit();

    const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
    defer server_thread.join();

    var client = try std.net.tcpConnectToAddress(listener.listen_address);
    defer client.close();

    try performClientHandshakeWithBearerToken(allocator, &client, "/", "access-secret");

    try fsrpcConnectAndAttach(allocator, &client, "req-connect");

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.ping\",\"id\":\"req-ping\"}");
    var pong = try readServerFrame(allocator, &client);
    defer pong.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, pong.payload, "\"type\":\"control.pong\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pong.payload, "\"payload\":{}") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.metrics\",\"id\":\"req-metrics\"}");
    var metrics = try readServerFrame(allocator, &client);
    defer metrics.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, metrics.payload, "\"type\":\"control.metrics\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, metrics.payload, "\"nodes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, metrics.payload, "\"projects\"") != null);
    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.debug_subscribe\",\"id\":\"req-debug-sub\"}");
    var debug_sub = try readServerFrame(allocator, &client);
    defer debug_sub.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, debug_sub.payload, "\"type\":\"control.error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, debug_sub.payload, "\"code\":\"unsupported_legacy_api\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.debug_unsubscribe\",\"id\":\"req-debug-unsub\"}");
    var debug_unsub = try readServerFrame(allocator, &client);
    defer debug_unsub.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, debug_unsub.payload, "\"type\":\"control.error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, debug_unsub.payload, "\"code\":\"unsupported_legacy_api\"") != null);

    try writeClientTextFrameMasked(&client, "{\"id\":\"req-chat\",\"type\":\"session.send\",\"content\":\"legacy\"}");
    var legacy_reply = try readServerFrame(allocator, &client);
    defer legacy_reply.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0x1), legacy_reply.opcode);
    try std.testing.expect(std.mem.indexOf(u8, legacy_reply.payload, "\"type\":\"control.error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, legacy_reply.payload, "\"code\":\"unsupported_legacy_api\"") != null);

    try expectLegacyAcheronRejected(allocator, &client);

    try std.testing.expect(server_ctx.err_name == null);
}

test "server: workspace namespace stays project-scoped across user session agent switches" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();
    try setAuthTokensForTests(&runtime_registry, "access-secret");

    const project_up = try runtime_registry.control_plane.projectUpWithRole(
        host_actor_id,
        "{\"name\":\"Scope Test\",\"vision\":\"Project-scoped namespace\",\"activate\":false}",
        true,
    );
    defer allocator.free(project_up);

    const project_id = try extractInternalProjectIdForTests(allocator, project_up);
    defer allocator.free(project_id);

    try runtime_registry.auth_tokens.setRememberedTarget(.access, "alice", project_id);

    var listener = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true });
    defer listener.deinit();

    var server_ctx = WsTestServerCtx{
        .allocator = allocator,
        .runtime_registry = &runtime_registry,
        .listener = &listener,
    };
    defer server_ctx.deinit();

    const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
    defer server_thread.join();

    var client = try std.net.tcpConnectToAddress(listener.listen_address);
    defer client.close();
    try performClientHandshakeWithBearerToken(allocator, &client, "/", "access-secret");

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"scope-version\",\"payload\":{\"protocol\":\"spiderweb-control\"}}");
    var version_ack = try readServerFrame(allocator, &client);
    defer version_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, version_ack.payload, "\"type\":\"control.version_ack\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"scope-connect\"}");
    var connect_ack = try readServerFrame(allocator, &client);
    defer connect_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"type\":\"control.connect_ack\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, project_id) != null);

    const attach_alice = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"control\",\"type\":\"control.session_attach\",\"id\":\"scope-attach-alice\",\"payload\":{{\"session_key\":\"scope-a\",\"agent_id\":\"alice\",\"workspace_id\":\"{s}\"}}}}",
        .{project_id},
    );
    defer allocator.free(attach_alice);
    try writeClientTextFrameMasked(&client, attach_alice);
    var attach_alice_ack = try readServerFrame(allocator, &client);
    defer attach_alice_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, attach_alice_ack.payload, "\"type\":\"control.session_attach\"") != null);
    var alice_scope = try parseWorkspaceScopeSnapshotFromControlFrame(allocator, attach_alice_ack.payload);
    defer alice_scope.deinit(allocator);

    const attach_bob = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"control\",\"type\":\"control.session_attach\",\"id\":\"scope-attach-bob\",\"payload\":{{\"session_key\":\"scope-b\",\"agent_id\":\"bob\",\"workspace_id\":\"{s}\"}}}}",
        .{project_id},
    );
    defer allocator.free(attach_bob);
    try writeClientTextFrameMasked(&client, attach_bob);
    var attach_bob_ack = try readServerFrame(allocator, &client);
    defer attach_bob_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, attach_bob_ack.payload, "\"type\":\"control.session_attach\"") != null);
    var bob_scope = try parseWorkspaceScopeSnapshotFromControlFrame(allocator, attach_bob_ack.payload);
    defer bob_scope.deinit(allocator);

    try expectWorkspaceScopeSnapshotsEqual(&alice_scope, &bob_scope);
    try std.testing.expect(std.mem.indexOf(u8, attach_alice_ack.payload, "\"mount_path\":\"/nodes/local/fs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, attach_bob_ack.payload, "\"mount_path\":\"/nodes/local/fs\"") != null);

    try writeClientTextFrameMasked(
        &client,
        "{\"channel\":\"control\",\"type\":\"control.session_history\",\"id\":\"scope-history\",\"payload\":{\"limit\":5}}",
    );
    var history = try readServerFrame(allocator, &client);
    defer history.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, history.payload, "\"type\":\"control.session_history\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, history.payload, "\"session_key\":\"scope-a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, history.payload, "\"session_key\":\"scope-b\"") != null);

    try websocket_transport.writeFrame(&client, "", .close);
    var close_reply = try readServerFrame(allocator, &client);
    defer close_reply.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0x8), close_reply.opcode);

    try std.testing.expect(server_ctx.err_name == null);
}

test "server: operator token gate protects control mutations" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();
    try setAuthTokensForTests(&runtime_registry, "access-secret");
    if (runtime_registry.control_operator_token) |token| {
        allocator.free(token);
    }
    runtime_registry.control_operator_token = try allocator.dupe(u8, "operator-secret");

    var listener = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true });
    defer listener.deinit();

    var server_ctx = WsTestServerCtx{
        .allocator = allocator,
        .runtime_registry = &runtime_registry,
        .listener = &listener,
    };
    defer server_ctx.deinit();

    const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
    defer server_thread.join();

    var client = try std.net.tcpConnectToAddress(listener.listen_address);
    defer client.close();
    try performClientHandshakeWithBearerToken(allocator, &client, "/", "access-secret");

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"v1\",\"payload\":{\"protocol\":\"spiderweb-control\"}}");
    var version_ack = try readServerFrame(allocator, &client);
    defer version_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, version_ack.payload, "\"type\":\"control.version_ack\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"c1\"}");
    var connect_ack = try readServerFrame(allocator, &client);
    defer connect_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"type\":\"control.connect_ack\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.workspace_create\",\"id\":\"p-missing\",\"payload\":{\"name\":\"NoToken\",\"vision\":\"NoToken\"}}");
    var missing_token = try readServerFrame(allocator, &client);
    defer missing_token.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, missing_token.payload, "\"type\":\"control.error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing_token.payload, "\"code\":\"missing_field\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.workspace_create\",\"id\":\"p-bad\",\"payload\":{\"name\":\"BadToken\",\"vision\":\"BadToken\",\"operator_token\":\"wrong\"}}");
    var bad_token = try readServerFrame(allocator, &client);
    defer bad_token.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, bad_token.payload, "\"type\":\"control.error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_token.payload, "\"code\":\"operator_auth_failed\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.workspace_create\",\"id\":\"p-good\",\"payload\":{\"name\":\"GoodToken\",\"vision\":\"GoodToken\",\"operator_token\":\"operator-secret\"}}");
    var good = try readServerFrame(allocator, &client);
    defer good.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, good.payload, "\"type\":\"control.workspace_create\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, good.payload, "\"workspace_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, good.payload, "\"workspace_token\"") != null);

    try websocket_transport.writeFrame(&client, "", .close);
    var close_reply = try readServerFrame(allocator, &client);
    defer close_reply.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0x8), close_reply.opcode);

    try std.testing.expect(server_ctx.err_name == null);
}

test "server: base websocket rejects legacy acheron runtime session" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();
    try setAuthTokensForTests(&runtime_registry, "access-secret");

    var listener = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true });
    defer listener.deinit();

    var server_ctx = WsTestServerCtx{
        .allocator = allocator,
        .runtime_registry = &runtime_registry,
        .listener = &listener,
    };
    defer server_ctx.deinit();

    const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
    defer server_thread.join();

    var client = try std.net.tcpConnectToAddress(listener.listen_address);
    defer client.close();

    try performClientHandshakeWithBearerToken(allocator, &client, "/", "access-secret");
    try fsrpcConnectAndAttach(allocator, &client, "fid-survive");
    try expectLegacyAcheronRejected(allocator, &client);

    try std.testing.expect(server_ctx.err_name == null);
}

test "server: base websocket supports namespace attach after session_attach" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();
    try setAuthTokensForTests(&runtime_registry, "access-secret");

    const join_payload = try runtime_registry.control_plane.ensureNode("node-a", "ws://127.0.0.1:18891/fs", 60_000);
    defer allocator.free(join_payload);
    const node_registration = try parseNodeRegistrationFromJoinPayload(allocator, join_payload);
    defer {
        allocator.free(node_registration.node_id);
        allocator.free(node_registration.node_secret);
    }

    const project_created = try runtime_registry.control_plane.createProject(
        "{\"name\":\"NamespaceAttach\",\"vision\":\"NamespaceAttach\"}",
    );
    defer allocator.free(project_created);
    const project_id = try extractInternalProjectIdForTests(allocator, project_created);
    defer allocator.free(project_id);

    const mount_payload = try std.fmt.allocPrint(
        allocator,
        "{{\"project_id\":\"{s}\",\"mount_path\":\"/nodes/{s}/fs\",\"node_id\":\"{s}\",\"export_name\":\"fs\"}}",
        .{ project_id, node_registration.node_id, node_registration.node_id },
    );
    defer allocator.free(mount_payload);
    const mount_result = try runtime_registry.control_plane.setProjectMountWithRole(mount_payload, true);
    defer allocator.free(mount_result);

    var listener = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true });
    defer listener.deinit();

    var server_ctx = WsTestServerCtx{
        .allocator = allocator,
        .runtime_registry = &runtime_registry,
        .listener = &listener,
    };
    defer server_ctx.deinit();

    const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
    defer server_thread.join();

    var client = try std.net.tcpConnectToAddress(listener.listen_address);
    defer client.close();

    try performClientHandshakeWithBearerToken(allocator, &client, "/", "access-secret");
    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"version\",\"payload\":{\"protocol\":\"spiderweb-control\"}}");
    var version_ack = try readServerFrame(allocator, &client);
    defer version_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, version_ack.payload, "\"type\":\"control.version_ack\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"connect\"}");
    var connect_ack = try readServerFrame(allocator, &client);
    defer connect_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"type\":\"control.connect_ack\"") != null);

    const attach_payload = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"control\",\"type\":\"control.session_attach\",\"id\":\"attach\",\"payload\":{{\"session_key\":\"main\",\"agent_id\":\"test-agent\",\"workspace_id\":\"{s}\"}}}}",
        .{project_id},
    );
    defer allocator.free(attach_payload);
    try writeClientTextFrameMasked(&client, attach_payload);
    var attach_ack = try readServerFrame(allocator, &client);
    defer attach_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, attach_ack.payload, "\"type\":\"control.session_attach\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, attach_ack.payload, "\"state\":\"ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, attach_ack.payload, "\"runtime_ready\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, attach_ack.payload, "\"mount_ready\":true") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"acheron\",\"type\":\"acheron.t_version\",\"tag\":1,\"msize\":1048576,\"version\":\"acheron-1\"}");
    var acheron_version = try readServerFrame(allocator, &client);
    defer acheron_version.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, acheron_version.payload, "\"type\":\"acheron.r_version\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"acheron\",\"type\":\"acheron.t_attach\",\"tag\":2,\"fid\":1}");
    var acheron_attach = try readServerFrame(allocator, &client);
    defer acheron_attach.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, acheron_attach.payload, "\"type\":\"acheron.r_attach\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"acheron\",\"type\":\"acheron.t_walk\",\"tag\":3,\"fid\":1,\"newfid\":2,\"path\":[\"services\"]}");
    var acheron_walk = try readServerFrame(allocator, &client);
    defer acheron_walk.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, acheron_walk.payload, "\"type\":\"acheron.r_walk\"") != null);

    try websocket_transport.writeFrame(&client, "", .close);
    var close_reply = try readServerFrame(allocator, &client);
    defer close_reply.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0x8), close_reply.opcode);

    try std.testing.expect(server_ctx.err_name == null);
}

test "server: auth matrix gates admin endpoints and handshake tokens" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();
    try setAuthTokensForTests(&runtime_registry, "access-secret");

    var listener = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true });
    defer listener.deinit();

    var server_ctx = WsTestServerCtx{
        .allocator = allocator,
        .runtime_registry = &runtime_registry,
        .listener = &listener,
    };
    defer server_ctx.deinit();

    {
        const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
        defer server_thread.join();

        var admin_client = try std.net.tcpConnectToAddress(listener.listen_address);
        defer admin_client.close();
        try performClientHandshakeWithBearerToken(allocator, &admin_client, "/", "access-secret");

        try writeClientTextFrameMasked(&admin_client, "{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"admin-version\",\"payload\":{\"protocol\":\"spiderweb-control\"}}");
        var version_ack = try readServerFrame(allocator, &admin_client);
        defer version_ack.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, version_ack.payload, "\"type\":\"control.version_ack\"") != null);

        try writeClientTextFrameMasked(&admin_client, "{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"admin-connect\"}");
        var connect_ack = try readServerFrame(allocator, &admin_client);
        defer connect_ack.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"type\":\"control.connect_ack\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"protocol\":\"spiderweb-control\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"workspace\":{") != null);
        try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"role\":") == null);
        try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"project_setup_required\":") == null);

        try writeClientTextFrameMasked(&admin_client, "{\"channel\":\"control\",\"type\":\"control.auth_status\",\"id\":\"admin-auth-status\"}");
        var auth_status = try readServerFrame(allocator, &admin_client);
        defer auth_status.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, auth_status.payload, "\"type\":\"control.auth_status\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, auth_status.payload, "\"access_token\":\"access-secret\"") != null);

        try writeClientTextFrameMasked(&admin_client, "{\"channel\":\"control\",\"type\":\"control.auth_rotate\",\"id\":\"admin-auth-rotate\",\"payload\":{}}");
        var auth_rotate = try readServerFrame(allocator, &admin_client);
        defer auth_rotate.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, auth_rotate.payload, "\"type\":\"control.auth_rotate\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, auth_rotate.payload, "\"access_token\":\"") != null);

        try writeClientTextFrameMasked(
            &admin_client,
            "{\"channel\":\"control\",\"type\":\"control.audit_tail\",\"id\":\"admin-audit\",\"payload\":{\"limit\":10}}",
        );
        var admin_audit = try readServerFrame(allocator, &admin_client);
        defer admin_audit.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, admin_audit.payload, "\"type\":\"control.audit_tail\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, admin_audit.payload, "\"control_type\":\"control.auth_rotate\"") != null);

        try websocket_transport.writeFrame(&admin_client, "", .close);
        var close_reply = try readServerFrame(allocator, &admin_client);
        defer close_reply.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 0x8), close_reply.opcode);
    }

    {
        const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
        defer server_thread.join();

        var user_client = try std.net.tcpConnectToAddress(listener.listen_address);
        defer user_client.close();
        try performClientHandshakeWithBearerToken(allocator, &user_client, "/", "access-secret");

        try writeClientTextFrameMasked(&user_client, "{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"user-version\",\"payload\":{\"protocol\":\"spiderweb-control\"}}");
        var version_ack = try readServerFrame(allocator, &user_client);
        defer version_ack.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, version_ack.payload, "\"type\":\"control.version_ack\"") != null);

        try writeClientTextFrameMasked(&user_client, "{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"user-connect\"}");
        var connect_ack = try readServerFrame(allocator, &user_client);
        defer connect_ack.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"type\":\"control.connect_ack\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"role\":") == null);

        try writeClientTextFrameMasked(&user_client, "{\"channel\":\"control\",\"type\":\"control.metrics\",\"id\":\"user-metrics\"}");
        var metrics = try readServerFrame(allocator, &user_client);
        defer metrics.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, metrics.payload, "\"type\":\"control.metrics\"") != null);

        try writeClientTextFrameMasked(&user_client, "{\"channel\":\"control\",\"type\":\"control.auth_status\",\"id\":\"user-auth-status\"}");
        var access_status = try readServerFrame(allocator, &user_client);
        defer access_status.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, access_status.payload, "\"type\":\"control.auth_status\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, access_status.payload, "\"access_token\":\"") != null);

        try writeClientTextFrameMasked(&user_client, "{\"channel\":\"control\",\"type\":\"control.auth_rotate\",\"id\":\"user-auth-rotate\",\"payload\":{}}");
        var access_rotate = try readServerFrame(allocator, &user_client);
        defer access_rotate.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, access_rotate.payload, "\"type\":\"control.auth_rotate\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, access_rotate.payload, "\"access_token\":\"") != null);

        const attach_default = try std.fmt.allocPrint(
            allocator,
            "{{\"channel\":\"control\",\"type\":\"control.session_attach\",\"id\":\"user-attach-default\",\"payload\":{{\"session_key\":\"main\",\"agent_id\":\"{s}\"}}}}",
            .{runtime_registry.default_agent_id},
        );
        defer allocator.free(attach_default);
        try writeClientTextFrameMasked(&user_client, attach_default);
        var forbidden_attach = try readServerFrame(allocator, &user_client);
        defer forbidden_attach.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, forbidden_attach.payload, "\"type\":\"control.error\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, forbidden_attach.payload, "\"code\":\"missing_field\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, forbidden_attach.payload, "workspace_id is required") != null);

        try websocket_transport.writeFrame(&user_client, "", .close);
        var close_reply = try readServerFrame(allocator, &user_client);
        defer close_reply.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 0x8), close_reply.opcode);
    }

    {
        const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
        defer server_thread.join();

        var bad_client = try std.net.tcpConnectToAddress(listener.listen_address);
        defer bad_client.close();
        try performClientHandshakeWithBearerToken(allocator, &bad_client, "/", "wrong-secret");

        var auth_error = try readServerFrame(allocator, &bad_client);
        defer auth_error.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, auth_error.payload, "\"code\":\"provider_auth_failed\"") != null);

        var close_reply = try readServerFrame(allocator, &bad_client);
        defer close_reply.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 0x8), close_reply.opcode);
    }

    {
        const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
        defer server_thread.join();

        var missing_client = try std.net.tcpConnectToAddress(listener.listen_address);
        defer missing_client.close();
        try performClientHandshake(allocator, &missing_client, "/");

        var auth_error = try readServerFrame(allocator, &missing_client);
        defer auth_error.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, auth_error.payload, "\"code\":\"provider_auth_failed\"") != null);

        var close_reply = try readServerFrame(allocator, &missing_client);
        defer close_reply.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 0x8), close_reply.opcode);
    }

    try std.testing.expect(server_ctx.err_name == null);
}

test "server: user connect keeps a minimal payload when no remembered non-host target exists" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();
    try setAuthTokensForTests(&runtime_registry, "access-secret");

    var listener = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true });
    defer listener.deinit();

    var server_ctx = WsTestServerCtx{
        .allocator = allocator,
        .runtime_registry = &runtime_registry,
        .listener = &listener,
    };
    defer server_ctx.deinit();

    const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
    defer server_thread.join();

    var user_client = try std.net.tcpConnectToAddress(listener.listen_address);
    defer user_client.close();
    try performClientHandshakeWithBearerToken(allocator, &user_client, "/", "access-secret");

    try writeClientTextFrameMasked(&user_client, "{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"user-avoid-primary-version\",\"payload\":{\"protocol\":\"spiderweb-control\"}}");
    var version_ack = try readServerFrame(allocator, &user_client);
    defer version_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, version_ack.payload, "\"type\":\"control.version_ack\"") != null);

    try writeClientTextFrameMasked(&user_client, "{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"user-avoid-primary-connect\"}");
    var connect_ack = try readServerFrame(allocator, &user_client);
    defer connect_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"type\":\"control.connect_ack\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"requires_session_attach\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"connect_gate\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"project_setup_required\":") == null);

    const attach_primary = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"control\",\"type\":\"control.session_attach\",\"id\":\"user-attach-primary-user-id\",\"payload\":{{\"session_key\":\"main\",\"agent_id\":\"{s}\"}}}}",
        .{runtime_registry.default_agent_id},
    );
    defer allocator.free(attach_primary);
    try writeClientTextFrameMasked(&user_client, attach_primary);
    var attach_forbidden = try readServerFrame(allocator, &user_client);
    defer attach_forbidden.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, attach_forbidden.payload, "\"type\":\"control.error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, attach_forbidden.payload, "\"code\":\"missing_field\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, attach_forbidden.payload, "workspace_id is required") != null);

    try websocket_transport.writeFrame(&user_client, "", .close);
    var close_reply = try readServerFrame(allocator, &user_client);
    defer close_reply.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0x8), close_reply.opcode);

    try std.testing.expect(server_ctx.err_name == null);
}

test "server: provisioning gate still allows workspace bootstrap control operations" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();
    try setAuthTokensForTests(&runtime_registry, "access-secret");

    var listener = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true });
    defer listener.deinit();

    var server_ctx = WsTestServerCtx{
        .allocator = allocator,
        .runtime_registry = &runtime_registry,
        .listener = &listener,
    };
    defer server_ctx.deinit();

    const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
    defer server_thread.join();

    var admin_client = try std.net.tcpConnectToAddress(listener.listen_address);
    defer admin_client.close();
    try performClientHandshakeWithBearerToken(allocator, &admin_client, "/", "access-secret");

    try writeClientTextFrameMasked(&admin_client, "{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"bootstrap-version\",\"payload\":{\"protocol\":\"spiderweb-control\"}}");
    var version_ack = try readServerFrame(allocator, &admin_client);
    defer version_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, version_ack.payload, "\"type\":\"control.version_ack\"") != null);

    try writeClientTextFrameMasked(&admin_client, "{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"bootstrap-connect\"}");
    var connect_ack = try readServerFrame(allocator, &admin_client);
    defer connect_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"type\":\"control.connect_ack\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"connect_gate\":") == null);

    try writeClientTextFrameMasked(&admin_client, "{\"channel\":\"control\",\"type\":\"control.workspace_create\",\"id\":\"bootstrap-create\",\"payload\":{\"name\":\"Bootstrap\",\"vision\":\"Bootstrap workspace\"}}");
    var create_ack = try readServerFrame(allocator, &admin_client);
    defer create_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, create_ack.payload, "\"type\":\"control.workspace_create\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_ack.payload, "\"workspace_id\"") != null);

    try websocket_transport.writeFrame(&admin_client, "", .close);
    var close_reply = try readServerFrame(allocator, &admin_client);
    defer close_reply.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0x8), close_reply.opcode);

    try std.testing.expect(server_ctx.err_name == null);
}

test "server: user connect stays minimal even when another project is active" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();
    try setAuthTokensForTests(&runtime_registry, "access-secret");

    const project_up = try runtime_registry.control_plane.projectUpWithRole(
        host_actor_id,
        "{\"name\":\"Needs Attach\",\"vision\":\"Needs Attach\",\"activate\":false}",
        true,
    );
    defer allocator.free(project_up);
    const project_id = try extractInternalProjectIdForTests(allocator, project_up);
    defer allocator.free(project_id);

    const activate_payload = try std.fmt.allocPrint(
        allocator,
        "{{\"project_id\":\"{s}\"}}",
        .{project_id},
    );
    defer allocator.free(activate_payload);
    const activated = try runtime_registry.control_plane.activateProjectWithRole("alice", activate_payload, true);
    defer allocator.free(activated);

    var listener = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true });
    defer listener.deinit();

    var server_ctx = WsTestServerCtx{
        .allocator = allocator,
        .runtime_registry = &runtime_registry,
        .listener = &listener,
    };
    defer server_ctx.deinit();

    const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
    defer server_thread.join();

    var user_client = try std.net.tcpConnectToAddress(listener.listen_address);
    defer user_client.close();
    try performClientHandshakeWithBearerToken(allocator, &user_client, "/", "access-secret");

    try writeClientTextFrameMasked(&user_client, "{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"user-requires-attach-version\",\"payload\":{\"protocol\":\"spiderweb-control\"}}");
    var version_ack = try readServerFrame(allocator, &user_client);
    defer version_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, version_ack.payload, "\"type\":\"control.version_ack\"") != null);

    try writeClientTextFrameMasked(&user_client, "{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"user-requires-attach-connect\"}");
    var connect_ack = try readServerFrame(allocator, &user_client);
    defer connect_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"type\":\"control.connect_ack\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"requires_session_attach\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"connect_gate\":") == null);

    try websocket_transport.writeFrame(&user_client, "", .close);
    var close_reply = try readServerFrame(allocator, &user_client);
    defer close_reply.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0x8), close_reply.opcode);

    try std.testing.expect(server_ctx.err_name == null);
}

test "server: connect and session_status omit actor identity metadata" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();
    try setAuthTokensForTests(&runtime_registry, "access-secret");

    var listener = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true });
    defer listener.deinit();

    var server_ctx = WsTestServerCtx{
        .allocator = allocator,
        .runtime_registry = &runtime_registry,
        .listener = &listener,
    };
    defer server_ctx.deinit();

    const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
    defer server_thread.join();

    var client = try std.net.tcpConnectToAddress(listener.listen_address);
    defer client.close();
    try performClientHandshakeWithBearerToken(allocator, &client, "/", "access-secret");

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"actor-meta-version\",\"payload\":{\"protocol\":\"spiderweb-control\"}}");
    var version_ack = try readServerFrame(allocator, &client);
    defer version_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, version_ack.payload, "\"type\":\"control.version_ack\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"actor-meta-connect\"}");
    var connect_ack = try readServerFrame(allocator, &client);
    defer connect_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"type\":\"control.connect_ack\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"actor_type\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"actor_id\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"workspace\":{") != null);

    try writeClientTextFrameMasked(
        &client,
        "{\"channel\":\"control\",\"type\":\"control.session_status\",\"id\":\"actor-meta-status\",\"payload\":{\"session_key\":\"main\"}}",
    );
    var status_ack = try readServerFrame(allocator, &client);
    defer status_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, status_ack.payload, "\"type\":\"control.session_status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_ack.payload, "\"actor_type\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, status_ack.payload, "\"actor_id\":") == null);

    try websocket_transport.writeFrame(&client, "", .close);
    var close_reply = try readServerFrame(allocator, &client);
    defer close_reply.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0x8), close_reply.opcode);

    try std.testing.expect(server_ctx.err_name == null);
}

test "server: session_attach ignores public actor identity fields" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();
    try setAuthTokensForTests(&runtime_registry, "access-secret");
    try seedRememberedTargetForTests(&runtime_registry, runtime_registry.default_agent_id);
    const remembered_target = runtime_registry.auth_tokens.access_last_target orelse return error.TestExpectedResult;
    const remembered_project_id = remembered_target.project_id;

    var listener = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true });
    defer listener.deinit();

    var server_ctx = WsTestServerCtx{
        .allocator = allocator,
        .runtime_registry = &runtime_registry,
        .listener = &listener,
    };
    defer server_ctx.deinit();

    const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
    defer server_thread.join();

    var client = try std.net.tcpConnectToAddress(listener.listen_address);
    defer client.close();
    try performClientHandshakeWithBearerToken(allocator, &client, "/", "access-secret");

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"actor-guard-version\",\"payload\":{\"protocol\":\"spiderweb-control\"}}");
    var version_ack = try readServerFrame(allocator, &client);
    defer version_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, version_ack.payload, "\"type\":\"control.version_ack\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"actor-guard-connect\"}");
    var connect_ack = try readServerFrame(allocator, &client);
    defer connect_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"type\":\"control.connect_ack\"") != null);

    const override_attach = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"control\",\"type\":\"control.session_attach\",\"id\":\"actor-guard-override\",\"payload\":{{\"session_key\":\"main\",\"agent_id\":\"{s}\",\"workspace_id\":\"{s}\",\"actor_type\":\"agent\",\"actor_id\":\"intruder\"}}}}",
        .{ runtime_registry.default_agent_id, remembered_project_id },
    );
    defer allocator.free(override_attach);
    try writeClientTextFrameMasked(&client, override_attach);
    var attach_ack = try readServerFrame(allocator, &client);
    defer attach_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, attach_ack.payload, "\"type\":\"control.session_attach\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, attach_ack.payload, "\"actor_type\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, attach_ack.payload, "\"actor_id\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, attach_ack.payload, "\"workspace\":{") != null);

    try websocket_transport.writeFrame(&client, "", .close);
    var close_reply = try readServerFrame(allocator, &client);
    defer close_reply.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0x8), close_reply.opcode);

    try std.testing.expect(server_ctx.err_name == null);
}

test "server: control.session_history and control.session_restore survive reconnect" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();
    try setAuthTokensForTests(&runtime_registry, "access-secret");
    try seedRememberedTargetForTests(&runtime_registry, runtime_registry.default_agent_id);
    const remembered_target = runtime_registry.auth_tokens.access_last_target orelse return error.TestExpectedResult;
    const remembered_project_id = remembered_target.project_id;

    var listener = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true });
    defer listener.deinit();

    var server_ctx = WsTestServerCtx{
        .allocator = allocator,
        .runtime_registry = &runtime_registry,
        .listener = &listener,
    };
    defer server_ctx.deinit();

    {
        const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
        defer server_thread.join();

        var user_client = try std.net.tcpConnectToAddress(listener.listen_address);
        defer user_client.close();
        try performClientHandshakeWithBearerToken(allocator, &user_client, "/", "access-secret");

        try writeClientTextFrameMasked(&user_client, "{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"history-version\",\"payload\":{\"protocol\":\"spiderweb-control\"}}");
        var version_ack = try readServerFrame(allocator, &user_client);
        defer version_ack.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, version_ack.payload, "\"type\":\"control.version_ack\"") != null);

        try writeClientTextFrameMasked(&user_client, "{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"history-connect\"}");
        var connect_ack = try readServerFrame(allocator, &user_client);
        defer connect_ack.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"type\":\"control.connect_ack\"") != null);

        const attach_payload = try std.fmt.allocPrint(
            allocator,
            "{{\"channel\":\"control\",\"type\":\"control.session_attach\",\"id\":\"history-attach\",\"payload\":{{\"session_key\":\"work-1\",\"agent_id\":\"{s}\",\"workspace_id\":\"{s}\"}}}}",
            .{ runtime_registry.default_agent_id, remembered_project_id },
        );
        defer allocator.free(attach_payload);
        try writeClientTextFrameMasked(&user_client, attach_payload);
        var attach_ack = try readServerFrame(allocator, &user_client);
        defer attach_ack.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, attach_ack.payload, "\"type\":\"control.session_attach\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, attach_ack.payload, "\"workspace\":{") != null);

        try writeClientTextFrameMasked(
            &user_client,
            "{\"channel\":\"control\",\"type\":\"control.session_history\",\"id\":\"history-list\",\"payload\":{\"limit\":5}}",
        );
        var history = try readServerFrame(allocator, &user_client);
        defer history.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, history.payload, "\"type\":\"control.session_history\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, history.payload, "\"session_key\":\"work-1\"") != null);

        try websocket_transport.writeFrame(&user_client, "", .close);
        var close_reply = try readServerFrame(allocator, &user_client);
        defer close_reply.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 0x8), close_reply.opcode);
    }

    {
        const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
        defer server_thread.join();

        var user_client = try std.net.tcpConnectToAddress(listener.listen_address);
        defer user_client.close();
        try performClientHandshakeWithBearerToken(allocator, &user_client, "/", "access-secret");

        try writeClientTextFrameMasked(&user_client, "{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"restore-version\",\"payload\":{\"protocol\":\"spiderweb-control\"}}");
        var version_ack = try readServerFrame(allocator, &user_client);
        defer version_ack.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, version_ack.payload, "\"type\":\"control.version_ack\"") != null);

        try writeClientTextFrameMasked(&user_client, "{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"restore-connect\"}");
        var connect_ack = try readServerFrame(allocator, &user_client);
        defer connect_ack.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"type\":\"control.connect_ack\"") != null);

        const restore_payload = try std.fmt.allocPrint(
            allocator,
            "{{\"channel\":\"control\",\"type\":\"control.session_restore\",\"id\":\"restore-last\",\"payload\":{{\"agent_id\":\"{s}\"}}}}",
            .{runtime_registry.default_agent_id},
        );
        defer allocator.free(restore_payload);
        try writeClientTextFrameMasked(&user_client, restore_payload);
        var restore = try readServerFrame(allocator, &user_client);
        defer restore.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, restore.payload, "\"type\":\"control.session_restore\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, restore.payload, "\"found\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, restore.payload, "\"session_key\":\"work-1\"") != null);

        try websocket_transport.writeFrame(&user_client, "", .close);
        var close_reply = try readServerFrame(allocator, &user_client);
        defer close_reply.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 0x8), close_reply.opcode);
    }

    try std.testing.expect(server_ctx.err_name == null);
}

test "server: control.auth_rotate reports storage_error when token persistence fails" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();
    try setAuthTokensForTests(&runtime_registry, "access-secret");

    if (runtime_registry.auth_tokens.path) |path| allocator.free(path);
    runtime_registry.auth_tokens.path = try allocator.dupe(u8, "/");
    const previous_access = try allocator.dupe(u8, runtime_registry.auth_tokens.access_token);
    defer allocator.free(previous_access);

    var listener = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true });
    defer listener.deinit();

    var server_ctx = WsTestServerCtx{
        .allocator = allocator,
        .runtime_registry = &runtime_registry,
        .listener = &listener,
    };
    defer server_ctx.deinit();

    const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
    defer server_thread.join();

    var client = try std.net.tcpConnectToAddress(listener.listen_address);
    defer client.close();
    try performClientHandshakeWithBearerToken(allocator, &client, "/", "access-secret");

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"rotate-fail-version\",\"payload\":{\"protocol\":\"spiderweb-control\"}}");
    var version_ack = try readServerFrame(allocator, &client);
    defer version_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, version_ack.payload, "\"type\":\"control.version_ack\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"rotate-fail-connect\"}");
    var connect_ack = try readServerFrame(allocator, &client);
    defer connect_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"type\":\"control.connect_ack\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.auth_rotate\",\"id\":\"rotate-fail\",\"payload\":{}}");
    var rotate_error = try readServerFrame(allocator, &client);
    defer rotate_error.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, rotate_error.payload, "\"type\":\"control.error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rotate_error.payload, "\"code\":\"storage_error\"") != null);

    try std.testing.expectEqualStrings(previous_access, runtime_registry.auth_tokens.access_token);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.ping\",\"id\":\"rotate-fail-ping\"}");
    var pong = try readServerFrame(allocator, &client);
    defer pong.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, pong.payload, "\"type\":\"control.pong\"") != null);

    try websocket_transport.writeFrame(&client, "", .close);
    var close_reply = try readServerFrame(allocator, &client);
    defer close_reply.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0x8), close_reply.opcode);

    try std.testing.expect(server_ctx.err_name == null);
}

test "server: debug subscription control operations are unsupported in acheron-native mode" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();
    try setAuthTokensForTests(&runtime_registry, "access-secret");

    var listener = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true });
    defer listener.deinit();

    var server_ctx = WsTestServerCtx{
        .allocator = allocator,
        .runtime_registry = &runtime_registry,
        .listener = &listener,
    };
    defer server_ctx.deinit();

    const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
    defer server_thread.join();

    var client = try std.net.tcpConnectToAddress(listener.listen_address);
    defer client.close();
    try performClientHandshakeWithBearerToken(allocator, &client, "/", "access-secret");
    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"ver\",\"payload\":{\"protocol\":\"spiderweb-control\"}}");
    var version_ack = try readServerFrame(allocator, &client);
    defer version_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, version_ack.payload, "\"type\":\"control.version_ack\"") != null);
    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"conn\"}");
    var connect_ack = try readServerFrame(allocator, &client);
    defer connect_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"type\":\"control.connect_ack\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.debug_subscribe\",\"id\":\"sub\"}");
    var subscribe = try readServerFrame(allocator, &client);
    defer subscribe.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, subscribe.payload, "\"type\":\"control.error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, subscribe.payload, "\"code\":\"unsupported_legacy_api\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.debug_unsubscribe\",\"id\":\"unsub\"}");
    var unsubscribe = try readServerFrame(allocator, &client);
    defer unsubscribe.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, unsubscribe.payload, "\"type\":\"control.error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, unsubscribe.payload, "\"code\":\"unsupported_legacy_api\"") != null);

    try websocket_transport.writeFrame(&client, "", .close);
    var close_reply = try readServerFrame(allocator, &client);
    defer close_reply.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0x8), close_reply.opcode);
    try std.testing.expect(server_ctx.err_name == null);
}

test "server: base path rejects legacy runtime connections cleanly across reconnects" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();
    try setAuthTokensForTests(&runtime_registry, "access-secret");

    var listener = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true });
    defer listener.deinit();

    var server_ctx = WsTestServerCtx{
        .allocator = allocator,
        .runtime_registry = &runtime_registry,
        .listener = &listener,
    };
    defer server_ctx.deinit();

    {
        const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
        defer server_thread.join();

        var client = try std.net.tcpConnectToAddress(listener.listen_address);
        defer client.close();
        try performClientHandshakeWithBearerToken(allocator, &client, "/", "access-secret");

        try fsrpcConnectAndAttach(allocator, &client, "a-connect");
        try expectLegacyAcheronRejected(allocator, &client);
    }

    {
        const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
        defer server_thread.join();

        var client = try std.net.tcpConnectToAddress(listener.listen_address);
        defer client.close();
        try performClientHandshakeWithBearerToken(allocator, &client, "/", "access-secret");

        try fsrpcConnectAndAttach(allocator, &client, "b-connect");
        try expectLegacyAcheronRejected(allocator, &client);
    }

    try std.testing.expectEqual(@as(usize, 0), runtime_registry.by_agent.count());

    try std.testing.expect(server_ctx.err_name == null);
}

test "server: runtime cap does not block repeated base-path reconnects" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.initWithLimits(
        allocator,
        .{ .state_directory = "", .state_db_filename = "" },
        null,
        1,
    );
    defer runtime_registry.deinit();
    try setAuthTokensForTests(&runtime_registry, "access-secret");

    var listener = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true });
    defer listener.deinit();

    var server_ctx = WsTestServerCtx{
        .allocator = allocator,
        .runtime_registry = &runtime_registry,
        .listener = &listener,
    };
    defer server_ctx.deinit();

    {
        const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
        defer server_thread.join();

        var client = try std.net.tcpConnectToAddress(listener.listen_address);
        defer client.close();
        try performClientHandshakeWithBearerToken(allocator, &client, "/", "access-secret");

        try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"alpha-version\",\"payload\":{\"protocol\":\"spiderweb-control\"}}");
        var version_ack = try readServerFrame(allocator, &client);
        defer version_ack.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, version_ack.payload, "\"type\":\"control.version_ack\"") != null);

        try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"alpha-connect\"}");
        var connect_ack = try readServerFrame(allocator, &client);
        defer connect_ack.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"type\":\"control.connect_ack\"") != null);

        try websocket_transport.writeFrame(&client, "", .close);
        var close_reply = try readServerFrame(allocator, &client);
        defer close_reply.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 0x8), close_reply.opcode);
    }

    {
        const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
        defer server_thread.join();

        var client = try std.net.tcpConnectToAddress(listener.listen_address);
        defer client.close();
        try performClientHandshakeWithBearerToken(allocator, &client, "/", "access-secret");

        try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"beta-version\",\"payload\":{\"protocol\":\"spiderweb-control\"}}");
        var version_ack = try readServerFrame(allocator, &client);
        defer version_ack.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, version_ack.payload, "\"type\":\"control.version_ack\"") != null);

        try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"beta-connect\"}");
        var connect_ack = try readServerFrame(allocator, &client);
        defer connect_ack.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"type\":\"control.connect_ack\"") != null);

        var close_reply = try readServerFrame(allocator, &client);
        defer close_reply.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 0x8), close_reply.opcode);
    }

    try std.testing.expectEqual(@as(usize, 1), runtime_registry.by_agent.count());
    try std.testing.expect(server_ctx.err_name == null);
}

test "server: project runtime switches persona when agent changes" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.initWithLimits(
        allocator,
        .{ .state_directory = "", .state_db_filename = "" },
        null,
        1,
    );
    defer runtime_registry.deinit();

    const project_id = "proj-persona-switch";
    const first_runtime = try runtime_registry.getOrCreate(runtime_registry.default_agent_id, project_id, null);
    defer first_runtime.release();
    try std.testing.expect(runtime_registry.hasRuntimeForBinding(runtime_registry.default_agent_id, project_id));
    try std.testing.expectEqual(@as(usize, 1), runtime_registry.by_agent.count());

    const second_runtime = try runtime_registry.getOrCreate(host_actor_id, project_id, null);
    defer second_runtime.release();
    try std.testing.expect(second_runtime != first_runtime);
    try std.testing.expect(!runtime_registry.hasRuntimeForBinding(runtime_registry.default_agent_id, project_id));
    try std.testing.expect(runtime_registry.hasRuntimeForBinding(host_actor_id, project_id));
    try std.testing.expectEqual(@as(usize, 1), runtime_registry.by_agent.count());

    const stale_lookup = runtime_registry.getRuntimeForBindingIfReady(runtime_registry.default_agent_id, project_id);
    try std.testing.expect(stale_lookup == null);

    const active_lookup = runtime_registry.getRuntimeForBindingIfReady(host_actor_id, project_id) orelse return error.TestExpectedResult;
    active_lookup.release();

    runtime_registry.mutex.lock();
    defer runtime_registry.mutex.unlock();
    const active_entry = runtime_registry.by_agent.getPtr(project_id) orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings(host_actor_id, active_entry.runtime_agent_id);
}

test "server: getOrCreate replaces unhealthy runtime for same agent" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.initWithLimits(
        allocator,
        .{ .state_directory = "", .state_db_filename = "" },
        null,
        1,
    );
    defer runtime_registry.deinit();

    const project_id = "proj-unhealthy-runtime";
    const first_runtime = try runtime_registry.getOrCreate(runtime_registry.default_agent_id, project_id, null);
    runtime_registry.mutex.lock();
    {
        const entry = runtime_registry.by_agent.getPtr(project_id) orelse return error.TestExpectedResult;
        entry.runtime.kind = .local_sandbox;
        entry.runtime.sandbox = null;
    }
    runtime_registry.mutex.unlock();

    const second_runtime = try runtime_registry.getOrCreate(runtime_registry.default_agent_id, project_id, null);
    defer second_runtime.release();
    defer first_runtime.release();

    try std.testing.expect(second_runtime != first_runtime);
    try std.testing.expect(runtime_registry.hasRuntimeForBinding(runtime_registry.default_agent_id, project_id));
    try std.testing.expectEqual(@as(usize, 1), runtime_registry.by_agent.count());
}

test "server: ready runtime lookup rejects unhealthy binding" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.initWithLimits(
        allocator,
        .{ .state_directory = "", .state_db_filename = "" },
        null,
        1,
    );
    defer runtime_registry.deinit();

    const project_id = "proj-unhealthy-ready-lookup";
    const runtime = try runtime_registry.getOrCreate(runtime_registry.default_agent_id, project_id, null);
    defer runtime.release();

    runtime_registry.mutex.lock();
    {
        const entry = runtime_registry.by_agent.getPtr(project_id) orelse return error.TestExpectedResult;
        entry.runtime.kind = .local_sandbox;
        entry.runtime.sandbox = null;
    }
    runtime_registry.mutex.unlock();

    const ready = runtime_registry.getRuntimeForBindingIfReady(runtime_registry.default_agent_id, project_id);
    try std.testing.expect(ready == null);
    try std.testing.expect(!runtime_registry.hasRuntimeForBinding(runtime_registry.default_agent_id, project_id));
    try std.testing.expectEqual(@as(usize, 0), runtime_registry.by_agent.count());
}

test "server: unhealthy binding drop marks warmup error" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.initWithLimits(
        allocator,
        .{ .state_directory = "", .state_db_filename = "" },
        null,
        1,
    );
    defer runtime_registry.deinit();

    const project_id = "proj-unhealthy-warmup-error";
    const runtime = try runtime_registry.getOrCreate(runtime_registry.default_agent_id, project_id, null);
    defer runtime.release();

    runtime_registry.mutex.lock();
    {
        const entry = runtime_registry.by_agent.getPtr(project_id) orelse return error.TestExpectedResult;
        entry.runtime.kind = .local_sandbox;
        entry.runtime.sandbox = null;
    }
    runtime_registry.mutex.unlock();

    try std.testing.expect(runtime_registry.dropUnhealthyRuntimeForBinding(
        runtime_registry.default_agent_id,
        project_id,
        "runtime_unhealthy",
        "project runtime became unhealthy",
    ));

    const binding_key = try runtime_registry.runtimeBindingKey(runtime_registry.default_agent_id, project_id);
    defer allocator.free(binding_key);

    const snapshot = runtime_registry.runtimeAttachSnapshotByKey(binding_key);
    defer snapshot.deinit(allocator);

    try std.testing.expectEqual(SessionAttachState.err, snapshot.state);
    try std.testing.expectEqualStrings("runtime_unhealthy", snapshot.error_code orelse "");
    try std.testing.expect(!runtime_registry.hasRuntimeForBinding(runtime_registry.default_agent_id, project_id));
}

test "server: websocket rejects unsupported route version" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();

    var listener = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true });
    defer listener.deinit();

    var server_ctx = WsTestServerCtx{
        .allocator = allocator,
        .runtime_registry = &runtime_registry,
        .listener = &listener,
    };
    defer server_ctx.deinit();

    const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
    defer server_thread.join();

    var client = try std.net.tcpConnectToAddress(listener.listen_address);
    defer client.close();
    try performClientHandshake(allocator, &client, "/v1/agents/default/stream");

    var invalid_path_error = try readServerFrame(allocator, &client);
    defer invalid_path_error.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0x1), invalid_path_error.opcode);
    try std.testing.expect(std.mem.indexOf(u8, invalid_path_error.payload, "\"code\":\"invalid_envelope\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, invalid_path_error.payload, "invalid websocket path") != null);

    var close_reply = try readServerFrame(allocator, &client);
    defer close_reply.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0x8), close_reply.opcode);

    try std.testing.expect(server_ctx.err_name == null);
}

test "server: resolve connection path maps base URL to default agent" {
    const resolved_root = resolveAgentIdFromConnectionPath("/", "default") orelse return error.TestExpectedAgent;
    try std.testing.expectEqualStrings("default", resolved_root);
    const resolved_query = resolveAgentIdFromConnectionPath("/?session=main", "default") orelse return error.TestExpectedAgent;
    try std.testing.expectEqualStrings("default", resolved_query);
    try std.testing.expect(resolveAgentIdFromConnectionPath("/v2/agents/default/stream", "default") == null);
    try std.testing.expect(resolveAgentIdFromConnectionPath("/v1/agents/default/stream", "default") == null);
}

test "server: pathMatchesControlTarget only matches control namespace root path" {
    try std.testing.expect(pathMatchesControlTarget("global/workspaces/control/up.json", "global/workspaces/control/up.json"));
    try std.testing.expect(pathMatchesControlTarget("/global/workspaces/control/up.json", "global/workspaces/control/up.json"));
    try std.testing.expect(pathMatchesControlTarget("/global/workspaces/control/up.json/", "global/workspaces/control/up.json"));
    try std.testing.expect(!pathMatchesControlTarget("workspace/global/workspaces/control/up.json", "global/workspaces/control/up.json"));
}

test "server: parseHttpRequestPath parses GET line" {
    const request =
        "GET /metrics HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "\r\n";
    const path = server_metrics_http.parseHttpRequestPath(request) orelse return error.TestExpectedPath;
    try std.testing.expectEqualStrings("/metrics", path);
}

test "server: stripHttpRequestTargetQuery removes query string" {
    try std.testing.expectEqualStrings("/metrics", server_metrics_http.stripHttpRequestTargetQuery("/metrics?format=json"));
    try std.testing.expectEqualStrings("/readyz", server_metrics_http.stripHttpRequestTargetQuery("/readyz"));
}

test "server: extract workspace payload helpers parse id and token" {
    const allocator = std.testing.allocator;
    const payload = "{\"workspace_id\":\"proj-7\",\"workspace_token\":\"proj-token-7\"}";

    const workspace_id = try server_control_scope.extractWorkspaceIdFromControlPayload(allocator, payload);
    defer if (workspace_id) |value| allocator.free(value);
    try std.testing.expect(workspace_id != null);
    try std.testing.expectEqualStrings("proj-7", workspace_id.?);

    const workspace_token = try server_control_scope.extractWorkspaceTokenFromControlPayload(allocator, payload);
    defer if (workspace_token) |value| allocator.free(value);
    try std.testing.expect(workspace_token != null);
    try std.testing.expectEqualStrings("proj-token-7", workspace_token.?);

    const token_missing = try server_control_scope.extractWorkspaceTokenFromControlPayload(allocator, "{\"workspace_id\":\"proj-7\"}");
    try std.testing.expect(token_missing == null);
}

test "server: extract node id helper parses valid payload" {
    const allocator = std.testing.allocator;
    const payload = "{\"node_id\":\"node-7\",\"venom_delta\":{\"changed\":true}}";
    const node_id = try server_control_scope.extractNodeIdFromControlPayload(allocator, payload);
    defer if (node_id) |value| allocator.free(value);
    try std.testing.expect(node_id != null);
    try std.testing.expectEqualStrings("node-7", node_id.?);

    const missing = try server_control_scope.extractNodeIdFromControlPayload(allocator, "{\"venom_delta\":{}}");
    try std.testing.expect(missing == null);
}

test "server: user node service visibility is project mounted-node scoped" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();

    const join_payload = try runtime_registry.control_plane.ensureNode("node-a", "ws://127.0.0.1:18891/fs", 60_000);
    defer allocator.free(join_payload);
    const node_registration = try parseNodeRegistrationFromJoinPayload(allocator, join_payload);
    defer {
        allocator.free(node_registration.node_id);
        allocator.free(node_registration.node_secret);
    }

    const project_created = try runtime_registry.control_plane.createProject(
        "{\"name\":\"ScopedProject\",\"vision\":\"ScopedProject\",\"access_policy\":{\"actions\":{\"observe\":\"open\"}}}",
    );
    defer allocator.free(project_created);
    const project_id = try extractInternalProjectIdForTests(allocator, project_created);
    defer allocator.free(project_id);

    const mount_payload = try std.fmt.allocPrint(
        allocator,
        "{{\"project_id\":\"{s}\",\"mount_path\":\"/nodes/node-a/fs\",\"node_id\":\"{s}\",\"export_name\":\"fs\"}}",
        .{ project_id, node_registration.node_id },
    );
    defer allocator.free(mount_payload);
    const mount_result = try runtime_registry.control_plane.setProjectMountWithRole(mount_payload, false);
    defer allocator.free(mount_result);

    try std.testing.expect(runtime_registry.control_plane.projectAllowsNodeVenomEvent(
        project_id.?,
        "bob",
        null,
        node_registration.node_id,
        false,
    ));
    try std.testing.expect(!runtime_registry.control_plane.projectAllowsNodeVenomEvent(
        project_id.?,
        "bob",
        null,
        "node-missing",
        false,
    ));
    try std.testing.expect(!runtime_registry.control_plane.projectAllowsNodeVenomEvent(
        project_id.?,
        "bob",
        null,
        "node-other",
        false,
    ));
}

test "server: validateFsNodeHelloPayload enforces optional auth_token" {
    const allocator = std.testing.allocator;
    _ = try validateFsNodeHelloPayload(
        allocator,
        "{\"protocol\":\"spiderweb-fs\",\"proto\":2}",
        null,
    );
    _ = try validateFsNodeHelloPayload(
        allocator,
        "{\"protocol\":\"spiderweb-fs\",\"proto\":2,\"auth_token\":\"secret\"}",
        "secret",
    );
    try std.testing.expectError(
        error.AuthMissing,
        validateFsNodeHelloPayload(
            allocator,
            "{\"protocol\":\"spiderweb-fs\",\"proto\":2}",
            "secret",
        ),
    );
    try std.testing.expectError(
        error.AuthFailed,
        validateFsNodeHelloPayload(
            allocator,
            "{\"protocol\":\"spiderweb-fs\",\"proto\":2,\"auth_token\":\"wrong\"}",
            "secret",
        ),
    );
}

test "server: node fs route parser extracts node id" {
    const route = parseNodeFsRoute("/fs/node/node-17") orelse return error.TestExpectedResponse;
    try std.testing.expectEqualStrings("node-17", route);
    const route_q = parseNodeFsRoute("/fs/node/node_17?session=a") orelse return error.TestExpectedResponse;
    try std.testing.expectEqualStrings("node_17", route_q);
    try std.testing.expect(parseNodeFsRoute("/fs/node/") == null);
    try std.testing.expect(parseNodeFsRoute("/fs/node/node:bad") == null);
}

test "server: buildInternalNodeFsUrl produces routed fs path" {
    const allocator = std.testing.allocator;
    const routed = try server_local_node_supervisor.buildInternalNodeFsUrl(allocator, "0.0.0.0", 18790, "node-17");
    defer allocator.free(routed);
    try std.testing.expectEqualStrings("ws://127.0.0.1:18790/fs/node/node-17", routed);
}

test "server: rewriteAcheronTag rewrites top-level tag" {
    const allocator = std.testing.allocator;
    const raw = "{\"channel\":\"acheron\",\"type\":\"acheron.t_fs_lookup\",\"tag\":7,\"payload\":{\"name\":\"a\"}}";
    const rewritten = try rewriteAcheronTag(allocator, raw, 99);
    defer allocator.free(rewritten);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "\"tag\":99") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "\"type\":\"acheron.t_fs_lookup\"") != null);
}

test "server: agent id validation allows safe identifiers only" {
    try std.testing.expect(AgentRuntimeRegistry.isValidAgentId("alpha-1"));
    try std.testing.expect(AgentRuntimeRegistry.isValidAgentId("agent_2"));
    try std.testing.expect(!AgentRuntimeRegistry.isValidAgentId("."));
    try std.testing.expect(!AgentRuntimeRegistry.isValidAgentId("agent:bad"));
    try std.testing.expect(!AgentRuntimeRegistry.isValidAgentId(""));
}

test "server: project id validation rejects traversal-like values" {
    try std.testing.expect(AgentRuntimeRegistry.isValidProjectId("proj-1"));
    try std.testing.expect(AgentRuntimeRegistry.isValidProjectId("proj.alpha_2"));
    try std.testing.expect(!AgentRuntimeRegistry.isValidProjectId(""));
    try std.testing.expect(!AgentRuntimeRegistry.isValidProjectId("."));
    try std.testing.expect(!AgentRuntimeRegistry.isValidProjectId(".."));
    try std.testing.expect(!AgentRuntimeRegistry.isValidProjectId("proj/../../etc"));
}

test "server: invalid configured default agent falls back to built-in default" {
    const allocator = std.testing.allocator;
    var cfg = Config.RuntimeConfig{};
    cfg.default_agent_id = ".";

    const registry = AgentRuntimeRegistry.initWithLimits(allocator, cfg, null, 8);
    try std.testing.expectEqualStrings(host_actor_id, registry.default_agent_id);
}

test "server: materializeMountGraphWriteData preserves suffix on offset zero partial writes" {
    const allocator = std.testing.allocator;
    const merged = try server_mount_graph_io.materializeWriteData(
        allocator,
        "abcdef",
        0,
        "xy",
        null,
        max_mount_graph_materialized_file_bytes,
    );
    defer allocator.free(merged);
    try std.testing.expectEqualStrings("xycdef", merged);
}

test "server: materializeMountGraphWriteData preserves suffix on middle writes" {
    const allocator = std.testing.allocator;
    const merged = try server_mount_graph_io.materializeWriteData(
        allocator,
        "abcdef",
        2,
        "XY",
        null,
        max_mount_graph_materialized_file_bytes,
    );
    defer allocator.free(merged);
    try std.testing.expectEqualStrings("abXYef", merged);
}

test "server: materializeMountGraphWriteData truncates existing content before rewrite" {
    const allocator = std.testing.allocator;
    const merged = try server_mount_graph_io.materializeWriteData(
        allocator,
        "abcdef",
        0,
        "",
        3,
        max_mount_graph_materialized_file_bytes,
    );
    defer allocator.free(merged);
    try std.testing.expectEqualStrings("abc", merged);
}

test "server: materializeMountGraphWriteData rejects truncate on missing files" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.FileNotFound,
        server_mount_graph_io.materializeWriteData(
            allocator,
            null,
            0,
            "",
            0,
            max_mount_graph_materialized_file_bytes,
        ),
    );
}

test "server: materializeMountGraphWriteData rejects oversized materialized writes" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.WriteTooLarge,
        server_mount_graph_io.materializeWriteData(
            allocator,
            "",
            max_mount_graph_materialized_file_bytes,
            "x",
            null,
            max_mount_graph_materialized_file_bytes,
        ),
    );
}

test "server: mountGraphWriteResponseCount reports request byte length" {
    try std.testing.expectEqual(@as(u32, 2), try server_mount_graph_io.writeResponseCount(2));
}

test "server: getRequiredStringFieldAllowEmpty accepts empty payload strings" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"data_b64\":\"\"}",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("", try getRequiredStringFieldAllowEmpty(parsed.value.object, "data_b64"));
}

test "server: mountGraphErrorCode emits errno-compatible tokens" {
    try std.testing.expectEqualStrings("enoent", mountGraphErrorCode(error.FileNotFound));
    try std.testing.expectEqualStrings("eacces", mountGraphErrorCode(error.AccessDenied));
    try std.testing.expectEqualStrings("einval", mountGraphErrorCode(error.InvalidPayload));
    try std.testing.expectEqualStrings("enotdir", mountGraphErrorCode(error.NotDir));
    try std.testing.expectEqualStrings("eisdir", mountGraphErrorCode(error.IsDir));
    try std.testing.expectEqualStrings("enodata", mountGraphErrorCode(error.NoData));
    try std.testing.expectEqualStrings("eagain", mountGraphErrorCode(error.WouldBlock));
    try std.testing.expectEqualStrings("erange", mountGraphErrorCode(error.Range));
    try std.testing.expectEqualStrings("enosys", mountGraphErrorCode(error.OperationNotSupported));
}

test "server: clampMountGraphReadLength rejects offsets beyond materialization limit" {
    const limit = max_mount_graph_materialized_file_bytes;
    try std.testing.expectError(
        error.InvalidOffset,
        server_mount_graph_io.clampReadLength(limit + 1, null, max_mount_graph_materialized_file_bytes),
    );
}

test "server: clampMountGraphReadLength clamps explicit length to remaining bytes" {
    const near_end = max_mount_graph_materialized_file_bytes - 16;
    try std.testing.expectEqual(
        @as(u32, 16),
        try server_mount_graph_io.clampReadLength(near_end, 1024, max_mount_graph_materialized_file_bytes),
    );
    try std.testing.expectEqual(
        @as(u32, 0),
        try server_mount_graph_io.clampReadLength(
            max_mount_graph_materialized_file_bytes,
            1024,
            max_mount_graph_materialized_file_bytes,
        ),
    );
}

test "server: mountGraphReadIsEof reports eof when clamp reaches materialization boundary" {
    const limit = max_mount_graph_materialized_file_bytes;
    try std.testing.expect(server_mount_graph_io.readIsEof(
        limit,
        null,
        0,
        0,
        max_mount_graph_materialized_file_bytes,
    ));
    try std.testing.expect(server_mount_graph_io.readIsEof(
        limit,
        1024,
        0,
        0,
        max_mount_graph_materialized_file_bytes,
    ));
}

test "server: mountGraphReadIsEof preserves zero-length request semantics away from boundary" {
    try std.testing.expect(!server_mount_graph_io.readIsEof(
        0,
        0,
        0,
        0,
        max_mount_graph_materialized_file_bytes,
    ));
}

test "server: mount attach and mount file read control operations are supported after session attach" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();
    try setAuthTokensForTests(&runtime_registry, "access-secret");

    const project_up = try runtime_registry.control_plane.projectUpWithRole(
        "mount-agent",
        "{\"name\":\"MountAttach\",\"vision\":\"MountAttach\",\"activate\":false}",
        true,
    );
    defer allocator.free(project_up);
    const project_id = try extractInternalProjectIdForTests(allocator, project_up);
    defer allocator.free(project_id);

    var listener = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true });
    defer listener.deinit();

    var server_ctx = WsTestServerCtx{
        .allocator = allocator,
        .runtime_registry = &runtime_registry,
        .listener = &listener,
    };
    defer server_ctx.deinit();

    const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
    defer server_thread.join();

    var client = try std.net.tcpConnectToAddress(listener.listen_address);
    defer client.close();
    try performClientHandshakeWithBearerToken(allocator, &client, "/", "access-secret");

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"mount-version\",\"payload\":{\"protocol\":\"spiderweb-control\"}}");
    var version_ack = try readServerFrame(allocator, &client);
    defer version_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, version_ack.payload, "\"type\":\"control.version_ack\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"mount-connect\"}");
    var connect_ack = try readServerFrame(allocator, &client);
    defer connect_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"type\":\"control.connect_ack\"") != null);

    const attach_payload = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"control\",\"type\":\"control.session_attach\",\"id\":\"mount-attach-session\",\"payload\":{{\"session_key\":\"fskit\",\"agent_id\":\"mount-agent\",\"workspace_id\":\"{s}\"}}}}",
        .{project_id},
    );
    defer allocator.free(attach_payload);
    try writeClientTextFrameMasked(&client, attach_payload);
    var attach_ack = try readServerFrame(allocator, &client);
    defer attach_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, attach_ack.payload, "\"type\":\"control.session_attach\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.mount_attach\",\"id\":\"mount-attach\",\"payload\":{\"path\":\"/\",\"depth\":1}}");
    var mount_attach_ack = try readServerFrame(allocator, &client);
    defer mount_attach_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, mount_attach_ack.payload, "\"type\":\"control.mount_attach\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mount_attach_ack.payload, "\"mount_session_id\":\"mount-v2:spiderweb:fskit\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.mount_file_read\",\"id\":\"mount-read\",\"payload\":{\"path\":\"/meta/protocol.json\",\"offset\":0,\"length\":128}}");
    var mount_read_ack = try readServerFrame(allocator, &client);
    defer mount_read_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, mount_read_ack.payload, "\"type\":\"control.mount_file_read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mount_read_ack.payload, "\"data_b64\":\"") != null);

    try websocket_transport.writeFrame(&client, "", .close);
    var close_reply = try readServerFrame(allocator, &client);
    defer close_reply.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0x8), close_reply.opcode);

    try std.testing.expect(server_ctx.err_name == null);
}

test "server: mount file read can read projected workspace managed files after session attach" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("spiderweb-runtime");

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const spiderweb_runtime_root = try std.fs.path.join(allocator, &.{ root, "spiderweb-runtime" });
    defer allocator.free(spiderweb_runtime_root);

    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
        .spider_web_root = spiderweb_runtime_root,
    }, null);
    defer runtime_registry.deinit();
    try setAuthTokensForTests(&runtime_registry, "access-secret");

    const join_payload = try runtime_registry.control_plane.ensureNode("workspace-node", "ws://127.0.0.1:18891/fs", 60_000);
    defer allocator.free(join_payload);
    const node_registration = try parseNodeRegistrationFromJoinPayload(allocator, join_payload);
    defer {
        allocator.free(node_registration.node_id);
        allocator.free(node_registration.node_secret);
    }

    const project_up = try runtime_registry.control_plane.projectUpWithRole(
        "mount-agent",
        try std.fmt.allocPrint(
            allocator,
            "{{\"name\":\"ProjectedManagedRead\",\"vision\":\"Projected managed files must stay readable over control.mount_file_read\",\"activate\":false,\"desired_mounts\":[{{\"mount_path\":\"/nodes/local/fs\",\"node_id\":\"{s}\",\"export_name\":\"workspace\"}}]}}",
            .{node_registration.node_id},
        ),
        true,
    );
    defer allocator.free(project_up);
    const project_id = try extractInternalProjectIdForTests(allocator, project_up);
    defer allocator.free(project_id);

    var listener = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true });
    defer listener.deinit();

    var server_ctx = WsTestServerCtx{
        .allocator = allocator,
        .runtime_registry = &runtime_registry,
        .listener = &listener,
    };
    defer server_ctx.deinit();

    const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
    defer server_thread.join();

    var client = try std.net.tcpConnectToAddress(listener.listen_address);
    defer client.close();
    try performClientHandshakeWithBearerToken(allocator, &client, "/", "access-secret");

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"projected-version\",\"payload\":{\"protocol\":\"spiderweb-control\"}}");
    var version_ack = try readServerFrame(allocator, &client);
    defer version_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, version_ack.payload, "\"type\":\"control.version_ack\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"projected-connect\"}");
    var connect_ack = try readServerFrame(allocator, &client);
    defer connect_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"type\":\"control.connect_ack\"") != null);

    const attach_payload = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"control\",\"type\":\"control.session_attach\",\"id\":\"projected-attach-session\",\"payload\":{{\"session_key\":\"fskit\",\"agent_id\":\"mount-agent\",\"workspace_id\":\"{s}\"}}}}",
        .{project_id},
    );
    defer allocator.free(attach_payload);
    try writeClientTextFrameMasked(&client, attach_payload);
    var attach_ack = try readServerFrame(allocator, &client);
    defer attach_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, attach_ack.payload, "\"type\":\"control.session_attach\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.mount_attach\",\"id\":\"projected-mount-attach\",\"payload\":{\"path\":\"/nodes/local/fs/.spiderweb\",\"depth\":2}}");
    var mount_attach_ack = try readServerFrame(allocator, &client);
    defer mount_attach_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, mount_attach_ack.payload, "\"type\":\"control.mount_attach\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.mount_file_read\",\"id\":\"projected-mount-read\",\"payload\":{\"path\":\"/nodes/local/fs/.spiderweb/protocol.json\",\"offset\":0,\"length\":256}}");
    var mount_read_ack = try readServerFrame(allocator, &client);
    defer mount_read_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, mount_read_ack.payload, "\"type\":\"control.mount_file_read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mount_read_ack.payload, "\"data_b64\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mount_read_ack.payload, "\"n\":0") == null);

    try websocket_transport.writeFrame(&client, "", .close);
    var close_reply = try readServerFrame(allocator, &client);
    defer close_reply.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0x8), close_reply.opcode);

    try std.testing.expect(server_ctx.err_name == null);
}
const SessionBinding = server_session_bindings.SessionBinding;
