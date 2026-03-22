const std = @import("std");

pub fn parseControlPayloadObject(
    allocator: std.mem.Allocator,
    payload_json: ?[]const u8,
) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, payload_json orelse "{}", .{});
}

pub fn getRequiredStringField(
    obj: std.json.ObjectMap,
    field: []const u8,
) ![]const u8 {
    const value = obj.get(field) orelse return error.MissingField;
    if (value != .string or value.string.len == 0) return error.InvalidPayload;
    return value.string;
}

pub fn getRequiredStringFieldAllowEmpty(
    obj: std.json.ObjectMap,
    field: []const u8,
) ![]const u8 {
    const value = obj.get(field) orelse return error.MissingField;
    if (value != .string) return error.InvalidPayload;
    return value.string;
}

pub fn getOptionalStringField(
    obj: std.json.ObjectMap,
    field: []const u8,
) ?[]const u8 {
    const value = obj.get(field) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

pub fn getOptionalBoolField(
    obj: std.json.ObjectMap,
    field: []const u8,
) ?bool {
    const value = obj.get(field) orelse return null;
    if (value != .bool) return null;
    return value.bool;
}

pub fn getOptionalU64Field(
    obj: std.json.ObjectMap,
    field: []const u8,
) ?u64 {
    const value = obj.get(field) orelse return null;
    return switch (value) {
        .integer => if (value.integer >= 0) @intCast(value.integer) else null,
        else => null,
    };
}

pub fn getOptionalU32Field(
    obj: std.json.ObjectMap,
    field: []const u8,
) ?u32 {
    const value = obj.get(field) orelse return null;
    return switch (value) {
        .integer => if (value.integer >= 0 and value.integer <= std.math.maxInt(u32)) @intCast(value.integer) else null,
        else => null,
    };
}

pub fn getOptionalI64Field(
    obj: std.json.ObjectMap,
    field: []const u8,
) ?i64 {
    const value = obj.get(field) orelse return null;
    return switch (value) {
        .integer => if (value.integer >= std.math.minInt(i64) and value.integer <= std.math.maxInt(i64)) @intCast(value.integer) else null,
        else => null,
    };
}

pub fn decodeStandardBase64Owned(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) ![]u8 {
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, encoded);
    return decoded;
}
