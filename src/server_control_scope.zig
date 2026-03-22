const std = @import("std");
const unified = @import("spider-protocol").unified;

pub const ControlMutationScope = enum {
    none,
    node,
    project,
    operator,
};

fn isValidNodeIdentifier(node_id: []const u8) bool {
    if (node_id.len == 0) return false;
    if (!std.mem.startsWith(u8, node_id, "node-")) return false;
    var idx: usize = "node-".len;
    while (idx < node_id.len) : (idx += 1) {
        if (!std.ascii.isAlphanumeric(node_id[idx]) and node_id[idx] != '-' and node_id[idx] != '_') return false;
    }
    return true;
}

pub fn extractNodeIdFromControlPayload(allocator: std.mem.Allocator, payload_json: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const node_id = parsed.value.object.get("node_id") orelse return null;
    if (node_id != .string or !isValidNodeIdentifier(node_id.string)) return null;
    const copy = try allocator.dupe(u8, node_id.string);
    return @as(?[]u8, copy);
}

pub fn extractWorkspaceIdFromControlPayload(allocator: std.mem.Allocator, payload_json: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const workspace_id = parsed.value.object.get("workspace_id") orelse return null;
    if (workspace_id != .string or workspace_id.string.len == 0) return null;
    const copy = try allocator.dupe(u8, workspace_id.string);
    return @as(?[]u8, copy);
}

pub fn extractWorkspaceTokenFromControlPayload(allocator: std.mem.Allocator, payload_json: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const workspace_token = parsed.value.object.get("workspace_token") orelse return null;
    if (workspace_token != .string or workspace_token.string.len == 0) return null;
    const copy = try allocator.dupe(u8, workspace_token.string);
    return @as(?[]u8, copy);
}

pub fn controlMutationScope(control_type: unified.ControlType) ControlMutationScope {
    return switch (control_type) {
        .node_invite_create,
        .node_ensure,
        .node_delete,
        .venom_bind,
        => .node,
        .node_join_pending_list,
        .node_join_approve,
        .node_join_deny,
        => .operator,
        .workspace_create,
        .workspace_update,
        .workspace_delete,
        .workspace_bind_set,
        .workspace_bind_remove,
        .workspace_mount_set,
        .workspace_mount_remove,
        .workspace_token_rotate,
        .workspace_token_revoke,
        .workspace_activate,
        .workspace_up,
        => .project,
        else => .none,
    };
}

pub fn validateControlScopeTokens(
    allocator: std.mem.Allocator,
    runtime_registry: anytype,
    control_type: unified.ControlType,
    payload_json: ?[]const u8,
) !void {
    const scope = controlMutationScope(control_type);
    if (scope == .none) return;

    const raw = payload_json orelse return error.MissingField;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    const obj = parsed.value.object;

    if (runtime_registry.control_operator_token) |operator_token| {
        if (obj.get("operator_token")) |token_value| {
            if (token_value != .string or token_value.string.len == 0) return error.InvalidPayload;
            if (!secureTokenEql(operator_token, token_value.string)) return error.OperatorAuthFailed;
            return;
        }
    }

    switch (scope) {
        .project => {
            if (runtime_registry.control_project_scope_token) |token| {
                const field = obj.get("project_scope_token") orelse return error.MissingField;
                if (field != .string or field.string.len == 0) return error.InvalidPayload;
                if (!secureTokenEql(token, field.string)) return error.OperatorAuthFailed;
                return;
            }
        },
        .node => {
            if (runtime_registry.control_node_scope_token) |token| {
                const field = obj.get("node_scope_token") orelse return error.MissingField;
                if (field != .string or field.string.len == 0) return error.InvalidPayload;
                if (!secureTokenEql(token, field.string)) return error.OperatorAuthFailed;
                return;
            }
        },
        .operator, .none => {},
    }

    if (runtime_registry.control_operator_token != null) {
        return error.MissingField;
    }
}

pub fn secureTokenEql(expected: []const u8, candidate: []const u8) bool {
    if (expected.len != candidate.len) return false;
    var diff: u8 = 0;
    for (expected, candidate) |lhs, rhs| {
        diff |= lhs ^ rhs;
    }
    return diff == 0;
}

pub fn controlScopeName(scope: ControlMutationScope) []const u8 {
    return switch (scope) {
        .none => "none",
        .node => "node",
        .project => "project",
        .operator => "operator",
    };
}
