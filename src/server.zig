const std = @import("std");
const builtin = @import("builtin");
const Config = @import("config.zig");
const connection_dispatcher = @import("connection_dispatcher.zig");
const protocol = @import("spider-protocol").protocol;
const runtime_handle_mod = @import("agents/runtime_handle.zig");
const websocket_transport = @import("websocket_transport.zig");
const control_plane_mod = @import("acheron/control_plane.zig");
const acheron_session_mod = @import("acheron/session.zig");
const fs_protocol = @import("spiderweb_fs").fs_protocol;
const spiderweb_node = @import("spiderweb_node");
const unified = @import("spider-protocol").unified;
const mission_store_mod = @import("mission_store.zig");
const default_max_agent_runtimes: usize = 64;
const max_agent_id_len: usize = 64;
const max_project_id_len: usize = 128;
const max_actor_type_len: usize = 64;
const max_actor_id_len: usize = 128;
const node_venom_event_history_max_default: usize = 1024;
const local_node_export_path_env = "SPIDERWEB_LOCAL_NODE_EXPORT_PATH";
const local_node_export_name_env = "SPIDERWEB_LOCAL_NODE_EXPORT_NAME";
const local_node_export_ro_env = "SPIDERWEB_LOCAL_NODE_EXPORT_RO";
const local_node_fs_url_env = "SPIDERWEB_LOCAL_NODE_FS_URL";
const local_node_name_env = "SPIDERWEB_LOCAL_NODE_NAME";
const local_node_lease_ttl_env = "SPIDERWEB_LOCAL_NODE_LEASE_TTL_MS";
const local_node_heartbeat_ms_env = "SPIDERWEB_LOCAL_NODE_HEARTBEAT_MS";
const local_node_watcher_enabled_env = "SPIDERWEB_LOCAL_NODE_WATCHER_ENABLED";
const local_node_supervisor_dirname = "local-node";
const local_node_state_filename = "state.json";
const local_node_manifests_dirname = "services.d";
const local_node_default_name = "spiderweb-local";
const local_node_service_binary_name = "spiderweb-local-service";
const local_node_ready_timeout_ms: u64 = 10_000;
const local_node_ready_poll_ms: u64 = 100;
const system_agent_id = "spiderweb";
const system_project_id = control_plane_mod.spider_web_project_id;
const legacy_local_node_mount_agents_self_capabilities = "/global/capabilities";
const legacy_local_node_mount_projects_system_agents_self_capabilities = "/nodes/local/projects/" ++ system_project_id ++ "/global/capabilities";
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

fn ensureDirectoryExists(dir_path: []const u8) !void {
    if (dir_path.len == 0) return error.InvalidPath;

    if (std.fs.path.isAbsolute(dir_path)) {
        var root_dir = try std.fs.openDirAbsolute("/", .{});
        defer root_dir.close();
        const rel_dir = std.mem.trimLeft(u8, dir_path, "/");
        if (rel_dir.len == 0) return;
        root_dir.makePath(rel_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        return;
    }

    std.fs.cwd().makePath(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

fn openFileReadWrite(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openFileAbsolute(path, .{ .mode = .read_write });
    }
    return std.fs.cwd().openFile(path, .{ .mode = .read_write });
}

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

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
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

fn resolveInternalWsClientHost(bind_addr: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, bind_addr, " \t\r\n");
    if (trimmed.len == 0) return "127.0.0.1";
    if (std.mem.eql(u8, trimmed, "0.0.0.0")) return "127.0.0.1";
    if (std.mem.eql(u8, trimmed, "::")) return "127.0.0.1";
    if (std.mem.eql(u8, trimmed, "[::]")) return "127.0.0.1";
    return trimmed;
}

fn formatInternalWsUrl(
    allocator: std.mem.Allocator,
    bind_addr: []const u8,
    port: u16,
    path: []const u8,
) ![]u8 {
    const host = resolveInternalWsClientHost(bind_addr);
    const is_ipv6_literal = std.mem.indexOfScalar(u8, host, ':') != null and
        !(host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']');
    if (is_ipv6_literal) {
        return std.fmt.allocPrint(allocator, "ws://[{s}]:{d}{s}", .{ host, port, path });
    }
    return std.fmt.allocPrint(allocator, "ws://{s}:{d}{s}", .{ host, port, path });
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

fn buildInternalNodeFsUrl(
    allocator: std.mem.Allocator,
    bind_addr: []const u8,
    port: u16,
    node_id: []const u8,
) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "/fs/node/{s}", .{node_id});
    defer allocator.free(path);
    return formatInternalWsUrl(allocator, bind_addr, port, path);
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

const ParsedWsUrl = struct {
    scheme: []const u8,
    authority: []const u8,
    path: []const u8,
};

fn parseWsUrlParts(url: []const u8) ?ParsedWsUrl {
    const scheme: []const u8 = if (std.mem.startsWith(u8, url, "ws://"))
        "ws"
    else if (std.mem.startsWith(u8, url, "wss://"))
        "wss"
    else
        return null;
    const prefix_len = scheme.len + 3;
    if (url.len <= prefix_len) return null;
    const rest = url[prefix_len..];
    const slash_idx = std.mem.indexOfScalar(u8, rest, '/') orelse {
        return .{ .scheme = scheme, .authority = rest, .path = "/" };
    };
    if (slash_idx == 0) return null;
    return .{
        .scheme = scheme,
        .authority = rest[0..slash_idx],
        .path = rest[slash_idx..],
    };
}

fn wsAuthorityHost(authority: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, authority, " \t\r\n");
    if (trimmed.len == 0) return trimmed;
    if (trimmed[0] == '[') {
        const closing = std.mem.indexOfScalar(u8, trimmed, ']') orelse return trimmed;
        if (closing <= 1) return "";
        return trimmed[1..closing];
    }
    const colon_idx = std.mem.lastIndexOfScalar(u8, trimmed, ':') orelse return trimmed;
    return trimmed[0..colon_idx];
}

fn wsAuthorityIsLocalOnly(authority: []const u8) bool {
    const host = wsAuthorityHost(authority);
    if (host.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (std.mem.eql(u8, host, "::1") or std.mem.eql(u8, host, "::")) return true;
    if (std.mem.eql(u8, host, "0.0.0.0")) return true;
    return std.mem.startsWith(u8, host, "127.");
}

fn rewriteLocalOnlyFsUrlForWorkspaceConnection(
    allocator: std.mem.Allocator,
    raw_fs_url: []const u8,
    connection_workspace_url: []const u8,
) ![]u8 {
    const fs_url = parseWsUrlParts(raw_fs_url) orelse return allocator.dupe(u8, raw_fs_url);
    if (!wsAuthorityIsLocalOnly(fs_url.authority)) return allocator.dupe(u8, raw_fs_url);

    const workspace_url = parseWsUrlParts(connection_workspace_url) orelse return allocator.dupe(u8, raw_fs_url);
    return std.fmt.allocPrint(
        allocator,
        "{s}://{s}{s}",
        .{ workspace_url.scheme, workspace_url.authority, fs_url.path },
    );
}

fn rewriteWorkspaceStatusFsUrls(
    allocator: std.mem.Allocator,
    workspace_json: []const u8,
    connection_workspace_url: ?[]const u8,
) ![]u8 {
    const workspace_url = connection_workspace_url orelse return allocator.dupe(u8, workspace_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, workspace_json, .{});
    defer parsed.deinit();
    const json_allocator = parsed.arena.allocator();
    if (parsed.value != .object) return allocator.dupe(u8, workspace_json);

    var rewrote_any = false;
    for ([_][]const u8{ "mounts", "desired_mounts", "actual_mounts" }) |field_name| {
        const mounts_value = parsed.value.object.getPtr(field_name) orelse continue;
        if (mounts_value.* != .array) continue;

        for (mounts_value.array.items) |*mount_value| {
            if (mount_value.* != .object) continue;
            const fs_url_value = mount_value.object.getPtr("fs_url") orelse continue;
            if (fs_url_value.* != .string) continue;

            const rewritten = try rewriteLocalOnlyFsUrlForWorkspaceConnection(
                allocator,
                fs_url_value.string,
                workspace_url,
            );
            defer allocator.free(rewritten);

            if (std.mem.eql(u8, rewritten, fs_url_value.string)) continue;
            fs_url_value.* = .{ .string = try json_allocator.dupe(u8, rewritten) };
            rewrote_any = true;
        }
    }

    if (!rewrote_any) return allocator.dupe(u8, workspace_json);
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(parsed.value, .{})});
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
    const rewritten = try rewriteWorkspaceStatusFsUrls(
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

fn resolveSiblingExecutablePath(allocator: std.mem.Allocator, executable_name: []const u8) ![]u8 {
    const self_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_path);
    const self_dir = std.fs.path.dirname(self_path) orelse return error.InvalidExecutablePath;

    const sibling = try std.fs.path.join(allocator, &.{ self_dir, executable_name });
    if (pathExists(sibling)) return sibling;
    allocator.free(sibling);

    return allocator.dupe(u8, executable_name);
}

fn deleteTreeIfPresent(dir_path: []const u8) !void {
    if (!pathExists(dir_path)) return;

    const parent = std.fs.path.dirname(dir_path) orelse return;
    const base = std.fs.path.basename(dir_path);
    if (base.len == 0) return;

    if (std.fs.path.isAbsolute(parent)) {
        var dir = std.fs.openDirAbsolute(parent, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close();
        try dir.deleteTree(base);
        return;
    }

    var dir = std.fs.cwd().openDir(parent, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();
    try dir.deleteTree(base);
}

fn writeFileReplacing(path: []const u8, data: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    const base = std.fs.path.basename(path);
    if (base.len == 0) return error.InvalidPath;
    try ensureDirectoryExists(parent);

    if (std.fs.path.isAbsolute(parent)) {
        var dir = try std.fs.openDirAbsolute(parent, .{});
        defer dir.close();
        var file = try dir.createFile(base, .{ .truncate = true });
        defer file.close();
        try file.writeAll(data);
        return;
    }

    var dir = try std.fs.cwd().openDir(parent, .{});
    defer dir.close();
    var file = try dir.createFile(base, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
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
    const control_cli_path = try resolveSiblingExecutablePath(allocator, "spiderweb-control");
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

const ControlMutationScope = enum {
    none,
    node,
    project,
    operator,
};

const AuditRecord = struct {
    id: u64,
    timestamp_ms: i64,
    agent_id: []u8,
    control_type: []u8,
    scope: ControlMutationScope,
    correlation_id: ?[]u8 = null,
    result: []u8,
    error_code: ?[]u8 = null,

    fn deinit(self: *AuditRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_id);
        allocator.free(self.control_type);
        if (self.correlation_id) |value| allocator.free(value);
        allocator.free(self.result);
        if (self.error_code) |value| allocator.free(value);
        self.* = undefined;
    }
};

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
    const raw = payload_json orelse return null;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidType;
    const auth_value = parsed.value.object.get("auth_token") orelse return null;
    if (auth_value != .string or auth_value.string.len == 0) return null;
    const copy = try allocator.dupe(u8, auth_value.string);
    return @as(?[]u8, copy);
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
    admin,
    user,
};

fn connectionRoleName(role: ConnectionRole) []const u8 {
    return switch (role) {
        .admin => "admin",
        .user => "user",
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

const SessionBinding = struct {
    agent_id: []u8,
    actor_type: []u8,
    actor_id: []u8,
    project_id: ?[]u8 = null,
    project_token: ?[]u8 = null,

    fn deinit(self: *SessionBinding, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_id);
        allocator.free(self.actor_type);
        allocator.free(self.actor_id);
        if (self.project_id) |value| allocator.free(value);
        if (self.project_token) |value| allocator.free(value);
        self.* = undefined;
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
        schema: u32 = 3,
        admin_token: []const u8,
        user_token: []const u8,
        admin_last_target: ?PersistedTarget = null,
        user_last_target: ?PersistedTarget = null,
        admin_session_history: ?[]PersistedSessionHistoryEntry = null,
        user_session_history: ?[]PersistedSessionHistoryEntry = null,
        updated_at_ms: i64,
    };

    allocator: std.mem.Allocator,
    path: ?[]u8 = null,
    admin_token: []u8,
    user_token: []u8,
    admin_last_target: ?RememberedTarget = null,
    user_last_target: ?RememberedTarget = null,
    admin_session_history: std.ArrayListUnmanaged(SessionHistoryEntry) = .{},
    user_session_history: std.ArrayListUnmanaged(SessionHistoryEntry) = .{},
    mutex: std.Thread.Mutex = .{},

    fn init(allocator: std.mem.Allocator, runtime_config: Config.RuntimeConfig) AuthTokenStore {
        var store = AuthTokenStore{
            .allocator = allocator,
            .admin_token = allocator.dupe(u8, "") catch @panic("oom"),
            .user_token = allocator.dupe(u8, "") catch @panic("oom"),
        };
        store.loadOrGenerate(runtime_config);
        return store;
    }

    fn deinit(self: *AuthTokenStore) void {
        if (self.path) |value| self.allocator.free(value);
        self.allocator.free(self.admin_token);
        self.allocator.free(self.user_token);
        if (self.admin_last_target) |*target| target.deinit(self.allocator);
        if (self.user_last_target) |*target| target.deinit(self.allocator);
        for (self.admin_session_history.items) |*entry| entry.deinit(self.allocator);
        self.admin_session_history.deinit(self.allocator);
        for (self.user_session_history.items) |*entry| entry.deinit(self.allocator);
        self.user_session_history.deinit(self.allocator);
        self.* = undefined;
    }

    fn authenticate(self: *const AuthTokenStore, authorization_header: ?[]const u8) ?ConnectionPrincipal {
        const raw = authorization_header orelse return null;
        const token = parseBearerToken(raw) orelse return null;
        const mutex = @constCast(&self.mutex);
        mutex.lock();
        defer mutex.unlock();
        if (secureTokenEql(self.admin_token, token)) return .{ .role = .admin, .token_id = "access" };
        // The old user token is now treated as the same effective access role.
        if (secureTokenEql(self.user_token, token)) return .{ .role = .admin, .token_id = "access-legacy-user" };
        return null;
    }

    fn rotateRoleToken(self: *AuthTokenStore, role: ConnectionRole) ![]u8 {
        const next = try makeOpaqueToken(self.allocator, switch (role) {
            .admin => "sw-admin",
            .user => "sw-user",
        });
        errdefer self.allocator.free(next);
        const replacement = try self.allocator.dupe(u8, next);
        errdefer self.allocator.free(replacement);

        self.mutex.lock();
        defer self.mutex.unlock();
        switch (role) {
            .admin => {
                const previous = self.admin_token;
                self.admin_token = replacement;
                self.persistCurrentStateLocked() catch |err| {
                    self.admin_token = previous;
                    self.allocator.free(replacement);
                    return err;
                };
                self.allocator.free(previous);
            },
            .user => {
                const previous = self.user_token;
                self.user_token = replacement;
                self.persistCurrentStateLocked() catch |err| {
                    self.user_token = previous;
                    self.allocator.free(replacement);
                    return err;
                };
                self.allocator.free(previous);
            },
        }
        return next;
    }

    fn rememberedTargetOwned(self: *const AuthTokenStore, role: ConnectionRole) !?RememberedTarget {
        const mutex = @constCast(&self.mutex);
        mutex.lock();
        defer mutex.unlock();
        const stored = switch (role) {
            .admin => self.admin_last_target,
            .user => self.user_last_target,
        } orelse return null;
        return .{
            .agent_id = try self.allocator.dupe(u8, stored.agent_id),
            .project_id = try self.allocator.dupe(u8, stored.project_id),
        };
    }

    fn setRememberedTarget(self: *AuthTokenStore, role: ConnectionRole, agent_id: []const u8, project_id: []const u8) !void {
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

        const slot = switch (role) {
            .admin => &self.admin_last_target,
            .user => &self.user_last_target,
        };
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
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot = switch (role) {
            .admin => &self.admin_last_target,
            .user => &self.user_last_target,
        };
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
        self.mutex.lock();
        defer self.mutex.unlock();

        const history = switch (role) {
            .admin => &self.admin_session_history,
            .user => &self.user_session_history,
        };

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

    fn sessionHistoryOwned(
        self: *AuthTokenStore,
        role: ConnectionRole,
        agent_id_filter: ?[]const u8,
        limit: usize,
    ) !std.ArrayListUnmanaged(SessionHistoryEntry) {
        var out = std.ArrayListUnmanaged(SessionHistoryEntry){};
        errdefer {
            for (out.items) |*entry| entry.deinit(self.allocator);
            out.deinit(self.allocator);
        }

        const effective_limit = if (limit == 0) @as(usize, 10) else limit;
        const mutex = &self.mutex;
        mutex.lock();
        defer mutex.unlock();
        const history = switch (role) {
            .admin => &self.admin_session_history,
            .user => &self.user_session_history,
        };
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

    fn latestSessionOwned(
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

    fn sessionLastActiveMs(self: *const AuthTokenStore, role: ConnectionRole, session_key: []const u8) ?i64 {
        const mutex = @constCast(&self.mutex);
        mutex.lock();
        defer mutex.unlock();
        const history = switch (role) {
            .admin => &self.admin_session_history,
            .user => &self.user_session_history,
        };
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
        const escaped_admin = try unified.jsonEscape(self.allocator, self.admin_token);
        defer self.allocator.free(escaped_admin);
        const escaped_user = try unified.jsonEscape(self.allocator, self.user_token);
        defer self.allocator.free(escaped_user);
        const path_json = if (self.path) |value| blk: {
            const escaped_path = try unified.jsonEscape(self.allocator, value);
            defer self.allocator.free(escaped_path);
            break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped_path});
        } else try self.allocator.dupe(u8, "null");
        defer self.allocator.free(path_json);
        const admin_target_json = if (self.admin_last_target) |target| blk: {
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
        defer self.allocator.free(admin_target_json);
        const user_target_json = if (self.user_last_target) |target| blk: {
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
        defer self.allocator.free(user_target_json);
        return std.fmt.allocPrint(
            self.allocator,
            "{{\"admin_token\":\"{s}\",\"user_token\":\"{s}\",\"path\":{s},\"admin_last_target\":{s},\"user_last_target\":{s}}}",
            .{
                escaped_admin,
                escaped_user,
                path_json,
                admin_target_json,
                user_target_json,
            },
        );
    }

    fn loadOrGenerate(self: *AuthTokenStore, runtime_config: Config.RuntimeConfig) void {
        const base_dir = std.mem.trim(u8, runtime_config.state_directory, " \t\r\n");
        const storage_dir = if (base_dir.len == 0) "." else base_dir;
        ensureDirectoryExists(storage_dir) catch {};
        self.path = std.fs.path.join(self.allocator, &.{ storage_dir, auth_tokens_filename }) catch null;

        if (self.path) |path| {
            const loaded = self.loadFromPath(path) catch false;
            if (loaded) return;
        }

        const generated_admin = makeOpaqueToken(self.allocator, "sw-admin") catch return;
        defer self.allocator.free(generated_admin);
        const generated_user = makeOpaqueToken(self.allocator, "sw-user") catch return;
        defer self.allocator.free(generated_user);
        const next_admin = self.allocator.dupe(u8, generated_admin) catch return;
        errdefer self.allocator.free(next_admin);
        const next_user = self.allocator.dupe(u8, generated_user) catch return;
        errdefer self.allocator.free(next_user);

        self.mutex.lock();
        defer self.mutex.unlock();
        const previous_admin = self.admin_token;
        const previous_user = self.user_token;
        self.admin_token = next_admin;
        self.user_token = next_user;
        self.allocator.free(previous_admin);
        self.allocator.free(previous_user);
        self.persistCurrentStateLocked() catch |err| {
            std.log.warn("failed to persist generated auth tokens: {s}", .{@errorName(err)});
        };

        std.log.warn("Generated Spiderweb auth tokens (save these now):", .{});
        std.log.warn("  admin: {s}", .{self.admin_token});
        std.log.warn("  user:  {s}", .{self.user_token});
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
        if (parsed.value.admin_token.len == 0 or parsed.value.user_token.len == 0) return false;
        const next_admin = try self.allocator.dupe(u8, parsed.value.admin_token);
        errdefer self.allocator.free(next_admin);
        const next_user = try self.allocator.dupe(u8, parsed.value.user_token);
        errdefer self.allocator.free(next_user);
        var next_admin_target = try copyPersistedTarget(self.allocator, parsed.value.admin_last_target);
        errdefer if (next_admin_target) |*target| target.deinit(self.allocator);
        var next_user_target = try copyPersistedTarget(self.allocator, parsed.value.user_last_target);
        errdefer if (next_user_target) |*target| target.deinit(self.allocator);
        var next_admin_history = try copyPersistedSessionHistory(
            self.allocator,
            parsed.value.admin_session_history,
        );
        errdefer deinitSessionHistoryList(self.allocator, &next_admin_history);
        var next_user_history = try copyPersistedSessionHistory(
            self.allocator,
            parsed.value.user_session_history,
        );
        errdefer deinitSessionHistoryList(self.allocator, &next_user_history);

        self.mutex.lock();
        defer self.mutex.unlock();
        const previous_admin = self.admin_token;
        const previous_user = self.user_token;
        var previous_admin_target = self.admin_last_target;
        var previous_user_target = self.user_last_target;
        var previous_admin_history = self.admin_session_history;
        var previous_user_history = self.user_session_history;
        self.admin_token = next_admin;
        self.user_token = next_user;
        self.admin_last_target = next_admin_target;
        self.user_last_target = next_user_target;
        self.admin_session_history = next_admin_history;
        self.user_session_history = next_user_history;
        self.allocator.free(previous_admin);
        self.allocator.free(previous_user);
        if (previous_admin_target) |*target| target.deinit(self.allocator);
        if (previous_user_target) |*target| target.deinit(self.allocator);
        deinitSessionHistoryList(self.allocator, &previous_admin_history);
        deinitSessionHistoryList(self.allocator, &previous_user_history);
        return true;
    }

    fn persistCurrentStateLocked(self: *AuthTokenStore) !void {
        const path = self.path orelse return error.AuthTokenPathUnavailable;
        const admin_history = try persistedSessionHistorySlice(
            self.allocator,
            self.admin_session_history.items,
        );
        defer if (admin_history) |value| self.allocator.free(value);
        const user_history = try persistedSessionHistorySlice(
            self.allocator,
            self.user_session_history.items,
        );
        defer if (user_history) |value| self.allocator.free(value);

        const payload = Persisted{
            .schema = 3,
            .admin_token = self.admin_token,
            .user_token = self.user_token,
            .admin_last_target = if (self.admin_last_target) |value| .{
                .agent_id = value.agent_id,
                .project_id = value.project_id,
            } else null,
            .user_last_target = if (self.user_last_target) |value| .{
                .agent_id = value.agent_id,
                .project_id = value.project_id,
            } else null,
            .admin_session_history = admin_history,
            .user_session_history = user_history,
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

    fn copyAdminToken(self: *AuthTokenStore) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.allocator.dupe(u8, self.admin_token);
    }

    fn copyUserToken(self: *AuthTokenStore) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.allocator.dupe(u8, self.user_token);
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
    missions: mission_store_mod.MissionStore,
    control_operator_token: ?[]u8 = null,
    control_project_scope_token: ?[]u8 = null,
    control_node_scope_token: ?[]u8 = null,
    local_node_supervisor: ?*LocalNodeSupervisor = null,
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
        var effective_default = allocator.dupe(u8, system_agent_id) catch @panic("OOM");
        if (configured_default.len > 0 and !isValidAgentId(configured_default)) {
            std.log.warn(
                "Invalid default_agent_id '{s}', falling back to '{s}'",
                .{ configured_default, system_agent_id },
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
                    .primary_agent_id = system_agent_id,
                    .spider_web_root = runtime_config.spider_web_root,
                    .node_venom_event_history_max = history_max,
                },
            ),
            .auth_tokens = AuthTokenStore.init(allocator, runtime_config),
            .missions = mission_store_mod.MissionStore.init(allocator, runtime_config),
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
        self.missions.deinit();
        self.allocator.free(self.default_agent_id);
    }

    fn authenticateConnection(self: *AgentRuntimeRegistry, authorization_header: ?[]const u8) ?ConnectionPrincipal {
        return self.auth_tokens.authenticate(authorization_header);
    }

    fn authStatusJson(self: *AgentRuntimeRegistry) ![]u8 {
        return self.auth_tokens.statusJson();
    }

    fn startLocalNodeSupervisor(self: *AgentRuntimeRegistry, bind_addr: []const u8, port: u16) !void {
        if (!self.runtime_config.local_node.enabled) return;

        self.mutex.lock();
        const existing = self.local_node_supervisor;
        self.mutex.unlock();
        if (existing != null) return;

        const control_auth_token = try self.auth_tokens.copyAdminToken();
        defer self.allocator.free(control_auth_token);

        const supervisor = try LocalNodeSupervisor.create(
            self.allocator,
            &self.control_plane,
            self.runtime_config,
            bind_addr,
            port,
            control_auth_token,
        );
        errdefer supervisor.deinit();
        try supervisor.start();

        self.pruneLegacySystemCapabilityMounts();

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

    fn rotateAuthToken(self: *AgentRuntimeRegistry, role: ConnectionRole) ![]u8 {
        return self.auth_tokens.rotateRoleToken(role);
    }

    const ConnectGateError = struct {
        code: []const u8,
        message: []const u8,
    };

    const InitialSessionBinding = struct {
        binding: SessionBinding,
        connect_gate_error: ?ConnectGateError = null,
        bootstrap_only: bool = false,
    };

    const ProjectSetupSnapshot = struct {
        vision: ?[]u8 = null,
        mount_count: usize = 0,

        fn deinit(self: *ProjectSetupSnapshot, allocator: std.mem.Allocator) void {
            if (self.vision) |value| allocator.free(value);
            self.* = undefined;
        }
    };

    const ProjectSetupHint = struct {
        required: bool = false,
        message: ?[]u8 = null,
        project_id: ?[]u8 = null,
        project_vision: ?[]u8 = null,

        fn deinit(self: *ProjectSetupHint, allocator: std.mem.Allocator) void {
            if (self.message) |value| allocator.free(value);
            if (self.project_id) |value| allocator.free(value);
            if (self.project_vision) |value| allocator.free(value);
            self.* = undefined;
        }
    };

    fn projectSetupSnapshot(self: *AgentRuntimeRegistry, project_id: []const u8, is_admin: bool) !ProjectSetupSnapshot {
        const escaped_project = try unified.jsonEscape(self.allocator, project_id);
        defer self.allocator.free(escaped_project);
        const payload = try std.fmt.allocPrint(self.allocator, "{{\"project_id\":\"{s}\"}}", .{escaped_project});
        defer self.allocator.free(payload);
        const project_json = try self.control_plane.getProjectWithRole(payload, is_admin);
        defer self.allocator.free(project_json);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, project_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;

        const vision_owned = if (parsed.value.object.get("vision")) |vision_val| blk: {
            if (vision_val != .string) break :blk null;
            if (vision_val.string.len == 0) break :blk null;
            break :blk try self.allocator.dupe(u8, vision_val.string);
        } else null;

        var mount_count: usize = 0;
        if (parsed.value.object.get("mounts")) |mounts_val| {
            if (mounts_val == .array) mount_count = mounts_val.array.items.len;
        }

        return .{
            .vision = vision_owned,
            .mount_count = mount_count,
        };
    }

    fn projectSetupHint(
        self: *AgentRuntimeRegistry,
        role: ConnectionRole,
        active_binding: SessionBinding,
        bootstrap_only: bool,
    ) !ProjectSetupHint {
        var hint = ProjectSetupHint{};
        errdefer hint.deinit(self.allocator);

        if (active_binding.project_id) |project_id| {
            hint.project_id = try self.allocator.dupe(u8, project_id);
        } else {
            return hint;
        }

        if (bootstrap_only and role == .admin) {
            hint.required = true;
            hint.message = try self.allocator.dupe(
                u8,
                "Workspace setup required: use spiderweb-control workspace_create, mount the workspace locally, then start Spider Monkey against that mounted folder.",
            );
            return hint;
        }

        const project_id = hint.project_id.?;
        if (std.mem.eql(u8, project_id, system_project_id)) return hint;

        var snapshot = self.projectSetupSnapshot(project_id, role == .admin) catch |err| {
            std.log.warn("failed to compute project setup snapshot for {s}: {s}", .{ project_id, @errorName(err) });
            return hint;
        };
        defer snapshot.deinit(self.allocator);

        if (snapshot.vision) |vision| {
            hint.project_vision = try self.allocator.dupe(u8, vision);
        }

        const vision_text = snapshot.vision orelse "";
        const vision_missing = std.mem.trim(u8, vision_text, " \t\r\n").len == 0;
        const mounts_missing = snapshot.mount_count == 0;
        const first_agent = self.firstAgentForProject(role, project_id);
        defer if (first_agent) |agent_id| self.allocator.free(agent_id);
        const agent_missing = first_agent == null;
        hint.required = vision_missing or mounts_missing or agent_missing;

        if (hint.required) {
            hint.message = if (agent_missing)
                try std.fmt.allocPrint(
                    self.allocator,
                    "Workspace setup required for {s}: attach an external worker to the mounted workspace.",
                    .{project_id},
                )
            else if (mounts_missing)
                try std.fmt.allocPrint(
                    self.allocator,
                    "Project setup required for {s}: no workspace mounts are configured yet.",
                    .{project_id},
                )
            else
                try std.fmt.allocPrint(
                    self.allocator,
                    "Project setup required for {s}: project vision is missing.",
                    .{project_id},
                );
        }

        return hint;
    }

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

    fn getRuntimeForBindingIfReady(
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

    fn publishVenomPresenceForBinding(
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

    fn hasNonSystemProject(self: *AgentRuntimeRegistry) bool {
        const payload = self.control_plane.listProjects() catch return false;
        defer self.allocator.free(payload);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        const projects = parsed.value.object.get("projects") orelse return false;
        if (projects != .array) return false;
        for (projects.array.items) |item| {
            if (item != .object) continue;
            const id_val = item.object.get("project_id") orelse continue;
            if (id_val != .string) continue;
            if (!std.mem.eql(u8, id_val.string, system_project_id)) return true;
        }
        return false;
    }

    fn isBootstrapOnlyState(self: *AgentRuntimeRegistry) bool {
        return !self.hasNonSystemProject();
    }

    fn firstAgentForProject(self: *AgentRuntimeRegistry, role: ConnectionRole, project_id: []const u8) ?[]u8 {
        const include_primary = role == .admin and std.mem.eql(u8, project_id, system_project_id);
        return self.control_plane.firstProjectAgent(project_id, include_primary) catch null;
    }

    fn resolvePreferredBindingForRole(self: *AgentRuntimeRegistry, role: ConnectionRole) !?SessionBinding {
        const is_admin = role == .admin;
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
                    if (role == .user and (std.mem.eql(u8, remembered.project_id, system_project_id) or std.mem.eql(u8, agent_id, system_agent_id))) {
                        self.allocator.free(agent_id);
                    } else {
                        return .{
                            .agent_id = agent_id,
                            .actor_type = try self.allocator.dupe(u8, defaultActorTypeForRole(role)),
                            .actor_id = try self.allocator.dupe(u8, connectionRoleName(role)),
                            .project_id = try self.allocator.dupe(u8, remembered.project_id),
                            .project_token = null,
                        };
                    }
                }
            } else {
                self.auth_tokens.clearRememberedTarget(role) catch {};
            }
        }

        return null;
    }

    fn buildInitialSessionBinding(self: *AgentRuntimeRegistry, role: ConnectionRole) !InitialSessionBinding {
        const bootstrap_only = self.isBootstrapOnlyState();
        if (try self.resolvePreferredBindingForRole(role)) |binding| {
            return .{
                .binding = binding,
                .bootstrap_only = bootstrap_only,
            };
        }

        return .{
            .binding = .{
                .agent_id = try self.allocator.dupe(u8, self.default_agent_id),
                .actor_type = try self.allocator.dupe(u8, defaultActorTypeForRole(role)),
                .actor_id = try self.allocator.dupe(u8, connectionRoleName(role)),
                .project_id = null,
                .project_token = null,
            },
            .connect_gate_error = .{
                .code = if (bootstrap_only) "provisioning_required" else "project_context_required",
                .message = if (bootstrap_only)
                    "no workspace is available; create one with spiderweb-control workspace_create, mount it, and start Spider Monkey"
                else
                    "workspace selection is required; call control.session_attach with workspace_id",
            },
            .bootstrap_only = bootstrap_only,
        };
    }

    fn rememberPrincipalSession(
        self: *AgentRuntimeRegistry,
        principal: ConnectionPrincipal,
        session_key: []const u8,
        agent_id: []const u8,
        project_id: ?[]const u8,
    ) void {
        const concrete_project = project_id orelse return;
        if (std.mem.eql(u8, concrete_project, system_project_id)) return;
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
            reconcileWorkerMain,
            .{self},
        );
    }

    fn startVenomPresenceWorker(self: *AgentRuntimeRegistry) !void {
        self.venom_presence_worker_mutex.lock();
        self.venom_presence_worker_stop = false;
        self.venom_presence_worker_mutex.unlock();
        self.venom_presence_worker_thread = try std.Thread.spawn(
            .{},
            servicePresenceWorkerMain,
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

        // Keep the reserved system runtime resident independently of active
        // workspace assignment so internal control-plane provisioning paths
        // remain available even when user-facing routes prefer mounted workspaces.
        if (self.control_plane.projectHasMounts(system_project_id)) {
            var system_attach_state = self.ensureRuntimeWarmup(
                system_agent_id,
                system_project_id,
                null,
                retry_on_error,
            ) catch |err| blk: {
                std.log.warn(
                    "system runtime residency warmup failed: agent={s} project={s} err={s}",
                    .{ system_agent_id, system_project_id, @errorName(err) },
                );
                break :blk null;
            };
            if (system_attach_state) |*attach_state| attach_state.deinit(self.allocator);
        }

        for (bindings) |binding| {
            if (!self.control_plane.projectHasMounts(binding.project_id)) continue;
            if (std.mem.eql(u8, binding.agent_id, system_agent_id) and
                !std.mem.eql(u8, binding.project_id, system_project_id))
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

    fn getOrCreate(
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

    fn touchRuntimeAttachState(self: *AgentRuntimeRegistry, agent_id: []const u8, project_id: ?[]const u8) void {
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

    fn beginRuntimeWarmupThread(self: *AgentRuntimeRegistry) !void {
        self.runtime_warmup_lifecycle_mutex.lock();
        defer self.runtime_warmup_lifecycle_mutex.unlock();
        if (self.runtime_warmup_stopping) return error.ShuttingDown;
        self.runtime_warmup_inflight += 1;
    }

    fn finishRuntimeWarmupThread(self: *AgentRuntimeRegistry) void {
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
        try self.beginRuntimeWarmupThread();
        errdefer self.finishRuntimeWarmupThread();

        const ctx = try self.allocator.create(RuntimeWarmupThreadContext);
        ctx.* = .{
            .allocator = self.allocator,
            .runtime_registry = self,
            .binding_key = null,
            .agent_id = null,
            .project_id = null,
            .project_token = null,
        };
        errdefer ctx.deinit();

        ctx.binding_key = try self.allocator.dupe(u8, binding_key);
        ctx.agent_id = try self.allocator.dupe(u8, agent_id);
        if (project_id) |value| {
            ctx.project_id = try self.allocator.dupe(u8, value);
        }
        if (project_token) |value| {
            ctx.project_token = try self.allocator.dupe(u8, value);
        }

        const thread = try std.Thread.spawn(.{}, runtimeWarmupThreadMain, .{ctx});
        thread.detach();
    }

    fn ensureRuntimeWarmup(
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

    fn getFirstAgentId(self: *AgentRuntimeRegistry) ?[]const u8 {
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

    fn appendAuditRecord(
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

    fn appendSecurityAuditAndDebug(
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

    fn buildAuditTailPayload(self: *AgentRuntimeRegistry, payload_json: ?[]const u8) ![]u8 {
        var limit: usize = 50;
        var filter_agent: ?[]const u8 = null;
        if (payload_json) |raw| {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{});
            defer parsed.deinit();
            if (parsed.value != .object) return error.InvalidPayload;
            if (parsed.value.object.get("limit")) |limit_val| {
                if (limit_val != .integer or limit_val.integer < 0) return error.InvalidPayload;
                limit = @intCast(limit_val.integer);
                if (limit > 500) limit = 500;
            }
            if (parsed.value.object.get("agent_id")) |agent_val| {
                if (agent_val != .string or agent_val.string.len == 0) return error.InvalidPayload;
                filter_agent = agent_val.string;
            }
        }

        self.audit_records_mutex.lock();
        defer self.audit_records_mutex.unlock();

        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "{\"audit\":[");

        var emitted: usize = 0;
        var idx = self.audit_records.items.len;
        while (idx > 0 and emitted < limit) {
            idx -= 1;
            const record = self.audit_records.items[idx];
            if (filter_agent) |agent| {
                if (!std.mem.eql(u8, agent, record.agent_id)) continue;
            }
            if (emitted != 0) try out.append(self.allocator, ',');
            emitted += 1;
            try appendAuditRecordJson(self.allocator, &out, record);
        }
        try out.appendSlice(self.allocator, "]}");
        return out.toOwnedSlice(self.allocator);
    }

    fn metricsJson(self: *AgentRuntimeRegistry) ![]u8 {
        return self.control_plane.metricsJson();
    }

    fn metricsPrometheus(self: *AgentRuntimeRegistry) ![]u8 {
        return self.control_plane.metricsPrometheus();
    }

    fn pruneLegacySystemCapabilityMounts(self: *AgentRuntimeRegistry) void {
        const legacy_paths = [_][]const u8{
            legacy_local_node_mount_agents_self_capabilities,
            legacy_local_node_mount_projects_system_agents_self_capabilities,
        };
        for (legacy_paths) |mount_path| {
            const escaped_project = unified.jsonEscape(self.allocator, system_project_id) catch continue;
            defer self.allocator.free(escaped_project);
            const escaped_mount = unified.jsonEscape(self.allocator, mount_path) catch continue;
            defer self.allocator.free(escaped_mount);
            const payload = std.fmt.allocPrint(
                self.allocator,
                "{{\"project_id\":\"{s}\",\"mount_path\":\"{s}\"}}",
                .{ escaped_project, escaped_mount },
            ) catch continue;
            defer self.allocator.free(payload);

            const result = self.control_plane.removeProjectMountWithRole(payload, true) catch |err| switch (err) {
                control_plane_mod.ControlPlaneError.MountNotFound => continue,
                else => {
                    std.log.warn(
                        "failed pruning legacy system mount {s}: {s}",
                        .{ mount_path, @errorName(err) },
                    );
                    continue;
                },
            };
            self.allocator.free(result);
            std.log.info("pruned legacy system mount path: {s}", .{mount_path});
        }
    }

};

const LocalNodeSupervisor = struct {
    allocator: std.mem.Allocator,
    control_plane: *control_plane_mod.ControlPlane,
    bind_addr: []u8,
    port: u16,
    control_url: []u8,
    control_auth_token: []u8,
    binary_path: []u8,
    service_binary_path: []u8,
    export_root: []u8,
    export_name: []u8,
    profile: []u8,
    state_dir: []u8,
    state_path: []u8,
    manifests_dir: []u8,
    extra_venoms_dir: ?[]u8 = null,
    restart_on_exit: bool,
    thread: ?std.Thread = null,
    mutex: std.Thread.Mutex = .{},
    stop_requested: bool = false,
    child_pid: ?std.process.Child.Id = null,

    fn create(
        allocator: std.mem.Allocator,
        control_plane: *control_plane_mod.ControlPlane,
        runtime_config: Config.RuntimeConfig,
        bind_addr: []const u8,
        port: u16,
        control_auth_token: []const u8,
    ) !*LocalNodeSupervisor {
        const local_cfg = runtime_config.local_node;
        const export_root_trimmed = runtime_config.effectiveLocalNodeExportPath();
        if (export_root_trimmed.len == 0) return error.InvalidArguments;

        const supervisor = try allocator.create(LocalNodeSupervisor);
        errdefer allocator.destroy(supervisor);

        const state_dir = try std.fs.path.join(allocator, &.{ runtime_config.state_directory, local_node_supervisor_dirname });
        errdefer allocator.free(state_dir);
        const state_path = try std.fs.path.join(allocator, &.{ state_dir, local_node_state_filename });
        errdefer allocator.free(state_path);
        const manifests_dir = try std.fs.path.join(allocator, &.{ state_dir, local_node_manifests_dirname });
        errdefer allocator.free(manifests_dir);

        supervisor.* = .{
            .allocator = allocator,
            .control_plane = control_plane,
            .bind_addr = try allocator.dupe(u8, bind_addr),
            .port = port,
            .control_url = try formatInternalWsUrl(allocator, bind_addr, port, "/"),
            .control_auth_token = try allocator.dupe(u8, control_auth_token),
            .binary_path = if (std.fs.path.isAbsolute(local_cfg.binary))
                try allocator.dupe(u8, local_cfg.binary)
            else
                try resolveSiblingExecutablePath(allocator, local_cfg.binary),
            .service_binary_path = try resolveSiblingExecutablePath(allocator, local_node_service_binary_name),
            .export_root = try allocator.dupe(u8, export_root_trimmed),
            .export_name = try allocator.dupe(u8, std.mem.trim(u8, local_cfg.export_name, " \t\r\n")),
            .profile = try allocator.dupe(u8, std.mem.trim(u8, local_cfg.profile, " \t\r\n")),
            .state_dir = state_dir,
            .state_path = state_path,
            .manifests_dir = manifests_dir,
            .extra_venoms_dir = blk: {
                const trimmed = std.mem.trim(u8, local_cfg.extra_venoms_dir, " \t\r\n");
                if (trimmed.len == 0) break :blk null;
                break :blk try allocator.dupe(u8, trimmed);
            },
            .restart_on_exit = local_cfg.restart_on_exit,
        };
        errdefer supervisor.deinit();

        if (supervisor.export_name.len == 0 or supervisor.profile.len == 0) return error.InvalidArguments;
        if (!std.mem.eql(u8, supervisor.profile, "external-agent-core")) {
            std.log.warn("unsupported runtime.local_node.profile '{s}', using external-agent-core only", .{supervisor.profile});
            return error.InvalidArguments;
        }
        return supervisor;
    }

    fn deinit(self: *LocalNodeSupervisor) void {
        if (self.thread != null) @panic("LocalNodeSupervisor.deinit called before join");
        self.allocator.free(self.bind_addr);
        self.allocator.free(self.control_url);
        self.allocator.free(self.control_auth_token);
        self.allocator.free(self.binary_path);
        self.allocator.free(self.service_binary_path);
        self.allocator.free(self.export_root);
        self.allocator.free(self.export_name);
        self.allocator.free(self.profile);
        self.allocator.free(self.state_dir);
        self.allocator.free(self.state_path);
        self.allocator.free(self.manifests_dir);
        if (self.extra_venoms_dir) |value| self.allocator.free(value);
        self.allocator.destroy(self);
    }

    fn start(self: *LocalNodeSupervisor) !void {
        if (self.thread != null) return;
        self.thread = try std.Thread.spawn(.{}, localNodeSupervisorMain, .{self});
    }

    fn join(self: *LocalNodeSupervisor) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn requestStop(self: *LocalNodeSupervisor) void {
        var child_to_kill: ?std.process.Child.Id = null;
        self.mutex.lock();
        self.stop_requested = true;
        child_to_kill = self.child_pid;
        self.mutex.unlock();
        if (child_to_kill) |child_id| terminateChildPid(child_id);
    }

    fn shouldStop(self: *LocalNodeSupervisor) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stop_requested;
    }

    fn setChildPid(self: *LocalNodeSupervisor, child_pid: ?std.process.Child.Id) void {
        self.mutex.lock();
        self.child_pid = child_pid;
        self.mutex.unlock();
    }

    fn prepareLaunch(self: *LocalNodeSupervisor) !void {
        try ensureDirectoryExists(self.state_dir);
        try deleteTreeIfPresent(self.manifests_dir);
        try ensureDirectoryExists(self.manifests_dir);
        const initial_join_payload = try self.control_plane.ensureNode(local_node_default_name, "", 15 * 60 * 1000);
        defer self.allocator.free(initial_join_payload);
        const node_id = try parseNodeIdFromJoinPayload(self.allocator, initial_join_payload);
        defer self.allocator.free(node_id);

        const routed_fs_url = try buildInternalNodeFsUrl(self.allocator, self.bind_addr, self.port, node_id);
        defer self.allocator.free(routed_fs_url);

        const join_payload = try self.control_plane.ensureNode(local_node_default_name, routed_fs_url, 15 * 60 * 1000);
        defer self.allocator.free(join_payload);
        try writeFileReplacing(self.state_path, join_payload);
        try self.control_plane.ensureSpiderWebMount(node_id, self.export_name);
        try self.writeManifestFiles();
    }

    fn writeManifestFiles(self: *LocalNodeSupervisor) !void {
        try self.writeManifestFile("terminal", "terminal");
        try self.writeManifestFile("git", "git");
        try self.writeManifestFile("search_code", "search_code");
    }

    fn writeManifestFile(self: *LocalNodeSupervisor, venom_id: []const u8, mode: []const u8) !void {
        const manifest_json = try self.buildManifestJson(venom_id, mode);
        defer self.allocator.free(manifest_json);
        const manifest_name = try std.fmt.allocPrint(self.allocator, "{s}.json", .{mode});
        defer self.allocator.free(manifest_name);
        const manifest_path = try std.fs.path.join(self.allocator, &.{ self.manifests_dir, manifest_name });
        defer self.allocator.free(manifest_path);
        try writeFileReplacing(manifest_path, manifest_json);
    }

    fn buildManifestJson(self: *LocalNodeSupervisor, venom_id: []const u8, mode: []const u8) ![]u8 {
        const escaped_exec = try unified.jsonEscape(self.allocator, self.service_binary_path);
        defer self.allocator.free(escaped_exec);
        const escaped_export_root = try unified.jsonEscape(self.allocator, self.export_root);
        defer self.allocator.free(escaped_export_root);
        const escaped_mode = try unified.jsonEscape(self.allocator, mode);
        defer self.allocator.free(escaped_mode);

        const kind: []const u8 = mode;
        const categories_json = if (std.mem.eql(u8, mode, "terminal"))
            "[\"terminal\",\"exec\"]"
        else if (std.mem.eql(u8, mode, "git"))
            "[\"developer\",\"scm\"]"
        else
            "[\"search\",\"code\"]";
        const requirements_json = if (std.mem.eql(u8, mode, "git"))
            "{\"host_capabilities\":[\"local_fs_export\"]}"
        else
            "{}";
        const capabilities_json = if (std.mem.eql(u8, mode, "terminal"))
            "{\"invoke\":true,\"discoverable\":true,\"operations\":[\"exec\"]}"
        else if (std.mem.eql(u8, mode, "git"))
            "{\"invoke\":true,\"discoverable\":true,\"operations\":[\"sync_checkout\",\"status\",\"diff_range\"]}"
        else
            "{\"invoke\":true,\"discoverable\":true,\"operations\":[\"search\"]}";
        const help_md = if (std.mem.eql(u8, mode, "terminal"))
            "Workspace terminal service backed by the supervised spiderweb-local-node process."
        else if (std.mem.eql(u8, mode, "git"))
            "Workspace git service backed by the supervised spiderweb-local-node process."
        else
            "Workspace code search service backed by the supervised spiderweb-local-node process.";
        const escaped_help = try unified.jsonEscape(self.allocator, help_md);
        defer self.allocator.free(escaped_help);
        const invoke_template_json = if (std.mem.eql(u8, mode, "terminal"))
            "{\"op\":\"exec\",\"arguments\":{\"command\":\"pwd\",\"cwd\":\"/nodes/local/fs\"}}"
        else if (std.mem.eql(u8, mode, "git"))
            "{\"op\":\"status\",\"arguments\":{\"checkout_path\":\"/nodes/local/fs\"}}"
        else
            "{\"op\":\"search\",\"arguments\":{\"query\":\"TODO\",\"path\":\"/nodes/local/fs\"}}";

        return std.fmt.allocPrint(
            self.allocator,
            "{{\"venom_id\":\"{s}\",\"package_id\":\"{s}\",\"kind\":\"{s}\",\"version\":\"1\",\"state\":\"online\",\"provider_scope\":\"node_export\",\"categories\":{s},\"hosts\":[\"node\"],\"projection_modes\":[\"node_export\",\"workspace_service\"],\"requirements\":{s},\"endpoints\":[\"/nodes/{{node_id}}/venoms/{s}\"],\"mounts\":[{{\"mount_id\":\"{s}\",\"mount_path\":\"/nodes/{{node_id}}/venoms/{s}\",\"state\":\"online\"}}],\"capabilities\":{s},\"ops\":{{\"model\":\"namespace\",\"invoke\":\"control/invoke.json\",\"paths\":{{\"invoke\":\"control/invoke.json\"}}}},\"runtime\":{{\"type\":\"native_proc\",\"abi\":\"namespace-driver-v1\",\"executable_path\":\"{s}\",\"args\":[\"{s}\",\"{s}\"],\"timeout_ms\":300000}},\"permissions\":{{\"default\":\"allow-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"scope\":\"project\"}},\"schema\":{{\"model\":\"namespace-mount\"}},\"invoke_template\":{s},\"help_md\":\"{s}\"}}",
            .{
                venom_id,
                venom_id,
                kind,
                categories_json,
                requirements_json,
                venom_id,
                venom_id,
                venom_id,
                capabilities_json,
                escaped_exec,
                escaped_mode,
                escaped_export_root,
                invoke_template_json,
                escaped_help,
            },
        );
    }

    fn buildArgv(self: *LocalNodeSupervisor, allocator: std.mem.Allocator) !std.ArrayListUnmanaged([]const u8) {
        var argv = std.ArrayListUnmanaged([]const u8){};
        errdefer argv.deinit(allocator);
        try argv.append(allocator, self.binary_path);
        try argv.appendSlice(allocator, &.{
            "--control-url",
            self.control_url,
            "--control-auth-token",
            self.control_auth_token,
            "--state-file",
            self.state_path,
            "--node-name",
            local_node_default_name,
        });
        const export_arg = try std.fmt.allocPrint(allocator, "{s}={s}:rw", .{ self.export_name, self.export_root });
        errdefer allocator.free(export_arg);
        try argv.append(allocator, "--export");
        try argv.append(allocator, export_arg);
        try argv.append(allocator, "--venoms-dir");
        try argv.append(allocator, self.manifests_dir);
        if (self.extra_venoms_dir) |extra_dir| {
            try argv.append(allocator, "--venoms-dir");
            try argv.append(allocator, extra_dir);
        }
        return argv;
    }
};

fn terminateChildPid(child_id: std.process.Child.Id) void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    std.posix.kill(child_id, std.posix.SIG.KILL) catch {};
}

fn parseNodeIdFromJoinPayload(allocator: std.mem.Allocator, payload_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    const node_id = parsed.value.object.get("node_id") orelse return error.MissingField;
    if (node_id != .string or node_id.string.len == 0) return error.InvalidPayload;
    return allocator.dupe(u8, node_id.string);
}

fn localNodeSupervisorMain(supervisor: *LocalNodeSupervisor) void {
    while (true) {
        if (supervisor.shouldStop()) return;

        supervisor.prepareLaunch() catch |err| {
            std.log.warn("local node supervisor prepare failed: {s}", .{@errorName(err)});
            if (supervisor.shouldStop()) return;
            std.Thread.sleep(500 * std.time.ns_per_ms);
            continue;
        };

        var argv = supervisor.buildArgv(supervisor.allocator) catch |err| {
            std.log.warn("local node supervisor argv failed: {s}", .{@errorName(err)});
            if (supervisor.shouldStop()) return;
            std.Thread.sleep(500 * std.time.ns_per_ms);
            continue;
        };
        defer {
            for (argv.items[0..]) |arg| {
                if (arg.ptr == supervisor.binary_path.ptr) continue;
                if (arg.ptr == supervisor.control_url.ptr) continue;
                if (arg.ptr == supervisor.control_auth_token.ptr) continue;
                if (arg.ptr == supervisor.state_path.ptr) continue;
                if (arg.ptr == supervisor.manifests_dir.ptr) continue;
                if (supervisor.extra_venoms_dir) |extra_dir| {
                    if (arg.ptr == extra_dir.ptr) continue;
                }
                if (arg.ptr == supervisor.export_name.ptr) continue;
                if (arg.ptr == supervisor.export_root.ptr) continue;
                if (std.mem.eql(u8, arg, "--control-url") or
                    std.mem.eql(u8, arg, "--control-auth-token") or
                    std.mem.eql(u8, arg, "--state-file") or
                    std.mem.eql(u8, arg, "--node-name") or
                    std.mem.eql(u8, arg, local_node_default_name) or
                    std.mem.eql(u8, arg, "--export") or
                    std.mem.eql(u8, arg, "--venoms-dir"))
                {
                    continue;
                }
                supervisor.allocator.free(arg);
            }
            argv.deinit(supervisor.allocator);
        }

        var child = std.process.Child.init(argv.items, supervisor.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        child.spawn() catch |err| {
            std.log.warn("local node supervisor spawn failed: {s}", .{@errorName(err)});
            if (supervisor.shouldStop()) return;
            std.Thread.sleep(500 * std.time.ns_per_ms);
            continue;
        };
        supervisor.setChildPid(child.id);

        const term = child.wait() catch |err| {
            supervisor.setChildPid(null);
            std.log.warn("local node supervisor wait failed: {s}", .{@errorName(err)});
            if (!supervisor.restart_on_exit or supervisor.shouldStop()) return;
            std.Thread.sleep(500 * std.time.ns_per_ms);
            continue;
        };
        supervisor.setChildPid(null);

        if (supervisor.shouldStop()) return;
        std.log.warn("local node exited: {s}", .{formatChildTerm(term)});
        if (!supervisor.restart_on_exit) return;
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }
}

fn formatChildTerm(term: std.process.Child.Term) []const u8 {
    return switch (term) {
        .Exited => "exited",
        .Signal => "signal",
        .Stopped => "stopped",
        .Unknown => "unknown",
    };
}

fn sessionAttachStateName(state: SessionAttachState) []const u8 {
    return switch (state) {
        .warming => "warming",
        .ready => "ready",
        .err => "error",
    };
}

const RuntimeWarmupThreadContext = struct {
    allocator: std.mem.Allocator,
    runtime_registry: *AgentRuntimeRegistry,
    binding_key: ?[]u8 = null,
    agent_id: ?[]u8 = null,
    project_id: ?[]u8 = null,
    project_token: ?[]u8 = null,

    fn deinit(self: *RuntimeWarmupThreadContext) void {
        if (self.binding_key) |value| self.allocator.free(value);
        if (self.agent_id) |value| self.allocator.free(value);
        if (self.project_id) |value| self.allocator.free(value);
        if (self.project_token) |value| self.allocator.free(value);
        self.allocator.destroy(self);
    }
};

fn runtimeWarmupThreadMain(ctx: *RuntimeWarmupThreadContext) void {
    defer ctx.deinit();
    defer ctx.runtime_registry.finishRuntimeWarmupThread();
    const binding_key = ctx.binding_key orelse return;
    const agent_id = ctx.agent_id orelse return;

    const runtime = ctx.runtime_registry.getOrCreate(
        agent_id,
        ctx.project_id,
        ctx.project_token,
    ) catch |err| {
        std.log.warn("runtime warmup thread failed: agent={s} project={s} err={s}", .{
            agent_id,
            ctx.project_id orelse "__auto__",
            @errorName(err),
        });
        const info = AgentRuntimeRegistry.mapRuntimeWarmupError(err);
        ctx.runtime_registry.markRuntimeWarmupError(
            binding_key,
            info.code,
            info.message,
        );
        return;
    };
    runtime.release();

    ctx.runtime_registry.markRuntimeWarmupReady(binding_key);
}

fn reconcileWorkerMain(runtime_registry: *AgentRuntimeRegistry) void {
    while (true) {
        if (runtime_registry.shouldStopReconcileWorker()) return;

        const maybe_payload = runtime_registry.control_plane.runReconcileCycle(false) catch |err| {
            std.log.warn("control-plane reconcile worker error: {s}", .{@errorName(err)});
            if (runtime_registry.shouldStopReconcileWorker()) return;
            std.Thread.sleep(runtime_registry.reconcile_worker_interval_ms * std.time.ns_per_ms);
            continue;
        };
        if (maybe_payload) |payload| {
            defer runtime_registry.allocator.free(payload);
        }

        std.Thread.sleep(runtime_registry.reconcile_worker_interval_ms * std.time.ns_per_ms);
    }
}

fn servicePresenceWorkerMain(runtime_registry: *AgentRuntimeRegistry) void {
    while (true) {
        runtime_registry.venom_presence_worker_mutex.lock();
        while (runtime_registry.venom_presence_jobs.items.len == 0 and !runtime_registry.venom_presence_worker_stop) {
            runtime_registry.venom_presence_worker_cond.wait(&runtime_registry.venom_presence_worker_mutex);
        }
        if (runtime_registry.venom_presence_worker_stop and runtime_registry.venom_presence_jobs.items.len == 0) {
            runtime_registry.venom_presence_worker_mutex.unlock();
            return;
        }
        var job = runtime_registry.venom_presence_jobs.orderedRemove(0);
        runtime_registry.venom_presence_worker_mutex.unlock();
        defer job.deinit(runtime_registry.allocator);

        runtime_registry.dispatchRuntimeAgentControlForTarget(
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

pub fn run(
    allocator: std.mem.Allocator,
    bind_addr: []const u8,
    port: u16,
    runtime_config: Config.RuntimeConfig,
) !void {
    var runtime_registry = AgentRuntimeRegistry.init(allocator, runtime_config);
    defer runtime_registry.deinit();

    warnDeprecatedEmbeddedLocalNodeEnv(allocator);

    runtime_registry.workspace_url = try formatInternalWsUrl(allocator, bind_addr, port, "/");
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
                runMetricsHttpServer,
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
    defer deinitSessionBindings(allocator, &session_bindings);

    var initial_binding = try runtime_registry.buildInitialSessionBinding(principal.role);
    defer initial_binding.binding.deinit(allocator);
    var connect_gate_error = initial_binding.connect_gate_error;
    var bootstrap_only_mode = initial_binding.bootstrap_only;
    try upsertSessionBinding(
        allocator,
        &session_bindings,
        "main",
        initial_binding.binding.agent_id,
        defaultActorTypeForRole(principal.role),
        defaultActorIdForPrincipal(principal),
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
                        if (connect_gate_error != null and !isConnectGateExemptControlType(control_type)) {
                            const gate = connect_gate_error.?;
                            const response = try unified.buildControlError(
                                allocator,
                                parsed.id,
                                gate.code,
                                gate.message,
                            );
                            defer allocator.free(response);
                            try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                            continue;
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
                                const project_json = if (active_binding.project_id) |project_id| blk: {
                                    const escaped_project = try unified.jsonEscape(allocator, project_id);
                                    defer allocator.free(escaped_project);
                                    break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped_project});
                                } else try allocator.dupe(u8, "null");
                                defer allocator.free(project_json);
                                const workspace_json = try buildWorkspaceStatusPayloadForBinding(
                                    allocator,
                                    runtime_registry,
                                    active_binding,
                                    connection_workspace_url,
                                    principal.role == .admin,
                                );
                                defer allocator.free(workspace_json);
                                const payload = try std.fmt.allocPrint(
                                    allocator,
                                    "{{\"agent_id\":\"{s}\",\"project_id\":{s},\"workspace\":{s},\"session\":\"{s}\",\"protocol\":\"{s}\"}}",
                                    .{
                                        active_binding.agent_id,
                                        project_json,
                                        workspace_json,
                                        active_session_key,
                                        control_protocol_version,
                                    },
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
                                if (principal.role != .admin) {
                                    const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                    runtime_registry.appendSecurityAuditAndDebug(
                                        active_binding.agent_id,
                                        .metrics,
                                        principal.role,
                                        parsed.correlation_id orelse parsed.id,
                                        "metrics_forbidden",
                                        false,
                                        "forbidden",
                                        "operation requires admin token",
                                    );
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "forbidden",
                                        "operation requires admin token",
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
                                if (principal.role != .admin) {
                                    const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                    runtime_registry.appendSecurityAuditAndDebug(
                                        active_binding.agent_id,
                                        .auth_status,
                                        principal.role,
                                        parsed.correlation_id orelse parsed.id,
                                        "auth_status_forbidden",
                                        false,
                                        "forbidden",
                                        "operation requires admin token",
                                    );
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "forbidden",
                                        "operation requires admin token",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                }
                                const payload = try runtime_registry.authStatusJson();
                                defer allocator.free(payload);
                                const response = try unified.buildControlAck(
                                    allocator,
                                    .auth_status,
                                    parsed.id,
                                    payload,
                                );
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                            .auth_rotate => {
                                if (principal.role != .admin) {
                                    const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                    runtime_registry.appendSecurityAuditAndDebug(
                                        active_binding.agent_id,
                                        .auth_rotate,
                                        principal.role,
                                        parsed.correlation_id orelse parsed.id,
                                        "auth_rotate_forbidden",
                                        false,
                                        "forbidden",
                                        "operation requires admin token",
                                    );
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "forbidden",
                                        "operation requires admin token",
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
                                const role_name = getRequiredStringField(payload.value.object, "role") catch {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "missing_field",
                                        "role is required",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                const role: ConnectionRole = if (std.mem.eql(u8, role_name, "admin"))
                                    .admin
                                else if (std.mem.eql(u8, role_name, "user"))
                                    .user
                                else {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "invalid_payload",
                                        "role must be 'admin' or 'user'",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                const rotated = runtime_registry.rotateAuthToken(role) catch |err| {
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
                                    "{{\"role\":\"{s}\",\"token\":\"{s}\"}}",
                                    .{
                                        if (role == .admin) "admin" else "user",
                                        escaped_token,
                                    },
                                );
                                defer allocator.free(payload_json);
                                const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                runtime_registry.appendSecurityAuditAndDebug(
                                    active_binding.agent_id,
                                    .auth_rotate,
                                    principal.role,
                                    parsed.correlation_id orelse parsed.id,
                                    if (role == .admin) "auth_rotate_admin_success" else "auth_rotate_user_success",
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
                                var payload = try parseControlPayloadObject(allocator, parsed.payload_json);
                                defer payload.deinit();
                                if (payload.value != .object) {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "invalid_payload",
                                        "session_attach payload must be an object",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                }

                                const session_key = getRequiredStringField(payload.value.object, "session_key") catch {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "missing_field",
                                        "session_key is required",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                const attach_agent_id = getRequiredStringField(payload.value.object, "agent_id") catch {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "missing_field",
                                        "agent_id is required",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                const attach_project_id = getRequiredStringField(payload.value.object, "project_id") catch {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "missing_field",
                                        "project_id is required",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                var attach_project_token = getOptionalStringField(payload.value.object, "project_token");
                                const current_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                var previous_active_binding = try cloneSessionBinding(allocator, current_binding);
                                defer previous_active_binding.deinit(allocator);
                                const security_correlation = parsed.correlation_id orelse parsed.id;

                                if (!isValidSessionKey(session_key)) {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "invalid_payload",
                                        "invalid session_key",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                }
                                if (!AgentRuntimeRegistry.isValidAgentId(attach_agent_id)) {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "invalid_payload",
                                        "invalid agent_id",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                }
                                if (!AgentRuntimeRegistry.isValidProjectId(attach_project_id)) {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "invalid_payload",
                                        "invalid project_id",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                }

                                const existing_binding = session_bindings.get(session_key);
                                if (existing_binding != null and std.mem.eql(u8, existing_binding.?.agent_id, attach_agent_id) and attach_project_token == null) {
                                    attach_project_token = existing_binding.?.project_token;
                                }

                                if (principal.role == .user and std.mem.eql(u8, attach_agent_id, system_agent_id)) {
                                    runtime_registry.appendSecurityAuditAndDebug(
                                        current_binding.agent_id,
                                        .session_attach,
                                        principal.role,
                                        security_correlation,
                                        "session_attach_forbidden_system_agent",
                                        false,
                                        "forbidden",
                                        "user role cannot attach to reserved system agent",
                                    );
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "forbidden",
                                        "user role cannot attach to reserved system agent",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                }
                                if (principal.role == .user and std.mem.eql(u8, attach_project_id, system_project_id)) {
                                    runtime_registry.appendSecurityAuditAndDebug(
                                        current_binding.agent_id,
                                        .session_attach,
                                        principal.role,
                                        security_correlation,
                                        "session_attach_forbidden_system_project",
                                        false,
                                        "forbidden",
                                        "user role cannot attach to reserved system workspace",
                                    );
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "forbidden",
                                        "user role cannot attach to reserved system workspace",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                }
                                if (std.mem.eql(u8, attach_agent_id, system_agent_id) and
                                    !std.mem.eql(u8, attach_project_id, system_project_id))
                                {
                                    runtime_registry.appendSecurityAuditAndDebug(
                                        current_binding.agent_id,
                                        .session_attach,
                                        principal.role,
                                        security_correlation,
                                        "session_attach_forbidden_primary_project",
                                        false,
                                        "forbidden",
                                        "reserved system agent can only attach to the reserved system workspace",
                                    );
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "forbidden",
                                        "reserved system agent can only attach to the reserved system workspace",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                }
                                const rebind_requested = if (existing_binding) |binding|
                                    !std.mem.eql(u8, binding.agent_id, attach_agent_id) or
                                        !optionalStringsEqual(binding.project_id, attach_project_id)
                                else
                                    false;

                                _ = rebind_requested;

                                const activate_payload = try buildProjectActivatePayload(allocator, attach_project_id, attach_project_token);
                                defer allocator.free(activate_payload);
                                _ = runtime_registry.control_plane.activateProjectWithRole(
                                    attach_agent_id,
                                    activate_payload,
                                    principal.role == .admin,
                                ) catch |activate_err| {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        controlPlaneErrorCode(activate_err),
                                        @errorName(activate_err),
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };

                                const previous_session_key = try allocator.dupe(u8, active_session_key);
                                defer allocator.free(previous_session_key);
                                try upsertSessionBinding(
                                    allocator,
                                    &session_bindings,
                                    session_key,
                                    attach_agent_id,
                                    defaultActorTypeForRole(principal.role),
                                    defaultActorIdForPrincipal(principal),
                                    attach_project_id,
                                    attach_project_token,
                                );
                                allocator.free(active_session_key);
                                active_session_key = try allocator.dupe(u8, session_key);

                                const active_binding = session_bindings.get(session_key) orelse return error.InvalidState;
                                var attach_state = runtime_registry.ensureRuntimeWarmup(
                                    active_binding.agent_id,
                                    active_binding.project_id,
                                    active_binding.project_token,
                                    true,
                                ) catch |warm_err| {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "execution_failed",
                                        @errorName(warm_err),
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                // Keep session_attach responsive even when runtime warmup is in-flight.
                                // Clients can poll control.session_status for warmup progression.
                                defer attach_state.deinit(allocator);
                                const attach_json = try buildSessionAttachStateJson(allocator, attach_state);
                                defer allocator.free(attach_json);
                                const workspace_json = try buildWorkspaceStatusPayloadForBinding(
                                    allocator,
                                    runtime_registry,
                                    active_binding,
                                    connection_workspace_url,
                                    principal.role == .admin,
                                );
                                defer allocator.free(workspace_json);
                                const ack_payload = try buildSessionAttachAckPayload(
                                    allocator,
                                    session_key,
                                    active_binding.agent_id,
                                    active_binding.project_id,
                                    workspace_json,
                                    attach_json,
                                );
                                defer allocator.free(ack_payload);

                                const response = try unified.buildControlAck(
                                    allocator,
                                    .session_attach,
                                    parsed.id,
                                    ack_payload,
                                );
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                resetNamespaceSession(&namespace_session);
                                connect_gate_error = null;
                                bootstrap_only_mode = runtime_registry.isBootstrapOnlyState();
                                runtime_registry.rememberPrincipalSession(
                                    principal,
                                    session_key,
                                    active_binding.agent_id,
                                    active_binding.project_id,
                                );
                                if (control_service_attached) {
                                    const runtime_binding_changed = !std.mem.eql(u8, previous_active_binding.agent_id, active_binding.agent_id) or
                                        !optionalStringsEqual(previous_active_binding.project_id, active_binding.project_id);
                                    if (runtime_binding_changed) {
                                        runtime_registry.publishVenomPresenceForBinding(
                                            principal.role,
                                            previous_active_binding,
                                            previous_session_key,
                                            connection_venom_id,
                                            false,
                                        );
                                    }
                                    runtime_registry.publishVenomPresenceForBinding(
                                        principal.role,
                                        active_binding,
                                        session_key,
                                        connection_venom_id,
                                        true,
                                    );
                                }
                                continue;
                            },
                            .session_status => {
                                var payload = try parseControlPayloadObject(allocator, parsed.payload_json);
                                defer payload.deinit();
                                if (payload.value != .object) {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "invalid_payload",
                                        "session_status payload must be an object",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                }

                                const payload_session_key = getOptionalStringField(payload.value.object, "session_key");
                                const session_key = if (payload_session_key) |value| value else active_session_key;
                                const heartbeat = getOptionalBoolField(payload.value.object, "heartbeat") orelse false;
                                const binding = session_bindings.get(session_key) orelse {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "not_found",
                                        "session_key not found",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };

                                if (heartbeat) {
                                    runtime_registry.rememberPrincipalSession(
                                        principal,
                                        session_key,
                                        binding.agent_id,
                                        binding.project_id,
                                    );
                                    runtime_registry.touchRuntimeAttachState(binding.agent_id, binding.project_id);
                                }

                                var attach_state = runtime_registry.ensureRuntimeWarmup(
                                    binding.agent_id,
                                    binding.project_id,
                                    binding.project_token,
                                    false,
                                ) catch |warm_err| {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "execution_failed",
                                        @errorName(warm_err),
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                defer attach_state.deinit(allocator);

                                const attach_json = try buildSessionAttachStateJson(allocator, attach_state);
                                defer allocator.free(attach_json);
                                const now_ms = std.time.milliTimestamp();
                                const session_last_active_ms = runtime_registry.auth_tokens.sessionLastActiveMs(principal.role, session_key) orelse 0;
                                const session_stale = session_last_active_ms > 0 and (now_ms - session_last_active_ms) > session_heartbeat_ttl_ms;
                                const agent_last_heartbeat_ms = attach_state.updated_at_ms;
                                const agent_stale = agent_last_heartbeat_ms > 0 and (now_ms - agent_last_heartbeat_ms) > agent_heartbeat_ttl_ms;
                                const payload_json = try buildSessionStatusPayload(
                                    allocator,
                                    session_key,
                                    binding.agent_id,
                                    binding.project_id,
                                    attach_json,
                                    session_last_active_ms,
                                    session_stale,
                                    agent_last_heartbeat_ms,
                                    agent_stale,
                                );
                                defer allocator.free(payload_json);
                                const response = try unified.buildControlAck(
                                    allocator,
                                    .session_status,
                                    parsed.id,
                                    payload_json,
                                );
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
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
                                    principal.role == .admin,
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
                                    principal.role == .admin,
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
                                    principal.role == .admin,
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
                                    principal.role == .admin,
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
                                    principal.role == .admin,
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
                                    principal.role == .admin,
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
                                    principal.role == .admin,
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
                                    principal.role == .admin,
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
                                    principal.role == .admin,
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
                                    principal.role == .admin,
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
                                    principal.role == .admin,
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
                                    principal.role == .admin,
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
                                    principal.role == .admin,
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
                                    principal.role == .admin,
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
                                    principal.role == .admin,
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
                                var payload = try parseControlPayloadObject(allocator, parsed.payload_json);
                                defer payload.deinit();
                                if (payload.value != .object) {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "invalid_payload",
                                        "session_resume payload must be an object",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                }
                                const session_key = getRequiredStringField(payload.value.object, "session_key") catch {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "missing_field",
                                        "session_key is required",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                const binding = session_bindings.get(session_key) orelse {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "not_found",
                                        "session_key not found",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };

                                const previous_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                const previous_session_key = try allocator.dupe(u8, active_session_key);
                                defer allocator.free(previous_session_key);
                                allocator.free(active_session_key);
                                active_session_key = try allocator.dupe(u8, session_key);
                                var attach_state = runtime_registry.ensureRuntimeWarmup(
                                    binding.agent_id,
                                    binding.project_id,
                                    binding.project_token,
                                    true,
                                ) catch |warm_err| {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "execution_failed",
                                        @errorName(warm_err),
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                defer attach_state.deinit(allocator);
                                const attach_json = try buildSessionAttachStateJson(allocator, attach_state);
                                defer allocator.free(attach_json);
                                const workspace_json = try buildWorkspaceStatusPayloadForBinding(
                                    allocator,
                                    runtime_registry,
                                    binding,
                                    connection_workspace_url,
                                    principal.role == .admin,
                                );
                                defer allocator.free(workspace_json);
                                const ack_payload = try buildSessionAttachAckPayload(
                                    allocator,
                                    session_key,
                                    binding.agent_id,
                                    binding.project_id,
                                    workspace_json,
                                    attach_json,
                                );
                                defer allocator.free(ack_payload);

                                const response = try unified.buildControlAck(
                                    allocator,
                                    .session_resume,
                                    parsed.id,
                                    ack_payload,
                                );
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                resetNamespaceSession(&namespace_session);
                                runtime_registry.rememberPrincipalSession(
                                    principal,
                                    session_key,
                                    binding.agent_id,
                                    binding.project_id,
                                );
                                if (control_service_attached) {
                                    const runtime_binding_changed = !std.mem.eql(u8, previous_binding.agent_id, binding.agent_id) or
                                        !optionalStringsEqual(previous_binding.project_id, binding.project_id);
                                    if (runtime_binding_changed) {
                                        runtime_registry.publishVenomPresenceForBinding(
                                            principal.role,
                                            previous_binding,
                                            previous_session_key,
                                            connection_venom_id,
                                            false,
                                        );
                                    }
                                    runtime_registry.publishVenomPresenceForBinding(
                                        principal.role,
                                        binding,
                                        session_key,
                                        connection_venom_id,
                                        true,
                                    );
                                }
                                continue;
                            },
                            .session_list => {
                                const payload_json = try buildSessionListPayload(allocator, &session_bindings, active_session_key);
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
                                var payload = try parseControlPayloadObject(allocator, parsed.payload_json);
                                defer payload.deinit();
                                if (payload.value != .object) {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "invalid_payload",
                                        "session_restore payload must be an object",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                }
                                const agent_filter = getOptionalStringField(payload.value.object, "agent_id");
                                var restored = try runtime_registry.auth_tokens.latestSessionOwned(principal.role, agent_filter);
                                defer if (restored) |*entry| entry.deinit(allocator);

                                const payload_json = try buildSessionRestorePayload(allocator, restored);
                                defer allocator.free(payload_json);
                                const response = try unified.buildControlAck(
                                    allocator,
                                    .session_restore,
                                    parsed.id,
                                    payload_json,
                                );
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                            .session_history => {
                                var payload = try parseControlPayloadObject(allocator, parsed.payload_json);
                                defer payload.deinit();
                                if (payload.value != .object) {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "invalid_payload",
                                        "session_history payload must be an object",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                }
                                const agent_filter = getOptionalStringField(payload.value.object, "agent_id");
                                const limit = blk: {
                                    const value = payload.value.object.get("limit") orelse break :blk @as(usize, 10);
                                    if (value != .integer or value.integer < 0) {
                                        const response = try unified.buildControlError(
                                            allocator,
                                            parsed.id,
                                            "invalid_payload",
                                            "limit must be a non-negative integer",
                                        );
                                        defer allocator.free(response);
                                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                        continue;
                                    }
                                    if (value.integer > 100) break :blk @as(usize, 100);
                                    break :blk @as(usize, @intCast(value.integer));
                                };
                                var history = try runtime_registry.auth_tokens.sessionHistoryOwned(
                                    principal.role,
                                    agent_filter,
                                    limit,
                                );
                                defer {
                                    for (history.items) |*entry| entry.deinit(allocator);
                                    history.deinit(allocator);
                                }

                                const payload_json = try buildSessionHistoryPayload(allocator, history.items);
                                defer allocator.free(payload_json);
                                const response = try unified.buildControlAck(
                                    allocator,
                                    .session_history,
                                    parsed.id,
                                    payload_json,
                                );
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                continue;
                            },
                            .session_close => {
                                var payload = try parseControlPayloadObject(allocator, parsed.payload_json);
                                defer payload.deinit();
                                if (payload.value != .object) {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "invalid_payload",
                                        "session_close payload must be an object",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                }
                                const session_key = getRequiredStringField(payload.value.object, "session_key") catch {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "missing_field",
                                        "session_key is required",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                if (std.mem.eql(u8, session_key, "main")) {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "forbidden",
                                        "main session cannot be closed",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                }
                                var previous_active_binding: ?SessionBinding = null;
                                defer if (previous_active_binding) |*value| value.deinit(allocator);
                                var previous_active_session_key: ?[]u8 = null;
                                defer if (previous_active_session_key) |value| allocator.free(value);
                                if (control_service_attached and std.mem.eql(u8, active_session_key, session_key)) {
                                    const active_binding_before_close = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                    previous_active_binding = try cloneSessionBinding(allocator, active_binding_before_close);
                                    previous_active_session_key = try allocator.dupe(u8, active_session_key);
                                }
                                if (session_bindings.fetchRemove(session_key)) |removed| {
                                    allocator.free(removed.key);
                                    var binding = removed.value;
                                    binding.deinit(allocator);
                                } else {
                                    const response = try unified.buildControlError(
                                        allocator,
                                        parsed.id,
                                        "not_found",
                                        "session_key not found",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                }

                                if (std.mem.eql(u8, active_session_key, session_key)) {
                                    allocator.free(active_session_key);
                                    active_session_key = try allocator.dupe(u8, "main");
                                }
                                if (control_service_attached and previous_active_binding != null and previous_active_session_key != null) {
                                    const main_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                    const old_binding = previous_active_binding.?;
                                    const runtime_binding_changed = !std.mem.eql(u8, old_binding.agent_id, main_binding.agent_id) or
                                        !optionalStringsEqual(old_binding.project_id, main_binding.project_id);
                                    if (runtime_binding_changed) {
                                        runtime_registry.publishVenomPresenceForBinding(
                                            principal.role,
                                            old_binding,
                                            previous_active_session_key.?,
                                            connection_venom_id,
                                            false,
                                        );
                                    }
                                    runtime_registry.publishVenomPresenceForBinding(
                                        principal.role,
                                        main_binding,
                                        active_session_key,
                                        connection_venom_id,
                                        true,
                                    );
                                }

                                const payload_json = try std.fmt.allocPrint(
                                    allocator,
                                    "{{\"session_key\":\"{s}\",\"closed\":true,\"active_session\":\"{s}\"}}",
                                    .{ session_key, active_session_key },
                                );
                                defer allocator.free(payload_json);
                                const response = try unified.buildControlAck(
                                    allocator,
                                    .session_close,
                                    parsed.id,
                                    payload_json,
                                );
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                resetNamespaceSession(&namespace_session);
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
                            .agent_ensure,
                            .agent_list,
                            .agent_get,
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
                            .project_create,
                            .project_update,
                            .project_delete,
                            .project_list,
                            .project_get,
                            .project_mount_set,
                            .project_mount_remove,
                            .project_mount_list,
                            .project_token_rotate,
                            .project_token_revoke,
                            .project_activate,
                            .workspace_status,
                            .reconcile_status,
                            .workspace_up,
                            .project_up,
                            .audit_tail,
                            => {
                                const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
                                const control_agent_id = active_binding.agent_id;
                                const correlation_id = parsed.correlation_id orelse parsed.id;
                                if (principal.role == .user and isControlAdminOnly(control_type)) {
                                    runtime_registry.appendSecurityAuditAndDebug(
                                        control_agent_id,
                                        control_type,
                                        principal.role,
                                        correlation_id,
                                        "admin_only_forbidden",
                                        false,
                                        "forbidden",
                                        "operation requires admin token",
                                    );
                                    const response = try buildControlErrorWithCorrelation(
                                        allocator,
                                        parsed.id,
                                        correlation_id,
                                        "forbidden",
                                        "operation requires admin token",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                }
                                const scope = controlMutationScope(control_type);
                                if (scope != .none and correlation_id == null) {
                                    const response = try buildControlErrorWithCorrelation(
                                        allocator,
                                        parsed.id,
                                        null,
                                        "correlation_required",
                                        "missing correlation_id on mutating control operation",
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                }
                                if (scope != .none) {
                                    validateControlScopeTokens(allocator, runtime_registry, control_type, parsed.payload_json) catch |err| {
                                        const code = switch (err) {
                                            error.MissingField => "missing_field",
                                            error.InvalidPayload => "invalid_payload",
                                            else => "operator_auth_failed",
                                        };
                                        runtime_registry.appendAuditRecord(
                                            control_agent_id,
                                            control_type,
                                            scope,
                                            correlation_id,
                                            false,
                                            code,
                                        );
                                        const response = try buildControlErrorWithCorrelation(
                                            allocator,
                                            parsed.id,
                                            correlation_id,
                                            code,
                                            @errorName(err),
                                        );
                                        defer allocator.free(response);
                                        try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                        continue;
                                    };
                                }
                                const availability_before = runtime_registry.control_plane.availabilitySnapshot();
                                const payload_json = handleControlPlaneCommand(
                                    runtime_registry,
                                    control_type,
                                    control_agent_id,
                                    principal.role == .admin,
                                    parsed.payload_json,
                                    connection_workspace_url,
                                ) catch |err| {
                                    const code = controlPlaneErrorCode(err);
                                    if (scope != .none) {
                                        runtime_registry.appendAuditRecord(
                                            control_agent_id,
                                            control_type,
                                            scope,
                                            correlation_id,
                                            false,
                                            code,
                                        );
                                    }
                                    const response = try buildControlErrorWithCorrelation(
                                        allocator,
                                        parsed.id,
                                        correlation_id,
                                        code,
                                        @errorName(err),
                                    );
                                    defer allocator.free(response);
                                    try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                    continue;
                                };
                                defer allocator.free(payload_json);

                                if (scope != .none) {
                                    runtime_registry.appendAuditRecord(
                                        control_agent_id,
                                        control_type,
                                        scope,
                                        correlation_id,
                                        true,
                                        null,
                                    );
                                }

                                const response = try unified.buildControlAck(
                                    allocator,
                                    control_type,
                                    parsed.id,
                                    payload_json,
                                );
                                defer allocator.free(response);
                                try writeFrameLocked(stream, &connection_write_mutex, response, .text);
                                const availability_after = runtime_registry.control_plane.availabilitySnapshot();
                                const topology_mutation = isWorkspaceTopologyMutation(control_type);
                                const availability_changed = !control_plane_mod.ControlPlane.AvailabilitySnapshot.eql(
                                    availability_before,
                                    availability_after,
                                );
                                if (topology_mutation or availability_changed) {
                                    runtime_registry.control_plane.requestReconcile();
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
                                principal.role == .admin,
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

fn deinitSessionBindings(allocator: std.mem.Allocator, map: *std.StringHashMapUnmanaged(SessionBinding)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        var binding = entry.value_ptr.*;
        binding.deinit(allocator);
    }
    map.deinit(allocator);
    map.* = .{};
}

fn resetNamespaceSession(namespace_session: *?acheron_session_mod.Session) void {
    if (namespace_session.*) |*session| {
        session.deinit();
        namespace_session.* = null;
    }
}

fn getOrInitNamespaceSessionForBinding(
    allocator: std.mem.Allocator,
    namespace_session: *?acheron_session_mod.Session,
    runtime_registry: *AgentRuntimeRegistry,
    binding: SessionBinding,
    session_key: []const u8,
    trusted_namespace_mount_url: ?[]const u8,
    is_admin: bool,
) !*acheron_session_mod.Session {
    if (namespace_session.* == null) {
        namespace_session.* = try initNamespaceSessionForBinding(
            allocator,
            runtime_registry,
            binding,
            session_key,
            trusted_namespace_mount_url,
            is_admin,
        );
    }
    return &(namespace_session.*.?);
}

fn localFsExportRootForNamespace(runtime_config: Config.RuntimeConfig) ?[]const u8 {
    const trimmed = runtime_config.effectiveLocalNodeExportPath();
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "/")) return null;
    return trimmed;
}

fn initNamespaceSessionForBinding(
    allocator: std.mem.Allocator,
    runtime_registry: *AgentRuntimeRegistry,
    binding: SessionBinding,
    session_key: []const u8,
    trusted_namespace_mount_url: ?[]const u8,
    is_admin: bool,
) !acheron_session_mod.Session {
    const project_id = binding.project_id orelse return error.InvalidState;
    const runtime = runtime_registry.getRuntimeForBindingIfReady(binding.agent_id, binding.project_id) orelse
        try runtime_registry.getOrCreate(binding.agent_id, binding.project_id, binding.project_token);
    defer runtime.release();

    const namespace_auth_token = if (is_admin)
        try runtime_registry.auth_tokens.copyAdminToken()
    else
        try runtime_registry.auth_tokens.copyUserToken();
    defer allocator.free(namespace_auth_token);

    return acheron_session_mod.Session.initWithOptions(
        allocator,
        runtime,
        binding.agent_id,
        .{
            .project_id = project_id,
            .project_token = binding.project_token,
            .namespace_mount_url = trusted_namespace_mount_url orelse runtime_registry.workspace_url,
            .namespace_session_key = session_key,
            .agents_dir = runtime_registry.runtime_config.agents_dir,
            .assets_dir = runtime_registry.runtime_config.assets_dir,
            .projects_dir = "projects",
            .local_fs_export_root = localFsExportRootForNamespace(runtime_registry.runtime_config),
            .sandbox_mounts_root = runtime_registry.runtime_config.sandbox_mounts_root,
            .sandbox_launcher = runtime_registry.runtime_config.sandbox_launcher,
            .sandbox_fs_mount_bin = runtime_registry.runtime_config.sandbox_fs_mount_bin,
            .control_plane = &runtime_registry.control_plane,
            .mission_store = &runtime_registry.missions,
            .namespace_auth_token = namespace_auth_token,
            .control_operator_token = runtime_registry.control_operator_token,
            .actor_type = binding.actor_type,
            .actor_id = binding.actor_id,
            .is_admin = is_admin,
        },
    );
}

fn cloneSessionBinding(allocator: std.mem.Allocator, binding: SessionBinding) !SessionBinding {
    var out = SessionBinding{
        .agent_id = try allocator.dupe(u8, binding.agent_id),
        .actor_type = try allocator.dupe(u8, binding.actor_type),
        .actor_id = try allocator.dupe(u8, binding.actor_id),
        .project_id = null,
        .project_token = null,
    };
    errdefer out.deinit(allocator);
    if (binding.project_id) |value| out.project_id = try allocator.dupe(u8, value);
    if (binding.project_token) |value| out.project_token = try allocator.dupe(u8, value);
    return out;
}

fn upsertSessionBinding(
    allocator: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(SessionBinding),
    session_key: []const u8,
    agent_id: []const u8,
    actor_type: []const u8,
    actor_id: []const u8,
    project_id: ?[]const u8,
    project_token: ?[]const u8,
) !void {
    if (map.getPtr(session_key)) |existing| {
        const next_agent_id = try allocator.dupe(u8, agent_id);
        errdefer allocator.free(next_agent_id);
        const next_actor_type = try allocator.dupe(u8, actor_type);
        errdefer allocator.free(next_actor_type);
        const next_actor_id = try allocator.dupe(u8, actor_id);
        errdefer allocator.free(next_actor_id);
        const next_project_id: ?[]u8 = if (project_id) |value| try allocator.dupe(u8, value) else null;
        errdefer if (next_project_id) |value| allocator.free(value);
        const next_project_token: ?[]u8 = if (project_token) |value| try allocator.dupe(u8, value) else null;
        errdefer if (next_project_token) |value| allocator.free(value);

        existing.deinit(allocator);
        existing.* = .{
            .agent_id = next_agent_id,
            .actor_type = next_actor_type,
            .actor_id = next_actor_id,
            .project_id = next_project_id,
            .project_token = next_project_token,
        };
        return;
    }

    try map.put(
        allocator,
        try allocator.dupe(u8, session_key),
        .{
            .agent_id = try allocator.dupe(u8, agent_id),
            .actor_type = try allocator.dupe(u8, actor_type),
            .actor_id = try allocator.dupe(u8, actor_id),
            .project_id = if (project_id) |value| try allocator.dupe(u8, value) else null,
            .project_token = if (project_token) |value| try allocator.dupe(u8, value) else null,
        },
    );
}

fn isValidSessionKey(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |char| {
        if (std.ascii.isAlphanumeric(char)) continue;
        if (char == '-' or char == '_' or char == '.' or char == ':') continue;
        return false;
    }
    return true;
}

fn isValidActorType(value: []const u8) bool {
    if (value.len == 0 or value.len > max_actor_type_len) return false;
    for (value) |char| {
        if (std.ascii.isAlphanumeric(char)) continue;
        if (char == '_' or char == '-') continue;
        return false;
    }
    return true;
}

fn isValidActorId(value: []const u8) bool {
    if (value.len == 0 or value.len > max_actor_id_len) return false;
    for (value) |char| {
        if (std.ascii.isAlphanumeric(char)) continue;
        if (char == '_' or char == '-' or char == '.') continue;
        return false;
    }
    return true;
}

fn defaultActorTypeForRole(role: ConnectionRole) []const u8 {
    _ = role;
    return "user";
}

fn defaultActorIdForPrincipal(principal: ConnectionPrincipal) []const u8 {
    return principal.token_id;
}

fn parseControlPayloadObject(allocator: std.mem.Allocator, payload_json: ?[]const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, payload_json orelse "{}", .{});
}

fn getRequiredStringField(obj: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const value = obj.get(field) orelse return error.MissingField;
    if (value != .string or value.string.len == 0) return error.InvalidPayload;
    return value.string;
}

fn getRequiredStringFieldAllowEmpty(obj: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const value = obj.get(field) orelse return error.MissingField;
    if (value != .string) return error.InvalidPayload;
    return value.string;
}

fn getOptionalStringField(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = obj.get(field) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn getOptionalBoolField(obj: std.json.ObjectMap, field: []const u8) ?bool {
    const value = obj.get(field) orelse return null;
    if (value != .bool) return null;
    return value.bool;
}

fn getOptionalU64Field(obj: std.json.ObjectMap, field: []const u8) ?u64 {
    const value = obj.get(field) orelse return null;
    return switch (value) {
        .integer => if (value.integer >= 0) @intCast(value.integer) else null,
        else => null,
    };
}

fn getOptionalU32Field(obj: std.json.ObjectMap, field: []const u8) ?u32 {
    const value = obj.get(field) orelse return null;
    return switch (value) {
        .integer => if (value.integer >= 0 and value.integer <= std.math.maxInt(u32)) @intCast(value.integer) else null,
        else => null,
    };
}

fn getOptionalI64Field(obj: std.json.ObjectMap, field: []const u8) ?i64 {
    const value = obj.get(field) orelse return null;
    return switch (value) {
        .integer => if (value.integer >= std.math.minInt(i64) and value.integer <= std.math.maxInt(i64)) @intCast(value.integer) else null,
        else => null,
    };
}

fn decodeStandardBase64Owned(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, encoded);
    return decoded;
}

fn materializeMountGraphWriteData(
    allocator: std.mem.Allocator,
    existing: ?[]const u8,
    offset: u64,
    data: []const u8,
    truncate_to_size: ?u64,
) ![]u8 {
    const base = if (truncate_to_size) |requested_size| blk: {
        const target_size = std.math.cast(usize, requested_size) orelse return error.InvalidOffset;
        if (target_size > max_mount_graph_materialized_file_bytes) return error.WriteTooLarge;

        const current = existing orelse return error.FileNotFound;
        var truncated = try allocator.alloc(u8, target_size);
        errdefer allocator.free(truncated);
        if (target_size > 0) {
            @memset(truncated, 0);
            const copy_len = @min(current.len, target_size);
            if (copy_len > 0) @memcpy(truncated[0..copy_len], current[0..copy_len]);
        }
        break :blk truncated;
    } else try allocator.dupe(u8, existing orelse "");
    errdefer allocator.free(base);

    if (base.len > max_mount_graph_materialized_file_bytes) return error.WriteTooLarge;
    if (data.len == 0) return base;

    const range = try validateMountGraphWriteRange(offset, data.len);
    if (range.write_end <= base.len) {
        @memcpy(base[range.base_offset..range.write_end], data);
        return base;
    }

    const merged_len = range.write_end;
    var merged = try allocator.alloc(u8, merged_len);
    errdefer allocator.free(merged);
    @memset(merged, 0);
    if (base.len > 0) {
        @memcpy(merged[0..base.len], base);
    }
    @memcpy(merged[range.base_offset..range.write_end], data);
    allocator.free(base);
    return merged;
}

fn validateMountGraphWriteRange(offset: u64, data_len: usize) !struct {
    base_offset: usize,
    write_end: usize,
} {
    const base_offset = std.math.cast(usize, offset) orelse return error.InvalidOffset;
    const write_end = std.math.add(usize, base_offset, data_len) catch return error.InvalidOffset;
    if (write_end > max_mount_graph_materialized_file_bytes) return error.WriteTooLarge;
    return .{
        .base_offset = base_offset,
        .write_end = write_end,
    };
}

fn mountGraphWriteResponseCount(request_bytes: usize) !u32 {
    return std.math.cast(u32, request_bytes) orelse error.InvalidPayload;
}

fn encodeStandardBase64Owned(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(data.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, data);
    return encoded;
}

fn handleMountAttachControl(
    allocator: std.mem.Allocator,
    runtime_registry: *AgentRuntimeRegistry,
    namespace_session: *?acheron_session_mod.Session,
    binding: SessionBinding,
    session_key: []const u8,
    trusted_namespace_mount_url: ?[]const u8,
    connection_workspace_url: ?[]const u8,
    is_admin: bool,
    payload_json: ?[]const u8,
) ![]u8 {
    var payload = try parseControlPayloadObject(allocator, payload_json);
    defer payload.deinit();
    if (payload.value != .object) return error.InvalidPayload;

    const requested_path = getOptionalStringField(payload.value.object, "path") orelse "/";
    const requested_depth = getOptionalU32Field(payload.value.object, "depth") orelse 1;
    const session = try getOrInitNamespaceSessionForBinding(
        allocator,
        namespace_session,
        runtime_registry,
        binding,
        session_key,
        trusted_namespace_mount_url,
        is_admin,
    );
    const workspace_json = try buildWorkspaceStatusPayloadForBinding(
        allocator,
        runtime_registry,
        binding,
        connection_workspace_url,
        is_admin,
    );
    defer allocator.free(workspace_json);
    return session.buildMountGraphSnapshotPayloadForPath(
        workspace_json,
        session_key,
        requested_path,
        requested_depth,
    );
}

fn handleMountFileReadControl(
    allocator: std.mem.Allocator,
    runtime_registry: *AgentRuntimeRegistry,
    namespace_session: *?acheron_session_mod.Session,
    binding: SessionBinding,
    session_key: []const u8,
    trusted_namespace_mount_url: ?[]const u8,
    is_admin: bool,
    payload_json: ?[]const u8,
) ![]u8 {
    var payload = try parseControlPayloadObject(allocator, payload_json);
    defer payload.deinit();
    if (payload.value != .object) return error.InvalidPayload;

    const absolute_path = try getRequiredStringField(payload.value.object, "path");
    const offset = getOptionalU64Field(payload.value.object, "offset") orelse 0;
    const requested_length_field = getOptionalU32Field(payload.value.object, "length");
    const requested_length = clampMountGraphReadLength(
        offset,
        requested_length_field,
    ) catch |err| switch (err) {
        error.InvalidOffset => return err,
    };

    const session = try getOrInitNamespaceSessionForBinding(
        allocator,
        namespace_session,
        runtime_registry,
        binding,
        session_key,
        trusted_namespace_mount_url,
        is_admin,
    );
    const chunk = try session.readMountGraphFile(absolute_path, offset, requested_length);
    defer allocator.free(chunk);

    const encoded = try encodeStandardBase64Owned(allocator, chunk);
    defer allocator.free(encoded);
    const escaped_path = try unified.jsonEscape(allocator, absolute_path);
    defer allocator.free(escaped_path);
    const count = try mountGraphWriteResponseCount(chunk.len);
    const eof = mountGraphReadIsEof(offset, requested_length_field, requested_length, chunk.len);

    return std.fmt.allocPrint(
        allocator,
        "{{\"path\":\"{s}\",\"offset\":{d},\"n\":{d},\"eof\":{},\"data_b64\":\"{s}\"}}",
        .{ escaped_path, offset, count, eof, encoded },
    );
}

fn clampMountGraphReadLength(offset: u64, requested_length: ?u32) !u32 {
    const materialized_limit_u64: u64 = max_mount_graph_materialized_file_bytes;
    if (offset > materialized_limit_u64) return error.InvalidOffset;

    const base_offset = std.math.cast(usize, offset) orelse return error.InvalidOffset;
    const remaining = max_mount_graph_materialized_file_bytes - base_offset;
    const max_length = std.math.cast(u32, remaining) orelse return error.InvalidOffset;
    return if (requested_length) |value| @min(value, max_length) else max_length;
}

fn mountGraphReadIsEof(offset: u64, requested_length_field: ?u32, requested_length: u32, chunk_len: usize) bool {
    if (chunk_len < requested_length) return true;
    if (requested_length != 0) return false;

    const materialized_limit_u64: u64 = max_mount_graph_materialized_file_bytes;
    const requested_some_bytes = requested_length_field == null or requested_length_field.? > 0;
    return offset == materialized_limit_u64 and requested_some_bytes;
}

fn handleMountFileWriteControl(
    allocator: std.mem.Allocator,
    runtime_registry: *AgentRuntimeRegistry,
    namespace_session: *?acheron_session_mod.Session,
    binding: SessionBinding,
    session_key: []const u8,
    trusted_namespace_mount_url: ?[]const u8,
    is_admin: bool,
    payload_json: ?[]const u8,
) ![]u8 {
    var payload = try parseControlPayloadObject(allocator, payload_json);
    defer payload.deinit();
    if (payload.value != .object) return error.InvalidPayload;

    const absolute_path = try getRequiredStringField(payload.value.object, "path");
    const data_b64 = try getRequiredStringFieldAllowEmpty(payload.value.object, "data_b64");
    const offset = getOptionalU64Field(payload.value.object, "offset") orelse 0;
    const truncate_to_size = getOptionalU64Field(payload.value.object, "truncate_to_size");
    const decoded = try decodeStandardBase64Owned(allocator, data_b64);
    defer allocator.free(decoded);

    const session = try getOrInitNamespaceSessionForBinding(
        allocator,
        namespace_session,
        runtime_registry,
        binding,
        session_key,
        trusted_namespace_mount_url,
        is_admin,
    );
    const existing = try session.tryReadInternalPath(absolute_path);
    defer if (existing) |value| allocator.free(value);
    const merged = try materializeMountGraphWriteData(allocator, existing, offset, decoded, truncate_to_size);
    defer allocator.free(merged);

    if (existing == null and try session.tryWriteLocalFsBackedMountFile(absolute_path, merged)) {
        const escaped_path = try unified.jsonEscape(allocator, absolute_path);
        defer allocator.free(escaped_path);
        const count = try mountGraphWriteResponseCount(decoded.len);
        return std.fmt.allocPrint(
            allocator,
            "{{\"path\":\"{s}\",\"offset\":{d},\"n\":{d}}}",
            .{ escaped_path, offset, count },
        );
    }

    if (try session.tryWriteBoundVenomProxyMountFile(absolute_path, merged)) {
        const escaped_path = try unified.jsonEscape(allocator, absolute_path);
        defer allocator.free(escaped_path);
        const count = try mountGraphWriteResponseCount(decoded.len);
        return std.fmt.allocPrint(
            allocator,
            "{{\"path\":\"{s}\",\"offset\":{d},\"n\":{d}}}",
            .{ escaped_path, offset, count },
        );
    }

    try session.writeMountGraphFile(absolute_path, merged);

    const escaped_path = try unified.jsonEscape(allocator, absolute_path);
    defer allocator.free(escaped_path);
    const count = try mountGraphWriteResponseCount(decoded.len);
    return std.fmt.allocPrint(
        allocator,
        "{{\"path\":\"{s}\",\"offset\":{d},\"n\":{d}}}",
        .{ escaped_path, offset, count },
    );
}

fn handleMountPathControl(
    allocator: std.mem.Allocator,
    runtime_registry: *AgentRuntimeRegistry,
    namespace_session: *?acheron_session_mod.Session,
    binding: SessionBinding,
    session_key: []const u8,
    trusted_namespace_mount_url: ?[]const u8,
    is_admin: bool,
    payload_json: ?[]const u8,
    control_type: unified.ControlType,
) ![]u8 {
    var payload = try parseControlPayloadObject(allocator, payload_json);
    defer payload.deinit();
    if (payload.value != .object) return error.InvalidPayload;

    const session = try getOrInitNamespaceSessionForBinding(
        allocator,
        namespace_session,
        runtime_registry,
        binding,
        session_key,
        trusted_namespace_mount_url,
        is_admin,
    );

    switch (control_type) {
        .mount_path_readlink => {
            const absolute_path = try getRequiredStringField(payload.value.object, "path");
            const target = (try session.tryReadlinkLocalFsBackedMountPath(absolute_path)) orelse return error.OperationNotSupported;
            defer allocator.free(target);
            const escaped_path = try unified.jsonEscape(allocator, absolute_path);
            defer allocator.free(escaped_path);
            const escaped_target = try unified.jsonEscape(allocator, target);
            defer allocator.free(escaped_target);
            return std.fmt.allocPrint(
                allocator,
                "{{\"path\":\"{s}\",\"target\":\"{s}\"}}",
                .{ escaped_path, escaped_target },
            );
        },
        .mount_path_mkdir => {
            const absolute_path = try getRequiredStringField(payload.value.object, "path");
            if (!(try session.tryMkdirLocalFsBackedMountPath(absolute_path))) return error.OperationNotSupported;
            const escaped_path = try unified.jsonEscape(allocator, absolute_path);
            defer allocator.free(escaped_path);
            return std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\"}}", .{escaped_path});
        },
        .mount_path_unlink => {
            const absolute_path = try getRequiredStringField(payload.value.object, "path");
            if (!(try session.tryUnlinkLocalFsBackedMountPath(absolute_path))) return error.OperationNotSupported;
            const escaped_path = try unified.jsonEscape(allocator, absolute_path);
            defer allocator.free(escaped_path);
            return std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\"}}", .{escaped_path});
        },
        .mount_path_rmdir => {
            const absolute_path = try getRequiredStringField(payload.value.object, "path");
            if (!(try session.tryRmdirLocalFsBackedMountPath(absolute_path))) return error.OperationNotSupported;
            const escaped_path = try unified.jsonEscape(allocator, absolute_path);
            defer allocator.free(escaped_path);
            return std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\"}}", .{escaped_path});
        },
        .mount_path_rename => {
            const old_path = try getRequiredStringField(payload.value.object, "old_path");
            const new_path = try getRequiredStringField(payload.value.object, "new_path");
            if (!(try session.tryRenameLocalFsBackedMountPath(old_path, new_path))) return error.OperationNotSupported;
            const escaped_old_path = try unified.jsonEscape(allocator, old_path);
            defer allocator.free(escaped_old_path);
            const escaped_new_path = try unified.jsonEscape(allocator, new_path);
            defer allocator.free(escaped_new_path);
            return std.fmt.allocPrint(
                allocator,
                "{{\"old_path\":\"{s}\",\"new_path\":\"{s}\"}}",
                .{ escaped_old_path, escaped_new_path },
            );
        },
        .mount_path_symlink => {
            const target = try getRequiredStringField(payload.value.object, "target");
            const link_path = try getRequiredStringField(payload.value.object, "link_path");
            if (!(try session.trySymlinkLocalFsBackedMountPath(target, link_path))) return error.OperationNotSupported;
            const escaped_target = try unified.jsonEscape(allocator, target);
            defer allocator.free(escaped_target);
            const escaped_link_path = try unified.jsonEscape(allocator, link_path);
            defer allocator.free(escaped_link_path);
            return std.fmt.allocPrint(
                allocator,
                "{{\"target\":\"{s}\",\"link_path\":\"{s}\"}}",
                .{ escaped_target, escaped_link_path },
            );
        },
        .mount_path_setxattr => {
            const absolute_path = try getRequiredStringField(payload.value.object, "path");
            const name = try getRequiredStringField(payload.value.object, "name");
            const value_b64 = try getRequiredStringFieldAllowEmpty(payload.value.object, "value_b64");
            const value = try decodeStandardBase64Owned(allocator, value_b64);
            defer allocator.free(value);
            const flags = getOptionalU32Field(payload.value.object, "flags") orelse 0;
            if (!(try session.trySetxattrLocalFsBackedMountPath(absolute_path, name, value, flags))) return error.OperationNotSupported;
            const escaped_path = try unified.jsonEscape(allocator, absolute_path);
            defer allocator.free(escaped_path);
            const escaped_name = try unified.jsonEscape(allocator, name);
            defer allocator.free(escaped_name);
            return std.fmt.allocPrint(
                allocator,
                "{{\"path\":\"{s}\",\"name\":\"{s}\"}}",
                .{ escaped_path, escaped_name },
            );
        },
        .mount_path_getxattr => {
            const absolute_path = try getRequiredStringField(payload.value.object, "path");
            const name = try getRequiredStringField(payload.value.object, "name");
            const value = (try session.tryGetxattrLocalFsBackedMountPath(absolute_path, name)) orelse return error.OperationNotSupported;
            defer allocator.free(value);
            const escaped_path = try unified.jsonEscape(allocator, absolute_path);
            defer allocator.free(escaped_path);
            const escaped_name = try unified.jsonEscape(allocator, name);
            defer allocator.free(escaped_name);
            const encoded = try encodeStandardBase64Owned(allocator, value);
            defer allocator.free(encoded);
            return std.fmt.allocPrint(
                allocator,
                "{{\"path\":\"{s}\",\"name\":\"{s}\",\"value_b64\":\"{s}\"}}",
                .{ escaped_path, escaped_name, encoded },
            );
        },
        .mount_path_listxattr => {
            const absolute_path = try getRequiredStringField(payload.value.object, "path");
            const names = (try session.tryListxattrLocalFsBackedMountPath(absolute_path)) orelse return error.OperationNotSupported;
            defer allocator.free(names);
            const escaped_path = try unified.jsonEscape(allocator, absolute_path);
            defer allocator.free(escaped_path);
            var out = std.ArrayListUnmanaged(u8){};
            errdefer out.deinit(allocator);
            try out.writer(allocator).print("{{\"path\":\"{s}\",\"names\":[", .{escaped_path});
            var first = true;
            var idx: usize = 0;
            while (idx < names.len) {
                const start = idx;
                while (idx < names.len and names[idx] != 0) : (idx += 1) {}
                if (idx > start) {
                    const escaped_name = try unified.jsonEscape(allocator, names[start..idx]);
                    defer allocator.free(escaped_name);
                    if (!first) try out.append(allocator, ',');
                    first = false;
                    try out.writer(allocator).print("\"{s}\"", .{escaped_name});
                }
                idx += 1;
            }
            try out.appendSlice(allocator, "]}");
            return out.toOwnedSlice(allocator);
        },
        .mount_path_removexattr => {
            const absolute_path = try getRequiredStringField(payload.value.object, "path");
            const name = try getRequiredStringField(payload.value.object, "name");
            if (!(try session.tryRemovexattrLocalFsBackedMountPath(absolute_path, name))) return error.OperationNotSupported;
            const escaped_path = try unified.jsonEscape(allocator, absolute_path);
            defer allocator.free(escaped_path);
            const escaped_name = try unified.jsonEscape(allocator, name);
            defer allocator.free(escaped_name);
            return std.fmt.allocPrint(
                allocator,
                "{{\"path\":\"{s}\",\"name\":\"{s}\"}}",
                .{ escaped_path, escaped_name },
            );
        },
        .mount_path_lock => {
            const absolute_path = try getRequiredStringField(payload.value.object, "path");
            const mode = try getRequiredStringField(payload.value.object, "mode");
            const wait = getOptionalBoolField(payload.value.object, "wait") orelse true;
            if (!(try session.tryLockLocalFsBackedMountPath(absolute_path, mode, wait))) return error.OperationNotSupported;
            const escaped_path = try unified.jsonEscape(allocator, absolute_path);
            defer allocator.free(escaped_path);
            const escaped_mode = try unified.jsonEscape(allocator, mode);
            defer allocator.free(escaped_mode);
            return std.fmt.allocPrint(
                allocator,
                "{{\"path\":\"{s}\",\"mode\":\"{s}\",\"wait\":{s}}}",
                .{ escaped_path, escaped_mode, if (wait) "true" else "false" },
            );
        },
        .mount_path_setattr => {
            const absolute_path = try getRequiredStringField(payload.value.object, "path");
            const mode = getOptionalU32Field(payload.value.object, "mode");
            const uid = getOptionalU32Field(payload.value.object, "uid");
            const gid = getOptionalU32Field(payload.value.object, "gid");
            const flags = getOptionalU32Field(payload.value.object, "flags");
            const at_ns = getOptionalI64Field(payload.value.object, "at_ns");
            const mt_ns = getOptionalI64Field(payload.value.object, "mt_ns");
            if (!(try session.trySetattrLocalFsBackedMountPath(absolute_path, mode, uid, gid, flags, at_ns, mt_ns))) {
                return error.OperationNotSupported;
            }
            const escaped_path = try unified.jsonEscape(allocator, absolute_path);
            defer allocator.free(escaped_path);
            return std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\"}}", .{escaped_path});
        },
        else => return error.InvalidPayload,
    }
}

fn optionalStringsEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.mem.eql(u8, left.?, right.?);
}

fn buildProjectActivatePayload(
    allocator: std.mem.Allocator,
    project_id: []const u8,
    project_token: ?[]const u8,
) ![]u8 {
    const escaped_project = try unified.jsonEscape(allocator, project_id);
    defer allocator.free(escaped_project);
    if (project_token) |token| {
        const escaped_token = try unified.jsonEscape(allocator, token);
        defer allocator.free(escaped_token);
        return std.fmt.allocPrint(
            allocator,
            "{{\"project_id\":\"{s}\",\"project_token\":\"{s}\"}}",
            .{ escaped_project, escaped_token },
        );
    }
    return std.fmt.allocPrint(allocator, "{{\"project_id\":\"{s}\"}}", .{escaped_project});
}

fn buildWorkspaceStatusPayloadForBinding(
    allocator: std.mem.Allocator,
    runtime_registry: *AgentRuntimeRegistry,
    binding: SessionBinding,
    connection_workspace_url: ?[]const u8,
    is_admin: bool,
) ![]u8 {
    const status_req = if (binding.project_id) |project_id|
        try buildProjectActivatePayload(allocator, project_id, binding.project_token)
    else
        try allocator.dupe(u8, "{}");
    defer allocator.free(status_req);

    const workspace_json = runtime_registry.control_plane.workspaceStatusWithRole(binding.agent_id, status_req, is_admin) catch |err| {
        std.log.warn(
            "workspace status unavailable for agent={s} project={s}: {s}",
            .{ binding.agent_id, binding.project_id orelse "null", @errorName(err) },
        );
        return try allocator.dupe(u8, "{}");
    };
    defer allocator.free(workspace_json);
    return rewriteWorkspaceStatusFsUrls(allocator, workspace_json, connection_workspace_url);
}

fn buildSessionAttachStateJson(allocator: std.mem.Allocator, state: SessionAttachStateSnapshot) ![]u8 {
    const escaped_state = try unified.jsonEscape(allocator, sessionAttachStateName(state.state));
    defer allocator.free(escaped_state);
    const error_code_json = if (state.error_code) |value| blk: {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(error_code_json);
    const error_message_json = if (state.error_message) |value| blk: {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(error_message_json);

    return std.fmt.allocPrint(
        allocator,
        "{{\"state\":\"{s}\",\"runtime_ready\":{},\"mount_ready\":{},\"error_code\":{s},\"error_message\":{s},\"updated_at_ms\":{d}}}",
        .{
            escaped_state,
            state.runtime_ready,
            state.mount_ready,
            error_code_json,
            error_message_json,
            state.updated_at_ms,
        },
    );
}

fn buildSessionAttachAckPayload(
    allocator: std.mem.Allocator,
    session_key: []const u8,
    agent_id: []const u8,
    project_id: ?[]const u8,
    workspace_json: []const u8,
    attach_json: []const u8,
) ![]u8 {
    const escaped_session = try unified.jsonEscape(allocator, session_key);
    defer allocator.free(escaped_session);
    const escaped_agent = try unified.jsonEscape(allocator, agent_id);
    defer allocator.free(escaped_agent);
    const project_json = if (project_id) |value| blk: {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(project_json);

    return std.fmt.allocPrint(
        allocator,
        "{{\"session_key\":\"{s}\",\"agent_id\":\"{s}\",\"project_id\":{s},\"workspace\":{s},\"attach\":{s}}}",
        .{ escaped_session, escaped_agent, project_json, workspace_json, attach_json },
    );
}

fn buildSessionStatusPayload(
    allocator: std.mem.Allocator,
    session_key: []const u8,
    agent_id: []const u8,
    project_id: ?[]const u8,
    attach_json: []const u8,
    session_last_active_ms: i64,
    session_stale: bool,
    agent_last_heartbeat_ms: i64,
    agent_stale: bool,
) ![]u8 {
    const escaped_session = try unified.jsonEscape(allocator, session_key);
    defer allocator.free(escaped_session);
    const escaped_agent = try unified.jsonEscape(allocator, agent_id);
    defer allocator.free(escaped_agent);
    const project_json = if (project_id) |value| blk: {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(project_json);

    return std.fmt.allocPrint(
        allocator,
        "{{\"session_key\":\"{s}\",\"agent_id\":\"{s}\",\"project_id\":{s},\"attach\":{s},\"session_last_activity_ms\":{d},\"session_stale\":{},\"agent_last_heartbeat_ms\":{d},\"agent_stale\":{},\"recoverable\":true}}",
        .{
            escaped_session,
            escaped_agent,
            project_json,
            attach_json,
            session_last_active_ms,
            session_stale,
            agent_last_heartbeat_ms,
            agent_stale,
        },
    );
}

fn buildSessionListPayload(
    allocator: std.mem.Allocator,
    map: *const std.StringHashMapUnmanaged(SessionBinding),
    active_session_key: []const u8,
) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);

    const escaped_active = try unified.jsonEscape(allocator, active_session_key);
    defer allocator.free(escaped_active);
    try out.writer(allocator).print("{{\"active_session\":\"{s}\",\"sessions\":[", .{escaped_active});

    var first = true;
    var it = map.iterator();
    while (it.next()) |entry| {
        if (!first) try out.append(allocator, ',');
        first = false;
        const escaped_key = try unified.jsonEscape(allocator, entry.key_ptr.*);
        defer allocator.free(escaped_key);
        const escaped_agent = try unified.jsonEscape(allocator, entry.value_ptr.agent_id);
        defer allocator.free(escaped_agent);
        const project_json = if (entry.value_ptr.project_id) |project_id| blk: {
            const escaped_project = try unified.jsonEscape(allocator, project_id);
            defer allocator.free(escaped_project);
            break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped_project});
        } else try allocator.dupe(u8, "null");
        defer allocator.free(project_json);
        try out.writer(allocator).print(
            "{{\"session_key\":\"{s}\",\"agent_id\":\"{s}\",\"project_id\":{s}}}",
            .{ escaped_key, escaped_agent, project_json },
        );
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn appendSessionHistoryEntryJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    entry: SessionHistoryEntry,
) !void {
    const escaped_session = try unified.jsonEscape(allocator, entry.session_key);
    defer allocator.free(escaped_session);
    const escaped_agent = try unified.jsonEscape(allocator, entry.agent_id);
    defer allocator.free(escaped_agent);
    const escaped_project = try unified.jsonEscape(allocator, entry.project_id);
    defer allocator.free(escaped_project);
    const summary_json = if (entry.summary) |value| blk: {
        const escaped_summary = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped_summary);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped_summary});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(summary_json);

    try out.writer(allocator).print(
        "{{\"session_key\":\"{s}\",\"agent_id\":\"{s}\",\"project_id\":\"{s}\",\"last_active_ms\":{d},\"message_count\":{d},\"summary\":{s}}}",
        .{
            escaped_session,
            escaped_agent,
            escaped_project,
            entry.last_active_ms,
            entry.message_count,
            summary_json,
        },
    );
}

fn buildSessionRestorePayload(
    allocator: std.mem.Allocator,
    maybe_entry: ?SessionHistoryEntry,
) ![]u8 {
    if (maybe_entry == null) return allocator.dupe(u8, "{\"found\":false}");
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"found\":true,\"session\":");
    try appendSessionHistoryEntryJson(allocator, &out, maybe_entry.?);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn buildSessionHistoryPayload(
    allocator: std.mem.Allocator,
    history: []const SessionHistoryEntry,
) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"sessions\":[");
    for (history, 0..) |entry, idx| {
        if (idx != 0) try out.append(allocator, ',');
        try appendSessionHistoryEntryJson(allocator, &out, entry);
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
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

fn isConnectGateExemptControlType(control_type: unified.ControlType) bool {
    return switch (control_type) {
        .version,
        .connect,
        .session_attach,
        .session_restore,
        .session_history,
        .agent_ensure,
        .agent_list,
        .agent_get,
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
        .workspace_up,
        .project_create,
        .project_update,
        .project_delete,
        .project_list,
        .project_get,
        .project_mount_set,
        .project_mount_remove,
        .project_mount_list,
        .project_token_rotate,
        .project_token_revoke,
        .project_activate,
        .project_up,
        .reconcile_status,
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

fn validateControlVersionPayload(allocator: std.mem.Allocator, payload_json: ?[]const u8) !void {
    const raw = payload_json orelse return error.MissingField;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidType;
    const protocol_value = parsed.value.object.get("protocol") orelse return error.MissingField;
    if (protocol_value != .string) return error.InvalidType;
    if (!std.mem.eql(u8, protocol_value.string, control_protocol_version)) return error.ProtocolMismatch;
}

const FsNodeHelloOptions = struct {
    allow_invalidations: bool = false,
};

fn validateFsNodeHelloPayloadWithAcceptedTokens(
    allocator: std.mem.Allocator,
    payload_json: ?[]const u8,
    accepted_auth_tokens: ?[]const []const u8,
) !FsNodeHelloOptions {
    const raw = payload_json orelse return error.MissingField;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidType;

    const protocol_value = parsed.value.object.get("protocol") orelse return error.MissingField;
    if (protocol_value != .string) return error.InvalidType;
    if (!std.mem.eql(u8, protocol_value.string, acheron_node_protocol_version)) return error.ProtocolMismatch;

    const proto_value = parsed.value.object.get("proto") orelse return error.MissingField;
    if (proto_value != .integer) return error.InvalidType;
    if (proto_value.integer != acheron_node_proto_id) return error.ProtocolMismatch;

    if (accepted_auth_tokens) |expected_tokens| {
        const auth_value = parsed.value.object.get("auth_token") orelse return error.AuthMissing;
        if (auth_value != .string) return error.InvalidType;

        var matched = false;
        for (expected_tokens) |expected| {
            if (std.mem.eql(u8, auth_value.string, expected)) {
                matched = true;
                break;
            }
        }
        if (!matched) return error.AuthFailed;
    }

    var opts = FsNodeHelloOptions{};
    if (parsed.value.object.get("subscribe_invalidations")) |value| {
        if (value != .bool) return error.InvalidType;
        opts.allow_invalidations = value.bool;
    }
    return opts;
}

fn validateFsNodeHelloPayload(
    allocator: std.mem.Allocator,
    payload_json: ?[]const u8,
    required_auth_token: ?[]const u8,
) !FsNodeHelloOptions {
    if (required_auth_token) |expected| {
        const tokens = [_][]const u8{expected};
        return validateFsNodeHelloPayloadWithAcceptedTokens(allocator, payload_json, tokens[0..]);
    }
    return validateFsNodeHelloPayloadWithAcceptedTokens(allocator, payload_json, null);
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
        .project_create,
        .project_update,
        .project_delete,
        .project_mount_set,
        .project_mount_remove,
        .project_activate,
        .project_up,
        => true,
        else => false,
    };
}

fn appendAvailabilitySnapshotJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    snapshot: control_plane_mod.ControlPlane.AvailabilitySnapshot,
) !void {
    try out.appendSlice(allocator, "{\"nodes\":{\"online\":");
    try out.writer(allocator).print("{d}", .{snapshot.nodes_online});
    try out.appendSlice(allocator, ",\"total\":");
    try out.writer(allocator).print("{d}", .{snapshot.nodes_total});
    try out.appendSlice(allocator, "},\"mounts\":{\"online\":");
    try out.writer(allocator).print("{d}", .{snapshot.mounts_online});
    try out.appendSlice(allocator, ",\"degraded\":");
    try out.writer(allocator).print("{d}", .{snapshot.mounts_degraded});
    try out.appendSlice(allocator, ",\"missing\":");
    try out.writer(allocator).print("{d}", .{snapshot.mounts_missing});
    try out.appendSlice(allocator, ",\"total\":");
    try out.writer(allocator).print("{d}", .{snapshot.mounts_total});
    try out.appendSlice(allocator, "},\"project_mount_digest\":");
    try out.writer(allocator).print("{d}", .{snapshot.project_mount_digest});
    try out.appendSlice(allocator, "}");
}

fn extractNodeIdFromControlPayload(allocator: std.mem.Allocator, payload_json: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const node_id = parsed.value.object.get("node_id") orelse return null;
    if (node_id != .string or !isValidNodeIdentifier(node_id.string)) return null;
    const copy = try allocator.dupe(u8, node_id.string);
    return @as(?[]u8, copy);
}

fn extractProjectIdFromControlPayload(allocator: std.mem.Allocator, payload_json: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const project_id = parsed.value.object.get("project_id") orelse return null;
    if (project_id != .string or project_id.string.len == 0) return null;
    const copy = try allocator.dupe(u8, project_id.string);
    return @as(?[]u8, copy);
}

fn extractProjectTokenFromControlPayload(allocator: std.mem.Allocator, payload_json: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const project_token = parsed.value.object.get("project_token") orelse return null;
    if (project_token != .string or project_token.string.len == 0) return null;
    const copy = try allocator.dupe(u8, project_token.string);
    return @as(?[]u8, copy);
}

fn controlMutationScope(control_type: unified.ControlType) ControlMutationScope {
    return switch (control_type) {
        .node_invite_create,
        .node_ensure,
        .node_delete,
        .venom_bind,
        => .node,
        .node_join_pending_list,
        .node_join_approve,
        .node_join_deny,
        => .operator,
        .workspace_create,
        .workspace_update,
        .workspace_delete,
        .workspace_bind_set,
        .workspace_bind_remove,
        .workspace_mount_set,
        .workspace_mount_remove,
        .workspace_token_rotate,
        .workspace_token_revoke,
        .workspace_activate,
        .workspace_up,
        .project_create,
        .project_update,
        .project_delete,
        .project_mount_set,
        .project_mount_remove,
        .project_token_rotate,
        .project_token_revoke,
        .project_activate,
        .project_up,
        => .project,
        else => .none,
    };
}

fn validateControlScopeTokens(
    allocator: std.mem.Allocator,
    runtime_registry: *AgentRuntimeRegistry,
    control_type: unified.ControlType,
    payload_json: ?[]const u8,
) !void {
    const scope = controlMutationScope(control_type);
    if (scope == .none) return;

    const raw = payload_json orelse return error.MissingField;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    const obj = parsed.value.object;

    if (runtime_registry.control_operator_token) |operator_token| {
        if (obj.get("operator_token")) |token_value| {
            if (token_value != .string or token_value.string.len == 0) return error.InvalidPayload;
            if (!secureTokenEql(operator_token, token_value.string)) return error.OperatorAuthFailed;
            return;
        }
    }

    switch (scope) {
        .project => {
            if (runtime_registry.control_project_scope_token) |token| {
                const field = obj.get("project_scope_token") orelse return error.MissingField;
                if (field != .string or field.string.len == 0) return error.InvalidPayload;
                if (!secureTokenEql(token, field.string)) return error.OperatorAuthFailed;
                return;
            }
        },
        .node => {
            if (runtime_registry.control_node_scope_token) |token| {
                const field = obj.get("node_scope_token") orelse return error.MissingField;
                if (field != .string or field.string.len == 0) return error.InvalidPayload;
                if (!secureTokenEql(token, field.string)) return error.OperatorAuthFailed;
                return;
            }
        },
        .operator, .none => {},
    }

    if (runtime_registry.control_operator_token != null) {
        return error.MissingField;
    }
}

fn secureTokenEql(expected: []const u8, candidate: []const u8) bool {
    if (expected.len != candidate.len) return false;
    var diff: u8 = 0;
    for (expected, candidate) |lhs, rhs| {
        diff |= lhs ^ rhs;
    }
    return diff == 0;
}

fn controlScopeName(scope: ControlMutationScope) []const u8 {
    return switch (scope) {
        .none => "none",
        .node => "node",
        .project => "project",
        .operator => "operator",
    };
}

fn appendAuditRecordJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    record: AuditRecord,
) !void {
    const escaped_agent = try unified.jsonEscape(allocator, record.agent_id);
    defer allocator.free(escaped_agent);
    const escaped_type = try unified.jsonEscape(allocator, record.control_type);
    defer allocator.free(escaped_type);
    const escaped_result = try unified.jsonEscape(allocator, record.result);
    defer allocator.free(escaped_result);
    const correlation_json = if (record.correlation_id) |value| blk: {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(correlation_json);
    const error_json = if (record.error_code) |value| blk: {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(error_json);

    try out.writer(allocator).print(
        "{{\"id\":{d},\"timestamp_ms\":{d},\"agent_id\":\"{s}\",\"control_type\":\"{s}\",\"scope\":\"{s}\",\"correlation_id\":{s},\"result\":\"{s}\",\"error_code\":{s}}}",
        .{
            record.id,
            record.timestamp_ms,
            escaped_agent,
            escaped_type,
            controlScopeName(record.scope),
            correlation_json,
            escaped_result,
            error_json,
        },
    );
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

const JsonFieldAlias = struct {
    from: []const u8,
    to: []const u8,
};

const workspace_to_project_aliases = [_]JsonFieldAlias{
    .{ .from = "workspace_id", .to = "project_id" },
    .{ .from = "workspace_token", .to = "project_token" },
    .{ .from = "workspace_name", .to = "name" },
    .{ .from = "workspaces", .to = "projects" },
    .{ .from = "active_workspace", .to = "active_project" },
    .{ .from = "selected_workspace", .to = "selected_project" },
    .{ .from = "workspace_mount_digest", .to = "project_mount_digest" },
};

const project_to_workspace_aliases = [_]JsonFieldAlias{
    .{ .from = "project_id", .to = "workspace_id" },
    .{ .from = "project_token", .to = "workspace_token" },
    .{ .from = "project_name", .to = "workspace_name" },
    .{ .from = "projects", .to = "workspaces" },
    .{ .from = "active_project", .to = "active_workspace" },
    .{ .from = "selected_project", .to = "selected_workspace" },
    .{ .from = "project_mount_digest", .to = "workspace_mount_digest" },
};

fn isWorkspaceAliasControlType(control_type: unified.ControlType) bool {
    return switch (control_type) {
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
        .workspace_up,
        => true,
        else => false,
    };
}

fn canonicalProjectControlType(control_type: unified.ControlType) unified.ControlType {
    return switch (control_type) {
        .workspace_create => .project_create,
        .workspace_update => .project_update,
        .workspace_delete => .project_delete,
        .workspace_list => .project_list,
        .workspace_get => .project_get,
        .workspace_mount_set => .project_mount_set,
        .workspace_mount_remove => .project_mount_remove,
        .workspace_mount_list => .project_mount_list,
        .workspace_token_rotate => .project_token_rotate,
        .workspace_token_revoke => .project_token_revoke,
        .workspace_activate => .project_activate,
        .workspace_up => .project_up,
        else => control_type,
    };
}

fn aliasFieldName(name: []const u8, aliases: []const JsonFieldAlias) []const u8 {
    for (aliases) |alias| {
        if (std.mem.eql(u8, name, alias.from)) return alias.to;
    }
    return name;
}

fn appendAliasedJsonValue(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    value: std.json.Value,
    aliases: []const JsonFieldAlias,
) !void {
    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |boolean| try out.appendSlice(allocator, if (boolean) "true" else "false"),
        .integer => |integer| try out.writer(allocator).print("{d}", .{integer}),
        .float => |float| try out.writer(allocator).print("{d}", .{float}),
        .number_string => |number| try out.appendSlice(allocator, number),
        .string => |string| {
            const escaped = try unified.jsonEscape(allocator, string);
            defer allocator.free(escaped);
            try out.writer(allocator).print("\"{s}\"", .{escaped});
        },
        .array => |array| {
            try out.append(allocator, '[');
            for (array.items, 0..) |item, idx| {
                if (idx != 0) try out.append(allocator, ',');
                try appendAliasedJsonValue(allocator, out, item, aliases);
            }
            try out.append(allocator, ']');
        },
        .object => |object| {
            try out.append(allocator, '{');
            var it = object.iterator();
            var idx: usize = 0;
            while (it.next()) |entry| : (idx += 1) {
                if (idx != 0) try out.append(allocator, ',');
                const aliased_name = aliasFieldName(entry.key_ptr.*, aliases);
                const escaped_name = try unified.jsonEscape(allocator, aliased_name);
                defer allocator.free(escaped_name);
                try out.writer(allocator).print("\"{s}\":", .{escaped_name});
                try appendAliasedJsonValue(allocator, out, entry.value_ptr.*, aliases);
            }
            try out.append(allocator, '}');
        },
    }
}

fn rewriteJsonFieldAliases(
    allocator: std.mem.Allocator,
    payload_json: ?[]const u8,
    aliases: []const JsonFieldAlias,
) !?[]u8 {
    const raw = payload_json orelse return null;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try appendAliasedJsonValue(allocator, &out, parsed.value, aliases);
    const owned = try out.toOwnedSlice(allocator);
    return @as(?[]u8, owned);
}

fn handleControlPlaneCommand(
    runtime_registry: *AgentRuntimeRegistry,
    control_type: unified.ControlType,
    agent_id: []const u8,
    is_admin: bool,
    payload_json: ?[]const u8,
    connection_workspace_url: ?[]const u8,
) ![]u8 {
    const control_type_canonical = canonicalProjectControlType(control_type);
    const request_json = if (isWorkspaceAliasControlType(control_type) or control_type == .workspace_status)
        try rewriteJsonFieldAliases(runtime_registry.allocator, payload_json, &workspace_to_project_aliases)
    else
        null;
    defer if (request_json) |value| runtime_registry.allocator.free(value);

    const effective_payload = if (request_json) |value| @as(?[]const u8, value) else payload_json;
    const raw_response_json = try switch (control_type_canonical) {
        .node_invite_create => try runtime_registry.control_plane.createNodeInvite(effective_payload),
        .node_join_request => try runtime_registry.control_plane.nodeJoinRequest(effective_payload),
        .node_join_pending_list => try runtime_registry.control_plane.listPendingNodeJoins(effective_payload),
        .node_join_approve => try runtime_registry.control_plane.approvePendingNodeJoin(effective_payload),
        .node_join_deny => try runtime_registry.control_plane.denyPendingNodeJoin(effective_payload),
        .node_join => try runtime_registry.control_plane.nodeJoin(effective_payload),
        .node_ensure => try runtime_registry.control_plane.nodeEnsure(effective_payload),
        .node_lease_refresh => try runtime_registry.control_plane.refreshNodeLease(effective_payload),
        .venom_bind => try runtime_registry.control_plane.bindPreferredVenomProvider(effective_payload),
        .venom_upsert => try runtime_registry.control_plane.nodeVenomUpsert(effective_payload),
        .venom_get => try runtime_registry.control_plane.nodeVenomGet(effective_payload),
        .agent_ensure,
        .agent_list,
        .agent_get,
        => error.UnsupportedLegacyApi,
        .node_list => try runtime_registry.control_plane.listNodes(),
        .node_get => try runtime_registry.control_plane.getNode(effective_payload),
        .node_delete => try runtime_registry.control_plane.deleteNode(effective_payload),
        .project_create => try runtime_registry.control_plane.createProject(effective_payload),
        .project_update => try runtime_registry.control_plane.updateProjectWithRole(effective_payload, is_admin),
        .project_delete => try runtime_registry.control_plane.deleteProjectWithRole(effective_payload, is_admin),
        .project_list => try runtime_registry.control_plane.listProjects(),
        .project_get => try runtime_registry.control_plane.getProjectWithRole(effective_payload, is_admin),
        .workspace_template_list => try runtime_registry.control_plane.listWorkspaceTemplates(),
        .workspace_template_get => try runtime_registry.control_plane.getWorkspaceTemplate(effective_payload),
        .project_mount_set => try runtime_registry.control_plane.setProjectMountWithRole(effective_payload, is_admin),
        .project_mount_remove => try runtime_registry.control_plane.removeProjectMountWithRole(effective_payload, is_admin),
        .project_mount_list => try runtime_registry.control_plane.listProjectMountsWithRole(effective_payload, is_admin),
        .workspace_bind_set => try runtime_registry.control_plane.setProjectBindWithRole(effective_payload, is_admin),
        .workspace_bind_remove => try runtime_registry.control_plane.removeProjectBindWithRole(effective_payload, is_admin),
        .workspace_bind_list => try runtime_registry.control_plane.listProjectBindsWithRole(effective_payload, is_admin),
        .project_token_rotate => try runtime_registry.control_plane.rotateProjectTokenWithRole(effective_payload, is_admin),
        .project_token_revoke => try runtime_registry.control_plane.revokeProjectTokenWithRole(effective_payload, is_admin),
        .project_activate => try runtime_registry.control_plane.activateProjectWithRole(agent_id, effective_payload, is_admin),
        .workspace_status => try runtime_registry.control_plane.workspaceStatusWithRole(agent_id, effective_payload, is_admin),
        .reconcile_status => try runtime_registry.control_plane.reconcileStatus(effective_payload),
        .project_up => try runtime_registry.control_plane.projectUpWithRole(agent_id, effective_payload, is_admin),
        .audit_tail => try runtime_registry.buildAuditTailPayload(effective_payload),
        else => return error.UnsupportedControlPlaneOperation,
    };
    errdefer runtime_registry.allocator.free(raw_response_json);

    const response_json = blk: {
        if (control_type_canonical == .workspace_status) {
            break :blk try rewriteWorkspaceStatusFsUrls(
                runtime_registry.allocator,
                raw_response_json,
                connection_workspace_url,
            );
        }
        break :blk raw_response_json;
    };
    if (response_json.ptr != raw_response_json.ptr) runtime_registry.allocator.free(raw_response_json);
    errdefer runtime_registry.allocator.free(response_json);

    if (isWorkspaceAliasControlType(control_type) or control_type == .workspace_status) {
        const rewritten = try rewriteJsonFieldAliases(runtime_registry.allocator, response_json, &project_to_workspace_aliases);
        const rewritten_value = rewritten orelse return response_json;
        runtime_registry.allocator.free(response_json);
        return rewritten_value;
    }

    return response_json;
}

fn controlPlaneErrorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.UnsupportedLegacyApi => "unsupported_legacy_api",
        error.AccessDenied => "forbidden",
        error.InvalidAgentId => "invalid_payload",
        control_plane_mod.ControlPlaneError.InvalidPayload => "invalid_payload",
        control_plane_mod.ControlPlaneError.MissingField => "missing_field",
        control_plane_mod.ControlPlaneError.TemplateNotFound => "template_not_found",
        control_plane_mod.ControlPlaneError.InviteNotFound => "invite_not_found",
        control_plane_mod.ControlPlaneError.InviteExpired => "invite_expired",
        control_plane_mod.ControlPlaneError.InviteRedeemed => "invite_redeemed",
        control_plane_mod.ControlPlaneError.NodeNotFound => "node_not_found",
        error.AgentNotFound => "agent_not_found",
        control_plane_mod.ControlPlaneError.NodeAuthFailed => "node_auth_failed",
        control_plane_mod.ControlPlaneError.PendingJoinNotFound => "pending_join_not_found",
        control_plane_mod.ControlPlaneError.ProjectNotFound => "project_not_found",
        control_plane_mod.ControlPlaneError.ProjectAuthFailed => "project_auth_failed",
        control_plane_mod.ControlPlaneError.ProjectProtected => "project_protected",
        control_plane_mod.ControlPlaneError.ProjectAssignmentForbidden => "project_assignment_forbidden",
        control_plane_mod.ControlPlaneError.ProjectPolicyForbidden => "project_policy_forbidden",
        control_plane_mod.ControlPlaneError.MountConflict => "mount_conflict",
        control_plane_mod.ControlPlaneError.MountNotFound => "mount_not_found",
        control_plane_mod.ControlPlaneError.BindConflict => "bind_conflict",
        control_plane_mod.ControlPlaneError.BindNotFound => "bind_not_found",
        else => "control_plane_error",
    };
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

fn runMetricsHttpServer(
    allocator: std.mem.Allocator,
    runtime_registry: *AgentRuntimeRegistry,
    listener: *std.net.Server,
) void {
    while (true) {
        var connection = listener.accept() catch |err| {
            std.log.err("metrics accept failed: {s}", .{@errorName(err)});
            std.Thread.sleep(250 * std.time.ns_per_ms);
            continue;
        };
        defer connection.stream.close();

        handleMetricsHttpConnection(allocator, runtime_registry, &connection.stream) catch |err| {
            std.log.warn("metrics request failed: {s}", .{@errorName(err)});
        };
    }
}

fn handleMetricsHttpConnection(
    allocator: std.mem.Allocator,
    runtime_registry: *AgentRuntimeRegistry,
    stream: *std.net.Stream,
) !void {
    var request_buf: [16 * 1024]u8 = undefined;
    const request = try readHttpRequestIntoBuffer(stream, &request_buf);
    const request_target = parseHttpRequestPath(request) orelse {
        try writeHttpStatus(stream, "400 Bad Request", "text/plain; charset=utf-8", "bad request\n");
        return;
    };
    const request_path = stripHttpRequestTargetQuery(request_target);

    if (std.mem.eql(u8, request_path, "/livez")) {
        try writeHttpStatus(stream, "200 OK", "text/plain; charset=utf-8", "ok\n");
        return;
    }

    if (std.mem.eql(u8, request_path, "/readyz")) {
        if (runtime_registry.getFirstAgentId() == null) {
            try writeHttpStatus(stream, "503 Service Unavailable", "text/plain; charset=utf-8", "not ready\n");
            return;
        }
        try writeHttpStatus(stream, "200 OK", "text/plain; charset=utf-8", "ready\n");
        return;
    }

    if (std.mem.eql(u8, request_path, "/metrics")) {
        const body = runtime_registry.metricsPrometheus() catch |err| {
            const err_msg = try std.fmt.allocPrint(allocator, "metrics formatter error: {s}\n", .{@errorName(err)});
            defer allocator.free(err_msg);
            try writeHttpStatus(stream, "500 Internal Server Error", "text/plain; charset=utf-8", err_msg);
            return;
        };
        defer allocator.free(body);
        try writeHttpStatus(stream, "200 OK", "text/plain; version=0.0.4; charset=utf-8", body);
        return;
    }

    if (!std.mem.eql(u8, request_path, "/metrics.json")) {
        try writeHttpStatus(stream, "404 Not Found", "text/plain; charset=utf-8", "not found\n");
        return;
    }

    const json_body = runtime_registry.metricsJson() catch |err| {
        const err_msg = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}\n", .{@errorName(err)});
        defer allocator.free(err_msg);
        try writeHttpStatus(stream, "500 Internal Server Error", "application/json", err_msg);
        return;
    };
    defer allocator.free(json_body);

    try writeHttpStatus(stream, "200 OK", "application/json", json_body);
}

fn readHttpRequestIntoBuffer(stream: *std.net.Stream, buffer: []u8) ![]const u8 {
    var used: usize = 0;
    while (used < buffer.len) {
        const read_n = try stream.read(buffer[used..]);
        if (read_n == 0) return error.ConnectionClosed;
        used += read_n;
        if (std.mem.indexOf(u8, buffer[0..used], "\r\n\r\n") != null) {
            return buffer[0..used];
        }
    }
    return error.RequestTooLarge;
}

fn parseHttpRequestPath(request: []const u8) ?[]const u8 {
    const line_end = std.mem.indexOf(u8, request, "\r\n") orelse return null;
    const line = request[0..line_end];
    if (!std.mem.startsWith(u8, line, "GET ")) return null;
    const path_start = 4;
    const path_end = std.mem.indexOfPos(u8, line, path_start, " ") orelse return null;
    if (path_end <= path_start) return null;
    return line[path_start..path_end];
}

fn stripHttpRequestTargetQuery(target: []const u8) []const u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return target;
    return target[0..query_start];
}

fn writeHttpStatus(
    stream: *std.net.Stream,
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
) !void {
    var header_buf: [256]u8 = undefined;
    const response_headers = try std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, content_type, body.len },
    );
    try stream.writeAll(response_headers);
    if (body.len > 0) try stream.writeAll(body);
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
    admin_token: []const u8,
    user_token: []const u8,
) !void {
    const allocator = runtime_registry.allocator;
    allocator.free(runtime_registry.auth_tokens.admin_token);
    allocator.free(runtime_registry.auth_tokens.user_token);
    if (runtime_registry.auth_tokens.admin_last_target) |*target| target.deinit(allocator);
    if (runtime_registry.auth_tokens.user_last_target) |*target| target.deinit(allocator);
    for (runtime_registry.auth_tokens.admin_session_history.items) |*entry| entry.deinit(allocator);
    runtime_registry.auth_tokens.admin_session_history.deinit(allocator);
    for (runtime_registry.auth_tokens.user_session_history.items) |*entry| entry.deinit(allocator);
    runtime_registry.auth_tokens.user_session_history.deinit(allocator);
    runtime_registry.auth_tokens.admin_token = try allocator.dupe(u8, admin_token);
    runtime_registry.auth_tokens.user_token = try allocator.dupe(u8, user_token);
    runtime_registry.auth_tokens.admin_last_target = null;
    runtime_registry.auth_tokens.user_last_target = null;
    runtime_registry.auth_tokens.admin_session_history = .{};
    runtime_registry.auth_tokens.user_session_history = .{};
}

fn seedUserRememberedTargetForTests(
    runtime_registry: *AgentRuntimeRegistry,
    agent_id: []const u8,
) !void {
    const allocator = runtime_registry.allocator;
    const project_up = try runtime_registry.control_plane.projectUp(
        agent_id,
        "{\"name\":\"User Seed Project\",\"vision\":\"User Seed Project\",\"activate\":true}",
    );
    defer allocator.free(project_up);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, project_up, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.TestExpectedResult;
    const project_id_value = parsed.value.object.get("project_id") orelse return error.TestExpectedResult;
    if (project_id_value != .string) return error.TestExpectedResult;

    try runtime_registry.auth_tokens.setRememberedTarget(.user, agent_id, project_id_value.string);
}

test "server: workspace template control ops expose dev catalog entries" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();

    const listed = try handleControlPlaneCommand(
        &runtime_registry,
        .workspace_template_list,
        system_agent_id,
        true,
        null,
        null,
    );
    defer allocator.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"template_id\":\"minimum\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"template_id\":\"dev\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"template_id\":\"github\"") != null);

    const fetched = try handleControlPlaneCommand(
        &runtime_registry,
        .workspace_template_get,
        system_agent_id,
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
    const bound = try handleControlPlaneCommand(
        &runtime_registry,
        .workspace_bind_set,
        system_agent_id,
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
    const listed = try handleControlPlaneCommand(
        &runtime_registry,
        .workspace_bind_list,
        system_agent_id,
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
    const removed = try handleControlPlaneCommand(
        &runtime_registry,
        .workspace_bind_remove,
        system_agent_id,
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
    try setAuthTokensForTests(&runtime_registry, "admin-secret", "user-secret");

    const project_up = try runtime_registry.control_plane.projectUpWithRole(
        system_agent_id,
        "{\"name\":\"Admin Remembered\",\"vision\":\"Remembered target test\",\"activate\":false}",
        true,
    );
    defer allocator.free(project_up);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, project_up, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.TestExpectedResult;
    const project_id_value = parsed.value.object.get("project_id") orelse return error.TestExpectedResult;
    if (project_id_value != .string or project_id_value.string.len == 0) return error.TestExpectedResult;

    try runtime_registry.auth_tokens.setRememberedTarget(.admin, "roger", project_id_value.string);

    const initial = try runtime_registry.buildInitialSessionBinding(.admin);
    defer {
        var owned = initial.binding;
        owned.deinit(allocator);
    }
    try std.testing.expect(initial.connect_gate_error == null);
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
    project_id: []u8,
    workspace_root: []u8,
    mount_paths: std.ArrayListUnmanaged([]u8) = .{},

    fn deinit(self: *WorkspaceScopeSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.project_id);
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

    const project_id_value = payload.object.get("project_id") orelse return error.TestExpectedResponse;
    if (project_id_value != .string or project_id_value.string.len == 0) return error.TestExpectedResponse;

    const workspace_value = payload.object.get("workspace") orelse return error.TestExpectedResponse;
    if (workspace_value != .object) return error.TestExpectedResponse;

    const workspace_root_value = workspace_value.object.get("workspace_root") orelse return error.TestExpectedResponse;
    if (workspace_root_value != .string or workspace_root_value.string.len == 0) return error.TestExpectedResponse;

    var snapshot = WorkspaceScopeSnapshot{
        .project_id = try allocator.dupe(u8, project_id_value.string),
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
    try setAuthTokensForTests(&runtime_registry, "admin-secret", "user-secret");
    try seedUserRememberedTargetForTests(&runtime_registry, "user-auth");

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

    try performClientHandshakeWithBearerToken(allocator, &client, "/", "admin-secret");

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
    try setAuthTokensForTests(&runtime_registry, "admin-secret", "user-secret");

    const project_up = try runtime_registry.control_plane.projectUpWithRole(
        system_agent_id,
        "{\"name\":\"Scope Test\",\"vision\":\"Project-scoped namespace\",\"activate\":false}",
        true,
    );
    defer allocator.free(project_up);

    const project_id = (try extractProjectIdFromControlPayload(allocator, project_up)) orelse return error.TestExpectedResult;
    defer allocator.free(project_id);

    try runtime_registry.auth_tokens.setRememberedTarget(.user, "alice", project_id);

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
    try performClientHandshakeWithBearerToken(allocator, &client, "/", "user-secret");

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
        "{{\"channel\":\"control\",\"type\":\"control.session_attach\",\"id\":\"scope-attach-alice\",\"payload\":{{\"session_key\":\"scope-a\",\"agent_id\":\"alice\",\"project_id\":\"{s}\"}}}}",
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
        "{{\"channel\":\"control\",\"type\":\"control.session_attach\",\"id\":\"scope-attach-bob\",\"payload\":{{\"session_key\":\"scope-b\",\"agent_id\":\"bob\",\"project_id\":\"{s}\"}}}}",
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
    try setAuthTokensForTests(&runtime_registry, "admin-secret", "user-secret");
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
    try performClientHandshakeWithBearerToken(allocator, &client, "/", "admin-secret");

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"v1\",\"payload\":{\"protocol\":\"spiderweb-control\"}}");
    var version_ack = try readServerFrame(allocator, &client);
    defer version_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, version_ack.payload, "\"type\":\"control.version_ack\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"c1\"}");
    var connect_ack = try readServerFrame(allocator, &client);
    defer connect_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"type\":\"control.connect_ack\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.project_create\",\"id\":\"p-missing\",\"payload\":{\"name\":\"NoToken\",\"vision\":\"NoToken\"}}");
    var missing_token = try readServerFrame(allocator, &client);
    defer missing_token.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, missing_token.payload, "\"type\":\"control.error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing_token.payload, "\"code\":\"missing_field\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.project_create\",\"id\":\"p-bad\",\"payload\":{\"name\":\"BadToken\",\"vision\":\"BadToken\",\"operator_token\":\"wrong\"}}");
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
    try setAuthTokensForTests(&runtime_registry, "admin-secret", "user-secret");

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

    try performClientHandshakeWithBearerToken(allocator, &client, "/", "admin-secret");
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
    try setAuthTokensForTests(&runtime_registry, "admin-secret", "user-secret");

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
    const project_id = (try extractProjectIdFromControlPayload(allocator, project_created)) orelse return error.TestExpectedResponse;
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

    try performClientHandshakeWithBearerToken(allocator, &client, "/", "admin-secret");
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
        "{{\"channel\":\"control\",\"type\":\"control.session_attach\",\"id\":\"attach\",\"payload\":{{\"session_key\":\"main\",\"agent_id\":\"test-agent\",\"project_id\":\"{s}\"}}}}",
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
    try setAuthTokensForTests(&runtime_registry, "admin-secret", "user-secret");

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
        try performClientHandshakeWithBearerToken(allocator, &admin_client, "/", "admin-secret");

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
        try std.testing.expect(std.mem.indexOf(u8, auth_status.payload, "\"admin_token\":\"admin-secret\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, auth_status.payload, "\"user_token\":\"user-secret\"") != null);

        try writeClientTextFrameMasked(&admin_client, "{\"channel\":\"control\",\"type\":\"control.auth_rotate\",\"id\":\"admin-auth-rotate\",\"payload\":{\"role\":\"admin\"}}");
        var auth_rotate = try readServerFrame(allocator, &admin_client);
        defer auth_rotate.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, auth_rotate.payload, "\"type\":\"control.auth_rotate\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, auth_rotate.payload, "\"role\":\"admin\"") != null);

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
        try performClientHandshakeWithBearerToken(allocator, &user_client, "/", "user-secret");

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
        var forbidden_metrics = try readServerFrame(allocator, &user_client);
        defer forbidden_metrics.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, forbidden_metrics.payload, "\"type\":\"control.error\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, forbidden_metrics.payload, "\"code\":\"forbidden\"") != null);

        try writeClientTextFrameMasked(&user_client, "{\"channel\":\"control\",\"type\":\"control.auth_status\",\"id\":\"user-auth-status\"}");
        var forbidden_status = try readServerFrame(allocator, &user_client);
        defer forbidden_status.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, forbidden_status.payload, "\"type\":\"control.error\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, forbidden_status.payload, "\"code\":\"forbidden\"") != null);

        try writeClientTextFrameMasked(&user_client, "{\"channel\":\"control\",\"type\":\"control.auth_rotate\",\"id\":\"user-auth-rotate\",\"payload\":{\"role\":\"user\"}}");
        var forbidden_rotate = try readServerFrame(allocator, &user_client);
        defer forbidden_rotate.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, forbidden_rotate.payload, "\"type\":\"control.error\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, forbidden_rotate.payload, "\"code\":\"forbidden\"") != null);

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
        try std.testing.expect(std.mem.indexOf(u8, forbidden_attach.payload, "project_id is required") != null);

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

test "server: user connect keeps a minimal payload when no remembered non-system target exists" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();
    try setAuthTokensForTests(&runtime_registry, "admin-secret", "user-secret");

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
    try performClientHandshakeWithBearerToken(allocator, &user_client, "/", "user-secret");

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
    try std.testing.expect(std.mem.indexOf(u8, attach_forbidden.payload, "project_id is required") != null);

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
    try setAuthTokensForTests(&runtime_registry, "admin-secret", "user-secret");

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
    try performClientHandshakeWithBearerToken(allocator, &admin_client, "/", "admin-secret");

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
    try setAuthTokensForTests(&runtime_registry, "admin-secret", "user-secret");

    const project_up = try runtime_registry.control_plane.projectUpWithRole(
        system_agent_id,
        "{\"name\":\"Needs Attach\",\"vision\":\"Needs Attach\",\"activate\":false}",
        true,
    );
    defer allocator.free(project_up);
    const project_id = (try extractProjectIdFromControlPayload(allocator, project_up)) orelse return error.TestExpectedResult;
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
    try performClientHandshakeWithBearerToken(allocator, &user_client, "/", "user-secret");

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
    try setAuthTokensForTests(&runtime_registry, "admin-secret", "user-secret");

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
    try performClientHandshakeWithBearerToken(allocator, &client, "/", "user-secret");

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
    try setAuthTokensForTests(&runtime_registry, "admin-secret", "user-secret");
    try seedUserRememberedTargetForTests(&runtime_registry, runtime_registry.default_agent_id);
    const remembered_target = runtime_registry.auth_tokens.user_last_target orelse return error.TestExpectedResult;
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
    try performClientHandshakeWithBearerToken(allocator, &client, "/", "user-secret");

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
        "{{\"channel\":\"control\",\"type\":\"control.session_attach\",\"id\":\"actor-guard-override\",\"payload\":{{\"session_key\":\"main\",\"agent_id\":\"{s}\",\"project_id\":\"{s}\",\"actor_type\":\"agent\",\"actor_id\":\"intruder\"}}}}",
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
    try setAuthTokensForTests(&runtime_registry, "admin-secret", "user-secret");
    try seedUserRememberedTargetForTests(&runtime_registry, runtime_registry.default_agent_id);
    const remembered_target = runtime_registry.auth_tokens.user_last_target orelse return error.TestExpectedResult;
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
        try performClientHandshakeWithBearerToken(allocator, &user_client, "/", "user-secret");

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
            "{{\"channel\":\"control\",\"type\":\"control.session_attach\",\"id\":\"history-attach\",\"payload\":{{\"session_key\":\"work-1\",\"agent_id\":\"{s}\",\"project_id\":\"{s}\"}}}}",
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
        try performClientHandshakeWithBearerToken(allocator, &user_client, "/", "user-secret");

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
    try setAuthTokensForTests(&runtime_registry, "admin-secret", "user-secret");

    if (runtime_registry.auth_tokens.path) |path| allocator.free(path);
    runtime_registry.auth_tokens.path = try allocator.dupe(u8, "/");
    const previous_admin = try allocator.dupe(u8, runtime_registry.auth_tokens.admin_token);
    defer allocator.free(previous_admin);

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
    try performClientHandshakeWithBearerToken(allocator, &client, "/", "admin-secret");

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"rotate-fail-version\",\"payload\":{\"protocol\":\"spiderweb-control\"}}");
    var version_ack = try readServerFrame(allocator, &client);
    defer version_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, version_ack.payload, "\"type\":\"control.version_ack\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"rotate-fail-connect\"}");
    var connect_ack = try readServerFrame(allocator, &client);
    defer connect_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"type\":\"control.connect_ack\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.auth_rotate\",\"id\":\"rotate-fail\",\"payload\":{\"role\":\"admin\"}}");
    var rotate_error = try readServerFrame(allocator, &client);
    defer rotate_error.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, rotate_error.payload, "\"type\":\"control.error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rotate_error.payload, "\"code\":\"storage_error\"") != null);

    try std.testing.expectEqualStrings(previous_admin, runtime_registry.auth_tokens.admin_token);

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

test "server: session_attach forbids reserved system agent on non-system workspace" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();
    try setAuthTokensForTests(&runtime_registry, "admin-secret", "user-secret");

    const project_up_payload = "{\"name\":\"NonSystem\",\"vision\":\"non-system\",\"activate\":false}";
    const project_up_result = try runtime_registry.control_plane.projectUpWithRole(system_agent_id, project_up_payload, true);
    defer allocator.free(project_up_result);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_up_result, .{});
    defer parsed_project.deinit();
    if (parsed_project.value != .object) return error.TestExpectedResult;
    const project_id_val = parsed_project.value.object.get("project_id") orelse return error.TestExpectedResult;
    if (project_id_val != .string or project_id_val.string.len == 0) return error.TestExpectedResult;
    const non_system_project_id = project_id_val.string;

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
    try performClientHandshakeWithBearerToken(allocator, &client, "/", "admin-secret");

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"system-agent-guard-version\",\"payload\":{\"protocol\":\"spiderweb-control\"}}");
    var version_ack = try readServerFrame(allocator, &client);
    defer version_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, version_ack.payload, "\"type\":\"control.version_ack\"") != null);

    try writeClientTextFrameMasked(&client, "{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"system-agent-guard-connect\"}");
    var connect_ack = try readServerFrame(allocator, &client);
    defer connect_ack.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, connect_ack.payload, "\"type\":\"control.connect_ack\"") != null);

    const attach_request = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"control\",\"type\":\"control.session_attach\",\"id\":\"system-agent-guard-attach\",\"payload\":{{\"session_key\":\"main\",\"agent_id\":\"{s}\",\"project_id\":\"{s}\"}}}}",
        .{ system_agent_id, non_system_project_id },
    );
    defer allocator.free(attach_request);
    try writeClientTextFrameMasked(&client, attach_request);

    var attach_error = try readServerFrame(allocator, &client);
    defer attach_error.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, attach_error.payload, "\"type\":\"control.error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, attach_error.payload, "\"code\":\"forbidden\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, attach_error.payload, "reserved system agent can only attach to the reserved system workspace") != null);

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
    try setAuthTokensForTests(&runtime_registry, "admin-secret", "user-secret");

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
    try performClientHandshakeWithBearerToken(allocator, &client, "/", "admin-secret");
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
    try setAuthTokensForTests(&runtime_registry, "admin-secret", "user-secret");

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
        try performClientHandshakeWithBearerToken(allocator, &client, "/", "admin-secret");

        try fsrpcConnectAndAttach(allocator, &client, "a-connect");
        try expectLegacyAcheronRejected(allocator, &client);
    }

    {
        const server_thread = try std.Thread.spawn(.{}, runSingleWsConnection, .{&server_ctx});
        defer server_thread.join();

        var client = try std.net.tcpConnectToAddress(listener.listen_address);
        defer client.close();
        try performClientHandshakeWithBearerToken(allocator, &client, "/", "admin-secret");

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
    try setAuthTokensForTests(&runtime_registry, "admin-secret", "user-secret");

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
        try performClientHandshakeWithBearerToken(allocator, &client, "/", "admin-secret");

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
        try performClientHandshakeWithBearerToken(allocator, &client, "/", "admin-secret");

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

    const second_runtime = try runtime_registry.getOrCreate(system_agent_id, project_id, null);
    defer second_runtime.release();
    try std.testing.expect(second_runtime != first_runtime);
    try std.testing.expect(!runtime_registry.hasRuntimeForBinding(runtime_registry.default_agent_id, project_id));
    try std.testing.expect(runtime_registry.hasRuntimeForBinding(system_agent_id, project_id));
    try std.testing.expectEqual(@as(usize, 1), runtime_registry.by_agent.count());

    const stale_lookup = runtime_registry.getRuntimeForBindingIfReady(runtime_registry.default_agent_id, project_id);
    try std.testing.expect(stale_lookup == null);

    const active_lookup = runtime_registry.getRuntimeForBindingIfReady(system_agent_id, project_id) orelse return error.TestExpectedResult;
    active_lookup.release();

    runtime_registry.mutex.lock();
    defer runtime_registry.mutex.unlock();
    const active_entry = runtime_registry.by_agent.getPtr(project_id) orelse return error.TestExpectedResult;
    try std.testing.expectEqualStrings(system_agent_id, active_entry.runtime_agent_id);
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
    const path = parseHttpRequestPath(request) orelse return error.TestExpectedPath;
    try std.testing.expectEqualStrings("/metrics", path);
}

test "server: stripHttpRequestTargetQuery removes query string" {
    try std.testing.expectEqualStrings("/metrics", stripHttpRequestTargetQuery("/metrics?format=json"));
    try std.testing.expectEqualStrings("/readyz", stripHttpRequestTargetQuery("/readyz"));
}

test "server: extract project payload helpers parse id and token" {
    const allocator = std.testing.allocator;
    const payload = "{\"project_id\":\"proj-7\",\"project_token\":\"proj-token-7\"}";

    const project_id = try extractProjectIdFromControlPayload(allocator, payload);
    defer if (project_id) |value| allocator.free(value);
    try std.testing.expect(project_id != null);
    try std.testing.expectEqualStrings("proj-7", project_id.?);

    const project_token = try extractProjectTokenFromControlPayload(allocator, payload);
    defer if (project_token) |value| allocator.free(value);
    try std.testing.expect(project_token != null);
    try std.testing.expectEqualStrings("proj-token-7", project_token.?);

    const token_missing = try extractProjectTokenFromControlPayload(allocator, "{\"project_id\":\"proj-7\"}");
    try std.testing.expect(token_missing == null);
}

test "server: extract node id helper parses valid payload" {
    const allocator = std.testing.allocator;
    const payload = "{\"node_id\":\"node-7\",\"venom_delta\":{\"changed\":true}}";
    const node_id = try extractNodeIdFromControlPayload(allocator, payload);
    defer if (node_id) |value| allocator.free(value);
    try std.testing.expect(node_id != null);
    try std.testing.expectEqualStrings("node-7", node_id.?);

    const missing = try extractNodeIdFromControlPayload(allocator, "{\"venom_delta\":{}}");
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
    const project_id = try extractProjectIdFromControlPayload(allocator, project_created);
    defer if (project_id) |value| allocator.free(value);
    try std.testing.expect(project_id != null);

    const mount_payload = try std.fmt.allocPrint(
        allocator,
        "{{\"project_id\":\"{s}\",\"mount_path\":\"/nodes/node-a/fs\",\"node_id\":\"{s}\",\"export_name\":\"fs\"}}",
        .{ project_id.?, node_registration.node_id },
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
    const routed = try buildInternalNodeFsUrl(allocator, "0.0.0.0", 18790, "node-17");
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
    try std.testing.expectEqualStrings(system_agent_id, registry.default_agent_id);
}

test "server: materializeMountGraphWriteData preserves suffix on offset zero partial writes" {
    const allocator = std.testing.allocator;
    const merged = try materializeMountGraphWriteData(allocator, "abcdef", 0, "xy", null);
    defer allocator.free(merged);
    try std.testing.expectEqualStrings("xycdef", merged);
}

test "server: materializeMountGraphWriteData preserves suffix on middle writes" {
    const allocator = std.testing.allocator;
    const merged = try materializeMountGraphWriteData(allocator, "abcdef", 2, "XY", null);
    defer allocator.free(merged);
    try std.testing.expectEqualStrings("abXYef", merged);
}

test "server: materializeMountGraphWriteData truncates existing content before rewrite" {
    const allocator = std.testing.allocator;
    const merged = try materializeMountGraphWriteData(allocator, "abcdef", 0, "", 3);
    defer allocator.free(merged);
    try std.testing.expectEqualStrings("abc", merged);
}

test "server: materializeMountGraphWriteData rejects truncate on missing files" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.FileNotFound,
        materializeMountGraphWriteData(allocator, null, 0, "", 0),
    );
}

test "server: materializeMountGraphWriteData rejects oversized materialized writes" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.WriteTooLarge,
        materializeMountGraphWriteData(allocator, "", max_mount_graph_materialized_file_bytes, "x", null),
    );
}

test "server: mountGraphWriteResponseCount reports request byte length" {
    try std.testing.expectEqual(@as(u32, 2), try mountGraphWriteResponseCount(2));
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
    try std.testing.expectError(error.InvalidOffset, clampMountGraphReadLength(limit + 1, null));
}

test "server: clampMountGraphReadLength clamps explicit length to remaining bytes" {
    const near_end = max_mount_graph_materialized_file_bytes - 16;
    try std.testing.expectEqual(@as(u32, 16), try clampMountGraphReadLength(near_end, 1024));
    try std.testing.expectEqual(@as(u32, 0), try clampMountGraphReadLength(max_mount_graph_materialized_file_bytes, 1024));
}

test "server: mountGraphReadIsEof reports eof when clamp reaches materialization boundary" {
    const limit = max_mount_graph_materialized_file_bytes;
    try std.testing.expect(mountGraphReadIsEof(limit, null, 0, 0));
    try std.testing.expect(mountGraphReadIsEof(limit, 1024, 0, 0));
}

test "server: mountGraphReadIsEof preserves zero-length request semantics away from boundary" {
    try std.testing.expect(!mountGraphReadIsEof(0, 0, 0, 0));
}

test "server: mount attach and mount file read control operations are supported after session attach" {
    const allocator = std.testing.allocator;
    var runtime_registry = AgentRuntimeRegistry.init(allocator, .{
        .state_directory = "",
        .state_db_filename = "",
    }, null);
    defer runtime_registry.deinit();
    try setAuthTokensForTests(&runtime_registry, "admin-secret", "user-secret");

    const project_up = try runtime_registry.control_plane.projectUpWithRole(
        "mount-agent",
        "{\"name\":\"MountAttach\",\"vision\":\"MountAttach\",\"activate\":false}",
        true,
    );
    defer allocator.free(project_up);
    const project_id = (try extractProjectIdFromControlPayload(allocator, project_up)) orelse return error.TestExpectedResult;
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
    try performClientHandshakeWithBearerToken(allocator, &client, "/", "admin-secret");

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
        "{{\"channel\":\"control\",\"type\":\"control.session_attach\",\"id\":\"mount-attach-session\",\"payload\":{{\"session_key\":\"fskit\",\"agent_id\":\"mount-agent\",\"project_id\":\"{s}\"}}}}",
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
    try setAuthTokensForTests(&runtime_registry, "admin-secret", "user-secret");

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
    const project_id = (try extractProjectIdFromControlPayload(allocator, project_up)) orelse return error.TestExpectedResult;
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
    try performClientHandshakeWithBearerToken(allocator, &client, "/", "admin-secret");

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
        "{{\"channel\":\"control\",\"type\":\"control.session_attach\",\"id\":\"projected-attach-session\",\"payload\":{{\"session_key\":\"fskit\",\"agent_id\":\"mount-agent\",\"project_id\":\"{s}\"}}}}",
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
