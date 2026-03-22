const std = @import("std");

pub const FsNodeHelloOptions = struct {
    allow_invalidations: bool = false,
};

pub fn validateControlVersionPayload(
    allocator: std.mem.Allocator,
    payload_json: ?[]const u8,
    expected_protocol: []const u8,
) !void {
    const raw = payload_json orelse return error.MissingField;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidType;
    const protocol_value = parsed.value.object.get("protocol") orelse return error.MissingField;
    if (protocol_value != .string) return error.InvalidType;
    if (!std.mem.eql(u8, protocol_value.string, expected_protocol)) return error.ProtocolMismatch;
}

pub fn validateFsNodeHelloPayloadWithAcceptedTokens(
    allocator: std.mem.Allocator,
    payload_json: ?[]const u8,
    accepted_auth_tokens: ?[]const []const u8,
    expected_protocol: []const u8,
    expected_proto_id: i64,
) !FsNodeHelloOptions {
    const raw = payload_json orelse return error.MissingField;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidType;

    const protocol_value = parsed.value.object.get("protocol") orelse return error.MissingField;
    if (protocol_value != .string) return error.InvalidType;
    if (!std.mem.eql(u8, protocol_value.string, expected_protocol)) return error.ProtocolMismatch;

    const proto_value = parsed.value.object.get("proto") orelse return error.MissingField;
    if (proto_value != .integer) return error.InvalidType;
    if (proto_value.integer != expected_proto_id) return error.ProtocolMismatch;

    if (accepted_auth_tokens) |expected_tokens| {
        const auth_value = parsed.value.object.get("auth_token") orelse return error.AuthMissing;
        if (auth_value != .string) return error.InvalidType;

        var matched = false;
        for (expected_tokens) |expected| {
            if (std.mem.eql(u8, auth_value.string, expected)) {
                matched = true;
                break;
            }
        }
        if (!matched) return error.AuthFailed;
    }

    var opts = FsNodeHelloOptions{};
    if (parsed.value.object.get("subscribe_invalidations")) |value| {
        if (value != .bool) return error.InvalidType;
        opts.allow_invalidations = value.bool;
    }
    return opts;
}

pub fn validateFsNodeHelloPayload(
    allocator: std.mem.Allocator,
    payload_json: ?[]const u8,
    required_auth_token: ?[]const u8,
    expected_protocol: []const u8,
    expected_proto_id: i64,
) !FsNodeHelloOptions {
    if (required_auth_token) |expected| {
        const tokens = [_][]const u8{expected};
        return validateFsNodeHelloPayloadWithAcceptedTokens(
            allocator,
            payload_json,
            tokens[0..],
            expected_protocol,
            expected_proto_id,
        );
    }
    return validateFsNodeHelloPayloadWithAcceptedTokens(
        allocator,
        payload_json,
        null,
        expected_protocol,
        expected_proto_id,
    );
}

pub fn parseFsHelloAuthToken(allocator: std.mem.Allocator, payload_json: ?[]const u8) !?[]u8 {
    const raw = payload_json orelse return null;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidType;
    const auth_value = parsed.value.object.get("auth_token") orelse return null;
    if (auth_value != .string or auth_value.string.len == 0) return null;
    const copy = try allocator.dupe(u8, auth_value.string);
    return @as(?[]u8, copy);
}
