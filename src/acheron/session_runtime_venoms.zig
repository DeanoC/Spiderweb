const std = @import("std");
const unified = @import("spider-protocol").unified;
const venom_packages = @import("../venom_packages.zig");
const venom_package = @import("../venom_package.zig");

pub fn seedBuiltinPackageMetadata(session: anytype, venom_dir_id: u32, venom_id: []const u8) !void {
    const spec = venom_packages.findBuiltinPackage(venom_id) orelse return;
    const package_json = try venom_packages.renderPackageMetadataJson(session.allocator, spec);
    defer session.allocator.free(package_json);
    _ = try session.addFile(venom_dir_id, "PACKAGE.json", package_json, false, .none);
}

pub fn cloneRuntimeVenomPackage(session: anytype, venom_id: []const u8) !?venom_package.VenomPackage {
    if (session.control_plane) |control_plane| {
        return control_plane.cloneVenomPackage(session.allocator, venom_id);
    }
    return venom_packages.cloneBuiltinPackage(session.allocator, venom_id);
}

pub fn seedPackageMetadata(session: anytype, venom_dir_id: u32, package: venom_package.VenomPackage) !void {
    if (session.lookupChild(venom_dir_id, "PACKAGE.json") != null) return;
    var package_json = std.ArrayListUnmanaged(u8){};
    defer package_json.deinit(session.allocator);
    try venom_package.appendPackageJson(session.allocator, &package_json, package);
    _ = try session.addFile(venom_dir_id, "PACKAGE.json", package_json.items, false, .none);
}

pub fn seedGenericRuntimeLoopbackVenomNamespaceAt(
    session: anytype,
    venom_dir_id: u32,
    base_path: []const u8,
    worker_id: []const u8,
    agent_id: []const u8,
    package: venom_package.VenomPackage,
) !void {
    const escaped_base_path = try unified.jsonEscape(session.allocator, base_path);
    defer session.allocator.free(escaped_base_path);
    const shape_json = try std.fmt.allocPrint(
        session.allocator,
        "{{\"kind\":\"venom\",\"venom_id\":\"{s}\",\"shape\":\"{s}/{{README.md,SCHEMA.json,CAPS.json,OPS.json,RUNTIME.json,PERMISSIONS.json,PACKAGE.json,STATUS.json,status.json,result.json,control/*}}\"}}",
        .{ package.venom_id, escaped_base_path },
    );
    defer session.allocator.free(shape_json);

    const readme = package.help_md orelse "Runtime-owned loopback venom projected for an attached external runtime.\n";
    try session.ensureRuntimeFile(venom_dir_id, "README.md", readme, false, .none);
    try session.ensureRuntimeFile(venom_dir_id, "SCHEMA.json", shape_json, false, .none);
    try session.ensureRuntimeFile(venom_dir_id, "CAPS.json", package.capabilities_json, false, .none);
    try session.ensureRuntimeFile(venom_dir_id, "OPS.json", package.ops_json, false, .none);
    try session.ensureRuntimeFile(venom_dir_id, "RUNTIME.json", package.runtime_json, false, .none);
    try session.ensureRuntimeFile(venom_dir_id, "PERMISSIONS.json", package.permissions_json, false, .none);
    try seedPackageMetadata(session, venom_dir_id, package);

    const status_json = try std.fmt.allocPrint(
        session.allocator,
        "{{\"venom_id\":\"{s}\",\"state\":\"worker_loopback\",\"has_invoke\":true,\"owner\":\"worker\",\"worker_id\":\"{s}\",\"agent_id\":\"{s}\"}}",
        .{ package.venom_id, worker_id, agent_id },
    );
    defer session.allocator.free(status_json);
    try session.ensureRuntimeFile(venom_dir_id, "STATUS.json", status_json, false, .none);
    try session.ensureRuntimeFile(venom_dir_id, "status.json", "{\"state\":\"idle\",\"tool\":null,\"updated_at_ms\":0,\"error\":null}", true, .none);
    try session.ensureRuntimeFile(venom_dir_id, "result.json", "{\"ok\":false,\"result\":null,\"error\":null}", true, .none);

    const control_dir = if (session.lookupChild(venom_dir_id, "control")) |existing|
        existing
    else
        try session.addDir(venom_dir_id, "control", false);
    try session.ensureRuntimeFile(control_dir, "README.md", "External runtime watches and writes this loopback venom namespace directly.\n", false, .none);
    try seedRuntimeControlFilesFromOpsJson(session, control_dir, package.ops_json);
}

pub fn seedRuntimeControlFilesFromOpsJson(session: anytype, control_dir: u32, ops_json: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, ops_json, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    if (parsed.value.object.get("invoke")) |invoke_value| {
        if (invoke_value == .string and invoke_value.string.len > 0) {
            try ensureRuntimeControlFileFromPath(session, control_dir, invoke_value.string);
        }
    }
    if (parsed.value.object.get("paths")) |paths_value| {
        if (paths_value != .object) return;
        var it = paths_value.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string or entry.value_ptr.string.len == 0) continue;
            try ensureRuntimeControlFileFromPath(session, control_dir, entry.value_ptr.string);
        }
    }
}

pub fn ensureRuntimeControlFileFromPath(session: anytype, control_dir: u32, raw_path: []const u8) !void {
    var relative = raw_path;
    if (std.mem.startsWith(u8, relative, "control/")) {
        relative = relative["control/".len..];
    }
    const name = std.fs.path.basename(relative);
    if (name.len == 0) return;
    try session.ensureRuntimeFile(control_dir, name, "", true, .none);
}
