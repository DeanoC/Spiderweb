const std = @import("std");
const unified = @import("spider-protocol").unified;

pub fn buildSessionAttachStateJson(
    allocator: std.mem.Allocator,
    state_name: []const u8,
    state: anytype,
) ![]u8 {
    const escaped_state = try unified.jsonEscape(allocator, state_name);
    defer allocator.free(escaped_state);
    const error_code_json = if (state.error_code) |value| blk: {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(error_code_json);
    const error_message_json = if (state.error_message) |value| blk: {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(error_message_json);

    return std.fmt.allocPrint(
        allocator,
        "{{\"state\":\"{s}\",\"runtime_ready\":{},\"mount_ready\":{},\"error_code\":{s},\"error_message\":{s},\"updated_at_ms\":{d}}}",
        .{
            escaped_state,
            state.runtime_ready,
            state.mount_ready,
            error_code_json,
            error_message_json,
            state.updated_at_ms,
        },
    );
}

pub fn buildSessionAttachAckPayload(
    allocator: std.mem.Allocator,
    session_key: []const u8,
    agent_id: []const u8,
    project_id: ?[]const u8,
    workspace_json: []const u8,
    attach_json: []const u8,
) ![]u8 {
    const escaped_session = try unified.jsonEscape(allocator, session_key);
    defer allocator.free(escaped_session);
    const escaped_agent = try unified.jsonEscape(allocator, agent_id);
    defer allocator.free(escaped_agent);
    const project_json = if (project_id) |value| blk: {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(project_json);

    return std.fmt.allocPrint(
        allocator,
        "{{\"session_key\":\"{s}\",\"agent_id\":\"{s}\",\"project_id\":{s},\"workspace\":{s},\"attach\":{s}}}",
        .{ escaped_session, escaped_agent, project_json, workspace_json, attach_json },
    );
}

pub fn buildSessionStatusPayload(
    allocator: std.mem.Allocator,
    session_key: []const u8,
    agent_id: []const u8,
    project_id: ?[]const u8,
    attach_json: []const u8,
    session_last_active_ms: i64,
    session_stale: bool,
    agent_last_heartbeat_ms: i64,
    agent_stale: bool,
) ![]u8 {
    const escaped_session = try unified.jsonEscape(allocator, session_key);
    defer allocator.free(escaped_session);
    const escaped_agent = try unified.jsonEscape(allocator, agent_id);
    defer allocator.free(escaped_agent);
    const project_json = if (project_id) |value| blk: {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(project_json);

    return std.fmt.allocPrint(
        allocator,
        "{{\"session_key\":\"{s}\",\"agent_id\":\"{s}\",\"project_id\":{s},\"attach\":{s},\"session_last_activity_ms\":{d},\"session_stale\":{},\"agent_last_heartbeat_ms\":{d},\"agent_stale\":{},\"recoverable\":true}}",
        .{
            escaped_session,
            escaped_agent,
            project_json,
            attach_json,
            session_last_active_ms,
            session_stale,
            agent_last_heartbeat_ms,
            agent_stale,
        },
    );
}

pub fn buildSessionListPayload(
    allocator: std.mem.Allocator,
    map: anytype,
    active_session_key: []const u8,
) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);

    const escaped_active = try unified.jsonEscape(allocator, active_session_key);
    defer allocator.free(escaped_active);
    try out.writer(allocator).print("{{\"active_session\":\"{s}\",\"sessions\":[", .{escaped_active});

    var first = true;
    var it = map.iterator();
    while (it.next()) |entry| {
        if (!first) try out.append(allocator, ',');
        first = false;
        const escaped_key = try unified.jsonEscape(allocator, entry.key_ptr.*);
        defer allocator.free(escaped_key);
        const escaped_agent = try unified.jsonEscape(allocator, entry.value_ptr.agent_id);
        defer allocator.free(escaped_agent);
        const project_json = if (entry.value_ptr.project_id) |project_id| blk: {
            const escaped_project = try unified.jsonEscape(allocator, project_id);
            defer allocator.free(escaped_project);
            break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped_project});
        } else try allocator.dupe(u8, "null");
        defer allocator.free(project_json);
        try out.writer(allocator).print(
            "{{\"session_key\":\"{s}\",\"agent_id\":\"{s}\",\"project_id\":{s}}}",
            .{ escaped_key, escaped_agent, project_json },
        );
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

pub fn buildSessionRestorePayload(
    allocator: std.mem.Allocator,
    maybe_entry: anytype,
) ![]u8 {
    if (maybe_entry == null) return allocator.dupe(u8, "{\"found\":false}");
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"found\":true,\"session\":");
    try appendSessionHistoryEntryJson(allocator, &out, maybe_entry.?);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub fn buildSessionHistoryPayload(
    allocator: std.mem.Allocator,
    history: anytype,
) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"sessions\":[");
    for (history, 0..) |entry, idx| {
        if (idx != 0) try out.append(allocator, ',');
        try appendSessionHistoryEntryJson(allocator, &out, entry);
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn appendSessionHistoryEntryJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    entry: anytype,
) !void {
    const escaped_session = try unified.jsonEscape(allocator, entry.session_key);
    defer allocator.free(escaped_session);
    const escaped_agent = try unified.jsonEscape(allocator, entry.agent_id);
    defer allocator.free(escaped_agent);
    const escaped_project = try unified.jsonEscape(allocator, entry.project_id);
    defer allocator.free(escaped_project);
    const summary_json = if (entry.summary) |value| blk: {
        const escaped_summary = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped_summary);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped_summary});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(summary_json);

    try out.writer(allocator).print(
        "{{\"session_key\":\"{s}\",\"agent_id\":\"{s}\",\"project_id\":\"{s}\",\"last_active_ms\":{d},\"message_count\":{d},\"summary\":{s}}}",
        .{
            escaped_session,
            escaped_agent,
            escaped_project,
            entry.last_active_ms,
            entry.message_count,
            summary_json,
        },
    );
}
