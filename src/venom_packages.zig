const std = @import("std");
const venom_package = @import("venom_package.zig");
const venom_model = @import("venom_model.zig");

pub const BuiltinPackageSpec = struct {
    venom_id: []const u8,
    kind: []const u8,
    version: []const u8 = "1",
    enabled: bool = true,
    default_host_role: venom_model.HostRole,
    binding_scopes: []const venom_model.BindingScope = &.{venom_model.BindingScope.workspace},
    runtime_kind: venom_model.RuntimeKind = .native,
    default_target_path: ?[]const u8 = null,
    categories_json: []const u8 = "[]",
    requirements_json: []const u8 = "{}",
    capabilities_json: []const u8 = "{}",
    ops_json: []const u8 = "{}",
    runtime_json: []const u8 = "{}",
    permissions_json: []const u8 = "{}",
    schema_json: []const u8 = "{}",
    help_md: ?[]const u8 = null,

    pub fn hostRolesJson(self: BuiltinPackageSpec) []const u8 {
        return switch (self.default_host_role) {
            .spiderweb => "[\"spiderweb\"]",
            .node => "[\"node\"]",
            .client => "[\"client\"]",
        };
    }

    pub fn bindingScopesJson(self: BuiltinPackageSpec) []const u8 {
        if (self.binding_scopes.len == 0) return "[]";
        if (self.binding_scopes.len == 1) {
            return switch (self.binding_scopes[0]) {
                .workspace => "[\"workspace\"]",
                .agent => "[\"agent\"]",
                .client => "[\"client\"]",
                .node => "[\"node\"]",
            };
        }
        if (self.binding_scopes.len == 2 and
            self.binding_scopes[0] == .workspace and
            self.binding_scopes[1] == .agent)
        {
            return "[\"workspace\",\"agent\"]";
        }
        @panic("unsupported builtin binding scope combination");
    }

    pub fn legacyProjectionModesJson(self: BuiltinPackageSpec) []const u8 {
        return venom_model.legacyProjectionModesJson(self.default_host_role, self.binding_scopes);
    }

    pub fn legacyDefaultProviderScope(self: BuiltinPackageSpec) []const u8 {
        return venom_model.legacyProviderScope(self.default_host_role, self.binding_scopes);
    }
};

const workspace_scope = &.{venom_model.BindingScope.workspace};
const agent_scope = &.{venom_model.BindingScope.agent};
const node_scope = &.{venom_model.BindingScope.node};

const builtin_packages = [_]BuiltinPackageSpec{
    .{ .venom_id = "library", .kind = "library", .default_host_role = .spiderweb, .binding_scopes = workspace_scope, .default_target_path = "/nodes/local/venoms/library", .categories_json = "[\"docs\",\"discovery\"]", .help_md = "Workspace library and topic discovery." },
    .{ .venom_id = "packages", .kind = "registry", .default_host_role = .spiderweb, .binding_scopes = workspace_scope, .default_target_path = "/nodes/local/venoms/packages", .categories_json = "[\"venoms\",\"registry\"]", .help_md = "Registry of available Venom packages and install/remove operations." },
    .{ .venom_id = "events", .kind = "events", .default_host_role = .spiderweb, .binding_scopes = workspace_scope, .default_target_path = "/nodes/local/venoms/events", .categories_json = "[\"events\",\"coordination\"]", .help_md = "Filesystem-native waits and event delivery." },
    .{ .venom_id = "home", .kind = "home", .default_host_role = .spiderweb, .binding_scopes = workspace_scope, .default_target_path = "/nodes/local/venoms/home", .categories_json = "[\"agent\",\"storage\"]", .help_md = "Provision durable per-agent workspace homes." },
    .{ .venom_id = "runtimes", .kind = "runtimes", .default_host_role = .spiderweb, .binding_scopes = workspace_scope, .default_target_path = "/nodes/local/venoms/runtimes", .categories_json = "[\"runtime\",\"registration\"]", .help_md = "Register and maintain runtime-private venom instances." },
    .{ .venom_id = "search_code", .kind = "search_code", .default_host_role = .node, .binding_scopes = workspace_scope, .default_target_path = "/nodes/local/venoms/search_code", .categories_json = "[\"search\",\"code\"]", .help_md = "Workspace code search service." },
    .{ .venom_id = "fs", .kind = "fs", .default_host_role = .node, .binding_scopes = node_scope, .runtime_kind = .native, .categories_json = "[\"filesystem\",\"node\"]", .runtime_json = "{\"type\":\"builtin\",\"abi\":\"venom-driver-v1\"}", .schema_json = "{\"model\":\"namespace-mount\"}", .help_md = "Filesystem export surfaced by a Spiderweb node." },
    .{ .venom_id = "terminal", .kind = "terminal", .default_host_role = .node, .binding_scopes = workspace_scope, .default_target_path = "/nodes/local/venoms/terminal", .categories_json = "[\"terminal\",\"exec\"]", .help_md = "Command execution service with Linux-only interactive terminal sessions." },
    .{ .venom_id = "mounts", .kind = "mounts", .default_host_role = .spiderweb, .binding_scopes = workspace_scope, .default_target_path = "/nodes/local/venoms/mounts", .categories_json = "[\"workspace\",\"mounts\"]", .help_md = "Workspace mounts and binds management." },
    .{ .venom_id = "workspaces", .kind = "workspaces", .default_host_role = .spiderweb, .binding_scopes = workspace_scope, .default_target_path = "/nodes/local/venoms/workspaces", .categories_json = "[\"workspace\",\"control\"]", .help_md = "Workspace control-plane management service." },
    .{ .venom_id = "git", .kind = "git", .default_host_role = .node, .binding_scopes = workspace_scope, .default_target_path = "/nodes/local/venoms/git", .categories_json = "[\"developer\",\"scm\"]", .requirements_json = "{\"host_capabilities\":[\"local_fs_export\"]}", .help_md = "Git checkout and diff operations." },
    .{ .venom_id = "memory", .kind = "memory", .default_host_role = .client, .binding_scopes = agent_scope, .categories_json = "[\"memory\",\"agent_private\"]", .capabilities_json = "{\"invoke\":true,\"operations\":[\"memory_create\",\"memory_load\",\"memory_versions\",\"memory_mutate\",\"memory_evict\",\"memory_search\"],\"discoverable\":true,\"runtime_owned\":true}", .ops_json = "{\"model\":\"filesystem_loopback\",\"invoke\":\"control/invoke.json\",\"transport\":\"filesystem\",\"paths\":{\"create\":\"control/create.json\",\"load\":\"control/load.json\",\"versions\":\"control/versions.json\",\"mutate\":\"control/mutate.json\",\"evict\":\"control/evict.json\",\"search\":\"control/search.json\"},\"operations\":{\"create\":\"create\",\"load\":\"load\",\"versions\":\"versions\",\"mutate\":\"mutate\",\"evict\":\"evict\",\"search\":\"search\"}}", .runtime_json = "{\"type\":\"external_runtime\",\"transport\":\"filesystem_loopback\",\"component\":\"spider_monkey\"}", .permissions_json = "{\"default\":\"allow-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"scope\":\"runtime\"}", .schema_json = "{\"model\":\"runtime-loopback-memory-v1\"}", .help_md = "Runtime-private memory service." },
    .{ .venom_id = "sub_brains", .kind = "sub_brains", .default_host_role = .client, .binding_scopes = agent_scope, .categories_json = "[\"agent_private\",\"sub_brains\"]", .capabilities_json = "{\"invoke\":true,\"operations\":[\"sub_brains_list\",\"sub_brains_upsert\",\"sub_brains_delete\"],\"discoverable\":true,\"runtime_owned\":true}", .ops_json = "{\"model\":\"filesystem_loopback\",\"invoke\":\"control/invoke.json\",\"transport\":\"filesystem\",\"paths\":{\"list\":\"control/list.json\",\"upsert\":\"control/upsert.json\",\"delete\":\"control/delete.json\"},\"operations\":{\"list\":\"list\",\"upsert\":\"upsert\",\"delete\":\"delete\"}}", .runtime_json = "{\"type\":\"external_runtime\",\"transport\":\"filesystem_loopback\",\"component\":\"spider_monkey\"}", .permissions_json = "{\"default\":\"allow-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"scope\":\"runtime\"}", .schema_json = "{\"model\":\"runtime-loopback-sub-brains-v1\"}", .help_md = "Runtime-private sub-brain service." },
};

pub fn allBuiltinPackages() []const BuiltinPackageSpec {
    return builtin_packages[0..];
}

pub fn findBuiltinPackage(venom_id: []const u8) ?BuiltinPackageSpec {
    for (builtin_packages) |spec| {
        if (std.mem.eql(u8, spec.venom_id, venom_id)) return spec;
    }
    return null;
}

pub fn resolveBuiltinTargetPath(venom_id: []const u8, host_role: venom_model.HostRole) ?[]const u8 {
    const spec = findBuiltinPackage(venom_id) orelse return null;
    if (spec.default_host_role != host_role) return null;
    return spec.default_target_path;
}

pub fn buildPackagesJson(allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (builtin_packages, 0..) |spec, idx| {
        if (idx != 0) try out.append(allocator, ',');
        try appendPackageJson(allocator, &out, spec);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn buildCombinedPackagesJson(
    allocator: std.mem.Allocator,
    installed_packages: []const venom_package.VenomPackage,
) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    var first = true;
    for (builtin_packages) |spec| {
        if (!first) try out.append(allocator, ',');
        first = false;
        try appendPackageJson(allocator, &out, spec);
    }
    for (installed_packages) |package| {
        if (!first) try out.append(allocator, ',');
        first = false;
        try venom_package.appendPackageJson(allocator, &out, package);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn renderPackageMetadataJson(allocator: std.mem.Allocator, spec: BuiltinPackageSpec) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);
    try appendPackageJson(allocator, &out, spec);
    return out.toOwnedSlice(allocator);
}

pub fn cloneBuiltinPackage(
    allocator: std.mem.Allocator,
    venom_id: []const u8,
) !?venom_package.VenomPackage {
    const spec = findBuiltinPackage(venom_id) orelse return null;
    return .{
        .venom_id = try allocator.dupe(u8, spec.venom_id),
        .kind = try allocator.dupe(u8, spec.kind),
        .version = try allocator.dupe(u8, spec.version),
        .enabled = spec.enabled,
        .categories_json = try allocator.dupe(u8, spec.categories_json),
        .host_roles_json = try allocator.dupe(u8, spec.hostRolesJson()),
        .binding_scopes_json = try allocator.dupe(u8, spec.bindingScopesJson()),
        .runtime_kind = spec.runtime_kind,
        .requirements_json = try allocator.dupe(u8, spec.requirements_json),
        .capabilities_json = try allocator.dupe(u8, spec.capabilities_json),
        .ops_json = try allocator.dupe(u8, spec.ops_json),
        .runtime_json = try allocator.dupe(u8, spec.runtime_json),
        .permissions_json = try allocator.dupe(u8, spec.permissions_json),
        .schema_json = try allocator.dupe(u8, spec.schema_json),
        .help_md = if (spec.help_md) |help| try allocator.dupe(u8, help) else null,
    };
}

fn appendPackageJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    spec: BuiltinPackageSpec,
) !void {
    const escaped_venom_id = try jsonEscape(allocator, spec.venom_id);
    defer allocator.free(escaped_venom_id);
    const escaped_kind = try jsonEscape(allocator, spec.kind);
    defer allocator.free(escaped_kind);
    const escaped_version = try jsonEscape(allocator, spec.version);
    defer allocator.free(escaped_version);
    const target_path_json = if (spec.default_target_path) |value| blk: {
        const escaped = try jsonEscape(allocator, value);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(target_path_json);

    try out.writer(allocator).print(
        "{{\"package_id\":\"{s}\",\"venom_id\":\"{s}\",\"kind\":\"{s}\",\"version\":\"{s}\",\"enabled\":{},\"categories\":{s},\"host_roles\":{s},\"binding_scopes\":{s},\"runtime_kind\":\"{s}\",\"requirements\":{s},\"capabilities\":{s},\"ops\":{s},\"runtime\":{s},\"permissions\":{s},\"schema\":{s},\"default_host_role\":\"{s}\",\"default_target_path\":{s}",
        .{
            escaped_venom_id,
            escaped_venom_id,
            escaped_kind,
            escaped_version,
            spec.enabled,
            spec.categories_json,
            spec.hostRolesJson(),
            spec.bindingScopesJson(),
            spec.runtime_kind.asString(),
            spec.requirements_json,
            spec.capabilities_json,
            spec.ops_json,
            spec.runtime_json,
            spec.permissions_json,
            spec.schema_json,
            spec.default_host_role.asString(),
            target_path_json,
        },
    );
    if (spec.help_md) |help| {
        const escaped_help = try jsonEscape(allocator, help);
        defer allocator.free(escaped_help);
        try out.writer(allocator).print(",\"help_md\":\"{s}\"}}", .{escaped_help});
        return;
    }
    try out.appendSlice(allocator, "}");
}

fn jsonEscape(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    for (value) |ch| switch (ch) {
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
    };
    return out.toOwnedSlice(allocator);
}

test "venom_packages: builtins render through shared package parser" {
    const allocator = std.testing.allocator;
    const raw = try buildPackagesJson(allocator);
    defer allocator.free(raw);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    var packages = std.ArrayListUnmanaged(venom_package.VenomPackage){};
    defer venom_package.deinitPackages(allocator, &packages);
    try venom_package.replacePackagesFromJsonValue(allocator, &packages, parsed.value);

    try std.testing.expect(packages.items.len >= 5);
    try std.testing.expect(findBuiltinPackage("runtimes") != null);
    try std.testing.expect(findBuiltinPackage("packages") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"venom_id\":\"memory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"package_id\":\"terminal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"venom_id\":\"packages\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"venom_id\":\"runtimes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"host_roles\":[\"node\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"binding_scopes\":[\"workspace\"]") != null);

    const terminal = findBuiltinPackage("terminal") orelse return error.TestExpectedResponse;
    const git = findBuiltinPackage("git") orelse return error.TestExpectedResponse;
    const search_code = findBuiltinPackage("search_code") orelse return error.TestExpectedResponse;
    try std.testing.expect(terminal.default_host_role == .node);
    try std.testing.expect(git.default_host_role == .node);
    try std.testing.expect(search_code.default_host_role == .node);
    try std.testing.expectEqualStrings("node_export", terminal.legacyDefaultProviderScope());
}
