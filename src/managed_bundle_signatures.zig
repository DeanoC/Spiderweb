const std = @import("std");

pub const signature_scheme = "ed25519-sha256-v1";

pub const TrustedKey = struct {
    key_id: []const u8,
    public_key_hex: []const u8,
};

pub const default_trusted_keys = [_]TrustedKey{
    .{
        .key_id = "spidervenoms-dev-2026-03",
        .public_key_hex = "b15238a1a3948fb8c1a77d22313a05448e07ba93469ae7d46e75762c73992f24",
    },
};

pub fn verifySignedValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !void {
    return verifySignedValueWithKeys(allocator, value, &default_trusted_keys);
}

pub fn verifySignedValueWithKeys(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    trusted_keys: []const TrustedKey,
) !void {
    if (value != .object) return error.InvalidBundleRelease;
    const obj = value.object;

    const trust = obj.get("trust") orelse return error.UnsignedManagedBundle;
    if (trust != .object) return error.UnsignedManagedBundle;
    const mode = getRequiredString(trust.object, "mode") orelse return error.UnsignedManagedBundle;
    if (std.mem.eql(u8, std.mem.trim(u8, mode, " \t\r\n"), "unsigned")) return error.UnsignedManagedBundle;

    const digest = getRequiredString(obj, "digest") orelse return error.InvalidBundleDigest;
    const digest_hex = std.mem.trim(u8, std.mem.trimLeft(u8, digest, " \t\r\n"), " \t\r\n");
    if (!std.mem.startsWith(u8, digest_hex, "sha256:")) return error.InvalidBundleDigest;
    const encoded_digest = digest_hex["sha256:".len..];
    if (encoded_digest.len != 64) return error.InvalidBundleDigest;

    var expected_digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected_digest, encoded_digest) catch return error.InvalidBundleDigest;

    const payload_json = try canonicalPayloadJsonAlloc(allocator, value);
    defer allocator.free(payload_json);
    var computed_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload_json, &computed_digest, .{});
    if (!std.mem.eql(u8, &expected_digest, &computed_digest)) return error.InvalidBundleDigest;

    const signature = obj.get("signature") orelse return error.UnsignedManagedBundle;
    if (signature != .object) return error.UnsignedManagedBundle;
    const scheme = getRequiredString(signature.object, "scheme") orelse return error.InvalidBundleSignature;
    if (!std.mem.eql(u8, scheme, signature_scheme)) return error.InvalidBundleSignature;
    const key_id = getRequiredString(signature.object, "key_id") orelse return error.InvalidBundleSignature;
    const signature_value = getRequiredString(signature.object, "value") orelse return error.InvalidBundleSignature;

    const trusted_key = findTrustedKey(trusted_keys, key_id) orelse return error.UntrustedBundleSigningKey;
    const public_key = try parseTrustedPublicKey(trusted_key.public_key_hex);

    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(signature_value);
    if (decoded_len != std.crypto.sign.Ed25519.Signature.encoded_length) return error.InvalidBundleSignature;
    var decoded_signature = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded_signature);
    try std.base64.standard.Decoder.decode(decoded_signature, signature_value);
    const signature_bytes = decoded_signature[0..std.crypto.sign.Ed25519.Signature.encoded_length];
    const signature_obj = std.crypto.sign.Ed25519.Signature.fromBytes(signature_bytes[0..std.crypto.sign.Ed25519.Signature.encoded_length].*);
    try signature_obj.verify(&computed_digest, public_key);
}

fn findTrustedKey(trusted_keys: []const TrustedKey, key_id: []const u8) ?TrustedKey {
    for (trusted_keys) |trusted_key| {
        if (std.mem.eql(u8, trusted_key.key_id, key_id)) return trusted_key;
    }
    return null;
}

fn parseTrustedPublicKey(public_key_hex: []const u8) !std.crypto.sign.Ed25519.PublicKey {
    if (public_key_hex.len != std.crypto.sign.Ed25519.PublicKey.encoded_length * 2) {
        return error.InvalidBundleSignature;
    }

    var public_key_bytes: [std.crypto.sign.Ed25519.PublicKey.encoded_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&public_key_bytes, public_key_hex) catch return error.InvalidBundleSignature;
    return std.crypto.sign.Ed25519.PublicKey.fromBytes(public_key_bytes) catch return error.InvalidBundleSignature;
}

fn canonicalPayloadJsonAlloc(allocator: std.mem.Allocator, value: std.json.Value) anyerror![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try writeCanonicalValue(allocator, &out, value);
    return out.toOwnedSlice(allocator);
}

fn writeCanonicalValue(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    value: std.json.Value,
) anyerror!void {
    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |bool_value| try out.appendSlice(allocator, if (bool_value) "true" else "false"),
        .integer => |integer_value| try out.writer(allocator).print("{}", .{integer_value}),
        .float => |float_value| try out.writer(allocator).print("{f}", .{std.json.fmt(float_value, .{})}),
        .number_string => |number_value| try out.appendSlice(allocator, number_value),
        .string => |string_value| try out.writer(allocator).print("{f}", .{std.json.fmt(string_value, .{})}),
        .array => |array_value| {
            try out.append(allocator, '[');
            for (array_value.items, 0..) |item, index| {
                if (index != 0) try out.append(allocator, ',');
                try writeCanonicalValue(allocator, out, item);
            }
            try out.append(allocator, ']');
        },
        .object => |object_value| try writeCanonicalObject(allocator, out, object_value),
    }
}

fn writeCanonicalObject(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    object_value: std.json.ObjectMap,
) anyerror!void {
    var keys = std.ArrayListUnmanaged([]const u8){};
    defer keys.deinit(allocator);

    var it = object_value.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "digest") or std.mem.eql(u8, key, "signature")) continue;
        try keys.append(allocator, key);
    }

    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);

    try out.append(allocator, '{');
    for (keys.items, 0..) |key, index| {
        if (index != 0) try out.append(allocator, ',');
        try out.writer(allocator).print("{f}", .{std.json.fmt(key, .{})});
        try out.append(allocator, ':');
        try writeCanonicalValue(allocator, out, object_value.get(key).?);
    }
    try out.append(allocator, '}');
}

fn getRequiredString(obj: std.json.ObjectMap, field_name: []const u8) ?[]const u8 {
    const value = obj.get(field_name) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

test "verifySignedValueWithKeys accepts a valid signed object" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "channel": "stable",
        \\  "name": "tool",
        \\  "release_version": "1.2.3",
        \\  "trust": {
        \\    "mode": "signed",
        \\    "publisher": "SpiderVenoms",
        \\    "allow_dev_unsigned": false
        \\  },
        \\  "digest": "sha256:81088112e3ef119287a546f96b3a1f64389a5cd18ccd5ecc73e015f724aa3ad8",
        \\  "signature": {
        \\    "scheme": "ed25519-sha256-v1",
        \\    "key_id": "spidervenoms-dev-2026-03",
        \\    "value": "DBxO8ZW1nfzzmLliSLOh4kIRd5huVQYPEBOeDSFgNSkSTcyK8Lafuo8XfFLbAS3hRSkzkQHzhAdY8TWrah2pBQ=="
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    try verifySignedValue(allocator, parsed.value);
}

test "verifySignedValueWithKeys rejects a tampered signed object" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "channel": "stable",
        \\  "name": "tool-tampered",
        \\  "release_version": "1.2.3",
        \\  "trust": {
        \\    "mode": "signed",
        \\    "publisher": "SpiderVenoms",
        \\    "allow_dev_unsigned": false
        \\  },
        \\  "digest": "sha256:81088112e3ef119287a546f96b3a1f64389a5cd18ccd5ecc73e015f724aa3ad8",
        \\  "signature": {
        \\    "scheme": "ed25519-sha256-v1",
        \\    "key_id": "spidervenoms-dev-2026-03",
        \\    "value": "DBxO8ZW1nfzzmLliSLOh4kIRd5huVQYPEBOeDSFgNSkSTcyK8Lafuo8XfFLbAS3hRSkzkQHzhAdY8TWrah2pBQ=="
        \\  }
        \\}
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectError(error.InvalidBundleDigest, verifySignedValue(allocator, parsed.value));
}
