const std = @import("std");

pub const max_actor_type_len: usize = 64;
pub const max_actor_id_len: usize = 128;

pub const SessionBinding = struct {
    agent_id: []u8,
    actor_type: []u8,
    actor_id: []u8,
    workspace_id: ?[]u8 = null,
    workspace_token: ?[]u8 = null,

    pub fn deinit(self: *SessionBinding, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_id);
        allocator.free(self.actor_type);
        allocator.free(self.actor_id);
        if (self.workspace_id) |value| allocator.free(value);
        if (self.workspace_token) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub fn deinitSessionBindings(
    allocator: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(SessionBinding),
) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        var binding = entry.value_ptr.*;
        binding.deinit(allocator);
    }
    map.deinit(allocator);
    map.* = .{};
}

pub fn cloneSessionBinding(
    allocator: std.mem.Allocator,
    binding: SessionBinding,
) !SessionBinding {
    var out = SessionBinding{
        .agent_id = try allocator.dupe(u8, binding.agent_id),
        .actor_type = try allocator.dupe(u8, binding.actor_type),
        .actor_id = try allocator.dupe(u8, binding.actor_id),
        .workspace_id = null,
        .workspace_token = null,
    };
    errdefer out.deinit(allocator);
    if (binding.workspace_id) |value| out.workspace_id = try allocator.dupe(u8, value);
    if (binding.workspace_token) |value| out.workspace_token = try allocator.dupe(u8, value);
    return out;
}

pub fn upsertSessionBinding(
    allocator: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(SessionBinding),
    session_key: []const u8,
    agent_id: []const u8,
    actor_type: []const u8,
    actor_id: []const u8,
    workspace_id: ?[]const u8,
    workspace_token: ?[]const u8,
) !void {
    if (map.getPtr(session_key)) |existing| {
        const next_agent_id = try allocator.dupe(u8, agent_id);
        errdefer allocator.free(next_agent_id);
        const next_actor_type = try allocator.dupe(u8, actor_type);
        errdefer allocator.free(next_actor_type);
        const next_actor_id = try allocator.dupe(u8, actor_id);
        errdefer allocator.free(next_actor_id);
        const next_workspace_id: ?[]u8 = if (workspace_id) |value| try allocator.dupe(u8, value) else null;
        errdefer if (next_workspace_id) |value| allocator.free(value);
        const next_workspace_token: ?[]u8 = if (workspace_token) |value| try allocator.dupe(u8, value) else null;
        errdefer if (next_workspace_token) |value| allocator.free(value);

        existing.deinit(allocator);
        existing.* = .{
            .agent_id = next_agent_id,
            .actor_type = next_actor_type,
            .actor_id = next_actor_id,
            .workspace_id = next_workspace_id,
            .workspace_token = next_workspace_token,
        };
        return;
    }

    try map.put(
        allocator,
        try allocator.dupe(u8, session_key),
        .{
            .agent_id = try allocator.dupe(u8, agent_id),
            .actor_type = try allocator.dupe(u8, actor_type),
            .actor_id = try allocator.dupe(u8, actor_id),
            .workspace_id = if (workspace_id) |value| try allocator.dupe(u8, value) else null,
            .workspace_token = if (workspace_token) |value| try allocator.dupe(u8, value) else null,
        },
    );
}

pub fn isValidSessionKey(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |char| {
        if (std.ascii.isAlphanumeric(char)) continue;
        if (char == '-' or char == '_' or char == '.' or char == ':') continue;
        return false;
    }
    return true;
}

pub fn isValidActorType(value: []const u8) bool {
    if (value.len == 0 or value.len > max_actor_type_len) return false;
    for (value) |char| {
        if (std.ascii.isAlphanumeric(char)) continue;
        if (char == '_' or char == '-') continue;
        return false;
    }
    return true;
}

pub fn isValidActorId(value: []const u8) bool {
    if (value.len == 0 or value.len > max_actor_id_len) return false;
    for (value) |char| {
        if (std.ascii.isAlphanumeric(char)) continue;
        if (char == '_' or char == '-' or char == '.') continue;
        return false;
    }
    return true;
}

pub fn defaultActorTypeForRole(role: anytype) []const u8 {
    _ = role;
    return "host_control";
}

pub fn defaultActorIdForPrincipal(principal: anytype) []const u8 {
    return principal.token_id;
}
