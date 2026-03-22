const std = @import("std");

pub fn seedActiveScopedVenomBindings(
    session: anytype,
    active_agent_venoms_dir: u32,
    project_venoms_dir: u32,
    active_project_id: []const u8,
) !void {
    const agent_prefix = try std.fmt.allocPrint(session.allocator, "/agents/{s}/venoms", .{session.agent_id});
    defer session.allocator.free(agent_prefix);
    const project_prefix = try std.fmt.allocPrint(session.allocator, "/projects/{s}/venoms", .{active_project_id});
    defer session.allocator.free(project_prefix);

    inline for ([_][]const u8{ "events", "fs" }) |venom_id| {
        const preferred_agent_node_id = try resolvePreferredBoundVenomNodeIdForContext(
            session,
            venom_id,
            active_project_id,
            session.agent_id,
        );
        defer if (preferred_agent_node_id) |value| session.allocator.free(value);
        _ = try session.addDir(active_agent_venoms_dir, venom_id, false);
        _ = try registerBoundVenomAliasOnly(
            session,
            agent_prefix,
            venom_id,
            "agent_binding",
            preferred_agent_node_id,
            active_project_id,
            session.agent_id,
        );

        const preferred_project_node_id = try resolvePreferredBoundVenomNodeIdForContext(
            session,
            venom_id,
            active_project_id,
            null,
        );
        defer if (preferred_project_node_id) |value| session.allocator.free(value);
        _ = try session.addDir(project_venoms_dir, venom_id, false);
        _ = try registerBoundVenomAliasOnly(
            session,
            project_prefix,
            venom_id,
            "workspace_binding",
            preferred_project_node_id,
            active_project_id,
            session.agent_id,
        );
    }
}

pub fn seedBoundNodeVenomNamespace(
    session: anytype,
    global_root: u32,
    venom_id: []const u8,
    preferred_node_id: []const u8,
) !bool {
    return seedBoundNodeVenomNamespaceAt(
        session,
        global_root,
        "/global",
        venom_id,
        "global_binding",
        preferred_node_id,
    );
}

pub fn seedBoundNodeVenomNamespaceAt(
    session: anytype,
    alias_root: u32,
    alias_base_path: []const u8,
    venom_id: []const u8,
    scope: []const u8,
    preferred_node_id: ?[]const u8,
) !bool {
    const nodes_root = session.lookupChild(session.root_id, "nodes") orelse return false;

    var selected_node_id: ?[]const u8 = null;
    var selected_venom_dir_id: ?u32 = null;

    if (preferred_node_id) |selected| {
        const preferred_node_dir_id = session.lookupChild(nodes_root, selected);
        if (preferred_node_dir_id) |node_dir_id| {
            if (session.lookupChild(node_dir_id, "venoms")) |venoms_root_id| {
                if (session.lookupChild(venoms_root_id, venom_id)) |venom_dir_id| {
                    selected_node_id = selected;
                    selected_venom_dir_id = venom_dir_id;
                }
            }
        }
    }

    if (selected_venom_dir_id == null) {
        const nodes_root_node = session.nodes.get(nodes_root) orelse return false;
        var node_it = nodes_root_node.children.iterator();
        while (node_it.next()) |entry| {
            const node_name = entry.key_ptr.*;
            const node_dir_id = entry.value_ptr.*;
            const venoms_root_id = session.lookupChild(node_dir_id, "venoms") orelse continue;
            const venom_dir_id = session.lookupChild(venoms_root_id, venom_id) orelse continue;
            selected_node_id = node_name;
            selected_venom_dir_id = venom_dir_id;
            break;
        }
    }

    const provider_node_id = selected_node_id orelse return false;
    const provider_dir_id = selected_venom_dir_id orelse return false;

    const alias_dir_id = try session.addDir(alias_root, venom_id, false);
    try session.copyOptionalServiceFile(provider_dir_id, alias_dir_id, "README.md");
    try session.copyOptionalServiceFile(provider_dir_id, alias_dir_id, "SCHEMA.json");
    try session.copyOptionalServiceFile(provider_dir_id, alias_dir_id, "CAPS.json");
    try session.copyOptionalServiceFile(provider_dir_id, alias_dir_id, "MOUNTS.json");
    try session.copyOptionalServiceFile(provider_dir_id, alias_dir_id, "OPS.json");
    try session.copyOptionalServiceFile(provider_dir_id, alias_dir_id, "RUNTIME.json");
    try session.copyOptionalServiceFile(provider_dir_id, alias_dir_id, "TEMPLATE.json");
    try session.copyOptionalServiceFile(provider_dir_id, alias_dir_id, "HOST.json");
    try session.copyOptionalServiceFile(provider_dir_id, alias_dir_id, "PERMISSIONS.json");
    try session.copyOptionalServiceFile(provider_dir_id, alias_dir_id, "STATUS.json");

    const venom_path = try std.fmt.allocPrint(session.allocator, "{s}/{s}", .{ alias_base_path, venom_id });
    defer session.allocator.free(venom_path);
    const provider_venom_path = try std.fmt.allocPrint(
        session.allocator,
        "/nodes/{s}/venoms/{s}",
        .{ provider_node_id, venom_id },
    );
    defer session.allocator.free(provider_venom_path);
    const endpoint_path = blk: {
        if (try session.firstVenomMountPath(provider_dir_id)) |value| break :blk value;
        break :blk try session.venomEndpointPath(provider_dir_id);
    };
    defer if (endpoint_path) |value| session.allocator.free(value);
    const invoke_path = try session.deriveVenomInvokePath(provider_node_id, venom_id, provider_dir_id);
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
    return true;
}

pub fn resolvePreferredBoundVenomNodeId(session: anytype, venom_id: []const u8) !?[]u8 {
    return resolvePreferredBoundVenomNodeIdForContext(session, venom_id, null, null);
}

pub fn resolvePreferredBoundVenomNodeIdForContext(
    session: anytype,
    venom_id: []const u8,
    project_id: ?[]const u8,
    agent_id: ?[]const u8,
) !?[]u8 {
    const plane = session.control_plane orelse return null;
    var provider = (try plane.resolvePreferredVenomProviderForContext(
        session.allocator,
        venom_id,
        &.{ "spiderapp-default", "spiderweb-local", "local" },
        project_id,
        agent_id,
    )) orelse return null;
    defer provider.deinit(session.allocator);
    return try session.allocator.dupe(u8, provider.node_id);
}

fn isBoundVenomNodeAllowed(
    session: anytype,
    project_id: ?[]const u8,
    agent_id: ?[]const u8,
    node_id: []const u8,
) bool {
    const scoped_project_id = project_id orelse return true;
    const plane = session.control_plane orelse return false;
    return plane.projectAllowsNodeVenomEvent(
        scoped_project_id,
        if (agent_id) |value| value else session.agent_id,
        session.project_token,
        node_id,
        session.is_admin,
    );
}

pub fn registerBoundVenomAliasOnly(
    session: anytype,
    alias_base_path: []const u8,
    venom_id: []const u8,
    scope: []const u8,
    preferred_node_id: ?[]const u8,
    project_id: ?[]const u8,
    agent_id: ?[]const u8,
) !bool {
    const nodes_root = session.lookupChild(session.root_id, "nodes") orelse return false;

    var selected_node_id: ?[]const u8 = null;
    var selected_venom_dir_id: ?u32 = null;

    if (preferred_node_id) |selected| {
        const preferred_node_dir_id = session.lookupChild(nodes_root, selected);
        if (preferred_node_dir_id) |node_dir_id| {
            if (session.lookupChild(node_dir_id, "venoms")) |venoms_root_id| {
                if (session.lookupChild(venoms_root_id, venom_id)) |venom_dir_id| {
                    if (isBoundVenomNodeAllowed(session, project_id, agent_id, selected)) {
                        selected_node_id = selected;
                        selected_venom_dir_id = venom_dir_id;
                    }
                }
            }
        }
    }

    if (selected_venom_dir_id == null) {
        const nodes_root_node = session.nodes.get(nodes_root) orelse return false;
        var node_it = nodes_root_node.children.iterator();
        while (node_it.next()) |entry| {
            const node_name = entry.key_ptr.*;
            const node_dir_id = entry.value_ptr.*;
            const venoms_root_id = session.lookupChild(node_dir_id, "venoms") orelse continue;
            const venom_dir_id = session.lookupChild(venoms_root_id, venom_id) orelse continue;
            if (!isBoundVenomNodeAllowed(session, project_id, agent_id, node_name)) continue;
            selected_node_id = node_name;
            selected_venom_dir_id = venom_dir_id;
            break;
        }
    }

    const provider_node_id = selected_node_id orelse return false;
    const provider_dir_id = selected_venom_dir_id orelse return false;
    const venom_path = try std.fmt.allocPrint(session.allocator, "{s}/{s}", .{ alias_base_path, venom_id });
    defer session.allocator.free(venom_path);
    const provider_venom_path = try std.fmt.allocPrint(
        session.allocator,
        "/nodes/{s}/venoms/{s}",
        .{ provider_node_id, venom_id },
    );
    defer session.allocator.free(provider_venom_path);
    const endpoint_path = blk: {
        if (try session.firstVenomMountPath(provider_dir_id)) |value| break :blk value;
        break :blk try session.venomEndpointPath(provider_dir_id);
    };
    defer if (endpoint_path) |value| session.allocator.free(value);
    const invoke_path = try session.deriveVenomInvokePath(provider_node_id, venom_id, provider_dir_id);
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
    return true;
}
