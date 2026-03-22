const std = @import("std");
const unified = @import("spider-protocol").unified;

const ParsedWsUrl = struct {
    scheme: []const u8,
    authority: []const u8,
    path: []const u8,
};

fn parseWsUrlParts(url: []const u8) ?ParsedWsUrl {
    const scheme: []const u8 = if (std.mem.startsWith(u8, url, "ws://"))
        "ws"
    else if (std.mem.startsWith(u8, url, "wss://"))
        "wss"
    else
        return null;
    const prefix_len = scheme.len + 3;
    if (url.len <= prefix_len) return null;
    const rest = url[prefix_len..];
    const slash_idx = std.mem.indexOfScalar(u8, rest, '/') orelse {
        return .{ .scheme = scheme, .authority = rest, .path = "/" };
    };
    if (slash_idx == 0) return null;
    return .{
        .scheme = scheme,
        .authority = rest[0..slash_idx],
        .path = rest[slash_idx..],
    };
}

fn wsAuthorityHost(authority: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, authority, " \t\r\n");
    if (trimmed.len == 0) return trimmed;
    if (trimmed[0] == '[') {
        const closing = std.mem.indexOfScalar(u8, trimmed, ']') orelse return trimmed;
        if (closing <= 1) return "";
        return trimmed[1..closing];
    }
    const colon_idx = std.mem.lastIndexOfScalar(u8, trimmed, ':') orelse return trimmed;
    return trimmed[0..colon_idx];
}

fn wsAuthorityIsLocalOnly(authority: []const u8) bool {
    const host = wsAuthorityHost(authority);
    if (host.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (std.mem.eql(u8, host, "::1") or std.mem.eql(u8, host, "::")) return true;
    if (std.mem.eql(u8, host, "0.0.0.0")) return true;
    return std.mem.startsWith(u8, host, "127.");
}

fn rewriteLocalOnlyFsUrlForWorkspaceConnection(
    allocator: std.mem.Allocator,
    raw_fs_url: []const u8,
    connection_workspace_url: []const u8,
) ![]u8 {
    const fs_url = parseWsUrlParts(raw_fs_url) orelse return allocator.dupe(u8, raw_fs_url);
    if (!wsAuthorityIsLocalOnly(fs_url.authority)) return allocator.dupe(u8, raw_fs_url);

    const workspace_url = parseWsUrlParts(connection_workspace_url) orelse return allocator.dupe(u8, raw_fs_url);
    return std.fmt.allocPrint(
        allocator,
        "{s}://{s}{s}",
        .{ workspace_url.scheme, workspace_url.authority, fs_url.path },
    );
}

pub fn rewriteWorkspaceStatusFsUrls(
    allocator: std.mem.Allocator,
    workspace_json: []const u8,
    connection_workspace_url: ?[]const u8,
) ![]u8 {
    const workspace_url = connection_workspace_url orelse return allocator.dupe(u8, workspace_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, workspace_json, .{});
    defer parsed.deinit();
    const json_allocator = parsed.arena.allocator();
    if (parsed.value != .object) return allocator.dupe(u8, workspace_json);

    var rewrote_any = false;
    for ([_][]const u8{ "mounts", "desired_mounts", "actual_mounts" }) |field_name| {
        const mounts_value = parsed.value.object.getPtr(field_name) orelse continue;
        if (mounts_value.* != .array) continue;

        for (mounts_value.array.items) |*mount_value| {
            if (mount_value.* != .object) continue;
            const fs_url_value = mount_value.object.getPtr("fs_url") orelse continue;
            if (fs_url_value.* != .string) continue;

            const rewritten = try rewriteLocalOnlyFsUrlForWorkspaceConnection(
                allocator,
                fs_url_value.string,
                workspace_url,
            );
            defer allocator.free(rewritten);

            if (std.mem.eql(u8, rewritten, fs_url_value.string)) continue;
            fs_url_value.* = .{ .string = try json_allocator.dupe(u8, rewritten) };
            rewrote_any = true;
        }
    }

    if (!rewrote_any) return allocator.dupe(u8, workspace_json);
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(parsed.value, .{})});
}

pub fn buildProjectActivatePayload(
    allocator: std.mem.Allocator,
    project_id: []const u8,
    project_token: ?[]const u8,
) ![]u8 {
    const escaped_project = try unified.jsonEscape(allocator, project_id);
    defer allocator.free(escaped_project);
    if (project_token) |token| {
        const escaped_token = try unified.jsonEscape(allocator, token);
        defer allocator.free(escaped_token);
        return std.fmt.allocPrint(
            allocator,
            "{{\"project_id\":\"{s}\",\"project_token\":\"{s}\"}}",
            .{ escaped_project, escaped_token },
        );
    }
    return std.fmt.allocPrint(allocator, "{{\"project_id\":\"{s}\"}}", .{escaped_project});
}

pub fn buildWorkspaceStatusPayloadForBinding(
    allocator: std.mem.Allocator,
    control_plane: anytype,
    host_actor_id: []const u8,
    host_project_id: []const u8,
    binding: anytype,
    connection_workspace_url: ?[]const u8,
    is_admin: bool,
) ![]u8 {
    if (std.mem.eql(u8, binding.agent_id, host_actor_id) and
        binding.project_id != null and
        std.mem.eql(u8, binding.project_id.?, host_project_id))
    {
        const workspace_json = control_plane.hostWorkspaceStatusWithRole(is_admin) catch |err| {
            std.log.warn(
                "host workspace status unavailable: {s}",
                .{@errorName(err)},
            );
            return try allocator.dupe(u8, "{}");
        };
        defer allocator.free(workspace_json);
        return rewriteWorkspaceStatusFsUrls(allocator, workspace_json, connection_workspace_url);
    }

    const status_req = if (binding.project_id) |project_id|
        try buildProjectActivatePayload(allocator, project_id, binding.project_token)
    else
        try allocator.dupe(u8, "{}");
    defer allocator.free(status_req);

    const workspace_json = control_plane.workspaceStatusWithRole(binding.agent_id, status_req, is_admin) catch |err| {
        std.log.warn(
            "workspace status unavailable for agent={s} project={s}: {s}",
            .{ binding.agent_id, binding.project_id orelse "null", @errorName(err) },
        );
        return try allocator.dupe(u8, "{}");
    };
    defer allocator.free(workspace_json);
    return rewriteWorkspaceStatusFsUrls(allocator, workspace_json, connection_workspace_url);
}

test "server_workspace_status: rewriteWorkspaceStatusFsUrls rewrites local-only mount endpoints to the connection authority" {
    const allocator = std.testing.allocator;
    const rewritten = try rewriteWorkspaceStatusFsUrls(
        allocator,
        "{\"mounts\":[{\"mount_path\":\"/nodes/local/fs\",\"fs_url\":\"ws://127.0.0.1:18790/fs\"}],\"desired_mounts\":[{\"mount_path\":\"/meta\",\"fs_url\":\"ws://127.0.0.1:18790/fs\"}],\"actual_mounts\":[{\"mount_path\":\"/agents\",\"fs_url\":\"ws://127.0.0.1:18790/fs\"}]}",
        "ws://192.168.10.101:18790/",
    );
    defer allocator.free(rewritten);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "\"fs_url\":\"ws://192.168.10.101:18790/fs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "\"desired_mounts\":[{\"mount_path\":\"/meta\",\"fs_url\":\"ws://192.168.10.101:18790/fs\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "\"actual_mounts\":[{\"mount_path\":\"/agents\",\"fs_url\":\"ws://192.168.10.101:18790/fs\"}]") != null);
}
