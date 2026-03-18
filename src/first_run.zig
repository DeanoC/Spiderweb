const builtin = @import("builtin");
const std = @import("std");
const Config = @import("config.zig");

fn println(comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, fmt ++ "\n", args);
    try std.fs.File.stdout().writeAll(msg);
}

pub fn runFirstRun(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var non_interactive = false;
    var saw_legacy_provider_flag = false;
    var saw_legacy_model_flag = false;
    var saw_legacy_agent_flag = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--non-interactive")) {
            non_interactive = true;
        } else if (std.mem.eql(u8, args[i], "--provider")) {
            saw_legacy_provider_flag = true;
            if (i + 1 < args.len) i += 1;
        } else if (std.mem.eql(u8, args[i], "--model")) {
            saw_legacy_model_flag = true;
            if (i + 1 < args.len) i += 1;
        } else if (std.mem.eql(u8, args[i], "--agent")) {
            saw_legacy_agent_flag = true;
            if (i + 1 < args.len) i += 1;
        } else {
            std.log.err("Unknown first-run option: {s}", .{args[i]});
            return error.InvalidArguments;
        }
    }

    try std.fs.File.stdout().writeAll("\n");
    try std.fs.File.stdout().writeAll("╔═══════════════════════════════════════════════════════════════╗\n");
    try std.fs.File.stdout().writeAll("║                                                               ║\n");
    try std.fs.File.stdout().writeAll("║   Spiderweb - Workspace Setup                                 ║\n");
    try std.fs.File.stdout().writeAll("║                                                               ║\n");
    try std.fs.File.stdout().writeAll("╚═══════════════════════════════════════════════════════════════╝\n");
    try std.fs.File.stdout().writeAll("\n");

    var config = try Config.init(allocator, null);
    defer config.deinit();

    if (saw_legacy_provider_flag or saw_legacy_model_flag or saw_legacy_agent_flag) {
        try std.fs.File.stdout().writeAll(
            "Legacy provider/agent setup flags were ignored. Spiderweb now expects external workers such as Spider Monkey to own model and credential configuration.\n\n",
        );
    }

    try std.fs.File.stdout().writeAll("Spiderweb is configured as a workspace host and mounted-filesystem control plane.\n");
    try std.fs.File.stdout().writeAll("Provider selection, OAuth, and API-key setup belong in the external worker repo.\n");
    try std.fs.File.stdout().writeAll("On a clean install, Spiderweb seeds a default local workspace root at ~/Spiderweb unless you configure runtime.spider_web_root explicitly.\n");

    if (!non_interactive) {
        try std.fs.File.stdout().writeAll("\n");
    }

    try std.fs.File.stdout().writeAll("╔═══════════════════════════════════════════════════════════════╗\n");
    try std.fs.File.stdout().writeAll("║  Setup Complete!                                              ║\n");
    try std.fs.File.stdout().writeAll("╚═══════════════════════════════════════════════════════════════╝\n");
    try println("\n  Config: {s}", .{config.config_path});
    try println("  Server: ws://{s}:{d}", .{ config.server.bind, config.server.port });
    try std.fs.File.stdout().writeAll("  Worker model: external filesystem agents\n");
    try std.fs.File.stdout().writeAll("\nHost flow:\n");
    try std.fs.File.stdout().writeAll("  1. Start Spiderweb: spiderweb\n");
    try std.fs.File.stdout().writeAll("  2. Create a mountable workspace: spiderweb-control workspace_up '{\"name\":\"Demo\",\"vision\":\"Mounted workspace\",\"template_id\":\"dev\",\"activate\":false}'\n");
    if (builtin.os.tag == .macos) {
        try std.fs.File.stdout().writeAll("  3. Open the Spiderweb macOS app and choose either:\n");
        try std.fs.File.stdout().writeAll("     - Run Spiderweb on this Mac\n");
        try std.fs.File.stdout().writeAll("     - Mount an existing Spiderweb\n");
        try std.fs.File.stdout().writeAll("  4. Enable “Spiderweb file system” in System Settings when prompted.\n");
        try std.fs.File.stdout().writeAll("  5. Mount locally with the native backend: spiderweb-fs-mount --workspace-url ws://127.0.0.1:18790/ --workspace-id <workspace-id> --mount-backend native mount <mountpoint>\n");
        try std.fs.File.stdout().writeAll("  6. Start Spider Monkey: spider-monkey run --workspace-root <mountpoint>\n");
    } else {
        try std.fs.File.stdout().writeAll("  3. Mount it locally: spiderweb-fs-mount --workspace-url ws://127.0.0.1:18790/ --workspace-id <workspace-id> mount <mountpoint>\n");
        try std.fs.File.stdout().writeAll("  4. Start Spider Monkey: spider-monkey run --workspace-root <mountpoint>\n");
    }
    try std.fs.File.stdout().writeAll("\nUseful commands:\n");
    try std.fs.File.stdout().writeAll("  spiderweb-config auth status\n");
    try std.fs.File.stdout().writeAll("  spiderweb-config config set-server --bind 0.0.0.0 --port 18790\n");
    try std.fs.File.stdout().writeAll("  spiderweb-config config service-status\n");
    try std.fs.File.stdout().writeAll("  spiderweb-control workspace_list\n");
    try std.fs.File.stdout().writeAll("\nInstall background service:\n");
    try std.fs.File.stdout().writeAll("  spiderweb-config config install-service\n");
}
