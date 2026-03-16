const builtin = @import("builtin");
const std = @import("std");
const native_protocol = @import("native_mount_protocol.zig");

pub const app_name = "SpiderwebFSKit";
pub const app_bundle_name = app_name ++ ".app";
pub const app_bundle_id = "com.deanoc.spiderweb.fskit.app";
pub const extension_bundle_name = "SpiderwebFSKitExtension.appex";
pub const extension_bundle_id = "com.deanoc.spiderweb.fskit.app.extension";
pub const module_short_name = "spiderwebnative";
pub const filesystem_bundle_name = module_short_name ++ ".fs";
pub const filesystem_bundle_id = "com.deanoc.spiderweb.filesystems.fs.spiderweb";
pub const mount_helper_name = "mount_" ++ module_short_name;
pub const shared_app_group_id = "group.com.deanoc.spiderweb.fskit";
pub const runtime_ready_manifest_name = "SpiderwebFSKit.runtime-ready";

const minimum_macos_native_version = std.SemanticVersion{ .major = 15, .minor = 4, .patch = 0 };

pub const InstallStatus = struct {
    supported_os: bool,
    app_path: []u8,
    source_app_path: ?[]u8,
    filesystem_bundle_path: []u8,
    source_filesystem_bundle_path: ?[]u8,
    mount_helper_path: []u8,
    extension_path: []u8,
    runtime_ready_manifest_path: []u8,
    request_dir: []u8,
    app_installed: bool,
    filesystem_bundle_installed: bool,
    mount_helper_present: bool,
    extension_present: bool,
    runtime_ready: bool,
    extension_registered: bool,
    signing_identity_available: bool,
    app_group_entitled: bool,
    extension_fskit_entitled: bool,
    app_provisioned: bool,
    extension_provisioned: bool,
    module_enabled: bool,

    pub fn deinit(self: *InstallStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.app_path);
        if (self.source_app_path) |value| allocator.free(value);
        allocator.free(self.filesystem_bundle_path);
        if (self.source_filesystem_bundle_path) |value| allocator.free(value);
        allocator.free(self.mount_helper_path);
        allocator.free(self.extension_path);
        allocator.free(self.runtime_ready_manifest_path);
        allocator.free(self.request_dir);
        self.* = undefined;
    }

    pub fn ready(self: InstallStatus) bool {
        return self.supported_os and
            self.app_installed and
            self.extension_present and
            self.runtime_ready and
            self.signing_identity_available and
            self.app_group_entitled and
            self.extension_fskit_entitled and
            self.app_provisioned and
            self.extension_provisioned and
            self.extension_registered and
            self.module_enabled;
    }
};

pub fn isCurrentMacosNativeSupported() bool {
    if (builtin.os.tag != .macos) return false;
    const runtime_target = std.zig.system.resolveTargetQuery(.{}) catch return false;
    return runtime_target.os.version_range.semver.min.order(minimum_macos_native_version) != .lt;
}

pub fn detectInstallStatus(allocator: std.mem.Allocator) !InstallStatus {
    const app_path = try installedAppPath(allocator);
    errdefer allocator.free(app_path);
    const filesystem_bundle_path = try installedFilesystemBundlePath(allocator);
    errdefer allocator.free(filesystem_bundle_path);
    const mount_helper_path = try std.fs.path.join(allocator, &.{ filesystem_bundle_path, "Contents", "Resources", mount_helper_name });
    errdefer allocator.free(mount_helper_path);
    const extension_path = try std.fs.path.join(allocator, &.{ app_path, "Contents", "Extensions", extension_bundle_name });
    errdefer allocator.free(extension_path);
    const runtime_ready_manifest_path = try std.fs.path.join(allocator, &.{ app_path, "Contents", "Resources", runtime_ready_manifest_name });
    errdefer allocator.free(runtime_ready_manifest_path);
    const request_dir = try defaultRequestDirectory(allocator);
    errdefer allocator.free(request_dir);

    const app_installed = pathExists(app_path);
    const filesystem_bundle_installed = pathExists(filesystem_bundle_path);
    const mount_helper_present = pathExists(mount_helper_path);
    const extension_present = pathExists(extension_path);
    const runtime_ready = pathExists(runtime_ready_manifest_path);
    const extension_registered = if (builtin.os.tag == .macos and app_installed)
        extensionRegistered(allocator)
    else
        false;
    const signing_identity_available = if (builtin.os.tag == .macos)
        hasCodeSigningIdentity(allocator)
    else
        false;
    const app_group_entitled = if (builtin.os.tag == .macos and app_installed)
        bundleHasEntitlement(allocator, app_path, "com.apple.security.application-groups", shared_app_group_id)
    else
        false;
    const extension_fskit_entitled = if (builtin.os.tag == .macos and extension_present)
        bundleHasEntitlement(allocator, extension_path, "com.apple.developer.fskit.fsmodule", null) and bundleHasEntitlement(allocator, extension_path, "com.apple.security.application-groups", shared_app_group_id)
    else
        false;
    const app_provisioned = if (builtin.os.tag == .macos and app_installed)
        bundleHasEmbeddedProvisionProfile(allocator, app_path)
    else
        false;
    const extension_provisioned = if (builtin.os.tag == .macos and extension_present)
        bundleHasEmbeddedProvisionProfile(allocator, extension_path)
    else
        false;
    const module_enabled = if (builtin.os.tag == .macos and extension_registered)
        fskitModuleEnabled(allocator)
    else
        false;

    return .{
        .supported_os = isCurrentMacosNativeSupported(),
        .app_path = app_path,
        .source_app_path = try resolveBuiltAppSourcePath(allocator),
        .filesystem_bundle_path = filesystem_bundle_path,
        .source_filesystem_bundle_path = try resolveBuiltFilesystemBundleSourcePath(allocator),
        .mount_helper_path = mount_helper_path,
        .extension_path = extension_path,
        .runtime_ready_manifest_path = runtime_ready_manifest_path,
        .request_dir = request_dir,
        .app_installed = app_installed,
        .filesystem_bundle_installed = filesystem_bundle_installed,
        .mount_helper_present = mount_helper_present,
        .extension_present = extension_present,
        .runtime_ready = runtime_ready,
        .extension_registered = extension_registered,
        .signing_identity_available = signing_identity_available,
        .app_group_entitled = app_group_entitled,
        .extension_fskit_entitled = extension_fskit_entitled,
        .app_provisioned = app_provisioned,
        .extension_provisioned = extension_provisioned,
        .module_enabled = module_enabled,
    };
}

pub fn probeNativeBackend(allocator: std.mem.Allocator) !void {
    var status = try detectInstallStatus(allocator);
    defer status.deinit(allocator);

    if (!status.supported_os) return error.UnsupportedMacosVersion;
    if (!status.app_installed or !status.extension_present) {
        return error.NativeFsExtensionNotInstalled;
    }
    if (!status.runtime_ready) return error.NativeFsExtensionNotReady;
    if (!status.signing_identity_available) {
        return error.NativeFsExtensionSigningRequired;
    }
    if (!status.app_group_entitled or !status.extension_fskit_entitled) {
        return error.NativeFsExtensionCapabilitiesMissing;
    }
    if (!status.app_provisioned or !status.extension_provisioned) {
        return error.NativeFsExtensionProvisioningRequired;
    }
    if (!status.extension_registered) return error.NativeFsExtensionApprovalRequired;
    if (!status.module_enabled) return error.NativeFsExtensionDisabled;
}

pub fn validateNativeMountRequest(mountpoint: []const u8) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedOs;
    if (!isCurrentMacosNativeSupported()) return error.UnsupportedMacosVersion;
    try validateNativeMacosMountpoint(mountpoint);
}

pub fn installedAppPath(allocator: std.mem.Allocator) ![]u8 {
    const system_path = try std.fs.path.join(allocator, &.{ "/Applications", app_bundle_name });
    errdefer allocator.free(system_path);
    if (pathExists(system_path)) return system_path;
    allocator.free(system_path);

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, "Applications", app_bundle_name });
}

pub fn installedFilesystemBundlePath(allocator: std.mem.Allocator) ![]u8 {
    return std.fs.path.join(allocator, &.{ "/Library", "Filesystems", filesystem_bundle_name });
}

fn defaultSupportDirectory(allocator: std.mem.Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, "Library", "Application Support", app_name });
}

fn defaultSharedContainerDirectory(allocator: std.mem.Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, "Library", "Group Containers", shared_app_group_id });
}

pub fn defaultRequestDirectory(allocator: std.mem.Allocator) ![]u8 {
    const base_dir = if (builtin.os.tag == .macos)
        try defaultSharedContainerDirectory(allocator)
    else
        try defaultSupportDirectory(allocator);
    defer allocator.free(base_dir);
    return std.fs.path.join(allocator, &.{ base_dir, "Requests" });
}

pub fn defaultStatusSnapshotPath(allocator: std.mem.Allocator) ![]u8 {
    const base_dir = if (builtin.os.tag == .macos)
        try defaultSharedContainerDirectory(allocator)
    else
        try defaultSupportDirectory(allocator);
    defer allocator.free(base_dir);
    return std.fs.path.join(allocator, &.{ base_dir, "native-status.json" });
}

pub fn defaultActiveRequestPath(allocator: std.mem.Allocator) ![]u8 {
    const base_dir = if (builtin.os.tag == .macos)
        try defaultSharedContainerDirectory(allocator)
    else
        try defaultSupportDirectory(allocator);
    defer allocator.free(base_dir);
    return std.fs.path.join(allocator, &.{ base_dir, "current-request.json" });
}

pub fn resolveBuiltAppSourcePath(allocator: std.mem.Allocator) !?[]u8 {
    if (std.process.getEnvVarOwned(allocator, "SPIDERWEB_FSKIT_APP_SOURCE")) |env_path| {
        errdefer allocator.free(env_path);
        if (pathExists(env_path)) return env_path;
        allocator.free(env_path);
    } else |_| {}

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    const candidates = [_][]const u8{
        "platform/macos/build/install-source/SpiderwebFSKit.install-source.zip",
        "platform/macos/build/Build/Products/Release/SpiderwebFSKit.app",
        "platform/macos/build/DerivedData/Build/Products/Release/SpiderwebFSKit.app",
        "zig-out/SpiderwebFSKit.app",
    };
    for (candidates) |candidate| {
        const joined = try std.fs.path.join(allocator, &.{ cwd, candidate });
        if (pathExists(joined)) return joined;
        allocator.free(joined);
    }
    return null;
}

pub fn resolveBuiltFilesystemBundleSourcePath(allocator: std.mem.Allocator) !?[]u8 {
    if (std.process.getEnvVarOwned(allocator, "SPIDERWEB_FSKIT_FILESYSTEM_SOURCE")) |env_path| {
        errdefer allocator.free(env_path);
        if (pathExists(env_path)) return env_path;
        allocator.free(env_path);
    } else |_| {}

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    const candidates = [_][]const u8{
        "platform/macos/build/install-source/spiderweb.fs.install-source.zip",
        "platform/macos/build/install-source/spiderweb.fs",
        "platform/macos/build/Release/spiderweb.fs",
    };
    for (candidates) |candidate| {
        const joined = try std.fs.path.join(allocator, &.{ cwd, candidate });
        if (pathExists(joined)) return joined;
        allocator.free(joined);
    }
    return null;
}

pub fn writeLaunchRequest(allocator: std.mem.Allocator, config: native_protocol.LaunchConfig) ![]u8 {
    const request_dir = try defaultRequestDirectory(allocator);
    defer allocator.free(request_dir);
    try makePathAny(request_dir);

    const request_id = try makeRequestId(allocator);
    defer allocator.free(request_id);
    const request_filename = try std.fmt.allocPrint(allocator, "{s}.json", .{request_id});
    defer allocator.free(request_filename);
    const request_path = try std.fs.path.join(allocator, &.{ request_dir, request_filename });

    const volume_name = try defaultVolumeNameForMountpoint(allocator, config.mountpoint);
    defer allocator.free(volume_name);
    const payload = try native_protocol.encodeMountRequest(allocator, .{
        .volume_name = volume_name,
        .launch_config = config,
    });
    defer allocator.free(payload);

    var file = try createFileAny(request_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(payload);

    const active_request_path = try defaultActiveRequestPath(allocator);
    defer allocator.free(active_request_path);
    var active_file = try createFileAny(active_request_path, .{ .truncate = true });
    defer active_file.close();
    try active_file.writeAll(payload);
    return request_path;
}

pub fn requestNativeMount(allocator: std.mem.Allocator, config: native_protocol.LaunchConfig, timeout_ms: u64) !void {
    try probeNativeBackend(allocator);
    const request_path = try writeLaunchRequest(allocator, config);
    defer allocator.free(request_path);
    const request_source_path = try defaultRequestDirectory(allocator);
    defer allocator.free(request_source_path);
    try issueMountRequest(allocator, request_source_path, config.mountpoint);
    try waitForMountpoint(config.mountpoint, timeout_ms);
}

pub fn openSystemSettingsForFsExtension() void {
    if (builtin.os.tag != .macos) return;
    const url = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension";
    _ = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "open", url },
        .max_output_bytes = 0,
    }) catch {};
}

fn waitForMountpoint(mountpoint: []const u8, timeout_ms: u64) !void {
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < @as(i64, @intCast(timeout_ms))) {
        if (try isMountedPath(std.heap.page_allocator, mountpoint)) return;
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
    return error.NativeMountTimedOut;
}

fn isMountedPath(allocator: std.mem.Allocator, mountpoint: []const u8) !bool {
    if (!pathExists(mountpoint)) return false;

    var result = try runCommandBestEffort(allocator, &.{"mount"});
    defer if (result) |*value| value.deinit(allocator);
    if (result) |value| {
        if (!commandExitedSuccessfully(value)) return true;
        const marker = try std.fmt.allocPrint(allocator, " on {s} (", .{mountpoint});
        defer allocator.free(marker);
        return std.mem.indexOf(u8, value.stdout, marker) != null;
    }
    return true;
}

fn extensionRegistered(allocator: std.mem.Allocator) bool {
    var result = runCommandBestEffort(allocator, &.{ "pluginkit", "-m", "-A", "-D", "-i", extension_bundle_id }) catch return false;
    defer if (result) |*value| value.deinit(allocator);
    if (result) |value| {
        if (!commandExitedSuccessfully(value)) return false;
        return std.mem.indexOf(u8, value.stdout, extension_bundle_id) != null;
    }
    return false;
}

fn issueMountRequest(allocator: std.mem.Allocator, request_path: []const u8, mountpoint: []const u8) !void {
    try runCommandSuccess(allocator, &.{ "mount", "-t", module_short_name, request_path, mountpoint });
}

fn hasCodeSigningIdentity(allocator: std.mem.Allocator) bool {
    var result = runCommandBestEffort(allocator, &.{ "security", "find-identity", "-v", "-p", "codesigning" }) catch return false;
    defer if (result) |*value| value.deinit(allocator);
    if (result) |value| {
        const output = if (value.stdout.len > 0) value.stdout else value.stderr;
        if (std.mem.indexOf(u8, output, "0 valid identities found") != null) return false;
        return std.mem.indexOf(u8, output, "valid identities found") != null;
    }
    return false;
}

fn bundleHasEntitlement(
    allocator: std.mem.Allocator,
    bundle_path: []const u8,
    entitlement_key: []const u8,
    required_value: ?[]const u8,
) bool {
    var result = runCommandBestEffort(allocator, &.{ "codesign", "-d", "--entitlements", ":-", bundle_path }) catch return false;
    defer if (result) |*value| value.deinit(allocator);
    if (result) |value| {
        const output = if (value.stdout.len > 0) value.stdout else value.stderr;
        if (std.mem.indexOf(u8, output, entitlement_key) == null) return false;
        if (required_value) |needle| {
            return std.mem.indexOf(u8, output, needle) != null;
        }
        return true;
    }
    return false;
}

fn bundleHasEmbeddedProvisionProfile(allocator: std.mem.Allocator, bundle_path: []const u8) bool {
    const profile_path = std.fs.path.join(allocator, &.{ bundle_path, "Contents", "embedded.provisionprofile" }) catch return false;
    defer allocator.free(profile_path);
    return pathExists(profile_path);
}

fn fskitModuleEnabled(allocator: std.mem.Allocator) bool {
    const request_path = makeEnablementProbeRequest(allocator) catch return false;
    defer allocator.free(request_path);
    defer std.fs.deleteFileAbsolute(request_path) catch {};

    const mountpoint = makeEnablementProbeMountpoint(allocator) catch return false;
    defer allocator.free(mountpoint);
    makePathAny(mountpoint) catch return false;
    defer std.fs.deleteDirAbsolute(mountpoint) catch {};

    var result = runCommandBestEffort(allocator, &.{ "mount", "-F", "-t", module_short_name, request_path, mountpoint }) catch return false;
    defer if (result) |*value| value.deinit(allocator);
    if (result) |value| {
        const output = if (value.stderr.len > 0) value.stderr else value.stdout;
        return nativeMountProbeShowsEnabled(output, value.term);
    }
    return false;
}

fn nativeMountProbeShowsEnabled(output: []const u8, term: std.process.Child.Term) bool {
    if (std.mem.indexOf(u8, output, "is disabled!") != null) return false;
    if (std.mem.indexOf(u8, output, "requires approval") != null) return false;
    if (std.mem.indexOf(u8, output, "invalid file system") != null) return false;
    if (std.mem.indexOf(u8, output, "Unable to invoke task") != null) return true;
    if (std.mem.indexOf(u8, output, "Resource busy") != null) return true;
    if (output.len > 0) return true;
    if (output.len == 0) {
        return switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };
    }
    return false;
}

fn makeRequestId(allocator: std.mem.Allocator) ![]u8 {
    var random_bytes: [12]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    var encoded_buf: [std.base64.url_safe_no_pad.Encoder.calcSize(random_bytes.len)]u8 = undefined;
    const encoded = std.base64.url_safe_no_pad.Encoder.encode(&encoded_buf, &random_bytes);
    return allocator.dupe(u8, encoded);
}

fn defaultVolumeNameForMountpoint(allocator: std.mem.Allocator, mountpoint: []const u8) ![]u8 {
    const normalized = std.mem.trimRight(u8, mountpoint, "/");
    const base = std.fs.path.basename(if (normalized.len == 0) mountpoint else normalized);
    if (base.len == 0) return allocator.dupe(u8, "Spiderweb");
    return allocator.dupe(u8, base);
}

fn makeEnablementProbeRequest(allocator: std.mem.Allocator) ![]u8 {
    const temp_dir = try std.process.getEnvVarOwned(allocator, "TMPDIR");
    defer allocator.free(temp_dir);
    const request_id = try makeRequestId(allocator);
    defer allocator.free(request_id);
    const request_filename = try std.fmt.allocPrint(allocator, "{s}.json", .{request_id});
    defer allocator.free(request_filename);
    const request_path = try std.fs.path.join(allocator, &.{ temp_dir, request_filename });
    errdefer allocator.free(request_path);

    const payload = try native_protocol.encodeMountRequest(allocator, .{
        .volume_name = "Spiderweb Probe",
        .launch_config = .{
            .mountpoint = "/tmp/spiderweb-fskit-probe",
            .endpoints = &.{},
            .namespace = null,
        },
    });
    defer allocator.free(payload);

    var file = try createFileAny(request_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(payload);
    return request_path;
}

fn makeEnablementProbeMountpoint(allocator: std.mem.Allocator) ![]u8 {
    const temp_dir = try std.process.getEnvVarOwned(allocator, "TMPDIR");
    defer allocator.free(temp_dir);
    return std.fs.path.join(allocator, &.{ temp_dir, "spiderweb-fskit-enable-probe" });
}

const CommandResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    fn deinit(self: *CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

fn runCommandCapture(allocator: std.mem.Allocator, argv: []const []const u8) !CommandResult {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 128 * 1024,
    });
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
    };
}

fn runCommandSuccess(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var result = try runCommandCapture(allocator, argv);
    defer result.deinit(allocator);
    if (commandExitedSuccessfully(result)) return;
    const output = if (result.stderr.len > 0) result.stderr else result.stdout;
    if (output.len > 0) {
        std.log.err("{s}", .{std.mem.trim(u8, output, " \n\r\t")});
    }
    return error.CommandFailed;
}

fn runCommandBestEffort(allocator: std.mem.Allocator, argv: []const []const u8) !?CommandResult {
    return runCommandCapture(allocator, argv) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
}

fn commandExitedSuccessfully(result: CommandResult) bool {
    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
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

fn validateNativeMacosMountpoint(mountpoint: []const u8) !void {
    const trimmed = std.mem.trimRight(u8, mountpoint, "/");
    if (trimmed.len == 0 or !std.fs.path.isAbsolute(trimmed)) return error.InvalidMacosMountpoint;
}

fn makePathAny(path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        var root_dir = try std.fs.openDirAbsolute("/", .{});
        defer root_dir.close();
        const rel_dir = std.mem.trimLeft(u8, path, "/");
        if (rel_dir.len == 0) return;
        root_dir.makePath(rel_dir) catch |err| switch (err) {
            error.PathAlreadyExists => return,
            else => return err,
        };
        return;
    }
    try std.fs.cwd().makePath(path);
}

fn createFileAny(path: []const u8, flags: std.fs.File.CreateFlags) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) return std.fs.createFileAbsolute(path, flags);
    return std.fs.cwd().createFile(path, flags);
}

test "native_mount_support: resolves install path under applications" {
    const allocator = std.testing.allocator;
    const app_path = try installedAppPath(allocator);
    defer allocator.free(app_path);
    const filesystem_bundle_path = try installedFilesystemBundlePath(allocator);
    defer allocator.free(filesystem_bundle_path);
    const request_dir = try defaultRequestDirectory(allocator);
    defer allocator.free(request_dir);

    try std.testing.expect(std.mem.endsWith(u8, app_path, "Applications/SpiderwebFSKit.app"));
    try std.testing.expect(std.mem.eql(u8, filesystem_bundle_path, "/Library/Filesystems/spiderweb.fs"));
    if (builtin.os.tag == .macos) {
        try std.testing.expect(std.mem.indexOf(u8, request_dir, "Group Containers/group.com.deanoc.spiderweb.fskit/Requests") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, request_dir, "Application Support/SpiderwebFSKit/Requests") != null);
    }
}

test "native_mount_support: runtime gating requires macos 15.4 or newer" {
    try std.testing.expect(minimum_macos_native_version.order(.{ .major = 15, .minor = 4, .patch = 0 }) != .gt);
}

test "native_mount_support: validates native macos mountpoint layout" {
    try validateNativeMacosMountpoint("/Volumes/Spiderweb");
    try validateNativeMacosMountpoint("/Users/deanocalver/spiderweb-mount");
    try validateNativeMacosMountpoint("/tmp/spiderweb-native");
    try std.testing.expectError(error.InvalidMacosMountpoint, validateNativeMacosMountpoint("relative/path"));
    try std.testing.expectError(error.InvalidMacosMountpoint, validateNativeMacosMountpoint(""));
}

test "native_mount_support: parses fsck_fskit disabled output" {
    try std.testing.expect(!nativeMountProbeShowsEnabled(
        "Module com.deanoc.spiderweb.fskit.app.extension is disabled!\n",
        .{ .Exited = 22 },
    ));
}

test "native_mount_support: parses native mount probe enabled output" {
    try std.testing.expect(nativeMountProbeShowsEnabled(
        "mount: Unable to invoke task\n",
        .{ .Exited = 8 },
    ));
    try std.testing.expect(nativeMountProbeShowsEnabled(
        "mount: Probing resource: The operation couldn’t be completed. Resource busy\nmount: Unable to invoke task\n",
        .{ .Exited = 72 },
    ));
}

test "native_mount_support: parses native mount probe disabled output" {
    try std.testing.expect(!nativeMountProbeShowsEnabled("mount: /tmp/probe: invalid file system.\n", .{ .Exited = 1 }));
    try std.testing.expect(!nativeMountProbeShowsEnabled("Module com.deanoc.spiderweb.fskit.app.extension is disabled!\n", .{ .Exited = 22 }));
    try std.testing.expect(!nativeMountProbeShowsEnabled("mount: File system extension requires approval\n", .{ .Exited = 69 }));
}
