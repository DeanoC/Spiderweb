const std = @import("std");

const reserved_mount_dirs = [_][]const u8{
    "/services",
    "/nodes",
    "/agents",
    "/global",
    "/meta",
    "/projects",
    "/shared_data",
    "/.spiderweb",
};

const reserved_mount_files = [_][]const u8{
    "/AGENTS.md",
};

pub fn isReservedStandaloneEndpointMountPath(path: []const u8) bool {
    for (reserved_mount_dirs) |root| {
        if (std.mem.eql(u8, path, root)) return true;
        if (pathMatchesChild(root, path)) return true;
    }
    for (reserved_mount_files) |root| {
        if (std.mem.eql(u8, path, root)) return true;
    }
    return false;
}

fn pathMatchesChild(root: []const u8, path: []const u8) bool {
    return path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/';
}

test "namespace_contract: reserved standalone endpoint mount paths cover Spiderweb-owned roots" {
    try std.testing.expect(isReservedStandaloneEndpointMountPath("/nodes/local/fs"));
    try std.testing.expect(isReservedStandaloneEndpointMountPath("/shared_data"));
    try std.testing.expect(isReservedStandaloneEndpointMountPath("/shared_data/world_seed.json"));
    try std.testing.expect(isReservedStandaloneEndpointMountPath("/.spiderweb/services"));
    try std.testing.expect(isReservedStandaloneEndpointMountPath("/AGENTS.md"));
    try std.testing.expect(!isReservedStandaloneEndpointMountPath("/a"));
    try std.testing.expect(!isReservedStandaloneEndpointMountPath("/workspace"));
}
