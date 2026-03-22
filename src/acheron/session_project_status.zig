const std = @import("std");
const unified = @import("spider-protocol").unified;
const workspace_policy = @import("../workspaces/policy.zig");

pub fn buildWorkspaceTopologyJson(session: anytype, policy: workspace_policy.WorkspacePolicy) ![]u8 {
    const escaped_workspace = try unified.jsonEscape(session.allocator, policy.workspace_id);
    defer session.allocator.free(escaped_workspace);
    const escaped_agent = try unified.jsonEscape(session.allocator, session.agent_id);
    defer session.allocator.free(escaped_agent);

    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(session.allocator);
    try out.writer(session.allocator).print(
        "{{\"workspace_id\":\"{s}\",\"agent_id\":\"{s}\",\"nodes\":[",
        .{ escaped_workspace, escaped_agent },
    );
    for (policy.nodes.items, 0..) |node, idx| {
        if (idx != 0) try out.append(session.allocator, ',');
        const escaped_node_id = try unified.jsonEscape(session.allocator, node.id);
        defer session.allocator.free(escaped_node_id);
        try out.writer(session.allocator).print(
            "{{\"id\":\"{s}\",\"resources\":{{\"fs\":{s},\"camera\":{s},\"screen\":{s},\"user\":{s}}},\"terminals\":[",
            .{
                escaped_node_id,
                if (node.resources.fs) "true" else "false",
                if (node.resources.camera) "true" else "false",
                if (node.resources.screen) "true" else "false",
                if (node.resources.user) "true" else "false",
            },
        );
        for (node.terminals.items, 0..) |terminal_id, term_idx| {
            if (term_idx != 0) try out.append(session.allocator, ',');
            const escaped_terminal = try unified.jsonEscape(session.allocator, terminal_id);
            defer session.allocator.free(escaped_terminal);
            try out.writer(session.allocator).print("\"{s}\"", .{escaped_terminal});
        }
        try out.appendSlice(session.allocator, "]}");
    }
    try out.appendSlice(session.allocator, "],\"workspace_links\":[");
    for (policy.workspace_links.items, 0..) |link, idx| {
        if (idx != 0) try out.append(session.allocator, ',');
        const target = try std.fmt.allocPrint(session.allocator, "/nodes/{s}/{s}", .{ link.node_id, link.resource });
        defer session.allocator.free(target);
        const escaped_name = try unified.jsonEscape(session.allocator, link.name);
        defer session.allocator.free(escaped_name);
        const escaped_node_id = try unified.jsonEscape(session.allocator, link.node_id);
        defer session.allocator.free(escaped_node_id);
        const escaped_resource = try unified.jsonEscape(session.allocator, link.resource);
        defer session.allocator.free(escaped_resource);
        const escaped_target = try unified.jsonEscape(session.allocator, target);
        defer session.allocator.free(escaped_target);
        try out.writer(session.allocator).print(
            "{{\"name\":\"{s}\",\"node_id\":\"{s}\",\"resource\":\"{s}\",\"target\":\"{s}\"}}",
            .{ escaped_name, escaped_node_id, escaped_resource, escaped_target },
        );
    }
    try out.appendSlice(session.allocator, "]}");
    return out.toOwnedSlice(session.allocator);
}

pub fn buildFallbackWorkspaceNodesJson(session: anytype, policy: workspace_policy.WorkspacePolicy) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(session.allocator);
    try out.appendSlice(session.allocator, "[");
    for (policy.nodes.items, 0..) |node, idx| {
        if (idx != 0) try out.append(session.allocator, ',');
        const escaped_node_id = try unified.jsonEscape(session.allocator, node.id);
        defer session.allocator.free(escaped_node_id);
        try out.writer(session.allocator).print(
            "{{\"node_id\":\"{s}\",\"state\":\"unknown\",\"mounts\":0}}",
            .{escaped_node_id},
        );
    }
    try out.appendSlice(session.allocator, "]");
    return out.toOwnedSlice(session.allocator);
}

pub fn buildWorkspaceAgentsJson(session: anytype, policy: workspace_policy.WorkspacePolicy) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(session.allocator);
    try out.appendSlice(session.allocator, "[");
    const escaped_self_name = try unified.jsonEscape(session.allocator, session.agent_id);
    defer session.allocator.free(escaped_self_name);
    const self_target = try std.fmt.allocPrint(session.allocator, "/agents/{s}", .{session.agent_id});
    defer session.allocator.free(self_target);
    const escaped_self_target = try unified.jsonEscape(session.allocator, self_target);
    defer session.allocator.free(escaped_self_target);
    try out.writer(session.allocator).print(
        "{{\"name\":\"{s}\",\"target\":\"{s}\",\"kind\":\"active\"}}",
        .{ escaped_self_name, escaped_self_target },
    );
    for (policy.visible_agents.items) |agent_name| {
        if (std.mem.eql(u8, agent_name, "self")) continue;
        if (std.mem.eql(u8, agent_name, session.agent_id)) continue;
        const escaped_agent_name = try unified.jsonEscape(session.allocator, agent_name);
        defer session.allocator.free(escaped_agent_name);
        const target = try std.fmt.allocPrint(session.allocator, "/agents/{s}", .{agent_name});
        defer session.allocator.free(target);
        const escaped_target = try unified.jsonEscape(session.allocator, target);
        defer session.allocator.free(escaped_target);
        try out.writer(session.allocator).print(
            ",{{\"name\":\"{s}\",\"target\":\"{s}\",\"kind\":\"visible\"}}",
            .{ escaped_agent_name, escaped_target },
        );
    }
    try out.appendSlice(session.allocator, "]");
    return out.toOwnedSlice(session.allocator);
}

pub fn buildWorkspaceSourcesJson(
    session: anytype,
    workspace_id: []const u8,
    has_workspace_status: bool,
    fs_from_workspace: bool,
    workspace_nodes_from_workspace: bool,
    nodes_meta_from_workspace: bool,
) ![]u8 {
    const escaped_workspace_id = try unified.jsonEscape(session.allocator, workspace_id);
    defer session.allocator.free(escaped_workspace_id);
    return std.fmt.allocPrint(
        session.allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_status\":\"{s}\",\"workspace_fs\":\"{s}\",\"workspace_nodes\":\"{s}\",\"nodes_meta\":\"{s}\",\"workspace_binds\":\"control_plane\",\"mounted_services\":\"namespace_projection\"}}",
        .{
            escaped_workspace_id,
            if (has_workspace_status) "control_plane" else "policy",
            if (fs_from_workspace) "workspace_mounts" else "policy_links",
            if (workspace_nodes_from_workspace) "workspace_mounts" else "policy_nodes",
            if (nodes_meta_from_workspace) "workspace_mounts" else "policy_nodes",
        },
    );
}

pub fn buildWorkspaceSummaryJson(
    session: anytype,
    policy: workspace_policy.WorkspacePolicy,
    workspace_status_json: ?[]const u8,
    loaded_live_mounts: bool,
    loaded_live_nodes: bool,
    nodes_meta_from_workspace: bool,
) ![]u8 {
    const escaped_workspace_id = try unified.jsonEscape(session.allocator, policy.workspace_id);
    defer session.allocator.free(escaped_workspace_id);

    var policy_agent_links: usize = 1;
    for (policy.visible_agents.items) |agent_name| {
        if (std.mem.eql(u8, agent_name, "self")) continue;
        if (std.mem.eql(u8, agent_name, session.agent_id)) continue;
        policy_agent_links += 1;
    }

    var workspace_mount_links: usize = 0;
    var workspace_node_links: usize = 0;
    var reconcile_state: []const u8 = "unknown";
    var reconcile_state_owned: ?[]u8 = null;
    defer if (reconcile_state_owned) |owned| session.allocator.free(owned);
    var queue_depth: i64 = 0;
    var health_state: []const u8 = "unknown";

    if (workspace_status_json) |status_json| {
        var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, status_json, .{}) catch null;
        if (parsed) |*status_parsed| {
            defer status_parsed.deinit();
            if (status_parsed.value == .object) {
                if (status_parsed.value.object.get("reconcile_state")) |value| {
                    if (value == .string and value.string.len > 0) {
                        reconcile_state_owned = try session.allocator.dupe(u8, value.string);
                        reconcile_state = reconcile_state_owned.?;
                    }
                }
                if (status_parsed.value.object.get("queue_depth")) |value| {
                    if (value == .integer and value.integer >= 0) queue_depth = value.integer;
                }

                var missing: i64 = 0;
                var degraded: i64 = 0;
                var drift_count: i64 = 0;
                if (status_parsed.value.object.get("availability")) |availability_value| {
                    if (availability_value == .object) {
                        if (availability_value.object.get("missing")) |value| {
                            if (value == .integer and value.integer >= 0) missing = value.integer;
                        }
                        if (availability_value.object.get("degraded")) |value| {
                            if (value == .integer and value.integer >= 0) degraded = value.integer;
                        }
                    }
                }
                if (status_parsed.value.object.get("drift")) |drift_value| {
                    if (drift_value == .object) {
                        if (drift_value.object.get("count")) |value| {
                            if (value == .integer and value.integer >= 0) drift_count = value.integer;
                        }
                    }
                }

                if (status_parsed.value.object.get("mounts")) |mounts_value| {
                    if (mounts_value == .array) {
                        workspace_mount_links = mounts_value.array.items.len;
                        var nodes_seen = std.StringHashMapUnmanaged(void){};
                        defer nodes_seen.deinit(session.allocator);
                        for (mounts_value.array.items) |mount_value| {
                            if (mount_value != .object) continue;
                            const node_id_value = mount_value.object.get("node_id") orelse continue;
                            if (node_id_value != .string or node_id_value.string.len == 0) continue;
                            if (!nodes_seen.contains(node_id_value.string)) {
                                try nodes_seen.put(session.allocator, node_id_value.string, {});
                            }
                        }
                        workspace_node_links = nodes_seen.count();
                    }
                }

                health_state = if (missing > 0)
                    "missing"
                else if (degraded > 0 or drift_count > 0 or queue_depth > 0 or std.mem.eql(u8, reconcile_state, "degraded"))
                    "degraded"
                else if (std.mem.eql(u8, reconcile_state, "unknown"))
                    "unknown"
                else
                    "healthy";
            }
        }
    }

    const source_workspace_status = if (workspace_status_json != null) "control_plane" else "policy";
    const source_workspace_fs = if (loaded_live_mounts) "workspace_mounts" else "policy_links";
    const source_workspace_nodes = if (loaded_live_nodes) "workspace_mounts" else "policy_nodes";
    const source_nodes_meta = if (nodes_meta_from_workspace) "workspace_mounts" else "policy_nodes";
    const effective_workspace_mount_links = if (loaded_live_mounts and workspace_mount_links > 0) workspace_mount_links else policy.workspace_links.items.len;
    const effective_workspace_node_links = if (loaded_live_nodes and workspace_node_links > 0) workspace_node_links else policy.nodes.items.len;

    const escaped_health_state = try unified.jsonEscape(session.allocator, health_state);
    defer session.allocator.free(escaped_health_state);
    const escaped_reconcile_state = try unified.jsonEscape(session.allocator, reconcile_state);
    defer session.allocator.free(escaped_reconcile_state);

    return std.fmt.allocPrint(
        session.allocator,
        "{{\"workspace_id\":\"{s}\",\"sources\":{{\"workspace_status\":\"{s}\",\"workspace_fs\":\"{s}\",\"workspace_nodes\":\"{s}\",\"nodes_meta\":\"{s}\"}},\"counts\":{{\"policy_nodes\":{d},\"policy_links\":{d},\"visible_agents\":{d},\"workspace_agent_links\":{d},\"workspace_node_links\":{d},\"workspace_mount_links\":{d}}},\"health\":{{\"state\":\"{s}\",\"reconcile_state\":\"{s}\",\"queue_depth\":{d}}}}}",
        .{
            escaped_workspace_id,
            source_workspace_status,
            source_workspace_fs,
            source_workspace_nodes,
            source_nodes_meta,
            policy.nodes.items.len,
            policy.workspace_links.items.len,
            policy.visible_agents.items.len,
            policy_agent_links,
            effective_workspace_node_links,
            effective_workspace_mount_links,
            escaped_health_state,
            escaped_reconcile_state,
            queue_depth,
        },
    );
}

pub fn extractWorkspaceAlerts(session: anytype, workspace_status_json: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, workspace_status_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    var missing: i64 = 0;
    var degraded: i64 = 0;
    var drift_count: i64 = 0;
    var queue_depth: i64 = 0;
    var reconcile_state: []const u8 = "unknown";

    if (parsed.value.object.get("availability")) |availability_value| {
        if (availability_value == .object) {
            if (availability_value.object.get("missing")) |value| {
                if (value == .integer and value.integer >= 0) missing = value.integer;
            }
            if (availability_value.object.get("degraded")) |value| {
                if (value == .integer and value.integer >= 0) degraded = value.integer;
            }
        }
    }
    if (parsed.value.object.get("drift")) |drift_value| {
        if (drift_value == .object) {
            if (drift_value.object.get("count")) |value| {
                if (value == .integer and value.integer >= 0) drift_count = value.integer;
            }
        }
    }
    if (parsed.value.object.get("queue_depth")) |value| {
        if (value == .integer and value.integer >= 0) queue_depth = value.integer;
    }
    if (parsed.value.object.get("reconcile_state")) |value| {
        if (value == .string and value.string.len > 0) reconcile_state = value.string;
    }

    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(session.allocator);
    try out.appendSlice(session.allocator, "[");
    var first = true;

    if (missing > 0) {
        if (!first) try out.append(session.allocator, ',');
        first = false;
        try out.writer(session.allocator).print(
            "{{\"id\":\"missing_mounts\",\"severity\":\"error\",\"count\":{d},\"message\":\"missing mounts detected\"}}",
            .{missing},
        );
    }
    if (degraded > 0) {
        if (!first) try out.append(session.allocator, ',');
        first = false;
        try out.writer(session.allocator).print(
            "{{\"id\":\"degraded_mounts\",\"severity\":\"warning\",\"count\":{d},\"message\":\"degraded mounts detected\"}}",
            .{degraded},
        );
    }
    if (drift_count > 0) {
        if (!first) try out.append(session.allocator, ',');
        first = false;
        try out.writer(session.allocator).print(
            "{{\"id\":\"workspace_drift\",\"severity\":\"warning\",\"count\":{d},\"message\":\"workspace drift detected\"}}",
            .{drift_count},
        );
    }
    if (std.mem.eql(u8, reconcile_state, "degraded")) {
        if (!first) try out.append(session.allocator, ',');
        first = false;
        try out.appendSlice(session.allocator, "{\"id\":\"reconcile_degraded\",\"severity\":\"warning\",\"message\":\"reconcile state degraded\"}");
    }
    if (queue_depth > 0) {
        if (!first) try out.append(session.allocator, ',');
        first = false;
        try out.writer(session.allocator).print(
            "{{\"id\":\"reconcile_queue\",\"severity\":\"info\",\"count\":{d},\"message\":\"reconcile queue pending\"}}",
            .{queue_depth},
        );
    }

    try out.appendSlice(session.allocator, "]");
    const rendered = try out.toOwnedSlice(session.allocator);
    return rendered;
}

pub fn loadWorkspaceStatus(session: anytype, workspace_id: []const u8) !?[]u8 {
    const plane = session.control_plane orelse return null;
    const escaped_workspace_id = try unified.jsonEscape(session.allocator, workspace_id);
    defer session.allocator.free(escaped_workspace_id);
    const request_json = if (session.project_token) |token| blk: {
        const escaped_token = try unified.jsonEscape(session.allocator, token);
        defer session.allocator.free(escaped_token);
        break :blk try std.fmt.allocPrint(
            session.allocator,
            "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\"}}",
            .{ escaped_workspace_id, escaped_token },
        );
    } else try std.fmt.allocPrint(
        session.allocator,
        "{{\"workspace_id\":\"{s}\"}}",
        .{escaped_workspace_id},
    );
    defer session.allocator.free(request_json);

    if (plane.workspaceStatusWithRole(session.agent_id, request_json, session.is_admin) catch null) |status_json| {
        if (try workspaceStatusMatchesWorkspace(session, status_json, workspace_id)) {
            return status_json;
        }
        session.allocator.free(status_json);
    }

    if (plane.workspaceStatusWithRole(session.agent_id, null, session.is_admin) catch null) |status_json| {
        if (try workspaceStatusMatchesWorkspace(session, status_json, workspace_id)) {
            return status_json;
        }
        session.allocator.free(status_json);
    }

    return null;
}

fn workspaceStatusMatchesWorkspace(
    session: anytype,
    workspace_status_json: []const u8,
    expected_workspace_id: []const u8,
) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, workspace_status_json, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const workspace_id_value = parsed.value.object.get("workspace_id") orelse return false;
    if (workspace_id_value != .string) return false;
    return std.mem.eql(u8, workspace_id_value.string, expected_workspace_id);
}

pub fn extractWorkspaceAvailability(session: anytype, workspace_status_json: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, workspace_status_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const availability_value = parsed.value.object.get("availability") orelse return null;
    if (availability_value != .object) return null;
    const rendered = try std.fmt.allocPrint(session.allocator, "{f}", .{std.json.fmt(availability_value, .{})});
    return rendered;
}

pub fn extractWorkspaceNodes(session: anytype, workspace_status_json: []const u8) !?[]u8 {
    const NodeSummary = struct {
        node_id: []const u8,
        state_rank: u8,
        mounts: u32,
    };
    var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, workspace_status_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const mounts_value = parsed.value.object.get("mounts") orelse return null;
    if (mounts_value != .array) return null;

    var summaries = std.ArrayListUnmanaged(NodeSummary){};
    defer summaries.deinit(session.allocator);
    for (mounts_value.array.items) |mount_value| {
        if (mount_value != .object) continue;
        const node_id_value = mount_value.object.get("node_id") orelse continue;
        if (node_id_value != .string or node_id_value.string.len == 0) continue;
        const state = if (mount_value.object.get("state")) |value|
            if (value == .string) value.string else "unknown"
        else
            "unknown";
        const rank = mountStateRank(state);

        var merged = false;
        for (summaries.items) |*entry| {
            if (!std.mem.eql(u8, entry.node_id, node_id_value.string)) continue;
            entry.mounts +%= 1;
            if (rank > entry.state_rank) entry.state_rank = rank;
            merged = true;
            break;
        }
        if (!merged) {
            try summaries.append(session.allocator, .{
                .node_id = node_id_value.string,
                .state_rank = rank,
                .mounts = 1,
            });
        }
    }

    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(session.allocator);
    try out.appendSlice(session.allocator, "[");
    for (summaries.items, 0..) |entry, idx| {
        if (idx != 0) try out.append(session.allocator, ',');
        const escaped_node_id = try unified.jsonEscape(session.allocator, entry.node_id);
        defer session.allocator.free(escaped_node_id);
        const state = mountStateNameFromRank(entry.state_rank);
        try out.writer(session.allocator).print(
            "{{\"node_id\":\"{s}\",\"state\":\"{s}\",\"mounts\":{d}}}",
            .{ escaped_node_id, state, entry.mounts },
        );
    }
    try out.appendSlice(session.allocator, "]");
    const rendered = try out.toOwnedSlice(session.allocator);
    return rendered;
}

fn mountStateRank(state: []const u8) u8 {
    if (std.mem.eql(u8, state, "missing")) return 3;
    if (std.mem.eql(u8, state, "degraded")) return 2;
    if (std.mem.eql(u8, state, "online")) return 1;
    return 0;
}

fn mountStateNameFromRank(rank: u8) []const u8 {
    return switch (rank) {
        3 => "missing",
        2 => "degraded",
        1 => "online",
        else => "unknown",
    };
}

pub fn extractWorkspaceMounts(session: anytype, workspace_status_json: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, workspace_status_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const mounts_value = parsed.value.object.get("mounts") orelse return null;
    if (mounts_value != .array) return null;
    const rendered = try std.fmt.allocPrint(session.allocator, "{f}", .{std.json.fmt(mounts_value, .{})});
    return rendered;
}

pub fn extractWorkspaceDesiredMounts(session: anytype, workspace_status_json: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, workspace_status_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const mounts_value = parsed.value.object.get("desired_mounts") orelse return null;
    if (mounts_value != .array) return null;
    const rendered = try std.fmt.allocPrint(session.allocator, "{f}", .{std.json.fmt(mounts_value, .{})});
    return rendered;
}

pub fn extractWorkspaceActualMounts(session: anytype, workspace_status_json: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, workspace_status_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const mounts_value = parsed.value.object.get("actual_mounts") orelse return null;
    if (mounts_value != .array) return null;
    const rendered = try std.fmt.allocPrint(session.allocator, "{f}", .{std.json.fmt(mounts_value, .{})});
    return rendered;
}

pub fn extractWorkspaceDrift(session: anytype, workspace_status_json: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, workspace_status_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const drift_value = parsed.value.object.get("drift") orelse return null;
    if (drift_value != .object) return null;
    const rendered = try std.fmt.allocPrint(session.allocator, "{f}", .{std.json.fmt(drift_value, .{})});
    return rendered;
}

pub fn extractWorkspaceReconcile(session: anytype, workspace_status_json: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, workspace_status_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const reconcile_state = blk: {
        if (parsed.value.object.get("reconcile_state")) |value| {
            if (value == .string and value.string.len > 0) break :blk value.string;
        }
        break :blk "unknown";
    };
    const last_reconcile_ms: i64 = blk: {
        if (parsed.value.object.get("last_reconcile_ms")) |value| {
            if (value == .integer) break :blk value.integer;
        }
        break :blk 0;
    };
    const last_success_ms: i64 = blk: {
        if (parsed.value.object.get("last_success_ms")) |value| {
            if (value == .integer) break :blk value.integer;
        }
        break :blk 0;
    };
    const queue_depth: i64 = blk: {
        if (parsed.value.object.get("queue_depth")) |value| {
            if (value == .integer and value.integer >= 0) break :blk value.integer;
        }
        break :blk 0;
    };
    const last_error_json = if (parsed.value.object.get("last_error")) |value|
        try std.fmt.allocPrint(session.allocator, "{f}", .{std.json.fmt(value, .{})})
    else
        try session.allocator.dupe(u8, "null");
    defer session.allocator.free(last_error_json);
    const escaped_state = try unified.jsonEscape(session.allocator, reconcile_state);
    defer session.allocator.free(escaped_state);

    const rendered = try std.fmt.allocPrint(
        session.allocator,
        "{{\"reconcile_state\":\"{s}\",\"last_reconcile_ms\":{d},\"last_success_ms\":{d},\"last_error\":{s},\"queue_depth\":{d}}}",
        .{ escaped_state, last_reconcile_ms, last_success_ms, last_error_json, queue_depth },
    );
    return rendered;
}

pub fn extractWorkspaceHealth(session: anytype, workspace_status_json: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, workspace_status_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    var mounts_total: i64 = 0;
    var online: i64 = 0;
    var degraded: i64 = 0;
    var missing: i64 = 0;
    if (parsed.value.object.get("availability")) |availability_value| {
        if (availability_value == .object) {
            if (availability_value.object.get("mounts_total")) |value| {
                if (value == .integer and value.integer >= 0) mounts_total = value.integer;
            }
            if (availability_value.object.get("online")) |value| {
                if (value == .integer and value.integer >= 0) online = value.integer;
            }
            if (availability_value.object.get("degraded")) |value| {
                if (value == .integer and value.integer >= 0) degraded = value.integer;
            }
            if (availability_value.object.get("missing")) |value| {
                if (value == .integer and value.integer >= 0) missing = value.integer;
            }
        }
    }

    var drift_count: i64 = 0;
    if (parsed.value.object.get("drift")) |drift_value| {
        if (drift_value == .object) {
            if (drift_value.object.get("count")) |value| {
                if (value == .integer and value.integer >= 0) drift_count = value.integer;
            }
        }
    }

    const reconcile_state = blk: {
        if (parsed.value.object.get("reconcile_state")) |value| {
            if (value == .string and value.string.len > 0) break :blk value.string;
        }
        break :blk "unknown";
    };
    const queue_depth: i64 = blk: {
        if (parsed.value.object.get("queue_depth")) |value| {
            if (value == .integer and value.integer >= 0) break :blk value.integer;
        }
        break :blk 0;
    };
    const state = blk: {
        if (missing > 0) break :blk "missing";
        if (degraded > 0 or drift_count > 0 or queue_depth > 0 or std.mem.eql(u8, reconcile_state, "degraded")) {
            break :blk "degraded";
        }
        if (std.mem.eql(u8, reconcile_state, "unknown")) break :blk "unknown";
        break :blk "healthy";
    };

    const escaped_state = try unified.jsonEscape(session.allocator, state);
    defer session.allocator.free(escaped_state);
    const escaped_reconcile_state = try unified.jsonEscape(session.allocator, reconcile_state);
    defer session.allocator.free(escaped_reconcile_state);

    const rendered = try std.fmt.allocPrint(
        session.allocator,
        "{{\"state\":\"{s}\",\"availability\":{{\"mounts_total\":{d},\"online\":{d},\"degraded\":{d},\"missing\":{d}}},\"drift_count\":{d},\"reconcile_state\":\"{s}\",\"queue_depth\":{d}}}",
        .{ escaped_state, mounts_total, online, degraded, missing, drift_count, escaped_reconcile_state, queue_depth },
    );
    return rendered;
}

pub fn buildFallbackWorkspaceStatusJson(session: anytype, policy: workspace_policy.WorkspacePolicy) ![]u8 {
    const escaped_agent = try unified.jsonEscape(session.allocator, session.agent_id);
    defer session.allocator.free(escaped_agent);
    const escaped_workspace = try unified.jsonEscape(session.allocator, policy.workspace_id);
    defer session.allocator.free(escaped_workspace);

    return std.fmt.allocPrint(
        session.allocator,
        "{{\"agent_id\":\"{s}\",\"workspace_id\":\"{s}\",\"template_id\":null,\"source\":\"policy\",\"workspace_root\":null,\"mounts\":[],\"desired_mounts\":[],\"actual_mounts\":[],\"drift\":{{\"count\":0,\"items\":[]}},\"availability\":{{\"mounts_total\":0,\"online\":0,\"degraded\":0,\"missing\":0}},\"reconcile_state\":\"unknown\",\"last_reconcile_ms\":0,\"last_success_ms\":0,\"last_error\":null,\"queue_depth\":0}}",
        .{ escaped_agent, escaped_workspace },
    );
}
