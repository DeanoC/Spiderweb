const std = @import("std");
const unified = @import("spider-protocol").unified;

pub fn refreshScopedVenomIndexes(session: anytype) !void {
    try refreshVenomsIndexFile(session, session.agent_venoms_index_id, "/global/", "global");

    if (session.active_agent_venoms_index_id != 0) {
        const prefix = try std.fmt.allocPrint(session.allocator, "/agents/{s}/venoms/", .{session.agent_id});
        defer session.allocator.free(prefix);
        try refreshVenomsIndexFile(session, session.active_agent_venoms_index_id, prefix, session.agent_id);
    }

    if (session.active_project_venoms_index_id != 0 and session.active_namespace_project_id != null) {
        const prefix = try std.fmt.allocPrint(session.allocator, "/projects/{s}/venoms/", .{session.active_namespace_project_id.?});
        defer session.allocator.free(prefix);
        try refreshVenomsIndexFile(session, session.active_project_venoms_index_id, prefix, session.active_namespace_project_id.?);
    }
}

pub fn refreshVenomsIndexFile(session: anytype, node_id: u32, binding_prefix: []const u8, binding_owner_id: []const u8) !void {
    const index_json = try buildScopedVenomsIndexJson(session, binding_prefix, binding_owner_id);
    defer session.allocator.free(index_json);
    try session.setFileContent(node_id, index_json);
}

pub fn buildScopedVenomsIndexJson(session: anytype, binding_prefix: []const u8, binding_owner_id: []const u8) ![]u8 {
    session.refreshDynamicDirectory(session.nodes_root_id) catch {};

    const nodes_root = session.nodes.get(session.nodes_root_id) orelse return session.allocator.dupe(u8, "[]");
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(session.allocator);
    try out.append(session.allocator, '[');

    var first = true;
    var node_it = nodes_root.children.iterator();
    while (node_it.next()) |node_entry| {
        const node_id = node_entry.key_ptr.*;
        const node_dir_id = node_entry.value_ptr.*;
        const node_dir = session.nodes.get(node_dir_id) orelse continue;
        if (node_dir.kind != .dir) continue;

        const services_root_id = session.lookupChild(node_dir_id, "venoms") orelse continue;
        const services_root = session.nodes.get(services_root_id) orelse continue;
        if (services_root.kind != .dir) continue;

        var venom_it = services_root.children.iterator();
        while (venom_it.next()) |venom_entry| {
            const venom_id = venom_entry.key_ptr.*;
            const venom_dir_id = venom_entry.value_ptr.*;
            const venom_dir = session.nodes.get(venom_dir_id) orelse continue;
            if (venom_dir.kind != .dir) continue;

            const venom_path = try std.fmt.allocPrint(
                session.allocator,
                "/nodes/{s}/venoms/{s}",
                .{ node_id, venom_id },
            );
            defer session.allocator.free(venom_path);
            const endpoint_path = blk: {
                if (try session.firstVenomMountPath(venom_dir_id)) |value| break :blk value;
                break :blk try session.venomEndpointPath(venom_dir_id);
            };
            defer if (endpoint_path) |value| session.allocator.free(value);
            const invoke_path = try session.deriveVenomInvokePath(node_id, venom_id, venom_dir_id);
            defer if (invoke_path) |value| session.allocator.free(value);

            try appendAgentVenomIndexEntry(
                session,
                &out,
                &first,
                node_id,
                venom_id,
                venom_path,
                endpoint_path,
                invoke_path,
                "node",
                null,
                null,
            );
        }
    }

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
}
