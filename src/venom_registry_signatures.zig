const std = @import("std");

pub const signature_scheme = "ed25519-sha256-v1";

pub const TrustedKeyStatus = enum {
    active,
    verify_only,
    revoked,
};

pub const TrustedKey = struct {
    key_id: []const u8,
    public_key_hex: []const u8,
    status: TrustedKeyStatus,
    venom_registry_document_allowed: bool,
};

pub const default_trusted_keys = [_]TrustedKey{
    .{
        .key_id = "spidervenomregistry-dev-2026-03",
        .public_key_hex = "54cbd9b6aa05c13d46bb76062188c9a303e27f90b0ca2203f8531fe3937cbb20",
        .status = .active,
        .venom_registry_document_allowed = true,
    },
    .{
        .key_id = "spidervenomregistry-revoked-2026-03",
        .public_key_hex = "373a430931addf8dba153124c73070b3f2dd7f12f6229f055ee0622190a86cbf",
        .status = .revoked,
        .venom_registry_document_allowed = true,
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
    if (value != .object) return error.InvalidRegistryDocument;
    const obj = value.object;

    const digest = getRequiredString(obj, "digest") orelse return error.InvalidRegistryDigest;
    const digest_hex = std.mem.trim(u8, std.mem.trimLeft(u8, digest, " \t\r\n"), " \t\r\n");
    if (!std.mem.startsWith(u8, digest_hex, "sha256:")) return error.InvalidRegistryDigest;
    const encoded_digest = digest_hex["sha256:".len..];
    if (encoded_digest.len != 64) return error.InvalidRegistryDigest;

    var expected_digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected_digest, encoded_digest) catch return error.InvalidRegistryDigest;

    const payload_json = try canonicalPayloadJsonAlloc(allocator, value);
    defer allocator.free(payload_json);
    var computed_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload_json, &computed_digest, .{});
    if (!std.mem.eql(u8, &expected_digest, &computed_digest)) return error.InvalidRegistryDigest;

    const signature = obj.get("signature") orelse return error.UnsignedRegistryDocument;
    if (signature != .object) return error.UnsignedRegistryDocument;
    const scheme = getRequiredString(signature.object, "scheme") orelse return error.InvalidRegistrySignature;
    if (!std.mem.eql(u8, scheme, signature_scheme)) return error.InvalidRegistrySignature;
    const key_id = getRequiredString(signature.object, "key_id") orelse return error.InvalidRegistrySignature;
    const signature_value = getRequiredString(signature.object, "value") orelse return error.InvalidRegistrySignature;

    const trusted_key = findTrustedKey(trusted_keys, key_id) orelse return error.UntrustedRegistrySigningKey;
    if (!trusted_key.venom_registry_document_allowed) return error.RegistrySigningKeyPolicyViolation;
    switch (trusted_key.status) {
        .active, .verify_only => {},
        .revoked => return error.RegistrySigningKeyRevoked,
    }
    const public_key = try parseTrustedPublicKey(trusted_key.public_key_hex);

    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(signature_value);
    if (decoded_len != std.crypto.sign.Ed25519.Signature.encoded_length) return error.InvalidRegistrySignature;
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
        return error.InvalidRegistrySignature;
    }

    var public_key_bytes: [std.crypto.sign.Ed25519.PublicKey.encoded_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&public_key_bytes, public_key_hex) catch return error.InvalidRegistrySignature;
    return std.crypto.sign.Ed25519.PublicKey.fromBytes(public_key_bytes) catch return error.InvalidRegistrySignature;
}

fn canonicalPayloadJsonAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try writeCanonicalValue(allocator, &out, value, true);
    return out.toOwnedSlice(allocator);
}

fn writeCanonicalValue(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    value: std.json.Value,
    omit_envelope_fields: bool,
) !void {
    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |n| try out.writer(allocator).print("{d}", .{n}),
        .float => |n| try out.writer(allocator).print("{d}", .{n}),
        .number_string => |raw| try out.appendSlice(allocator, raw),
        .string => |s| {
            const escaped = try std.json.Stringify.valueAlloc(allocator, s, .{});
            defer allocator.free(escaped);
            try out.appendSlice(allocator, escaped);
        },
        .array => |array| {
            try out.append(allocator, '[');
            for (array.items, 0..) |item, idx| {
                if (idx != 0) try out.append(allocator, ',');
                try writeCanonicalValue(allocator, out, item, false);
            }
            try out.append(allocator, ']');
        },
        .object => |obj| {
            var entries = std.ArrayListUnmanaged([]const u8){};
            defer entries.deinit(allocator);
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (omit_envelope_fields and (std.mem.eql(u8, key, "digest") or std.mem.eql(u8, key, "signature"))) continue;
                try entries.append(allocator, key);
            }
            std.mem.sort([]const u8, entries.items, {}, struct {
                fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                    return std.mem.order(u8, lhs, rhs) == .lt;
                }
            }.lessThan);

            try out.append(allocator, '{');
            for (entries.items, 0..) |key, idx| {
                if (idx != 0) try out.append(allocator, ',');
                const escaped = try std.json.Stringify.valueAlloc(allocator, key, .{});
                defer allocator.free(escaped);
                try out.appendSlice(allocator, escaped);
                try out.append(allocator, ':');
                try writeCanonicalValue(allocator, out, obj.get(key).?, false);
            }
            try out.append(allocator, '}');
        },
    }
}

fn getRequiredString(obj: std.json.ObjectMap, field_name: []const u8) ?[]const u8 {
    const value = obj.get(field_name) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

test "verifySignedValue accepts a valid signed registry index" {
    const allocator = std.testing.allocator;
    const payload =
        \\{
        \\  "schema_version": "spidervenom-registry-v1",
        \\  "publisher": "SpiderVenomRegistry",
        \\  "generated_at": "2026-03-26T15:37:16Z",
        \\  "keys": [{"key_id":"spidervenomregistry-dev-2026-03","path":"keys/trusted-registry-keys.json"}],
        \\  "channels": [{"id":"stable","path":"v1/channels/stable.json"}],
        \\  "bundles": [{"bundle_id":"managed-local","package_ids":["terminal"],"latest_by_channel":{"stable":{"release_version":"0.5.8","path":"v1/bundles/managed-local/0.5.8.json"}}}],
        \\  "digest": "sha256:fe31bfd068f09f588518e67689ff25ce11a80b59bdb9c8dad261d903b1226ec2",
        \\  "signature": {
        \\    "scheme": "ed25519-sha256-v1",
        \\    "key_id": "spidervenomregistry-dev-2026-03",
        \\    "value": "uQck8xm3hqQKWG4Pu2oAU1j6hANL5eIAGzsSHg8Q3xCPck98L04uLhRvXzlm8x9vIbdWeL8HkT7UU6cD4RXvCQ=="
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try verifySignedValue(allocator, parsed.value);
}

test "verifySignedValue rejects a tampered signed registry document" {
    const allocator = std.testing.allocator;
    const payload =
        \\{
        \\  "schema_version": "spidervenom-registry-v1",
        \\  "publisher": "SpiderVenomRegistry",
        \\  "generated_at": "2026-03-26T15:37:16Z",
        \\  "keys": [{"key_id":"spidervenomregistry-dev-2026-03","path":"keys/trusted-registry-keys.json"}],
        \\  "channels": [{"id":"stable","path":"v1/channels/stable.json"}],
        \\  "bundles": [{"bundle_id":"managed-local","package_ids":["terminal"],"latest_by_channel":{"stable":{"release_version":"0.5.9","path":"v1/bundles/managed-local/0.5.8.json"}}}],
        \\  "digest": "sha256:fe31bfd068f09f588518e67689ff25ce11a80b59bdb9c8dad261d903b1226ec2",
        \\  "signature": {
        \\    "scheme": "ed25519-sha256-v1",
        \\    "key_id": "spidervenomregistry-dev-2026-03",
        \\    "value": "uQck8xm3hqQKWG4Pu2oAU1j6hANL5eIAGzsSHg8Q3xCPck98L04uLhRvXzlm8x9vIbdWeL8HkT7UU6cD4RXvCQ=="
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidRegistryDigest, verifySignedValue(allocator, parsed.value));
}

test "verifySignedValue rejects a revoked trusted registry signing key" {
    const allocator = std.testing.allocator;
    const payload =
        \\{
        \\  "schema_version": "spidervenom-registry-v1",
        \\  "publisher": "SpiderVenomRegistry",
        \\  "generated_at": "2026-03-26T15:37:16Z",
        \\  "keys": [{"key_id":"spidervenomregistry-dev-2026-03","path":"keys/trusted-registry-keys.json"}],
        \\  "channels": [{"id":"stable","path":"v1/channels/stable.json"}],
        \\  "bundles": [{"bundle_id":"managed-local","package_ids":["terminal"],"latest_by_channel":{"stable":{"release_version":"0.5.8","path":"v1/bundles/managed-local/0.5.8.json"}}}],
        \\  "digest": "sha256:fe31bfd068f09f588518e67689ff25ce11a80b59bdb9c8dad261d903b1226ec2",
        \\  "signature": {
        \\    "scheme": "ed25519-sha256-v1",
        \\    "key_id": "spidervenomregistry-dev-2026-03",
        \\    "value": "uQck8xm3hqQKWG4Pu2oAU1j6hANL5eIAGzsSHg8Q3xCPck98L04uLhRvXzlm8x9vIbdWeL8HkT7UU6cD4RXvCQ=="
        \\  }
        \\}
    ;
    const revoked_keys = [_]TrustedKey{
        .{
            .key_id = "spidervenomregistry-dev-2026-03",
            .public_key_hex = "54cbd9b6aa05c13d46bb76062188c9a303e27f90b0ca2203f8531fe3937cbb20",
            .status = .revoked,
            .venom_registry_document_allowed = true,
        },
    };
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(
        error.RegistrySigningKeyRevoked,
        verifySignedValueWithKeys(allocator, parsed.value, &revoked_keys),
    );
}

test "verifySignedValue rejects a trusted key without registry-document purpose" {
    const allocator = std.testing.allocator;
    const payload =
        \\{
        \\  "schema_version": "spidervenom-registry-v1",
        \\  "publisher": "SpiderVenomRegistry",
        \\  "generated_at": "2026-03-26T15:37:16Z",
        \\  "keys": [{"key_id":"spidervenomregistry-dev-2026-03","path":"keys/trusted-registry-keys.json"}],
        \\  "channels": [{"id":"stable","path":"v1/channels/stable.json"}],
        \\  "bundles": [{"bundle_id":"managed-local","package_ids":["terminal"],"latest_by_channel":{"stable":{"release_version":"0.5.8","path":"v1/bundles/managed-local/0.5.8.json"}}}],
        \\  "digest": "sha256:fe31bfd068f09f588518e67689ff25ce11a80b59bdb9c8dad261d903b1226ec2",
        \\  "signature": {
        \\    "scheme": "ed25519-sha256-v1",
        \\    "key_id": "spidervenomregistry-dev-2026-03",
        \\    "value": "uQck8xm3hqQKWG4Pu2oAU1j6hANL5eIAGzsSHg8Q3xCPck98L04uLhRvXzlm8x9vIbdWeL8HkT7UU6cD4RXvCQ=="
        \\  }
        \\}
    ;
    const wrong_purpose_keys = [_]TrustedKey{
        .{
            .key_id = "spidervenomregistry-dev-2026-03",
            .public_key_hex = "54cbd9b6aa05c13d46bb76062188c9a303e27f90b0ca2203f8531fe3937cbb20",
            .status = .active,
            .venom_registry_document_allowed = false,
        },
    };
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(
        error.RegistrySigningKeyPolicyViolation,
        verifySignedValueWithKeys(allocator, parsed.value, &wrong_purpose_keys),
    );
}
