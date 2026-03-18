const std = @import("std");

pub const VenomPackage = struct {
    venom_id: []u8,
    kind: []u8,
    version: []u8,
    categories_json: []u8,
    hosts_json: []u8,
    projection_modes_json: []u8,
    requirements_json: []u8,
    capabilities_json: []u8,
    ops_json: []u8,
    runtime_json: []u8,
    permissions_json: []u8,
    schema_json: []u8,
    help_md: ?[]u8 = null,

    pub fn deinit(self: *VenomPackage, allocator: std.mem.Allocator) void {
        allocator.free(self.venom_id);
        allocator.free(self.kind);
        allocator.free(self.version);
        allocator.free(self.categories_json);
        allocator.free(self.hosts_json);
        allocator.free(self.projection_modes_json);
        allocator.free(self.requirements_json);
        allocator.free(self.capabilities_json);
        allocator.free(self.ops_json);
        allocator.free(self.runtime_json);
        allocator.free(self.permissions_json);
        allocator.free(self.schema_json);
        if (self.help_md) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub fn deinitPackages(
    allocator: std.mem.Allocator,
    packages: *std.ArrayListUnmanaged(VenomPackage),
) void {
    for (packages.items) |*package| package.deinit(allocator);
    packages.deinit(allocator);
}

pub fn replacePackagesFromJsonValue(
    allocator: std.mem.Allocator,
    packages: *std.ArrayListUnmanaged(VenomPackage),
    value: std.json.Value,
) !void {
    if (value != .array) return error.InvalidPackage;

    deinitPackages(allocator, packages);
    packages.* = .{};
    errdefer deinitPackages(allocator, packages);

    for (value.array.items) |item| {
        if (item != .object) return error.InvalidPackage;
        try packages.append(allocator, try parsePackageObject(allocator, item.object));
    }
}

pub fn appendPackageJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    package: VenomPackage,
) !void {
    const escaped_venom_id = try jsonEscape(allocator, package.venom_id);
    defer allocator.free(escaped_venom_id);
    const escaped_kind = try jsonEscape(allocator, package.kind);
    defer allocator.free(escaped_kind);
    const escaped_version = try jsonEscape(allocator, package.version);
    defer allocator.free(escaped_version);

    if (package.help_md) |help| {
        const escaped_help = try jsonEscape(allocator, help);
        defer allocator.free(escaped_help);
        try out.writer(allocator).print(
            "{{\"venom_id\":\"{s}\",\"kind\":\"{s}\",\"version\":\"{s}\",\"categories\":{s},\"hosts\":{s},\"projection_modes\":{s},\"requirements\":{s},\"capabilities\":{s},\"ops\":{s},\"runtime\":{s},\"permissions\":{s},\"schema\":{s},\"help_md\":\"{s}\"}}",
            .{
                escaped_venom_id,
                escaped_kind,
                escaped_version,
                package.categories_json,
                package.hosts_json,
                package.projection_modes_json,
                package.requirements_json,
                package.capabilities_json,
                package.ops_json,
                package.runtime_json,
                package.permissions_json,
                package.schema_json,
                escaped_help,
            },
        );
        return;
    }

    try out.writer(allocator).print(
        "{{\"venom_id\":\"{s}\",\"kind\":\"{s}\",\"version\":\"{s}\",\"categories\":{s},\"hosts\":{s},\"projection_modes\":{s},\"requirements\":{s},\"capabilities\":{s},\"ops\":{s},\"runtime\":{s},\"permissions\":{s},\"schema\":{s}}}",
        .{
            escaped_venom_id,
            escaped_kind,
            escaped_version,
            package.categories_json,
            package.hosts_json,
            package.projection_modes_json,
            package.requirements_json,
            package.capabilities_json,
            package.ops_json,
            package.runtime_json,
            package.permissions_json,
            package.schema_json,
        },
    );
}

fn parsePackageObject(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !VenomPackage {
    return .{
        .venom_id = try dupRequiredString(allocator, obj, "venom_id", 128),
        .kind = try dupRequiredString(allocator, obj, "kind", 128),
        .version = try dupStringOrDefault(allocator, obj, "version", "1"),
        .categories_json = try dupObjectFieldJsonOrDefault(allocator, obj, "categories", "[]"),
        .hosts_json = try dupObjectFieldJsonOrDefault(allocator, obj, "hosts", "[]"),
        .projection_modes_json = try dupObjectFieldJsonOrDefault(allocator, obj, "projection_modes", "[]"),
        .requirements_json = try dupObjectFieldJsonOrDefault(allocator, obj, "requirements", "{}"),
        .capabilities_json = try dupObjectFieldJsonOrDefault(allocator, obj, "capabilities", "{}"),
        .ops_json = try dupObjectFieldJsonOrDefault(allocator, obj, "ops", "{}"),
        .runtime_json = try dupObjectFieldJsonOrDefault(allocator, obj, "runtime", "{}"),
        .permissions_json = try dupObjectFieldJsonOrDefault(allocator, obj, "permissions", "{}"),
        .schema_json = try dupObjectFieldJsonOrDefault(allocator, obj, "schema", "{}"),
        .help_md = try dupOptionalString(allocator, obj, "help_md"),
    };
}

fn dupRequiredString(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    max_len: usize,
) ![]u8 {
    const value = obj.get(key) orelse return error.InvalidPackage;
    if (value != .string or value.string.len == 0 or value.string.len > max_len) return error.InvalidPackage;
    return allocator.dupe(u8, value.string);
}

fn dupStringOrDefault(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    default_value: []const u8,
) ![]u8 {
    const value = obj.get(key) orelse return allocator.dupe(u8, default_value);
    if (value != .string or value.string.len == 0) return error.InvalidPackage;
    return allocator.dupe(u8, value.string);
}

fn dupOptionalString(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) !?[]u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return error.InvalidPackage;
    return try allocator.dupe(u8, value.string);
}

fn dupObjectFieldJsonOrDefault(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    default_json: []const u8,
) ![]u8 {
    const value = obj.get(key) orelse return allocator.dupe(u8, default_json);
    return switch (value) {
        .array, .object => std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})}),
        else => error.InvalidPackage,
    };
}

fn jsonEscape(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    for (value) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => if (ch < 0x20) {
                try out.writer(allocator).print("\\u00{x:0>2}", .{ch});
            } else {
                try out.append(allocator, ch);
            },
        }
    }

    return out.toOwnedSlice(allocator);
}
