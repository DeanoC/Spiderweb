const std = @import("std");
const unified = @import("spider-protocol").unified;
const venom_model = @import("../venom_model.zig");
const venom_packages = @import("../venom_packages.zig");

pub fn buildCatalogPackagesJson(session: anytype) ![]u8 {
    const raw_packages_json = if (session.control_plane) |plane|
        try plane.listVenomPackages()
    else
        try venom_packages.buildPackagesJson(session.allocator);
    defer session.allocator.free(raw_packages_json);

    session.refreshDynamicDirectory(session.nodes_root_id) catch {};

    var parsed = try std.json.parseFromSlice(std.json.Value, session.allocator, raw_packages_json, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return session.allocator.dupe(u8, "[]");

    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(session.allocator);
    try out.append(session.allocator, '[');

    var first = true;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const package_id = getString(item.object, "venom_id") orelse continue;
        if (item.object.get("enabled")) |enabled| {
            if (enabled == .bool and !enabled.bool) continue;
        }
        if (!venom_model.isCapabilityVenomId(package_id)) continue;
        if (venom_model.isExplicitBindOnlyCapabilityVenomId(package_id) and
            !sessionHasPublishedCapabilityProvider(session, package_id))
        {
            continue;
        }

        const kind = getString(item.object, "kind") orelse package_id;
        const version = getString(item.object, "version") orelse "1";
        const help_md = getString(item.object, "help_md");
        const runtime_kind = normalizedRuntimeKindFromObject(item.object);
        const escaped_package_id = try unified.jsonEscape(session.allocator, package_id);
        defer session.allocator.free(escaped_package_id);
        const escaped_kind = try unified.jsonEscape(session.allocator, kind);
        defer session.allocator.free(escaped_kind);
        const escaped_version = try unified.jsonEscape(session.allocator, version);
        defer session.allocator.free(escaped_version);
        const host_roles_json = try normalizedHostRolesJson(session.allocator, item.object.get("host_roles"));
        defer session.allocator.free(host_roles_json);
        const binding_scopes_json = try normalizedBindingScopesJson(session.allocator, item.object.get("binding_scopes"));
        defer session.allocator.free(binding_scopes_json);
        const help_json = if (help_md) |value| blk: {
            const escaped = try unified.jsonEscape(session.allocator, value);
            defer session.allocator.free(escaped);
            break :blk try std.fmt.allocPrint(session.allocator, "\"{s}\"", .{escaped});
        } else try session.allocator.dupe(u8, "null");
        defer session.allocator.free(help_json);

        if (!first) try out.append(session.allocator, ',');
        first = false;
        try out.writer(session.allocator).print(
            "{{\"package_id\":\"{s}\",\"kind\":\"{s}\",\"version\":\"{s}\",\"enabled\":true,\"host_roles\":{s},\"binding_scopes\":{s},\"runtime_kind\":\"{s}\",\"help_md\":{s}}}",
            .{
                escaped_package_id,
                escaped_kind,
                escaped_version,
                host_roles_json,
                binding_scopes_json,
                runtime_kind.asString(),
                help_json,
            },
        );
    }

    try out.append(session.allocator, ']');
    return out.toOwnedSlice(session.allocator);
}

fn sessionHasPublishedCapabilityProvider(session: anytype, package_id: []const u8) bool {
    const nodes_root = session.nodes.get(session.nodes_root_id) orelse return false;
    var node_it = nodes_root.children.iterator();
    while (node_it.next()) |node_entry| {
        const node_dir_id = node_entry.value_ptr.*;
        const venoms_root_id = session.lookupChild(node_dir_id, "venoms") orelse continue;
        const venoms_root = session.nodes.get(venoms_root_id) orelse continue;
        if (venoms_root.kind != .dir) continue;

        var venom_it = venoms_root.children.iterator();
        while (venom_it.next()) |venom_entry| {
            const venom_id = venom_entry.key_ptr.*;
            if (!venom_model.isCapabilityVenomId(venom_id)) continue;
            if (std.mem.eql(u8, venom_id, package_id)) return true;
            if (std.mem.startsWith(u8, venom_id, package_id) and
                venom_id.len > package_id.len and
                venom_id[package_id.len] == '-')
            {
                return true;
            }
        }
    }
    return false;
}

pub fn buildCatalogProvidersJson(session: anytype) ![]u8 {
    session.refreshDynamicDirectory(session.nodes_root_id) catch {};

    const nodes_root = session.nodes.get(session.nodes_root_id) orelse return session.allocator.dupe(u8, "[]");
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(session.allocator);
    try out.append(session.allocator, '[');

    var first = true;
    var node_it = nodes_root.children.iterator();
    while (node_it.next()) |node_entry| {
        const node_id = node_entry.key_ptr.*;
        const node_dir_id = node_entry.value_ptr.*;
        var node_metadata = try resolveNodeMetadata(session, node_id);
        defer node_metadata.deinit(session.allocator);
        const venoms_root_id = session.lookupChild(node_dir_id, "venoms") orelse continue;
        const venoms_root = session.nodes.get(venoms_root_id) orelse continue;
        if (venoms_root.kind != .dir) continue;

        var venom_it = venoms_root.children.iterator();
        while (venom_it.next()) |venom_entry| {
            const venom_id = venom_entry.key_ptr.*;
            if (!venom_model.isCapabilityVenomId(venom_id)) continue;

            const venom_dir_id = venom_entry.value_ptr.*;
            const package_id = try packageIdForProvider(session, venom_dir_id, venom_id);
            defer session.allocator.free(package_id);
            const state = try providerStateForDir(session, venom_dir_id);
            defer session.allocator.free(state);
            const endpoint_path = try providerEndpointPathForDir(session, node_id, venom_id, venom_dir_id);
            defer if (endpoint_path) |value| session.allocator.free(value);
            const runtime_kind = try providerRuntimeKindForDir(session, venom_dir_id);
            var runtime_summary = try providerRuntimeSummaryForDir(session, venom_dir_id, runtime_kind, state);
            defer runtime_summary.deinit(session.allocator);
            const host_role = try providerHostRoleForDir(session, node_id, venom_dir_id);
            const binding_eligibility_json = try providerBindingEligibilityJson(session, venom_dir_id);
            defer session.allocator.free(binding_eligibility_json);
            const provider_id = try std.fmt.allocPrint(session.allocator, "{s}:{s}", .{ node_id, venom_id });
            defer session.allocator.free(provider_id);

            const provider_id_escaped = try unified.jsonEscape(session.allocator, provider_id);
            defer session.allocator.free(provider_id_escaped);
            const package_id_escaped = try unified.jsonEscape(session.allocator, package_id);
            defer session.allocator.free(package_id_escaped);
            const venom_id_escaped = try unified.jsonEscape(session.allocator, venom_id);
            defer session.allocator.free(venom_id_escaped);
            const node_id_escaped = try unified.jsonEscape(session.allocator, node_id);
            defer session.allocator.free(node_id_escaped);
            const state_escaped = try unified.jsonEscape(session.allocator, state);
            defer session.allocator.free(state_escaped);
            const node_name_escaped = try unified.jsonEscape(session.allocator, node_metadata.node_name);
            defer session.allocator.free(node_name_escaped);
            const platform_os_escaped = try unified.jsonEscape(session.allocator, node_metadata.platform_os);
            defer session.allocator.free(platform_os_escaped);
            const platform_arch_escaped = try unified.jsonEscape(session.allocator, node_metadata.platform_arch);
            defer session.allocator.free(platform_arch_escaped);
            const platform_runtime_escaped = try unified.jsonEscape(session.allocator, node_metadata.platform_runtime_kind);
            defer session.allocator.free(platform_runtime_escaped);
            const endpoint_json = if (endpoint_path) |value| blk: {
                const escaped = try unified.jsonEscape(session.allocator, value);
                defer session.allocator.free(escaped);
                break :blk try std.fmt.allocPrint(session.allocator, "\"{s}\"", .{escaped});
            } else try session.allocator.dupe(u8, "null");
            defer session.allocator.free(endpoint_json);

            if (!first) try out.append(session.allocator, ',');
            first = false;
            try out.writer(session.allocator).print(
                "{{\"provider_id\":\"{s}\",\"package_id\":\"{s}\",\"venom_id\":\"{s}\",\"host_role\":\"{s}\",\"host_id\":\"{s}\",\"node_name\":\"{s}\",\"platform\":{{\"os\":\"{s}\",\"arch\":\"{s}\",\"runtime_kind\":\"{s}\"}},\"runtime_kind\":\"{s}\",\"install\":{s},\"provider\":{s},\"policy\":{s},\"state\":\"{s}\",\"health\":\"{s}\",\"binding_eligibility\":{s},\"endpoint_path\":{s}}}",
                .{
                    provider_id_escaped,
                    package_id_escaped,
                    venom_id_escaped,
                    host_role.asString(),
                    node_id_escaped,
                    node_name_escaped,
                    platform_os_escaped,
                    platform_arch_escaped,
                    platform_runtime_escaped,
                    runtime_kind.asString(),
                    runtime_summary.install_json,
                    runtime_summary.provider_json,
                    runtime_summary.policy_json,
                    state_escaped,
                    state_escaped,
                    binding_eligibility_json,
                    endpoint_json,
                },
            );
        }
    }

    try out.append(session.allocator, ']');
    return out.toOwnedSlice(session.allocator);
}

pub fn buildCatalogTargetsJson(session: anytype) ![]u8 {
    const TargetCapability = struct {
        binding_path: ?[]u8 = null,
        target_path: ?[]u8 = null,
        provider_id: ?[]u8 = null,
        available: bool = false,

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            if (self.binding_path) |value| allocator.free(value);
            if (self.target_path) |value| allocator.free(value);
            if (self.provider_id) |value| allocator.free(value);
            self.* = .{};
        }
    };

    const TargetEntry = struct {
        target_id: []u8,
        node_id: ?[]u8 = null,
        node_name: ?[]u8 = null,
        platform_os: ?[]u8 = null,
        platform_arch: ?[]u8 = null,
        platform_runtime_kind: ?[]u8 = null,
        computer: TargetCapability = .{},
        browser: TargetCapability = .{},

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.target_id);
            if (self.node_id) |value| allocator.free(value);
            if (self.node_name) |value| allocator.free(value);
            if (self.platform_os) |value| allocator.free(value);
            if (self.platform_arch) |value| allocator.free(value);
            if (self.platform_runtime_kind) |value| allocator.free(value);
            self.computer.deinit(allocator);
            self.browser.deinit(allocator);
            self.* = undefined;
        }
    };

    var targets = std.ArrayListUnmanaged(TargetEntry){};
    defer {
        for (targets.items) |*entry| entry.deinit(session.allocator);
        targets.deinit(session.allocator);
    }

    for (session.workspace_binds.items) |bind| {
        if (bind.kind != .workspace) continue;
        const parsed = parseTargetBinding(bind.bind_path) orelse continue;

        var entry_index: ?usize = null;
        for (targets.items, 0..) |entry, idx| {
            if (std.mem.eql(u8, entry.target_id, parsed.target_id)) {
                entry_index = idx;
                break;
            }
        }
        if (entry_index == null) {
            try targets.append(session.allocator, .{
                .target_id = try session.allocator.dupe(u8, parsed.target_id),
            });
            entry_index = targets.items.len - 1;
        }

        var entry = &targets.items[entry_index.?];
        const capability = if (std.mem.eql(u8, parsed.capability, "computer")) &entry.computer else &entry.browser;
        if (capability.binding_path) |value| session.allocator.free(value);
        capability.binding_path = try session.allocator.dupe(u8, bind.bind_path);
        if (capability.target_path) |value| session.allocator.free(value);
        capability.target_path = try session.allocator.dupe(u8, bind.target_path);
        capability.available = session.resolveAbsolutePathNoBinds(bind.target_path) != null;

        if (try parseNodeProviderBinding(session.allocator, bind.target_path)) |provider_value| {
            var provider = provider_value;
            defer provider.deinit(session.allocator);
            const resolved_node_id = if (try session.resolveCatalogControlPlaneNodeIdForVenom(provider.node_id, provider.venom_id)) |value|
                value
            else
                try session.allocator.dupe(u8, provider.node_id);
            defer session.allocator.free(resolved_node_id);

            if (capability.provider_id) |value| session.allocator.free(value);
            capability.provider_id = try std.fmt.allocPrint(session.allocator, "{s}:{s}", .{ resolved_node_id, provider.venom_id });

            if (entry.node_id == null) entry.node_id = try session.allocator.dupe(u8, resolved_node_id);
            if (entry.node_name == null or entry.platform_os == null or entry.platform_arch == null or entry.platform_runtime_kind == null) {
                var node_metadata = try resolveNodeMetadata(session, resolved_node_id);
                defer node_metadata.deinit(session.allocator);

                if (entry.node_name) |value| session.allocator.free(value);
                entry.node_name = try session.allocator.dupe(u8, node_metadata.node_name);
                if (entry.platform_os) |value| session.allocator.free(value);
                entry.platform_os = try session.allocator.dupe(u8, node_metadata.platform_os);
                if (entry.platform_arch) |value| session.allocator.free(value);
                entry.platform_arch = try session.allocator.dupe(u8, node_metadata.platform_arch);
                if (entry.platform_runtime_kind) |value| session.allocator.free(value);
                entry.platform_runtime_kind = try session.allocator.dupe(u8, node_metadata.platform_runtime_kind);
            }
        }
    }

    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(session.allocator);
    try out.append(session.allocator, '[');

    for (targets.items, 0..) |entry, idx| {
        if (idx != 0) try out.append(session.allocator, ',');
        const escaped_target_id = try unified.jsonEscape(session.allocator, entry.target_id);
        defer session.allocator.free(escaped_target_id);
        const node_id_json = try optionalJsonString(session.allocator, entry.node_id);
        defer session.allocator.free(node_id_json);
        const node_name_json = try optionalJsonString(session.allocator, entry.node_name);
        defer session.allocator.free(node_name_json);
        const platform_os_json = try optionalJsonString(session.allocator, entry.platform_os);
        defer session.allocator.free(platform_os_json);
        const platform_arch_json = try optionalJsonString(session.allocator, entry.platform_arch);
        defer session.allocator.free(platform_arch_json);
        const platform_runtime_json = try optionalJsonString(session.allocator, entry.platform_runtime_kind);
        defer session.allocator.free(platform_runtime_json);
        const computer_paths_json = try capabilityPathsJson(session.allocator, entry.computer);
        defer session.allocator.free(computer_paths_json);
        const browser_paths_json = try capabilityPathsJson(session.allocator, entry.browser);
        defer session.allocator.free(browser_paths_json);
        const computer_provider_json = try optionalJsonString(session.allocator, entry.computer.provider_id);
        defer session.allocator.free(computer_provider_json);
        const browser_provider_json = try optionalJsonString(session.allocator, entry.browser.provider_id);
        defer session.allocator.free(browser_provider_json);
        try out.writer(session.allocator).print(
            "{{\"target_id\":\"{s}\",\"node_id\":{s},\"node_name\":{s},\"platform\":{{\"os\":{s},\"arch\":{s},\"runtime_kind\":{s}}},\"paths\":{{\"computer\":{s},\"browser\":{s}}},\"provider_ids\":{{\"computer\":{s},\"browser\":{s}}},\"availability\":{{\"computer\":\"{s}\",\"browser\":\"{s}\"}}}}",
            .{
                escaped_target_id,
                node_id_json,
                node_name_json,
                platform_os_json,
                platform_arch_json,
                platform_runtime_json,
                computer_paths_json,
                browser_paths_json,
                computer_provider_json,
                browser_provider_json,
                if (entry.computer.available) "online" else "offline",
                if (entry.browser.available) "online" else "offline",
            },
        );
    }

    try out.append(session.allocator, ']');
    return out.toOwnedSlice(session.allocator);
}

pub fn buildCatalogBindingsJson(session: anytype) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(session.allocator);
    try out.append(session.allocator, '[');

    var first = true;
    for (session.scoped_venom_bindings.items) |binding| {
        if (!venom_model.isCapabilityVenomId(binding.venom_id)) continue;
        if (!std.mem.startsWith(u8, binding.venom_path, "/.spiderweb/venoms/")) continue;

        const provider_id_json = if (binding.provider_node_id) |value|
            try std.fmt.allocPrint(session.allocator, "\"{s}:{s}\"", .{ value, binding.venom_id })
        else
            try session.allocator.dupe(u8, "null");
        defer session.allocator.free(provider_id_json);

        if (!first) try out.append(session.allocator, ',');
        first = false;
        try out.writer(session.allocator).print(
            "{{\"binding_id\":\"workspace:{s}\",\"scope\":\"{s}\",\"alias\":\"{s}\",\"binding_path\":\"{s}\",\"target_path\":\"{s}\",\"provider_id\":{s}}}",
            .{
                binding.venom_id,
                venom_model.BindingScope.workspace.asString(),
                binding.venom_id,
                binding.venom_path,
                if (binding.provider_venom_path) |value| value else binding.venom_path,
                provider_id_json,
            },
        );
    }

    for (session.workspace_binds.items) |bind| {
        if (bind.kind != .workspace) continue;
        if (!std.mem.startsWith(u8, bind.bind_path, "/.spiderweb/venoms/")) continue;
        if (hasScopedBindingForPath(session, bind.bind_path)) continue;

        const alias = bind.bind_path["/.spiderweb/venoms/".len..];
        if (alias.len == 0 or std.mem.indexOfScalar(u8, alias, '/') != null) continue;
        if (!venom_model.isCapabilityVenomId(alias)) continue;

        const provider_id_json = if (std.mem.startsWith(u8, bind.target_path, "/nodes/")) blk: {
            const after_prefix = bind.target_path["/nodes/".len..];
            const node_end = std.mem.indexOfScalar(u8, after_prefix, '/') orelse break :blk try session.allocator.dupe(u8, "null");
            const node_id = after_prefix[0..node_end];
            const after_node = after_prefix[node_end..];
            const provider_venom_id = if (std.mem.startsWith(u8, after_node, "/venoms/")) blk2: {
                const tail = after_node["/venoms/".len..];
                const venom_end = std.mem.indexOfScalar(u8, tail, '/') orelse tail.len;
                break :blk2 tail[0..venom_end];
            } else alias;
            const resolved_node_id = if (try session.resolveCatalogControlPlaneNodeIdForVenom(node_id, provider_venom_id)) |value|
                value
            else
                try session.allocator.dupe(u8, node_id);
            defer session.allocator.free(resolved_node_id);
            break :blk try std.fmt.allocPrint(session.allocator, "\"{s}:{s}\"", .{ resolved_node_id, provider_venom_id });
        } else try session.allocator.dupe(u8, "null");
        defer session.allocator.free(provider_id_json);

        if (!first) try out.append(session.allocator, ',');
        first = false;
        try out.writer(session.allocator).print(
            "{{\"binding_id\":\"workspace:{s}\",\"scope\":\"{s}\",\"alias\":\"{s}\",\"binding_path\":\"{s}\",\"target_path\":\"{s}\",\"provider_id\":{s}}}",
            .{
                alias,
                venom_model.BindingScope.workspace.asString(),
                alias,
                bind.bind_path,
                bind.target_path,
                provider_id_json,
            },
        );
    }

    try out.append(session.allocator, ']');
    return out.toOwnedSlice(session.allocator);
}

fn hasScopedBindingForPath(session: anytype, binding_path: []const u8) bool {
    for (session.scoped_venom_bindings.items) |binding| {
        if (std.mem.eql(u8, binding.venom_path, binding_path)) return true;
    }
    return false;
}

const ResolvedNodeMetadata = struct {
    node_name: []u8,
    platform_os: []u8,
    platform_arch: []u8,
    platform_runtime_kind: []u8,

    fn deinit(self: *ResolvedNodeMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.node_name);
        allocator.free(self.platform_os);
        allocator.free(self.platform_arch);
        allocator.free(self.platform_runtime_kind);
        self.* = undefined;
    }
};

pub const ParsedTargetBinding = struct {
    target_id: []const u8,
    capability: []const u8,
};

const ParsedNodeProvider = struct {
    node_id: []u8,
    venom_id: []u8,

    fn deinit(self: *ParsedNodeProvider, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
        allocator.free(self.venom_id);
        self.* = undefined;
    }
};

fn resolveNodeMetadata(session: anytype, node_id: []const u8) !ResolvedNodeMetadata {
    if (session.control_plane) |plane| {
        const payload = try std.fmt.allocPrint(session.allocator, "{{\"node_id\":\"{s}\"}}", .{node_id});
        defer session.allocator.free(payload);
        const raw = plane.getNode(payload) catch null;
        if (raw) |node_json| {
            defer session.allocator.free(node_json);
            var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, node_json, .{}) catch null;
            if (parsed) |*parsed_value| {
                defer parsed_value.deinit();
                if (parsed_value.value == .object) {
                    if (parsed_value.value.object.get("node")) |node_value| {
                        if (node_value == .object) {
                            const platform_value = node_value.object.get("platform");
                            const platform_obj = if (platform_value) |value|
                                if (value == .object) value.object else null
                            else
                                null;
                            return .{
                                .node_name = try session.allocator.dupe(u8, getString(node_value.object, "node_name") orelse node_id),
                                .platform_os = try session.allocator.dupe(u8, if (platform_obj) |obj| getString(obj, "os") orelse "unknown" else "unknown"),
                                .platform_arch = try session.allocator.dupe(u8, if (platform_obj) |obj| getString(obj, "arch") orelse "unknown" else "unknown"),
                                .platform_runtime_kind = try session.allocator.dupe(u8, if (platform_obj) |obj| getString(obj, "runtime_kind") orelse "unknown" else "unknown"),
                            };
                        }
                    }
                }
            }
        }
    }
    return .{
        .node_name = try session.allocator.dupe(u8, node_id),
        .platform_os = try session.allocator.dupe(u8, "unknown"),
        .platform_arch = try session.allocator.dupe(u8, "unknown"),
        .platform_runtime_kind = try session.allocator.dupe(u8, "unknown"),
    };
}

fn parseTargetBinding(binding_path: []const u8) ?ParsedTargetBinding {
    const prefix = "/.spiderweb/targets/";
    if (!std.mem.startsWith(u8, binding_path, prefix)) return null;
    const tail = binding_path[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, tail, '/') orelse return null;
    const target_id = tail[0..slash];
    const capability = tail[slash + 1 ..];
    if (target_id.len == 0) return null;
    if (!std.mem.eql(u8, capability, "computer") and !std.mem.eql(u8, capability, "browser")) return null;
    return .{ .target_id = target_id, .capability = capability };
}

pub fn parseTargetBindingForSession(binding_path: []const u8) ?ParsedTargetBinding {
    return parseTargetBinding(binding_path);
}

fn parseNodeProviderBinding(allocator: std.mem.Allocator, target_path: []const u8) !?ParsedNodeProvider {
    const prefix = "/nodes/";
    if (!std.mem.startsWith(u8, target_path, prefix)) return null;
    const after_nodes = target_path[prefix.len..];
    const node_end = std.mem.indexOfScalar(u8, after_nodes, '/') orelse return null;
    const node_id = after_nodes[0..node_end];
    const after_node = after_nodes[node_end..];
    if (!std.mem.startsWith(u8, after_node, "/venoms/")) return null;
    const after_venoms = after_node["/venoms/".len..];
    const venom_end = std.mem.indexOfScalar(u8, after_venoms, '/') orelse after_venoms.len;
    const venom_id = after_venoms[0..venom_end];
    if (node_id.len == 0 or venom_id.len == 0) return null;
    return .{
        .node_id = try allocator.dupe(u8, node_id),
        .venom_id = try allocator.dupe(u8, venom_id),
    };
}

fn optionalJsonString(allocator: std.mem.Allocator, value: ?[]const u8) ![]u8 {
    if (value) |present| {
        const escaped = try unified.jsonEscape(allocator, present);
        defer allocator.free(escaped);
        return std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    }
    return allocator.dupe(u8, "null");
}

fn capabilityPathsJson(allocator: std.mem.Allocator, capability: anytype) ![]u8 {
    return optionalJsonString(allocator, capability.binding_path);
}

pub fn buildWorkspaceBindsArrayJson(session: anytype) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(session.allocator);
    try out.append(session.allocator, '[');
    var first = true;
    for (session.workspace_binds.items) |bind| {
        if (bind.kind != .workspace) continue;
        if (!first) try out.append(session.allocator, ',');
        first = false;
        const escaped_bind = try unified.jsonEscape(session.allocator, bind.bind_path);
        defer session.allocator.free(escaped_bind);
        const escaped_target = try unified.jsonEscape(session.allocator, bind.target_path);
        defer session.allocator.free(escaped_target);
        try out.writer(session.allocator).print(
            "{{\"bind_path\":\"{s}\",\"target_path\":\"{s}\"}}",
            .{ escaped_bind, escaped_target },
        );
    }
    try out.append(session.allocator, ']');
    return out.toOwnedSlice(session.allocator);
}

fn collectCapabilityVenomIds(session: anytype, out: *std.ArrayListUnmanaged([]u8)) !void {
    for (session.scoped_venom_bindings.items) |binding| {
        if (!venom_model.isCapabilityVenomId(binding.venom_id)) continue;
        try appendUniqueString(session.allocator, out, binding.venom_id);
    }

    const nodes_root = session.nodes.get(session.nodes_root_id) orelse return;
    var node_it = nodes_root.children.iterator();
    while (node_it.next()) |node_entry| {
        const node_dir_id = node_entry.value_ptr.*;
        const venoms_root_id = session.lookupChild(node_dir_id, "venoms") orelse continue;
        const venoms_root = session.nodes.get(venoms_root_id) orelse continue;
        if (venoms_root.kind != .dir) continue;
        var venom_it = venoms_root.children.iterator();
        while (venom_it.next()) |venom_entry| {
            const venom_id = venom_entry.key_ptr.*;
            if (!venom_model.isCapabilityVenomId(venom_id)) continue;
            try appendUniqueString(session.allocator, out, venom_id);
        }
    }
}

fn appendUniqueString(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged([]u8),
    value: []const u8,
) !void {
    for (out.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    try out.append(allocator, try allocator.dupe(u8, value));
}

fn getString(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = obj.get(name) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn normalizedRuntimeKindFromObject(obj: std.json.ObjectMap) venom_model.RuntimeKind {
    if (getString(obj, "runtime_kind")) |runtime_kind| {
        return venom_model.RuntimeKind.fromRuntimeType(runtime_kind);
    }
    const runtime_value = obj.get("runtime") orelse return .native;
    if (runtime_value != .object) return .native;
    const runtime_type = getString(runtime_value.object, "type") orelse return .native;
    return venom_model.RuntimeKind.fromRuntimeType(runtime_type);
}

fn normalizedHostRolesJson(allocator: std.mem.Allocator, maybe_host_roles: ?std.json.Value) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');

    var first = true;
    if (maybe_host_roles) |host_roles_value| {
        if (host_roles_value == .array) {
            for (host_roles_value.array.items) |item| {
                if (item != .string) continue;
                if (!first) try out.append(allocator, ',');
                first = false;
                try out.writer(allocator).print("\"{s}\"", .{venom_model.HostRole.fromString(item.string).asString()});
            }
        }
    }

    if (first) try out.writer(allocator).print("\"{s}\"", .{venom_model.HostRole.spiderweb.asString()});
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn normalizedBindingScopesJson(allocator: std.mem.Allocator, maybe_binding_scopes: ?std.json.Value) ![]u8 {
    var has_workspace = false;
    var has_agent = false;
    var has_client = false;
    var has_node = false;

    if (maybe_binding_scopes) |binding_scopes| {
        if (binding_scopes == .array) {
            for (binding_scopes.array.items) |item| {
                if (item != .string) continue;
                if (std.mem.eql(u8, item.string, venom_model.BindingScope.workspace.asString())) has_workspace = true;
                if (std.mem.eql(u8, item.string, venom_model.BindingScope.agent.asString())) has_agent = true;
                if (std.mem.eql(u8, item.string, venom_model.BindingScope.client.asString())) has_client = true;
                if (std.mem.eql(u8, item.string, venom_model.BindingScope.node.asString())) has_node = true;
            }
        }
    }

    if (!has_workspace and !has_agent and !has_client and !has_node) has_workspace = true;

    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');

    var first = true;
    const candidates = [_]struct {
        enabled: bool,
        scope: venom_model.BindingScope,
    }{
        .{ .enabled = has_workspace, .scope = .workspace },
        .{ .enabled = has_agent, .scope = .agent },
        .{ .enabled = has_client, .scope = .client },
        .{ .enabled = has_node, .scope = .node },
    };
    for (candidates) |candidate| {
        if (!candidate.enabled) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        try out.writer(allocator).print("\"{s}\"", .{candidate.scope.asString()});
    }

    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn packageIdForProvider(session: anytype, venom_dir_id: u32, venom_id: []const u8) ![]u8 {
    if (session.lookupChild(venom_dir_id, "PACKAGE.json")) |package_id| {
        const package_node = session.nodes.get(package_id) orelse return session.allocator.dupe(u8, venom_id);
        if (package_node.kind == .file and package_node.content.len != 0) {
            var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, package_node.content, .{}) catch return session.allocator.dupe(u8, venom_id);
            defer parsed.deinit();
            if (parsed.value == .object) {
                if (getString(parsed.value.object, "package_id")) |value| return session.allocator.dupe(u8, value);
                if (getString(parsed.value.object, "venom_id")) |value| return session.allocator.dupe(u8, value);
            }
        }
    }
    return session.allocator.dupe(u8, venom_id);
}

fn providerHostRoleForDir(session: anytype, node_id: []const u8, venom_dir_id: u32) !venom_model.HostRole {
    if (session.lookupChild(venom_dir_id, "PACKAGE.json")) |package_id| {
        const package_node = session.nodes.get(package_id) orelse return venom_model.defaultHostRoleForNodeId(node_id);
        if (package_node.kind == .file and package_node.content.len != 0) {
            var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, package_node.content, .{}) catch return venom_model.defaultHostRoleForNodeId(node_id);
            defer parsed.deinit();
            if (parsed.value == .object) {
                if (firstHostRoleFromValue(parsed.value.object.get("host_roles"))) |host_role| {
                    return host_role;
                }
            }
        }
    }
    return venom_model.defaultHostRoleForNodeId(node_id);
}

fn providerBindingEligibilityJson(session: anytype, venom_dir_id: u32) ![]u8 {
    if (session.lookupChild(venom_dir_id, "PACKAGE.json")) |package_id| {
        const package_node = session.nodes.get(package_id) orelse return session.allocator.dupe(u8, "[\"workspace\",\"agent\",\"client\",\"node\"]");
        if (package_node.kind == .file and package_node.content.len != 0) {
            var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, package_node.content, .{}) catch return session.allocator.dupe(u8, "[\"workspace\",\"agent\",\"client\",\"node\"]");
            defer parsed.deinit();
            if (parsed.value == .object) {
                return normalizedBindingScopesJson(
                    session.allocator,
                    parsed.value.object.get("binding_scopes"),
                );
            }
        }
    }
    return session.allocator.dupe(u8, "[\"workspace\",\"agent\",\"client\",\"node\"]");
}

fn providerStateForDir(session: anytype, venom_dir_id: u32) ![]u8 {
    const status_id = session.lookupChild(venom_dir_id, "STATUS.json") orelse return session.allocator.dupe(u8, "online");
    const status_node = session.nodes.get(status_id) orelse return session.allocator.dupe(u8, "online");
    if (status_node.kind != .file) return session.allocator.dupe(u8, "online");
    var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, status_node.content, .{}) catch return session.allocator.dupe(u8, "online");
    defer parsed.deinit();
    if (parsed.value != .object) return session.allocator.dupe(u8, "online");
    if (getString(parsed.value.object, "state")) |value| return session.allocator.dupe(u8, value);
    return session.allocator.dupe(u8, "online");
}

fn providerEndpointPathForDir(session: anytype, node_id: []const u8, venom_id: []const u8, venom_dir_id: u32) !?[]u8 {
    if (try session.firstVenomMountPath(venom_dir_id)) |value| return value;
    if (try session.venomEndpointPath(venom_dir_id)) |value| return value;
    return try std.fmt.allocPrint(session.allocator, "/nodes/{s}/venoms/{s}", .{ node_id, venom_id });
}

fn providerRuntimeKindForDir(session: anytype, venom_dir_id: u32) !venom_model.RuntimeKind {
    const runtime_id = session.lookupChild(venom_dir_id, "RUNTIME.json") orelse return .native;
    const runtime_node = session.nodes.get(runtime_id) orelse return .native;
    if (runtime_node.kind != .file) return .native;
    var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, runtime_node.content, .{}) catch return .native;
    defer parsed.deinit();
    if (parsed.value != .object) return .native;
    const runtime_type = getString(parsed.value.object, "type") orelse return .native;
    return venom_model.RuntimeKind.fromRuntimeType(runtime_type);
}

const ProviderRuntimeSummary = struct {
    install_json: []u8,
    provider_json: []u8,
    policy_json: []u8,

    fn deinit(self: *ProviderRuntimeSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.install_json);
        allocator.free(self.provider_json);
        allocator.free(self.policy_json);
        self.* = undefined;
    }
};

fn providerRuntimeSummaryForDir(
    session: anytype,
    venom_dir_id: u32,
    runtime_kind: venom_model.RuntimeKind,
    fallback_state: []const u8,
) !ProviderRuntimeSummary {
    var summary = ProviderRuntimeSummary{
        .install_json = try std.fmt.allocPrint(
            session.allocator,
            "{{\"installed\":true,\"enabled\":true,\"runtime_type\":\"{s}\"}}",
            .{runtime_kind.asString()},
        ),
        .provider_json = try std.fmt.allocPrint(
            session.allocator,
            "{{\"state\":\"{s}\",\"running\":{s}}}",
            .{ fallback_state, if (std.mem.eql(u8, fallback_state, "offline")) "false" else "true" },
        ),
        .policy_json = try session.allocator.dupe(u8, "null"),
    };
    errdefer summary.deinit(session.allocator);

    const status_id = session.lookupChild(venom_dir_id, "STATUS.json") orelse return summary;
    const status_node = session.nodes.get(status_id) orelse return summary;
    if (status_node.kind != .file) return summary;

    var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, status_node.content, .{}) catch return summary;
    defer parsed.deinit();
    if (parsed.value != .object) return summary;
    const runtime_value = parsed.value.object.get("runtime") orelse return summary;
    if (runtime_value != .object) return summary;

    if (runtime_value.object.get("install")) |value| {
        const next_json = try std.fmt.allocPrint(session.allocator, "{f}", .{std.json.fmt(value, .{})});
        session.allocator.free(summary.install_json);
        summary.install_json = next_json;
    }
    if (runtime_value.object.get("provider")) |value| {
        const next_json = try std.fmt.allocPrint(session.allocator, "{f}", .{std.json.fmt(value, .{})});
        session.allocator.free(summary.provider_json);
        summary.provider_json = next_json;
    }
    if (runtime_value.object.get("policy")) |value| {
        const next_json = try std.fmt.allocPrint(session.allocator, "{f}", .{std.json.fmt(value, .{})});
        session.allocator.free(summary.policy_json);
        summary.policy_json = next_json;
    }

    return summary;
}

fn firstHostRoleFromValue(maybe_hosts: ?std.json.Value) ?venom_model.HostRole {
    const hosts_value = maybe_hosts orelse return null;
    if (hosts_value != .array) return null;
    for (hosts_value.array.items) |item| {
        if (item != .string) continue;
        return venom_model.HostRole.fromString(item.string);
    }
    return null;
}
