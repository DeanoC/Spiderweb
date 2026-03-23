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
};

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
};

const control_substrate_ids = [_][]const u8{
    "fs",
    "home",
    "mounts",
    "venom_packages",
    "workers",
    "workspaces",
};

const non_production_capability_ids = [_][]const u8{
    "memory",
    "sub_brains",
};

pub const production_priority_capability_ids = [_][]const u8{
    "terminal",
    "git",
    "search_code",
    "events",
    "library",
};

pub fn isControlSubstrateVenomId(venom_id: []const u8) bool {
    inline for (control_substrate_ids) |candidate| {
        if (std.mem.eql(u8, venom_id, candidate)) return true;
    }
    return false;
}

pub fn isCapabilityVenomId(venom_id: []const u8) bool {
    if (isControlSubstrateVenomId(venom_id)) return false;
    inline for (non_production_capability_ids) |candidate| {
        if (std.mem.eql(u8, venom_id, candidate)) return false;
    }
    return venom_id.len != 0;
}

pub fn defaultHostRoleForNodeId(node_id: []const u8) HostRole {
    if (std.mem.eql(u8, node_id, "local") or std.mem.eql(u8, node_id, "spiderweb-local")) {
        return .spiderweb;
    }
    return .node;
}

pub fn defaultBindingScopeForPath(path: []const u8) BindingScope {
    if (std.mem.startsWith(u8, path, "/agents/")) return .agent;
    if (std.mem.startsWith(u8, path, "/clients/")) return .client;
    if (std.mem.startsWith(u8, path, "/nodes/")) return .node;
    return .workspace;
}

test "venom_model classifies substrate and production capability venoms" {
    try std.testing.expect(isControlSubstrateVenomId("mounts"));
    try std.testing.expect(isControlSubstrateVenomId("workers"));
    try std.testing.expect(!isCapabilityVenomId("mounts"));
    try std.testing.expect(!isCapabilityVenomId("memory"));
    try std.testing.expect(isCapabilityVenomId("terminal"));
    try std.testing.expectEqualStrings("spiderweb", defaultHostRoleForNodeId("local").asString());
    try std.testing.expectEqualStrings("node", defaultHostRoleForNodeId("node-2").asString());
    try std.testing.expectEqualStrings("workspace", defaultBindingScopeForPath("/.spiderweb/venoms/terminal").asString());
}
