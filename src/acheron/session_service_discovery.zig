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
        if (!venom_model.isCapabilityVenomId(package_id)) continue;

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
        const host_roles_json = try normalizedHostRolesJson(session.allocator, item.object.get("host_roles") orelse item.object.get("hosts"));
        defer session.allocator.free(host_roles_json);
        const binding_scopes_json = try normalizedBindingScopesJson(session.allocator, item.object.get("binding_scopes") orelse item.object.get("projection_modes"));
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
            "{{\"package_id\":\"{s}\",\"kind\":\"{s}\",\"version\":\"{s}\",\"host_roles\":{s},\"binding_scopes\":{s},\"runtime_kind\":\"{s}\",\"help_md\":{s}}}",
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
            const host_role = try providerHostRoleForDir(session, node_id, venom_dir_id);
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
            const endpoint_json = if (endpoint_path) |value| blk: {
                const escaped = try unified.jsonEscape(session.allocator, value);
                defer session.allocator.free(escaped);
                break :blk try std.fmt.allocPrint(session.allocator, "\"{s}\"", .{escaped});
            } else try session.allocator.dupe(u8, "null");
            defer session.allocator.free(endpoint_json);

            if (!first) try out.append(session.allocator, ',');
            first = false;
            try out.writer(session.allocator).print(
                "{{\"provider_id\":\"{s}\",\"package_id\":\"{s}\",\"venom_id\":\"{s}\",\"host_role\":\"{s}\",\"host_id\":\"{s}\",\"runtime_kind\":\"{s}\",\"install\":{{\"installed\":true,\"enabled\":{s}}},\"state\":\"{s}\",\"health\":\"{s}\",\"binding_eligibility\":[\"workspace\",\"agent\",\"client\",\"node\"],\"endpoint_path\":{s}}}",
                .{
                    provider_id_escaped,
                    package_id_escaped,
                    venom_id_escaped,
                    host_role.asString(),
                    node_id_escaped,
                    runtime_kind.asString(),
                    if (std.mem.eql(u8, state, "offline")) "false" else "true",
                    state_escaped,
                    state_escaped,
                    endpoint_json,
                },
            );
        }
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

    try out.append(session.allocator, ']');
    return out.toOwnedSlice(session.allocator);
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

fn normalizedHostRolesJson(allocator: std.mem.Allocator, maybe_hosts: ?std.json.Value) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');

    var first = true;
    if (maybe_hosts) |hosts_value| {
        if (hosts_value == .array) {
            for (hosts_value.array.items) |item| {
                if (item != .string) continue;
                const mapped = if (std.mem.eql(u8, item.string, "worker") or std.mem.eql(u8, item.string, "client"))
                    venom_model.HostRole.client
                else if (std.mem.eql(u8, item.string, "node"))
                    venom_model.HostRole.node
                else
                    venom_model.HostRole.spiderweb;
                if (!first) try out.append(allocator, ',');
                first = false;
                try out.writer(allocator).print("\"{s}\"", .{mapped.asString()});
            }
        }
    }

    if (first) try out.writer(allocator).print("\"{s}\"", .{venom_model.HostRole.spiderweb.asString()});
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn normalizedBindingScopesJson(allocator: std.mem.Allocator, maybe_binding_scopes_or_projection_modes: ?std.json.Value) ![]u8 {
    var has_workspace = false;
    var has_agent = false;
    var has_client = false;
    var has_node = false;

    if (maybe_binding_scopes_or_projection_modes) |projection_modes| {
        if (projection_modes == .array) {
            for (projection_modes.array.items) |item| {
                if (item != .string) continue;
                if (std.mem.eql(u8, item.string, venom_model.BindingScope.workspace.asString())) has_workspace = true;
                if (std.mem.eql(u8, item.string, venom_model.BindingScope.agent.asString())) has_agent = true;
                if (std.mem.eql(u8, item.string, venom_model.BindingScope.client.asString())) has_client = true;
                if (std.mem.eql(u8, item.string, venom_model.BindingScope.node.asString())) has_node = true;
                if (std.mem.eql(u8, item.string, "workspace_service")) has_workspace = true;
                if (std.mem.eql(u8, item.string, "worker_private")) has_agent = true;
                if (std.mem.eql(u8, item.string, "host_local")) has_node = true;
                if (std.mem.eql(u8, item.string, "node_export")) has_workspace = true;
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
                if (firstHostRoleFromValue(parsed.value.object.get("host_roles") orelse parsed.value.object.get("hosts"))) |host_role| {
                    return host_role;
                }
            }
        }
    }
    return venom_model.defaultHostRoleForNodeId(node_id);
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

fn firstHostRoleFromValue(maybe_hosts: ?std.json.Value) ?venom_model.HostRole {
    const hosts_value = maybe_hosts orelse return null;
    if (hosts_value != .array) return null;
    for (hosts_value.array.items) |item| {
        if (item != .string) continue;
        return venom_model.HostRole.fromString(item.string);
    }
    return null;
}
