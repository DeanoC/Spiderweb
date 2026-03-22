const std = @import("std");

fn lookupLocalNodeVenomsRoot(session: anytype) ?u32 {
    const nodes_root = session.lookupChild(session.root_id, "nodes") orelse return null;
    const local_node_dir = session.lookupChild(nodes_root, "local") orelse return null;
    return session.lookupChild(local_node_dir, "venoms");
}

fn resolvePreferredLocalCatalogProviderNodeId(session: anytype, venom_id: []const u8) !?[]u8 {
    const plane = session.control_plane orelse return null;
    var provider = (try plane.resolvePreferredVenomProvider(
        session.allocator,
        venom_id,
        &.{ "spiderweb-local", "local" },
    )) orelse return null;
    defer provider.deinit(session.allocator);
    return try session.allocator.dupe(u8, provider.node_id);
}

pub fn registerLocalCatalogVenomBinding(session: anytype, venom_id: []const u8, scope: []const u8) !void {
    const local_venoms_root = lookupLocalNodeVenomsRoot(session) orelse return;
    const venom_dir_id = session.lookupChild(local_venoms_root, venom_id) orelse return;
    const venom_path = try std.fmt.allocPrint(session.allocator, "/nodes/local/venoms/{s}", .{venom_id});
    defer session.allocator.free(venom_path);
    const endpoint_path = blk: {
        if (try session.firstVenomMountPath(venom_dir_id)) |value| break :blk value;
        break :blk try session.venomEndpointPath(venom_dir_id);
    };
    defer if (endpoint_path) |value| session.allocator.free(value);
    const preferred_provider_node_id = try resolvePreferredLocalCatalogProviderNodeId(session, venom_id);
    defer if (preferred_provider_node_id) |value| session.allocator.free(value);
    const provider_node_id = preferred_provider_node_id orelse "local";
    const provider_venom_path = if (preferred_provider_node_id) |value|
        try std.fmt.allocPrint(session.allocator, "/nodes/{s}/venoms/{s}", .{ value, venom_id })
    else
        try session.allocator.dupe(u8, venom_path);
    defer session.allocator.free(provider_venom_path);
    const invoke_path = try session.deriveVenomInvokePath(provider_node_id, venom_id, venom_dir_id);
    defer if (invoke_path) |value| session.allocator.free(value);

    try session.registerScopedVenomBinding(
        venom_id,
        scope,
        venom_path,
        provider_node_id,
        provider_venom_path,
        endpoint_path,
        invoke_path,
    );
}

pub fn registerExistingGlobalVenomBinding(
    session: anytype,
    global_root: u32,
    venom_id: []const u8,
    scope: []const u8,
) !void {
    const venom_dir_id = session.lookupChild(global_root, venom_id) orelse return;
    const venom_dir = session.nodes.get(venom_dir_id) orelse return;
    if (venom_dir.kind != .dir) return;

    const venom_path = try std.fmt.allocPrint(session.allocator, "/global/{s}", .{venom_id});
    defer session.allocator.free(venom_path);
    const invoke_path = if (session.venomCapsInvoke(venom_dir_id)) blk: {
        const invoke_target = try session.resolveNodeVenomInvokeTarget(venom_dir_id);
        defer session.allocator.free(invoke_target);
        break :blk try session.pathWithInvokeTarget(venom_path, invoke_target);
    } else null;
    defer if (invoke_path) |value| session.allocator.free(value);

    const local_provider_dir_id = blk: {
        const local_venoms_root = lookupLocalNodeVenomsRoot(session) orelse break :blk null;
        break :blk session.lookupChild(local_venoms_root, venom_id);
    };

    var explicit_provider = if (local_provider_dir_id == null) blk: {
        const plane = session.control_plane orelse break :blk null;
        break :blk try plane.resolveExplicitPreferredVenomProvider(session.allocator, venom_id);
    } else null;
    defer if (explicit_provider) |*value| value.deinit(session.allocator);

    const provider_node_id = if (local_provider_dir_id != null)
        if (try resolvePreferredLocalCatalogProviderNodeId(session, venom_id)) |resolved|
            resolved
        else
            try session.allocator.dupe(u8, "local")
    else if (explicit_provider) |provider|
        try session.allocator.dupe(u8, provider.node_id)
    else
        null;
    defer if (provider_node_id) |value| session.allocator.free(value);
    const provider_venom_path = if (provider_node_id) |node_id|
        try std.fmt.allocPrint(session.allocator, "/nodes/{s}/venoms/{s}", .{ node_id, venom_id })
    else
        null;
    defer if (provider_venom_path) |value| session.allocator.free(value);
    const provider_invoke_path = if (local_provider_dir_id) |provider_dir_id|
        try session.deriveVenomInvokePath(provider_node_id orelse "local", venom_id, provider_dir_id)
    else if (explicit_provider) |provider| blk: {
        const nodes_root = session.lookupChild(session.root_id, "nodes") orelse break :blk null;
        const node_dir_id = session.lookupChild(nodes_root, provider.node_id) orelse break :blk null;
        const venoms_root_id = session.lookupChild(node_dir_id, "venoms") orelse break :blk null;
        const provider_dir_id = session.lookupChild(venoms_root_id, venom_id) orelse break :blk null;
        break :blk try session.deriveVenomInvokePath(provider.node_id, venom_id, provider_dir_id);
    } else null;
    defer if (provider_invoke_path) |value| session.allocator.free(value);

    try session.registerScopedVenomBinding(
        venom_id,
        scope,
        venom_path,
        provider_node_id,
        provider_venom_path,
        if (provider_venom_path != null) provider_venom_path else venom_path,
        if (provider_invoke_path != null) provider_invoke_path else invoke_path,
    );
}
