const std = @import("std");
const unified = @import("spider-protocol").unified;
const namespace_session_mod = @import("acheron/session.zig");
const control_plane_mod = @import("acheron/control_plane.zig");
const server_control_payloads = @import("server_control_payloads.zig");
const server_namespace_sessions = @import("server_namespace_sessions.zig");
const server_session_bindings = @import("server_session_bindings.zig");
const server_session_payloads = @import("server_session_payloads.zig");
const server_workspace_status = @import("server_workspace_status.zig");

const host_actor_id = "spiderweb";
const host_workspace_id = control_plane_mod.host_workspace_id;

const parseControlPayloadObject = server_control_payloads.parseControlPayloadObject;
const getOptionalStringField = server_control_payloads.getOptionalStringField;
const getRequiredStringField = server_control_payloads.getRequiredStringField;

pub const ControlError = struct {
    code: []const u8,
    message: []const u8,
};

pub const ControlResult = union(enum) {
    ack: []u8,
    err: ControlError,
};

pub fn buildConnectAckPayload(
    allocator: std.mem.Allocator,
    runtime_registry: anytype,
    binding: server_session_bindings.SessionBinding,
    active_session_key: []const u8,
    connection_workspace_url: ?[]const u8,
    is_admin: bool,
    control_protocol_version: []const u8,
) ![]u8 {
    const workspace_id_json = if (binding.workspace_id) |workspace_id| blk: {
        const escaped_workspace = try unified.jsonEscape(allocator, workspace_id);
        defer allocator.free(escaped_workspace);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped_workspace});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(workspace_id_json);

    const workspace_json = try buildWorkspaceStatusPayloadForBinding(
        allocator,
        runtime_registry,
        binding,
        connection_workspace_url,
        is_admin,
    );
    defer allocator.free(workspace_json);

    return std.fmt.allocPrint(
        allocator,
        "{{\"agent_id\":\"{s}\",\"workspace_id\":{s},\"workspace\":{s},\"session\":\"{s}\",\"protocol\":\"{s}\"}}",
        .{
            binding.agent_id,
            workspace_id_json,
            workspace_json,
            active_session_key,
            control_protocol_version,
        },
    );
}

pub fn handleSessionAttachControl(
    allocator: std.mem.Allocator,
    runtime_registry: anytype,
    session_bindings: *std.StringHashMapUnmanaged(server_session_bindings.SessionBinding),
    active_session_key: *[]u8,
    namespace_session: *?namespace_session_mod.Session,
    principal: anytype,
    connection_venom_id: []const u8,
    control_service_attached: bool,
    connection_workspace_url: ?[]const u8,
    payload_json: ?[]const u8,
) !ControlResult {
    var payload = try parseControlPayloadObject(allocator, payload_json);
    defer payload.deinit();
    if (payload.value != .object) {
        return .{ .err = .{ .code = "invalid_payload", .message = "session_attach payload must be an object" } };
    }

    const session_key = getRequiredStringField(payload.value.object, "session_key") catch {
        return .{ .err = .{ .code = "missing_field", .message = "session_key is required" } };
    };
    const attach_agent_id = getRequiredStringField(payload.value.object, "agent_id") catch {
        return .{ .err = .{ .code = "missing_field", .message = "agent_id is required" } };
    };
    const attach_workspace_id = getRequiredStringField(payload.value.object, "workspace_id") catch {
        return .{ .err = .{ .code = "missing_field", .message = "workspace_id is required" } };
    };

    var attach_workspace_token = getOptionalStringField(payload.value.object, "workspace_token");
    const current_binding = session_bindings.get(active_session_key.*) orelse return error.InvalidState;
    var previous_active_binding = try server_session_bindings.cloneSessionBinding(allocator, current_binding);
    defer previous_active_binding.deinit(allocator);

    if (!server_session_bindings.isValidSessionKey(session_key)) {
        return .{ .err = .{ .code = "invalid_payload", .message = "invalid session_key" } };
    }
    if (!isValidAgentId(attach_agent_id)) {
        return .{ .err = .{ .code = "invalid_payload", .message = "invalid agent_id" } };
    }
    if (!isValidWorkspaceId(attach_workspace_id)) {
        return .{ .err = .{ .code = "invalid_payload", .message = "invalid workspace_id" } };
    }

    const existing_binding = session_bindings.get(session_key);
    if (existing_binding != null and std.mem.eql(u8, existing_binding.?.agent_id, attach_agent_id) and attach_workspace_token == null) {
        attach_workspace_token = existing_binding.?.workspace_token;
    }

    const activate_payload = try server_workspace_status.buildWorkspaceAccessPayload(allocator, attach_workspace_id, attach_workspace_token);
    defer allocator.free(activate_payload);
    _ = runtime_registry.control_plane.activateWorkspaceWithRole(
        attach_agent_id,
        activate_payload,
        principal.role == .access,
    ) catch |activate_err| {
        return .{ .err = .{
            .code = controlPlaneErrorCode(activate_err),
            .message = @errorName(activate_err),
        } };
    };

    const previous_session_key = try allocator.dupe(u8, active_session_key.*);
    defer allocator.free(previous_session_key);

    try server_session_bindings.upsertSessionBinding(
        allocator,
        session_bindings,
        session_key,
        attach_agent_id,
        server_session_bindings.defaultActorTypeForRole(principal.role),
        server_session_bindings.defaultActorIdForPrincipal(principal),
        attach_workspace_id,
        attach_workspace_token,
    );

    allocator.free(active_session_key.*);
    active_session_key.* = try allocator.dupe(u8, session_key);

    const active_binding = session_bindings.get(session_key) orelse return error.InvalidState;
    var attach_state = runtime_registry.ensureRuntimeWarmup(
        active_binding.agent_id,
        active_binding.workspace_id,
        active_binding.workspace_token,
        true,
    ) catch |warm_err| {
        return .{ .err = .{
            .code = "execution_failed",
            .message = @errorName(warm_err),
        } };
    };
    defer deinitAttachState(allocator, &attach_state);

    const attach_json = try buildSessionAttachStateJson(allocator, attach_state);
    defer allocator.free(attach_json);
    const workspace_json = try buildWorkspaceStatusPayloadForBinding(
        allocator,
        runtime_registry,
        active_binding,
        connection_workspace_url,
        principal.role == .access,
    );
    defer allocator.free(workspace_json);
    const ack_payload = try server_session_payloads.buildSessionAttachAckPayload(
        allocator,
        session_key,
        active_binding.agent_id,
        active_binding.workspace_id,
        workspace_json,
        attach_json,
    );

    server_namespace_sessions.resetNamespaceSession(namespace_session);
    runtime_registry.rememberPrincipalSession(
        principal,
        session_key,
        active_binding.agent_id,
        active_binding.workspace_id,
    );

    if (control_service_attached) {
        const runtime_binding_changed = !std.mem.eql(u8, previous_active_binding.agent_id, active_binding.agent_id) or
            !optionalStringsEqual(previous_active_binding.workspace_id, active_binding.workspace_id);
        if (runtime_binding_changed) {
            runtime_registry.publishVenomPresenceForBinding(
                principal.role,
                previous_active_binding,
                previous_session_key,
                connection_venom_id,
                false,
            );
        }
        runtime_registry.publishVenomPresenceForBinding(
            principal.role,
            active_binding,
            session_key,
            connection_venom_id,
            true,
        );
    }

    return .{ .ack = ack_payload };
}

pub fn handleSessionResumeControl(
    allocator: std.mem.Allocator,
    runtime_registry: anytype,
    session_bindings: *std.StringHashMapUnmanaged(server_session_bindings.SessionBinding),
    active_session_key: *[]u8,
    namespace_session: *?namespace_session_mod.Session,
    principal: anytype,
    connection_venom_id: []const u8,
    control_service_attached: bool,
    connection_workspace_url: ?[]const u8,
    payload_json: ?[]const u8,
) !ControlResult {
    var payload = try parseControlPayloadObject(allocator, payload_json);
    defer payload.deinit();
    if (payload.value != .object) {
        return .{ .err = .{ .code = "invalid_payload", .message = "session_resume payload must be an object" } };
    }

    const session_key = getRequiredStringField(payload.value.object, "session_key") catch {
        return .{ .err = .{ .code = "missing_field", .message = "session_key is required" } };
    };
    const binding = session_bindings.get(session_key) orelse {
        return .{ .err = .{ .code = "not_found", .message = "session_key not found" } };
    };

    const previous_binding = session_bindings.get(active_session_key.*) orelse return error.InvalidState;
    const previous_session_key = try allocator.dupe(u8, active_session_key.*);
    defer allocator.free(previous_session_key);

    allocator.free(active_session_key.*);
    active_session_key.* = try allocator.dupe(u8, session_key);

    var attach_state = runtime_registry.ensureRuntimeWarmup(
        binding.agent_id,
        binding.workspace_id,
        binding.workspace_token,
        true,
    ) catch |warm_err| {
        return .{ .err = .{
            .code = "execution_failed",
            .message = @errorName(warm_err),
        } };
    };
    defer deinitAttachState(allocator, &attach_state);

    const attach_json = try buildSessionAttachStateJson(allocator, attach_state);
    defer allocator.free(attach_json);
    const workspace_json = try buildWorkspaceStatusPayloadForBinding(
        allocator,
        runtime_registry,
        binding,
        connection_workspace_url,
        principal.role == .access,
    );
    defer allocator.free(workspace_json);
    const ack_payload = try server_session_payloads.buildSessionAttachAckPayload(
        allocator,
        session_key,
        binding.agent_id,
        binding.workspace_id,
        workspace_json,
        attach_json,
    );

    server_namespace_sessions.resetNamespaceSession(namespace_session);
    runtime_registry.rememberPrincipalSession(
        principal,
        session_key,
        binding.agent_id,
        binding.workspace_id,
    );

    if (control_service_attached) {
        const runtime_binding_changed = !std.mem.eql(u8, previous_binding.agent_id, binding.agent_id) or
            !optionalStringsEqual(previous_binding.workspace_id, binding.workspace_id);
        if (runtime_binding_changed) {
            runtime_registry.publishVenomPresenceForBinding(
                principal.role,
                previous_binding,
                previous_session_key,
                connection_venom_id,
                false,
            );
        }
        runtime_registry.publishVenomPresenceForBinding(
            principal.role,
            binding,
            session_key,
            connection_venom_id,
            true,
        );
    }

    return .{ .ack = ack_payload };
}

pub fn handleSessionCloseControl(
    allocator: std.mem.Allocator,
    runtime_registry: anytype,
    session_bindings: *std.StringHashMapUnmanaged(server_session_bindings.SessionBinding),
    active_session_key: *[]u8,
    namespace_session: *?namespace_session_mod.Session,
    principal: anytype,
    connection_venom_id: []const u8,
    control_service_attached: bool,
    payload_json: ?[]const u8,
) !ControlResult {
    var payload = try parseControlPayloadObject(allocator, payload_json);
    defer payload.deinit();
    if (payload.value != .object) {
        return .{ .err = .{ .code = "invalid_payload", .message = "session_close payload must be an object" } };
    }

    const session_key = getRequiredStringField(payload.value.object, "session_key") catch {
        return .{ .err = .{ .code = "missing_field", .message = "session_key is required" } };
    };
    if (std.mem.eql(u8, session_key, "main")) {
        return .{ .err = .{ .code = "forbidden", .message = "main session cannot be closed" } };
    }

    var previous_active_binding: ?server_session_bindings.SessionBinding = null;
    defer if (previous_active_binding) |*value| value.deinit(allocator);
    var previous_active_session_key: ?[]u8 = null;
    defer if (previous_active_session_key) |value| allocator.free(value);

    if (control_service_attached and std.mem.eql(u8, active_session_key.*, session_key)) {
        const active_binding_before_close = session_bindings.get(active_session_key.*) orelse return error.InvalidState;
        previous_active_binding = try server_session_bindings.cloneSessionBinding(allocator, active_binding_before_close);
        previous_active_session_key = try allocator.dupe(u8, active_session_key.*);
    }

    if (session_bindings.fetchRemove(session_key)) |removed| {
        allocator.free(removed.key);
        var binding = removed.value;
        binding.deinit(allocator);
    } else {
        return .{ .err = .{ .code = "not_found", .message = "session_key not found" } };
    }

    if (std.mem.eql(u8, active_session_key.*, session_key)) {
        allocator.free(active_session_key.*);
        active_session_key.* = try allocator.dupe(u8, "main");
    }

    if (control_service_attached and previous_active_binding != null and previous_active_session_key != null) {
        const main_binding = session_bindings.get(active_session_key.*) orelse return error.InvalidState;
        const old_binding = previous_active_binding.?;
        const runtime_binding_changed = !std.mem.eql(u8, old_binding.agent_id, main_binding.agent_id) or
            !optionalStringsEqual(old_binding.workspace_id, main_binding.workspace_id);
        if (runtime_binding_changed) {
            runtime_registry.publishVenomPresenceForBinding(
                principal.role,
                old_binding,
                previous_active_session_key.?,
                connection_venom_id,
                false,
            );
        }
        runtime_registry.publishVenomPresenceForBinding(
            principal.role,
            main_binding,
            active_session_key.*,
            connection_venom_id,
            true,
        );
    }

    const ack_payload = try std.fmt.allocPrint(
        allocator,
        "{{\"session_key\":\"{s}\",\"closed\":true,\"active_session\":\"{s}\"}}",
        .{ session_key, active_session_key.* },
    );

    server_namespace_sessions.resetNamespaceSession(namespace_session);
    return .{ .ack = ack_payload };
}

fn buildWorkspaceStatusPayloadForBinding(
    allocator: std.mem.Allocator,
    runtime_registry: anytype,
    binding: server_session_bindings.SessionBinding,
    connection_workspace_url: ?[]const u8,
    is_admin: bool,
) ![]u8 {
    return server_workspace_status.buildWorkspaceStatusPayloadForBinding(
        allocator,
        &runtime_registry.control_plane,
        host_actor_id,
        host_workspace_id,
        binding,
        connection_workspace_url,
        is_admin,
    );
}

fn buildSessionAttachStateJson(allocator: std.mem.Allocator, state: anytype) ![]u8 {
    return server_session_payloads.buildSessionAttachStateJson(
        allocator,
        sessionAttachStateName(state.state),
        state,
    );
}

fn sessionAttachStateName(state: anytype) []const u8 {
    return switch (state) {
        .warming => "warming",
        .ready => "ready",
        .err => "error",
    };
}

fn optionalStringsEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.mem.eql(u8, left.?, right.?);
}

fn controlPlaneErrorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.UnsupportedControlPlaneOperation => "unsupported_control_plane_operation",
        error.UnsupportedLegacyApi => "unsupported_legacy_api",
        error.AccessDenied => "forbidden",
        error.InvalidAgentId => "invalid_payload",
        control_plane_mod.ControlPlaneError.InvalidPayload => "invalid_payload",
        control_plane_mod.ControlPlaneError.MissingField => "missing_field",
        control_plane_mod.ControlPlaneError.TemplateNotFound => "template_not_found",
        control_plane_mod.ControlPlaneError.InviteNotFound => "invite_not_found",
        control_plane_mod.ControlPlaneError.InviteExpired => "invite_expired",
        control_plane_mod.ControlPlaneError.InviteRedeemed => "invite_redeemed",
        control_plane_mod.ControlPlaneError.NodeNotFound => "node_not_found",
        error.AgentNotFound => "agent_not_found",
        control_plane_mod.ControlPlaneError.NodeAuthFailed => "node_auth_failed",
        control_plane_mod.ControlPlaneError.PendingJoinNotFound => "pending_join_not_found",
        control_plane_mod.ControlPlaneError.WorkspaceNotFound => "workspace_not_found",
        control_plane_mod.ControlPlaneError.WorkspaceAuthFailed => "workspace_auth_failed",
        control_plane_mod.ControlPlaneError.WorkspaceProtected => "workspace_protected",
        control_plane_mod.ControlPlaneError.WorkspaceAssignmentForbidden => "workspace_assignment_forbidden",
        control_plane_mod.ControlPlaneError.WorkspacePolicyForbidden => "workspace_policy_forbidden",
        control_plane_mod.ControlPlaneError.MountConflict => "mount_conflict",
        control_plane_mod.ControlPlaneError.MountNotFound => "mount_not_found",
        control_plane_mod.ControlPlaneError.BindConflict => "bind_conflict",
        control_plane_mod.ControlPlaneError.BindNotFound => "bind_not_found",
        else => "control_plane_error",
    };
}

fn isValidAgentId(agent_id: []const u8) bool {
    if (agent_id.len == 0 or agent_id.len > 128) return false;
    for (agent_id) |char| {
        if (std.ascii.isAlphanumeric(char)) continue;
        if (char == '-' or char == '_') continue;
        return false;
    }
    return true;
}

fn isValidWorkspaceId(project_id: []const u8) bool {
    if (project_id.len == 0 or project_id.len > 128) return false;
    for (project_id) |char| {
        if (std.ascii.isAlphanumeric(char)) continue;
        if (char == '-' or char == '_') continue;
        return false;
    }
    return true;
}

fn deinitAttachState(allocator: std.mem.Allocator, state: anytype) void {
    if (state.error_code) |value| allocator.free(value);
    if (state.error_message) |value| allocator.free(value);
    state.* = undefined;
}
