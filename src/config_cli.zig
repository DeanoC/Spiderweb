const std = @import("std");
const builtin = @import("builtin");
const Config = @import("config.zig");
const credential_store_mod = @import("credential_store.zig");
const native_mount_support = @import("acheron/native_mount_support.zig");
const first_run = @import("first_run.zig");

const auth_tokens_filename = "auth_tokens.json";

const AuthStatusSnapshot = struct {
    admin_token: []u8,
    user_token: []u8,

    fn deinit(self: *AuthStatusSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.admin_token);
        allocator.free(self.user_token);
        self.* = undefined;
    }
};

const NativeFsStatusSnapshot = struct {
    version: u8 = 1,
    registered: bool,
    module_enabled: bool,
    ready: bool,
    filesystem_bundle_present: bool,
    mount_helper_present: bool,
    runtime_ready: bool,
    updated_at_ms: i64,
};

const AuthStatusJson = struct {
    path: []const u8,
    admin_present: bool,
    user_present: bool,
    admin_token: ?[]const u8 = null,
    user_token: ?[]const u8 = null,
};

const ServiceStatusJson = struct {
    manager: []const u8,
    unit_path: []const u8,
    installed: bool,
    loaded: bool,
    enabled: ?[]const u8 = null,
    active: ?[]const u8 = null,
};

const FsExtensionStatusJson = struct {
    manager: []const u8 = "native-fskit",
    supported_os: bool,
    active_app: []const u8,
    built_app_source: ?[]const u8 = null,
    extension_bundle: []const u8,
    runtime_source: []const u8,
    filesystem_bundle: []const u8,
    extension_present: bool,
    runtime_ready: bool,
    signing_identity: bool,
    app_group_entitlements: bool,
    extension_fs_entitlement: bool,
    app_provisioned: bool,
    extension_provisioned: bool,
    registered: bool,
    module_enabled: bool,
    ready: bool,
    request_dir: []const u8,
    notes: []const []const u8,
};

const RemoteNodeStatusJson = struct {
    enabled: bool,
    remote_control_url: []const u8,
    node_name: []const u8,
    public_base_url: []const u8,
    export_path: []const u8,
    export_name: []const u8,
    export_ro: bool,
    node_id: []const u8,
    lease_ttl_ms: u64,
    heartbeat_ms: u64,
    secret_present: bool,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "config")) {
        try handleConfigCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "auth")) {
        try handleAuthCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "first-run")) {
        try first_run.runFirstRun(allocator, args[2..]);
    } else {
        std.log.err("Unknown command: {s}", .{command});
        try printUsage();
        return error.UnknownCommand;
    }
}

fn handleAuthCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const subcommand = if (args.len > 0) args[0] else "help";

    if (std.mem.eql(u8, subcommand, "path")) {
        var config = try Config.init(allocator, null);
        defer config.deinit();
        const path = try resolveAuthTokensPath(allocator, config.runtime.ltm_directory, config.runtime.spider_web_root, config.config_path);
        defer allocator.free(path);
        const out = try std.fmt.allocPrint(allocator, "{s}\n", .{path});
        defer allocator.free(out);
        try std.fs.File.stdout().writeAll(out);
        return;
    }

    if (std.mem.eql(u8, subcommand, "status")) {
        var reveal_tokens = false;
        var json_output = false;
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--reveal")) {
                reveal_tokens = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--json")) {
                json_output = true;
                continue;
            }
            std.log.err("Unknown auth status arg: {s}", .{arg});
            return error.InvalidArguments;
        }

        var config = try Config.init(allocator, null);
        defer config.deinit();
        const path = try resolveAuthTokensPath(allocator, config.runtime.ltm_directory, config.runtime.spider_web_root, config.config_path);
        defer allocator.free(path);

        var snapshot = try loadAuthStatusSnapshot(allocator, path);
        defer snapshot.deinit(allocator);

        if (json_output) {
            const payload = try std.json.Stringify.valueAlloc(allocator, AuthStatusJson{
                .path = path,
                .admin_present = snapshot.admin_token.len > 0,
                .user_present = snapshot.user_token.len > 0,
                .admin_token = if (reveal_tokens) snapshot.admin_token else null,
                .user_token = if (reveal_tokens) snapshot.user_token else null,
            }, .{});
            defer allocator.free(payload);
            try std.fs.File.stdout().writeAll(payload);
            try std.fs.File.stdout().writeAll("\n");
            return;
        }

        const admin_display_owned = if (reveal_tokens)
            null
        else
            try maskTokenForDisplay(allocator, snapshot.admin_token);
        defer if (admin_display_owned) |value| allocator.free(value);

        const user_display_owned = if (reveal_tokens)
            null
        else
            try maskTokenForDisplay(allocator, snapshot.user_token);
        defer if (user_display_owned) |value| allocator.free(value);

        const admin_display = if (admin_display_owned) |value| value else snapshot.admin_token;
        const user_display = if (user_display_owned) |value| value else snapshot.user_token;

        const out = try std.fmt.allocPrint(
            allocator,
            "Auth status\n  admin_token: {s}\n  user_token:  {s}\n  path:        {s}\n",
            .{ admin_display, user_display, path },
        );
        defer allocator.free(out);
        try std.fs.File.stdout().writeAll(out);
        if (!reveal_tokens) {
            try std.fs.File.stdout().writeAll("  note: tokens are masked; run `spiderweb-config auth status --reveal` for full values\n");
        }
        return;
    }

    if (std.mem.eql(u8, subcommand, "reset")) {
        var confirmed = false;
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--yes")) {
                confirmed = true;
                continue;
            }
            std.log.err("Unknown auth reset arg: {s}", .{arg});
            return error.InvalidArguments;
        }
        if (!confirmed) {
            std.log.err("Refusing to reset auth tokens without --yes", .{});
            std.log.info("Run: spiderweb-config auth reset --yes", .{});
            return error.InvalidArguments;
        }

        var config = try Config.init(allocator, null);
        defer config.deinit();
        const path = try resolveAuthTokensPath(allocator, config.runtime.ltm_directory, config.runtime.spider_web_root, config.config_path);
        defer allocator.free(path);
        const admin_token = try makeOpaqueToken(allocator, "sw-admin");
        defer allocator.free(admin_token);
        const user_token = try makeOpaqueToken(allocator, "sw-user");
        defer allocator.free(user_token);
        try persistAuthTokens(allocator, path, admin_token, user_token);

        std.log.warn("Emergency auth token reset completed.", .{});
        std.log.warn("  path:  {s}", .{path});
        std.log.warn("  admin: {s}", .{admin_token});
        std.log.warn("  user:  {s}", .{user_token});
        std.log.warn("Restart spiderweb to apply new tokens for subsequent connections.", .{});
        return;
    }

    try printAuthUsage();
}

fn handleConfigCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        // Show current config
        var config = try Config.init(allocator, null);
        defer config.deinit();

        const stdout_file = std.fs.File.stdout();
        var buf: [1024]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "Config: {s}\n  Bind: {s}:{d}\n  Spider Web Root: {s}\n  Runtime Storage: {s}/{s}\n  Log: {s}\n", .{
            config.config_path,
            config.server.bind,
            config.server.port,
            config.runtime.spider_web_root,
            config.runtime.ltm_directory,
            config.runtime.ltm_filename,
            config.log.level,
        });
        try stdout_file.writeAll(msg);
        try stdout_file.writeAll("  Note: AI provider and worker configuration now lives with the external worker (for example Spider Monkey).\n");
        return;
    }

    const subcommand = args[0];

    if (std.mem.eql(u8, subcommand, "set-server")) {
        if (args.len < 3) {
            std.log.err("Usage: config set-server --bind <addr> --port <port>", .{});
            return error.InvalidArguments;
        }

        var config = try Config.init(allocator, null);
        defer config.deinit();

        var bind: ?[]const u8 = null;
        var port: ?u16 = null;

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--bind")) {
                i += 1;
                if (i < args.len) bind = args[i];
            } else if (std.mem.eql(u8, args[i], "--port")) {
                i += 1;
                if (i < args.len) port = try std.fmt.parseInt(u16, args[i], 10);
            }
        }

        try config.setServer(bind, port);
        std.log.info("Updated server config", .{});
    } else if (std.mem.eql(u8, subcommand, "set-log")) {
        if (args.len < 2) {
            std.log.err("Usage: config set-log <level>", .{});
            return error.InvalidArguments;
        }

        var config = try Config.init(allocator, null);
        defer config.deinit();

        try config.setLogLevel(args[1]);
        std.log.info("Set log level to {s}", .{args[1]});
    } else if (std.mem.eql(u8, subcommand, "path")) {
        var config = try Config.init(allocator, null);
        defer config.deinit();

        const stdout_file = std.fs.File.stdout();
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{s}\n", .{config.config_path});
        try stdout_file.writeAll(msg);
    } else if (std.mem.eql(u8, subcommand, "install-service")) {
        try installService(allocator);
    } else if (std.mem.eql(u8, subcommand, "uninstall-service")) {
        try uninstallService(allocator);
    } else if (std.mem.eql(u8, subcommand, "service-status")) {
        const json_output = try parseJsonOnlyFlag(args[1..]);
        try printServiceStatus(allocator, json_output);
    } else if (std.mem.eql(u8, subcommand, "install-fs-extension")) {
        try installFsExtension(allocator);
    } else if (std.mem.eql(u8, subcommand, "uninstall-fs-extension")) {
        try uninstallFsExtension(allocator);
    } else if (std.mem.eql(u8, subcommand, "fs-extension-status")) {
        const json_output = try parseJsonOnlyFlag(args[1..]);
        try printFsExtensionStatus(allocator, json_output);
    } else if (std.mem.eql(u8, subcommand, "remote-node")) {
        try handleRemoteNodeConfigCommand(allocator, args[1..]);
    } else {
        std.log.err("Unknown config command: {s}", .{subcommand});
        std.log.info("Available: set-server, set-log, path, install-service, uninstall-service, service-status, install-fs-extension, uninstall-fs-extension, fs-extension-status, remote-node", .{});
        return error.UnknownCommand;
    }
}

const ServiceManager = enum {
    systemd_user,
    launchd_user,
    unsupported,
};

const service_name = "spiderweb";

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

fn installService(allocator: std.mem.Allocator) !void {
    try ensureDefaultLocalWorkspaceRootConfig(allocator);
    try ensureDefaultRuntimeStorageConfig(allocator);
    return switch (detectServiceManager()) {
        .systemd_user => installSystemdUserService(allocator),
        .launchd_user => installLaunchdUserService(allocator),
        .unsupported => error.UnsupportedPlatform,
    };
}

fn uninstallService(allocator: std.mem.Allocator) !void {
    return switch (detectServiceManager()) {
        .systemd_user => uninstallSystemdUserService(allocator),
        .launchd_user => uninstallLaunchdUserService(allocator),
        .unsupported => error.UnsupportedPlatform,
    };
}

fn parseJsonOnlyFlag(args: []const []const u8) !bool {
    var json_output = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
            continue;
        }
        std.log.err("Unknown status arg: {s}", .{arg});
        return error.InvalidArguments;
    }
    return json_output;
}

fn printServiceStatus(allocator: std.mem.Allocator, json_output: bool) !void {
    return switch (detectServiceManager()) {
        .systemd_user => printSystemdUserServiceStatus(allocator, json_output),
        .launchd_user => printLaunchdUserServiceStatus(allocator, json_output),
        .unsupported => error.UnsupportedPlatform,
    };
}

fn handleRemoteNodeConfigCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const subcommand = if (args.len > 0) args[0] else "status";
    if (std.mem.eql(u8, subcommand, "status")) {
        const json_output = try parseJsonOnlyFlag(args[1..]);
        try printRemoteNodeStatus(allocator, json_output);
        return;
    }
    if (std.mem.eql(u8, subcommand, "clear")) {
        try clearRemoteNodeConfig(allocator);
        return;
    }
    if (std.mem.eql(u8, subcommand, "set")) {
        try setRemoteNodeConfig(allocator, args[1..]);
        return;
    }

    std.log.err("Unknown remote-node command: {s}", .{subcommand});
    std.log.info("Available: status, set, clear", .{});
    return error.UnknownCommand;
}

fn printRemoteNodeStatus(allocator: std.mem.Allocator, json_output: bool) !void {
    var config = try Config.init(allocator, null);
    defer config.deinit();
    const store = credential_store_mod.CredentialStore.init(allocator);
    const secret_present = blk: {
        const node_id = std.mem.trim(u8, config.runtime.remote_node.node_id, " \t\r\n");
        if (node_id.len == 0) break :blk false;
        const secret = store.getRemoteNodeSecret(node_id) orelse break :blk false;
        allocator.free(secret);
        break :blk true;
    };

    if (json_output) {
        const payload = try std.json.Stringify.valueAlloc(allocator, RemoteNodeStatusJson{
            .enabled = config.runtime.remote_node.enabled,
            .remote_control_url = config.runtime.remote_node.remote_control_url,
            .node_name = config.runtime.remote_node.node_name,
            .public_base_url = config.runtime.remote_node.public_base_url,
            .export_path = config.runtime.remote_node.export_path,
            .export_name = config.runtime.remote_node.export_name,
            .export_ro = config.runtime.remote_node.export_ro,
            .node_id = config.runtime.remote_node.node_id,
            .lease_ttl_ms = config.runtime.remote_node.lease_ttl_ms,
            .heartbeat_ms = config.runtime.remote_node.heartbeat_ms,
            .secret_present = secret_present,
        }, .{});
        defer allocator.free(payload);
        try std.fs.File.stdout().writeAll(payload);
        try std.fs.File.stdout().writeAll("\n");
        return;
    }

    const out = try std.fmt.allocPrint(
        allocator,
        "Remote node\n  enabled:            {s}\n  remote_control_url: {s}\n  node_name:          {s}\n  public_base_url:    {s}\n  export_path:        {s}\n  export_name:        {s}\n  export_ro:          {s}\n  node_id:            {s}\n  lease_ttl_ms:       {d}\n  heartbeat_ms:       {d}\n  secret_present:     {s}\n",
        .{
            if (config.runtime.remote_node.enabled) "yes" else "no",
            config.runtime.remote_node.remote_control_url,
            config.runtime.remote_node.node_name,
            config.runtime.remote_node.public_base_url,
            config.runtime.remote_node.export_path,
            config.runtime.remote_node.export_name,
            if (config.runtime.remote_node.export_ro) "yes" else "no",
            config.runtime.remote_node.node_id,
            config.runtime.remote_node.lease_ttl_ms,
            config.runtime.remote_node.heartbeat_ms,
            if (secret_present) "yes" else "no",
        },
    );
    defer allocator.free(out);
    try std.fs.File.stdout().writeAll(out);
}

fn setRemoteNodeConfig(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var remote_control_url: ?[]const u8 = null;
    var node_name: ?[]const u8 = null;
    var public_base_url: ?[]const u8 = null;
    var export_path: ?[]const u8 = null;
    var export_name: ?[]const u8 = null;
    var node_id: ?[]const u8 = null;
    var node_secret: ?[]const u8 = null;
    var export_ro = false;
    var lease_ttl_ms: ?u64 = null;
    var heartbeat_ms: ?u64 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--remote-control-url")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            remote_control_url = args[i];
        } else if (std.mem.eql(u8, arg, "--node-name")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            node_name = args[i];
        } else if (std.mem.eql(u8, arg, "--public-base-url")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            public_base_url = args[i];
        } else if (std.mem.eql(u8, arg, "--export-path")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            export_path = args[i];
        } else if (std.mem.eql(u8, arg, "--export-name")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            export_name = args[i];
        } else if (std.mem.eql(u8, arg, "--node-id")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            node_id = args[i];
        } else if (std.mem.eql(u8, arg, "--node-secret")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            node_secret = args[i];
        } else if (std.mem.eql(u8, arg, "--lease-ttl-ms")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            lease_ttl_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--heartbeat-ms")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            heartbeat_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--read-only")) {
            export_ro = true;
        } else {
            std.log.err("Unknown remote-node set arg: {s}", .{arg});
            return error.InvalidArguments;
        }
    }

    const next_remote_control_url = remote_control_url orelse return error.InvalidArguments;
    const next_node_name = node_name orelse return error.InvalidArguments;
    const next_public_base_url = public_base_url orelse return error.InvalidArguments;
    const next_export_path = export_path orelse return error.InvalidArguments;
    const next_node_id = node_id orelse return error.InvalidArguments;

    var config = try Config.init(allocator, null);
    defer config.deinit();

    replaceOwnedString(allocator, &config.runtime.remote_node.remote_control_url, next_remote_control_url) catch return error.OutOfMemory;
    replaceOwnedString(allocator, &config.runtime.remote_node.node_name, next_node_name) catch return error.OutOfMemory;
    replaceOwnedString(allocator, &config.runtime.remote_node.public_base_url, next_public_base_url) catch return error.OutOfMemory;
    replaceOwnedString(allocator, &config.runtime.remote_node.export_path, next_export_path) catch return error.OutOfMemory;
    replaceOwnedString(allocator, &config.runtime.remote_node.export_name, export_name orelse "fs") catch return error.OutOfMemory;
    replaceOwnedString(allocator, &config.runtime.remote_node.node_id, next_node_id) catch return error.OutOfMemory;
    config.runtime.remote_node.export_ro = export_ro;
    config.runtime.remote_node.enabled = true;
    config.runtime.remote_node.lease_ttl_ms = lease_ttl_ms orelse config.runtime.remote_node.lease_ttl_ms;
    config.runtime.remote_node.heartbeat_ms = heartbeat_ms orelse config.runtime.remote_node.heartbeat_ms;
    try config.save();

    if (node_secret) |secret| {
        const store = credential_store_mod.CredentialStore.init(allocator);
        try store.setRemoteNodeSecret(next_node_id, secret);
    }
}

fn clearRemoteNodeConfig(allocator: std.mem.Allocator) !void {
    var config = try Config.init(allocator, null);
    defer config.deinit();

    const previous_node_id = try allocator.dupe(u8, std.mem.trim(u8, config.runtime.remote_node.node_id, " \t\r\n"));
    defer allocator.free(previous_node_id);

    replaceOwnedString(allocator, &config.runtime.remote_node.remote_control_url, "") catch return error.OutOfMemory;
    replaceOwnedString(allocator, &config.runtime.remote_node.node_name, "") catch return error.OutOfMemory;
    replaceOwnedString(allocator, &config.runtime.remote_node.public_base_url, "") catch return error.OutOfMemory;
    replaceOwnedString(allocator, &config.runtime.remote_node.export_path, "") catch return error.OutOfMemory;
    replaceOwnedString(allocator, &config.runtime.remote_node.export_name, "fs") catch return error.OutOfMemory;
    replaceOwnedString(allocator, &config.runtime.remote_node.node_id, "") catch return error.OutOfMemory;
    config.runtime.remote_node.export_ro = false;
    config.runtime.remote_node.enabled = false;
    config.runtime.remote_node.lease_ttl_ms = 15 * 60 * 1000;
    config.runtime.remote_node.heartbeat_ms = (15 * 60 * 1000) / 2;
    try config.save();

    if (previous_node_id.len > 0) {
        const store = credential_store_mod.CredentialStore.init(allocator);
        store.clearRemoteNodeSecret(previous_node_id) catch {};
    }
}

fn replaceOwnedString(allocator: std.mem.Allocator, target: *[]const u8, next: []const u8) !void {
    const dupe = try allocator.dupe(u8, next);
    allocator.free(target.*);
    target.* = dupe;
}

fn installFsExtension(allocator: std.mem.Allocator) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;

    var status = try native_mount_support.detectInstallStatus(allocator);
    defer status.deinit(allocator);

    if (!status.supported_os) return error.UnsupportedMacosVersion;
    const target_app_path = status.app_path;
    const source_app_path = blk: {
        if (status.source_app_path) |value| break :blk value;
        if (pathExists(target_app_path)) break :blk target_app_path;
        std.log.err("Could not find Spiderweb.app to register. Reinstall Spiderweb.app or build it from Xcode under platform/macos.", .{});
        return error.NativeFsExtensionNotInstalled;
    };
    const source_is_installed_app = std.mem.eql(u8, source_app_path, target_app_path);
    const install_script_path = try native_mount_support.resolveFilesystemBundleInstallScriptPath(allocator);
    defer if (install_script_path) |value| allocator.free(value);

    stopNativeFsExtensionProcesses(allocator);
    try cleanupLegacyNativeFsArtifacts(
        allocator,
        target_app_path,
        if (source_is_installed_app) status.filesystem_bundle_path else null,
    );
    try cleanupDerivedDataNativeFsArtifacts(allocator, target_app_path);

    if (!source_is_installed_app) {
        if (try runCommandBestEffort(allocator, &.{
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
            "-u",
            source_app_path,
        })) |result| {
            var owned = result;
            owned.deinit(allocator);
        }
    }

    if (pathExists(status.extension_path)) {
        if (try runCommandBestEffort(allocator, &.{ "pluginkit", "-r", status.extension_path })) |result| {
            var owned = result;
            owned.deinit(allocator);
        }
    }

    if (!source_is_installed_app) {
        try installBundleTreeFromSource(
            allocator,
            source_app_path,
            target_app_path,
            isSystemApplicationsPath(target_app_path),
            null,
        );
    }

    if (!status.filesystem_bundle_installed or !status.mount_helper_present or !source_is_installed_app) {
        const script_path = install_script_path orelse {
            std.log.err("Could not find install-spiderweb-fskit-filesystem-bundle.sh under platform/macos/scripts.", .{});
            return error.NativeFsExtensionNotInstalled;
        };
        try runCommandSuccess(allocator, &.{ "/bin/bash", script_path });
    }
    try runCommandSuccess(allocator, &.{
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
        "-f",
        "-R",
        "-trusted",
        target_app_path,
    });

    const installed_extension_path = try std.fs.path.join(
        allocator,
        &.{ target_app_path, "Contents", "Extensions", native_mount_support.extension_bundle_name },
    );
    defer allocator.free(installed_extension_path);

    if (pathExists(installed_extension_path)) {
        if (try runCommandBestEffort(allocator, &.{ "pluginkit", "-a", installed_extension_path })) |result| {
            var owned = result;
            owned.deinit(allocator);
        }
        if (try runCommandBestEffort(allocator, &.{ "pluginkit", "-e", "use", "-p", "com.apple.fskit.fsmodule", "-i", native_mount_support.extension_bundle_id })) |result| {
            var owned = result;
            owned.deinit(allocator);
        }
    }
    if (try runCommandBestEffort(allocator, &.{ "open", "-n", "-a", target_app_path })) |result| {
        var owned = result;
        owned.deinit(allocator);
    }
    native_mount_support.openSystemSettingsForFsExtension();

    var refreshed = try native_mount_support.detectInstallStatus(allocator);
    defer refreshed.deinit(allocator);
    try writeNativeFsStatusSnapshot(allocator, refreshed);

    if (source_is_installed_app) {
        std.log.info("Registered installed Spiderweb.app at {s}", .{target_app_path});
    } else {
        std.log.info("Installed Spiderweb.app from {s} to {s}", .{ source_app_path, target_app_path });
    }
    std.log.info("Installed spiderweb.fs to {s}", .{status.filesystem_bundle_path});
    std.log.info("If macOS prompts for approval, enable the file system extension in System Settings -> General -> Login Items & Extensions.", .{});
}

fn uninstallFsExtension(allocator: std.mem.Allocator) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;

    var status = try native_mount_support.detectInstallStatus(allocator);
    defer status.deinit(allocator);

    stopNativeFsExtensionProcesses(allocator);
    if (pathExists(status.extension_path)) {
        if (try runCommandBestEffort(allocator, &.{ "pluginkit", "-r", status.extension_path })) |result| {
            var owned = result;
            owned.deinit(allocator);
        }
    }
    if (pathExists(status.app_path)) {
        if (try runCommandBestEffort(allocator, &.{
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
            "-u",
            status.app_path,
        })) |result| {
            var owned = result;
            owned.deinit(allocator);
        }
    }
    try cleanupLegacyNativeFsArtifacts(allocator, status.app_path, null);
    _ = try deleteTreeIfExistsAny(status.request_dir);
    const snapshot_path = try native_mount_support.defaultStatusSnapshotPath(allocator);
    defer allocator.free(snapshot_path);
    _ = try deleteFileIfExistsAny(snapshot_path);

    std.log.info("Unregistered Spiderweb.app at {s}", .{status.app_path});
    std.log.info("Removed Spiderweb filesystem bundles from /Library/Filesystems", .{});
}

fn stopNativeFsExtensionProcesses(allocator: std.mem.Allocator) void {
    const command_sets = [_][]const []const u8{
        &.{ "pkill", "-x", native_mount_support.app_name },
        &.{ "pkill", "-f", native_mount_support.app_bundle_id },
        &.{ "pkill", "-f", native_mount_support.extension_bundle_id },
    };

    for (command_sets) |argv| {
        if (runCommandBestEffort(allocator, argv)) |maybe_result| {
            if (maybe_result) |result| {
                var owned = result;
                owned.deinit(allocator);
            }
        } else |_| {}
    }
}

fn cleanupLegacyNativeFsArtifacts(
    allocator: std.mem.Allocator,
    active_app_path: []const u8,
    active_filesystem_bundle_path: ?[]const u8,
) !void {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
    defer if (home) |value| allocator.free(value);

    const user_app_path = if (home) |home_dir|
        try std.fs.path.join(allocator, &.{ home_dir, "Applications", native_mount_support.app_bundle_name })
    else
        null;
    defer if (user_app_path) |value| allocator.free(value);

    const legacy_app_paths = [_][]const u8{
        "/Applications/SpiderwebFSKit.app",
        if (user_app_path) |value| value else "",
    };
    for (legacy_app_paths) |path| {
        if (path.len == 0) continue;
        if (std.mem.eql(u8, path, active_app_path)) continue;
        if (try runCommandBestEffort(allocator, &.{
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
            "-u",
            path,
        })) |result| {
            var owned = result;
            owned.deinit(allocator);
        }
        if (pathExists(path)) {
            if (isSystemApplicationsPath(path)) {
                try privilegedDeleteTreeIfExists(allocator, path);
            } else {
                _ = try deleteTreeIfExistsAny(path);
            }
        }
    }

    const legacy_filesystem_paths = [_][]const u8{
        "/Library/Filesystems/passthrough.fs",
        "/Library/Filesystems/PassthroughFS.fs",
        "/Library/Filesystems/spiderweb.fs",
        "/Library/Filesystems/spiderweb.fs.disabled-codex",
    };
    for (legacy_filesystem_paths) |path| {
        if (active_filesystem_bundle_path) |active_path| {
            if (std.mem.eql(u8, path, active_path)) continue;
        }
        if (try runCommandBestEffort(allocator, &.{ "pluginkit", "-r", path })) |result| {
            var owned = result;
            owned.deinit(allocator);
        }
        if (pathExists(path)) {
            try privilegedDeleteTreeIfExists(allocator, path);
        }
    }
}

fn cleanupDerivedDataNativeFsArtifacts(allocator: std.mem.Allocator, active_app_path: []const u8) !void {
    if (builtin.os.tag != .macos) return;

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return;
    defer allocator.free(home);
    const derived_data_root = try std.fs.path.join(allocator, &.{ home, "Library", "Developer", "Xcode", "DerivedData" });
    defer allocator.free(derived_data_root);
    if (!pathExists(derived_data_root)) return;

    var result = try runCommandBestEffort(allocator, &.{
        "find",
        derived_data_root,
        "-maxdepth",
        "5",
        "-type",
        "d",
        "-name",
        native_mount_support.app_bundle_name,
    });
    defer if (result) |*value| value.deinit(allocator);

    if (result) |value| {
        if (!commandExitedSuccessfully(value)) return;
        var lines = std.mem.tokenizeAny(u8, value.stdout, "\r\n");
        while (lines.next()) |app_path| {
            if (app_path.len == 0) continue;
            if (std.mem.eql(u8, app_path, active_app_path)) continue;

            const extension_path = try std.fs.path.join(
                allocator,
                &.{ app_path, "Contents", "Extensions", native_mount_support.extension_bundle_name },
            );
            defer allocator.free(extension_path);

            if (pathExists(extension_path)) {
                if (try runCommandBestEffort(allocator, &.{ "pluginkit", "-r", extension_path })) |plugin_result| {
                    var owned_plugin_result = plugin_result;
                    owned_plugin_result.deinit(allocator);
                }
            }
            if (try runCommandBestEffort(allocator, &.{
                "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                "-u",
                app_path,
            })) |ls_result| {
                var owned_ls_result = ls_result;
                owned_ls_result.deinit(allocator);
            }
        }
    }
}

fn printFsExtensionStatus(allocator: std.mem.Allocator, json_output: bool) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;

    var status = try native_mount_support.detectInstallStatus(allocator);
    defer status.deinit(allocator);
    try writeNativeFsStatusSnapshot(allocator, status);

    var notes = std.ArrayListUnmanaged([]const u8){};
    defer notes.deinit(allocator);
    if (!status.runtime_ready) try notes.append(allocator, "no current Spiderweb Xcode build was found; build the app in platform/macos, then rerun install-fs-extension");
    if (!status.extension_fskit_entitled) try notes.append(allocator, "launch is blocked because the extension build is missing the FSKit entitlement");
    if (status.ready()) {
        try notes.append(allocator, "owner/group changes are unsupported because native macOS mounts currently present as noowners");
        try notes.append(allocator, "advisory locks currently apply only inside the mounted Spiderweb view and are not mirrored to the host path");
        try notes.append(allocator, "files edited directly on the host path after they have already been seen through the mount may remain stale until reopen or remount");
    }

    if (json_output) {
        const payload = try std.json.Stringify.valueAlloc(allocator, FsExtensionStatusJson{
            .supported_os = status.supported_os,
            .active_app = status.app_path,
            .built_app_source = status.source_app_path,
            .extension_bundle = status.extension_path,
            .runtime_source = status.runtime_ready_manifest_path,
            .filesystem_bundle = status.filesystem_bundle_path,
            .extension_present = status.extension_present,
            .runtime_ready = status.runtime_ready,
            .signing_identity = status.signing_identity_available,
            .app_group_entitlements = status.app_group_entitled,
            .extension_fs_entitlement = status.extension_fskit_entitled,
            .app_provisioned = status.app_provisioned,
            .extension_provisioned = status.extension_provisioned,
            .registered = status.extension_registered,
            .module_enabled = status.module_enabled,
            .ready = status.ready(),
            .request_dir = status.request_dir,
            .notes = notes.items,
        }, .{});
        defer allocator.free(payload);
        try std.fs.File.stdout().writeAll(payload);
        try std.fs.File.stdout().writeAll("\n");
        return;
    }

    const out = try std.fmt.allocPrint(
        allocator,
        "FS extension manager: native-fskit\n  supported_os:             {s}\n  active_app:               {s}\n  built_app_source:         {s}\n  extension_bundle:         {s}\n  runtime_source:           {s}\n  filesystem_bundle:        {s}\n  extension_present:        {s}\n  runtime_ready:            {s}\n  signing_identity:         {s}\n  app_group_entitlements:   {s}\n  extension_fs_entitlement: {s}\n  app_provisioned:          {s}\n  extension_provisioned:    {s}\n  registered:               {s}\n  module_enabled:           {s}\n  ready:                    {s}\n  request_dir:              {s}\n",
        .{
            if (status.supported_os) "yes" else "no",
            status.app_path,
            status.source_app_path orelse "(not found)",
            status.extension_path,
            status.runtime_ready_manifest_path,
            status.filesystem_bundle_path,
            if (status.extension_present) "yes" else "no",
            if (status.runtime_ready) "yes" else "no",
            if (status.signing_identity_available) "yes" else "no",
            if (status.app_group_entitled) "yes" else "no",
            if (status.extension_fskit_entitled) "yes" else "no",
            if (status.app_provisioned) "yes" else "no",
            if (status.extension_provisioned) "yes" else "no",
            if (status.extension_registered) "yes" else "no",
            if (status.module_enabled) "yes" else "no",
            if (status.ready()) "yes" else "no",
            status.request_dir,
        },
    );
    defer allocator.free(out);
    try std.fs.File.stdout().writeAll(out);
    if (!status.runtime_ready) {
        try std.fs.File.stdout().writeAll(
            "  note: no current Spiderweb Xcode build was found; build the app in platform/macos, then rerun install-fs-extension.\n",
        );
    }
    if (!status.extension_fskit_entitled) {
        try std.fs.File.stdout().writeAll(
            "  note: launch is currently blocked because the extension build is missing the FSKit entitlement.\n",
        );
    }
    if (status.ready()) {
        try std.fs.File.stdout().writeAll(
            "  note: current native macOS mounts still present as noowners, so chown/owner-group changes are unsupported.\n",
        );
        try std.fs.File.stdout().writeAll(
            "  note: advisory locks currently apply inside the mounted Spiderweb view only and are not mirrored back to the host path.\n",
        );
        try std.fs.File.stdout().writeAll(
            "  note: files edited directly on the underlying host path after they have already been seen through the mount may remain stale until reopen or remount.\n",
        );
    }
}

fn writeNativeFsStatusSnapshot(allocator: std.mem.Allocator, status: native_mount_support.InstallStatus) !void {
    const snapshot_path = try native_mount_support.defaultStatusSnapshotPath(allocator);
    defer allocator.free(snapshot_path);

    if (std.fs.path.dirname(snapshot_path)) |dir| try makePathAny(dir);

    const payload = try std.json.Stringify.valueAlloc(allocator, NativeFsStatusSnapshot{
        .registered = status.extension_registered,
        .module_enabled = status.module_enabled,
        .ready = status.ready(),
        .filesystem_bundle_present = status.filesystem_bundle_installed,
        .mount_helper_present = status.mount_helper_present,
        .runtime_ready = status.runtime_ready,
        .updated_at_ms = std.time.milliTimestamp(),
    }, .{});
    defer allocator.free(payload);

    var file = try createFileAny(snapshot_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(payload);
}

fn detectServiceManager() ServiceManager {
    return switch (builtin.os.tag) {
        .linux => .systemd_user,
        .macos => .launchd_user,
        else => .unsupported,
    };
}

fn installSystemdUserService(allocator: std.mem.Allocator) !void {
    const exec_path = try resolveServiceExecutablePath(allocator);
    defer allocator.free(exec_path);
    const working_dir = try defaultServiceWorkingDirectory(allocator);
    defer allocator.free(working_dir);
    const service_path = try systemdUserServicePath(allocator);
    defer allocator.free(service_path);

    if (std.fs.path.dirname(service_path)) |dir| try makePathAny(dir);
    try makePathAny(working_dir);

    const content = try std.fmt.allocPrint(
        allocator,
        \\[Unit]
        \\Description=Spiderweb Workspace Host
        \\After=network.target
        \\
        \\[Service]
        \\Type=simple
        \\ExecStart={s}
        \\WorkingDirectory={s}
        \\Restart=on-failure
        \\RestartSec=5
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    ,
        .{ exec_path, working_dir },
    );
    defer allocator.free(content);

    var file = try createFileAny(service_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);

    try runCommandSuccess(allocator, &.{ "systemctl", "--user", "daemon-reload" });
    try runCommandSuccess(allocator, &.{ "systemctl", "--user", "enable", "--now", service_name });

    std.log.info("Installed and started systemd user service at {s}", .{service_path});
}

fn uninstallSystemdUserService(allocator: std.mem.Allocator) !void {
    const service_path = try systemdUserServicePath(allocator);
    defer allocator.free(service_path);

    if (try runCommandBestEffort(allocator, &.{ "systemctl", "--user", "disable", "--now", service_name })) |result| {
        var owned_result = result;
        owned_result.deinit(allocator);
    }
    _ = try deleteFileIfExistsAny(service_path);
    if (try runCommandBestEffort(allocator, &.{ "systemctl", "--user", "daemon-reload" })) |result| {
        var owned_result = result;
        owned_result.deinit(allocator);
    }

    std.log.info("Removed systemd user service definition at {s}", .{service_path});
}

fn printSystemdUserServiceStatus(allocator: std.mem.Allocator, json_output: bool) !void {
    const service_path = try systemdUserServicePath(allocator);
    defer allocator.free(service_path);
    const installed = pathExists(service_path);

    if (!installed) {
        if (json_output) {
            const payload = try std.json.Stringify.valueAlloc(allocator, ServiceStatusJson{
                .manager = "systemd",
                .unit_path = service_path,
                .installed = false,
                .loaded = false,
                .enabled = null,
                .active = null,
            }, .{});
            defer allocator.free(payload);
            try std.fs.File.stdout().writeAll(payload);
            try std.fs.File.stdout().writeAll("\n");
            return;
        }
        const out = try std.fmt.allocPrint(
            allocator,
            "Service manager: systemd\n  unit:      {s}\n  installed: no\n",
            .{service_path},
        );
        defer allocator.free(out);
        try std.fs.File.stdout().writeAll(out);
        return;
    }

    var enabled = try runCommandBestEffort(allocator, &.{ "systemctl", "--user", "is-enabled", service_name });
    defer if (enabled) |*value| value.deinit(allocator);
    var active = try runCommandBestEffort(allocator, &.{ "systemctl", "--user", "is-active", service_name });
    defer if (active) |*value| value.deinit(allocator);

    const enabled_text = if (enabled) |value|
        commandResultSummary(value, "unknown")
    else
        "unknown";
    const active_text = if (active) |value|
        commandResultSummary(value, "unknown")
    else
        "unknown";

    if (json_output) {
        const payload = try std.json.Stringify.valueAlloc(allocator, ServiceStatusJson{
            .manager = "systemd",
            .unit_path = service_path,
            .installed = true,
            .loaded = active != null and commandExitedSuccessfully(active.?),
            .enabled = enabled_text,
            .active = active_text,
        }, .{});
        defer allocator.free(payload);
        try std.fs.File.stdout().writeAll(payload);
        try std.fs.File.stdout().writeAll("\n");
        return;
    }

    const out = try std.fmt.allocPrint(
        allocator,
        "Service manager: systemd\n  unit:      {s}\n  installed: yes\n  enabled:   {s}\n  active:    {s}\n",
        .{ service_path, enabled_text, active_text },
    );
    defer allocator.free(out);
    try std.fs.File.stdout().writeAll(out);
}

fn installLaunchdUserService(allocator: std.mem.Allocator) !void {
    const exec_path = try resolveServiceExecutablePath(allocator);
    defer allocator.free(exec_path);
    const working_dir = try defaultServiceWorkingDirectory(allocator);
    defer allocator.free(working_dir);
    const plist_path = try launchdPlistPath(allocator);
    defer allocator.free(plist_path);

    if (std.fs.path.dirname(plist_path)) |dir| try makePathAny(dir);
    try makePathAny(working_dir);

    const content = try std.fmt.allocPrint(
        allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key>
        \\  <string>{s}</string>
        \\  <key>ProgramArguments</key>
        \\  <array>
        \\    <string>{s}</string>
        \\  </array>
        \\  <key>WorkingDirectory</key>
        \\  <string>{s}</string>
        \\  <key>RunAtLoad</key>
        \\  <true/>
        \\  <key>KeepAlive</key>
        \\  <true/>
        \\</dict>
        \\</plist>
        \\
    ,
        .{ service_name, exec_path, working_dir },
    );
    defer allocator.free(content);

    var file = try createFileAny(plist_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);

    const domain_target = try launchdDomainTarget(allocator);
    defer allocator.free(domain_target);
    const service_target = try launchdServiceTarget(allocator);
    defer allocator.free(service_target);

    if (try runCommandBestEffort(allocator, &.{ "launchctl", "bootout", domain_target, plist_path })) |result| {
        var owned_result = result;
        owned_result.deinit(allocator);
    }
    try runCommandSuccess(allocator, &.{ "launchctl", "bootstrap", domain_target, plist_path });
    try runCommandSuccess(allocator, &.{ "launchctl", "kickstart", "-k", service_target });

    std.log.info("Installed and started launchd user service at {s}", .{plist_path});
}

fn uninstallLaunchdUserService(allocator: std.mem.Allocator) !void {
    const plist_path = try launchdPlistPath(allocator);
    defer allocator.free(plist_path);
    const domain_target = try launchdDomainTarget(allocator);
    defer allocator.free(domain_target);
    const service_target = try launchdServiceTarget(allocator);
    defer allocator.free(service_target);

    if (try runCommandBestEffort(allocator, &.{ "launchctl", "bootout", domain_target, plist_path })) |result| {
        var owned_result = result;
        owned_result.deinit(allocator);
    }
    if (try runCommandBestEffort(allocator, &.{ "launchctl", "bootout", service_target })) |result| {
        var owned_result = result;
        owned_result.deinit(allocator);
    }
    _ = try deleteFileIfExistsAny(plist_path);

    std.log.info("Removed launchd user service definition at {s}", .{plist_path});
}

fn printLaunchdUserServiceStatus(allocator: std.mem.Allocator, json_output: bool) !void {
    const plist_path = try launchdPlistPath(allocator);
    defer allocator.free(plist_path);
    const installed = pathExists(plist_path);
    const service_target = try launchdServiceTarget(allocator);
    defer allocator.free(service_target);

    var printed = if (installed)
        try runCommandBestEffort(allocator, &.{ "launchctl", "print", service_target })
    else
        null;
    defer if (printed) |*value| value.deinit(allocator);

    if (json_output) {
        const payload = try std.json.Stringify.valueAlloc(allocator, ServiceStatusJson{
            .manager = "launchd",
            .unit_path = plist_path,
            .installed = installed,
            .loaded = printed != null and commandExitedSuccessfully(printed.?),
            .enabled = null,
            .active = null,
        }, .{});
        defer allocator.free(payload);
        try std.fs.File.stdout().writeAll(payload);
        try std.fs.File.stdout().writeAll("\n");
        return;
    }

    const out = try std.fmt.allocPrint(
        allocator,
        "Service manager: launchd\n  plist:      {s}\n  installed:  {s}\n  loaded:     {s}\n",
        .{
            plist_path,
            if (installed) "yes" else "no",
            if (printed != null and commandExitedSuccessfully(printed.?)) "yes" else "no",
        },
    );
    defer allocator.free(out);
    try std.fs.File.stdout().writeAll(out);
}

fn resolveServiceExecutablePath(allocator: std.mem.Allocator) ![]u8 {
    const self_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_path);
    const self_dir = std.fs.path.dirname(self_path) orelse return error.InvalidExecutablePath;

    const sibling = try std.fs.path.join(allocator, &.{ self_dir, "spiderweb" });
    if (pathExists(sibling)) return sibling;
    allocator.free(sibling);

    const home = try requireHomeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".local", "bin", "spiderweb" });
}

fn defaultServiceWorkingDirectory(allocator: std.mem.Allocator) ![]u8 {
    const home = try requireHomeDir(allocator);
    defer allocator.free(home);

    return switch (builtin.os.tag) {
        .macos => std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "Spiderweb" }),
        else => std.fs.path.join(allocator, &.{ home, ".local", "share", "spiderweb" }),
    };
}

fn defaultServiceRuntimeStorageDirectory(allocator: std.mem.Allocator) ![]u8 {
    const working_dir = try defaultServiceWorkingDirectory(allocator);
    defer allocator.free(working_dir);
    return std.fs.path.join(allocator, &.{ working_dir, ".spiderweb-ltm" });
}

fn defaultLocalWorkspaceRoot(allocator: std.mem.Allocator) ![]u8 {
    const home = try requireHomeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, "Spiderweb" });
}

fn ensureDefaultLocalWorkspaceLayout(allocator: std.mem.Allocator, root: []const u8, agents_dir: []const u8) !void {
    try makePathAny(root);

    const trimmed_agents = std.mem.trim(u8, agents_dir, " \t\r\n");
    if (trimmed_agents.len == 0) return;

    const agents_path = if (std.fs.path.isAbsolute(trimmed_agents))
        try allocator.dupe(u8, trimmed_agents)
    else
        try std.fs.path.join(allocator, &.{ root, trimmed_agents });
    defer allocator.free(agents_path);
    try makePathAny(agents_path);
}

fn ensureDefaultLocalWorkspaceRootConfig(allocator: std.mem.Allocator) !void {
    var config = try Config.init(allocator, null);
    defer config.deinit();

    const current_root = std.mem.trim(u8, config.runtime.spider_web_root, " \t\r\n");
    if (current_root.len > 0) {
        try ensureDefaultLocalWorkspaceLayout(allocator, current_root, config.runtime.agents_dir);
        return;
    }

    const default_root = try defaultLocalWorkspaceRoot(allocator);
    defer allocator.free(default_root);
    try ensureDefaultLocalWorkspaceLayout(allocator, default_root, config.runtime.agents_dir);

    config.allocator.free(config.runtime.spider_web_root);
    config.runtime.spider_web_root = try allocator.dupe(u8, default_root);
    try config.save();
}

fn ensureDefaultRuntimeStorageConfig(allocator: std.mem.Allocator) !void {
    var config = try Config.init(allocator, null);
    defer config.deinit();

    const current = std.mem.trim(u8, config.runtime.ltm_directory, " \t\r\n");
    if (current.len > 0 and std.fs.path.isAbsolute(current)) {
        try makePathAny(current);
        return;
    }

    if (current.len > 0 and !std.mem.eql(u8, current, ".spiderweb-ltm")) {
        return;
    }

    const default_storage = try defaultServiceRuntimeStorageDirectory(allocator);
    defer allocator.free(default_storage);
    try makePathAny(default_storage);

    config.allocator.free(config.runtime.ltm_directory);
    config.runtime.ltm_directory = try allocator.dupe(u8, default_storage);
    try config.save();
}

fn requireHomeDir(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "HOME") catch {
        std.log.err("Could not get HOME directory", .{});
        return error.MissingHome;
    };
}

fn systemdUserServicePath(allocator: std.mem.Allocator) ![]u8 {
    const home = try requireHomeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".config", "systemd", "user", "spiderweb.service" });
}

fn launchdPlistPath(allocator: std.mem.Allocator) ![]u8 {
    const home = try requireHomeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, "Library", "LaunchAgents", "spiderweb.plist" });
}

fn launchdDomainTarget(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "gui/{d}", .{std.posix.getuid()});
}

fn launchdServiceTarget(allocator: std.mem.Allocator) ![]u8 {
    const domain_target = try launchdDomainTarget(allocator);
    defer allocator.free(domain_target);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ domain_target, service_name });
}

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

    const stderr_text = trimmedCommandText(result.stderr);
    const stdout_text = trimmedCommandText(result.stdout);
    if (stderr_text.len > 0) {
        std.log.err("command failed: {s}", .{stderr_text});
    } else if (stdout_text.len > 0) {
        std.log.err("command failed: {s}", .{stdout_text});
    } else {
        std.log.err("command failed: {s}", .{argv[0]});
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

fn commandResultSummary(result: CommandResult, fallback: []const u8) []const u8 {
    const stdout_text = trimmedCommandText(result.stdout);
    if (stdout_text.len > 0) return stdout_text;
    const stderr_text = trimmedCommandText(result.stderr);
    if (stderr_text.len > 0) return stderr_text;
    return fallback;
}

fn trimmedCommandText(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

fn resolveAuthTokensPath(
    allocator: std.mem.Allocator,
    ltm_directory: []const u8,
    spider_web_root: []const u8,
    config_path: []const u8,
) ![]u8 {
    const storage_dir = try resolveRuntimeStorageDirectory(allocator, ltm_directory, spider_web_root, config_path);
    defer allocator.free(storage_dir);
    try makePathAny(storage_dir);
    return std.fs.path.join(allocator, &.{ storage_dir, auth_tokens_filename });
}

fn resolveRuntimeStorageDirectory(
    allocator: std.mem.Allocator,
    ltm_directory: []const u8,
    spider_web_root: []const u8,
    config_path: []const u8,
) ![]u8 {
    const runtime_base = try resolveRuntimeBaseDirectory(allocator, ltm_directory, spider_web_root, config_path);
    defer allocator.free(runtime_base);
    return resolveRuntimeStorageDirectoryWithBase(allocator, ltm_directory, runtime_base);
}

fn resolveRuntimeStorageDirectoryWithBase(
    allocator: std.mem.Allocator,
    ltm_directory: []const u8,
    runtime_base: []const u8,
) ![]u8 {
    const base_dir = std.mem.trim(u8, ltm_directory, " \t\r\n");
    if (std.fs.path.isAbsolute(base_dir)) return allocator.dupe(u8, base_dir);
    if (base_dir.len == 0) return allocator.dupe(u8, runtime_base);
    return std.fs.path.join(allocator, &.{ runtime_base, base_dir });
}

fn resolveRuntimeBaseDirectory(
    allocator: std.mem.Allocator,
    ltm_directory: []const u8,
    spider_web_root: []const u8,
    config_path: []const u8,
) ![]u8 {
    _ = config_path;
    const configured_root = std.mem.trim(u8, spider_web_root, " \t\r\n");
    if (configured_root.len > 0 and !std.mem.eql(u8, configured_root, "/")) {
        if (std.fs.path.isAbsolute(configured_root)) return allocator.dupe(u8, configured_root);
        const cwd = try currentShellWorkingDirectory(allocator);
        defer allocator.free(cwd);
        return std.fs.path.join(allocator, &.{ cwd, configured_root });
    }

    if (try detectServiceWorkingDirectory(allocator)) |service_dir| {
        if (try currentDirectoryOwnsRuntimeStorage(allocator, ltm_directory)) {
            defer allocator.free(service_dir);
            return currentShellWorkingDirectory(allocator);
        }
        return service_dir;
    }

    const cwd = try currentShellWorkingDirectory(allocator);
    if (cwd.len > 0 and !std.mem.eql(u8, cwd, "/")) return cwd;
    allocator.free(cwd);
    return currentShellWorkingDirectory(allocator);
}

fn currentDirectoryOwnsRuntimeStorage(allocator: std.mem.Allocator, ltm_directory: []const u8) !bool {
    const cwd = try currentShellWorkingDirectory(allocator);
    defer allocator.free(cwd);
    if (cwd.len == 0 or std.mem.eql(u8, cwd, "/")) return false;

    const storage_dir = try resolveRuntimeStorageDirectoryWithBase(allocator, ltm_directory, cwd);
    defer allocator.free(storage_dir);

    const auth_tokens_path = try std.fs.path.join(allocator, &.{ storage_dir, auth_tokens_filename });
    defer allocator.free(auth_tokens_path);
    return pathExists(auth_tokens_path);
}

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn currentShellWorkingDirectory(allocator: std.mem.Allocator) ![]u8 {
    const env_pwd = std.process.getEnvVarOwned(allocator, "PWD") catch null;
    if (env_pwd) |pwd| {
        if (pwd.len > 0 and std.fs.path.isAbsolute(pwd)) return pwd;
        allocator.free(pwd);
    }
    return std.process.getCwdAlloc(allocator);
}

fn detectServiceWorkingDirectory(allocator: std.mem.Allocator) !?[]u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
    if (home) |home_dir| {
        defer allocator.free(home_dir);
        const launchd_path = try std.fs.path.join(allocator, &.{ home_dir, "Library", "LaunchAgents", "spiderweb.plist" });
        defer allocator.free(launchd_path);
        if (try parseServiceWorkingDirectory(allocator, launchd_path)) |dir| return dir;
        const user_service_path = try std.fs.path.join(allocator, &.{ home_dir, ".config", "systemd", "user", "spiderweb.service" });
        defer allocator.free(user_service_path);
        if (try parseServiceWorkingDirectory(allocator, user_service_path)) |dir| return dir;
    }

    if (try parseServiceWorkingDirectory(allocator, "/etc/systemd/system/spiderweb.service")) |dir| return dir;
    return null;
}

fn parseServiceWorkingDirectory(allocator: std.mem.Allocator, service_path: []const u8) !?[]u8 {
    const contents = readFileAllocAny(allocator, service_path, 128 * 1024) catch |err| switch (err) {
        error.FileNotFound,
        error.NotDir,
        error.AccessDenied,
        => return null,
        else => return err,
    };
    defer allocator.free(contents);

    if (std.mem.indexOf(u8, contents, "<plist") != null) {
        return extractPlistStringValue(allocator, contents, "WorkingDirectory");
    }

    return parseSystemdWorkingDirectory(allocator, contents, service_path);
}

fn parseSystemdWorkingDirectory(
    allocator: std.mem.Allocator,
    contents: []const u8,
    service_path: []const u8,
) !?[]u8 {
    var lines = std.mem.tokenizeAny(u8, contents, "\r\n");
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t");
        if (line.len == 0) continue;
        if (line[0] == '#' or line[0] == ';') continue;
        if (!std.mem.startsWith(u8, line, "WorkingDirectory=")) continue;

        const value = std.mem.trim(u8, line["WorkingDirectory=".len..], " \t\"");
        if (value.len == 0) continue;
        if (std.fs.path.isAbsolute(value)) return try allocator.dupe(u8, value);
        const service_dir = std.fs.path.dirname(service_path) orelse ".";
        return try std.fs.path.join(allocator, &.{ service_dir, value });
    }
    return null;
}

fn extractPlistStringValue(
    allocator: std.mem.Allocator,
    contents: []const u8,
    key_name: []const u8,
) !?[]u8 {
    const key_tag = try std.fmt.allocPrint(allocator, "<key>{s}</key>", .{key_name});
    defer allocator.free(key_tag);

    const key_idx = std.mem.indexOf(u8, contents, key_tag) orelse return null;
    const after_key = contents[key_idx + key_tag.len ..];
    const string_start_rel = std.mem.indexOf(u8, after_key, "<string>") orelse return null;
    const value_start = string_start_rel + "<string>".len;
    const value_end_rel = std.mem.indexOf(u8, after_key[value_start..], "</string>") orelse return null;
    const value = std.mem.trim(u8, after_key[value_start .. value_start + value_end_rel], " \t\r\n");
    if (value.len == 0) return null;
    return try allocator.dupe(u8, value);
}

fn readFileAllocAny(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
        defer file.close();
        return file.readToEndAlloc(allocator, max_bytes);
    }
    return std.fs.cwd().readFileAlloc(allocator, path, max_bytes);
}

fn makePathAny(path: []const u8) !void {
    if (path.len == 0) return;
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
    std.fs.cwd().makePath(path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
}

fn createFileAny(path: []const u8, flags: std.fs.File.CreateFlags) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.createFileAbsolute(path, flags);
    }
    return std.fs.cwd().createFile(path, flags);
}

fn isSystemApplicationsPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/Applications/");
}

fn shellQuotePosix(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var list = std.ArrayListUnmanaged(u8){};
    errdefer list.deinit(allocator);

    try list.append(allocator, '\'');
    for (value) |ch| {
        if (ch == '\'') {
            try list.appendSlice(allocator, "'\"'\"'");
        } else {
            try list.append(allocator, ch);
        }
    }
    try list.append(allocator, '\'');
    return list.toOwnedSlice(allocator);
}

fn runMacosPrivilegedShellCommand(allocator: std.mem.Allocator, shell_command: []const u8) !void {
    try runCommandSuccess(allocator, &.{
        "osascript",
        "-e",
        "on run argv",
        "-e",
        "do shell script (item 1 of argv) with administrator privileges",
        "-e",
        "end run",
        shell_command,
    });
}

fn privilegedReplaceApplicationBundle(allocator: std.mem.Allocator, source_path: []const u8, target_path: []const u8) !void {
    try privilegedReplaceTreeOwnedByRoot(allocator, source_path, target_path, null);
}

fn privilegedReplaceTreeOwnedByRoot(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    target_path: []const u8,
    setuid_binary_path: ?[]const u8,
) !void {
    const target_dir = std.fs.path.dirname(target_path) orelse return error.InvalidArguments;
    const quoted_source = try shellQuotePosix(allocator, source_path);
    defer allocator.free(quoted_source);
    const quoted_target = try shellQuotePosix(allocator, target_path);
    defer allocator.free(quoted_target);
    const quoted_target_dir = try shellQuotePosix(allocator, target_dir);
    defer allocator.free(quoted_target_dir);

    const shell_command = if (setuid_binary_path) |binary_path| blk: {
        const quoted_binary = try shellQuotePosix(allocator, binary_path);
        defer allocator.free(quoted_binary);
        break :blk try std.fmt.allocPrint(
            allocator,
            "mkdir -p {s} && rm -rf {s} && /usr/bin/ditto {s} {s} && /usr/sbin/chown -R root:wheel {s} && /usr/sbin/chown root:wheel {s} && /bin/chmod 4755 {s}",
            .{ quoted_target_dir, quoted_target, quoted_source, quoted_target, quoted_target, quoted_binary, quoted_binary },
        );
    } else try std.fmt.allocPrint(
        allocator,
        "mkdir -p {s} && rm -rf {s} && /usr/bin/ditto {s} {s} && /usr/sbin/chown -R root:wheel {s}",
        .{ quoted_target_dir, quoted_target, quoted_source, quoted_target, quoted_target },
    );
    defer allocator.free(shell_command);
    try runMacosPrivilegedShellCommand(allocator, shell_command);
}

fn installBundleTreeFromSource(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    target_path: []const u8,
    privileged: bool,
    setuid_binary_path: ?[]const u8,
) !void {
    if (!privileged) {
        if (std.fs.path.dirname(target_path)) |dir| try makePathAny(dir);
    }

    if (std.mem.endsWith(u8, source_path, ".zip")) {
        const temp_root = try std.fs.path.join(allocator, &.{ "/tmp", "spiderweb-native-install" });
        defer allocator.free(temp_root);
        _ = try deleteTreeIfExistsAny(temp_root);
        try makePathAny(temp_root);
        defer _ = deleteTreeIfExistsAny(temp_root) catch false;

        try runCommandSuccess(allocator, &.{ "ditto", "-x", "-k", source_path, temp_root });
        const unpacked_path = try std.fs.path.join(allocator, &.{ temp_root, std.fs.path.basename(target_path) });
        defer allocator.free(unpacked_path);
        if (privileged) {
            try privilegedReplaceTreeOwnedByRoot(allocator, unpacked_path, target_path, setuid_binary_path);
        } else {
            _ = try deleteTreeIfExistsAny(target_path);
            try runCommandSuccess(allocator, &.{ "ditto", unpacked_path, target_path });
        }
        return;
    }

    if (privileged) {
        try privilegedReplaceTreeOwnedByRoot(allocator, source_path, target_path, setuid_binary_path);
    } else {
        _ = try deleteTreeIfExistsAny(target_path);
        try runCommandSuccess(allocator, &.{ "ditto", source_path, target_path });
    }
}

fn privilegedDeleteTreeIfExists(allocator: std.mem.Allocator, path: []const u8) !void {
    if (!pathExists(path)) return;
    const quoted_path = try shellQuotePosix(allocator, path);
    defer allocator.free(quoted_path);
    const shell_command = try std.fmt.allocPrint(allocator, "rm -rf {s}", .{quoted_path});
    defer allocator.free(shell_command);
    try runMacosPrivilegedShellCommand(allocator, shell_command);
}

fn deleteFileIfExistsAny(path: []const u8) !bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn deleteTreeIfExistsAny(path: []const u8) !bool {
    if (!pathExists(path)) return false;

    if (std.fs.path.isAbsolute(path)) {
        var root_dir = try std.fs.openDirAbsolute("/", .{});
        defer root_dir.close();
        const rel_path = std.mem.trimLeft(u8, path, "/");
        if (rel_path.len == 0) return false;
        try root_dir.deleteTree(rel_path);
        return true;
    }

    try std.fs.cwd().deleteTree(path);
    return true;
}

fn makeOpaqueToken(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    var random_bytes: [24]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    var encoded_buf: [std.base64.url_safe_no_pad.Encoder.calcSize(random_bytes.len)]u8 = undefined;
    const encoded = std.base64.url_safe_no_pad.Encoder.encode(&encoded_buf, &random_bytes);
    return std.fmt.allocPrint(allocator, "{s}_{s}", .{ prefix, encoded });
}

fn maskTokenForDisplay(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    if (token.len == 0) return allocator.dupe(u8, "(empty)");
    if (token.len <= 8) return allocator.dupe(u8, "****");
    return std.fmt.allocPrint(
        allocator,
        "{s}...{s}",
        .{ token[0..4], token[token.len - 4 ..] },
    );
}

fn loadAuthStatusSnapshot(allocator: std.mem.Allocator, path: []const u8) !AuthStatusSnapshot {
    const raw = try readFileAllocAny(allocator, path, 64 * 1024);
    defer allocator.free(raw);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;

    const admin_val = parsed.value.object.get("admin_token") orelse return error.InvalidResponse;
    if (admin_val != .string or admin_val.string.len == 0) return error.InvalidResponse;
    const user_val = parsed.value.object.get("user_token") orelse return error.InvalidResponse;
    if (user_val != .string or user_val.string.len == 0) return error.InvalidResponse;

    return .{
        .admin_token = try allocator.dupe(u8, admin_val.string),
        .user_token = try allocator.dupe(u8, user_val.string),
    };
}

fn persistAuthTokens(
    allocator: std.mem.Allocator,
    path: []const u8,
    admin_token: []const u8,
    user_token: []const u8,
) !void {
    const Persisted = struct {
        schema: u32 = 1,
        admin_token: []const u8,
        user_token: []const u8,
        updated_at_ms: i64,
    };

    const payload = Persisted{
        .schema = 1,
        .admin_token = admin_token,
        .user_token = user_token,
        .updated_at_ms = std.time.milliTimestamp(),
    };
    const bytes = try std.json.Stringify.valueAlloc(allocator, payload, .{
        .emit_null_optional_fields = false,
        .whitespace = .indent_2,
    });
    defer allocator.free(bytes);

    var file = try createFileAny(path, .{
        .truncate = true,
        .mode = 0o600,
    });
    defer file.close();
    if (builtin.os.tag != .windows) {
        try file.chmod(0o600);
    }
    try file.writeAll(bytes);
}

fn printAuthUsage() !void {
    const usage =
        \\Auth token recovery commands:
        \\  spiderweb-config auth path
        \\  spiderweb-config auth status [--reveal]
        \\  spiderweb-config auth reset --yes
        \\
        \\`auth reset --yes` regenerates BOTH admin and user tokens in auth_tokens.json.
        \\Use only for emergency recovery (for example lost admin token).
        \\
    ;
    try std.fs.File.stdout().writeAll(usage);
}

fn printUsage() !void {
    const usage =
        \\Spiderweb Configuration Tool
        \\
        \\Usage:
        \\  spiderweb-config auth path
        \\  spiderweb-config auth status [--reveal]
        \\  spiderweb-config auth reset --yes
        \\  spiderweb-config first-run [--non-interactive]
        \\  spiderweb-config config              Show current config
        \\  spiderweb-config config path         Show config file path
        \\  spiderweb-config config set-server --bind <addr> --port <port>
        \\  spiderweb-config config set-log <debug|info|warn|error>
        \\  spiderweb-config config install-service
        \\  spiderweb-config config uninstall-service
        \\  spiderweb-config config service-status
        \\  spiderweb-config config install-fs-extension
        \\  spiderweb-config config uninstall-fs-extension
        \\  spiderweb-config config fs-extension-status
        \\
        \\Examples:
        \\  spiderweb-config first-run
        \\  spiderweb-config first-run --non-interactive
        \\  spiderweb-config auth path
        \\  spiderweb-config auth status --reveal
        \\  spiderweb-config auth reset --yes
        \\  spiderweb-config config set-server --bind 0.0.0.0 --port 9000
        \\  spiderweb-config config install-service
        \\  spiderweb-config config service-status
        \\  spiderweb-config config install-fs-extension
        \\  spiderweb-config config fs-extension-status
        \\
        \\Workspace-first flow:
        \\  spiderweb-control workspace_create '{"name":"Demo","vision":"Deliver the demo workspace"}'
        \\  spiderweb-fs-mount --workspace-id <workspace-id> ./workspace
        \\  note: on macOS, auto prefers the native FSKit backend when Spiderweb is installed and enabled; otherwise it falls back to macFUSE
        \\  spider-monkey run --workspace-root ./workspace
        \\
    ;
    const stdout_file = std.fs.File.stdout();
    try stdout_file.writeAll(usage);
}

test "config_cli: resolve runtime storage directory keeps absolute ltm path" {
    const allocator = std.testing.allocator;
    const resolved = try resolveRuntimeStorageDirectoryWithBase(allocator, "/var/lib/spiderweb/ltm", "/ignored/base");
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings("/var/lib/spiderweb/ltm", resolved);
}

test "config_cli: resolve runtime storage directory joins relative ltm path with runtime base" {
    const allocator = std.testing.allocator;
    const resolved = try resolveRuntimeStorageDirectoryWithBase(allocator, ".spiderweb-ltm", "/srv/spiderweb");
    defer allocator.free(resolved);
    const expected = try std.fs.path.join(allocator, &.{ "/srv/spiderweb", ".spiderweb-ltm" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, resolved);
}

test "config_cli: parse service working directory from unit file" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{
        .sub_path = "spiderweb.service",
        .data =
        \\[Unit]
        \\Description=Spiderweb
        \\
        \\[Service]
        \\WorkingDirectory=/opt/ziggy-spiderweb
        \\ExecStart=/usr/bin/spiderweb
        \\
        ,
    });

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const service_path = try std.fs.path.join(allocator, &.{ root, "spiderweb.service" });
    defer allocator.free(service_path);

    const parsed = (try parseServiceWorkingDirectory(allocator, service_path)) orelse return error.TestExpectedWorkingDirectory;
    defer allocator.free(parsed);
    try std.testing.expectEqualStrings("/opt/ziggy-spiderweb", parsed);
}

test "config_cli: parse working directory from launchd plist" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{
        .sub_path = "spiderweb.plist",
        .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key>
        \\  <string>spiderweb</string>
        \\  <key>WorkingDirectory</key>
        \\  <string>/Users/example/Spiderweb</string>
        \\</dict>
        \\</plist>
        ,
    });

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const plist_path = try std.fs.path.join(allocator, &.{ root, "spiderweb.plist" });
    defer allocator.free(plist_path);

    const parsed = (try parseServiceWorkingDirectory(allocator, plist_path)) orelse return error.TestExpectedWorkingDirectory;
    defer allocator.free(parsed);
    try std.testing.expectEqualStrings("/Users/example/Spiderweb", parsed);
}
