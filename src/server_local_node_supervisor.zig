const std = @import("std");
const builtin = @import("builtin");
const Config = @import("config.zig");
const control_plane_mod = @import("acheron/control_plane.zig");
const managed_bundle_signatures = @import("managed_bundle_signatures.zig");
const venom_model = @import("venom_model.zig");

const local_node_supervisor_dirname = "local-node";
const local_node_state_filename = "state.json";
const local_node_manifests_dirname = "services.d";
pub const local_node_default_name = "spiderweb-local";
const local_node_host_type_label = "spider.host_type=" ++ venom_model.HostType.spiderweb_managed.asString();
const packaged_bundle_release_rel_path = "share/spidervenoms/bundles/managed-local/release.json";
const app_resources_bundle_release_rel_path = "spidervenoms/bundles/managed-local/release.json";
const repo_bundle_release_rel_path = "SpiderVenoms/zig-out/share/spidervenoms/bundles/managed-local/release.json";

pub fn ensureDirectoryExists(dir_path: []const u8) !void {
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

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn resolveInternalWsClientHost(bind_addr: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, bind_addr, " \t\r\n");
    if (trimmed.len == 0) return "127.0.0.1";
    if (std.mem.eql(u8, trimmed, "0.0.0.0")) return "127.0.0.1";
    if (std.mem.eql(u8, trimmed, "::")) return "127.0.0.1";
    if (std.mem.eql(u8, trimmed, "[::]")) return "127.0.0.1";
    return trimmed;
}

pub fn formatInternalWsUrl(
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

pub fn buildInternalNodeFsUrl(
    allocator: std.mem.Allocator,
    bind_addr: []const u8,
    port: u16,
    node_id: []const u8,
) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "/fs/node/{s}", .{node_id});
    defer allocator.free(path);
    return formatInternalWsUrl(allocator, bind_addr, port, path);
}

pub fn resolveSiblingExecutablePath(allocator: std.mem.Allocator, executable_name: []const u8) ![]u8 {
    const self_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_path);
    const self_dir = std.fs.path.dirname(self_path) orelse return error.InvalidExecutablePath;

    const sibling = try std.fs.path.join(allocator, &.{ self_dir, executable_name });
    if (pathExists(sibling)) return sibling;
    allocator.free(sibling);

    return allocator.dupe(u8, executable_name);
}

fn isFilesystemRoot(path: []const u8) bool {
    const parent = std.fs.path.dirname(path) orelse return true;
    return std.mem.eql(u8, parent, path);
}

fn findExistingPathFromBase(
    allocator: std.mem.Allocator,
    base: []const u8,
    relative_candidates: []const []const u8,
) !?[]u8 {
    var current = try allocator.dupe(u8, base);
    defer allocator.free(current);

    while (true) {
        for (relative_candidates) |candidate| {
            const joined = try std.fs.path.join(allocator, &.{ current, candidate });
            if (pathExists(joined)) return joined;
            allocator.free(joined);
        }

        if (isFilesystemRoot(current)) break;
        const parent = std.fs.path.dirname(current) orelse break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }

    return null;
}

fn resolveBundleReleasePath(allocator: std.mem.Allocator, configured_path: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, configured_path, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidArguments;
    if (std.fs.path.isAbsolute(trimmed)) return allocator.dupe(u8, trimmed);
    if (pathExists(trimmed)) return allocator.dupe(u8, trimmed);

    const self_path = std.fs.selfExePathAlloc(allocator) catch null;
    defer if (self_path) |value| allocator.free(value);
    if (self_path) |exe_path| {
        if (std.fs.path.dirname(exe_path)) |exe_dir| {
            const exe_relative = try std.fs.path.join(allocator, &.{ exe_dir, trimmed });
            if (pathExists(exe_relative)) return exe_relative;
            allocator.free(exe_relative);

            if (try findExistingPathFromBase(allocator, exe_dir, &.{
                packaged_bundle_release_rel_path,
                app_resources_bundle_release_rel_path,
                repo_bundle_release_rel_path,
            })) |resolved| {
                return resolved;
            }
        }
    }

    const cwd = std.process.getCwdAlloc(allocator) catch null;
    defer if (cwd) |value| allocator.free(value);
    if (cwd) |cwd_path| {
        if (try findExistingPathFromBase(allocator, cwd_path, &.{
            repo_bundle_release_rel_path,
            packaged_bundle_release_rel_path,
        })) |resolved| {
            return resolved;
        }
    }

    return allocator.dupe(u8, trimmed);
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

fn openFileForRead(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openFileAbsolute(path, .{ .mode = .read_only });
    }
    return std.fs.cwd().openFile(path, .{ .mode = .read_only });
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var file = try openFileForRead(path);
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

fn containsPathSeparator(path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, path, std.fs.path.sep)) |_| return true;
    if (builtin.os.tag == .windows) {
        if (std.mem.indexOfScalar(u8, path, '/')) |_| return true;
    }
    return false;
}

fn resolveExecutableSourcePath(allocator: std.mem.Allocator, source_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(source_path) or containsPathSeparator(source_path)) {
        return allocator.dupe(u8, source_path);
    }

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    const path_value = env_map.get("PATH") orelse return allocator.dupe(u8, source_path);
    const delimiter: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var path_it = std.mem.splitScalar(u8, path_value, delimiter);
    while (path_it.next()) |entry| {
        if (entry.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &.{ entry, source_path });
        errdefer allocator.free(candidate);
        if (pathExists(candidate)) return candidate;
        allocator.free(candidate);
    }

    return allocator.dupe(u8, source_path);
}

fn openOrCreateFileForWrite(path: []const u8) !std.fs.File {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    const base = std.fs.path.basename(path);
    if (base.len == 0) return error.InvalidPath;
    try ensureDirectoryExists(parent);

    if (std.fs.path.isAbsolute(parent)) {
        var dir = try std.fs.openDirAbsolute(parent, .{});
        defer dir.close();
        return dir.createFile(base, .{ .truncate = true });
    }

    var dir = try std.fs.cwd().openDir(parent, .{});
    defer dir.close();
    return dir.createFile(base, .{ .truncate = true });
}

fn stageExecutable(allocator: std.mem.Allocator, source_path: []const u8, staged_path: []const u8) !void {
    const resolved_source_path = try resolveExecutableSourcePath(allocator, source_path);
    defer allocator.free(resolved_source_path);

    var source_file = try openFileForRead(resolved_source_path);
    defer source_file.close();

    var staged_file = try openOrCreateFileForWrite(staged_path);
    defer staged_file.close();

    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        const read_len = try source_file.read(&buffer);
        if (read_len == 0) break;
        try staged_file.writeAll(buffer[0..read_len]);
    }

    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        try staged_file.chmod(0o755);
    }
}

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

fn formatChildTerm(term: std.process.Child.Term) []const u8 {
    return switch (term) {
        .Exited => "exited",
        .Signal => "signal",
        .Stopped => "stopped",
        .Unknown => "unknown",
    };
}

pub const LocalNodeSupervisor = struct {
    allocator: std.mem.Allocator,
    control_plane: *control_plane_mod.ControlPlane,
    bind_addr: []u8,
    port: u16,
    control_url: []u8,
    control_auth_token: []u8,
    binary_path: []u8,
    export_root: []u8,
    export_name: []u8,
    profile: []u8,
    state_dir: []u8,
    state_path: []u8,
    manifests_dir: []u8,
    bundle_release_path: []u8,
    bundle_root_dir: []u8,
    allow_unsigned_dev_bundles: bool,
    extra_venoms_dir: ?[]u8 = null,
    restart_on_exit: bool,
    thread: ?std.Thread = null,
    mutex: std.Thread.Mutex = .{},
    stop_requested: bool = false,
    child_pid: ?std.process.Child.Id = null,

    pub fn create(
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
        const bundle_release_path = try resolveBundleReleasePath(allocator, local_cfg.bundle_release_path);
        errdefer allocator.free(bundle_release_path);
        const bundle_root_dir = blk: {
            const dirname = std.fs.path.dirname(bundle_release_path) orelse return error.InvalidArguments;
            break :blk try allocator.dupe(u8, dirname);
        };
        errdefer allocator.free(bundle_root_dir);

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
            .export_root = try allocator.dupe(u8, export_root_trimmed),
            .export_name = try allocator.dupe(u8, std.mem.trim(u8, local_cfg.export_name, " \t\r\n")),
            .profile = try allocator.dupe(u8, std.mem.trim(u8, local_cfg.profile, " \t\r\n")),
            .state_dir = state_dir,
            .state_path = state_path,
            .manifests_dir = manifests_dir,
            .bundle_release_path = bundle_release_path,
            .bundle_root_dir = bundle_root_dir,
            .allow_unsigned_dev_bundles = local_cfg.allow_unsigned_dev_bundles,
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

    pub fn deinit(self: *LocalNodeSupervisor) void {
        if (self.thread != null) @panic("LocalNodeSupervisor.deinit called before join");
        self.allocator.free(self.bind_addr);
        self.allocator.free(self.control_url);
        self.allocator.free(self.control_auth_token);
        self.allocator.free(self.binary_path);
        self.allocator.free(self.export_root);
        self.allocator.free(self.export_name);
        self.allocator.free(self.profile);
        self.allocator.free(self.state_dir);
        self.allocator.free(self.state_path);
        self.allocator.free(self.manifests_dir);
        self.allocator.free(self.bundle_release_path);
        self.allocator.free(self.bundle_root_dir);
        if (self.extra_venoms_dir) |value| self.allocator.free(value);
        self.allocator.destroy(self);
    }

    pub fn start(self: *LocalNodeSupervisor) !void {
        if (self.thread != null) return;
        self.thread = try std.Thread.spawn(.{}, localNodeSupervisorMain, .{self});
    }

    pub fn join(self: *LocalNodeSupervisor) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn requestStop(self: *LocalNodeSupervisor) void {
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
        try ensureDirectoryExists(self.export_root);
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
        try self.writeBundleManifestFiles();
    }

    fn writeBundleManifestFiles(self: *LocalNodeSupervisor) !void {
        const release_json = try readFileAlloc(self.allocator, self.bundle_release_path, 1024 * 1024);
        defer self.allocator.free(release_json);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, release_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidBundleRelease;

        try self.validateBundleEnvelope(parsed.value.object);
        const executables = try getRequiredBundleArray(parsed.value.object, "executables");
        try stageBundleExecutables(self.allocator, self.state_dir, self.bundle_root_dir, executables);
        const packages_value = parsed.value.object.get("packages") orelse return error.InvalidBundleRelease;
        if (packages_value != .array) return error.InvalidBundleRelease;

        for (packages_value.array.items) |item| {
            if (item != .object) return error.InvalidBundleRelease;
            try self.writeBundleManifestEntry(item.object, executables);
        }
    }

    fn writeBundleManifestEntry(self: *LocalNodeSupervisor, item: std.json.ObjectMap, executables: []const std.json.Value) !void {
        try self.validateBundleEnvelope(item);

        const manifest_rel_path = getRequiredBundleString(item, "manifest_path");
        if (manifest_rel_path.len == 0) return error.InvalidBundleRelease;
        const executable_id = getRequiredBundleString(item, "executable_id");
        if (executable_id.len == 0) return error.InvalidBundleRelease;
        const executable_path = try resolveBundleExecutableInstallPath(
            self.allocator,
            self.state_dir,
            self.bundle_root_dir,
            executables,
            executable_id,
        ) orelse return;
        defer self.allocator.free(executable_path);

        const manifest_source_path = try std.fs.path.join(self.allocator, &.{ self.bundle_root_dir, manifest_rel_path });
        defer self.allocator.free(manifest_source_path);
        const manifest_template = try readFileAlloc(self.allocator, manifest_source_path, 1024 * 1024);
        defer self.allocator.free(manifest_template);
        var parsed_manifest = try std.json.parseFromSlice(std.json.Value, self.allocator, manifest_template, .{});
        defer parsed_manifest.deinit();
        if (parsed_manifest.value != .object) return error.InvalidBundleRelease;
        try self.validateBundleEnvelope(parsed_manifest.value.object);
        try validateBundleManifestMatchesRelease(item, parsed_manifest.value.object);

        const template_bindings = getOptionalBundleObject(item, "template_bindings");
        const rendered_manifest = try renderBundleManifestTemplate(
            self.allocator,
            self.state_dir,
            self.bundle_root_dir,
            self.export_root,
            manifest_template,
            executable_path,
            template_bindings,
        );
        defer self.allocator.free(rendered_manifest);

        const manifest_name = std.fs.path.basename(manifest_rel_path);
        if (manifest_name.len == 0) return error.InvalidBundleRelease;
        const manifest_path = try std.fs.path.join(self.allocator, &.{ self.manifests_dir, manifest_name });
        defer self.allocator.free(manifest_path);
        try writeFileReplacing(manifest_path, rendered_manifest);
    }

    fn validateBundleEnvelope(self: *LocalNodeSupervisor, obj: std.json.ObjectMap) !void {
        if (self.allow_unsigned_dev_bundles) return;
        try managed_bundle_signatures.verifySignedValue(self.allocator, .{ .object = obj });
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
        try argv.append(allocator, "--label");
        try argv.append(allocator, local_node_host_type_label);
        try argv.append(allocator, "--venoms-dir");
        try argv.append(allocator, self.manifests_dir);
        if (self.extra_venoms_dir) |extra_dir| {
            try argv.append(allocator, "--venoms-dir");
            try argv.append(allocator, extra_dir);
        }
        return argv;
    }
};

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
                    std.mem.eql(u8, arg, "--label") or
                    std.mem.eql(u8, arg, local_node_host_type_label) or
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

fn getRequiredBundleString(obj: std.json.ObjectMap, field_name: []const u8) []const u8 {
    const value = obj.get(field_name) orelse return "";
    if (value != .string or value.string.len == 0) return "";
    return value.string;
}

fn getRequiredBundleArray(obj: std.json.ObjectMap, field_name: []const u8) ![]const std.json.Value {
    const value = obj.get(field_name) orelse return error.InvalidBundleRelease;
    if (value != .array) return error.InvalidBundleRelease;
    return value.array.items;
}

fn getRequiredBundleObject(obj: std.json.ObjectMap, field_name: []const u8) !std.json.ObjectMap {
    const value = obj.get(field_name) orelse return error.InvalidBundleRelease;
    if (value != .object) return error.InvalidBundleRelease;
    return value.object;
}

fn getOptionalBundleString(obj: std.json.ObjectMap, field_name: []const u8) ?[]const u8 {
    const value = obj.get(field_name) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn getOptionalBundleObject(obj: std.json.ObjectMap, field_name: []const u8) ?std.json.ObjectMap {
    const value = obj.get(field_name) orelse return null;
    if (value != .object) return null;
    return value.object;
}

fn currentBundlePlatformLabel() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => @tagName(builtin.os.tag),
    };
}

fn bundleObjectSupportsCurrentPlatform(obj: std.json.ObjectMap) !bool {
    const platforms_value = obj.get("platforms") orelse return true;
    if (platforms_value != .array) return error.InvalidBundleRelease;

    const current_platform = currentBundlePlatformLabel();
    for (platforms_value.array.items) |item| {
        if (item != .string) return error.InvalidBundleRelease;
        const platform = std.mem.trim(u8, item.string, " \t\r\n");
        if (platform.len == 0) return error.InvalidBundleRelease;
        if (std.mem.eql(u8, platform, current_platform)) return true;
    }
    return false;
}

fn resolveBundleExecutableSourcePath(
    allocator: std.mem.Allocator,
    bundle_root_dir: []const u8,
    executable: std.json.ObjectMap,
) ![]u8 {
    const source = try getRequiredBundleObject(executable, "source");
    const kind = getRequiredBundleString(source, "kind");
    const path = getRequiredBundleString(source, "path");
    if (kind.len == 0 or path.len == 0) return error.InvalidBundleRelease;

    if (std.mem.eql(u8, kind, "sibling_executable")) {
        return resolveSiblingExecutablePath(allocator, path);
    }
    if (std.mem.eql(u8, kind, "path_lookup")) {
        return resolveExecutableSourcePath(allocator, path);
    }
    if (std.mem.eql(u8, kind, "bundle_relative")) {
        return std.fs.path.join(allocator, &.{ bundle_root_dir, path });
    }
    return error.InvalidBundleRelease;
}

fn resolveBundleExecutableStagePath(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    executable: std.json.ObjectMap,
) !?[]u8 {
    const stage_rel_path = getOptionalBundleString(executable, "stage_path") orelse return null;
    const trimmed = std.mem.trim(u8, stage_rel_path, " \t\r\n");
    if (trimmed.len == 0 or std.fs.path.isAbsolute(trimmed)) return error.InvalidBundleRelease;
    return blk: {
        break :blk try std.fs.path.join(allocator, &.{ state_dir, trimmed });
    };
}

fn findBundleExecutableObject(
    executables: []const std.json.Value,
    executable_id: []const u8,
) !?std.json.ObjectMap {
    for (executables) |entry| {
        if (entry != .object) return error.InvalidBundleRelease;
        const id = getRequiredBundleString(entry.object, "id");
        if (id.len == 0) return error.InvalidBundleRelease;
        if (std.mem.eql(u8, id, executable_id)) return entry.object;
    }
    return null;
}

fn stageBundleExecutables(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    bundle_root_dir: []const u8,
    executables: []const std.json.Value,
) !void {
    for (executables) |entry| {
        if (entry != .object) return error.InvalidBundleRelease;
        if (!try bundleObjectSupportsCurrentPlatform(entry.object)) continue;

        const staged_path = try resolveBundleExecutableStagePath(allocator, state_dir, entry.object) orelse continue;
        defer allocator.free(staged_path);

        const source_path = try resolveBundleExecutableSourcePath(allocator, bundle_root_dir, entry.object);
        defer allocator.free(source_path);
        try stageExecutable(allocator, source_path, staged_path);
    }
}

fn resolveBundleExecutableInstallPath(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    bundle_root_dir: []const u8,
    executables: []const std.json.Value,
    executable_id: []const u8,
) !?[]u8 {
    const executable = try findBundleExecutableObject(executables, executable_id) orelse return null;
    if (!try bundleObjectSupportsCurrentPlatform(executable)) return null;

    if (try resolveBundleExecutableStagePath(allocator, state_dir, executable)) |staged_path| {
        return staged_path;
    }
    return blk: {
        break :blk try resolveBundleExecutableSourcePath(allocator, bundle_root_dir, executable);
    };
}

fn resolveManifestTemplateBindingValue(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    bundle_root_dir: []const u8,
    export_root: []const u8,
    binding_value: std.json.Value,
) ![]u8 {
    switch (binding_value) {
        .string => |value| return allocator.dupe(u8, value),
        .object => |binding| {
            const kind = getRequiredBundleString(binding, "kind");
            if (kind.len == 0) return error.InvalidBundleRelease;

            if (std.mem.eql(u8, kind, "export_root")) {
                return allocator.dupe(u8, export_root);
            }
            if (std.mem.eql(u8, kind, "literal")) {
                const value = getRequiredBundleString(binding, "value");
                if (value.len == 0) return error.InvalidBundleRelease;
                return allocator.dupe(u8, value);
            }
            if (std.mem.eql(u8, kind, "bundle_relative")) {
                const rel_path = getRequiredBundleString(binding, "path");
                if (rel_path.len == 0) return error.InvalidBundleRelease;
                return std.fs.path.join(allocator, &.{ bundle_root_dir, rel_path });
            }
            if (std.mem.eql(u8, kind, "state_file")) {
                const rel_path = getRequiredBundleString(binding, "path");
                if (rel_path.len == 0 or std.fs.path.isAbsolute(rel_path)) return error.InvalidBundleRelease;
                const full_path = try std.fs.path.join(allocator, &.{ state_dir, rel_path });
                errdefer allocator.free(full_path);
                try ensureDirectoryExists(std.fs.path.dirname(full_path) orelse state_dir);
                return full_path;
            }
            if (std.mem.eql(u8, kind, "state_dir")) {
                const rel_path = getRequiredBundleString(binding, "path");
                if (rel_path.len == 0 or std.fs.path.isAbsolute(rel_path)) return error.InvalidBundleRelease;
                const full_path = try std.fs.path.join(allocator, &.{ state_dir, rel_path });
                errdefer allocator.free(full_path);
                try ensureDirectoryExists(full_path);
                return full_path;
            }
            return error.InvalidBundleRelease;
        },
        else => return error.InvalidBundleRelease,
    }
}

fn renderBundleManifestTemplate(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    bundle_root_dir: []const u8,
    export_root: []const u8,
    template_json: []const u8,
    executable_path: []const u8,
    template_bindings: ?std.json.ObjectMap,
) ![]u8 {
    var rendered = try allocator.dupe(u8, template_json);
    errdefer allocator.free(rendered);

    try replaceManifestPlaceholder(allocator, &rendered, "__EXECUTABLE_PATH__", executable_path);
    if (template_bindings) |bindings| {
        var it = bindings.iterator();
        while (it.next()) |entry| {
            const replacement = try resolveManifestTemplateBindingValue(
                allocator,
                state_dir,
                bundle_root_dir,
                export_root,
                entry.value_ptr.*,
            );
            defer allocator.free(replacement);
            try replaceManifestPlaceholder(allocator, &rendered, entry.key_ptr.*, replacement);
        }
    }

    return rendered;
}

fn replaceManifestPlaceholder(
    allocator: std.mem.Allocator,
    source: *[]u8,
    placeholder: []const u8,
    replacement: []const u8,
) !void {
    const next = try replaceAllAlloc(allocator, source.*, placeholder, replacement);
    allocator.free(source.*);
    source.* = next;
}

fn replaceAllAlloc(
    allocator: std.mem.Allocator,
    haystack: []const u8,
    needle: []const u8,
    replacement: []const u8,
) ![]u8 {
    if (needle.len == 0) return allocator.dupe(u8, haystack);

    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, cursor, needle)) |index| {
        try out.appendSlice(allocator, haystack[cursor..index]);
        try out.appendSlice(allocator, replacement);
        cursor = index + needle.len;
    }
    try out.appendSlice(allocator, haystack[cursor..]);
    return out.toOwnedSlice(allocator);
}

fn otherBundlePlatformLabel() []const u8 {
    const current = currentBundlePlatformLabel();
    if (!std.mem.eql(u8, current, "linux")) return "linux";
    if (!std.mem.eql(u8, current, "macos")) return "macos";
    return "windows";
}

fn validateBundleManifestMatchesRelease(release_entry: std.json.ObjectMap, manifest: std.json.ObjectMap) !void {
    try requireMatchingBundleString("package_id", release_entry, manifest);
    try requireMatchingBundleString("release_version", release_entry, manifest);
    try requireMatchingBundleString("venom_id", release_entry, manifest);
    try requireMatchingBundleString("kind", release_entry, manifest);
    try requireMatchingBundleString("channel", release_entry, manifest);
}

fn requireMatchingBundleString(
    field_name: []const u8,
    release_entry: std.json.ObjectMap,
    manifest: std.json.ObjectMap,
) !void {
    const expected = getRequiredBundleString(release_entry, field_name);
    const actual = getRequiredBundleString(manifest, field_name);
    if (expected.len == 0 or actual.len == 0) return error.InvalidBundleRelease;
    if (!std.mem.eql(u8, expected, actual)) return error.InvalidBundleRelease;
}

test "managed bundle metadata stages executables and renders template bindings" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const bundle_root = try std.fs.path.join(allocator, &.{ root, "bundle" });
    defer allocator.free(bundle_root);
    const state_dir = try std.fs.path.join(allocator, &.{ root, "state" });
    defer allocator.free(state_dir);
    const export_root = try std.fs.path.join(allocator, &.{ root, "workspace" });
    defer allocator.free(export_root);

    const driver_source = try std.fs.path.join(allocator, &.{ bundle_root, "drivers", "tool.sh" });
    defer allocator.free(driver_source);
    try writeFileReplacing(driver_source, "#!/bin/sh\necho managed-tool\n");

    const template_json =
        \\{
        \\  "runtime": {
        \\    "executable_path": "__EXECUTABLE_PATH__",
        \\    "env": {
        \\      "EXPORT_ROOT": "__EXPORT_ROOT__",
        \\      "STATE_FILE": "__STATE_FILE__",
        \\      "STATE_DIR": "__STATE_DIR__",
        \\      "ASSET_PATH": "__ASSET_PATH__",
        \\      "STATIC_VALUE": "__STATIC_VALUE__"
        \\    }
        \\  }
        \\}
    ;

    const release_json = try std.fmt.allocPrint(
        allocator,
        \\{{
        \\  "executables": [
        \\    {{
        \\      "id": "tool",
        \\      "source": {{
        \\        "kind": "bundle_relative",
        \\        "path": "drivers/tool.sh"
        \\      }},
        \\      "stage_path": "bin/tool.sh",
        \\      "platforms": ["{s}"]
        \\    }}
        \\  ],
        \\  "packages": [
        \\    {{
        \\      "package_id": "tool",
        \\      "manifest_path": "manifests/tool.json",
        \\      "executable_id": "tool",
        \\      "template_bindings": {{
        \\        "__EXPORT_ROOT__": {{
        \\          "kind": "export_root"
        \\        }},
        \\        "__STATE_FILE__": {{
        \\          "kind": "state_file",
        \\          "path": "browser/state.json"
        \\        }},
        \\        "__STATE_DIR__": {{
        \\          "kind": "state_dir",
        \\          "path": "browser/profile"
        \\        }},
        \\        "__ASSET_PATH__": {{
        \\          "kind": "bundle_relative",
        \\          "path": "assets/info.txt"
        \\        }},
        \\        "__STATIC_VALUE__": {{
        \\          "kind": "literal",
        \\          "value": "hello"
        \\        }}
        \\      }}
        \\    }}
        \\  ]
        \\}}
    ,
        .{currentBundlePlatformLabel()},
    );
    defer allocator.free(release_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, release_json, .{});
    defer parsed.deinit();

    const executables = try getRequiredBundleArray(parsed.value.object, "executables");
    try stageBundleExecutables(allocator, state_dir, bundle_root, executables);

    const executable_path = try resolveBundleExecutableInstallPath(
        allocator,
        state_dir,
        bundle_root,
        executables,
        "tool",
    ) orelse return error.TestUnexpectedResult;
    defer allocator.free(executable_path);

    const staged_contents = try readFileAlloc(allocator, executable_path, 1024);
    defer allocator.free(staged_contents);
    try std.testing.expectEqualStrings("#!/bin/sh\necho managed-tool\n", staged_contents);

    const expected_state_file = try std.fs.path.join(allocator, &.{ state_dir, "browser", "state.json" });
    defer allocator.free(expected_state_file);
    const expected_state_dir = try std.fs.path.join(allocator, &.{ state_dir, "browser", "profile" });
    defer allocator.free(expected_state_dir);
    const expected_asset_path = try std.fs.path.join(allocator, &.{ bundle_root, "assets", "info.txt" });
    defer allocator.free(expected_asset_path);

    const package = parsed.value.object.get("packages").?.array.items[0].object;
    const rendered_manifest = try renderBundleManifestTemplate(
        allocator,
        state_dir,
        bundle_root,
        export_root,
        template_json,
        executable_path,
        getOptionalBundleObject(package, "template_bindings"),
    );
    defer allocator.free(rendered_manifest);

    try std.testing.expect(std.mem.indexOf(u8, rendered_manifest, executable_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered_manifest, export_root) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered_manifest, expected_state_file) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered_manifest, expected_state_dir) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered_manifest, expected_asset_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered_manifest, "\"hello\"") != null);
    try std.testing.expect(pathExists(expected_state_dir));
}

test "managed bundle metadata skips executables for other platforms" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const bundle_root = try std.fs.path.join(allocator, &.{ root, "bundle" });
    defer allocator.free(bundle_root);
    const state_dir = try std.fs.path.join(allocator, &.{ root, "state" });
    defer allocator.free(state_dir);

    const driver_source = try std.fs.path.join(allocator, &.{ bundle_root, "drivers", "tool.sh" });
    defer allocator.free(driver_source);
    try writeFileReplacing(driver_source, "#!/bin/sh\necho skipped-tool\n");

    const release_json = try std.fmt.allocPrint(
        allocator,
        \\{{
        \\  "executables": [
        \\    {{
        \\      "id": "tool",
        \\      "source": {{
        \\        "kind": "bundle_relative",
        \\        "path": "drivers/tool.sh"
        \\      }},
        \\      "stage_path": "bin/tool.sh",
        \\      "platforms": ["{s}"]
        \\    }}
        \\  ]
        \\}}
    ,
        .{otherBundlePlatformLabel()},
    );
    defer allocator.free(release_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, release_json, .{});
    defer parsed.deinit();

    const executables = try getRequiredBundleArray(parsed.value.object, "executables");
    try stageBundleExecutables(allocator, state_dir, bundle_root, executables);

    const staged_path = try std.fs.path.join(allocator, &.{ state_dir, "bin", "tool.sh" });
    defer allocator.free(staged_path);
    try std.testing.expect(!pathExists(staged_path));

    const executable_path = try resolveBundleExecutableInstallPath(
        allocator,
        state_dir,
        bundle_root,
        executables,
        "tool",
    );
    if (executable_path) |value| allocator.free(value);
    try std.testing.expect(executable_path == null);
}
