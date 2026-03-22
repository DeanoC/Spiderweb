const std = @import("std");
const unified = @import("spider-protocol").unified;
const server_control_scope = @import("server_control_scope.zig");

pub const ControlMutationScope = server_control_scope.ControlMutationScope;

pub const AuditRecord = struct {
    id: u64,
    timestamp_ms: i64,
    agent_id: []u8,
    control_type: []u8,
    scope: ControlMutationScope,
    correlation_id: ?[]u8 = null,
    result: []u8,
    error_code: ?[]u8 = null,

    pub fn deinit(self: *AuditRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_id);
        allocator.free(self.control_type);
        if (self.correlation_id) |value| allocator.free(value);
        allocator.free(self.result);
        if (self.error_code) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub fn buildAuditTailPayload(runtime_registry: anytype, payload_json: ?[]const u8) ![]u8 {
    var limit: usize = 50;
    var filter_agent: ?[]const u8 = null;
    if (payload_json) |raw| {
        var parsed = try std.json.parseFromSlice(std.json.Value, runtime_registry.allocator, raw, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidPayload;
        if (parsed.value.object.get("limit")) |limit_val| {
            if (limit_val != .integer or limit_val.integer < 0) return error.InvalidPayload;
            limit = @intCast(limit_val.integer);
            if (limit > 500) limit = 500;
        }
        if (parsed.value.object.get("agent_id")) |agent_val| {
            if (agent_val != .string or agent_val.string.len == 0) return error.InvalidPayload;
            filter_agent = agent_val.string;
        }
    }

    runtime_registry.audit_records_mutex.lock();
    defer runtime_registry.audit_records_mutex.unlock();

    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(runtime_registry.allocator);
    try out.appendSlice(runtime_registry.allocator, "{\"audit\":[");

    var emitted: usize = 0;
    var idx = runtime_registry.audit_records.items.len;
    while (idx > 0 and emitted < limit) {
        idx -= 1;
        const record = runtime_registry.audit_records.items[idx];
        if (filter_agent) |agent| {
            if (!std.mem.eql(u8, agent, record.agent_id)) continue;
        }
        if (emitted != 0) try out.append(runtime_registry.allocator, ',');
        emitted += 1;
        try appendAuditRecordJson(runtime_registry.allocator, &out, record);
    }
    try out.appendSlice(runtime_registry.allocator, "]}");
    return out.toOwnedSlice(runtime_registry.allocator);
}

fn appendAuditRecordJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    record: AuditRecord,
) !void {
    const escaped_agent = try unified.jsonEscape(allocator, record.agent_id);
    defer allocator.free(escaped_agent);
    const escaped_type = try unified.jsonEscape(allocator, record.control_type);
    defer allocator.free(escaped_type);
    const escaped_result = try unified.jsonEscape(allocator, record.result);
    defer allocator.free(escaped_result);
    const correlation_json = if (record.correlation_id) |value| blk: {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(correlation_json);
    const error_json = if (record.error_code) |value| blk: {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(error_json);

    try out.writer(allocator).print(
        "{{\"id\":{d},\"timestamp_ms\":{d},\"agent_id\":\"{s}\",\"control_type\":\"{s}\",\"scope\":\"{s}\",\"correlation_id\":{s},\"result\":\"{s}\",\"error_code\":{s}}}",
        .{
            record.id,
            record.timestamp_ms,
            escaped_agent,
            escaped_type,
            server_control_scope.controlScopeName(record.scope),
            correlation_json,
            escaped_result,
            error_json,
        },
    );
}
