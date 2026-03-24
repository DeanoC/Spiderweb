const std = @import("std");
const unified = @import("spider-protocol").unified;
const control_plane_mod = @import("../acheron/control_plane.zig");

pub const Op = enum {
    ensure,
};

const default_home_root = "/nodes/local/fs/.spiderweb/agents";

pub fn seedNamespace(self: anytype, home_dir: u32) !void {
    return seedNamespaceAt(self, home_dir, "/.spiderweb/_compat/global/home");
}

pub fn seedNamespaceAt(self: anytype, home_dir: u32, base_path: []const u8) !void {
    const escaped_base_path = try unified.jsonEscape(self.allocator, base_path);
    defer self.allocator.free(escaped_base_path);
    const shape_json = try std.fmt.allocPrint(
        self.allocator,
        "{{\"kind\":\"venom\",\"venom_id\":\"home\",\"shape\":\"{s}/{{README.md,SCHEMA.json,CAPS.json,OPS.json,PERMISSIONS.json,STATUS.json,status.json,result.json,control/*}}\"}}",
        .{escaped_base_path},
    );
    defer self.allocator.free(shape_json);
    try self.addDirectoryDescriptors(
        home_dir,
        "Agent Home",
        shape_json,
        "{\"invoke\":true,\"operations\":[\"home_ensure\"],\"discoverable\":true,\"project_scope\":true}",
        "Provision a durable per-agent home path inside the mounted workspace namespace.",
    );
    _ = try self.addFile(
        home_dir,
        "OPS.json",
        "{\"model\":\"local_bridge\",\"invoke\":\"control/invoke.json\",\"transport\":\"acheron-local\",\"paths\":{\"ensure\":\"control/ensure.json\"},\"operations\":{\"ensure\":\"home_ensure\"}}",
        false,
        .none,
    );
    _ = try self.addFile(
        home_dir,
        "RUNTIME.json",
        "{\"type\":\"acheron_local\",\"component\":\"acheron_session\",\"subject\":\"agent_home\"}",
        false,
        .none,
    );
    _ = try self.addFile(
        home_dir,
        "PERMISSIONS.json",
        "{\"default\":\"allow-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"scope\":\"project\",\"project_token_required\":false}",
        false,
        .none,
    );
    _ = try self.addFile(
        home_dir,
        "STATUS.json",
        "{\"venom_id\":\"home\",\"state\":\"namespace\",\"has_invoke\":true}",
        false,
        .none,
    );
    self.home_status_id = try self.addFile(
        home_dir,
        "status.json",
        "{\"state\":\"idle\",\"tool\":null,\"updated_at_ms\":0,\"error\":null}",
        false,
        .none,
    );
    const initial_result = try buildSuccessResultJson(
        self,
        .ensure,
        "{\"ok\":false,\"home_path\":null,\"target_path\":null}",
    );
    defer self.allocator.free(initial_result);
    self.home_result_id = try self.addFile(
        home_dir,
        "result.json",
        initial_result,
        false,
        .none,
    );

    const control_dir = try self.addDir(home_dir, "control", false);
    _ = try self.addFile(
        control_dir,
        "README.md",
        "Write the JSON payload in ensure.json to provision /home/<agent_id> as a durable bind into the mounted workspace.\n",
        false,
        .none,
    );
    _ = try self.addFile(control_dir, "invoke.json", "", true, .home_invoke);
    const ensure_template = try buildEnsureTemplateJson(self);
    defer self.allocator.free(ensure_template);
    _ = try self.addFile(control_dir, "ensure.json", ensure_template, true, .home_ensure);
}

pub fn handleNamespaceWrite(self: anytype, special: anytype, node_id: u32, raw_input: []const u8) !usize {
    const input = std.mem.trim(u8, raw_input, " \t\r\n");
    const payload = if (input.len == 0) "{}" else input;
    try self.setFileContent(node_id, payload);

    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch return error.InvalidPayload;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    const obj = parsed.value.object;

    const op = switch (special) {
        .home_ensure => Op.ensure,
        .home_invoke => blk: {
            const op_raw = blk2: {
                if (obj.get("op")) |value| if (value == .string and value.string.len > 0) break :blk2 value.string;
                if (obj.get("operation")) |value| if (value == .string and value.string.len > 0) break :blk2 value.string;
                if (obj.get("tool")) |value| if (value == .string and value.string.len > 0) break :blk2 value.string;
                if (obj.get("tool_name")) |value| if (value == .string and value.string.len > 0) break :blk2 value.string;
                break :blk2 null;
            } orelse return error.InvalidPayload;
            break :blk parseOp(op_raw) orelse return error.InvalidPayload;
        },
        else => return error.InvalidPayload,
    };

    const args_obj = blk: {
        if (obj.get("arguments")) |value| {
            if (value != .object) return error.InvalidPayload;
            break :blk value.object;
        }
        if (obj.get("args")) |value| {
            if (value != .object) return error.InvalidPayload;
            break :blk value.object;
        }
        break :blk obj;
    };

    return executeOp(self, op, args_obj, raw_input.len);
}

fn parseOp(raw: []const u8) ?Op {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.eql(u8, value, "ensure") or std.mem.eql(u8, value, "home_ensure")) return .ensure;
    return null;
}

fn executeOp(self: anytype, op: Op, args_obj: std.json.ObjectMap, written: usize) !usize {
    const tool_name = "home_ensure";
    const running_status = try self.buildServiceInvokeStatusJson("running", tool_name, null);
    defer self.allocator.free(running_status);
    try self.setMirroredFileContent(self.home_status_id, self.home_status_alias_id, running_status);

    const result_payload = executeOpPayload(self, op, args_obj) catch |err| {
        const failed_status = try self.buildServiceInvokeStatusJson("failed", tool_name, @errorName(err));
        defer self.allocator.free(failed_status);
        try self.setMirroredFileContent(self.home_status_id, self.home_status_alias_id, failed_status);
        const error_code = switch (err) {
            error.AccessDenied => "forbidden",
            else => "invalid_payload",
        };
        const failed_result = try buildFailureResultJson(self, op, error_code, @errorName(err));
        defer self.allocator.free(failed_result);
        try self.setMirroredFileContent(self.home_result_id, self.home_result_alias_id, failed_result);
        return err;
    };
    defer self.allocator.free(result_payload);

    const done_status = try self.buildServiceInvokeStatusJson("done", tool_name, null);
    defer self.allocator.free(done_status);
    try self.setMirroredFileContent(self.home_status_id, self.home_status_alias_id, done_status);
    try self.setMirroredFileContent(self.home_result_id, self.home_result_alias_id, result_payload);
    return written;
}

fn executeOpPayload(self: anytype, op: Op, args_obj: std.json.ObjectMap) ![]u8 {
    _ = op;
    const agent_id = extractOptionalStringByNames(args_obj, &[_][]const u8{"agent_id"}) orelse self.agent_id;
    if (!isValidIdentifier(agent_id)) return error.InvalidPayload;
    const project_id = extractOptionalStringByNames(args_obj, &[_][]const u8{"workspace_id"}) orelse self.workspace_id orelse return error.InvalidPayload;
    const project_token = extractOptionalStringByNames(args_obj, &[_][]const u8{"workspace_token"}) orelse self.workspace_token;

    const bind_path = if (extractOptionalStringByNames(args_obj, &[_][]const u8{ "bind_path", "home_path" })) |value| blk: {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidPayload;
        break :blk try self.allocator.dupe(u8, trimmed);
    } else try std.fmt.allocPrint(self.allocator, "/home/{s}", .{agent_id});
    defer self.allocator.free(bind_path);

    const target_path = if (extractOptionalStringByNames(args_obj, &[_][]const u8{"target_path"})) |value| blk: {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidPayload;
        break :blk try self.allocator.dupe(u8, trimmed);
    } else try std.fmt.allocPrint(self.allocator, "{s}/{s}/home", .{ default_home_root, agent_id });
    defer self.allocator.free(target_path);

    const payload = try buildScopedBindPayload(self.allocator, project_id, project_token, bind_path, target_path);
    defer self.allocator.free(payload);

    const plane = self.control_plane orelse return error.InvalidPayload;
    _ = plane.setWorkspaceBindWithRole(payload, self.is_admin) catch |err| switch (err) {
        control_plane_mod.ControlPlaneError.WorkspacePolicyForbidden,
        control_plane_mod.ControlPlaneError.WorkspaceAuthFailed,
        control_plane_mod.ControlPlaneError.WorkspaceProtected,
        control_plane_mod.ControlPlaneError.WorkspaceAssignmentForbidden,
        => return error.AccessDenied,
        control_plane_mod.ControlPlaneError.MissingField,
        control_plane_mod.ControlPlaneError.InvalidPayload,
        control_plane_mod.ControlPlaneError.WorkspaceNotFound,
        control_plane_mod.ControlPlaneError.BindConflict,
        => return error.InvalidPayload,
        else => return err,
    };

    try self.refreshWorkspaceBindsFromControlPlane();
    return buildEnsureResultJson(self, agent_id, project_id, bind_path, target_path);
}

fn buildEnsureTemplateJson(self: anytype) ![]u8 {
    const escaped_agent_id = try unified.jsonEscape(self.allocator, self.agent_id);
    defer self.allocator.free(escaped_agent_id);
    const project_id = self.workspace_id orelse "";
    const escaped_project_id = try unified.jsonEscape(self.allocator, project_id);
    defer self.allocator.free(escaped_project_id);
    return std.fmt.allocPrint(
        self.allocator,
        "{{\"agent_id\":\"{s}\",\"workspace_id\":\"{s}\"}}",
        .{ escaped_agent_id, escaped_project_id },
    );
}

fn buildScopedBindPayload(
    allocator: std.mem.Allocator,
    project_id: []const u8,
    project_token: ?[]const u8,
    bind_path: []const u8,
    target_path: []const u8,
) ![]u8 {
    const escaped_project_id = try unified.jsonEscape(allocator, project_id);
    defer allocator.free(escaped_project_id);
    const escaped_bind_path = try unified.jsonEscape(allocator, bind_path);
    defer allocator.free(escaped_bind_path);
    const escaped_target_path = try unified.jsonEscape(allocator, target_path);
    defer allocator.free(escaped_target_path);
    const token_fragment = if (project_token) |token| blk: {
        const escaped = try unified.jsonEscape(allocator, token);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(allocator, ",\"workspace_token\":\"{s}\"", .{escaped});
    } else try allocator.dupe(u8, "");
    defer allocator.free(token_fragment);
    return std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\"{s},\"bind_path\":\"{s}\",\"target_path\":\"{s}\"}}",
        .{ escaped_project_id, token_fragment, escaped_bind_path, escaped_target_path },
    );
}

fn buildEnsureResultJson(
    self: anytype,
    agent_id: []const u8,
    project_id: []const u8,
    bind_path: []const u8,
    target_path: []const u8,
) ![]u8 {
    const state_path = try std.fmt.allocPrint(self.allocator, "{s}/state", .{bind_path});
    defer self.allocator.free(state_path);
    const cache_path = try std.fmt.allocPrint(self.allocator, "{s}/cache", .{bind_path});
    defer self.allocator.free(cache_path);
    const binds_path = try std.fmt.allocPrint(self.allocator, "{s}/binds", .{bind_path});
    defer self.allocator.free(binds_path);

    const escaped_agent_id = try unified.jsonEscape(self.allocator, agent_id);
    defer self.allocator.free(escaped_agent_id);
    const escaped_project_id = try unified.jsonEscape(self.allocator, project_id);
    defer self.allocator.free(escaped_project_id);
    const escaped_bind_path = try unified.jsonEscape(self.allocator, bind_path);
    defer self.allocator.free(escaped_bind_path);
    const escaped_target_path = try unified.jsonEscape(self.allocator, target_path);
    defer self.allocator.free(escaped_target_path);
    const escaped_state_path = try unified.jsonEscape(self.allocator, state_path);
    defer self.allocator.free(escaped_state_path);
    const escaped_cache_path = try unified.jsonEscape(self.allocator, cache_path);
    defer self.allocator.free(escaped_cache_path);
    const escaped_binds_path = try unified.jsonEscape(self.allocator, binds_path);
    defer self.allocator.free(escaped_binds_path);

    const payload = try std.fmt.allocPrint(
        self.allocator,
        "{{\"ok\":true,\"operation\":\"ensure\",\"agent_id\":\"{s}\",\"workspace_id\":\"{s}\",\"home_path\":\"{s}\",\"target_path\":\"{s}\",\"recommended_paths\":{{\"state\":\"{s}\",\"cache\":\"{s}\",\"binds\":\"{s}\"}}}}",
        .{ escaped_agent_id, escaped_project_id, escaped_bind_path, escaped_target_path, escaped_state_path, escaped_cache_path, escaped_binds_path },
    );
    defer self.allocator.free(payload);
    return buildSuccessResultJson(self, .ensure, payload);
}

fn buildSuccessResultJson(self: anytype, op: Op, payload_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        self.allocator,
        "{{\"ok\":true,\"operation\":\"{s}\",\"result\":{s}}}",
        .{ operationName(op), payload_json },
    );
}

fn buildFailureResultJson(self: anytype, op: Op, error_code: []const u8, error_message: []const u8) ![]u8 {
    const escaped_message = try unified.jsonEscape(self.allocator, error_message);
    defer self.allocator.free(escaped_message);
    return std.fmt.allocPrint(
        self.allocator,
        "{{\"ok\":false,\"operation\":\"{s}\",\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}",
        .{ operationName(op), error_code, escaped_message },
    );
}

fn operationName(op: Op) []const u8 {
    return switch (op) {
        .ensure => "ensure",
    };
}

fn extractOptionalStringByNames(obj: std.json.ObjectMap, candidate_names: []const []const u8) ?[]const u8 {
    for (candidate_names) |field| {
        if (obj.get(field)) |value| {
            if (value == .string and value.string.len > 0) return value.string;
        }
    }
    return null;
}

fn isValidIdentifier(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |char| {
        if (std.ascii.isAlphanumeric(char)) continue;
        if (char == '-' or char == '_' or char == '.') continue;
        return false;
    }
    return true;
}
