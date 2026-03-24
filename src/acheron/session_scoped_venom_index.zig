const std = @import("std");
const unified = @import("spider-protocol").unified;
const venom_model = @import("../venom_model.zig");

pub fn refreshScopedVenomIndexes(session: anytype) !void {
    try refreshVenomsIndexFile(session, session.agent_venoms_index_id, "/.spiderweb/venoms/", "workspace");

    if (session.active_agent_venoms_index_id != 0) {
        const prefix = try std.fmt.allocPrint(session.allocator, "/agents/{s}/venoms/", .{session.agent_id});
        defer session.allocator.free(prefix);
        try refreshVenomsIndexFile(session, session.active_agent_venoms_index_id, prefix, session.agent_id);
    }

    if (session.active_workspace_venoms_index_id != 0 and session.active_namespace_workspace_id != null) {
        try refreshVenomsIndexFile(session, session.active_workspace_venoms_index_id, "/.spiderweb/venoms/", session.active_namespace_workspace_id.?);
    }
}

pub fn refreshVenomsIndexFile(session: anytype, node_id: u32, binding_prefix: []const u8, binding_owner_id: []const u8) !void {
    const index_json = try buildScopedVenomsIndexJson(session, binding_prefix, binding_owner_id);
    defer session.allocator.free(index_json);
    try session.setFileContent(node_id, index_json);
}

pub fn buildScopedVenomsIndexJson(session: anytype, binding_prefix: []const u8, binding_owner_id: []const u8) ![]u8 {
    session.refreshDynamicDirectory(session.nodes_root_id) catch {};
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(session.allocator);
    try out.append(session.allocator, '[');

    var first = true;
    try appendScopedVenomBindingIndexEntriesForPrefix(session, &out, &first, binding_prefix, binding_owner_id);
    try out.append(session.allocator, ']');
    return out.toOwnedSlice(session.allocator);
}

fn appendAgentVenomIndexEntry(
    session: anytype,
    out: *std.ArrayListUnmanaged(u8),
    first: *bool,
    node_id: []const u8,
    venom_id: []const u8,
    venom_path: []const u8,
    endpoint_path: ?[]const u8,
    invoke_path: ?[]const u8,
    scope: []const u8,
    provider_node_id: ?[]const u8,
    provider_venom_path: ?[]const u8,
) !void {
    const escaped_node_id = try unified.jsonEscape(session.allocator, node_id);
    defer session.allocator.free(escaped_node_id);
    const escaped_venom_id = try unified.jsonEscape(session.allocator, venom_id);
    defer session.allocator.free(escaped_venom_id);
    const escaped_venom_path = try unified.jsonEscape(session.allocator, venom_path);
    defer session.allocator.free(escaped_venom_path);
    const escaped_scope = try unified.jsonEscape(session.allocator, scope);
    defer session.allocator.free(escaped_scope);

    const endpoint_json = if (endpoint_path) |value| blk: {
        const escaped = try unified.jsonEscape(session.allocator, value);
        defer session.allocator.free(escaped);
        break :blk try std.fmt.allocPrint(session.allocator, "\"{s}\"", .{escaped});
    } else try session.allocator.dupe(u8, "null");
    defer session.allocator.free(endpoint_json);

    const invoke_json = if (invoke_path) |value| blk: {
        const escaped = try unified.jsonEscape(session.allocator, value);
        defer session.allocator.free(escaped);
        break :blk try std.fmt.allocPrint(session.allocator, "\"{s}\"", .{escaped});
    } else try session.allocator.dupe(u8, "null");
    defer session.allocator.free(invoke_json);

    const provider_node_json = if (provider_node_id) |value| blk: {
        const escaped = try unified.jsonEscape(session.allocator, value);
        defer session.allocator.free(escaped);
        break :blk try std.fmt.allocPrint(session.allocator, "\"{s}\"", .{escaped});
    } else try session.allocator.dupe(u8, "null");
    defer session.allocator.free(provider_node_json);

    const provider_path_json = if (provider_venom_path) |value| blk: {
        const escaped = try unified.jsonEscape(session.allocator, value);
        defer session.allocator.free(escaped);
        break :blk try std.fmt.allocPrint(session.allocator, "\"{s}\"", .{escaped});
    } else try session.allocator.dupe(u8, "null");
    defer session.allocator.free(provider_path_json);

    if (!first.*) try out.append(session.allocator, ',');
    first.* = false;
    try out.writer(session.allocator).print(
        "{{\"node_id\":\"{s}\",\"venom_id\":\"{s}\",\"venom_path\":\"{s}\",\"endpoint_path\":{s},\"invoke_path\":{s},\"has_invoke\":{s},\"scope\":\"{s}\",\"provider_node_id\":{s},\"provider_venom_path\":{s}}}",
        .{
            escaped_node_id,
            escaped_venom_id,
            escaped_venom_path,
            endpoint_json,
            invoke_json,
            if (invoke_path != null) "true" else "false",
            escaped_scope,
            provider_node_json,
            provider_path_json,
        },
    );
}

fn appendScopedVenomBindingIndexEntriesForPrefix(
    session: anytype,
    out: *std.ArrayListUnmanaged(u8),
    first: *bool,
    binding_prefix: []const u8,
    binding_owner_id: []const u8,
) !void {
    for (session.scoped_venom_bindings.items) |binding| {
        if (!std.mem.startsWith(u8, binding.venom_path, binding_prefix)) continue;
        if (!venom_model.isCapabilityVenomId(binding.venom_id)) continue;
        try appendAgentVenomIndexEntry(
            session,
            out,
            first,
            binding_owner_id,
            binding.venom_id,
            binding.venom_path,
            binding.endpoint_path,
            binding.invoke_path,
            binding.scope,
            binding.provider_node_id,
            binding.provider_venom_path,
        );
    }

    for (session.workspace_binds.items) |bind| {
        if (bind.kind != .workspace) continue;
        if (!std.mem.startsWith(u8, bind.bind_path, binding_prefix)) continue;
        if (hasScopedBindingForPath(session, bind.bind_path)) continue;

        const venom_id = bind.bind_path[binding_prefix.len..];
        if (venom_id.len == 0 or std.mem.indexOfScalar(u8, venom_id, '/') != null) continue;
        if (!venom_model.isCapabilityVenomId(venom_id)) continue;

        const invoke_path = try session.pathWithInvokeSuffix(bind.target_path);
        defer session.allocator.free(invoke_path);

        const provider_node_id = if (std.mem.startsWith(u8, bind.target_path, "/nodes/")) blk: {
            const after_prefix = bind.target_path["/nodes/".len..];
            const node_end = std.mem.indexOfScalar(u8, after_prefix, '/') orelse break :blk null;
            break :blk after_prefix[0..node_end];
        } else null;

        try appendAgentVenomIndexEntry(
            session,
            out,
            first,
            binding_owner_id,
            venom_id,
            bind.bind_path,
            bind.target_path,
            invoke_path,
            "workspace_binding",
            provider_node_id,
            bind.target_path,
        );
    }
}

fn hasScopedBindingForPath(session: anytype, binding_path: []const u8) bool {
    for (session.scoped_venom_bindings.items) |binding| {
        if (std.mem.eql(u8, binding.venom_path, binding_path)) return true;
    }
    return false;
}
