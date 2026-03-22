const std = @import("std");
const unified = @import("spider-protocol").unified;
const server_control_payloads = @import("server_control_payloads.zig");
const server_session_bindings = @import("server_session_bindings.zig");
const server_session_payloads = @import("server_session_payloads.zig");

const session_heartbeat_ttl_ms: i64 = 5 * 60 * 1000;
const agent_heartbeat_ttl_ms: i64 = 5 * 60 * 1000;

const parseControlPayloadObject = server_control_payloads.parseControlPayloadObject;
const getOptionalStringField = server_control_payloads.getOptionalStringField;
const getOptionalBoolField = server_control_payloads.getOptionalBoolField;

pub const ControlError = struct {
    code: []const u8,
    message: []const u8,
};

pub const ControlResult = union(enum) {
    ack: []u8,
    err: ControlError,
};

pub fn handleAuthStatusControl(
    allocator: std.mem.Allocator,
    runtime_registry: anytype,
    session_bindings: *std.StringHashMapUnmanaged(server_session_bindings.SessionBinding),
    active_session_key: []const u8,
    principal: anytype,
    correlation_id: ?[]const u8,
) !ControlResult {
    _ = allocator;
    if (principal.role != .access) {
        const active_binding = session_bindings.get(active_session_key) orelse return error.InvalidState;
        runtime_registry.appendSecurityAuditAndDebug(
            active_binding.agent_id,
            .auth_status,
            principal.role,
            correlation_id,
            "auth_status_forbidden",
            false,
            "forbidden",
            "operation requires access token",
        );
        return .{ .err = .{ .code = "forbidden", .message = "operation requires access token" } };
    }
    return .{ .ack = try runtime_registry.authStatusJson() };
}

pub fn handleSessionStatusControl(
    allocator: std.mem.Allocator,
    runtime_registry: anytype,
    session_bindings: *std.StringHashMapUnmanaged(server_session_bindings.SessionBinding),
    active_session_key: []const u8,
    principal: anytype,
    payload_json: ?[]const u8,
) !ControlResult {
    var payload = try parseControlPayloadObject(allocator, payload_json);
    defer payload.deinit();
    if (payload.value != .object) {
        return .{ .err = .{ .code = "invalid_payload", .message = "session_status payload must be an object" } };
    }

    const payload_session_key = getOptionalStringField(payload.value.object, "session_key");
    const session_key = if (payload_session_key) |value| value else active_session_key;
    const heartbeat = getOptionalBoolField(payload.value.object, "heartbeat") orelse false;
    const binding = session_bindings.get(session_key) orelse {
        return .{ .err = .{ .code = "not_found", .message = "session_key not found" } };
    };

    if (heartbeat) {
        runtime_registry.rememberPrincipalSession(
            principal,
            session_key,
            binding.agent_id,
            binding.workspace_id,
        );
        runtime_registry.touchRuntimeAttachState(binding.agent_id, binding.workspace_id);
    }

    var attach_state = runtime_registry.ensureRuntimeWarmup(
        binding.agent_id,
        binding.workspace_id,
        binding.workspace_token,
        false,
    ) catch |warm_err| {
        return .{ .err = .{
            .code = "execution_failed",
            .message = @errorName(warm_err),
        } };
    };
    defer deinitAttachState(allocator, &attach_state);

    const attach_json = try buildSessionAttachStateJson(allocator, attach_state);
    defer allocator.free(attach_json);
    const now_ms = std.time.milliTimestamp();
    const session_last_active_ms = runtime_registry.auth_tokens.sessionLastActiveMs(principal.role, session_key) orelse 0;
    const session_stale = session_last_active_ms > 0 and (now_ms - session_last_active_ms) > session_heartbeat_ttl_ms;
    const agent_last_heartbeat_ms = attach_state.updated_at_ms;
    const agent_stale = agent_last_heartbeat_ms > 0 and (now_ms - agent_last_heartbeat_ms) > agent_heartbeat_ttl_ms;
    return .{ .ack = try server_session_payloads.buildSessionStatusPayload(
        allocator,
        session_key,
        binding.agent_id,
        binding.workspace_id,
        attach_json,
        session_last_active_ms,
        session_stale,
        agent_last_heartbeat_ms,
        agent_stale,
    ) };
}

pub fn handleSessionListControl(
    allocator: std.mem.Allocator,
    session_bindings: *std.StringHashMapUnmanaged(server_session_bindings.SessionBinding),
    active_session_key: []const u8,
) ![]u8 {
    return server_session_payloads.buildSessionListPayload(allocator, session_bindings, active_session_key);
}

pub fn handleSessionRestoreControl(
    allocator: std.mem.Allocator,
    runtime_registry: anytype,
    principal: anytype,
    payload_json: ?[]const u8,
) !ControlResult {
    var payload = try parseControlPayloadObject(allocator, payload_json);
    defer payload.deinit();
    if (payload.value != .object) {
        return .{ .err = .{ .code = "invalid_payload", .message = "session_restore payload must be an object" } };
    }

    const agent_filter = getOptionalStringField(payload.value.object, "agent_id");
    var restored = try runtime_registry.auth_tokens.latestSessionOwned(principal.role, agent_filter);
    defer if (restored) |*entry| deinitHistoryEntry(allocator, entry);
    return .{ .ack = try server_session_payloads.buildSessionRestorePayload(allocator, restored) };
}

pub fn handleSessionHistoryControl(
    allocator: std.mem.Allocator,
    runtime_registry: anytype,
    principal: anytype,
    payload_json: ?[]const u8,
) !ControlResult {
    var payload = try parseControlPayloadObject(allocator, payload_json);
    defer payload.deinit();
    if (payload.value != .object) {
        return .{ .err = .{ .code = "invalid_payload", .message = "session_history payload must be an object" } };
    }
    const agent_filter = getOptionalStringField(payload.value.object, "agent_id");
    const limit = blk: {
        const value = payload.value.object.get("limit") orelse break :blk @as(usize, 10);
        if (value != .integer or value.integer < 0) {
            return .{ .err = .{ .code = "invalid_payload", .message = "limit must be a non-negative integer" } };
        }
        if (value.integer > 100) break :blk @as(usize, 100);
        break :blk @as(usize, @intCast(value.integer));
    };

    var history = try runtime_registry.auth_tokens.sessionHistoryOwned(
        principal.role,
        agent_filter,
        limit,
    );
    defer {
        for (history.items) |*entry| deinitHistoryEntry(allocator, entry);
        history.deinit(allocator);
    }
    return .{ .ack = try server_session_payloads.buildSessionHistoryPayload(allocator, history.items) };
}

fn buildSessionAttachStateJson(allocator: std.mem.Allocator, state: anytype) ![]u8 {
    return server_session_payloads.buildSessionAttachStateJson(
        allocator,
        switch (state.state) {
            .warming => "warming",
            .ready => "ready",
            .err => "error",
        },
        state,
    );
}

fn deinitAttachState(allocator: std.mem.Allocator, state: anytype) void {
    if (state.error_code) |value| allocator.free(value);
    if (state.error_message) |value| allocator.free(value);
    state.* = undefined;
}

fn deinitHistoryEntry(allocator: std.mem.Allocator, entry: anytype) void {
    allocator.free(entry.session_key);
    allocator.free(entry.agent_id);
    allocator.free(entry.workspace_id);
    if (entry.summary) |value| allocator.free(value);
    entry.* = undefined;
}
