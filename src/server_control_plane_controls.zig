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
        => true,
        else => false,
    };
}

pub fn handleControlPlaneCommand(
    runtime_registry: anytype,
    control_type: unified.ControlType,
    agent_id: []const u8,
    is_admin: bool,
    payload_json: ?[]const u8,
    connection_workspace_url: ?[]const u8,
) ![]u8 {
    const raw_response_json = switch (control_type) {
        .node_invite_create => try runtime_registry.control_plane.createNodeInvite(payload_json),
        .node_join_request => try runtime_registry.control_plane.nodeJoinRequest(payload_json),
        .node_join_pending_list => try runtime_registry.control_plane.listPendingNodeJoins(payload_json),
        .node_join_approve => try runtime_registry.control_plane.approvePendingNodeJoin(payload_json),
        .node_join_deny => try runtime_registry.control_plane.denyPendingNodeJoin(payload_json),
        .node_join => try runtime_registry.control_plane.nodeJoin(payload_json),
        .node_ensure => try runtime_registry.control_plane.nodeEnsure(payload_json),
        .node_lease_refresh => try runtime_registry.control_plane.refreshNodeLease(payload_json),
        .venom_bind => try runtime_registry.control_plane.bindPreferredVenomProvider(payload_json),
        .venom_upsert => try runtime_registry.control_plane.nodeVenomUpsert(payload_json),
        .venom_get => try runtime_registry.control_plane.nodeVenomGet(payload_json),
        .node_list => try runtime_registry.control_plane.listNodes(),
        .node_get => try runtime_registry.control_plane.getNode(payload_json),
        .node_delete => try runtime_registry.control_plane.deleteNode(payload_json),
        .workspace_create => try runtime_registry.control_plane.createProject(payload_json),
        .workspace_update => try runtime_registry.control_plane.updateProjectWithRole(payload_json, is_admin),
        .workspace_delete => try runtime_registry.control_plane.deleteProjectWithRole(payload_json, is_admin),
        .workspace_list => try runtime_registry.control_plane.listProjects(),
        .workspace_get => try runtime_registry.control_plane.getProjectWithRole(payload_json, is_admin),
        .workspace_template_list => try runtime_registry.control_plane.listWorkspaceTemplates(),
        .workspace_template_get => try runtime_registry.control_plane.getWorkspaceTemplate(payload_json),
        .workspace_mount_set => try runtime_registry.control_plane.setProjectMountWithRole(payload_json, is_admin),
        .workspace_mount_remove => try runtime_registry.control_plane.removeProjectMountWithRole(payload_json, is_admin),
        .workspace_mount_list => try runtime_registry.control_plane.listProjectMountsWithRole(payload_json, is_admin),
        .workspace_bind_set => try runtime_registry.control_plane.setProjectBindWithRole(payload_json, is_admin),
        .workspace_bind_remove => try runtime_registry.control_plane.removeProjectBindWithRole(payload_json, is_admin),
        .workspace_bind_list => try runtime_registry.control_plane.listProjectBindsWithRole(payload_json, is_admin),
        .workspace_token_rotate => try runtime_registry.control_plane.rotateProjectTokenWithRole(payload_json, is_admin),
        .workspace_token_revoke => try runtime_registry.control_plane.revokeProjectTokenWithRole(payload_json, is_admin),
        .workspace_activate => try runtime_registry.control_plane.activateProjectWithRole(agent_id, payload_json, is_admin),
        .workspace_status => try runtime_registry.control_plane.workspaceStatusWithRole(agent_id, payload_json, is_admin),
        .reconcile_status => try runtime_registry.control_plane.reconcileStatus(payload_json),
        .workspace_up => try runtime_registry.control_plane.projectUpWithRole(agent_id, payload_json, is_admin),
        .audit_tail => try runtime_registry.buildAuditTailPayload(payload_json),
        else => return error.UnsupportedControlPlaneOperation,
    };
    errdefer runtime_registry.allocator.free(raw_response_json);

    const response_json = blk: {
        if (control_type == .workspace_status) {
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
