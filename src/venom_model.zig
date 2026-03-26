const std = @import("std");

pub const HostRole = enum {
    spiderweb,
    node,
    client,

    pub fn asString(self: HostRole) []const u8 {
        return switch (self) {
            .spiderweb => "spiderweb",
            .node => "node",
            .client => "client",
        };
    }

    pub fn fromString(value: []const u8) HostRole {
        if (std.mem.eql(u8, value, "node")) return .node;
        if (std.mem.eql(u8, value, "client")) return .client;
        return .spiderweb;
    }
};

pub const HostType = enum {
    app_local,
    spiderweb_managed,
    remote_node,
    unknown,

    pub fn asString(self: HostType) []const u8 {
        return switch (self) {
            .app_local => "app_local",
            .spiderweb_managed => "spiderweb_managed",
            .remote_node => "remote_node",
            .unknown => "unknown",
        };
    }

    pub fn fromString(value: []const u8) HostType {
        if (std.mem.eql(u8, value, "app_local") or std.mem.eql(u8, value, "app_managed")) return .app_local;
        if (std.mem.eql(u8, value, "spiderweb_managed")) return .spiderweb_managed;
        if (std.mem.eql(u8, value, "remote_node")) return .remote_node;
        return .unknown;
    }

    pub fn selectionPriority(self: HostType) u8 {
        return switch (self) {
            .app_local => 3,
            .spiderweb_managed => 2,
            .remote_node => 1,
            .unknown => 0,
        };
    }
};

pub const host_type_label_key = "spider.host_type";

pub const RuntimeKind = enum {
    native,
    wasm,

    pub fn asString(self: RuntimeKind) []const u8 {
        return switch (self) {
            .native => "native",
            .wasm => "wasm",
        };
    }

    pub fn fromRuntimeType(runtime_type: []const u8) RuntimeKind {
        if (std.mem.eql(u8, runtime_type, "wasm")) return .wasm;
        return .native;
    }
};

pub const BindingScope = enum {
    workspace,
    agent,
    client,
    node,

    pub fn asString(self: BindingScope) []const u8 {
        return switch (self) {
            .workspace => "workspace",
            .agent => "agent",
            .client => "client",
            .node => "node",
        };
    }

    pub fn fromString(value: []const u8) BindingScope {
        if (std.mem.eql(u8, value, "agent")) return .agent;
        if (std.mem.eql(u8, value, "client")) return .client;
        if (std.mem.eql(u8, value, "node")) return .node;
        return .workspace;
    }
};

const control_substrate_ids = [_][]const u8{
    "fs",
    "home",
    "mounts",
    "packages",
    "runtimes",
    "workspaces",
};

const non_production_capability_ids = [_][]const u8{
    "memory",
    "sub_brains",
};

pub const production_priority_capability_ids = [_][]const u8{
    "computer",
    "browser",
};

pub const default_workspace_capability_ids = [_][]const u8{
    "terminal",
    "git",
    "search_code",
};

pub fn isExplicitBindOnlyCapabilityVenomId(venom_id: []const u8) bool {
    inline for (production_priority_capability_ids) |candidate| {
        if (matchesVenomFamilyOrInstance(venom_id, candidate)) return true;
    }
    return false;
}

fn matchesVenomFamilyOrInstance(venom_id: []const u8, family_id: []const u8) bool {
    if (std.mem.eql(u8, venom_id, family_id)) return true;
    return std.mem.startsWith(u8, venom_id, family_id) and
        venom_id.len > family_id.len and
        venom_id[family_id.len] == '-';
}

pub fn isControlSubstrateVenomId(venom_id: []const u8) bool {
    inline for (control_substrate_ids) |candidate| {
        if (std.mem.eql(u8, venom_id, candidate)) return true;
    }
    return false;
}

pub fn isCapabilityVenomId(venom_id: []const u8) bool {
    inline for (default_workspace_capability_ids) |candidate| {
        if (matchesVenomFamilyOrInstance(venom_id, candidate)) return true;
    }
    inline for (production_priority_capability_ids) |candidate| {
        if (matchesVenomFamilyOrInstance(venom_id, candidate)) return true;
    }
    inline for (control_substrate_ids) |candidate| {
        if (std.mem.eql(u8, venom_id, candidate)) return false;
    }
    inline for (non_production_capability_ids) |candidate| {
        if (std.mem.eql(u8, venom_id, candidate)) return false;
    }
    return false;
}

pub fn defaultHostRoleForNodeId(node_id: []const u8) HostRole {
    return defaultHostRoleForHostType(defaultHostTypeForNodeName(node_id));
}

pub fn defaultHostTypeForNodeName(node_name: []const u8) HostType {
    if (std.mem.eql(u8, node_name, "local") or std.mem.eql(u8, node_name, "spiderweb-local")) {
        return .spiderweb_managed;
    }
    if (std.mem.eql(u8, node_name, "spiderapp-default") or std.mem.startsWith(u8, node_name, "spiderapp-")) {
        return .app_local;
    }
    return .remote_node;
}

pub fn defaultHostRoleForHostType(host_type: HostType) HostRole {
    return switch (host_type) {
        .spiderweb_managed => .spiderweb,
        .app_local, .remote_node, .unknown => .node,
    };
}

pub fn defaultBindingScopeForPath(path: []const u8) BindingScope {
    if (std.mem.startsWith(u8, path, "/agents/")) return .agent;
    if (std.mem.startsWith(u8, path, "/clients/")) return .client;
    if (std.mem.startsWith(u8, path, "/nodes/")) return .node;
    return .workspace;
}

pub fn legacyProviderScope(host_role: HostRole, binding_scopes: []const BindingScope) []const u8 {
    _ = binding_scopes;
    return switch (host_role) {
        .spiderweb => "host_local",
        .node => "node_export",
        .client => "runtime_private",
    };
}

pub fn legacyProjectionModesJson(host_role: HostRole, binding_scopes: []const BindingScope) []const u8 {
    const workspace = containsBindingScope(binding_scopes, .workspace);
    const agent = containsBindingScope(binding_scopes, .agent);
    const client = containsBindingScope(binding_scopes, .client);
    const node = containsBindingScope(binding_scopes, .node);

    return switch (host_role) {
        .spiderweb => if (workspace) "[\"host_local\",\"workspace_service\"]" else "[\"host_local\"]",
        .node => if (workspace) "[\"node_export\",\"workspace_service\"]" else if (node) "[\"node_export\"]" else "[\"node_export\"]",
        .client => if (agent or client) "[\"runtime_private\"]" else "[\"runtime_private\"]",
    };
}

pub fn containsBindingScope(binding_scopes: []const BindingScope, needle: BindingScope) bool {
    for (binding_scopes) |scope| {
        if (scope == needle) return true;
    }
    return false;
}

test "venom_model classifies substrate and production capability venoms" {
    try std.testing.expect(isControlSubstrateVenomId("mounts"));
    try std.testing.expect(isControlSubstrateVenomId("runtimes"));
    try std.testing.expect(!isCapabilityVenomId("mounts"));
    try std.testing.expect(!isCapabilityVenomId("mounts-main"));
    try std.testing.expect(!isCapabilityVenomId("memory"));
    try std.testing.expect(!isCapabilityVenomId("memory-main"));
    try std.testing.expect(!isCapabilityVenomId("events"));
    try std.testing.expect(!isCapabilityVenomId("library"));
    try std.testing.expect(!isCapabilityVenomId("camera-main"));
    try std.testing.expect(isExplicitBindOnlyCapabilityVenomId("computer"));
    try std.testing.expect(isExplicitBindOnlyCapabilityVenomId("computer-main"));
    try std.testing.expect(isExplicitBindOnlyCapabilityVenomId("browser-main"));
    try std.testing.expect(isCapabilityVenomId("terminal"));
    try std.testing.expect(isCapabilityVenomId("terminal-main"));
    try std.testing.expect(isCapabilityVenomId("git-main"));
    try std.testing.expect(isCapabilityVenomId("search_code-main"));
    try std.testing.expect(isCapabilityVenomId("computer-main"));
    try std.testing.expect(isCapabilityVenomId("browser"));
    try std.testing.expectEqualStrings("spiderweb", defaultHostRoleForNodeId("local").asString());
    try std.testing.expectEqualStrings("node", defaultHostRoleForNodeId("node-2").asString());
    try std.testing.expectEqualStrings("spiderweb_managed", defaultHostTypeForNodeName("spiderweb-local").asString());
    try std.testing.expectEqualStrings("app_local", defaultHostTypeForNodeName("spiderapp-default").asString());
    try std.testing.expectEqualStrings("workspace", defaultBindingScopeForPath("/.spiderweb/venoms/terminal").asString());
}
