const builtin = @import("builtin");
const std = @import("std");
const fs_router = @import("acheron_fs_router");
const fs_fuse_adapter = @import("spiderweb_fs_fuse_adapter");
const mount_provider = @import("spiderweb_mount_provider");
const mount_state = @import("mount_state.zig");
const native_mount_protocol = @import("spiderweb_native_mount_protocol");
const native_mount_support = @import("native_mount_support.zig");
const namespace_client = @import("namespace_client.zig");
const namespace_contract = @import("namespace_contract.zig");
const namespace_mount_provider = @import("namespace_mount_provider.zig");

const control_reply_timeout_ms: i32 = 45_000;
const control_handshake_timeout_ms: i32 = 10_000;
const native_mount_timeout_ms: u64 = 30_000;
const namespace_warmup_deadline_ms: i64 = 10_000;
const namespace_warmup_retry_ms: u64 = 200;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var endpoint_specs = std.ArrayListUnmanaged(fs_router.EndpointConfig){};
    defer endpoint_specs.deinit(allocator);
    var owned_endpoint_fields = std.ArrayListUnmanaged([]u8){};
    defer {
        for (owned_endpoint_fields.items) |value| allocator.free(value);
        owned_endpoint_fields.deinit(allocator);
    }
    var remaining = std.ArrayListUnmanaged([]const u8){};
    defer remaining.deinit(allocator);
    var workspace_url: ?[]const u8 = null;
    var namespace_url: ?[]const u8 = null;
    var workspace_id: ?[]const u8 = null;
    var workspace_token: ?[]const u8 = null;
    var workspace_auth_token: ?[]const u8 = null;
    var workspace_sync_interval_ms: u64 = 5_000;
    var namespace_keepalive_interval_ms: u64 = 60_000;
    var namespace_agent_id: ?[]const u8 = null;
    var namespace_session_key: ?[]const u8 = null;
    var mount_backend: fs_fuse_adapter.FuseAdapter.MountBackend = .auto;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--endpoint")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            try endpoint_specs.append(allocator, try parseEndpointFlag(args[i]));
        } else if (std.mem.eql(u8, args[i], "--workspace-url")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            workspace_url = args[i];
        } else if (std.mem.eql(u8, args[i], "--namespace-url")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            namespace_url = args[i];
        } else if (std.mem.eql(u8, args[i], "--workspace-sync-interval-ms")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            workspace_sync_interval_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--namespace-keepalive-interval-ms")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            namespace_keepalive_interval_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--workspace-id")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            workspace_id = args[i];
        } else if (std.mem.eql(u8, args[i], "--workspace-token")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            workspace_token = args[i];
        } else if (std.mem.eql(u8, args[i], "--auth-token")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            workspace_auth_token = args[i];
        } else if (std.mem.eql(u8, args[i], "--agent-id")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            namespace_agent_id = args[i];
        } else if (std.mem.eql(u8, args[i], "--session-key")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            namespace_session_key = args[i];
        } else if (std.mem.eql(u8, args[i], "--mount-backend")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            mount_backend = try parseMountBackend(args[i]);
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            try printHelp();
            return;
        } else {
            try remaining.append(allocator, args[i]);
        }
    }
    if (workspace_token != null and workspace_id == null) return error.InvalidArguments;
    if (workspace_url != null and namespace_url != null) return error.InvalidArguments;
    const resolved_workspace_auth_token = workspace_auth_token orelse std.process.getEnvVarOwned(allocator, "SPIDERWEB_AUTH_TOKEN") catch null;
    defer if (workspace_auth_token == null) {
        if (resolved_workspace_auth_token) |token| allocator.free(token);
    };

    var namespace_client_instance: ?namespace_client.NamespaceClient = null;
    defer if (namespace_client_instance) |*client| client.deinit();
    var namespace_status = NamespaceStatus{};
    defer namespace_status.deinit(allocator);

    if (workspace_url) |url| {
        var hydrated = try fetchWorkspaceEndpointSpecs(
            allocator,
            url,
            workspace_id,
            workspace_token,
            resolved_workspace_auth_token,
        );
        defer hydrated.deinit(allocator);
        try appendHydratedEndpointSpecs(allocator, &endpoint_specs, &owned_endpoint_fields, hydrated.items.items);

        var client = try namespace_client.NamespaceClient.connect(allocator, url, resolved_workspace_auth_token);
        errdefer client.deinit();

        var connect_info = try client.controlConnect();
        defer connect_info.deinit(allocator);

        const resolved_workspace_id = if (workspace_id) |requested_workspace_id|
            try allocator.dupe(u8, requested_workspace_id)
        else if (connect_info.workspace_id) |connected_workspace_id|
            try allocator.dupe(u8, connected_workspace_id)
        else
            return error.WorkspaceRequired;
        defer allocator.free(resolved_workspace_id);

        var state_store = try mount_state.ClientStateStore.init(allocator);
        defer state_store.deinit();

        const resolved_agent_id = if (namespace_agent_id) |agent_id|
            try allocator.dupe(u8, agent_id)
        else
            try state_store.loadOrCreateAgentId(url, resolved_workspace_id);
        defer allocator.free(resolved_agent_id);

        const resolved_session_key = if (namespace_session_key) |session_key|
            try allocator.dupe(u8, session_key)
        else
            try mount_state.ClientStateStore.generateEphemeralSessionKey(allocator);
        defer allocator.free(resolved_session_key);

        var attach_info = try client.controlSessionAttach(.{
            .session_key = resolved_session_key,
            .agent_id = resolved_agent_id,
            .workspace_id = resolved_workspace_id,
            .workspace_token = workspace_token,
        });
        defer attach_info.deinit(allocator);

        namespace_status = .{
            .namespace_url = try allocator.dupe(u8, url),
            .workspace_id = try allocator.dupe(u8, resolved_workspace_id),
            .workspace_name = if (hydrated.workspace_name) |value| try allocator.dupe(u8, value) else null,
            .agent_id = try allocator.dupe(u8, resolved_agent_id),
            .session_key = try allocator.dupe(u8, resolved_session_key),
        };
        namespace_client_instance = client;
    } else if (namespace_url) |url| {
        var client = try namespace_client.NamespaceClient.connect(allocator, url, resolved_workspace_auth_token);
        errdefer client.deinit();

        var connect_info = try client.controlConnect();
        defer connect_info.deinit(allocator);

        const resolved_workspace_id = if (workspace_id) |requested_workspace_id|
            try allocator.dupe(u8, requested_workspace_id)
        else if (connect_info.workspace_id) |connected_workspace_id|
            try allocator.dupe(u8, connected_workspace_id)
        else
            return error.WorkspaceRequired;
        defer allocator.free(resolved_workspace_id);

        var state_store = try mount_state.ClientStateStore.init(allocator);
        defer state_store.deinit();

        const resolved_agent_id = if (namespace_agent_id) |agent_id|
            try allocator.dupe(u8, agent_id)
        else
            try state_store.loadOrCreateAgentId(url, resolved_workspace_id);
        defer allocator.free(resolved_agent_id);

        const resolved_session_key = if (namespace_session_key) |session_key|
            try allocator.dupe(u8, session_key)
        else
            try mount_state.ClientStateStore.generateEphemeralSessionKey(allocator);
        defer allocator.free(resolved_session_key);

        var attach_info = try client.controlSessionAttach(.{
            .session_key = resolved_session_key,
            .agent_id = resolved_agent_id,
            .workspace_id = resolved_workspace_id,
            .workspace_token = workspace_token,
        });
        defer attach_info.deinit(allocator);

        var hydrated = try fetchWorkspaceEndpointSpecs(
            allocator,
            url,
            resolved_workspace_id,
            workspace_token,
            resolved_workspace_auth_token,
        );
        defer hydrated.deinit(allocator);
        try appendHydratedEndpointSpecs(allocator, &endpoint_specs, &owned_endpoint_fields, hydrated.items.items);

        namespace_status = .{
            .namespace_url = try allocator.dupe(u8, url),
            .workspace_id = try allocator.dupe(u8, resolved_workspace_id),
            .workspace_name = if (hydrated.workspace_name) |value| try allocator.dupe(u8, value) else null,
            .agent_id = try allocator.dupe(u8, resolved_agent_id),
            .session_key = try allocator.dupe(u8, resolved_session_key),
        };
        namespace_client_instance = client;
    }

    if (endpoint_specs.items.len == 0) {
        if (workspace_url != null) {
            std.log.err("no mountable workspace endpoints were returned by control.connect_ack payload.workspace", .{});
            return error.NoWorkspaceMounts;
        }
        if (namespace_url == null) {
            try endpoint_specs.append(allocator, .{
                .name = "a",
                .url = "ws://127.0.0.1:18891/fs",
                .export_name = null,
                .mount_path = "/a",
            });
        }
    }
    if (remaining.items.len == 0) {
        try printHelp();
        return error.InvalidArguments;
    }
    if (workspace_url == null and namespace_url == null) {
        try validateStandaloneEndpointMountPaths(allocator, endpoint_specs.items);
    }

    var router = try fs_router.Router.init(allocator, endpoint_specs.items);
    defer router.deinit();
    const provider = if (namespace_client_instance) |*client|
        try namespace_mount_provider.init(allocator, client)
    else blk: {
        if (workspace_url != null or namespace_url != null) return error.InvalidState;
        break :blk try mount_provider.initRouterProvider(allocator, &router);
    };
    var adapter = fs_fuse_adapter.FuseAdapter.init(allocator, provider);
    defer adapter.deinit();

    const command = remaining.items[0];
    if (std.mem.eql(u8, command, "getattr")) {
        if (remaining.items.len < 2) return error.InvalidArguments;
        const attr = try adapter.getattr(remaining.items[1]);
        defer allocator.free(attr);
        const line = try std.fmt.allocPrint(allocator, "{s}\n", .{attr});
        defer allocator.free(line);
        try std.fs.File.stdout().writeAll(line);
        return;
    }

    if (std.mem.eql(u8, command, "readdir")) {
        if (remaining.items.len < 2) return error.InvalidArguments;
        const cookie = if (remaining.items.len >= 3) try std.fmt.parseInt(u64, remaining.items[2], 10) else 0;
        const max_entries = if (remaining.items.len >= 4) try std.fmt.parseInt(u32, remaining.items[3], 10) else 256;
        const listing = try adapter.readdir(remaining.items[1], cookie, max_entries);
        defer allocator.free(listing);
        const line = try std.fmt.allocPrint(allocator, "{s}\n", .{listing});
        defer allocator.free(line);
        try std.fs.File.stdout().writeAll(line);
        return;
    }

    if (std.mem.eql(u8, command, "cat")) {
        if (remaining.items.len < 2) return error.InvalidArguments;
        const file = try adapter.open(remaining.items[1], 0);
        defer adapter.release(file) catch {};

        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(allocator);
        var offset: u64 = 0;
        const chunk_len: u32 = 256 * 1024;
        while (true) {
            const chunk = try adapter.read(file, offset, chunk_len);
            defer allocator.free(chunk);
            if (chunk.len == 0) break;
            try out.appendSlice(allocator, chunk);
            if (chunk.len < chunk_len) break;
            offset += chunk.len;
        }
        try std.fs.File.stdout().writeAll(out.items);
        return;
    }

    if (std.mem.eql(u8, command, "write")) {
        if (remaining.items.len < 3) return error.InvalidArguments;
        const path = remaining.items[1];
        const content = remaining.items[2];
        const existing_size = getPathSize(&adapter, allocator, path) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };

        const file = adapter.open(path, 2) catch |err| blk: {
            if (err != error.FileNotFound) return err;
            break :blk try adapter.create(path, 0o100644, 2);
        };

        adapter.truncate(path, 0) catch |err| switch (err) {
            error.OperationNotSupported => {
                if (existing_size) |size| {
                    if (size > content.len) return err;
                }
            },
            else => return err,
        };
        _ = try adapter.write(file, 0, content);
        try adapter.release(file);
        try std.fs.File.stdout().writeAll("ok\n");
        return;
    }

    if (std.mem.eql(u8, command, "mkdir")) {
        if (remaining.items.len < 2) return error.InvalidArguments;
        try adapter.mkdir(remaining.items[1]);
        try std.fs.File.stdout().writeAll("ok\n");
        return;
    }

    if (std.mem.eql(u8, command, "rmdir")) {
        if (remaining.items.len < 2) return error.InvalidArguments;
        try adapter.rmdir(remaining.items[1]);
        try std.fs.File.stdout().writeAll("ok\n");
        return;
    }

    if (std.mem.eql(u8, command, "unlink")) {
        if (remaining.items.len < 2) return error.InvalidArguments;
        try adapter.unlink(remaining.items[1]);
        try std.fs.File.stdout().writeAll("ok\n");
        return;
    }

    if (std.mem.eql(u8, command, "rename")) {
        if (remaining.items.len < 3) return error.InvalidArguments;
        try adapter.rename(remaining.items[1], remaining.items[2]);
        try std.fs.File.stdout().writeAll("ok\n");
        return;
    }

    if (std.mem.eql(u8, command, "truncate")) {
        if (remaining.items.len < 3) return error.InvalidArguments;
        const size = try std.fmt.parseInt(u64, remaining.items[2], 10);
        try adapter.truncate(remaining.items[1], size);
        try std.fs.File.stdout().writeAll("ok\n");
        return;
    }

    if (std.mem.eql(u8, command, "status")) {
        if (remaining.items.len > 2) return error.InvalidArguments;
        var force_probe = true;
        if (remaining.items.len == 2) {
            if (std.mem.eql(u8, remaining.items[1], "--no-probe")) {
                force_probe = false;
            } else {
                return error.InvalidArguments;
            }
        }
        const status = if (namespace_status.namespace_url != null)
            try buildNamespaceStatusJson(allocator, &router, namespace_status, force_probe)
        else
            try router.statusJson(force_probe);
        defer allocator.free(status);
        emitLocalMountStatusDiagnostic(allocator, mount_backend);
        const line = try std.fmt.allocPrint(allocator, "{s}\n", .{status});
        defer allocator.free(line);
        try std.fs.File.stdout().writeAll(line);
        return;
    }

    if (std.mem.eql(u8, command, "mount")) {
        if (remaining.items.len < 2) return error.InvalidArguments;
        const mountpoint = remaining.items[1];
        const effective_backend = try resolveRequestedMountBackend(
            allocator,
            mount_backend,
            workspace_url,
            namespace_status,
        );
        if (effective_backend == .native and workspace_url != null and namespace_status.namespace_url == null) {
            namespace_status = try buildNativeNamespaceStatusFromWorkspace(
                allocator,
                workspace_url.?,
                workspace_id,
                workspace_token,
                resolved_workspace_auth_token,
            );
        }
        if (fs_fuse_adapter.mountpointMustExistBeforeMount(effective_backend)) {
            try ensurePathExists(mountpoint);
        }
        if (effective_backend == .native) {
            native_mount_support.validateNativeMountRequest(mountpoint) catch |err| {
                reportMountCommandError(err, mountpoint, effective_backend);
                std.process.exit(2);
            };
            requestNativeMount(
                allocator,
                mountpoint,
                endpoint_specs.items,
                namespace_status,
                workspace_token,
                resolved_workspace_auth_token,
                workspace_sync_interval_ms,
                namespace_keepalive_interval_ms,
            ) catch |err| {
                reportMountCommandError(err, mountpoint, effective_backend);
                return err;
            };
            return;
        }
        fs_fuse_adapter.validateLocalMountRequest(mountpoint, effective_backend) catch |err| {
            reportMountCommandError(err, mountpoint, effective_backend);
            std.process.exit(2);
        };
        fs_fuse_adapter.probeLocalMountBackend(effective_backend) catch |err| {
            reportMountCommandError(err, mountpoint, effective_backend);
            std.process.exit(2);
        };
        if (builtin.os.tag == .windows) {
            if (buildSharedHelperLaunchConfig(
                allocator,
                mountpoint,
                endpoint_specs.items,
                namespace_status,
                workspace_token,
                resolved_workspace_auth_token,
                workspace_sync_interval_ms,
                namespace_keepalive_interval_ms,
            )) |helper_config| {
                defer {
                    for (endpoint_specs.items, 0..) |endpoint, idx| {
                        if (endpoint.mount_path == null) allocator.free(helper_config.endpoints[idx].mount_path);
                    }
                    allocator.free(helper_config.endpoints);
                }
                adapter.enableHelperTransport(helper_config) catch |err| {
                    std.log.warn(
                        "windows shared mount helper unavailable, falling back to in-process WinFsp path: {s}",
                        .{@errorName(err)},
                    );
                };
            } else |err| {
                std.log.warn("windows shared mount helper launch config unavailable: {s}", .{@errorName(err)});
            }
        }
        var sync_ctx: ?*WorkspaceSyncContext = null;
        var sync_thread: ?std.Thread = null;
        var keepalive_ctx: ?*NamespaceKeepaliveContext = null;
        var keepalive_thread: ?std.Thread = null;
        defer {
            if (keepalive_ctx) |ctx| {
                ctx.requestStop();
                if (keepalive_thread) |thread| {
                    thread.join();
                }
                ctx.deinit();
                allocator.destroy(ctx);
            }
            if (sync_ctx) |ctx| {
                ctx.requestStop();
                if (sync_thread) |thread| {
                    thread.join();
                }
                ctx.deinit();
                allocator.destroy(ctx);
            }
        }
        if (workspace_url) |url| {
            if (namespace_client_instance != null) {
                // Attached namespace sessions already carry the live Spiderweb
                // view, so there is nothing client-side to reconcile.
            } else if (workspace_sync_interval_ms > 0) {
                const ctx = try allocator.create(WorkspaceSyncContext);
                errdefer allocator.destroy(ctx);
                ctx.* = .{
                    .allocator = allocator,
                    .adapter = &adapter,
                    .workspace_url = try allocator.dupe(u8, url),
                    .workspace_id = if (workspace_id) |selected_workspace_id| try allocator.dupe(u8, selected_workspace_id) else null,
                    .workspace_token = if (workspace_token) |selected_workspace_token| try allocator.dupe(u8, selected_workspace_token) else null,
                    .auth_token = if (resolved_workspace_auth_token) |token| try allocator.dupe(u8, token) else null,
                    .interval_ms = workspace_sync_interval_ms,
                };
                errdefer allocator.free(ctx.workspace_url);
                errdefer if (ctx.workspace_id) |selected_workspace_id| allocator.free(selected_workspace_id);
                errdefer if (ctx.workspace_token) |selected_workspace_token| allocator.free(selected_workspace_token);
                errdefer if (ctx.auth_token) |token| allocator.free(token);
                sync_thread = try std.Thread.spawn(.{}, workspaceSyncThreadMain, .{ctx});
                sync_ctx = ctx;
            }
        }
        if (namespace_client_instance != null and namespace_keepalive_interval_ms > 0) {
            const ctx = try allocator.create(NamespaceKeepaliveContext);
            errdefer allocator.destroy(ctx);
            ctx.* = .{
                .adapter = &adapter,
                .interval_ms = namespace_keepalive_interval_ms,
            };
            keepalive_thread = try std.Thread.spawn(.{}, namespaceKeepaliveThreadMain, .{ctx});
            keepalive_ctx = ctx;
        }
        if (namespace_client_instance != null) {
            warmDefaultNamespaceViews(allocator, &adapter);
        }
        adapter.mountWithBackend(mountpoint, effective_backend) catch |err| {
            reportMountCommandError(err, mountpoint, effective_backend);
            return err;
        };
        return;
    }

    std.log.err("unknown command: {s}", .{command});
    try printHelp();
    return error.InvalidArguments;
}

fn warmDefaultNamespaceViews(allocator: std.mem.Allocator, adapter: *fs_fuse_adapter.FuseAdapter) void {
    const warm_paths = [_]struct {
        path: []const u8,
        list: bool,
    }{
        .{ .path = "/nodes/local/fs", .list = true },
        .{ .path = "/nodes/local/fs/.spiderweb", .list = true },
        .{ .path = "/shared_data", .list = true },
    };

    for (warm_paths) |entry| {
        warmNamespacePath(allocator, adapter, entry.path, entry.list);
    }
}

fn warmNamespacePath(
    allocator: std.mem.Allocator,
    adapter: *fs_fuse_adapter.FuseAdapter,
    path: []const u8,
    list_children: bool,
) void {
    const deadline = std.time.milliTimestamp() + namespace_warmup_deadline_ms;
    var last_error: ?anyerror = null;

    while (std.time.milliTimestamp() < deadline) {
        const attr_json = adapter.getattr(path) catch |err| {
            last_error = err;
            std.Thread.sleep(namespace_warmup_retry_ms * std.time.ns_per_ms);
            continue;
        };
        allocator.free(attr_json);

        if (!list_children) return;

        const listing_json = adapter.readdir(path, 0, 64) catch |err| {
            last_error = err;
            std.Thread.sleep(namespace_warmup_retry_ms * std.time.ns_per_ms);
            continue;
        };
        allocator.free(listing_json);
        return;
    }

    if (last_error) |err| {
        std.log.warn("namespace warmup incomplete for {s}: {s}", .{ path, @errorName(err) });
    }
}

fn parseEndpointFlag(raw: []const u8) !fs_router.EndpointConfig {
    const eq_idx = std.mem.indexOfScalar(u8, raw, '=') orelse return error.InvalidEndpointFlag;
    const name = raw[0..eq_idx];
    if (name.len == 0) return error.InvalidEndpointFlag;

    var rhs = raw[eq_idx + 1 ..];
    if (rhs.len == 0) return error.InvalidEndpointFlag;

    var mount_path: ?[]const u8 = null;
    if (std.mem.lastIndexOfScalar(u8, rhs, '@')) |at_idx| {
        const maybe_mount = rhs[at_idx + 1 ..];
        if (maybe_mount.len > 0 and maybe_mount[0] == '/') {
            mount_path = maybe_mount;
            rhs = rhs[0..at_idx];
        }
    }

    var export_name: ?[]const u8 = null;
    if (std.mem.lastIndexOfScalar(u8, rhs, '#')) |hash_idx| {
        const maybe_export = rhs[hash_idx + 1 ..];
        if (maybe_export.len == 0) return error.InvalidEndpointFlag;
        export_name = maybe_export;
        rhs = rhs[0..hash_idx];
    }
    const url = rhs;
    if (url.len == 0) return error.InvalidEndpointFlag;

    return .{
        .name = name,
        .url = url,
        .export_name = export_name,
        .mount_path = mount_path,
        .auth_token = null,
    };
}

fn printHelp() !void {
    const help =
        \\spiderweb-fs-mount - Spiderweb namespace mount client
        \\
        \\Usage:
        \\  spiderweb-fs-mount [--workspace-url <ws-url> | --namespace-url <ws-url>] [--workspace-id <id>] [--workspace-token <token>] [--auth-token <token>] [--agent-id <id>] [--session-key <key>] [--mount-backend auto|native|fuse|winfsp] [--workspace-sync-interval-ms <ms>] [--namespace-keepalive-interval-ms <ms>] [--endpoint <name>=<ws-url>[#export][@/mount]] <command> [args]
        \\  Spiderweb workspace mounts have one path: attach a namespace session and mount the Spiderweb-owned view.
        \\  --workspace-url asks Spiderweb control to resolve the workspace and attach a namespace session for it.
        \\  --namespace-url starts from an already attached Spiderweb session.
        \\  The mounted tree must be identical either way; backends consume the Spiderweb namespace and do not implement their own routing, overlays, or bypass rules.
        \\  Standalone --endpoint mode is only for direct endpoint debugging and may not claim Spiderweb-owned roots such as /nodes, /services, /shared_data, /.spiderweb, or /meta.
        \\  On macOS, auto prefers the native FSKit backend and falls back to macFUSE.
        \\  On macOS, native mounts can use any writable absolute mountpoint. Fuse mounts still require /Volumes/<name> and macFUSE 5.x.
        \\
        \\Commands:
        \\  getattr <path>
        \\  readdir <path> [cookie] [max]
        \\  cat <path>
        \\  write <path> <content>
        \\  mkdir <path>
        \\  rmdir <path>
        \\  unlink <path>
        \\  rename <old> <new>
        \\  truncate <path> <size>
        \\  status [--no-probe]
        \\  mount <mountpoint>
        \\
        \\Examples:
        \\  spiderweb-fs-mount --endpoint a=ws://127.0.0.1:18891/fs#work readdir /a
        \\  spiderweb-fs-mount --endpoint a=ws://127.0.0.1:18891/fs#work@/src readdir /src
        \\  spiderweb-fs-mount --endpoint a=ws://127.0.0.1:18891/fs cat /a/README.md
        \\  spiderweb-fs-mount --endpoint a=ws://127.0.0.1:18891/fs status
        \\  spiderweb-fs-mount --workspace-url ws://127.0.0.1:18790/ readdir /
        \\  spiderweb-fs-mount --workspace-url ws://127.0.0.1:18790/ --workspace-id ws-demo --workspace-sync-interval-ms 5000 mount /mnt/spiderweb
        \\  spiderweb-fs-mount --workspace-url ws://127.0.0.1:18790/ --workspace-id ws-demo --mount-backend native mount ~/spiderweb-demo
        \\  spiderweb-fs-mount --workspace-url ws://127.0.0.1:18790/ --workspace-id ws-demo --mount-backend fuse mount /Volumes/spiderweb-demo
        \\  spiderweb-fs-mount --workspace-url ws://127.0.0.1:18790/ --workspace-id ws-demo --workspace-token ws-token-... readdir /
        \\  spiderweb-fs-mount --workspace-url ws://127.0.0.1:18790/ --auth-token sw-admin-... readdir /
        \\  spiderweb-fs-mount --namespace-url ws://127.0.0.1:18790/ --workspace-id ws-demo mount /mnt/spiderweb
        \\  spiderweb-fs-mount --namespace-url ws://127.0.0.1:18790/ --workspace-id ws-demo mount ~/spiderweb-demo
        \\  spiderweb-fs-mount --namespace-url ws://127.0.0.1:18790/ --workspace-id ws-demo --mount-backend winfsp mount X:
        \\  spiderweb-fs-mount --endpoint a=ws://127.0.0.1:18891/fs#work@/a --endpoint b=ws://127.0.0.1:18892/fs#work@/a readdir /a
        \\    (repeat the same mount path to enable failover)
        \\  Auth token for workspace control can also come from SPIDERWEB_AUTH_TOKEN.
        \\
    ;
    try std.fs.File.stdout().writeAll(help);
}

fn validateStandaloneEndpointMountPaths(
    allocator: std.mem.Allocator,
    endpoint_specs: []const fs_router.EndpointConfig,
) !void {
    for (endpoint_specs) |endpoint| {
        const owned_mount_path = if (endpoint.mount_path == null)
            try std.fmt.allocPrint(allocator, "/{s}", .{endpoint.name})
        else
            null;
        defer if (owned_mount_path) |value| allocator.free(value);

        const mount_path = endpoint.mount_path orelse owned_mount_path.?;
        if (!namespace_contract.isReservedStandaloneEndpointMountPath(mount_path)) continue;
        return error.ReservedNamespacePath;
    }
}

const NamespaceStatus = struct {
    namespace_url: ?[]u8 = null,
    workspace_id: ?[]u8 = null,
    workspace_name: ?[]u8 = null,
    agent_id: ?[]u8 = null,
    session_key: ?[]u8 = null,

    fn deinit(self: *NamespaceStatus, allocator: std.mem.Allocator) void {
        if (self.namespace_url) |value| allocator.free(value);
        if (self.workspace_id) |value| allocator.free(value);
        if (self.workspace_name) |value| allocator.free(value);
        if (self.agent_id) |value| allocator.free(value);
        if (self.session_key) |value| allocator.free(value);
        self.* = .{};
    }
};

fn parseMountBackend(raw: []const u8) !fs_fuse_adapter.FuseAdapter.MountBackend {
    if (std.mem.eql(u8, raw, "auto")) return .auto;
    if (std.mem.eql(u8, raw, "native")) return .native;
    if (std.mem.eql(u8, raw, "fuse")) return .fuse;
    if (std.mem.eql(u8, raw, "winfsp")) return .winfsp;
    return error.InvalidArguments;
}

fn emitLocalMountStatusDiagnostic(allocator: std.mem.Allocator, backend: fs_fuse_adapter.FuseAdapter.MountBackend) void {
    if (builtin.os.tag != .macos) return;

    switch (backend) {
        .native => {
            _ = emitNativeStatusDiagnostic(allocator);
        },
        .fuse => emitFuseStatusDiagnostic(.fuse),
        .auto => {
            if (!emitNativeStatusDiagnostic(allocator)) {
                emitFuseStatusDiagnostic(.fuse);
            }
        },
        .winfsp => {
            std.log.warn("local macOS mount backend unavailable: --mount-backend winfsp is Windows-only; use auto, native, or fuse", .{});
        },
    }
}

fn reportMountCommandError(
    err: anyerror,
    mountpoint: []const u8,
    backend: fs_fuse_adapter.FuseAdapter.MountBackend,
) void {
    _ = backend;
    if (builtin.os.tag == .macos) switch (err) {
        error.UnsupportedMountBackend => {
            std.log.err("macOS local mounts do not support that backend; use auto, native, or fuse", .{});
            return;
        },
        error.UnsupportedMacosVersion => {
            std.log.err("macOS native mounts require macOS 15.4+ or newer", .{});
            return;
        },
        error.InvalidMacosMountpoint => {
            std.log.err("macOS native mounts require an absolute writable mountpoint; got {s}", .{mountpoint});
            return;
        },
        error.NativeFsExtensionNotInstalled => {
            std.log.err("macOS native mounts require a current Spiderweb.app Xcode build plus the installed spiderweb.fs wrapper. Build under platform/macos, then run `spiderweb-config config install-fs-extension`.", .{});
            return;
        },
        error.NativeFsExtensionNotReady => {
            std.log.err("macOS native mounts require a current Spiderweb.app build output. Rebuild under platform/macos, reinstall the FS extension, then retry.", .{});
            return;
        },
        error.NativeFsExtensionSigningRequired => {
            std.log.err("macOS native mounts require a real Apple development signing identity. Sign into Xcode, select a development team, rebuild Spiderweb.app, then reinstall the FS extension so the FSKit and app-group entitlements are preserved.", .{});
            return;
        },
        error.NativeFsExtensionCapabilitiesMissing => {
            std.log.err("macOS native mounts require SpiderwebFSKitExtension to carry the FSKit entitlement. Rebuild the Spiderweb app from Xcode with the selected team and retry.", .{});
            return;
        },
        error.NativeFsExtensionProvisioningRequired => {
            std.log.err("macOS native mounts require a signed Spiderweb build from Xcode. Rebuild the app with your selected team and retry.", .{});
            return;
        },
        error.NativeFsExtensionApprovalRequired => {
            std.log.err("macOS native mounts require the Spiderweb file system extension to be enabled in System Settings -> General -> Login Items & Extensions -> File System Extensions.", .{});
            return;
        },
        error.NativeFsExtensionDisabled => {
            std.log.err("macOS sees the Spiderweb module as disabled. Re-enable it in System Settings -> General -> Login Items & Extensions -> File System Extensions after reinstalling a correctly signed build.", .{});
            return;
        },
        error.NativeNamespaceBindingRequired => {
            std.log.err("macOS native mounts currently require a Spiderweb namespace binding. Provide --workspace-url/--workspace-id or a pre-attached namespace before using --mount-backend native.", .{});
            return;
        },
        error.NativeMountTimedOut => {
            std.log.err("macOS native mount request timed out waiting for {s} to appear. Check the Spiderweb app/extension logs and retry.", .{mountpoint});
            return;
        },
        error.MacFuseNotInstalled, error.MountLibraryNotFound => {
            std.log.err("macOS local mounts require macFUSE 5.x. Install it from https://macfuse.github.io/ and retry with /Volumes/<name>", .{});
            return;
        },
        else => {},
    };
}

fn resolveRequestedMountBackend(
    allocator: std.mem.Allocator,
    backend: fs_fuse_adapter.FuseAdapter.MountBackend,
    workspace_url: ?[]const u8,
    namespace_status: NamespaceStatus,
) !fs_fuse_adapter.FuseAdapter.MountBackend {
    if (builtin.os.tag != .macos) return backend;

    return switch (backend) {
        .auto => blk: {
            if (!nativeMountCanBindNamespace(workspace_url, namespace_status)) break :blk .fuse;
            var status = native_mount_support.detectInstallStatus(allocator) catch break :blk .fuse;
            defer status.deinit(allocator);
            break :blk if (status.ready()) .native else .fuse;
        },
        else => backend,
    };
}

fn nativeMountCanBindNamespace(workspace_url: ?[]const u8, namespace_status: NamespaceStatus) bool {
    return workspace_url != null or namespace_status.namespace_url != null;
}

fn emitNativeStatusDiagnostic(allocator: std.mem.Allocator) bool {
    var status = native_mount_support.detectInstallStatus(allocator) catch |err| {
        std.log.warn("local macOS native mount backend probe failed: {s}", .{@errorName(err)});
        return false;
    };
    defer status.deinit(allocator);

    if (!status.supported_os) {
        std.log.warn("local macOS native mount backend unavailable: macOS 15.4+ is required for FSKit mounts", .{});
        return false;
    }
    if (status.ready()) {
        std.log.info("local macOS native mount backend ready: use any writable mountpoint with --mount-backend native", .{});
        return true;
    }

    if (!status.app_installed) {
        std.log.warn("local macOS native mount backend unavailable: build Spiderweb in Xcode under platform/macos, then run `spiderweb-config config install-fs-extension`", .{});
        return false;
    }
    if (!status.extension_present) {
        std.log.warn("local macOS native mount backend unavailable: the current Spiderweb build is missing the FSKit extension payload", .{});
        return false;
    }
    if (!status.filesystem_bundle_installed or !status.mount_helper_present) {
        std.log.warn("local macOS native mount backend unavailable: the spiderweb.fs wrapper is not installed; run `spiderweb-config config install-fs-extension`", .{});
        return false;
    }
    if (!status.runtime_ready) {
        std.log.warn("local macOS native mount backend scaffold detected, but no current Spiderweb build is available; rebuild from platform/macos", .{});
        return false;
    }
    if (!status.signing_identity_available) {
        std.log.warn("local macOS native mount backend needs Xcode signing setup: no valid Apple development code-signing identities were found", .{});
        return false;
    }
    if (!status.extension_fskit_entitled) {
        std.log.warn("local macOS native mount backend is signed, but the current build is missing the FSKit entitlement; native mounts will stay disabled until that capability is preserved", .{});
        return false;
    }
    if (!status.extension_registered) {
        std.log.warn("local macOS native mount backend needs approval: enable Spiderweb in System Settings -> General -> Login Items & Extensions -> File System Extensions", .{});
        return false;
    }
    if (!status.module_enabled) {
        std.log.warn("local macOS native mount backend is installed but still disabled by the OS; enable Spiderweb in File System Extensions and verify the signed entitlements survived install", .{});
        return false;
    }
    return false;
}

fn emitFuseStatusDiagnostic(backend: fs_fuse_adapter.FuseAdapter.MountBackend) void {
    if (!fs_fuse_adapter.isCurrentMacosFskitSupported()) {
        std.log.warn("local macOS fuse backend unavailable: macOS 15.4+ is required for macFUSE FSKit mounts", .{});
        return;
    }

    if (fs_fuse_adapter.probeLocalMountBackend(backend)) |_| {
        std.log.info("local macOS fuse backend ready: use mount /Volumes/<name> with macFUSE 5.x", .{});
    } else |err| switch (err) {
        error.UnsupportedMountBackend => {
            std.log.warn("local macOS fuse backend unavailable: use auto, native, or fuse", .{});
        },
        error.MacFuseNotInstalled => {
            std.log.warn("local macOS fuse backend unavailable: install macFUSE 5.x from https://macfuse.github.io/ and mount under /Volumes/<name>", .{});
        },
        error.UnsupportedMacosVersion => {
            std.log.warn("local macOS fuse backend unavailable: macOS 15.4+ is required for backend=fskit", .{});
        },
        else => {
            std.log.warn("local macOS fuse backend probe failed: {s}", .{@errorName(err)});
        },
    }
}

fn requestNativeMount(
    allocator: std.mem.Allocator,
    mountpoint: []const u8,
    endpoint_specs: []const fs_router.EndpointConfig,
    namespace_status: NamespaceStatus,
    workspace_token: ?[]const u8,
    auth_token: ?[]const u8,
    workspace_sync_interval_ms: u64,
    namespace_keepalive_interval_ms: u64,
) !void {
    const native_endpoints = try allocator.alloc(native_mount_protocol.EndpointSpec, endpoint_specs.len);
    defer allocator.free(native_endpoints);
    const owned_mount_paths = try allocator.alloc(?[]u8, endpoint_specs.len);
    for (owned_mount_paths) |*slot| slot.* = null;
    defer {
        for (owned_mount_paths) |maybe_path| {
            if (maybe_path) |path| allocator.free(path);
        }
        allocator.free(owned_mount_paths);
    }
    for (endpoint_specs, 0..) |endpoint, idx| {
        const mount_path = try resolveNativeEndpointMountPath(allocator, endpoint, &owned_mount_paths[idx]);
        native_endpoints[idx] = .{
            .name = endpoint.name,
            .url = endpoint.url,
            .export_name = endpoint.export_name,
            .mount_path = mount_path,
            .auth_token = endpoint.auth_token orelse auth_token,
        };
    }

    const namespace_binding = try makeNativeNamespaceBinding(namespace_status, workspace_token, auth_token);

    try native_mount_support.requestNativeMount(allocator, .{
        .mountpoint = mountpoint,
        .workspace_sync_interval_ms = workspace_sync_interval_ms,
        .namespace_keepalive_interval_ms = namespace_keepalive_interval_ms,
        .endpoints = native_endpoints,
        .namespace = namespace_binding,
    }, native_mount_timeout_ms, namespace_status.workspace_name);
}

fn buildSharedHelperLaunchConfig(
    allocator: std.mem.Allocator,
    mountpoint: []const u8,
    endpoint_specs: []const fs_router.EndpointConfig,
    namespace_status: NamespaceStatus,
    workspace_token: ?[]const u8,
    auth_token: ?[]const u8,
    workspace_sync_interval_ms: u64,
    namespace_keepalive_interval_ms: u64,
) !native_mount_protocol.LaunchConfig {
    const helper_endpoints = try allocator.alloc(native_mount_protocol.EndpointSpec, endpoint_specs.len);
    errdefer allocator.free(helper_endpoints);
    const owned_mount_paths = try allocator.alloc(?[]u8, endpoint_specs.len);
    for (owned_mount_paths) |*slot| slot.* = null;
    defer allocator.free(owned_mount_paths);
    errdefer {
        for (owned_mount_paths) |maybe_path| {
            if (maybe_path) |path| allocator.free(path);
        }
    }
    for (endpoint_specs, 0..) |endpoint, idx| {
        const mount_path = try resolveNativeEndpointMountPath(allocator, endpoint, &owned_mount_paths[idx]);
        helper_endpoints[idx] = .{
            .name = endpoint.name,
            .url = endpoint.url,
            .export_name = endpoint.export_name,
            .mount_path = mount_path,
            .auth_token = endpoint.auth_token orelse auth_token,
        };
    }

    const namespace_binding = if (namespace_status.namespace_url != null)
        try makeNativeNamespaceBinding(namespace_status, workspace_token, auth_token)
    else
        null;

    return .{
        .mountpoint = mountpoint,
        .workspace_sync_interval_ms = workspace_sync_interval_ms,
        .namespace_keepalive_interval_ms = namespace_keepalive_interval_ms,
        .shared_auth_token = auth_token,
        .endpoints = helper_endpoints,
        .namespace = namespace_binding,
    };
}

fn resolveNativeEndpointMountPath(
    allocator: std.mem.Allocator,
    endpoint: fs_router.EndpointConfig,
    owned_mount_path: *?[]u8,
) ![]const u8 {
    if (endpoint.mount_path) |mount_path| {
        owned_mount_path.* = null;
        return mount_path;
    }

    const default_mount_path = try std.fmt.allocPrint(allocator, "/{s}", .{endpoint.name});
    owned_mount_path.* = default_mount_path;
    return default_mount_path;
}

fn makeNativeNamespaceBinding(
    namespace_status: NamespaceStatus,
    workspace_token: ?[]const u8,
    auth_token: ?[]const u8,
) !native_mount_protocol.NamespaceBinding {
    return .{
        .namespace_url = namespace_status.namespace_url orelse return error.NativeNamespaceBindingRequired,
        .auth_token = auth_token,
        .workspace_id = namespace_status.workspace_id orelse return error.WorkspaceRequired,
        .project_id = namespace_status.workspace_id,
        .agent_id = namespace_status.agent_id orelse return error.InvalidResponse,
        .session_key = namespace_status.session_key orelse return error.InvalidResponse,
        .workspace_token = workspace_token,
        .project_token = workspace_token,
    };
}

fn buildNativeNamespaceStatusFromWorkspace(
    allocator: std.mem.Allocator,
    workspace_url: []const u8,
    workspace_id: ?[]const u8,
    workspace_token: ?[]const u8,
    auth_token: ?[]const u8,
) !NamespaceStatus {
    var client = try namespace_client.NamespaceClient.connect(allocator, workspace_url, auth_token);
    defer client.deinit();

    var connect_info = try client.controlConnect();
    defer connect_info.deinit(allocator);

    const resolved_workspace_id = if (workspace_id) |requested_workspace_id|
        try allocator.dupe(u8, requested_workspace_id)
    else if (connect_info.workspace_id) |connected_workspace_id|
        try allocator.dupe(u8, connected_workspace_id)
    else
        return error.WorkspaceRequired;
    errdefer allocator.free(resolved_workspace_id);

    var state_store = try mount_state.ClientStateStore.init(allocator);
    defer state_store.deinit();

    const resolved_agent_id = try state_store.loadOrCreateAgentId(workspace_url, resolved_workspace_id);
    errdefer allocator.free(resolved_agent_id);

    const resolved_session_key = try mount_state.ClientStateStore.generateEphemeralSessionKey(allocator);
    errdefer allocator.free(resolved_session_key);

    var attach_info = try client.controlSessionAttach(.{
        .session_key = resolved_session_key,
        .agent_id = resolved_agent_id,
        .workspace_id = resolved_workspace_id,
        .workspace_token = workspace_token,
    });
    defer attach_info.deinit(allocator);

    const workspace_status_json = try client.controlWorkspaceStatus(resolved_workspace_id, workspace_token);
    defer allocator.free(workspace_status_json);

    var parsed_status = try std.json.parseFromSlice(std.json.Value, allocator, workspace_status_json, .{});
    defer parsed_status.deinit();
    if (parsed_status.value != .object) return error.InvalidWorkspacePayload;
    const workspace_name = if (getOptionalString(parsed_status.value.object, "workspace_name") orelse
        getOptionalString(parsed_status.value.object, "name") orelse
        getOptionalString(parsed_status.value.object, "project_name")) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (workspace_name) |value| allocator.free(value);

    return .{
        .namespace_url = try allocator.dupe(u8, workspace_url),
        .workspace_id = resolved_workspace_id,
        .workspace_name = workspace_name,
        .agent_id = resolved_agent_id,
        .session_key = resolved_session_key,
    };
}

fn buildNamespaceStatusJson(
    allocator: std.mem.Allocator,
    router: *fs_router.Router,
    namespace_status: NamespaceStatus,
    force_probe: bool,
) ![]u8 {
    const router_status = try router.statusJson(force_probe);
    defer allocator.free(router_status);
    return std.fmt.allocPrint(
        allocator,
        "{{\"mode\":\"namespace\",\"namespace_url\":\"{s}\",\"workspace_id\":\"{s}\",\"workspace_name\":\"{s}\",\"agent_id\":\"{s}\",\"session_key\":\"{s}\",\"router\":{s}}}",
        .{
            namespace_status.namespace_url orelse "",
            namespace_status.workspace_id orelse "",
            namespace_status.workspace_name orelse "",
            namespace_status.agent_id orelse "",
            namespace_status.session_key orelse "",
            router_status,
        },
    );
}

fn appendHydratedEndpointSpecs(
    allocator: std.mem.Allocator,
    endpoint_specs: *std.ArrayListUnmanaged(fs_router.EndpointConfig),
    owned_endpoint_fields: *std.ArrayListUnmanaged([]u8),
    hydrated_items: []const WorkspaceEndpointSpec,
) !void {
    for (hydrated_items) |item| {
        const owned_name = try allocator.dupe(u8, item.name);
        owned_endpoint_fields.append(allocator, owned_name) catch |err| {
            allocator.free(owned_name);
            return err;
        };

        const owned_url = try allocator.dupe(u8, item.url);
        owned_endpoint_fields.append(allocator, owned_url) catch |err| {
            allocator.free(owned_url);
            return err;
        };

        const owned_mount = try allocator.dupe(u8, item.mount_path);
        owned_endpoint_fields.append(allocator, owned_mount) catch |err| {
            allocator.free(owned_mount);
            return err;
        };

        var owned_export: ?[]u8 = null;
        if (item.export_name) |export_name| {
            owned_export = try allocator.dupe(u8, export_name);
            owned_endpoint_fields.append(allocator, owned_export.?) catch |err| {
                allocator.free(owned_export.?);
                return err;
            };
        }

        var owned_auth: ?[]u8 = null;
        if (item.auth_token) |auth_token| {
            owned_auth = try allocator.dupe(u8, auth_token);
            owned_endpoint_fields.append(allocator, owned_auth.?) catch |err| {
                allocator.free(owned_auth.?);
                return err;
            };
        }

        try endpoint_specs.append(allocator, .{
            .name = owned_name,
            .url = owned_url,
            .export_name = owned_export,
            .mount_path = owned_mount,
            .auth_token = owned_auth,
        });
    }
}

fn getPathSize(adapter: *fs_fuse_adapter.FuseAdapter, allocator: std.mem.Allocator, path: []const u8) !?usize {
    const attr_json = adapter.getattr(path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(attr_json);
    return try parseAttrSize(attr_json);
}

fn parseAttrSize(attr_json: []const u8) !usize {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, attr_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const size_value = parsed.value.object.get("sz") orelse return error.InvalidResponse;
    if (size_value != .integer or size_value.integer < 0) return error.InvalidResponse;
    return std.math.cast(usize, size_value.integer) orelse error.InvalidResponse;
}

fn ensurePathExists(path: []const u8) !void {
    if (@import("builtin").os.tag == .windows and path.len == 2 and path[1] == ':') {
        // WinFSP drive-letter mounts target the drive root directly.
        return;
    }
    if (std.fs.path.isAbsolute(path)) {
        if (@import("builtin").os.tag == .windows) {
            if (path.len < 3 or path[1] != ':' or (path[2] != '\\' and path[2] != '/')) return error.InvalidMountpoint;
            const rel = std.mem.trimLeft(u8, path[3..], "\\/");
            if (rel.len == 0) return;
            var root = try std.fs.openDirAbsolute(path[0..3], .{});
            defer root.close();
            try root.makePath(rel);
        } else {
            var root = try std.fs.openDirAbsolute("/", .{});
            defer root.close();
            const rel = std.mem.trimLeft(u8, path, "/");
            if (rel.len == 0) return;
            try root.makePath(rel);
        }
        return;
    }
    try std.fs.cwd().makePath(path);
}

const WorkspaceEndpointSpec = struct {
    name: []u8,
    url: []u8,
    export_name: ?[]u8,
    mount_path: []u8,
    auth_token: ?[]u8,

    fn deinit(self: *WorkspaceEndpointSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.url);
        if (self.export_name) |value| allocator.free(value);
        allocator.free(self.mount_path);
        if (self.auth_token) |value| allocator.free(value);
        self.* = undefined;
    }
};

const WorkspaceEndpointSpecs = struct {
    allocator: std.mem.Allocator,
    workspace_name: ?[]u8 = null,
    items: std.ArrayListUnmanaged(WorkspaceEndpointSpec) = .{},

    fn deinit(self: *WorkspaceEndpointSpecs, allocator: std.mem.Allocator) void {
        _ = allocator;
        if (self.workspace_name) |value| self.allocator.free(value);
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }
};

const ParsedWsUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

const WsFrame = struct {
    opcode: u8,
    payload: []u8,

    fn deinit(self: *WsFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }
};

const WorkspaceSyncContext = struct {
    allocator: std.mem.Allocator,
    adapter: *fs_fuse_adapter.FuseAdapter,
    workspace_url: []u8,
    workspace_id: ?[]u8 = null,
    workspace_token: ?[]u8 = null,
    auth_token: ?[]u8 = null,
    interval_ms: u64,
    stop: bool = false,
    stop_mutex: std.Thread.Mutex = .{},
    force_refresh: bool = false,
    force_refresh_mutex: std.Thread.Mutex = .{},

    fn requestStop(self: *WorkspaceSyncContext) void {
        self.stop_mutex.lock();
        self.stop = true;
        self.stop_mutex.unlock();
    }

    fn shouldStop(self: *WorkspaceSyncContext) bool {
        self.stop_mutex.lock();
        defer self.stop_mutex.unlock();
        return self.stop;
    }

    fn deinit(self: *WorkspaceSyncContext) void {
        self.allocator.free(self.workspace_url);
        if (self.workspace_id) |selected_workspace_id| self.allocator.free(selected_workspace_id);
        if (self.workspace_token) |selected_workspace_token| self.allocator.free(selected_workspace_token);
        if (self.auth_token) |token| self.allocator.free(token);
        self.* = undefined;
    }

    fn requestRefresh(self: *WorkspaceSyncContext) void {
        self.force_refresh_mutex.lock();
        self.force_refresh = true;
        self.force_refresh_mutex.unlock();
    }

    fn takeRefreshRequest(self: *WorkspaceSyncContext) bool {
        self.force_refresh_mutex.lock();
        defer self.force_refresh_mutex.unlock();
        const refresh = self.force_refresh;
        self.force_refresh = false;
        return refresh;
    }
};

const NamespaceKeepaliveContext = struct {
    adapter: *fs_fuse_adapter.FuseAdapter,
    interval_ms: u64,
    stop: bool = false,
    stop_mutex: std.Thread.Mutex = .{},

    fn requestStop(self: *NamespaceKeepaliveContext) void {
        self.stop_mutex.lock();
        self.stop = true;
        self.stop_mutex.unlock();
    }

    fn shouldStop(self: *NamespaceKeepaliveContext) bool {
        self.stop_mutex.lock();
        defer self.stop_mutex.unlock();
        return self.stop;
    }

    fn deinit(self: *NamespaceKeepaliveContext) void {
        self.* = undefined;
    }
};

fn workspaceSyncThreadMain(ctx: *WorkspaceSyncContext) void {
    const allocator = std.heap.page_allocator;
    ctx.requestRefresh();
    var last_poll_ms: i64 = 0;

    while (true) {
        if (ctx.shouldStop()) return;

        const now_ms = std.time.milliTimestamp();
        const interval_due = ctx.interval_ms > 0 and (last_poll_ms == 0 or now_ms - last_poll_ms >= @as(i64, @intCast(ctx.interval_ms)));
        const should_refresh = ctx.takeRefreshRequest() or interval_due;

        if (should_refresh) {
            tryRefreshWorkspaceTopology(allocator, ctx);
            last_poll_ms = now_ms;
        }

        if (!sleepWithStop(ctx, 250)) return;
    }
}

fn namespaceKeepaliveThreadMain(ctx: *NamespaceKeepaliveContext) void {
    while (true) {
        if (!sleepNamespaceKeepalive(ctx, ctx.interval_ms)) return;
        _ = ctx.adapter.tryKeepAliveIfIdle() catch |err| {
            std.log.warn("namespace keepalive failed: {s}", .{@errorName(err)});
        };
    }
}

fn tryRefreshWorkspaceTopology(allocator: std.mem.Allocator, ctx: *WorkspaceSyncContext) void {
    var specs = fetchWorkspaceEndpointSpecs(
        allocator,
        ctx.workspace_url,
        if (ctx.workspace_id) |selected_workspace_id| selected_workspace_id else null,
        if (ctx.workspace_token) |selected_workspace_token| selected_workspace_token else null,
        if (ctx.auth_token) |token| token else null,
    ) catch |err| {
        std.log.warn("workspace sync: fetch workspace endpoint specs failed: {s}", .{@errorName(err)});
        return;
    };
    defer specs.deinit(allocator);

    const endpoint_configs = allocator.alloc(fs_router.EndpointConfig, specs.items.items.len) catch |err| {
        std.log.warn("workspace sync: alloc endpoint configs failed: {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(endpoint_configs);

    for (specs.items.items, 0..) |item, idx| {
        endpoint_configs[idx] = .{
            .name = item.name,
            .url = item.url,
            .export_name = item.export_name,
            .mount_path = item.mount_path,
            .auth_token = item.auth_token,
        };
    }

    _ = ctx.adapter.tryReconcileEndpointsIfIdle(endpoint_configs) catch |err| {
        std.log.warn("workspace sync: reconcile failed: {s}", .{@errorName(err)});
        return;
    };
}

fn waitReadable(stream: *std.net.Stream, timeout_ms: i32) !bool {
    var fds = [_]std.posix.pollfd{
        .{
            .fd = stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    const ready = try std.posix.poll(&fds, timeout_ms);
    if (ready == 0) return false;
    if ((fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0) {
        return error.ConnectionClosed;
    }
    return (fds[0].revents & std.posix.POLL.IN) != 0;
}

fn sleepWithStop(ctx: *WorkspaceSyncContext, total_ms: u64) bool {
    if (total_ms == 0) return !ctx.shouldStop();
    var elapsed: u64 = 0;
    while (elapsed < total_ms) {
        if (ctx.shouldStop()) return false;
        const chunk_ms: u64 = @min(@as(u64, 250), total_ms - elapsed);
        std.Thread.sleep(chunk_ms * std.time.ns_per_ms);
        elapsed += chunk_ms;
    }
    return !ctx.shouldStop();
}

fn sleepNamespaceKeepalive(ctx: *NamespaceKeepaliveContext, total_ms: u64) bool {
    if (total_ms == 0) return !ctx.shouldStop();
    var elapsed: u64 = 0;
    while (elapsed < total_ms) {
        if (ctx.shouldStop()) return false;
        const chunk_ms: u64 = @min(@as(u64, 250), total_ms - elapsed);
        std.Thread.sleep(chunk_ms * std.time.ns_per_ms);
        elapsed += chunk_ms;
    }
    return !ctx.shouldStop();
}

fn fetchWorkspaceEndpointSpecs(
    allocator: std.mem.Allocator,
    workspace_url: []const u8,
    workspace_id: ?[]const u8,
    workspace_token: ?[]const u8,
    auth_token: ?[]const u8,
) !WorkspaceEndpointSpecs {
    var specs = WorkspaceEndpointSpecs{ .allocator = allocator };
    errdefer specs.deinit(allocator);

    var client = try namespace_client.NamespaceClient.connect(allocator, workspace_url, auth_token);
    defer client.deinit();

    var connect_info = try client.controlConnect();
    defer connect_info.deinit(allocator);

    if (!shouldFetchWorkspaceStatusFromControl(
        workspace_id,
        workspace_token,
        connect_info.workspace_id,
        connect_info.has_workspace_mounts,
    )) {
        if (connect_info.workspace_json) |workspace_json| {
            var parsed_workspace = try std.json.parseFromSlice(std.json.Value, allocator, workspace_json, .{});
            defer parsed_workspace.deinit();
            if (parsed_workspace.value != .object) return error.InvalidWorkspacePayload;
            try appendWorkspaceMountSpecsFromStatusObject(allocator, &specs, parsed_workspace.value.object);
            return specs;
        }
    }

    const effective_workspace_id = workspace_id orelse connect_info.workspace_id;
    const payload_json = try client.controlWorkspaceStatus(effective_workspace_id, workspace_token);
    defer allocator.free(payload_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidWorkspacePayload;
    try appendWorkspaceMountSpecsFromStatusObject(allocator, &specs, parsed.value.object);

    return specs;
}

fn shouldFetchWorkspaceStatusFromControl(
    requested_workspace_id: ?[]const u8,
    requested_workspace_token: ?[]const u8,
    connected_workspace_id: ?[]const u8,
    connect_has_workspace_mounts: bool,
) bool {
    if (requested_workspace_token != null) return true;
    if (requested_workspace_id) |selected_workspace| {
        if (connected_workspace_id) |connected_workspace| {
            if (!std.mem.eql(u8, selected_workspace, connected_workspace)) return true;
            return !connect_has_workspace_mounts;
        }
        return true;
    }
    return !connect_has_workspace_mounts;
}

fn connectWorkspaceHasMounts(connect_workspace: ?std.json.Value) bool {
    const workspace_value = connect_workspace orelse return false;
    if (workspace_value != .object) return false;
    const mounts_value = workspace_value.object.get("mounts") orelse return false;
    if (mounts_value != .array) return false;
    return mounts_value.array.items.len > 0;
}

fn appendWorkspaceMountSpecsFromStatusObject(
    allocator: std.mem.Allocator,
    specs: *WorkspaceEndpointSpecs,
    status_obj: std.json.ObjectMap,
) !void {
    if (specs.workspace_name == null) {
        const workspace_name = getOptionalString(status_obj, "workspace_name") orelse
            getOptionalString(status_obj, "name") orelse
            getOptionalString(status_obj, "project_name");
        if (workspace_name) |value| {
            specs.workspace_name = try allocator.dupe(u8, value);
        }
    }

    const mounts_value = status_obj.get("mounts") orelse return;
    if (mounts_value != .array) return error.InvalidWorkspacePayload;

    for (mounts_value.array.items) |item| {
        if (item != .object) return error.InvalidWorkspacePayload;
        const mount_path_val = item.object.get("mount_path") orelse return error.InvalidWorkspacePayload;
        if (mount_path_val != .string or mount_path_val.string.len == 0) return error.InvalidWorkspacePayload;

        const url_val = item.object.get("fs_url") orelse continue;
        if (url_val != .string) continue;
        if (url_val.string.len == 0) continue;
        if (!std.mem.startsWith(u8, url_val.string, "ws://")) continue;
        if (std.mem.indexOf(u8, url_val.string, "/fs") == null) continue;

        const node_id = if (item.object.get("node_id")) |value|
            if (value == .string and value.string.len > 0) value.string else "node"
        else
            "node";
        const node_name = if (item.object.get("node_name")) |value|
            if (value == .string and value.string.len > 0) value.string else node_id
        else
            node_id;
        const export_name = if (item.object.get("export_name")) |value|
            if (value == .string and value.string.len > 0) value.string else null
        else
            null;
        const auth_token = if (item.object.get("fs_auth_token")) |value|
            if (value == .string and value.string.len > 0) value.string else null
        else
            null;

        const spec = WorkspaceEndpointSpec{
            .name = try allocator.dupe(u8, node_name),
            .url = try allocator.dupe(u8, url_val.string),
            .export_name = if (export_name) |value| try allocator.dupe(u8, value) else null,
            .mount_path = try allocator.dupe(u8, mount_path_val.string),
            .auth_token = if (auth_token) |value| try allocator.dupe(u8, value) else null,
        };
        try specs.items.append(allocator, spec);
    }
}

fn getOptionalString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn negotiateControlVersion(
    allocator: std.mem.Allocator,
    stream: *std.net.Stream,
    request_id: []const u8,
) !void {
    const message = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"{s}\",\"payload\":{{\"protocol\":\"spiderweb-control\"}}}}",
        .{request_id},
    );
    defer allocator.free(message);
    try writeClientTextFrameMasked(allocator, stream, message);
    const payload = try readControlPayloadFor(allocator, stream, request_id, "control.version_ack");
    allocator.free(payload);
}

fn parseWsUrlWithDefaultPath(url: []const u8, default_path: []const u8) !ParsedWsUrl {
    const prefix = "ws://";
    if (!std.mem.startsWith(u8, url, prefix)) return error.InvalidUrl;
    const rest = url[prefix.len..];

    const slash_idx = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..slash_idx];
    const path = if (slash_idx < rest.len) rest[slash_idx..] else default_path;
    if (host_port.len == 0) return error.InvalidUrl;

    if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |colon_idx| {
        const host = host_port[0..colon_idx];
        const port_str = host_port[colon_idx + 1 ..];
        if (host.len == 0 or port_str.len == 0) return error.InvalidUrl;
        const port = try std.fmt.parseInt(u16, port_str, 10);
        return .{ .host = host, .port = port, .path = path };
    }
    return .{ .host = host_port, .port = 80, .path = path };
}

fn performClientHandshake(
    allocator: std.mem.Allocator,
    stream: *std.net.Stream,
    host: []const u8,
    port: u16,
    path: []const u8,
    auth_token: ?[]const u8,
) !void {
    var nonce: [16]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    var encoded_nonce: [std.base64.standard.Encoder.calcSize(nonce.len)]u8 = undefined;
    const key = std.base64.standard.Encoder.encode(&encoded_nonce, &nonce);
    const authorization_line = if (auth_token) |token|
        try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}\r\n", .{token})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(authorization_line);

    const request = try std.fmt.allocPrint(
        allocator,
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}:{d}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "{s}\r\n",
        .{ path, host, port, key, authorization_line },
    );
    defer allocator.free(request);

    try socketWriteAll(stream, request);

    const response = try readHttpResponse(allocator, stream, 8 * 1024);
    defer allocator.free(response);
    if (std.mem.indexOf(u8, response, " 101 ") == null and std.mem.indexOf(u8, response, " 101\r\n") == null) {
        return error.HandshakeRejected;
    }
}

fn readHttpResponse(allocator: std.mem.Allocator, stream: *std.net.Stream, max_bytes: usize) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    const deadline_ms = std.time.milliTimestamp() + @as(i64, control_handshake_timeout_ms);
    var chunk: [512]u8 = undefined;
    while (out.items.len < max_bytes) {
        const now_ms = std.time.milliTimestamp();
        if (now_ms >= deadline_ms) return error.ControlHandshakeTimeout;
        const remaining_i64 = deadline_ms - now_ms;
        const remaining_ms: i32 = @intCast(@min(remaining_i64, @as(i64, std.math.maxInt(i32))));
        if (!try waitReadable(stream, remaining_ms)) return error.ControlHandshakeTimeout;
        const n = try socketRead(stream, &chunk);
        if (n == 0) return error.ConnectionClosed;
        try out.appendSlice(allocator, chunk[0..n]);
        if (std.mem.indexOf(u8, out.items, "\r\n\r\n") != null) {
            return out.toOwnedSlice(allocator);
        }
    }
    return error.ResponseTooLarge;
}

fn readControlPayloadFor(
    allocator: std.mem.Allocator,
    stream: *std.net.Stream,
    expected_id: []const u8,
    expected_type: []const u8,
) ![]u8 {
    const deadline_ms = std.time.milliTimestamp() + @as(i64, control_reply_timeout_ms);
    while (true) {
        const now_ms = std.time.milliTimestamp();
        if (now_ms >= deadline_ms) return error.ControlRequestTimeout;
        const remaining_i64 = deadline_ms - now_ms;
        const remaining_ms: i32 = @intCast(@min(remaining_i64, @as(i64, std.math.maxInt(i32))));
        if (!try waitReadable(stream, remaining_ms)) {
            return error.ControlRequestTimeout;
        }
        var frame = try readServerFrame(allocator, stream, 4 * 1024 * 1024);
        defer frame.deinit(allocator);

        switch (frame.opcode) {
            0x1 => {
                var parsed = try std.json.parseFromSlice(std.json.Value, allocator, frame.payload, .{});
                defer parsed.deinit();
                if (parsed.value != .object) continue;
                const root = parsed.value.object;

                const channel = root.get("channel") orelse continue;
                if (channel != .string or !std.mem.eql(u8, channel.string, "control")) continue;

                const msg_id = root.get("id") orelse continue;
                if (msg_id != .string or !std.mem.eql(u8, msg_id.string, expected_id)) continue;

                const msg_type = root.get("type") orelse continue;
                if (msg_type != .string) continue;
                if (std.mem.eql(u8, msg_type.string, "control.error")) {
                    return error.ControlRequestFailed;
                }
                if (!std.mem.eql(u8, msg_type.string, expected_type)) {
                    return error.UnexpectedControlResponse;
                }

                const payload = root.get("payload") orelse return allocator.dupe(u8, "{}");
                return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(payload, .{})});
            },
            0x8 => return error.ConnectionClosed,
            0x9 => try writeClientPongFrameMasked(allocator, stream, frame.payload),
            0xA => {},
            else => return error.InvalidFrameOpcode,
        }
    }
}

fn readServerFrame(allocator: std.mem.Allocator, stream: *std.net.Stream, max_payload_bytes: usize) !WsFrame {
    var header: [2]u8 = undefined;
    try readExact(stream, &header);

    const fin = (header[0] & 0x80) != 0;
    if (!fin) return error.UnsupportedFragmentation;
    const opcode = header[0] & 0x0F;
    const masked = (header[1] & 0x80) != 0;
    if (masked) return error.UnexpectedMaskedFrame;

    var payload_len: usize = header[1] & 0x7F;
    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        try readExact(stream, &ext);
        payload_len = std.mem.readInt(u16, &ext, .big);
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        try readExact(stream, &ext);
        payload_len = @intCast(std.mem.readInt(u64, &ext, .big));
    }
    if (payload_len > max_payload_bytes) return error.FrameTooLarge;

    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    if (payload_len > 0) try readExact(stream, payload);
    return .{ .opcode = opcode, .payload = payload };
}

fn writeClientTextFrameMasked(allocator: std.mem.Allocator, stream: *std.net.Stream, payload: []const u8) !void {
    try writeClientFrameMasked(allocator, stream, payload, 0x1);
}

fn writeClientPongFrameMasked(allocator: std.mem.Allocator, stream: *std.net.Stream, payload: []const u8) !void {
    try writeClientFrameMasked(allocator, stream, payload, 0xA);
}

fn writeClientFrameMasked(allocator: std.mem.Allocator, stream: *std.net.Stream, payload: []const u8, opcode: u8) !void {
    var header: [14]u8 = undefined;
    var header_len: usize = 2;
    header[0] = 0x80 | opcode;

    if (payload.len < 126) {
        header[1] = 0x80 | @as(u8, @intCast(payload.len));
    } else if (payload.len <= std.math.maxInt(u16)) {
        header[1] = 0x80 | 126;
        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        header_len = 4;
    } else {
        header[1] = 0x80 | 127;
        std.mem.writeInt(u64, header[2..10], payload.len, .big);
        header_len = 10;
    }

    var mask_key: [4]u8 = undefined;
    std.crypto.random.bytes(&mask_key);
    @memcpy(header[header_len .. header_len + 4], &mask_key);
    header_len += 4;

    const masked_payload = try allocator.alloc(u8, payload.len);
    defer allocator.free(masked_payload);
    for (payload, 0..) |byte, idx| {
        masked_payload[idx] = byte ^ mask_key[idx % 4];
    }

    try socketWriteAll(stream, header[0..header_len]);
    if (masked_payload.len > 0) try socketWriteAll(stream, masked_payload);
}

fn readExact(stream: *std.net.Stream, out: []u8) !void {
    var offset: usize = 0;
    while (offset < out.len) {
        const n = try socketRead(stream, out[offset..]);
        if (n == 0) return error.EndOfStream;
        offset += n;
    }
}

fn socketRead(stream: *std.net.Stream, buffer: []u8) !usize {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const ws2_32 = windows.ws2_32;
        const rc = ws2_32.recv(stream.handle, buffer.ptr, @intCast(@min(buffer.len, std.math.maxInt(i32))), 0);
        if (rc == ws2_32.SOCKET_ERROR) {
            return switch (ws2_32.WSAGetLastError()) {
                .WSAEWOULDBLOCK => error.WouldBlock,
                .WSAETIMEDOUT => error.TimedOut,
                .WSAECONNRESET, .WSAECONNABORTED, .WSAENOTCONN => error.ConnectionResetByPeer,
                else => |err| windows.unexpectedWSAError(err),
            };
        }
        return @intCast(rc);
    }
    return std.posix.recv(stream.handle, buffer, 0);
}

fn socketWriteAll(stream: *std.net.Stream, data: []const u8) !void {
    var offset: usize = 0;
    while (offset < data.len) {
        const written: usize = if (builtin.os.tag == .windows) blk: {
            const windows = std.os.windows;
            const ws2_32 = windows.ws2_32;
            const chunk = data[offset..];
            const rc = ws2_32.send(stream.handle, chunk.ptr, @intCast(@min(chunk.len, std.math.maxInt(i32))), 0);
            if (rc == ws2_32.SOCKET_ERROR) {
                return switch (ws2_32.WSAGetLastError()) {
                    .WSAEWOULDBLOCK => error.WouldBlock,
                    .WSAETIMEDOUT => error.TimedOut,
                    .WSAECONNRESET, .WSAECONNABORTED, .WSAENOTCONN => error.ConnectionResetByPeer,
                    else => |err| windows.unexpectedWSAError(err),
                };
            }
            break :blk @as(usize, @intCast(rc));
        } else try std.posix.send(stream.handle, data[offset..], 0);
        if (written == 0) return error.ConnectionClosed;
        offset += written;
    }
}

fn jsonEscape(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    for (value) |char| {
        switch (char) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => if (char < 0x20) {
                try out.writer(allocator).print("\\u00{x:0>2}", .{char});
            } else {
                try out.append(allocator, char);
            },
        }
    }

    return out.toOwnedSlice(allocator);
}

const LiveSmokeConfig = struct {
    url: []u8,
    workspace_id: []u8,
    auth_token: []u8,

    fn deinit(self: *LiveSmokeConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.workspace_id);
        allocator.free(self.auth_token);
        self.* = undefined;
    }
};

fn loadLiveSmokeConfig(allocator: std.mem.Allocator) !?LiveSmokeConfig {
    const url = std.process.getEnvVarOwned(allocator, "SPIDERWEB_LIVE_SMOKE_URL") catch return null;
    errdefer allocator.free(url);
    const workspace_id = std.process.getEnvVarOwned(allocator, "SPIDERWEB_LIVE_SMOKE_PROJECT_ID") catch return null;
    errdefer allocator.free(workspace_id);
    const auth_token = std.process.getEnvVarOwned(allocator, "SPIDERWEB_LIVE_SMOKE_AUTH_TOKEN") catch return null;
    errdefer allocator.free(auth_token);
    return .{
        .url = url,
        .workspace_id = workspace_id,
        .auth_token = auth_token,
    };
}

fn liveSmokeReadFile(
    allocator: std.mem.Allocator,
    client: *namespace_client.NamespaceClient,
    path: []const u8,
) ![]u8 {
    const file = try client.open(path, 0);
    defer client.release(file) catch {};

    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);
    var offset: u64 = 0;
    const chunk_len: u32 = 256 * 1024;
    while (true) {
        const chunk = try client.read(file, offset, chunk_len);
        defer allocator.free(chunk);
        if (chunk.len == 0) break;
        try out.appendSlice(allocator, chunk);
        if (chunk.len < chunk_len) break;
        offset += chunk.len;
    }
    return out.toOwnedSlice(allocator);
}

fn liveSmokeWriteFile(client: *namespace_client.NamespaceClient, path: []const u8, content: []const u8) !void {
    const file = try client.open(path, 2);
    errdefer client.release(file) catch {};
    _ = try client.write(file, 0, content);
    try client.release(file);
}

test "acheron_mount_main: parseEndpointFlag supports explicit mount path" {
    const parsed = try parseEndpointFlag("a=ws://127.0.0.1:18891/fs#work@/src");
    try std.testing.expectEqualStrings("a", parsed.name);
    try std.testing.expectEqualStrings("ws://127.0.0.1:18891/fs", parsed.url);
    try std.testing.expectEqualStrings("work", parsed.export_name.?);
    try std.testing.expectEqualStrings("/src", parsed.mount_path.?);
}

test "acheron_mount_main: parseEndpointFlag defaults mount path to endpoint name" {
    const parsed = try parseEndpointFlag("alpha=ws://127.0.0.1:18891/fs#work");
    try std.testing.expectEqualStrings("alpha", parsed.name);
    try std.testing.expectEqualStrings("ws://127.0.0.1:18891/fs", parsed.url);
    try std.testing.expectEqualStrings("work", parsed.export_name.?);
    try std.testing.expect(parsed.mount_path == null);
}

test "acheron_mount_main: shouldFetchWorkspaceStatusFromControl only falls back when needed" {
    try std.testing.expect(!shouldFetchWorkspaceStatusFromControl(null, null, "proj-a", true));
    try std.testing.expect(shouldFetchWorkspaceStatusFromControl(null, null, "proj-a", false));

    try std.testing.expect(!shouldFetchWorkspaceStatusFromControl("proj-a", null, "proj-a", true));
    try std.testing.expect(shouldFetchWorkspaceStatusFromControl("proj-a", null, "proj-b", true));
    try std.testing.expect(shouldFetchWorkspaceStatusFromControl("proj-a", null, null, true));
    try std.testing.expect(shouldFetchWorkspaceStatusFromControl("proj-a", "token-a", "proj-a", true));
}

test "acheron_mount_main: connectWorkspaceHasMounts requires non-empty mounts array" {
    const allocator = std.testing.allocator;

    var parsed_empty = try std.json.parseFromSlice(std.json.Value, allocator, "{\"workspace\":{}}", .{});
    defer parsed_empty.deinit();
    try std.testing.expect(!connectWorkspaceHasMounts(parsed_empty.value.object.get("workspace")));

    var parsed_empty_mounts = try std.json.parseFromSlice(std.json.Value, allocator, "{\"workspace\":{\"mounts\":[]}}", .{});
    defer parsed_empty_mounts.deinit();
    try std.testing.expect(!connectWorkspaceHasMounts(parsed_empty_mounts.value.object.get("workspace")));

    var parsed_with_mount = try std.json.parseFromSlice(std.json.Value, allocator, "{\"workspace\":{\"mounts\":[{\"mount_path\":\"/m\",\"fs_url\":\"ws://127.0.0.1:18891/fs\"}]}}", .{});
    defer parsed_with_mount.deinit();
    try std.testing.expect(connectWorkspaceHasMounts(parsed_with_mount.value.object.get("workspace")));
}

test "acheron_mount_main: workspace status parsing tolerates deprecated metadata without changing mount resolution" {
    const allocator = std.testing.allocator;
    var specs = WorkspaceEndpointSpecs{ .allocator = allocator };
    defer specs.deinit(allocator);

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"mounts\":[{\"mount_path\":\"/nodes/local/fs\",\"fs_url\":\"ws://127.0.0.1:18891/fs\",\"namespace_owned_subpaths\":[\"/AGENTS.md\",\"/.spiderweb\"]}]}",
        .{},
    );
    defer parsed.deinit();

    try appendWorkspaceMountSpecsFromStatusObject(allocator, &specs, parsed.value.object);
    try std.testing.expectEqual(@as(usize, 1), specs.items.items.len);
    try std.testing.expectEqualStrings("/nodes/local/fs", specs.items.items[0].mount_path);
    try std.testing.expectEqualStrings("ws://127.0.0.1:18891/fs", specs.items.items[0].url);
}

test "acheron_mount_main: standalone endpoint mode rejects Spiderweb namespace roots" {
    const allocator = std.testing.allocator;
    const endpoint_specs = [_]fs_router.EndpointConfig{
        .{
            .name = "local",
            .url = "ws://127.0.0.1:18891/fs",
            .export_name = null,
            .mount_path = "/nodes/local/fs",
        },
    };

    try std.testing.expectError(
        error.ReservedNamespacePath,
        validateStandaloneEndpointMountPaths(allocator, &endpoint_specs),
    );
}

test "acheron_mount_main: auto native backend requires namespace binding" {
    try std.testing.expect(!nativeMountCanBindNamespace(null, .{}));
    try std.testing.expect(nativeMountCanBindNamespace("ws://127.0.0.1:18790/", .{}));
    try std.testing.expect(nativeMountCanBindNamespace(null, .{ .namespace_url = @constCast("ws://127.0.0.1:18790/control") }));
}

test "acheron_mount_main: explicit native mount requires namespace binding" {
    try std.testing.expectError(error.NativeNamespaceBindingRequired, makeNativeNamespaceBinding(.{}, null, null));
}

test "acheron_mount_main: live mac smoke covers terminal exec" {
    if (builtin.os.tag != .macos) return;

    const allocator = std.testing.allocator;
    var live = (try loadLiveSmokeConfig(allocator)) orelse return;
    defer live.deinit(allocator);

    var client = try namespace_client.NamespaceClient.connect(allocator, live.url, live.auth_token);
    defer client.deinit();

    var connect_info = try client.controlConnect();
    defer connect_info.deinit(allocator);

    const session_key = try std.fmt.allocPrint(allocator, "mac-live-smoke-{d}", .{std.time.milliTimestamp()});
    defer allocator.free(session_key);
    const agent_id = "mac-live-smoke-agent";

    var attach_info = try client.controlSessionAttach(.{
        .session_key = session_key,
        .agent_id = agent_id,
        .workspace_id = live.workspace_id,
    });
    defer attach_info.deinit(allocator);
    try client.attachNamespaceRoot(attach_info.session_key);

    const terminal_status_descriptor = try liveSmokeReadFile(allocator, &client, "/nodes/local/venoms/terminal/STATUS.json");
    defer allocator.free(terminal_status_descriptor);
    try std.testing.expect(std.mem.indexOf(u8, terminal_status_descriptor, "\"interactive\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal_status_descriptor, "\"sessionized\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal_status_descriptor, "\"pty\":false") != null);

    try liveSmokeWriteFile(
        &client,
        "/nodes/local/venoms/terminal/control/exec.json",
        "{\"command\":\"printf terminal-ok\"}",
    );

    const terminal_status = try liveSmokeReadFile(allocator, &client, "/nodes/local/venoms/terminal/status.json");
    defer allocator.free(terminal_status);
    try std.testing.expect(std.mem.indexOf(u8, terminal_status, "\"state\":\"done\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal_status, "\"tool\":\"shell_exec\"") != null);

    const terminal_result = try liveSmokeReadFile(allocator, &client, "/nodes/local/venoms/terminal/result.json");
    defer allocator.free(terminal_result);
    try std.testing.expect(std.mem.indexOf(u8, terminal_result, "\"operation\":\"exec\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal_result, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal_result, "dGVybWluYWwtb2s=") != null);

    const terminal_current = try liveSmokeReadFile(allocator, &client, "/nodes/local/venoms/terminal/current.json");
    defer allocator.free(terminal_current);
    try std.testing.expect(std.mem.indexOf(u8, terminal_current, "\"session\":null") != null);
}
