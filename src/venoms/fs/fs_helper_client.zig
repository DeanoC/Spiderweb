const builtin = @import("builtin");
const std = @import("std");
const fs_router = @import("acheron_fs_router");
const mount_provider = @import("spiderweb_mount_provider");
const native_protocol = @import("spiderweb_native_mount_protocol");

pub const HelperClient = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    stdin_file: std.fs.File,
    stdout_file: std.fs.File,
    config_path: []u8,
    shared_auth_token: ?[]u8 = null,
    auth_token_by_endpoint_name: std.StringHashMapUnmanaged([]u8) = .{},
    mutex: std.Thread.Mutex = .{},

    pub fn start(allocator: std.mem.Allocator, config: native_protocol.LaunchConfig) !HelperClient {
        const config_path = try writeLaunchConfig(allocator, config);
        errdefer deleteConfigFileBestEffort(config_path);
        errdefer allocator.free(config_path);

        const helper_exe = try resolveHelperExecutablePath(allocator);
        defer allocator.free(helper_exe);

        var child = std.process.Child.init(&.{ helper_exe, "serve", "--config", config_path }, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        try child.spawn();
        errdefer {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
        }

        const stdin_file = child.stdin.?;
        const stdout_file = child.stdout.?;
        const shared_auth_token = if (config.shared_auth_token) |auth_token|
            try allocator.dupe(u8, auth_token)
        else if (config.namespace) |namespace|
            if (namespace.auth_token) |auth_token|
                try allocator.dupe(u8, auth_token)
            else
                null
        else
            null;
        errdefer if (shared_auth_token) |auth_token| allocator.free(auth_token);

        var client = HelperClient{
            .allocator = allocator,
            .child = child,
            .stdin_file = stdin_file,
            .stdout_file = stdout_file,
            .config_path = config_path,
            .shared_auth_token = shared_auth_token,
        };
        errdefer client.deinit();

        try client.rememberConfiguredEndpointAuths(config.endpoints);
        try client.ping();
        return client;
    }

    pub fn deinit(self: *HelperClient) void {
        self.stdin_file.close();
        self.stdout_file.close();
        _ = self.child.kill() catch {};
        _ = self.child.wait() catch {};
        deleteConfigFileBestEffort(self.config_path);
        self.allocator.free(self.config_path);
        if (self.shared_auth_token) |auth_token| self.allocator.free(auth_token);
        var auth_it = self.auth_token_by_endpoint_name.iterator();
        while (auth_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.auth_token_by_endpoint_name.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn ping(self: *HelperClient) !void {
        var response = try self.roundTrip(.{ .op = "ping" });
        defer response.deinit(self.allocator);
    }

    pub fn getattr(self: *HelperClient, path: []const u8) ![]u8 {
        var response = try self.roundTrip(.{
            .op = "getattr",
            .path = path,
        });
        defer response.deinit(self.allocator);
        return response.takeResultJson(self.allocator);
    }

    pub fn readdir(self: *HelperClient, path: []const u8, cookie: u64, max_entries: u32) ![]u8 {
        var response = try self.roundTrip(.{
            .op = "readdir",
            .path = path,
            .cookie = cookie,
            .max_entries = max_entries,
        });
        defer response.deinit(self.allocator);
        return response.takeResultJson(self.allocator);
    }

    pub fn statfs(self: *HelperClient, path: []const u8) ![]u8 {
        var response = try self.roundTrip(.{
            .op = "statfs",
            .path = path,
        });
        defer response.deinit(self.allocator);
        return response.takeResultJson(self.allocator);
    }

    pub fn open(self: *HelperClient, path: []const u8, flags: u32) !mount_provider.OpenFile {
        var response = try self.roundTrip(.{
            .op = "open",
            .path = path,
            .flags = flags,
        });
        defer response.deinit(self.allocator);
        return response.toOpenFile();
    }

    pub fn read(self: *HelperClient, file: mount_provider.OpenFile, off: u64, len: u32) ![]u8 {
        const namespace_handle = try expectNamespaceHandle(file);
        var response = try self.roundTrip(.{
            .op = "read",
            .handle_id = namespace_handle.handle_id,
            .off = off,
            .len = len,
        });
        defer response.deinit(self.allocator);
        return response.takeData(self.allocator);
    }

    pub fn release(self: *HelperClient, file: mount_provider.OpenFile) !void {
        const namespace_handle = try expectNamespaceHandle(file);
        var response = try self.roundTrip(.{
            .op = "release",
            .handle_id = namespace_handle.handle_id,
        });
        defer response.deinit(self.allocator);
    }

    pub fn create(self: *HelperClient, path: []const u8, mode: u32, flags: u32) !mount_provider.OpenFile {
        var response = try self.roundTrip(.{
            .op = "create",
            .path = path,
            .mode = mode,
            .flags = flags,
        });
        defer response.deinit(self.allocator);
        return response.toOpenFile();
    }

    pub fn write(self: *HelperClient, file: mount_provider.OpenFile, off: u64, data: []const u8) !u32 {
        const namespace_handle = try expectNamespaceHandle(file);
        const data_b64 = try native_protocol.encodeBase64(self.allocator, data);
        defer self.allocator.free(data_b64);

        var response = try self.roundTrip(.{
            .op = "write",
            .handle_id = namespace_handle.handle_id,
            .off = off,
            .data_b64 = data_b64,
        });
        defer response.deinit(self.allocator);
        return response.bytes_written orelse return error.InvalidResponse;
    }

    pub fn truncate(self: *HelperClient, path: []const u8, size: u64) !void {
        var response = try self.roundTrip(.{
            .op = "truncate",
            .path = path,
            .size = size,
        });
        defer response.deinit(self.allocator);
    }

    pub fn unlink(self: *HelperClient, path: []const u8) !void {
        var response = try self.roundTrip(.{
            .op = "unlink",
            .path = path,
        });
        defer response.deinit(self.allocator);
    }

    pub fn mkdir(self: *HelperClient, path: []const u8) !void {
        var response = try self.roundTrip(.{
            .op = "mkdir",
            .path = path,
        });
        defer response.deinit(self.allocator);
    }

    pub fn rmdir(self: *HelperClient, path: []const u8) !void {
        var response = try self.roundTrip(.{
            .op = "rmdir",
            .path = path,
        });
        defer response.deinit(self.allocator);
    }

    pub fn rename(self: *HelperClient, old_path: []const u8, new_path: []const u8) !void {
        var response = try self.roundTrip(.{
            .op = "rename",
            .old_path = old_path,
            .new_path = new_path,
        });
        defer response.deinit(self.allocator);
    }

    pub fn symlink(self: *HelperClient, target: []const u8, link_path: []const u8) !void {
        var response = try self.roundTrip(.{
            .op = "symlink",
            .target = target,
            .link_path = link_path,
        });
        defer response.deinit(self.allocator);
    }

    pub fn setxattr(self: *HelperClient, path: []const u8, name: []const u8, value: []const u8, flags: u32) !void {
        const value_b64 = try native_protocol.encodeBase64(self.allocator, value);
        defer self.allocator.free(value_b64);

        var response = try self.roundTrip(.{
            .op = "setxattr",
            .path = path,
            .name = name,
            .value_b64 = value_b64,
            .flags = flags,
        });
        defer response.deinit(self.allocator);
    }

    pub fn getxattr(self: *HelperClient, path: []const u8, name: []const u8) ![]u8 {
        var response = try self.roundTrip(.{
            .op = "getxattr",
            .path = path,
            .name = name,
        });
        defer response.deinit(self.allocator);
        return response.takeData(self.allocator);
    }

    pub fn listxattr(self: *HelperClient, path: []const u8) ![]u8 {
        var response = try self.roundTrip(.{
            .op = "listxattr",
            .path = path,
        });
        defer response.deinit(self.allocator);
        return response.takeData(self.allocator);
    }

    pub fn removexattr(self: *HelperClient, path: []const u8, name: []const u8) !void {
        var response = try self.roundTrip(.{
            .op = "removexattr",
            .path = path,
            .name = name,
        });
        defer response.deinit(self.allocator);
    }

    pub fn lock(self: *HelperClient, file: mount_provider.OpenFile, mode: mount_provider.LockMode, wait: bool) !void {
        const namespace_handle = try expectNamespaceHandle(file);
        const wire_mode: []const u8 = switch (mode) {
            .shared => "shared",
            .exclusive => "exclusive",
            .unlock => "unlock",
        };
        var response = try self.roundTrip(.{
            .op = "lock",
            .handle_id = namespace_handle.handle_id,
            .mode = wire_mode,
            .wait = wait,
        });
        defer response.deinit(self.allocator);
    }

    pub fn tryReconcileEndpointsIfIdle(self: *HelperClient, endpoint_configs: []const fs_router.EndpointConfig) !bool {
        const endpoints = try self.allocator.alloc(ReconcileEndpointRequest.Endpoint, endpoint_configs.len);
        defer self.allocator.free(endpoints);
        const owned_mount_paths = try self.allocator.alloc(?[]u8, endpoint_configs.len);
        defer self.allocator.free(owned_mount_paths);
        for (owned_mount_paths) |*slot| slot.* = null;
        defer {
            for (owned_mount_paths) |maybe_path| {
                if (maybe_path) |path| self.allocator.free(path);
            }
        }
        for (endpoint_configs, 0..) |endpoint, idx| {
            const auth_token = endpoint.auth_token orelse self.authTokenForEndpoint(endpoint.name) orelse self.shared_auth_token;
            endpoints[idx] = .{
                .name = endpoint.name,
                .url = endpoint.url,
                .export_name = endpoint.export_name,
                .mount_path = try resolveReconcileEndpointMountPath(self.allocator, endpoint, &owned_mount_paths[idx]),
                .auth_token = auth_token,
            };
        }

        var response = try self.roundTrip(ReconcileEndpointRequest{
            .op = "reconcile_endpoints",
            .endpoints = endpoints,
        });
        defer response.deinit(self.allocator);
        const reconciled = try response.parseBoolResult(self.allocator, "reconciled");
        try self.rememberReconciledEndpointAuths(endpoint_configs, endpoints);
        return reconciled;
    }

    pub fn tryKeepAliveIfIdle(self: *HelperClient) !bool {
        var response = try self.roundTrip(.{ .op = "keepalive" });
        defer response.deinit(self.allocator);
        return response.parseBoolResult(self.allocator, "kept_alive");
    }

    fn roundTrip(self: *HelperClient, request: anytype) !ParsedResponse {
        self.mutex.lock();
        defer self.mutex.unlock();

        const encoded = try std.json.Stringify.valueAlloc(self.allocator, request, .{
            .emit_null_optional_fields = false,
        });
        defer self.allocator.free(encoded);

        try self.stdin_file.writeAll(encoded);
        try self.stdin_file.writeAll("\n");

        var reader = self.stdout_file.reader(&.{});
        const line = reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return error.UnexpectedEndOfStream,
            else => return err,
        };
        return ParsedResponse.parse(self.allocator, line);
    }

    fn rememberConfiguredEndpointAuths(
        self: *HelperClient,
        endpoints: []const native_protocol.EndpointSpec,
    ) !void {
        for (endpoints) |endpoint| {
            const auth_token = endpoint.auth_token orelse continue;
            try self.rememberEndpointAuthToken(endpoint.name, auth_token);
        }
    }

    fn rememberReconciledEndpointAuths(
        self: *HelperClient,
        endpoint_configs: []const fs_router.EndpointConfig,
        endpoints: []const ReconcileEndpointRequest.Endpoint,
    ) !void {
        try self.pruneEndpointAuthsNotInConfig(endpoint_configs);
        for (endpoint_configs, endpoints) |config_endpoint, request_endpoint| {
            if (request_endpoint.auth_token) |auth_token| {
                try self.rememberEndpointAuthToken(config_endpoint.name, auth_token);
            } else {
                self.removeEndpointAuthToken(config_endpoint.name);
            }
        }
    }

    fn rememberEndpointAuthToken(self: *HelperClient, endpoint_name: []const u8, auth_token: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, endpoint_name);
        errdefer self.allocator.free(owned_name);
        const owned_auth_token = try self.allocator.dupe(u8, auth_token);
        errdefer self.allocator.free(owned_auth_token);

        const entry = try self.auth_token_by_endpoint_name.getOrPut(self.allocator, owned_name);
        if (entry.found_existing) {
            self.allocator.free(owned_name);
            self.allocator.free(entry.value_ptr.*);
            entry.value_ptr.* = owned_auth_token;
        } else {
            entry.value_ptr.* = owned_auth_token;
        }
    }

    fn authTokenForEndpoint(self: *const HelperClient, endpoint_name: []const u8) ?[]const u8 {
        return self.auth_token_by_endpoint_name.get(endpoint_name);
    }

    fn removeEndpointAuthToken(self: *HelperClient, endpoint_name: []const u8) void {
        const removed = self.auth_token_by_endpoint_name.fetchRemove(endpoint_name) orelse return;
        self.allocator.free(removed.key);
        self.allocator.free(removed.value);
    }

    fn pruneEndpointAuthsNotInConfig(
        self: *HelperClient,
        endpoint_configs: []const fs_router.EndpointConfig,
    ) !void {
        var stale_endpoint_names = std.ArrayListUnmanaged([]u8){};
        defer {
            for (stale_endpoint_names.items) |endpoint_name| self.allocator.free(endpoint_name);
            stale_endpoint_names.deinit(self.allocator);
        }

        var key_it = self.auth_token_by_endpoint_name.keyIterator();
        while (key_it.next()) |endpoint_name_ptr| {
            var found = false;
            for (endpoint_configs) |endpoint| {
                if (std.mem.eql(u8, endpoint.name, endpoint_name_ptr.*)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try stale_endpoint_names.append(self.allocator, try self.allocator.dupe(u8, endpoint_name_ptr.*));
            }
        }

        for (stale_endpoint_names.items) |endpoint_name| {
            self.removeEndpointAuthToken(endpoint_name);
        }
    }
};

fn resolveReconcileEndpointMountPath(
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

const ReconcileEndpointRequest = struct {
    op: []const u8,
    endpoints: []const Endpoint,

    const Endpoint = struct {
        name: []const u8,
        url: []const u8,
        export_name: ?[]const u8 = null,
        mount_path: []const u8,
        auth_token: ?[]const u8 = null,
    };
};

const ParsedResponse = struct {
    result_json: ?[]u8 = null,
    data_b64: ?[]u8 = null,
    handle_id: ?u64 = null,
    writable: ?bool = null,
    bytes_written: ?u32 = null,

    fn deinit(self: *ParsedResponse, allocator: std.mem.Allocator) void {
        if (self.result_json) |value| allocator.free(value);
        if (self.data_b64) |value| allocator.free(value);
        self.* = .{};
    }

    fn parse(allocator: std.mem.Allocator, line: []const u8) !ParsedResponse {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;

        const ok_value = parsed.value.object.get("ok") orelse return error.InvalidResponse;
        if (ok_value != .bool) return error.InvalidResponse;
        if (!ok_value.bool) {
            const code_value = parsed.value.object.get("code") orelse return error.InvalidResponse;
            if (code_value != .string) return error.InvalidResponse;
            return codeToError(code_value.string);
        }

        return .{
            .result_json = try duplicateOptionalString(allocator, parsed.value.object.get("result_json")),
            .data_b64 = try duplicateOptionalString(allocator, parsed.value.object.get("data_b64")),
            .handle_id = integerFieldToU64(parsed.value.object.get("handle_id")),
            .writable = boolField(parsed.value.object.get("writable")),
            .bytes_written = integerFieldToU32(parsed.value.object.get("bytes_written")),
        };
    }

    fn takeResultJson(self: *ParsedResponse, allocator: std.mem.Allocator) ![]u8 {
        _ = allocator;
        const value = self.result_json orelse return error.InvalidResponse;
        self.result_json = null;
        return value;
    }

    fn takeData(self: *ParsedResponse, allocator: std.mem.Allocator) ![]u8 {
        const encoded = self.data_b64 orelse return error.InvalidResponse;
        const out_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
        const out = try allocator.alloc(u8, out_len);
        errdefer allocator.free(out);
        try std.base64.standard.Decoder.decode(out, encoded);
        return out;
    }

    fn toOpenFile(self: *ParsedResponse) !mount_provider.OpenFile {
        return .{
            .namespace = .{
                .handle_id = self.handle_id orelse return error.InvalidResponse,
                .writable = self.writable orelse false,
            },
        };
    }

    fn parseBoolResult(self: *ParsedResponse, allocator: std.mem.Allocator, field_name: []const u8) !bool {
        const payload = self.result_json orelse return error.InvalidResponse;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const field = parsed.value.object.get(field_name) orelse return error.InvalidResponse;
        if (field != .bool) return error.InvalidResponse;
        return field.bool;
    }
};

fn expectNamespaceHandle(file: mount_provider.OpenFile) !mount_provider.NamespaceHandle {
    return switch (file) {
        .namespace => |handle| handle,
        else => error.InvalidResponse,
    };
}

fn writeLaunchConfig(allocator: std.mem.Allocator, config: native_protocol.LaunchConfig) ![]u8 {
    const temp_dir = try temporaryDirectory(allocator);
    defer allocator.free(temp_dir);

    const request_id = try makeRequestId(allocator);
    defer allocator.free(request_id);

    const basename = if (builtin.os.tag == .windows)
        try std.fmt.allocPrint(allocator, "spiderweb-fs-helper-{s}.json", .{request_id})
    else
        try std.fmt.allocPrint(allocator, "spiderweb-fs-helper-{s}.json", .{request_id});
    defer allocator.free(basename);

    const config_path = try std.fs.path.join(allocator, &.{ temp_dir, basename });
    errdefer allocator.free(config_path);

    const encoded = try native_protocol.encodeLaunchConfig(allocator, config);
    defer allocator.free(encoded);

    var file = try createFileAny(config_path, .{
        .truncate = true,
        .mode = 0o600,
    });
    defer file.close();
    try file.writeAll(encoded);
    return config_path;
}

fn temporaryDirectory(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "TEMP")) |value| return value else |_| {}
    if (std.process.getEnvVarOwned(allocator, "TMP")) |value| return value else |_| {}
    return std.process.getCwdAlloc(allocator);
}

fn resolveHelperExecutablePath(allocator: std.mem.Allocator) ![]u8 {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.FileNotFound;
    const helper_name = if (builtin.os.tag == .windows) "spiderweb-fs-helper.exe" else "spiderweb-fs-helper";
    const helper_path = try std.fs.path.join(allocator, &.{ exe_dir, helper_name });
    if (pathExists(helper_path)) return helper_path;
    allocator.free(helper_path);
    return allocator.dupe(u8, helper_name);
}

fn deleteConfigFileBestEffort(path: []const u8) void {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.deleteFileAbsolute(path) catch {};
    } else {
        std.fs.cwd().deleteFile(path) catch {};
    }
}

fn createFileAny(path: []const u8, flags: std.fs.File.CreateFlags) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.createFileAbsolute(path, flags);
    }
    return std.fs.cwd().createFile(path, flags);
}

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn makeRequestId(allocator: std.mem.Allocator) ![]u8 {
    var random_bytes: [12]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    var encoded_buf: [std.base64.url_safe_no_pad.Encoder.calcSize(random_bytes.len)]u8 = undefined;
    const encoded = std.base64.url_safe_no_pad.Encoder.encode(&encoded_buf, &random_bytes);
    return allocator.dupe(u8, encoded);
}

fn duplicateOptionalString(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]u8 {
    const resolved = value orelse return null;
    if (resolved != .string) return error.InvalidResponse;
    return try allocator.dupe(u8, resolved.string);
}

fn integerFieldToU64(value: ?std.json.Value) ?u64 {
    const resolved = value orelse return null;
    if (resolved != .integer or resolved.integer < 0) return null;
    return @intCast(resolved.integer);
}

fn integerFieldToU32(value: ?std.json.Value) ?u32 {
    const resolved = value orelse return null;
    if (resolved != .integer or resolved.integer < 0 or resolved.integer > std.math.maxInt(u32)) return null;
    return @intCast(resolved.integer);
}

fn boolField(value: ?std.json.Value) ?bool {
    const resolved = value orelse return null;
    if (resolved != .bool) return null;
    return resolved.bool;
}

fn codeToError(code: []const u8) anyerror {
    if (std.mem.eql(u8, code, "enoent")) return error.FileNotFound;
    if (std.mem.eql(u8, code, "eacces")) return error.PermissionDenied;
    if (std.mem.eql(u8, code, "enotdir")) return error.NotDirectory;
    if (std.mem.eql(u8, code, "eisdir")) return error.IsDirectory;
    if (std.mem.eql(u8, code, "eexist")) return error.AlreadyExists;
    if (std.mem.eql(u8, code, "enodata")) return error.NoData;
    if (std.mem.eql(u8, code, "enospc")) return error.NoSpace;
    if (std.mem.eql(u8, code, "erange")) return error.Range;
    if (std.mem.eql(u8, code, "eagain")) return error.WouldBlock;
    if (std.mem.eql(u8, code, "exdev")) return error.CrossEndpointRename;
    if (std.mem.eql(u8, code, "erofs")) return error.ReadOnlyFilesystem;
    if (std.mem.eql(u8, code, "enosys")) return error.OperationNotSupported;
    if (std.mem.eql(u8, code, "einval")) return error.InvalidResponse;
    return error.UnexpectedHelperError;
}
