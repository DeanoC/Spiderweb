const std = @import("std");
const builtin = @import("builtin");
const Config = @import("config.zig");
const control_plane_mod = @import("acheron/control_plane.zig");
const unified = @import("spider-protocol").unified;
const macos_capability_venoms = @import("spiderweb_node").macos_capability_venoms;

const local_node_supervisor_dirname = "local-node";
const local_node_state_filename = "state.json";
const local_node_manifests_dirname = "services.d";
const local_node_bin_dirname = "bin";
pub const local_node_default_name = "spiderweb-local";
const local_node_service_binary_name = "spiderweb-local-service";
const local_node_computer_binary_name = macos_capability_venoms.computer_driver_binary_name;
const local_node_browser_binary_name = macos_capability_venoms.browser_driver_binary_name;

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
    service_binary_path: []u8,
    computer_driver_binary_path: ?[]u8 = null,
    browser_driver_binary_path: ?[]u8 = null,
    driver_bin_dir: []u8,
    staged_computer_driver_path: ?[]u8 = null,
    staged_browser_driver_path: ?[]u8 = null,
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
        const driver_bin_dir = try std.fs.path.join(allocator, &.{ state_dir, local_node_bin_dirname });
        errdefer allocator.free(driver_bin_dir);

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
            .computer_driver_binary_path = if (builtin.os.tag == .macos)
                try resolveSiblingExecutablePath(allocator, local_node_computer_binary_name)
            else
                null,
            .browser_driver_binary_path = if (builtin.os.tag == .macos)
                try resolveSiblingExecutablePath(allocator, local_node_browser_binary_name)
            else
                null,
            .driver_bin_dir = driver_bin_dir,
            .staged_computer_driver_path = if (builtin.os.tag == .macos)
                try std.fs.path.join(allocator, &.{ driver_bin_dir, local_node_computer_binary_name })
            else
                null,
            .staged_browser_driver_path = if (builtin.os.tag == .macos)
                try std.fs.path.join(allocator, &.{ driver_bin_dir, local_node_browser_binary_name })
            else
                null,
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

    pub fn deinit(self: *LocalNodeSupervisor) void {
        if (self.thread != null) @panic("LocalNodeSupervisor.deinit called before join");
        self.allocator.free(self.bind_addr);
        self.allocator.free(self.control_url);
        self.allocator.free(self.control_auth_token);
        self.allocator.free(self.binary_path);
        self.allocator.free(self.service_binary_path);
        if (self.computer_driver_binary_path) |value| self.allocator.free(value);
        if (self.browser_driver_binary_path) |value| self.allocator.free(value);
        self.allocator.free(self.driver_bin_dir);
        if (self.staged_computer_driver_path) |value| self.allocator.free(value);
        if (self.staged_browser_driver_path) |value| self.allocator.free(value);
        self.allocator.free(self.export_root);
        self.allocator.free(self.export_name);
        self.allocator.free(self.profile);
        self.allocator.free(self.state_dir);
        self.allocator.free(self.state_path);
        self.allocator.free(self.manifests_dir);
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
        try ensureDirectoryExists(self.driver_bin_dir);
        try self.stageCapabilityDrivers();
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
        if (builtin.os.tag == .macos) {
            if (self.staged_computer_driver_path) |value| {
                try self.writeCapabilityManifestFile("computer", value);
            }
            if (self.staged_browser_driver_path) |value| {
                try self.writeCapabilityManifestFile("browser", value);
            }
        }
    }

    fn stageCapabilityDrivers(self: *LocalNodeSupervisor) !void {
        if (builtin.os.tag != .macos) return;

        if (self.computer_driver_binary_path) |source_path| {
            const staged_path = self.staged_computer_driver_path orelse return error.InvalidArguments;
            try stageExecutable(self.allocator, source_path, staged_path);
        }
        if (self.browser_driver_binary_path) |source_path| {
            const staged_path = self.staged_browser_driver_path orelse return error.InvalidArguments;
            try stageExecutable(self.allocator, source_path, staged_path);
        }
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

    fn writeCapabilityManifestFile(self: *LocalNodeSupervisor, family_id: []const u8, executable_path: []const u8) !void {
        const manifest_json = if (std.mem.eql(u8, family_id, "computer")) blk: {
            break :blk try macos_capability_venoms.renderComputerManifestJson(self.allocator, executable_path);
        } else if (std.mem.eql(u8, family_id, "browser")) blk: {
            const browser_state_path = try std.fs.path.join(self.allocator, &.{ self.state_dir, "browser", "state.json" });
            defer self.allocator.free(browser_state_path);
            const browser_profile_dir = try std.fs.path.join(self.allocator, &.{ self.state_dir, "browser", "profile" });
            defer self.allocator.free(browser_profile_dir);
            break :blk try macos_capability_venoms.renderBrowserManifestJsonWithRuntimePaths(
                self.allocator,
                executable_path,
                .{
                    .state_path = browser_state_path,
                    .profile_dir = browser_profile_dir,
                },
            );
        } else
            return error.InvalidArguments;
        defer self.allocator.free(manifest_json);
        const manifest_name = try std.fmt.allocPrint(self.allocator, "{s}.json", .{family_id});
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
            "{{\"venom_id\":\"{s}\",\"package_id\":\"{s}\",\"kind\":\"{s}\",\"version\":\"1\",\"state\":\"online\",\"categories\":{s},\"host_roles\":[\"node\"],\"binding_scopes\":[\"workspace\"],\"requirements\":{s},\"runtime_kind\":\"native\",\"endpoints\":[\"/nodes/{{node_id}}/venoms/{s}\"],\"mounts\":[{{\"mount_id\":\"{s}\",\"mount_path\":\"/nodes/{{node_id}}/venoms/{s}\",\"state\":\"online\"}}],\"capabilities\":{s},\"ops\":{{\"model\":\"namespace\",\"invoke\":\"control/invoke.json\",\"paths\":{{\"invoke\":\"control/invoke.json\"}}}},\"runtime\":{{\"type\":\"native_proc\",\"abi\":\"namespace-driver-v1\",\"executable_path\":\"{s}\",\"args\":[\"{s}\",\"{s}\"],\"timeout_ms\":300000}},\"permissions\":{{\"default\":\"allow-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"scope\":\"project\"}},\"schema\":{{\"model\":\"namespace-mount\"}},\"invoke_template\":{s},\"help_md\":\"{s}\"}}",
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
