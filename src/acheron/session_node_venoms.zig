const std = @import("std");
const unified = @import("spider-protocol").unified;
const shared_node = @import("spiderweb_node");
const venom_model = @import("../venom_model.zig");
const workspace_policy = @import("../workspaces/policy.zig");

pub const NodeResourceView = struct {
    fs: bool = false,
    camera: bool = false,
    screen: bool = false,
    user: bool = false,
    terminals: std.ArrayListUnmanaged([]u8) = .{},
    roots: std.ArrayListUnmanaged([]u8) = .{},

    pub fn deinit(self: *NodeResourceView, allocator: std.mem.Allocator) void {
        for (self.terminals.items) |terminal_id| allocator.free(terminal_id);
        self.terminals.deinit(allocator);
        for (self.roots.items) |root| allocator.free(root);
        self.roots.deinit(allocator);
        self.* = undefined;
    }

    fn addRoot(self: *NodeResourceView, allocator: std.mem.Allocator, root: []const u8) !void {
        if (root.len == 0) return;
        for (self.roots.items) |existing| {
            if (std.mem.eql(u8, existing, root)) return;
        }
        try self.roots.append(allocator, try allocator.dupe(u8, root));
    }

    fn observeMounts(
        self: *NodeResourceView,
        allocator: std.mem.Allocator,
        node_id: []const u8,
        mounts_json: []const u8,
    ) !void {
        if (mounts_json.len == 0) return;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, mounts_json, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .array) return;
        for (parsed.value.array.items) |mount| {
            if (mount != .object) continue;
            const mount_path_value = mount.object.get("mount_path") orelse continue;
            if (mount_path_value != .string) continue;
            const root = nodeRootNameFromPath(node_id, mount_path_value.string) orelse continue;
            try self.addRoot(allocator, root);
        }
    }

    fn observe(
        self: *NodeResourceView,
        allocator: std.mem.Allocator,
        node_id: []const u8,
        kind: []const u8,
        venom_id: []const u8,
        endpoint: []const u8,
        mounts_json: []const u8,
    ) !void {
        var handled_terminal = false;
        if (std.mem.eql(u8, kind, "fs")) {
            self.fs = true;
            try self.addRoot(allocator, "fs");
        }
        if (std.mem.eql(u8, kind, "camera")) {
            self.camera = true;
            try self.addRoot(allocator, "camera");
        }
        if (std.mem.eql(u8, kind, "screen")) {
            self.screen = true;
            try self.addRoot(allocator, "screen");
        }
        if (std.mem.eql(u8, kind, "user")) {
            self.user = true;
            try self.addRoot(allocator, "user");
        }
        if (std.mem.eql(u8, kind, "terminal")) {
            handled_terminal = true;
            try self.addRoot(allocator, "terminal");

            const maybe_terminal_id = if (std.mem.startsWith(u8, venom_id, "terminal-") and venom_id.len > "terminal-".len)
                venom_id["terminal-".len..]
            else
                terminalIdFromEndpoint(endpoint);
            const terminal_id = maybe_terminal_id orelse {
                try self.observeMounts(allocator, node_id, mounts_json);
                return;
            };
            if (terminal_id.len == 0) {
                try self.observeMounts(allocator, node_id, mounts_json);
                return;
            }
            for (self.terminals.items) |existing| {
                if (std.mem.eql(u8, existing, terminal_id)) {
                    try self.observeMounts(allocator, node_id, mounts_json);
                    return;
                }
            }
            try self.terminals.append(allocator, try allocator.dupe(u8, terminal_id));
        }

        try self.observeMounts(allocator, node_id, mounts_json);
        if (!handled_terminal) {
            if (nodeRootNameFromPath(node_id, endpoint)) |root| {
                try self.addRoot(allocator, root);
            }
        }
    }
};

fn nodeRootNameFromPath(node_id: []const u8, mount_path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, mount_path, "/nodes/")) return null;
    const after_nodes = mount_path["/nodes/".len..];
    if (!std.mem.startsWith(u8, after_nodes, node_id)) return null;
    if (after_nodes.len <= node_id.len or after_nodes[node_id.len] != '/') return null;
    const tail = after_nodes[node_id.len + 1 ..];
    if (tail.len == 0) return null;
    const slash = std.mem.indexOfScalar(u8, tail, '/') orelse tail.len;
    const root = tail[0..slash];
    if (root.len == 0) return null;
    for (root) |char| {
        if (std.ascii.isAlphanumeric(char)) continue;
        if (char == '-' or char == '_' or char == '.') continue;
        return null;
    }
    return root;
}

fn terminalIdFromEndpoint(endpoint: []const u8) ?[]const u8 {
    if (endpoint.len == 0) return null;
    const marker = "/terminal/";
    const marker_start = std.mem.lastIndexOf(u8, endpoint, marker) orelse return null;
    const start = marker_start + marker.len;
    if (start >= endpoint.len) return null;
    const tail = endpoint[start..];
    const slash = std.mem.indexOfScalar(u8, tail, '/') orelse tail.len;
    const id = tail[0..slash];
    if (id.len == 0) return null;
    return id;
}

pub fn addNodeVenoms(session: anytype, node_dir: u32, node: workspace_policy.WorkspaceNodePolicy) !NodeResourceView {
    var view = NodeResourceView{};
    errdefer view.deinit(session.allocator);

    const venoms_root = try session.addDir(node_dir, "venoms", false);
    try session.addDirectoryDescriptors(
        venoms_root,
        "Node Venoms",
        "{\"kind\":\"collection\",\"entries\":\"venom_id\",\"shape\":\"/nodes/<node_id>/venoms/<venom_id>/{README.md,SCHEMA.json,TEMPLATE.json,CAPS.json,MOUNTS.json,OPS.json,RUNTIME.json,HOST.json,PERMISSIONS.json,STATUS.json}\"}",
        "{\"read\":true,\"write\":false}",
        "Node Venom descriptors mirrored from the node Venom catalog.",
    );
    var services_index = std.ArrayListUnmanaged(u8){};
    defer services_index.deinit(session.allocator);
    try services_index.append(session.allocator, '[');
    var services_index_first = true;

    switch (try loadNodeVenomsFromControlPlane(session, node.id)) {
        .catalog => |catalog_value| {
            var catalog = catalog_value;
            defer catalog.deinit(session.allocator);
            for (catalog.items.items) |venom| {
                const allow_discovery = session.canAccessVenomWithPermissions(venom.permissions_json) or
                    venom_model.isExplicitBindOnlyCapabilityVenomId(venom.package_id) or
                    venom_model.isExplicitBindOnlyCapabilityVenomId(venom.venom_id);
                if (!allow_discovery) continue;
                try addNodeVenomEntry(
                    session,
                    venoms_root,
                    venom.venom_id,
                    venom.package_id,
                    venom.instance_id,
                    venom.kind,
                    venom.version,
                    venom.state,
                    venom.categories_json,
                    venom.host_roles_json,
                    venom.binding_scopes_json,
                    venom.runtime_kind,
                    venom.requirements_json,
                    venom.endpoint,
                    venom.caps_json,
                    venom.mounts_json,
                    venom.ops_json,
                    venom.runtime_json,
                    venom.permissions_json,
                    venom.schema_json,
                    venom.invoke_template_json,
                    venom.help_md,
                );
                try view.observe(
                    session.allocator,
                    node.id,
                    venom.kind,
                    venom.venom_id,
                    venom.endpoint,
                    venom.mounts_json,
                );
                try session.appendVenomIndexEntry(
                    &services_index,
                    &services_index_first,
                    venom.venom_id,
                    venom.kind,
                    venom.state,
                    venom.endpoint,
                );
            }
            try services_index.append(session.allocator, ']');
            const services_index_json = try services_index.toOwnedSlice(session.allocator);
            defer session.allocator.free(services_index_json);
            _ = try session.addFile(venoms_root, "VENOMS.json", services_index_json, false, .none);
            return view;
        },
        .empty => {
            try services_index.append(session.allocator, ']');
            const services_index_json = try services_index.toOwnedSlice(session.allocator);
            defer session.allocator.free(services_index_json);
            _ = try session.addFile(venoms_root, "VENOMS.json", services_index_json, false, .none);
            return view;
        },
        .unavailable => {},
    }

    if (node.resources.fs) {
        const caps = "{\"rw\":true}";
        const mounts = try std.fmt.allocPrint(
            session.allocator,
            "[{{\"mount_id\":\"fs\",\"mount_path\":\"/nodes/{s}/fs\",\"state\":\"online\"}}]",
            .{node.id},
        );
        defer session.allocator.free(mounts);
        const endpoint = try std.fmt.allocPrint(session.allocator, "/nodes/{s}/fs", .{node.id});
        defer session.allocator.free(endpoint);
        const permissions = "{\"default\":\"allow-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"scope\":\"project\"}";
        if (session.canAccessVenomWithPermissions(permissions)) {
            try addNodeVenomEntry(
                session,
                venoms_root,
                "fs",
                "fs",
                "local:fs",
                "fs",
                "1",
                "online",
                "[\"filesystem\"]",
                "[\"node\"]",
                "[\"node\"]",
                .native,
                "{}",
                endpoint,
                caps,
                mounts,
                "{\"model\":\"namespace\"}",
                "{\"type\":\"builtin\"}",
                permissions,
                "{\"model\":\"filesystem\"}",
                null,
                "Workspace node filesystem export.",
            );
            try addNodeVenomEntry(
                session,
                venoms_root,
                "fs",
                "fs",
                "local:fs",
                "fs",
                "1",
                "online",
                "[\"filesystem\"]",
                "[\"node\"]",
                "[\"node\"]",
                .native,
                "{}",
                endpoint,
                caps,
                mounts,
                "{\"model\":\"namespace\"}",
                "{\"type\":\"builtin\"}",
                permissions,
                "{\"model\":\"filesystem\"}",
                null,
                "Workspace node filesystem export.",
            );
            try view.observe(session.allocator, node.id, "fs", "fs", endpoint, mounts);
            try session.appendVenomIndexEntry(&services_index, &services_index_first, "fs", "fs", "online", endpoint);
        }
    }
    if (node.resources.camera) {
        const caps = "{\"still\":true}";
        const mounts = try std.fmt.allocPrint(
            session.allocator,
            "[{{\"mount_id\":\"camera\",\"mount_path\":\"/nodes/{s}/camera\",\"state\":\"online\"}}]",
            .{node.id},
        );
        defer session.allocator.free(mounts);
        const endpoint = try std.fmt.allocPrint(session.allocator, "/nodes/{s}/camera", .{node.id});
        defer session.allocator.free(endpoint);
        const permissions = "{\"default\":\"allow-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"scope\":\"node\"}";
        if (session.canAccessVenomWithPermissions(permissions)) {
            try addNodeVenomEntry(
                session,
                venoms_root,
                "camera",
                "camera",
                "local:camera",
                "camera",
                "1",
                "online",
                "[\"camera\"]",
                "[\"node\"]",
                "[\"node\"]",
                .native,
                "{}",
                endpoint,
                caps,
                mounts,
                "{\"model\":\"namespace\"}",
                "{\"type\":\"builtin\"}",
                permissions,
                "{\"model\":\"camera\"}",
                null,
                "Camera capture namespace.",
            );
            try addNodeVenomEntry(
                session,
                venoms_root,
                "camera",
                "camera",
                "local:camera",
                "camera",
                "1",
                "online",
                "[\"camera\"]",
                "[\"node\"]",
                "[\"node\"]",
                .native,
                "{}",
                endpoint,
                caps,
                mounts,
                "{\"model\":\"namespace\"}",
                "{\"type\":\"builtin\"}",
                permissions,
                "{\"model\":\"camera\"}",
                null,
                "Camera capture namespace.",
            );
            try view.observe(session.allocator, node.id, "camera", "camera", endpoint, mounts);
            try session.appendVenomIndexEntry(&services_index, &services_index_first, "camera", "camera", "online", endpoint);
        }
    }
    if (node.resources.screen) {
        const caps = "{\"capture\":true}";
        const mounts = try std.fmt.allocPrint(
            session.allocator,
            "[{{\"mount_id\":\"screen\",\"mount_path\":\"/nodes/{s}/screen\",\"state\":\"online\"}}]",
            .{node.id},
        );
        defer session.allocator.free(mounts);
        const endpoint = try std.fmt.allocPrint(session.allocator, "/nodes/{s}/screen", .{node.id});
        defer session.allocator.free(endpoint);
        const permissions = "{\"default\":\"allow-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"scope\":\"node\"}";
        if (session.canAccessVenomWithPermissions(permissions)) {
            try addNodeVenomEntry(
                session,
                venoms_root,
                "screen",
                "screen",
                "local:screen",
                "screen",
                "1",
                "online",
                "[\"screen\"]",
                "[\"node\"]",
                "[\"node\"]",
                .native,
                "{}",
                endpoint,
                caps,
                mounts,
                "{\"model\":\"namespace\"}",
                "{\"type\":\"builtin\"}",
                permissions,
                "{\"model\":\"screen\"}",
                null,
                "Screen capture namespace.",
            );
            try addNodeVenomEntry(
                session,
                venoms_root,
                "screen",
                "screen",
                "local:screen",
                "screen",
                "1",
                "online",
                "[\"screen\"]",
                "[\"node\"]",
                "[\"node\"]",
                .native,
                "{}",
                endpoint,
                caps,
                mounts,
                "{\"model\":\"namespace\"}",
                "{\"type\":\"builtin\"}",
                permissions,
                "{\"model\":\"screen\"}",
                null,
                "Screen capture namespace.",
            );
            try view.observe(session.allocator, node.id, "screen", "screen", endpoint, mounts);
            try session.appendVenomIndexEntry(&services_index, &services_index_first, "screen", "screen", "online", endpoint);
        }
    }
    if (node.resources.user) {
        const caps = "{\"interaction\":true}";
        const mounts = try std.fmt.allocPrint(
            session.allocator,
            "[{{\"mount_id\":\"user\",\"mount_path\":\"/nodes/{s}/user\",\"state\":\"online\"}}]",
            .{node.id},
        );
        defer session.allocator.free(mounts);
        const endpoint = try std.fmt.allocPrint(session.allocator, "/nodes/{s}/user", .{node.id});
        defer session.allocator.free(endpoint);
        const permissions = "{\"default\":\"allow-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"scope\":\"node\"}";
        if (session.canAccessVenomWithPermissions(permissions)) {
            try addNodeVenomEntry(
                session,
                venoms_root,
                "user",
                "user",
                "local:user",
                "user",
                "1",
                "online",
                "[\"user_interaction\"]",
                "[\"node\"]",
                "[\"node\"]",
                .native,
                "{}",
                endpoint,
                caps,
                mounts,
                "{\"model\":\"namespace\"}",
                "{\"type\":\"builtin\"}",
                permissions,
                "{\"model\":\"user\"}",
                null,
                "User interaction namespace.",
            );
            try addNodeVenomEntry(
                session,
                venoms_root,
                "user",
                "user",
                "local:user",
                "user",
                "1",
                "online",
                "[\"user_interaction\"]",
                "[\"node\"]",
                "[\"node\"]",
                .native,
                "{}",
                endpoint,
                caps,
                mounts,
                "{\"model\":\"namespace\"}",
                "{\"type\":\"builtin\"}",
                permissions,
                "{\"model\":\"user\"}",
                null,
                "User interaction namespace.",
            );
            try view.observe(session.allocator, node.id, "user", "user", endpoint, mounts);
            try session.appendVenomIndexEntry(&services_index, &services_index_first, "user", "user", "online", endpoint);
        }
    }

    for (node.terminals.items) |terminal_id| {
        const venom_id = try std.fmt.allocPrint(session.allocator, "terminal-{s}", .{terminal_id});
        defer session.allocator.free(venom_id);
        const endpoint = try std.fmt.allocPrint(session.allocator, "/nodes/{s}/terminal/{s}", .{ node.id, terminal_id });
        defer session.allocator.free(endpoint);
        const escaped_terminal_id = try unified.jsonEscape(session.allocator, terminal_id);
        defer session.allocator.free(escaped_terminal_id);
        const caps = try std.fmt.allocPrint(
            session.allocator,
            "{{\"pty\":true,\"terminal_id\":\"{s}\"}}",
            .{escaped_terminal_id},
        );
        defer session.allocator.free(caps);
        const mounts = try std.fmt.allocPrint(
            session.allocator,
            "[{{\"mount_id\":\"{s}\",\"mount_path\":\"/nodes/{s}/terminal/{s}\",\"state\":\"online\"}}]",
            .{ venom_id, node.id, terminal_id },
        );
        defer session.allocator.free(mounts);
        const permissions = "{\"default\":\"allow-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"scope\":\"node\"}";
        if (session.canAccessVenomWithPermissions(permissions)) {
            try addNodeVenomEntry(
                session,
                venoms_root,
                venom_id,
                "terminal",
                venom_id,
                "terminal",
                "1",
                "online",
                "[\"terminal\",\"exec\"]",
                "[\"node\"]",
                "[\"workspace\"]",
                .native,
                "{}",
                endpoint,
                caps,
                mounts,
                "{\"model\":\"namespace\"}",
                "{\"type\":\"builtin\"}",
                permissions,
                "{\"model\":\"terminal\"}",
                null,
                "Interactive terminal namespace.",
            );
            try addNodeVenomEntry(
                session,
                venoms_root,
                venom_id,
                "terminal",
                venom_id,
                "terminal",
                "1",
                "online",
                "[\"terminal\",\"exec\"]",
                "[\"node\"]",
                "[\"workspace\"]",
                .native,
                "{}",
                endpoint,
                caps,
                mounts,
                "{\"model\":\"namespace\"}",
                "{\"type\":\"builtin\"}",
                permissions,
                "{\"model\":\"terminal\"}",
                null,
                "Interactive terminal namespace.",
            );
            try view.observe(session.allocator, node.id, "terminal", venom_id, endpoint, mounts);
            try session.appendVenomIndexEntry(&services_index, &services_index_first, venom_id, "terminal", "online", endpoint);
        }
    }

    try services_index.append(session.allocator, ']');
    const services_index_json = try services_index.toOwnedSlice(session.allocator);
    defer session.allocator.free(services_index_json);
    _ = try session.addFile(venoms_root, "VENOMS.json", services_index_json, false, .none);
    return view;
}

const NodeVenomCatalog = struct {
    const Entry = struct {
        venom_id: []u8,
        package_id: []u8,
        instance_id: ?[]u8 = null,
        kind: []u8,
        version: []u8,
        state: []u8,
        categories_json: []u8,
        host_roles_json: []u8,
        binding_scopes_json: []u8,
        runtime_kind: venom_model.RuntimeKind,
        requirements_json: []u8,
        endpoint: []u8,
        caps_json: []u8,
        mounts_json: []u8,
        ops_json: []u8,
        runtime_json: []u8,
        permissions_json: []u8,
        schema_json: []u8,
        invoke_template_json: ?[]u8 = null,
        help_md: ?[]u8 = null,

        fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
            allocator.free(self.venom_id);
            allocator.free(self.package_id);
            if (self.instance_id) |value| allocator.free(value);
            allocator.free(self.kind);
            allocator.free(self.version);
            allocator.free(self.state);
            allocator.free(self.categories_json);
            allocator.free(self.host_roles_json);
            allocator.free(self.binding_scopes_json);
            allocator.free(self.requirements_json);
            allocator.free(self.endpoint);
            allocator.free(self.caps_json);
            allocator.free(self.mounts_json);
            allocator.free(self.ops_json);
            allocator.free(self.runtime_json);
            allocator.free(self.permissions_json);
            allocator.free(self.schema_json);
            if (self.invoke_template_json) |value| allocator.free(value);
            if (self.help_md) |value| allocator.free(value);
            self.* = undefined;
        }
    };

    items: std.ArrayListUnmanaged(Entry) = .{},

    fn deinit(self: *NodeVenomCatalog, allocator: std.mem.Allocator) void {
        for (self.items.items) |*item| item.deinit(allocator);
        self.items.deinit(allocator);
        self.* = undefined;
    }
};

const NodeVenomCatalogResult = union(enum) {
    unavailable,
    empty,
    catalog: NodeVenomCatalog,
};

fn normalizedHostRolesJson(allocator: std.mem.Allocator, host_roles_value: ?std.json.Value) ![]u8 {
    if (host_roles_value) |value| {
        if (value == .array) return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
    }
    return allocator.dupe(u8, "[\"node\"]");
}

fn normalizedBindingScopesJson(allocator: std.mem.Allocator, binding_scopes_value: ?std.json.Value) ![]u8 {
    if (binding_scopes_value) |value| {
        if (value == .array) return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
    }
    return allocator.dupe(u8, "[\"workspace\"]");
}

fn runtimeKindFromValues(runtime_kind_value: ?std.json.Value, runtime_value: ?std.json.Value) venom_model.RuntimeKind {
    if (runtime_kind_value) |value| {
        if (value == .string) {
            if (std.mem.eql(u8, value.string, venom_model.RuntimeKind.wasm.asString())) return .wasm;
            if (std.mem.eql(u8, value.string, venom_model.RuntimeKind.native.asString())) return .native;
        }
    }
    if (runtime_value) |value| {
        if (value == .object) {
            if (value.object.get("type")) |runtime_type| {
                if (runtime_type == .string and std.mem.eql(u8, runtime_type.string, "wasm")) return .wasm;
            }
        }
    }
    return .native;
}

fn loadNodeVenomsFromControlPlane(session: anytype, node_id: []const u8) !NodeVenomCatalogResult {
    const plane = session.control_plane orelse return .unavailable;
    const catalog_node_id = (try session.resolveCatalogControlPlaneNodeId(node_id)) orelse return .unavailable;
    defer session.allocator.free(catalog_node_id);
    const escaped_node_id = try unified.jsonEscape(session.allocator, catalog_node_id);
    defer session.allocator.free(escaped_node_id);
    const request_json = try std.fmt.allocPrint(
        session.allocator,
        "{{\"node_id\":\"{s}\"}}",
        .{escaped_node_id},
    );
    defer session.allocator.free(request_json);

    const response_json = plane.nodeVenomGet(request_json) catch return .unavailable;
    defer session.allocator.free(response_json);

    var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, response_json, .{}) catch return .unavailable;
    defer parsed.deinit();
    if (parsed.value != .object) return .unavailable;
    const venoms_val = parsed.value.object.get("venoms") orelse return .unavailable;
    if (venoms_val != .array) return .unavailable;
    if (venoms_val.array.items.len == 0) return .empty;

    var catalog = NodeVenomCatalog{};
    errdefer catalog.deinit(session.allocator);

    for (venoms_val.array.items) |item| {
        if (item != .object) continue;
        const venom_id_val = item.object.get("venom_id") orelse continue;
        if (venom_id_val != .string or venom_id_val.string.len == 0) continue;
        const kind_val = item.object.get("kind") orelse continue;
        if (kind_val != .string or kind_val.string.len == 0) continue;
        const state_val = item.object.get("state");
        const state = if (state_val) |value|
            if (value == .string and value.string.len > 0) value.string else "unknown"
        else
            "unknown";

        const endpoint = blk: {
            if (item.object.get("endpoints")) |raw| {
                if (raw == .array) {
                    for (raw.array.items) |candidate| {
                        if (candidate != .string or candidate.string.len == 0) continue;
                        break :blk candidate.string;
                    }
                }
            }
            break :blk "";
        };
        const resolved_endpoint = if (endpoint.len > 0)
            try session.allocator.dupe(u8, endpoint)
        else
            try std.fmt.allocPrint(session.allocator, "/nodes/{s}/venoms/{s}", .{ node_id, venom_id_val.string });
        errdefer session.allocator.free(resolved_endpoint);

        const package_id = if (item.object.get("package_id")) |value|
            if (value == .string and value.string.len > 0)
                try session.allocator.dupe(u8, value.string)
            else
                try session.allocator.dupe(u8, venom_id_val.string)
        else
            try session.allocator.dupe(u8, venom_id_val.string);
        errdefer session.allocator.free(package_id);

        const instance_id = if (item.object.get("instance_id")) |value|
            if (value == .string and value.string.len > 0)
                try session.allocator.dupe(u8, value.string)
            else
                null
        else
            null;
        errdefer if (instance_id) |value| session.allocator.free(value);

        const categories_json = if (item.object.get("categories")) |value|
            if (value == .array)
                try std.fmt.allocPrint(session.allocator, "{f}", .{std.json.fmt(value, .{})})
            else
                try session.allocator.dupe(u8, "[]")
        else
            try session.allocator.dupe(u8, "[]");
        errdefer session.allocator.free(categories_json);

        const host_roles_json = try normalizedHostRolesJson(
            session.allocator,
            item.object.get("host_roles"),
        );
        errdefer session.allocator.free(host_roles_json);

        const binding_scopes_json = try normalizedBindingScopesJson(
            session.allocator,
            item.object.get("binding_scopes"),
        );
        errdefer session.allocator.free(binding_scopes_json);

        const requirements_json = if (item.object.get("requirements")) |value|
            if (value == .object)
                try std.fmt.allocPrint(session.allocator, "{f}", .{std.json.fmt(value, .{})})
            else
                try session.allocator.dupe(u8, "{}")
        else
            try session.allocator.dupe(u8, "{}");
        errdefer session.allocator.free(requirements_json);

        const version = if (item.object.get("version")) |value|
            if (value == .string and value.string.len > 0)
                try session.allocator.dupe(u8, value.string)
            else
                try session.allocator.dupe(u8, "1")
        else
            try session.allocator.dupe(u8, "1");
        errdefer session.allocator.free(version);

        const caps_json = if (item.object.get("capabilities")) |caps|
            if (caps == .object)
                try std.fmt.allocPrint(session.allocator, "{f}", .{std.json.fmt(caps, .{})})
            else
                try session.allocator.dupe(u8, "{}")
        else
            try session.allocator.dupe(u8, "{}");
        errdefer session.allocator.free(caps_json);

        const mounts_json = if (item.object.get("mounts")) |mounts|
            if (mounts == .array)
                try std.fmt.allocPrint(session.allocator, "{f}", .{std.json.fmt(mounts, .{})})
            else
                try session.allocator.dupe(u8, "[]")
        else
            try session.allocator.dupe(u8, "[]");
        errdefer session.allocator.free(mounts_json);

        const ops_json = if (item.object.get("ops")) |ops|
            if (ops == .object)
                try std.fmt.allocPrint(session.allocator, "{f}", .{std.json.fmt(ops, .{})})
            else
                try session.allocator.dupe(u8, "{}")
        else
            try session.allocator.dupe(u8, "{}");
        errdefer session.allocator.free(ops_json);

        const runtime_json = if (item.object.get("runtime")) |runtime|
            if (runtime == .object)
                try std.fmt.allocPrint(session.allocator, "{f}", .{std.json.fmt(runtime, .{})})
            else
                try session.allocator.dupe(u8, "{}")
        else
            try session.allocator.dupe(u8, "{}");
        errdefer session.allocator.free(runtime_json);
        const runtime_kind = runtimeKindFromValues(item.object.get("runtime_kind"), item.object.get("runtime"));

        const permissions_json = if (item.object.get("permissions")) |permissions|
            if (permissions == .object)
                try std.fmt.allocPrint(session.allocator, "{f}", .{std.json.fmt(permissions, .{})})
            else
                try session.allocator.dupe(u8, "{}")
        else
            try session.allocator.dupe(u8, "{}");
        errdefer session.allocator.free(permissions_json);

        const schema_json = if (item.object.get("schema")) |schema|
            if (schema == .object)
                try std.fmt.allocPrint(session.allocator, "{f}", .{std.json.fmt(schema, .{})})
            else
                try session.allocator.dupe(u8, "{}")
        else
            try session.allocator.dupe(u8, "{}");
        errdefer session.allocator.free(schema_json);

        const invoke_template_json = if (item.object.get("invoke_template")) |invoke_template|
            if (invoke_template == .object)
                try std.fmt.allocPrint(session.allocator, "{f}", .{std.json.fmt(invoke_template, .{})})
            else
                null
        else
            null;
        errdefer if (invoke_template_json) |value| session.allocator.free(value);

        const help_md = if (item.object.get("help_md")) |help|
            if (help == .string and help.string.len > 0)
                try session.allocator.dupe(u8, help.string)
            else
                null
        else
            null;
        errdefer if (help_md) |value| session.allocator.free(value);

        try catalog.items.append(session.allocator, .{
            .venom_id = try session.allocator.dupe(u8, venom_id_val.string),
            .package_id = package_id,
            .instance_id = instance_id,
            .kind = try session.allocator.dupe(u8, kind_val.string),
            .version = version,
            .state = try session.allocator.dupe(u8, state),
            .categories_json = categories_json,
            .host_roles_json = host_roles_json,
            .binding_scopes_json = binding_scopes_json,
            .runtime_kind = runtime_kind,
            .requirements_json = requirements_json,
            .endpoint = resolved_endpoint,
            .caps_json = caps_json,
            .mounts_json = mounts_json,
            .ops_json = ops_json,
            .runtime_json = runtime_json,
            .permissions_json = permissions_json,
            .schema_json = schema_json,
            .invoke_template_json = invoke_template_json,
            .help_md = help_md,
        });
    }

    if (catalog.items.items.len == 0) {
        catalog.deinit(session.allocator);
        return .empty;
    }
    return .{ .catalog = catalog };
}

fn addNodeVenomEntry(
    session: anytype,
    services_root: u32,
    venom_id: []const u8,
    package_id: []const u8,
    instance_id: ?[]const u8,
    kind: []const u8,
    version: []const u8,
    state: []const u8,
    categories_json: []const u8,
    host_roles_json: []const u8,
    binding_scopes_json: []const u8,
    runtime_kind: venom_model.RuntimeKind,
    requirements_json: []const u8,
    endpoint: []const u8,
    caps_json: []const u8,
    mounts_json: []const u8,
    ops_json: []const u8,
    runtime_json: []const u8,
    permissions_json: []const u8,
    schema_json: []const u8,
    invoke_template_json: ?[]const u8,
    help_md: ?[]const u8,
) !void {
    const venom_dir = try session.addDir(services_root, venom_id, false);

    const escaped_venom_id = try unified.jsonEscape(session.allocator, venom_id);
    defer session.allocator.free(escaped_venom_id);
    const escaped_kind = try unified.jsonEscape(session.allocator, kind);
    defer session.allocator.free(escaped_kind);
    const escaped_state = try unified.jsonEscape(session.allocator, state);
    defer session.allocator.free(escaped_state);
    const escaped_endpoint = try unified.jsonEscape(session.allocator, endpoint);
    defer session.allocator.free(escaped_endpoint);

    const readme = if (help_md) |value|
        value
    else
        "# Venom metadata for this node capability.\n";
    _ = try session.addFile(venom_dir, "README.md", readme, false, .none);
    const package_json = try renderNodeVenomPackageJson(
        session,
        package_id,
        kind,
        version,
        categories_json,
        host_roles_json,
        binding_scopes_json,
        runtime_kind,
        requirements_json,
        caps_json,
        ops_json,
        runtime_json,
        permissions_json,
        schema_json,
        help_md,
    );
    defer session.allocator.free(package_json);
    _ = try session.addFile(venom_dir, "PACKAGE.json", package_json, false, .none);
    _ = try session.addFile(venom_dir, "SCHEMA.json", schema_json, false, .none);
    _ = try session.addFile(venom_dir, "CAPS.json", caps_json, false, .none);
    _ = try session.addFile(venom_dir, "MOUNTS.json", mounts_json, false, .none);
    _ = try session.addFile(venom_dir, "OPS.json", ops_json, false, .none);
    _ = try session.addFile(venom_dir, "RUNTIME.json", runtime_json, false, .none);
    if (invoke_template_json) |value| {
        _ = try session.addFile(venom_dir, "TEMPLATE.json", value, false, .none);
    }
    const host_json = try renderNodeVenomHostJson(session, runtime_json);
    defer session.allocator.free(host_json);
    _ = try session.addFile(venom_dir, "HOST.json", host_json, false, .none);
    _ = try session.addFile(venom_dir, "PERMISSIONS.json", permissions_json, false, .none);

    const escaped_package_id = try unified.jsonEscape(session.allocator, package_id);
    defer session.allocator.free(escaped_package_id);
    const escaped_runtime_kind = try unified.jsonEscape(session.allocator, runtime_kind.asString());
    defer session.allocator.free(escaped_runtime_kind);
    const instance_id_json = if (instance_id) |value| blk: {
        const escaped_instance_id = try unified.jsonEscape(session.allocator, value);
        defer session.allocator.free(escaped_instance_id);
        break :blk try std.fmt.allocPrint(session.allocator, "\"{s}\"", .{escaped_instance_id});
    } else try session.allocator.dupe(u8, "null");
    defer session.allocator.free(instance_id_json);

    const status = try std.fmt.allocPrint(
        session.allocator,
        "{{\"venom_id\":\"{s}\",\"package_id\":\"{s}\",\"instance_id\":{s},\"kind\":\"{s}\",\"state\":\"{s}\",\"runtime_kind\":\"{s}\",\"endpoint\":\"{s}\"}}",
        .{ escaped_venom_id, escaped_package_id, instance_id_json, escaped_kind, escaped_state, escaped_runtime_kind, escaped_endpoint },
    );
    defer session.allocator.free(status);
    _ = try session.addFile(venom_dir, "STATUS.json", status, false, .none);
    try seedNodeVenomServiceNamespace(session, venom_dir, caps_json, ops_json, schema_json);
}

fn seedNodeVenomServiceNamespace(
    session: anytype,
    venom_dir: u32,
    caps_json: []const u8,
    ops_json: []const u8,
    schema_json: []const u8,
) !void {
    if (!nodeVenomHasInvoke(caps_json, ops_json)) return;

    const control_dir = try session.addDir(venom_dir, "control", false);
    _ = try session.addFile(control_dir, "invoke.json", "", true, .none);
    _ = try session.addFile(venom_dir, "status.json", "", false, .none);
    _ = try session.addFile(venom_dir, "result.json", "", false, .none);
    _ = try session.addFile(venom_dir, "health.json", "", false, .none);
    _ = try session.addFile(venom_dir, "last_error.txt", "", false, .none);

    var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, schema_json, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const artifacts = parsed.value.object.get("artifacts") orelse return;
    if (artifacts != .object) return;

    const artifacts_dir = try session.addDir(venom_dir, "artifacts", false);
    var it = artifacts.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        try seedRelativeServicePath(session, artifacts_dir, entry.value_ptr.*.string, "artifacts/");
    }
}

fn seedRelativeServicePath(
    session: anytype,
    base_dir: u32,
    relative_path: []const u8,
    required_prefix: []const u8,
) !void {
    if (!std.mem.startsWith(u8, relative_path, required_prefix)) return;
    const tail = relative_path[required_prefix.len..];
    if (tail.len == 0) return;

    var current_dir = base_dir;
    var iter = std.mem.splitScalar(u8, tail, '/');
    while (iter.next()) |segment| {
        if (segment.len == 0) continue;
        const rest = iter.rest();
        if (rest.len == 0) {
            _ = try session.addFile(current_dir, segment, "", false, .none);
            return;
        }
        if (session.lookupChild(current_dir, segment)) |existing| {
            const child = session.nodes.get(existing) orelse return error.MissingNode;
            if (child.kind != .dir) return error.InvalidPayload;
            current_dir = existing;
            continue;
        }
        current_dir = try session.addDir(current_dir, segment, false);
    }
}

fn nodeVenomHasInvoke(caps_json: []const u8, ops_json: []const u8) bool {
    var caps = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, caps_json, .{}) catch return false;
    defer caps.deinit();
    if (caps.value == .object) {
        if (caps.value.object.get("invoke")) |value| {
            if (value == .bool and value.bool) return true;
        }
    }

    var ops = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, ops_json, .{}) catch return false;
    defer ops.deinit();
    if (ops.value != .object) return false;
    if (ops.value.object.get("invoke")) |value| {
        if (value == .string and value.string.len != 0) return true;
    }
    if (ops.value.object.get("paths")) |value| {
        if (value == .object) {
            if (value.object.get("invoke")) |invoke_value| {
                return invoke_value == .string and invoke_value.string.len != 0;
            }
        }
    }
    return false;
}

fn renderNodeVenomPackageJson(
    session: anytype,
    venom_id: []const u8,
    kind: []const u8,
    version: []const u8,
    categories_json: []const u8,
    host_roles_json: []const u8,
    binding_scopes_json: []const u8,
    runtime_kind: venom_model.RuntimeKind,
    requirements_json: []const u8,
    capabilities_json: []const u8,
    ops_json: []const u8,
    runtime_json: []const u8,
    permissions_json: []const u8,
    schema_json: []const u8,
    help_md: ?[]const u8,
) ![]u8 {
    const escaped_venom_id = try unified.jsonEscape(session.allocator, venom_id);
    defer session.allocator.free(escaped_venom_id);
    const escaped_kind = try unified.jsonEscape(session.allocator, kind);
    defer session.allocator.free(escaped_kind);
    const escaped_version = try unified.jsonEscape(session.allocator, version);
    defer session.allocator.free(escaped_version);
    const escaped_runtime_kind = try unified.jsonEscape(session.allocator, runtime_kind.asString());
    defer session.allocator.free(escaped_runtime_kind);

    if (help_md) |help| {
        const escaped_help = try unified.jsonEscape(session.allocator, help);
        defer session.allocator.free(escaped_help);
        return std.fmt.allocPrint(
            session.allocator,
            "{{\"venom_id\":\"{s}\",\"kind\":\"{s}\",\"version\":\"{s}\",\"categories\":{s},\"host_roles\":{s},\"binding_scopes\":{s},\"requirements\":{s},\"capabilities\":{s},\"ops\":{s},\"runtime_kind\":\"{s}\",\"runtime\":{s},\"permissions\":{s},\"schema\":{s},\"help_md\":\"{s}\"}}",
            .{ escaped_venom_id, escaped_kind, escaped_version, categories_json, host_roles_json, binding_scopes_json, requirements_json, capabilities_json, ops_json, escaped_runtime_kind, runtime_json, permissions_json, schema_json, escaped_help },
        );
    }

    return std.fmt.allocPrint(
        session.allocator,
        "{{\"venom_id\":\"{s}\",\"kind\":\"{s}\",\"version\":\"{s}\",\"categories\":{s},\"host_roles\":{s},\"binding_scopes\":{s},\"requirements\":{s},\"capabilities\":{s},\"ops\":{s},\"runtime_kind\":\"{s}\",\"runtime\":{s},\"permissions\":{s},\"schema\":{s}}}",
        .{ escaped_venom_id, escaped_kind, escaped_version, categories_json, host_roles_json, binding_scopes_json, requirements_json, capabilities_json, ops_json, escaped_runtime_kind, runtime_json, permissions_json, schema_json },
    );
}

fn renderNodeVenomHostJson(session: anytype, runtime_json: []const u8) ![]u8 {
    var runtime_kind: []const u8 = "builtin";
    var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, runtime_json, .{}) catch {
        return shared_node.service_runtime_host.renderMetadataJson(session.allocator, runtime_kind);
    };
    defer parsed.deinit();
    if (parsed.value == .object) {
        if (parsed.value.object.get("type")) |runtime_type| {
            if (runtime_type == .string and runtime_type.string.len > 0) {
                runtime_kind = runtime_type.string;
            }
        }
    }
    return shared_node.service_runtime_host.renderMetadataJson(session.allocator, runtime_kind);
}
