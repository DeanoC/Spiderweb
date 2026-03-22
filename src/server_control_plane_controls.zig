const std = @import("std");
const unified = @import("spider-protocol").unified;
const control_plane_mod = @import("acheron/control_plane.zig");
const server_control_scope = @import("server_control_scope.zig");
const server_workspace_status = @import("server_workspace_status.zig");

pub const ControlError = struct {
    code: []const u8,
    message: []const u8,
};

pub const ControlAck = struct {
    payload_json: []u8,
    request_reconcile: bool,
};

pub const ControlResult = union(enum) {
    ack: ControlAck,
    err: ControlError,
};

const JsonFieldAlias = struct {
    from: []const u8,
    to: []const u8,
};

const workspace_to_project_aliases = [_]JsonFieldAlias{
    .{ .from = "workspace_id", .to = "project_id" },
    .{ .from = "workspace_token", .to = "project_token" },
    .{ .from = "workspace_name", .to = "name" },
    .{ .from = "workspaces", .to = "projects" },
    .{ .from = "active_workspace", .to = "active_project" },
    .{ .from = "selected_workspace", .to = "selected_project" },
    .{ .from = "workspace_mount_digest", .to = "project_mount_digest" },
};

const project_to_workspace_aliases = [_]JsonFieldAlias{
    .{ .from = "project_id", .to = "workspace_id" },
    .{ .from = "project_token", .to = "workspace_token" },
    .{ .from = "project_name", .to = "workspace_name" },
    .{ .from = "projects", .to = "workspaces" },
    .{ .from = "active_project", .to = "active_workspace" },
    .{ .from = "selected_project", .to = "selected_workspace" },
    .{ .from = "project_mount_digest", .to = "workspace_mount_digest" },
};

pub fn handleControlPlaneControl(
    allocator: std.mem.Allocator,
    runtime_registry: anytype,
    control_type: unified.ControlType,
    control_agent_id: []const u8,
    is_admin: bool,
    correlation_id: ?[]const u8,
    payload_json: ?[]const u8,
    connection_workspace_url: ?[]const u8,
) !ControlResult {
    const scope = server_control_scope.controlMutationScope(control_type);
    if (scope != .none and correlation_id == null) {
        return .{ .err = .{
            .code = "correlation_required",
            .message = "missing correlation_id on mutating control operation",
        } };
    }
    if (scope != .none) {
        server_control_scope.validateControlScopeTokens(allocator, runtime_registry, control_type, payload_json) catch |err| {
            const code = switch (err) {
                error.MissingField => "missing_field",
                error.InvalidPayload => "invalid_payload",
                else => "operator_auth_failed",
            };
            runtime_registry.appendAuditRecord(
                control_agent_id,
                control_type,
                scope,
                correlation_id,
                false,
                code,
            );
            return .{ .err = .{
                .code = code,
                .message = @errorName(err),
            } };
        };
    }

    const availability_before = runtime_registry.control_plane.availabilitySnapshot();
    const result_payload = handleControlPlaneCommand(
        runtime_registry,
        control_type,
        control_agent_id,
        is_admin,
        payload_json,
        connection_workspace_url,
    ) catch |err| {
        const code = controlPlaneErrorCode(err);
        if (scope != .none) {
            runtime_registry.appendAuditRecord(
                control_agent_id,
                control_type,
                scope,
                correlation_id,
                false,
                code,
            );
        }
        return .{ .err = .{
            .code = code,
            .message = @errorName(err),
        } };
    };

    if (scope != .none) {
        runtime_registry.appendAuditRecord(
            control_agent_id,
            control_type,
            scope,
            correlation_id,
            true,
            null,
        );
    }

    const availability_after = runtime_registry.control_plane.availabilitySnapshot();
    const request_reconcile =
        isWorkspaceTopologyMutation(control_type) or
        !control_plane_mod.ControlPlane.AvailabilitySnapshot.eql(availability_before, availability_after);

    return .{ .ack = .{
        .payload_json = result_payload,
        .request_reconcile = request_reconcile,
    } };
}

fn isWorkspaceTopologyMutation(control_type: unified.ControlType) bool {
    return switch (control_type) {
        .node_join_approve,
        .node_join_deny,
        .node_join,
        .node_ensure,
        .venom_bind,
        .venom_upsert,
        .node_delete,
        .workspace_create,
        .workspace_update,
        .workspace_delete,
        .workspace_bind_set,
        .workspace_bind_remove,
        .workspace_mount_set,
        .workspace_mount_remove,
        .workspace_activate,
        .workspace_up,
        .project_create,
        .project_update,
        .project_delete,
        .project_mount_set,
        .project_mount_remove,
        .project_activate,
        .project_up,
        => true,
        else => false,
    };
}

fn isWorkspaceAliasControlType(control_type: unified.ControlType) bool {
    return switch (control_type) {
        .workspace_create,
        .workspace_update,
        .workspace_delete,
        .workspace_list,
        .workspace_get,
        .workspace_template_list,
        .workspace_template_get,
        .workspace_mount_set,
        .workspace_mount_remove,
        .workspace_mount_list,
        .workspace_bind_set,
        .workspace_bind_remove,
        .workspace_bind_list,
        .workspace_token_rotate,
        .workspace_token_revoke,
        .workspace_activate,
        .workspace_status,
        .workspace_up,
        => true,
        else => false,
    };
}

fn canonicalProjectControlType(control_type: unified.ControlType) unified.ControlType {
    return switch (control_type) {
        .workspace_create => .project_create,
        .workspace_update => .project_update,
        .workspace_delete => .project_delete,
        .workspace_list => .project_list,
        .workspace_get => .project_get,
        .workspace_mount_set => .project_mount_set,
        .workspace_mount_remove => .project_mount_remove,
        .workspace_mount_list => .project_mount_list,
        .workspace_token_rotate => .project_token_rotate,
        .workspace_token_revoke => .project_token_revoke,
        .workspace_activate => .project_activate,
        .workspace_up => .project_up,
        else => control_type,
    };
}

fn aliasFieldName(name: []const u8, aliases: []const JsonFieldAlias) []const u8 {
    for (aliases) |alias| {
        if (std.mem.eql(u8, name, alias.from)) return alias.to;
    }
    return name;
}

fn appendAliasedJsonValue(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    value: std.json.Value,
    aliases: []const JsonFieldAlias,
) !void {
    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |boolean| try out.appendSlice(allocator, if (boolean) "true" else "false"),
        .integer => |integer| try out.writer(allocator).print("{d}", .{integer}),
        .float => |float| try out.writer(allocator).print("{d}", .{float}),
        .number_string => |number| try out.appendSlice(allocator, number),
        .string => |string| {
            const escaped = try unified.jsonEscape(allocator, string);
            defer allocator.free(escaped);
            try out.writer(allocator).print("\"{s}\"", .{escaped});
        },
        .array => |array| {
            try out.append(allocator, '[');
            for (array.items, 0..) |item, idx| {
                if (idx != 0) try out.append(allocator, ',');
                try appendAliasedJsonValue(allocator, out, item, aliases);
            }
            try out.append(allocator, ']');
        },
        .object => |object| {
            try out.append(allocator, '{');
            var it = object.iterator();
            var idx: usize = 0;
            while (it.next()) |entry| : (idx += 1) {
                if (idx != 0) try out.append(allocator, ',');
                const aliased_name = aliasFieldName(entry.key_ptr.*, aliases);
                const escaped_name = try unified.jsonEscape(allocator, aliased_name);
                defer allocator.free(escaped_name);
                try out.writer(allocator).print("\"{s}\":", .{escaped_name});
                try appendAliasedJsonValue(allocator, out, entry.value_ptr.*, aliases);
            }
            try out.append(allocator, '}');
        },
    }
}

fn rewriteJsonFieldAliases(
    allocator: std.mem.Allocator,
    payload_json: ?[]const u8,
    aliases: []const JsonFieldAlias,
) !?[]u8 {
    const raw = payload_json orelse return null;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try appendAliasedJsonValue(allocator, &out, parsed.value, aliases);
    const owned = try out.toOwnedSlice(allocator);
    return @as(?[]u8, owned);
}

pub fn handleControlPlaneCommand(
    runtime_registry: anytype,
    control_type: unified.ControlType,
    agent_id: []const u8,
    is_admin: bool,
    payload_json: ?[]const u8,
    connection_workspace_url: ?[]const u8,
) ![]u8 {
    const control_type_canonical = canonicalProjectControlType(control_type);
    const request_json = if (isWorkspaceAliasControlType(control_type) or control_type == .workspace_status)
        try rewriteJsonFieldAliases(runtime_registry.allocator, payload_json, &workspace_to_project_aliases)
    else
        null;
    defer if (request_json) |value| runtime_registry.allocator.free(value);

    const effective_payload = if (request_json) |value| @as(?[]const u8, value) else payload_json;
    const raw_response_json = switch (control_type_canonical) {
        .node_invite_create => try runtime_registry.control_plane.createNodeInvite(effective_payload),
        .node_join_request => try runtime_registry.control_plane.nodeJoinRequest(effective_payload),
        .node_join_pending_list => try runtime_registry.control_plane.listPendingNodeJoins(effective_payload),
        .node_join_approve => try runtime_registry.control_plane.approvePendingNodeJoin(effective_payload),
        .node_join_deny => try runtime_registry.control_plane.denyPendingNodeJoin(effective_payload),
        .node_join => try runtime_registry.control_plane.nodeJoin(effective_payload),
        .node_ensure => try runtime_registry.control_plane.nodeEnsure(effective_payload),
        .node_lease_refresh => try runtime_registry.control_plane.refreshNodeLease(effective_payload),
        .venom_bind => try runtime_registry.control_plane.bindPreferredVenomProvider(effective_payload),
        .venom_upsert => try runtime_registry.control_plane.nodeVenomUpsert(effective_payload),
        .venom_get => try runtime_registry.control_plane.nodeVenomGet(effective_payload),
        .node_list => try runtime_registry.control_plane.listNodes(),
        .node_get => try runtime_registry.control_plane.getNode(effective_payload),
        .node_delete => try runtime_registry.control_plane.deleteNode(effective_payload),
        .project_create => try runtime_registry.control_plane.createProject(effective_payload),
        .project_update => try runtime_registry.control_plane.updateProjectWithRole(effective_payload, is_admin),
        .project_delete => try runtime_registry.control_plane.deleteProjectWithRole(effective_payload, is_admin),
        .project_list => try runtime_registry.control_plane.listProjects(),
        .project_get => try runtime_registry.control_plane.getProjectWithRole(effective_payload, is_admin),
        .workspace_template_list => try runtime_registry.control_plane.listWorkspaceTemplates(),
        .workspace_template_get => try runtime_registry.control_plane.getWorkspaceTemplate(effective_payload),
        .project_mount_set => try runtime_registry.control_plane.setProjectMountWithRole(effective_payload, is_admin),
        .project_mount_remove => try runtime_registry.control_plane.removeProjectMountWithRole(effective_payload, is_admin),
        .project_mount_list => try runtime_registry.control_plane.listProjectMountsWithRole(effective_payload, is_admin),
        .workspace_bind_set => try runtime_registry.control_plane.setProjectBindWithRole(effective_payload, is_admin),
        .workspace_bind_remove => try runtime_registry.control_plane.removeProjectBindWithRole(effective_payload, is_admin),
        .workspace_bind_list => try runtime_registry.control_plane.listProjectBindsWithRole(effective_payload, is_admin),
        .project_token_rotate => try runtime_registry.control_plane.rotateProjectTokenWithRole(effective_payload, is_admin),
        .project_token_revoke => try runtime_registry.control_plane.revokeProjectTokenWithRole(effective_payload, is_admin),
        .project_activate => try runtime_registry.control_plane.activateProjectWithRole(agent_id, effective_payload, is_admin),
        .workspace_status => try runtime_registry.control_plane.workspaceStatusWithRole(agent_id, effective_payload, is_admin),
        .reconcile_status => try runtime_registry.control_plane.reconcileStatus(effective_payload),
        .project_up => try runtime_registry.control_plane.projectUpWithRole(agent_id, effective_payload, is_admin),
        .audit_tail => try runtime_registry.buildAuditTailPayload(effective_payload),
        else => return error.UnsupportedControlPlaneOperation,
    };
    errdefer runtime_registry.allocator.free(raw_response_json);

    const response_json = blk: {
        if (control_type_canonical == .workspace_status) {
            break :blk try server_workspace_status.rewriteWorkspaceStatusFsUrls(
                runtime_registry.allocator,
                raw_response_json,
                connection_workspace_url,
            );
        }
        break :blk raw_response_json;
    };
    if (response_json.ptr != raw_response_json.ptr) runtime_registry.allocator.free(raw_response_json);
    errdefer runtime_registry.allocator.free(response_json);

    if (isWorkspaceAliasControlType(control_type) or control_type == .workspace_status) {
        const rewritten = try rewriteJsonFieldAliases(runtime_registry.allocator, response_json, &project_to_workspace_aliases);
        const rewritten_value = rewritten orelse return response_json;
        runtime_registry.allocator.free(response_json);
        return rewritten_value;
    }

    return response_json;
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
        control_plane_mod.ControlPlaneError.ProjectNotFound => "project_not_found",
        control_plane_mod.ControlPlaneError.ProjectAuthFailed => "project_auth_failed",
        control_plane_mod.ControlPlaneError.ProjectProtected => "project_protected",
        control_plane_mod.ControlPlaneError.ProjectAssignmentForbidden => "project_assignment_forbidden",
        control_plane_mod.ControlPlaneError.ProjectPolicyForbidden => "project_policy_forbidden",
        control_plane_mod.ControlPlaneError.MountConflict => "mount_conflict",
        control_plane_mod.ControlPlaneError.MountNotFound => "mount_not_found",
        control_plane_mod.ControlPlaneError.BindConflict => "bind_conflict",
        control_plane_mod.ControlPlaneError.BindNotFound => "bind_not_found",
        else => "control_plane_error",
    };
}
