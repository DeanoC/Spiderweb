const std = @import("std");
const unified = @import("spider-protocol").unified;
const venom_packages = @import("../venom_packages.zig");

pub fn buildVenomPackagesJson(session: anytype) ![]u8 {
    if (session.control_plane) |plane| {
        return plane.listVenomPackages();
    }
    return venom_packages.buildPackagesJson(session.allocator);
}

pub fn buildProjectBindsArrayJson(session: anytype) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(session.allocator);
    try out.append(session.allocator, '[');
    var first = true;
    for (session.project_binds.items) |bind| {
        if (bind.kind != .workspace) continue;
        if (!first) try out.append(session.allocator, ',');
        first = false;
        const escaped_bind = try unified.jsonEscape(session.allocator, bind.bind_path);
        defer session.allocator.free(escaped_bind);
        const escaped_target = try unified.jsonEscape(session.allocator, bind.target_path);
        defer session.allocator.free(escaped_target);
        try out.writer(session.allocator).print(
            "{{\"bind_path\":\"{s}\",\"target_path\":\"{s}\"}}",
            .{ escaped_bind, escaped_target },
        );
    }
    try out.append(session.allocator, ']');
    return out.toOwnedSlice(session.allocator);
}

pub fn buildMountedServicesJson(session: anytype) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(session.allocator);
    try out.append(session.allocator, '[');
    var first = true;

    for (session.project_binds.items) |bind| {
        if (bind.kind != .workspace) continue;
        if (!first) try out.append(session.allocator, ',');
        first = false;
        try appendMountedServiceBindJson(session, &out, bind);
    }

    for (session.scoped_venom_bindings.items) |binding| {
        if (!first) try out.append(session.allocator, ',');
        first = false;
        try appendDirectMountedServiceJson(session, &out, binding);
    }

    try out.append(session.allocator, ']');
    return out.toOwnedSlice(session.allocator);
}

fn appendMountedServiceBindJson(session: anytype, out: *std.ArrayListUnmanaged(u8), bind: anytype) !void {
    var selected_index: ?usize = null;
    for (session.scoped_venom_bindings.items, 0..) |binding, idx| {
        if (!pathMatchesPrefixBoundary(bind.target_path, binding.venom_path)) continue;
        if (selected_index == null or binding.venom_path.len > session.scoped_venom_bindings.items[selected_index.?].venom_path.len) {
            selected_index = idx;
        }
    }

    const escaped_bind = try unified.jsonEscape(session.allocator, bind.bind_path);
    defer session.allocator.free(escaped_bind);
    const escaped_target = try unified.jsonEscape(session.allocator, bind.target_path);
    defer session.allocator.free(escaped_target);

    if (selected_index) |idx| {
        const binding = session.scoped_venom_bindings.items[idx];
        const escaped_venom_id = try unified.jsonEscape(session.allocator, binding.venom_id);
        defer session.allocator.free(escaped_venom_id);
        const escaped_scope = try unified.jsonEscape(session.allocator, binding.scope);
        defer session.allocator.free(escaped_scope);
        const escaped_source = try unified.jsonEscape(session.allocator, binding.venom_path);
        defer session.allocator.free(escaped_source);
        const invoke_json = if (binding.invoke_path) |invoke_path| blk: {
            if (try session.rebaseBoundServicePath(bind.bind_path, bind.target_path, invoke_path)) |rebased| {
                defer session.allocator.free(rebased);
                const escaped = try unified.jsonEscape(session.allocator, rebased);
                defer session.allocator.free(escaped);
                break :blk try std.fmt.allocPrint(session.allocator, "\"{s}\"", .{escaped});
            }
            break :blk try session.allocator.dupe(u8, "null");
        } else try session.allocator.dupe(u8, "null");
        defer session.allocator.free(invoke_json);
        const provider_node_json = if (binding.provider_node_id) |value| blk: {
            const escaped = try unified.jsonEscape(session.allocator, value);
            defer session.allocator.free(escaped);
            break :blk try std.fmt.allocPrint(session.allocator, "\"{s}\"", .{escaped});
        } else try session.allocator.dupe(u8, "null");
        defer session.allocator.free(provider_node_json);
        const provider_path_json = if (binding.provider_venom_path) |value| blk: {
            const escaped = try unified.jsonEscape(session.allocator, value);
            defer session.allocator.free(escaped);
            break :blk try std.fmt.allocPrint(session.allocator, "\"{s}\"", .{escaped});
        } else try session.allocator.dupe(u8, "null");
        defer session.allocator.free(provider_path_json);
        const endpoint_json = if (binding.endpoint_path) |value| blk: {
            const escaped = try unified.jsonEscape(session.allocator, value);
            defer session.allocator.free(escaped);
            break :blk try std.fmt.allocPrint(session.allocator, "\"{s}\"", .{escaped});
        } else try session.allocator.dupe(u8, "null");
        defer session.allocator.free(endpoint_json);

        try out.writer(session.allocator).print(
            "{{\"kind\":\"venom\",\"exposure\":\"project_bind\",\"venom_id\":\"{s}\",\"scope\":\"{s}\",\"path\":\"{s}\",\"target_path\":\"{s}\",\"source_path\":\"{s}\",\"provider_node_id\":{s},\"provider_venom_path\":{s},\"endpoint_path\":{s},\"invoke_path\":{s}}}",
            .{
                escaped_venom_id,
                escaped_scope,
                escaped_bind,
                escaped_target,
                escaped_source,
                provider_node_json,
                provider_path_json,
                endpoint_json,
                invoke_json,
            },
        );
        return;
    }

    try out.writer(session.allocator).print(
        "{{\"kind\":\"path_bind\",\"exposure\":\"project_bind\",\"path\":\"{s}\",\"target_path\":\"{s}\"}}",
        .{ escaped_bind, escaped_target },
    );
}

fn appendDirectMountedServiceJson(session: anytype, out: *std.ArrayListUnmanaged(u8), binding: anytype) !void {
    const escaped_venom_id = try unified.jsonEscape(session.allocator, binding.venom_id);
    defer session.allocator.free(escaped_venom_id);
    const escaped_scope = try unified.jsonEscape(session.allocator, binding.scope);
    defer session.allocator.free(escaped_scope);
    const escaped_path = try unified.jsonEscape(session.allocator, binding.venom_path);
    defer session.allocator.free(escaped_path);
    const provider_node_json = if (binding.provider_node_id) |value| blk: {
        const escaped = try unified.jsonEscape(session.allocator, value);
        defer session.allocator.free(escaped);
        break :blk try std.fmt.allocPrint(session.allocator, "\"{s}\"", .{escaped});
    } else try session.allocator.dupe(u8, "null");
    defer session.allocator.free(provider_node_json);
    const provider_path_json = if (binding.provider_venom_path) |value| blk: {
        const escaped = try unified.jsonEscape(session.allocator, value);
        defer session.allocator.free(escaped);
        break :blk try std.fmt.allocPrint(session.allocator, "\"{s}\"", .{escaped});
    } else try session.allocator.dupe(u8, "null");
    defer session.allocator.free(provider_path_json);
    const endpoint_json = if (binding.endpoint_path) |value| blk: {
        const escaped = try unified.jsonEscape(session.allocator, value);
        defer session.allocator.free(escaped);
        break :blk try std.fmt.allocPrint(session.allocator, "\"{s}\"", .{escaped});
    } else try session.allocator.dupe(u8, "null");
    defer session.allocator.free(endpoint_json);
    const invoke_json = if (binding.invoke_path) |value| blk: {
        const escaped = try unified.jsonEscape(session.allocator, value);
        defer session.allocator.free(escaped);
        break :blk try std.fmt.allocPrint(session.allocator, "\"{s}\"", .{escaped});
    } else try session.allocator.dupe(u8, "null");
    defer session.allocator.free(invoke_json);

    try out.writer(session.allocator).print(
        "{{\"kind\":\"venom\",\"exposure\":\"direct\",\"venom_id\":\"{s}\",\"scope\":\"{s}\",\"path\":\"{s}\",\"provider_node_id\":{s},\"provider_venom_path\":{s},\"endpoint_path\":{s},\"invoke_path\":{s}}}",
        .{
            escaped_venom_id,
            escaped_scope,
            escaped_path,
            provider_node_json,
            provider_path_json,
            endpoint_json,
            invoke_json,
        },
    );
}

fn pathMatchesPrefixBoundary(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    if (path.len == prefix.len) return true;
    if (prefix.len == 0) return true;
    return prefix[prefix.len - 1] == '/' or path[prefix.len] == '/';
}
