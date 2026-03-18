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
    packages.* = .{};
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
    var package = VenomPackage{
        .venom_id = undefined,
        .kind = undefined,
        .version = undefined,
        .categories_json = undefined,
        .hosts_json = undefined,
        .projection_modes_json = undefined,
        .requirements_json = undefined,
        .capabilities_json = undefined,
        .ops_json = undefined,
        .runtime_json = undefined,
        .permissions_json = undefined,
        .schema_json = undefined,
        .help_md = null,
    };
    var venom_id_set = false;
    var kind_set = false;
    var version_set = false;
    var categories_set = false;
    var hosts_set = false;
    var projection_modes_set = false;
    var requirements_set = false;
    var capabilities_set = false;
    var ops_set = false;
    var runtime_set = false;
    var permissions_set = false;
    var schema_set = false;
    errdefer {
        if (venom_id_set) allocator.free(package.venom_id);
        if (kind_set) allocator.free(package.kind);
        if (version_set) allocator.free(package.version);
        if (categories_set) allocator.free(package.categories_json);
        if (hosts_set) allocator.free(package.hosts_json);
        if (projection_modes_set) allocator.free(package.projection_modes_json);
        if (requirements_set) allocator.free(package.requirements_json);
        if (capabilities_set) allocator.free(package.capabilities_json);
        if (ops_set) allocator.free(package.ops_json);
        if (runtime_set) allocator.free(package.runtime_json);
        if (permissions_set) allocator.free(package.permissions_json);
        if (schema_set) allocator.free(package.schema_json);
        if (package.help_md) |value| allocator.free(value);
    }

    package.venom_id = try dupRequiredString(allocator, obj, "venom_id", 128);
    venom_id_set = true;
    package.kind = try dupRequiredString(allocator, obj, "kind", 128);
    kind_set = true;
    package.version = try dupStringOrDefault(allocator, obj, "version", "1");
    version_set = true;
    package.categories_json = try dupObjectFieldJsonOrDefault(allocator, obj, "categories", "[]");
    categories_set = true;
    package.hosts_json = try dupObjectFieldJsonOrDefault(allocator, obj, "hosts", "[]");
    hosts_set = true;
    package.projection_modes_json = try dupObjectFieldJsonOrDefault(allocator, obj, "projection_modes", "[]");
    projection_modes_set = true;
    package.requirements_json = try dupObjectFieldJsonOrDefault(allocator, obj, "requirements", "{}");
    requirements_set = true;
    package.capabilities_json = try dupObjectFieldJsonOrDefault(allocator, obj, "capabilities", "{}");
    capabilities_set = true;
    package.ops_json = try dupObjectFieldJsonOrDefault(allocator, obj, "ops", "{}");
    ops_set = true;
    package.runtime_json = try dupObjectFieldJsonOrDefault(allocator, obj, "runtime", "{}");
    runtime_set = true;
    package.permissions_json = try dupObjectFieldJsonOrDefault(allocator, obj, "permissions", "{}");
    permissions_set = true;
    package.schema_json = try dupObjectFieldJsonOrDefault(allocator, obj, "schema", "{}");
    schema_set = true;
    package.help_md = try dupOptionalString(allocator, obj, "help_md");
    return package;
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
