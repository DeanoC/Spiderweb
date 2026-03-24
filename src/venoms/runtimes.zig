const std = @import("std");
const unified = @import("spider-protocol").unified;

pub const Op = enum {
    register,
    heartbeat,
    detach,
};

const default_runtime_venoms = [_][]const u8{
    "memory",
    "sub_brains",
};
const default_runtime_ttl_ms: u64 = 30_000;

pub fn seedNamespace(self: anytype, runtimes_dir: u32) !void {
    return seedNamespaceAt(self, runtimes_dir, "/.spiderweb/_compat/global/runtimes");
}

pub fn seedNamespaceAt(self: anytype, runtimes_dir: u32, base_path: []const u8) !void {
    const escaped_base_path = try unified.jsonEscape(self.allocator, base_path);
    defer self.allocator.free(escaped_base_path);
    const shape_json = try std.fmt.allocPrint(
        self.allocator,
        "{{\"kind\":\"control_substrate\",\"surface_id\":\"runtimes\",\"shape\":\"{s}/{{README.md,SCHEMA.json,CAPS.json,OPS.json,PERMISSIONS.json,STATUS.json,status.json,result.json,control/*}}\"}}",
        .{escaped_base_path},
    );
    defer self.allocator.free(shape_json);
    try self.addDirectoryDescriptors(
        runtimes_dir,
        "Runtimes",
        shape_json,
        "{\"invoke\":true,\"operations\":[\"runtime_attach\",\"runtime_heartbeat\",\"runtime_detach\"],\"discoverable\":true,\"workspace_scope\":true}",
        "Attach an external runtime, heartbeat its lease, detach it, and project its private loopback venoms into /nodes/<runtime_id>/venoms/*.",
    );
    _ = try self.addFile(
        runtimes_dir,
        "OPS.json",
        "{\"model\":\"local_bridge\",\"invoke\":\"control/invoke.json\",\"transport\":\"acheron-local\",\"paths\":{\"register\":\"control/register.json\",\"heartbeat\":\"control/heartbeat.json\",\"detach\":\"control/detach.json\"},\"operations\":{\"register\":\"runtime_attach\",\"heartbeat\":\"runtime_heartbeat\",\"detach\":\"runtime_detach\"}}",
        false,
        .none,
    );
    _ = try self.addFile(
        runtimes_dir,
        "RUNTIME.json",
        "{\"type\":\"acheron_local\",\"component\":\"acheron_session\",\"subject\":\"runtime_attach_registry\"}",
        false,
        .none,
    );
    _ = try self.addFile(
        runtimes_dir,
        "PERMISSIONS.json",
        "{\"default\":\"allow-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"scope\":\"workspace\",\"workspace_token_required\":false}",
        false,
        .none,
    );
    _ = try self.addFile(
        runtimes_dir,
        "STATUS.json",
        "{\"surface_id\":\"runtimes\",\"state\":\"namespace\",\"has_invoke\":true}",
        false,
        .none,
    );
    self.runtimes_status_id = try self.addFile(
        runtimes_dir,
        "status.json",
        "{\"state\":\"idle\",\"tool\":null,\"updated_at_ms\":0,\"error\":null}",
        false,
        .none,
    );
    const initial_result = try buildSuccessResultJson(
        self,
        .register,
        "{\"ok\":false,\"node_id\":null,\"node_path\":null,\"venoms\":[],\"expires_at_ms\":0,\"detached\":false}",
    );
    defer self.allocator.free(initial_result);
    self.runtimes_result_id = try self.addFile(
        runtimes_dir,
        "result.json",
        initial_result,
        false,
        .none,
    );

    const control_dir = try self.addDir(runtimes_dir, "control", false);
    _ = try self.addFile(
        control_dir,
        "README.md",
        "Write attach or heartbeat payloads here to maintain a live runtime lease inside the mounted workspace.\n",
        false,
        .none,
    );
    _ = try self.addFile(control_dir, "invoke.json", "", true, .runtimes_invoke);
    _ = try self.addFile(control_dir, "register.json", "", true, .runtimes_register);
    _ = try self.addFile(control_dir, "heartbeat.json", "", true, .runtimes_heartbeat);
    _ = try self.addFile(control_dir, "detach.json", "", true, .runtimes_detach);
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
        .runtimes_register => Op.register,
        .runtimes_heartbeat => Op.heartbeat,
        .runtimes_detach => Op.detach,
        .runtimes_invoke => blk: {
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
    if (std.mem.eql(u8, value, "register") or std.mem.eql(u8, value, "attach") or std.mem.eql(u8, value, "workers_register") or std.mem.eql(u8, value, "runtime_attach")) return .register;
    if (std.mem.eql(u8, value, "heartbeat") or std.mem.eql(u8, value, "workers_heartbeat") or std.mem.eql(u8, value, "runtime_heartbeat")) return .heartbeat;
    if (std.mem.eql(u8, value, "detach") or std.mem.eql(u8, value, "workers_detach") or std.mem.eql(u8, value, "runtime_detach")) return .detach;
    return null;
}

fn executeOp(self: anytype, op: Op, args_obj: std.json.ObjectMap, written: usize) !usize {
    const tool_name = switch (op) {
        .register => "runtime_attach",
        .heartbeat => "runtime_heartbeat",
        .detach => "runtime_detach",
    };
    const running_status = try self.buildServiceInvokeStatusJson("running", tool_name, null);
    defer self.allocator.free(running_status);
    try self.setMirroredFileContent(self.runtimes_status_id, self.runtimes_status_alias_id, running_status);

    const result_payload = executeOpPayload(self, op, args_obj) catch |err| {
        const failed_status = try self.buildServiceInvokeStatusJson("failed", tool_name, @errorName(err));
        defer self.allocator.free(failed_status);
        try self.setMirroredFileContent(self.runtimes_status_id, self.runtimes_status_alias_id, failed_status);
        const failed_result = try buildFailureResultJson(self, op, "invalid_payload", @errorName(err));
        defer self.allocator.free(failed_result);
        try self.setMirroredFileContent(self.runtimes_result_id, self.runtimes_result_alias_id, failed_result);
        return err;
    };
    defer self.allocator.free(result_payload);

    const done_status = try self.buildServiceInvokeStatusJson("done", tool_name, null);
    defer self.allocator.free(done_status);
    try self.setMirroredFileContent(self.runtimes_status_id, self.runtimes_status_alias_id, done_status);
    try self.setMirroredFileContent(self.runtimes_result_id, self.runtimes_result_alias_id, result_payload);
    return written;
}

fn executeOpPayload(self: anytype, op: Op, args_obj: std.json.ObjectMap) ![]u8 {
    const runtime_id = extractOptionalStringByNames(args_obj, &[_][]const u8{ "runtime_id", "worker_id", "node_id" }) orelse return error.InvalidPayload;
    if (!isValidIdentifier(runtime_id)) return error.InvalidPayload;
    const agent_id = extractOptionalStringByNames(args_obj, &[_][]const u8{"agent_id"}) orelse self.agent_id;
    if (!isValidIdentifier(agent_id)) return error.InvalidPayload;
    const ttl_ms = extractOptionalU64(args_obj, "ttl_ms") orelse default_runtime_ttl_ms;

    if (op == .detach) {
        try self.detachRuntimeLoopbackNode(runtime_id);
        return buildDetachResultJson(self, runtime_id, agent_id);
    }

    var venoms = std.ArrayListUnmanaged([]const u8){};
    defer venoms.deinit(self.allocator);
    try appendRequestedVenoms(self.allocator, &venoms, args_obj);
    if (venoms.items.len == 0) return error.InvalidPayload;
    if (self.control_plane) |control_plane| {
        try control_plane.validateRuntimeVenomInstantiation(venoms.items);
    } else {
        for (venoms.items) |venom_id| {
            if (!isSupportedRuntimeVenom(venom_id)) return error.InvalidPayload;
        }
    }

    try self.recordRuntimeHeartbeat(runtime_id, agent_id, ttl_ms);
    try self.ensureRuntimeLoopbackNode(runtime_id, agent_id, venoms.items);
    return switch (op) {
        .register => buildRegisterResultJson(self, runtime_id, agent_id, venoms.items),
        .heartbeat => buildHeartbeatResultJson(self, runtime_id, agent_id, ttl_ms),
        .detach => unreachable,
    };
}

fn appendRequestedVenoms(
    allocator: std.mem.Allocator,
    venoms: *std.ArrayListUnmanaged([]const u8),
    args_obj: std.json.ObjectMap,
) !void {
    if (args_obj.get("venoms")) |value| {
        if (value != .array) return error.InvalidPayload;
        for (value.array.items) |item| {
            if (item != .string or item.string.len == 0) return error.InvalidPayload;
            try venoms.append(allocator, item.string);
        }
        return;
    }

    inline for (default_runtime_venoms) |venom_id| {
        try venoms.append(allocator, venom_id);
    }
}

pub fn seedPassiveRuntimeMemoryNamespaceAt(
    self: anytype,
    memory_dir: u32,
    base_path: []const u8,
    runtime_id: []const u8,
    agent_id: []const u8,
) !void {
    const escaped_base_path = try unified.jsonEscape(self.allocator, base_path);
    defer self.allocator.free(escaped_base_path);
    const shape_json = try std.fmt.allocPrint(
        self.allocator,
        "{{\"kind\":\"venom\",\"venom_id\":\"memory\",\"shape\":\"{s}/{{README.md,SCHEMA.json,CAPS.json,OPS.json,PERMISSIONS.json,STATUS.json,status.json,result.json,control/*,items/*}}\"}}",
        .{escaped_base_path},
    );
    defer self.allocator.free(shape_json);
    const runtime_json = try std.fmt.allocPrint(
        self.allocator,
        "{{\"type\":\"external_worker\",\"component\":\"spider_monkey\",\"subject\":\"runtime_memory\",\"runtime_id\":\"{s}\",\"agent_id\":\"{s}\"}}",
        .{ runtime_id, agent_id },
    );
    defer self.allocator.free(runtime_json);

    try ensureFile(self, memory_dir, "README.md", "Runtime-owned memory loopback surface. Spider Monkey manages these files directly inside the mounted workspace.\n", false, .none);
    try ensureFile(self, memory_dir, "SCHEMA.json", shape_json, false, .none);
    try ensureFile(self, memory_dir, "CAPS.json", "{\"invoke\":true,\"operations\":[\"memory_create\",\"memory_load\",\"memory_versions\",\"memory_mutate\",\"memory_evict\",\"memory_search\"],\"discoverable\":true,\"runtime_owned\":true}", false, .none);
    try ensureFile(self, memory_dir, "OPS.json", "{\"model\":\"filesystem_loopback\",\"invoke\":\"control/invoke.json\",\"transport\":\"filesystem\",\"paths\":{\"create\":\"control/create.json\",\"load\":\"control/load.json\",\"versions\":\"control/versions.json\",\"mutate\":\"control/mutate.json\",\"evict\":\"control/evict.json\",\"search\":\"control/search.json\"},\"operations\":{\"create\":\"create\",\"load\":\"load\",\"versions\":\"versions\",\"mutate\":\"mutate\",\"evict\":\"evict\",\"search\":\"search\"}}", false, .none);
    try ensureFile(self, memory_dir, "RUNTIME.json", runtime_json, false, .none);
    try ensureFile(self, memory_dir, "PERMISSIONS.json", "{\"default\":\"allow-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"scope\":\"worker\"}", false, .none);
    try ensureFile(self, memory_dir, "STATUS.json", "{\"venom_id\":\"memory\",\"state\":\"runtime_loopback\",\"has_invoke\":true,\"owner\":\"runtime\"}", false, .none);
    try ensureFile(self, memory_dir, "status.json", "{\"state\":\"idle\",\"tool\":null,\"updated_at_ms\":0,\"error\":null}", true, .none);
    try ensureFile(self, memory_dir, "result.json", "{\"ok\":false,\"result\":null,\"error\":null}", true, .none);

    const control_dir = if (self.lookupChild(memory_dir, "control")) |existing|
        existing
    else
        try self.addDir(memory_dir, "control", false);
    try ensureFile(self, control_dir, "README.md", "Spider Monkey watches and writes this loopback memory namespace directly.\n", false, .none);
    inline for ([_][]const u8{ "invoke.json", "create.json", "load.json", "versions.json", "mutate.json", "evict.json", "search.json" }) |name| {
        try ensureFile(self, control_dir, name, "", true, .none);
    }

    const items_dir = if (self.lookupChild(memory_dir, "items")) |existing|
        existing
    else
        try self.addDir(memory_dir, "items", true);
    _ = items_dir;
}

pub fn seedPassiveRuntimeSubBrainsNamespaceAt(
    self: anytype,
    sub_brains_dir: u32,
    base_path: []const u8,
    runtime_id: []const u8,
    agent_id: []const u8,
) !void {
    const escaped_base_path = try unified.jsonEscape(self.allocator, base_path);
    defer self.allocator.free(escaped_base_path);
    const shape_json = try std.fmt.allocPrint(
        self.allocator,
        "{{\"kind\":\"venom\",\"venom_id\":\"sub_brains\",\"shape\":\"{s}/{{README.md,SCHEMA.json,CAPS.json,OPS.json,PERMISSIONS.json,STATUS.json,status.json,result.json,control/*}}\"}}",
        .{escaped_base_path},
    );
    defer self.allocator.free(shape_json);
    const runtime_json = try std.fmt.allocPrint(
        self.allocator,
        "{{\"type\":\"external_worker\",\"component\":\"spider_monkey\",\"subject\":\"runtime_sub_brains\",\"runtime_id\":\"{s}\",\"agent_id\":\"{s}\"}}",
        .{ runtime_id, agent_id },
    );
    defer self.allocator.free(runtime_json);

    try ensureFile(self, sub_brains_dir, "README.md", "Runtime-owned sub-brains loopback surface. Spider Monkey manages sub-brain state from this mounted namespace.\n", false, .none);
    try ensureFile(self, sub_brains_dir, "SCHEMA.json", shape_json, false, .none);
    try ensureFile(self, sub_brains_dir, "CAPS.json", "{\"invoke\":true,\"operations\":[\"sub_brains_list\",\"sub_brains_upsert\",\"sub_brains_delete\"],\"discoverable\":true,\"runtime_owned\":true}", false, .none);
    try ensureFile(self, sub_brains_dir, "OPS.json", "{\"model\":\"filesystem_loopback\",\"invoke\":\"control/invoke.json\",\"transport\":\"filesystem\",\"paths\":{\"list\":\"control/list.json\",\"upsert\":\"control/upsert.json\",\"delete\":\"control/delete.json\"},\"operations\":{\"list\":\"list\",\"upsert\":\"upsert\",\"delete\":\"delete\"}}", false, .none);
    try ensureFile(self, sub_brains_dir, "RUNTIME.json", runtime_json, false, .none);
    try ensureFile(self, sub_brains_dir, "PERMISSIONS.json", "{\"default\":\"allow-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"scope\":\"worker\"}", false, .none);
    try ensureFile(self, sub_brains_dir, "STATUS.json", "{\"venom_id\":\"sub_brains\",\"state\":\"runtime_loopback\",\"has_invoke\":true,\"owner\":\"runtime\"}", false, .none);
    try ensureFile(self, sub_brains_dir, "status.json", "{\"state\":\"idle\",\"tool\":null,\"updated_at_ms\":0,\"error\":null}", true, .none);
    try ensureFile(self, sub_brains_dir, "result.json", "{\"ok\":false,\"result\":null,\"error\":null}", true, .none);

    const control_dir = if (self.lookupChild(sub_brains_dir, "control")) |existing|
        existing
    else
        try self.addDir(sub_brains_dir, "control", false);
    try ensureFile(self, control_dir, "README.md", "Spider Monkey watches and writes this loopback sub-brains namespace directly.\n", false, .none);
    inline for ([_][]const u8{ "invoke.json", "list.json", "upsert.json", "delete.json" }) |name| {
        try ensureFile(self, control_dir, name, "", true, .none);
    }
}

fn ensureFile(
    self: anytype,
    parent_id: u32,
    name: []const u8,
    content: []const u8,
    writable: bool,
    special: anytype,
) !void {
    if (self.lookupChild(parent_id, name) != null) return;
    _ = try self.addFile(parent_id, name, content, writable, special);
}

fn buildRegisterResultJson(self: anytype, runtime_id: []const u8, agent_id: []const u8, venoms: []const []const u8) ![]u8 {
    const node_path = try std.fmt.allocPrint(self.allocator, "/nodes/{s}", .{runtime_id});
    defer self.allocator.free(node_path);
    var venoms_json = std.ArrayListUnmanaged(u8){};
    defer venoms_json.deinit(self.allocator);
    try venoms_json.append(self.allocator, '[');
    for (venoms, 0..) |venom_id, idx| {
        if (idx != 0) try venoms_json.append(self.allocator, ',');
        const venom_path = try std.fmt.allocPrint(self.allocator, "/nodes/{s}/venoms/{s}", .{ runtime_id, venom_id });
        defer self.allocator.free(venom_path);
        const escaped_venom_id = try unified.jsonEscape(self.allocator, venom_id);
        defer self.allocator.free(escaped_venom_id);
        const escaped_venom_path = try unified.jsonEscape(self.allocator, venom_path);
        defer self.allocator.free(escaped_venom_path);
        try venoms_json.writer(self.allocator).print(
            "{{\"venom_id\":\"{s}\",\"path\":\"{s}\"}}",
            .{ escaped_venom_id, escaped_venom_path },
        );
    }
    try venoms_json.append(self.allocator, ']');

    const escaped_runtime_id = try unified.jsonEscape(self.allocator, runtime_id);
    defer self.allocator.free(escaped_runtime_id);
    const escaped_agent_id = try unified.jsonEscape(self.allocator, agent_id);
    defer self.allocator.free(escaped_agent_id);
    const escaped_node_path = try unified.jsonEscape(self.allocator, node_path);
    defer self.allocator.free(escaped_node_path);
    const expires_at_ms = currentRuntimeExpiry(self, runtime_id);
    const result_json = try std.fmt.allocPrint(
        self.allocator,
        "{{\"ok\":true,\"runtime_id\":\"{s}\",\"agent_id\":\"{s}\",\"node_id\":\"{s}\",\"node_path\":\"{s}\",\"venoms\":{s},\"expires_at_ms\":{d}}}",
        .{ escaped_runtime_id, escaped_agent_id, escaped_runtime_id, escaped_node_path, venoms_json.items, expires_at_ms },
    );
    defer self.allocator.free(result_json);
    return buildSuccessResultJson(self, .register, result_json);
}

fn buildHeartbeatResultJson(self: anytype, runtime_id: []const u8, agent_id: []const u8, ttl_ms: u64) ![]u8 {
    const escaped_runtime_id = try unified.jsonEscape(self.allocator, runtime_id);
    defer self.allocator.free(escaped_runtime_id);
    const escaped_agent_id = try unified.jsonEscape(self.allocator, agent_id);
    defer self.allocator.free(escaped_agent_id);
    const result_json = try std.fmt.allocPrint(
        self.allocator,
        "{{\"ok\":true,\"runtime_id\":\"{s}\",\"agent_id\":\"{s}\",\"ttl_ms\":{d},\"expires_at_ms\":{d}}}",
        .{ escaped_runtime_id, escaped_agent_id, ttl_ms, currentRuntimeExpiry(self, runtime_id) },
    );
    defer self.allocator.free(result_json);
    return buildSuccessResultJson(self, .heartbeat, result_json);
}

fn buildDetachResultJson(self: anytype, runtime_id: []const u8, agent_id: []const u8) ![]u8 {
    const escaped_runtime_id = try unified.jsonEscape(self.allocator, runtime_id);
    defer self.allocator.free(escaped_runtime_id);
    const escaped_agent_id = try unified.jsonEscape(self.allocator, agent_id);
    defer self.allocator.free(escaped_agent_id);
    const result_json = try std.fmt.allocPrint(
        self.allocator,
        "{{\"ok\":true,\"runtime_id\":\"{s}\",\"agent_id\":\"{s}\",\"detached\":true}}",
        .{ escaped_runtime_id, escaped_agent_id },
    );
    defer self.allocator.free(result_json);
    return buildSuccessResultJson(self, .detach, result_json);
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

fn operationName(op: Op) []const u8 {
    return switch (op) {
        .register => "register",
        .heartbeat => "heartbeat",
        .detach => "detach",
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

fn extractOptionalU64(obj: std.json.ObjectMap, name: []const u8) ?u64 {
    if (obj.get(name)) |value| {
        if (value == .integer and value.integer > 0) return @intCast(value.integer);
    }
    return null;
}

fn currentRuntimeExpiry(self: anytype, runtime_id: []const u8) i64 {
    if (self.runtime_presence.get(runtime_id)) |presence| return presence.expires_at_ms;
    return 0;
}

fn isSupportedRuntimeVenom(venom_id: []const u8) bool {
    inline for (default_runtime_venoms) |supported| {
        if (std.mem.eql(u8, venom_id, supported)) return true;
    }
    return false;
}

fn isValidIdentifier(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch)) continue;
        switch (ch) {
            '-', '_', '.' => continue,
            else => return false,
        }
    }
    return true;
}
