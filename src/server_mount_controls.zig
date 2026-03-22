const std = @import("std");
const unified = @import("spider-protocol").unified;
const acheron_session_mod = @import("acheron/session.zig");
const control_plane_mod = @import("acheron/control_plane.zig");
const server_control_payloads = @import("server_control_payloads.zig");
const server_mount_graph_io = @import("server_mount_graph_io.zig");
const server_namespace_sessions = @import("server_namespace_sessions.zig");
const server_session_bindings = @import("server_session_bindings.zig");
const server_workspace_status = @import("server_workspace_status.zig");

const host_actor_id = "spiderweb";
const host_workspace_id = control_plane_mod.host_workspace_id;
const max_mount_graph_materialized_file_bytes: usize = 16 * 1024 * 1024;

const parseControlPayloadObject = server_control_payloads.parseControlPayloadObject;
const getOptionalStringField = server_control_payloads.getOptionalStringField;
const getRequiredStringField = server_control_payloads.getRequiredStringField;
const getRequiredStringFieldAllowEmpty = server_control_payloads.getRequiredStringFieldAllowEmpty;
const getOptionalU64Field = server_control_payloads.getOptionalU64Field;
const getOptionalU32Field = server_control_payloads.getOptionalU32Field;
const getOptionalI64Field = server_control_payloads.getOptionalI64Field;
const getOptionalBoolField = server_control_payloads.getOptionalBoolField;
const decodeStandardBase64Owned = server_control_payloads.decodeStandardBase64Owned;

pub fn handleMountAttachControl(
    allocator: std.mem.Allocator,
    runtime_registry: anytype,
    namespace_session: *?acheron_session_mod.Session,
    binding: server_session_bindings.SessionBinding,
    session_key: []const u8,
    trusted_namespace_mount_url: ?[]const u8,
    connection_workspace_url: ?[]const u8,
    is_admin: bool,
    payload_json: ?[]const u8,
) ![]u8 {
    var payload = try parseControlPayloadObject(allocator, payload_json);
    defer payload.deinit();
    if (payload.value != .object) return error.InvalidPayload;

    const requested_path = getOptionalStringField(payload.value.object, "path") orelse "/";
    const requested_depth = getOptionalU32Field(payload.value.object, "depth") orelse 1;
    const session = try server_namespace_sessions.getOrInitNamespaceSessionForBinding(
        allocator,
        namespace_session,
        runtime_registry,
        binding,
        session_key,
        trusted_namespace_mount_url,
        is_admin,
    );
    const workspace_json = buildWorkspaceStatusPayloadForBinding(
        allocator,
        runtime_registry,
        binding,
        connection_workspace_url,
        is_admin,
    ) catch |err| {
        std.log.warn("mount_attach workspace status build failed: {s}", .{@errorName(err)});
        return err;
    };
    defer allocator.free(workspace_json);
    return session.buildMountGraphSnapshotPayloadForPath(
        workspace_json,
        session_key,
        requested_path,
        requested_depth,
    ) catch |err| {
        std.log.warn("mount_attach snapshot build failed path={s} depth={d}: {s}", .{
            requested_path,
            requested_depth,
            @errorName(err),
        });
        return err;
    };
}

pub fn handleMountFileReadControl(
    allocator: std.mem.Allocator,
    runtime_registry: anytype,
    namespace_session: *?acheron_session_mod.Session,
    binding: server_session_bindings.SessionBinding,
    session_key: []const u8,
    trusted_namespace_mount_url: ?[]const u8,
    is_admin: bool,
    payload_json: ?[]const u8,
) ![]u8 {
    var payload = try parseControlPayloadObject(allocator, payload_json);
    defer payload.deinit();
    if (payload.value != .object) return error.InvalidPayload;

    const absolute_path = try getRequiredStringField(payload.value.object, "path");
    const offset = getOptionalU64Field(payload.value.object, "offset") orelse 0;
    const requested_length_field = getOptionalU32Field(payload.value.object, "length");
    const requested_length = server_mount_graph_io.clampReadLength(
        offset,
        requested_length_field,
        max_mount_graph_materialized_file_bytes,
    ) catch |err| switch (err) {
        error.InvalidOffset => return err,
    };

    const session = try server_namespace_sessions.getOrInitNamespaceSessionForBinding(
        allocator,
        namespace_session,
        runtime_registry,
        binding,
        session_key,
        trusted_namespace_mount_url,
        is_admin,
    );
    const chunk = try session.readMountGraphFile(absolute_path, offset, requested_length);
    defer allocator.free(chunk);

    const encoded = try server_mount_graph_io.encodeStandardBase64Owned(allocator, chunk);
    defer allocator.free(encoded);
    const escaped_path = try unified.jsonEscape(allocator, absolute_path);
    defer allocator.free(escaped_path);
    const count = try server_mount_graph_io.writeResponseCount(chunk.len);
    const eof = server_mount_graph_io.readIsEof(
        offset,
        requested_length_field,
        requested_length,
        chunk.len,
        max_mount_graph_materialized_file_bytes,
    );

    return std.fmt.allocPrint(
        allocator,
        "{{\"path\":\"{s}\",\"offset\":{d},\"n\":{d},\"eof\":{},\"data_b64\":\"{s}\"}}",
        .{ escaped_path, offset, count, eof, encoded },
    );
}

pub fn handleMountFileWriteControl(
    allocator: std.mem.Allocator,
    runtime_registry: anytype,
    namespace_session: *?acheron_session_mod.Session,
    binding: server_session_bindings.SessionBinding,
    session_key: []const u8,
    trusted_namespace_mount_url: ?[]const u8,
    is_admin: bool,
    payload_json: ?[]const u8,
) ![]u8 {
    var payload = try parseControlPayloadObject(allocator, payload_json);
    defer payload.deinit();
    if (payload.value != .object) return error.InvalidPayload;

    const absolute_path = try getRequiredStringField(payload.value.object, "path");
    const data_b64 = try getRequiredStringFieldAllowEmpty(payload.value.object, "data_b64");
    const offset = getOptionalU64Field(payload.value.object, "offset") orelse 0;
    const truncate_to_size = getOptionalU64Field(payload.value.object, "truncate_to_size");
    const decoded = try decodeStandardBase64Owned(allocator, data_b64);
    defer allocator.free(decoded);

    const session = try server_namespace_sessions.getOrInitNamespaceSessionForBinding(
        allocator,
        namespace_session,
        runtime_registry,
        binding,
        session_key,
        trusted_namespace_mount_url,
        is_admin,
    );
    const existing = try session.tryReadInternalPath(absolute_path);
    defer if (existing) |value| allocator.free(value);
    const merged = try server_mount_graph_io.materializeWriteData(
        allocator,
        existing,
        offset,
        decoded,
        truncate_to_size,
        max_mount_graph_materialized_file_bytes,
    );
    defer allocator.free(merged);

    if (existing == null and try session.tryWriteLocalFsBackedMountFile(absolute_path, merged)) {
        const escaped_path = try unified.jsonEscape(allocator, absolute_path);
        defer allocator.free(escaped_path);
        const count = try server_mount_graph_io.writeResponseCount(decoded.len);
        return std.fmt.allocPrint(
            allocator,
            "{{\"path\":\"{s}\",\"offset\":{d},\"n\":{d}}}",
            .{ escaped_path, offset, count },
        );
    }

    if (try session.tryWriteBoundVenomProxyMountFile(absolute_path, merged)) {
        const escaped_path = try unified.jsonEscape(allocator, absolute_path);
        defer allocator.free(escaped_path);
        const count = try server_mount_graph_io.writeResponseCount(decoded.len);
        return std.fmt.allocPrint(
            allocator,
            "{{\"path\":\"{s}\",\"offset\":{d},\"n\":{d}}}",
            .{ escaped_path, offset, count },
        );
    }

    try session.writeMountGraphFile(absolute_path, merged);

    const escaped_path = try unified.jsonEscape(allocator, absolute_path);
    defer allocator.free(escaped_path);
    const count = try server_mount_graph_io.writeResponseCount(decoded.len);
    return std.fmt.allocPrint(
        allocator,
        "{{\"path\":\"{s}\",\"offset\":{d},\"n\":{d}}}",
        .{ escaped_path, offset, count },
    );
}

pub fn handleMountPathControl(
    allocator: std.mem.Allocator,
    runtime_registry: anytype,
    namespace_session: *?acheron_session_mod.Session,
    binding: server_session_bindings.SessionBinding,
    session_key: []const u8,
    trusted_namespace_mount_url: ?[]const u8,
    is_admin: bool,
    payload_json: ?[]const u8,
    control_type: unified.ControlType,
) ![]u8 {
    var payload = try parseControlPayloadObject(allocator, payload_json);
    defer payload.deinit();
    if (payload.value != .object) return error.InvalidPayload;

    const session = try server_namespace_sessions.getOrInitNamespaceSessionForBinding(
        allocator,
        namespace_session,
        runtime_registry,
        binding,
        session_key,
        trusted_namespace_mount_url,
        is_admin,
    );

    switch (control_type) {
        .mount_path_readlink => {
            const absolute_path = try getRequiredStringField(payload.value.object, "path");
            const target = (try session.tryReadlinkLocalFsBackedMountPath(absolute_path)) orelse return error.OperationNotSupported;
            defer allocator.free(target);
            const escaped_path = try unified.jsonEscape(allocator, absolute_path);
            defer allocator.free(escaped_path);
            const escaped_target = try unified.jsonEscape(allocator, target);
            defer allocator.free(escaped_target);
            return std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"target\":\"{s}\"}}", .{ escaped_path, escaped_target });
        },
        .mount_path_mkdir => {
            const absolute_path = try getRequiredStringField(payload.value.object, "path");
            if (!(try session.tryMkdirLocalFsBackedMountPath(absolute_path))) return error.OperationNotSupported;
            const escaped_path = try unified.jsonEscape(allocator, absolute_path);
            defer allocator.free(escaped_path);
            return std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\"}}", .{escaped_path});
        },
        .mount_path_unlink => {
            const absolute_path = try getRequiredStringField(payload.value.object, "path");
            if (!(try session.tryUnlinkLocalFsBackedMountPath(absolute_path))) return error.OperationNotSupported;
            const escaped_path = try unified.jsonEscape(allocator, absolute_path);
            defer allocator.free(escaped_path);
            return std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\"}}", .{escaped_path});
        },
        .mount_path_rmdir => {
            const absolute_path = try getRequiredStringField(payload.value.object, "path");
            if (!(try session.tryRmdirLocalFsBackedMountPath(absolute_path))) return error.OperationNotSupported;
            const escaped_path = try unified.jsonEscape(allocator, absolute_path);
            defer allocator.free(escaped_path);
            return std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\"}}", .{escaped_path});
        },
        .mount_path_rename => {
            const old_path = try getRequiredStringField(payload.value.object, "old_path");
            const new_path = try getRequiredStringField(payload.value.object, "new_path");
            if (!(try session.tryRenameLocalFsBackedMountPath(old_path, new_path))) return error.OperationNotSupported;
            const escaped_old_path = try unified.jsonEscape(allocator, old_path);
            defer allocator.free(escaped_old_path);
            const escaped_new_path = try unified.jsonEscape(allocator, new_path);
            defer allocator.free(escaped_new_path);
            return std.fmt.allocPrint(allocator, "{{\"old_path\":\"{s}\",\"new_path\":\"{s}\"}}", .{ escaped_old_path, escaped_new_path });
        },
        .mount_path_symlink => {
            const target = try getRequiredStringField(payload.value.object, "target");
            const link_path = try getRequiredStringField(payload.value.object, "link_path");
            if (!(try session.trySymlinkLocalFsBackedMountPath(target, link_path))) return error.OperationNotSupported;
            const escaped_target = try unified.jsonEscape(allocator, target);
            defer allocator.free(escaped_target);
            const escaped_link_path = try unified.jsonEscape(allocator, link_path);
            defer allocator.free(escaped_link_path);
            return std.fmt.allocPrint(allocator, "{{\"target\":\"{s}\",\"link_path\":\"{s}\"}}", .{ escaped_target, escaped_link_path });
        },
        .mount_path_setxattr => {
            const absolute_path = try getRequiredStringField(payload.value.object, "path");
            const name = try getRequiredStringField(payload.value.object, "name");
            const value_b64 = try getRequiredStringFieldAllowEmpty(payload.value.object, "value_b64");
            const value = try decodeStandardBase64Owned(allocator, value_b64);
            defer allocator.free(value);
            const flags = getOptionalU32Field(payload.value.object, "flags") orelse 0;
            if (!(try session.trySetxattrLocalFsBackedMountPath(absolute_path, name, value, flags))) return error.OperationNotSupported;
            const escaped_path = try unified.jsonEscape(allocator, absolute_path);
            defer allocator.free(escaped_path);
            const escaped_name = try unified.jsonEscape(allocator, name);
            defer allocator.free(escaped_name);
            return std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"name\":\"{s}\"}}", .{ escaped_path, escaped_name });
        },
        .mount_path_getxattr => {
            const absolute_path = try getRequiredStringField(payload.value.object, "path");
            const name = try getRequiredStringField(payload.value.object, "name");
            const value = (try session.tryGetxattrLocalFsBackedMountPath(absolute_path, name)) orelse return error.OperationNotSupported;
            defer allocator.free(value);
            const escaped_path = try unified.jsonEscape(allocator, absolute_path);
            defer allocator.free(escaped_path);
            const escaped_name = try unified.jsonEscape(allocator, name);
            defer allocator.free(escaped_name);
            const encoded = try server_mount_graph_io.encodeStandardBase64Owned(allocator, value);
            defer allocator.free(encoded);
            return std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"name\":\"{s}\",\"value_b64\":\"{s}\"}}", .{ escaped_path, escaped_name, encoded });
        },
        .mount_path_listxattr => {
            const absolute_path = try getRequiredStringField(payload.value.object, "path");
            const names = (try session.tryListxattrLocalFsBackedMountPath(absolute_path)) orelse return error.OperationNotSupported;
            defer allocator.free(names);
            const escaped_path = try unified.jsonEscape(allocator, absolute_path);
            defer allocator.free(escaped_path);
            var out = std.ArrayListUnmanaged(u8){};
            errdefer out.deinit(allocator);
            try out.writer(allocator).print("{{\"path\":\"{s}\",\"names\":[", .{escaped_path});
            var first = true;
            var idx: usize = 0;
            while (idx < names.len) {
                const start = idx;
                while (idx < names.len and names[idx] != 0) : (idx += 1) {}
                if (idx > start) {
                    const escaped_name = try unified.jsonEscape(allocator, names[start..idx]);
                    defer allocator.free(escaped_name);
                    if (!first) try out.append(allocator, ',');
                    first = false;
                    try out.writer(allocator).print("\"{s}\"", .{escaped_name});
                }
                idx += 1;
            }
            try out.appendSlice(allocator, "]}");
            return out.toOwnedSlice(allocator);
        },
        .mount_path_removexattr => {
            const absolute_path = try getRequiredStringField(payload.value.object, "path");
            const name = try getRequiredStringField(payload.value.object, "name");
            if (!(try session.tryRemovexattrLocalFsBackedMountPath(absolute_path, name))) return error.OperationNotSupported;
            const escaped_path = try unified.jsonEscape(allocator, absolute_path);
            defer allocator.free(escaped_path);
            const escaped_name = try unified.jsonEscape(allocator, name);
            defer allocator.free(escaped_name);
            return std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"name\":\"{s}\"}}", .{ escaped_path, escaped_name });
        },
        .mount_path_lock => {
            const absolute_path = try getRequiredStringField(payload.value.object, "path");
            const mode = try getRequiredStringField(payload.value.object, "mode");
            const wait = getOptionalBoolField(payload.value.object, "wait") orelse true;
            if (!(try session.tryLockLocalFsBackedMountPath(absolute_path, mode, wait))) return error.OperationNotSupported;
            const escaped_path = try unified.jsonEscape(allocator, absolute_path);
            defer allocator.free(escaped_path);
            const escaped_mode = try unified.jsonEscape(allocator, mode);
            defer allocator.free(escaped_mode);
            return std.fmt.allocPrint(
                allocator,
                "{{\"path\":\"{s}\",\"mode\":\"{s}\",\"wait\":{s}}}",
                .{ escaped_path, escaped_mode, if (wait) "true" else "false" },
            );
        },
        .mount_path_setattr => {
            const absolute_path = try getRequiredStringField(payload.value.object, "path");
            const mode = getOptionalU32Field(payload.value.object, "mode");
            const uid = getOptionalU32Field(payload.value.object, "uid");
            const gid = getOptionalU32Field(payload.value.object, "gid");
            const flags = getOptionalU32Field(payload.value.object, "flags");
            const at_ns = getOptionalI64Field(payload.value.object, "at_ns");
            const mt_ns = getOptionalI64Field(payload.value.object, "mt_ns");
            if (!(try session.trySetattrLocalFsBackedMountPath(absolute_path, mode, uid, gid, flags, at_ns, mt_ns))) {
                return error.OperationNotSupported;
            }
            const escaped_path = try unified.jsonEscape(allocator, absolute_path);
            defer allocator.free(escaped_path);
            return std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\"}}", .{escaped_path});
        },
        else => return error.InvalidPayload,
    }
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
