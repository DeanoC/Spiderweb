const std = @import("std");
const unified = @import("spider-protocol").unified;
const venom_packages = @import("../venom_packages.zig");
const control_plane_mod = @import("../acheron/control_plane.zig");

pub const Op = enum {
    list,
    get,
    install,
    enable,
    switch_release,
    disable,
    rollback,
    remove,
};

pub fn seedNamespace(self: anytype, packages_dir: u32) !void {
    return seedNamespaceAt(self, packages_dir, "/.spiderweb/_compat/global/packages");
}

pub fn seedNamespaceAt(self: anytype, packages_dir: u32, base_path: []const u8) !void {
    const escaped_base_path = try unified.jsonEscape(self.allocator, base_path);
    defer self.allocator.free(escaped_base_path);
    const shape_json = try std.fmt.allocPrint(
        self.allocator,
        "{{\"kind\":\"control_substrate\",\"surface_id\":\"packages\",\"shape\":\"{s}/{{README.md,SCHEMA.json,CAPS.json,OPS.json,PERMISSIONS.json,STATUS.json,status.json,result.json,control/*}}\"}}",
        .{escaped_base_path},
    );
    defer self.allocator.free(shape_json);
    try self.addDirectoryDescriptors(
        packages_dir,
        "Packages",
        shape_json,
        "{\"invoke\":true,\"operations\":[\"packages_list\",\"packages_get\",\"packages_install\",\"packages_enable\",\"packages_switch\",\"packages_disable\",\"packages_rollback\",\"packages_remove\"],\"discoverable\":true}",
        "List, inspect, install, enable, switch, disable, rollback, and remove package definitions available to this Spiderweb host.",
    );
    _ = try self.addFile(
        packages_dir,
        "OPS.json",
        "{\"model\":\"local_bridge\",\"invoke\":\"control/invoke.json\",\"transport\":\"namespace-local\",\"paths\":{\"list\":\"control/list.json\",\"get\":\"control/get.json\",\"install\":\"control/install.json\",\"enable\":\"control/enable.json\",\"switch\":\"control/switch.json\",\"disable\":\"control/disable.json\",\"rollback\":\"control/rollback.json\",\"remove\":\"control/remove.json\"},\"operations\":{\"list\":\"packages_list\",\"get\":\"packages_get\",\"install\":\"packages_install\",\"enable\":\"packages_enable\",\"switch\":\"packages_switch\",\"disable\":\"packages_disable\",\"rollback\":\"packages_rollback\",\"remove\":\"packages_remove\"}}",
        false,
        .none,
    );
    _ = try self.addFile(
        packages_dir,
        "RUNTIME.json",
        "{\"type\":\"namespace_local\",\"component\":\"namespace_session\",\"subject\":\"package_registry\"}",
        false,
        .none,
    );
    _ = try self.addFile(
        packages_dir,
        "PERMISSIONS.json",
        "{\"default\":\"allow-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"scope\":\"workspace_control_plane\"}",
        false,
        .none,
    );
    _ = try self.addFile(
        packages_dir,
        "STATUS.json",
        "{\"surface_id\":\"packages\",\"state\":\"namespace\",\"has_invoke\":true}",
        false,
        .none,
    );
    self.packages_status_id = try self.addFile(
        packages_dir,
        "status.json",
        "{\"state\":\"idle\",\"tool\":null,\"updated_at_ms\":0,\"error\":null}",
        false,
        .none,
    );
    const initial_result = try buildListResultJson(self);
    defer self.allocator.free(initial_result);
    self.packages_result_id = try self.addFile(
        packages_dir,
        "result.json",
        initial_result,
        false,
        .none,
    );

    const control_dir = try self.addDir(packages_dir, "control", false);
    _ = try self.addFile(
        control_dir,
        "README.md",
        "Use list/get/install/enable/switch/disable/rollback/remove operation files, or invoke.json with op=list|get|install|enable|switch|disable|rollback|remove plus arguments.\n",
        false,
        .none,
    );
    _ = try self.addFile(control_dir, "invoke.json", "", true, .packages_invoke);
    _ = try self.addFile(control_dir, "list.json", "", true, .packages_list);
    _ = try self.addFile(control_dir, "get.json", "", true, .packages_get);
    _ = try self.addFile(control_dir, "install.json", "", true, .packages_install);
    _ = try self.addFile(control_dir, "enable.json", "", true, .packages_enable);
    _ = try self.addFile(control_dir, "switch.json", "", true, .packages_switch);
    _ = try self.addFile(control_dir, "disable.json", "", true, .packages_disable);
    _ = try self.addFile(control_dir, "rollback.json", "", true, .packages_rollback);
    _ = try self.addFile(control_dir, "remove.json", "", true, .packages_remove);
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
        .packages_list => Op.list,
        .packages_get => Op.get,
        .packages_install => Op.install,
        .packages_enable => Op.enable,
        .packages_switch => Op.switch_release,
        .packages_disable => Op.disable,
        .packages_rollback => Op.rollback,
        .packages_remove => Op.remove,
        .packages_invoke => blk: {
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

    return executeOp(self, op, args_obj, payload);
}

fn parseOp(raw: []const u8) ?Op {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.eql(u8, value, "list") or std.mem.eql(u8, value, "packages_list")) return .list;
    if (std.mem.eql(u8, value, "get") or std.mem.eql(u8, value, "packages_get")) return .get;
    if (std.mem.eql(u8, value, "install") or std.mem.eql(u8, value, "packages_install")) return .install;
    if (std.mem.eql(u8, value, "enable") or std.mem.eql(u8, value, "packages_enable")) return .enable;
    if (std.mem.eql(u8, value, "switch") or std.mem.eql(u8, value, "packages_switch")) return .switch_release;
    if (std.mem.eql(u8, value, "disable") or std.mem.eql(u8, value, "packages_disable")) return .disable;
    if (std.mem.eql(u8, value, "rollback") or std.mem.eql(u8, value, "packages_rollback")) return .rollback;
    if (std.mem.eql(u8, value, "remove") or std.mem.eql(u8, value, "packages_remove")) return .remove;
    return null;
}

fn executeOp(self: anytype, op: Op, args_obj: std.json.ObjectMap, payload: []const u8) !usize {
    const tool_name = statusToolName(op);
    const running_status = try self.buildServiceInvokeStatusJson("running", tool_name, null);
    defer self.allocator.free(running_status);
    try self.setMirroredFileContent(self.packages_status_id, self.packages_status_alias_id, running_status);

    const result_payload = executeOpPayload(self, op, args_obj, payload) catch |err| {
        const error_code = switch (err) {
            error.AccessDenied => "forbidden",
            error.AlreadyExists => "already_exists",
            error.InvalidPayload => "invalid_payload",
            else => "invalid_payload",
        };
        const failed_status = try self.buildServiceInvokeStatusJson("failed", tool_name, @errorName(err));
        defer self.allocator.free(failed_status);
        try self.setMirroredFileContent(self.packages_status_id, self.packages_status_alias_id, failed_status);
        const failed_result = try buildFailureResultJson(self, op, error_code, @errorName(err));
        defer self.allocator.free(failed_result);
        try self.setMirroredFileContent(self.packages_result_id, self.packages_result_alias_id, failed_result);
        return err;
    };
    defer self.allocator.free(result_payload);

    const done_status = try self.buildServiceInvokeStatusJson("done", tool_name, null);
    defer self.allocator.free(done_status);
    try self.setMirroredFileContent(self.packages_status_id, self.packages_status_alias_id, done_status);
    try self.setMirroredFileContent(self.packages_result_id, self.packages_result_alias_id, result_payload);
    try self.refreshWorkspaceServiceDiscoveryFiles();
    return payload.len;
}

fn executeOpPayload(self: anytype, op: Op, args_obj: std.json.ObjectMap, payload: []const u8) ![]u8 {
    const plane = self.control_plane;
    return switch (op) {
        .list => buildListResultJson(self),
        .get => blk: {
            const venom_id = extractOptionalStringByNames(args_obj, &.{ "venom_id", "id" }) orelse return error.InvalidPayload;
            const request = try buildPackageSelectionRequestJson(self.allocator, venom_id, extractOptionalStringByNames(args_obj, &.{"release_version"}));
            defer self.allocator.free(request);
            const package_json = if (plane) |value|
                if (extractOptionalStringByNames(args_obj, &.{"release_version"}) != null)
                    value.getVenomRelease(request) catch |err| switch (err) {
                        control_plane_mod.ControlPlaneError.VenomPackageNotFound => return error.InvalidPayload,
                        control_plane_mod.ControlPlaneError.MissingField,
                        control_plane_mod.ControlPlaneError.InvalidPayload,
                        => return error.InvalidPayload,
                        else => return err,
                    }
                else
                    value.getVenomPackage(request) catch |err| switch (err) {
                        control_plane_mod.ControlPlaneError.VenomPackageNotFound => return error.InvalidPayload,
                        control_plane_mod.ControlPlaneError.MissingField,
                        control_plane_mod.ControlPlaneError.InvalidPayload,
                        => return error.InvalidPayload,
                        else => return err,
                    }
            else if (venom_packages.findBuiltinPackage(venom_id)) |spec|
                try venom_packages.renderPackageMetadataJson(self.allocator, spec)
            else
                return error.InvalidPayload;
            defer self.allocator.free(package_json);
            break :blk buildSingleResultJson(self, .get, if (extractOptionalStringByNames(args_obj, &.{"release_version"}) != null) "release" else "package", package_json);
        },
        .install => blk: {
            const control = plane orelse return error.InvalidPayload;
            const package_json = control.installVenomPackage(payload) catch |err| switch (err) {
                control_plane_mod.ControlPlaneError.AlreadyExists => return error.AlreadyExists,
                control_plane_mod.ControlPlaneError.VenomPackageBuiltinProtected => return error.AccessDenied,
                control_plane_mod.ControlPlaneError.InvalidPayload,
                control_plane_mod.ControlPlaneError.MissingField,
                => return error.InvalidPayload,
                else => return err,
            };
            defer self.allocator.free(package_json);
            break :blk buildSinglePackageResultJson(self, .install, package_json);
        },
        .enable => blk: {
            const control = plane orelse return error.InvalidPayload;
            const venom_id = extractOptionalStringByNames(args_obj, &.{ "venom_id", "id" }) orelse return error.InvalidPayload;
            const request = try buildPackageSelectionRequestJson(self.allocator, venom_id, extractOptionalStringByNames(args_obj, &.{"release_version"}));
            defer self.allocator.free(request);
            const package_json = control.enableVenomPackage(request) catch |err| switch (err) {
                control_plane_mod.ControlPlaneError.VenomPackageBuiltinProtected => return error.AccessDenied,
                control_plane_mod.ControlPlaneError.VenomPackageNotFound,
                control_plane_mod.ControlPlaneError.InvalidPayload,
                control_plane_mod.ControlPlaneError.MissingField,
                => return error.InvalidPayload,
                else => return err,
            };
            defer self.allocator.free(package_json);
            break :blk buildSinglePackageResultJson(self, .enable, package_json);
        },
        .switch_release => blk: {
            const control = plane orelse return error.InvalidPayload;
            const venom_id = extractOptionalStringByNames(args_obj, &.{ "venom_id", "id" }) orelse return error.InvalidPayload;
            const release_version = extractOptionalStringByNames(args_obj, &.{"release_version"}) orelse return error.InvalidPayload;
            const request = try buildPackageSelectionRequestJson(self.allocator, venom_id, release_version);
            defer self.allocator.free(request);
            const package_json = control.switchVenomRelease(request) catch |err| switch (err) {
                control_plane_mod.ControlPlaneError.VenomPackageBuiltinProtected => return error.AccessDenied,
                control_plane_mod.ControlPlaneError.VenomPackageNotFound,
                control_plane_mod.ControlPlaneError.InvalidPayload,
                control_plane_mod.ControlPlaneError.MissingField,
                => return error.InvalidPayload,
                else => return err,
            };
            defer self.allocator.free(package_json);
            break :blk buildSinglePackageResultJson(self, .switch_release, package_json);
        },
        .disable => blk: {
            const control = plane orelse return error.InvalidPayload;
            const venom_id = extractOptionalStringByNames(args_obj, &.{ "venom_id", "id" }) orelse return error.InvalidPayload;
            const request = try buildPackageSelectionRequestJson(self.allocator, venom_id, extractOptionalStringByNames(args_obj, &.{"release_version"}));
            defer self.allocator.free(request);
            const package_json = control.disableVenomPackage(request) catch |err| switch (err) {
                control_plane_mod.ControlPlaneError.VenomPackageBuiltinProtected => return error.AccessDenied,
                control_plane_mod.ControlPlaneError.VenomPackageNotFound,
                control_plane_mod.ControlPlaneError.InvalidPayload,
                control_plane_mod.ControlPlaneError.MissingField,
                => return error.InvalidPayload,
                else => return err,
            };
            defer self.allocator.free(package_json);
            break :blk buildSinglePackageResultJson(self, .disable, package_json);
        },
        .rollback => blk: {
            const control = plane orelse return error.InvalidPayload;
            const venom_id = extractOptionalStringByNames(args_obj, &.{ "venom_id", "id" }) orelse return error.InvalidPayload;
            const request = try buildPackageSelectionRequestJson(self.allocator, venom_id, extractOptionalStringByNames(args_obj, &.{"release_version"}));
            defer self.allocator.free(request);
            const package_json = control.rollbackVenomPackage(request) catch |err| switch (err) {
                control_plane_mod.ControlPlaneError.VenomPackageBuiltinProtected => return error.AccessDenied,
                control_plane_mod.ControlPlaneError.VenomPackageNotFound,
                control_plane_mod.ControlPlaneError.InvalidPayload,
                control_plane_mod.ControlPlaneError.MissingField,
                => return error.InvalidPayload,
                else => return err,
            };
            defer self.allocator.free(package_json);
            break :blk buildSinglePackageResultJson(self, .rollback, package_json);
        },
        .remove => blk: {
            const control = plane orelse return error.InvalidPayload;
            const venom_id = extractOptionalStringByNames(args_obj, &.{ "venom_id", "id" }) orelse return error.InvalidPayload;
            const request = try buildPackageSelectionRequestJson(self.allocator, venom_id, extractOptionalStringByNames(args_obj, &.{"release_version"}));
            defer self.allocator.free(request);
            const result_json = control.removeVenomPackage(request) catch |err| switch (err) {
                control_plane_mod.ControlPlaneError.VenomPackageBuiltinProtected => return error.AccessDenied,
                control_plane_mod.ControlPlaneError.VenomPackageNotFound,
                control_plane_mod.ControlPlaneError.InvalidPayload,
                control_plane_mod.ControlPlaneError.MissingField,
                => return error.InvalidPayload,
                else => return err,
            };
            defer self.allocator.free(result_json);
            break :blk buildSuccessResultJson(self, .remove, result_json);
        },
    };
}

fn buildListResultJson(self: anytype) ![]u8 {
    const packages_json = if (self.control_plane) |plane|
        try plane.listVenomPackages()
    else
        try venom_packages.buildPackagesJson(self.allocator);
    defer self.allocator.free(packages_json);
    const wrapped = if (self.control_plane) |plane| blk: {
        const releases_json = try plane.listVenomReleases();
        defer self.allocator.free(releases_json);
        break :blk try std.fmt.allocPrint(self.allocator, "{{\"packages\":{s},\"releases\":{s}}}", .{ packages_json, releases_json });
    } else try std.fmt.allocPrint(self.allocator, "{{\"packages\":{s}}}", .{packages_json});
    defer self.allocator.free(wrapped);
    return buildSuccessResultJson(self, .list, wrapped);
}

fn buildSinglePackageResultJson(self: anytype, op: Op, package_json: []const u8) ![]u8 {
    return buildSingleResultJson(self, op, "package", package_json);
}

fn buildSingleResultJson(self: anytype, op: Op, field_name: []const u8, json: []const u8) ![]u8 {
    const wrapped = try std.fmt.allocPrint(self.allocator, "{{\"{s}\":{s}}}", .{ field_name, json });
    defer self.allocator.free(wrapped);
    return buildSuccessResultJson(self, op, wrapped);
}

fn buildSuccessResultJson(self: anytype, op: Op, result_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        self.allocator,
        "{{\"ok\":true,\"operation\":\"{s}\",\"result\":{s}}}",
        .{ operationName(op), result_json },
    );
}

fn buildFailureResultJson(self: anytype, op: Op, code: []const u8, message: []const u8) ![]u8 {
    const escaped_code = try unified.jsonEscape(self.allocator, code);
    defer self.allocator.free(escaped_code);
    const escaped_message = try unified.jsonEscape(self.allocator, message);
    defer self.allocator.free(escaped_message);
    return std.fmt.allocPrint(
        self.allocator,
        "{{\"ok\":false,\"operation\":\"{s}\",\"result\":null,\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}",
        .{ operationName(op), escaped_code, escaped_message },
    );
}

fn buildPackageSelectionRequestJson(
    allocator: std.mem.Allocator,
    venom_id: []const u8,
    release_version: ?[]const u8,
) ![]u8 {
    if (release_version) |value| {
        return std.fmt.allocPrint(
            allocator,
            "{{\"venom_id\":\"{s}\",\"release_version\":\"{s}\"}}",
            .{ venom_id, value },
        );
    }
    return std.fmt.allocPrint(allocator, "{{\"venom_id\":\"{s}\"}}", .{venom_id});
}

fn operationName(op: Op) []const u8 {
    return switch (op) {
        .list => "list",
        .get => "get",
        .install => "install",
        .enable => "enable",
        .switch_release => "switch",
        .disable => "disable",
        .rollback => "rollback",
        .remove => "remove",
    };
}

fn statusToolName(op: Op) []const u8 {
    return switch (op) {
        .list => "packages_list",
        .get => "packages_get",
        .install => "packages_install",
        .enable => "packages_enable",
        .switch_release => "packages_switch",
        .disable => "packages_disable",
        .rollback => "packages_rollback",
        .remove => "packages_remove",
    };
}

fn extractOptionalStringByNames(obj: std.json.ObjectMap, names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        if (obj.get(name)) |value| {
            if (value == .string and value.string.len > 0) return value.string;
        }
    }
    return null;
}
