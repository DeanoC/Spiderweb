const std = @import("std");

const max_policy_bytes: usize = 1024 * 1024;

pub const WorkspaceResourcePolicy = struct {
    fs: bool = true,
    camera: bool = false,
    screen: bool = false,
    user: bool = false,
};

pub const WorkspaceNodePolicy = struct {
    id: []u8,
    resources: WorkspaceResourcePolicy = .{},
    terminals: std.ArrayListUnmanaged([]u8) = .{},

    fn deinit(self: *WorkspaceNodePolicy, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        for (self.terminals.items) |terminal| allocator.free(terminal);
        self.terminals.deinit(allocator);
        self.* = undefined;
    }
};

pub const WorkspaceLink = struct {
    name: []u8,
    node_id: []u8,
    resource: []u8,

    fn deinit(self: *WorkspaceLink, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.node_id);
        allocator.free(self.resource);
        self.* = undefined;
    }
};

pub const WorkspacePolicy = struct {
    workspace_id: []u8,
    nodes: std.ArrayListUnmanaged(WorkspaceNodePolicy) = .{},
    visible_agents: std.ArrayListUnmanaged([]u8) = .{},
    workspace_links: std.ArrayListUnmanaged(WorkspaceLink) = .{},

    pub fn deinit(self: *WorkspacePolicy, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        for (self.nodes.items) |*node| node.deinit(allocator);
        self.nodes.deinit(allocator);
        for (self.visible_agents.items) |agent| allocator.free(agent);
        self.visible_agents.deinit(allocator);
        for (self.workspace_links.items) |*link| link.deinit(allocator);
        self.workspace_links.deinit(allocator);
        self.* = undefined;
    }
};

pub const LoadOptions = struct {
    agent_id: []const u8,
    workspace_id: ?[]const u8 = null,
    agents_dir: []const u8 = "agents",
    projects_dir: []const u8 = "projects",
};

pub fn loadWorkspacePolicy(allocator: std.mem.Allocator, options: LoadOptions) !WorkspacePolicy {
    var policy = try initDefaults(allocator, options);
    errdefer policy.deinit(allocator);

    const agent_policy_path = try std.fs.path.join(allocator, &.{ options.agents_dir, options.agent_id, "agent_policy.json" });
    defer allocator.free(agent_policy_path);

    // Apply the agent policy once up front so it can steer project selection,
    // then re-apply it last so agent-specific restrictions remain authoritative.
    try applyWorkspacePolicyFile(allocator, &policy, options.agent_id, agent_policy_path);

    const workspace_policy_path = try std.fs.path.join(allocator, &.{ options.projects_dir, policy.workspace_id, "project_policy.json" });
    defer allocator.free(workspace_policy_path);
    try applyWorkspacePolicyFile(allocator, &policy, options.agent_id, workspace_policy_path);

    try applyWorkspacePolicyFile(allocator, &policy, options.agent_id, agent_policy_path);

    try ensureDefaults(allocator, &policy, options.agent_id);
    return policy;
}

fn initDefaults(allocator: std.mem.Allocator, options: LoadOptions) !WorkspacePolicy {
    const workspace_seed = options.workspace_id orelse "workspace";
    var policy = WorkspacePolicy{
        .workspace_id = try allocator.dupe(u8, workspace_seed),
    };
    errdefer policy.deinit(allocator);

    try policy.visible_agents.append(allocator, try allocator.dupe(u8, options.agent_id));
    try appendDefaultLocalNode(allocator, &policy.nodes);
    try appendDefaultWorkspaceLinks(allocator, &policy);
    return policy;
}

fn appendDefaultLocalNode(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayListUnmanaged(WorkspaceNodePolicy),
) !void {
    var node = WorkspaceNodePolicy{
        .id = try allocator.dupe(u8, "local"),
        .resources = .{
            .fs = true,
            .camera = false,
            .screen = false,
            .user = false,
        },
    };
    errdefer node.deinit(allocator);
    try node.terminals.append(allocator, try allocator.dupe(u8, "1"));
    try nodes.append(allocator, node);
}

fn appendDefaultWorkspaceLinks(allocator: std.mem.Allocator, policy: *WorkspacePolicy) !void {
    for (policy.nodes.items) |node| {
        if (!node.resources.fs) continue;
        const link_name = try std.fmt.allocPrint(allocator, "{s}::fs", .{node.id});
        errdefer allocator.free(link_name);
        var link = WorkspaceLink{
            .name = link_name,
            .node_id = try allocator.dupe(u8, node.id),
            .resource = try allocator.dupe(u8, "fs"),
        };
        errdefer link.deinit(allocator);
        try policy.workspace_links.append(allocator, link);
    }
}

fn ensureDefaults(
    allocator: std.mem.Allocator,
    policy: *WorkspacePolicy,
    agent_id: []const u8,
) !void {
    if (policy.nodes.items.len == 0) {
        try appendDefaultLocalNode(allocator, &policy.nodes);
    }

    if (!sliceListContains(policy.visible_agents.items, agent_id)) {
        try policy.visible_agents.append(allocator, try allocator.dupe(u8, agent_id));
    }

    if (policy.visible_agents.items.len == 0) {
        try policy.visible_agents.append(allocator, try allocator.dupe(u8, agent_id));
    }

    if (policy.workspace_links.items.len == 0) {
        try appendDefaultWorkspaceLinks(allocator, policy);
    }

    if (policy.workspace_links.items.len == 0 and policy.nodes.items.len > 0) {
        const link_name = try std.fmt.allocPrint(allocator, "{s}::fs", .{policy.nodes.items[0].id});
        errdefer allocator.free(link_name);
        var link = WorkspaceLink{
            .name = link_name,
            .node_id = try allocator.dupe(u8, policy.nodes.items[0].id),
            .resource = try allocator.dupe(u8, "fs"),
        };
        errdefer link.deinit(allocator);
        try policy.workspace_links.append(allocator, link);
    }
}

fn applyWorkspacePolicyFile(
    allocator: std.mem.Allocator,
    policy: *WorkspacePolicy,
    agent_id: []const u8,
    path: []const u8,
) !void {
    const raw = std.fs.cwd().readFileAlloc(allocator, path, max_policy_bytes) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            std.log.warn("workspace policy load skipped for {s}: {s}", .{ path, @errorName(err) });
            return;
        },
    };
    defer allocator.free(raw);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch |err| {
        std.log.warn("workspace policy parse skipped for {s}: {s}", .{ path, @errorName(err) });
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        std.log.warn("workspace policy parse skipped for {s}: root is not object", .{path});
        return;
    }
    const obj = parsed.value.object;

    if (obj.get("project_id")) |raw_value| {
        if (raw_value == .string and raw_value.string.len > 0) {
            allocator.free(policy.workspace_id);
            policy.workspace_id = try allocator.dupe(u8, raw_value.string);
        }
    }

    if (obj.get("nodes")) |raw_nodes| {
        try replaceNodesFromValue(allocator, &policy.nodes, raw_nodes);
    }

    if (obj.get("visible_agents")) |raw_agents| {
        try replaceVisibleAgentsFromValue(allocator, &policy.visible_agents, raw_agents);
    }

    if (obj.get("project_links")) |raw_links| {
        try replaceWorkspaceLinksFromValue(allocator, &policy.workspace_links, raw_links);
    }

    if (!sliceListContains(policy.visible_agents.items, agent_id)) {
        try policy.visible_agents.append(allocator, try allocator.dupe(u8, agent_id));
    }
}

fn replaceNodesFromValue(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayListUnmanaged(WorkspaceNodePolicy),
    value: std.json.Value,
) !void {
    if (value != .array) return;

    for (nodes.items) |*node| node.deinit(allocator);
    nodes.clearRetainingCapacity();

    for (value.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const raw_id = obj.get("id") orelse continue;
        if (raw_id != .string or raw_id.string.len == 0) continue;

        var node = WorkspaceNodePolicy{
            .id = try allocator.dupe(u8, raw_id.string),
            .resources = .{},
        };
        errdefer node.deinit(allocator);

        if (obj.get("resources")) |raw_resources| {
            if (raw_resources == .object) {
                if (raw_resources.object.get("fs")) |raw_field| {
                    if (raw_field == .bool) node.resources.fs = raw_field.bool;
                }
                if (raw_resources.object.get("camera")) |raw_field| {
                    if (raw_field == .bool) node.resources.camera = raw_field.bool;
                }
                if (raw_resources.object.get("screen")) |raw_field| {
                    if (raw_field == .bool) node.resources.screen = raw_field.bool;
                }
                if (raw_resources.object.get("user")) |raw_field| {
                    if (raw_field == .bool) node.resources.user = raw_field.bool;
                }
            }
        }

        if (obj.get("terminals")) |raw_terminals| {
            if (raw_terminals == .array) {
                for (raw_terminals.array.items) |raw_terminal| {
                    if (raw_terminal != .string or raw_terminal.string.len == 0) continue;
                    try node.terminals.append(allocator, try allocator.dupe(u8, raw_terminal.string));
                }
            }
        }

        if (node.resources.fs and node.terminals.items.len == 0) {
            try node.terminals.append(allocator, try allocator.dupe(u8, "1"));
        }
        try nodes.append(allocator, node);
    }
}

fn replaceVisibleAgentsFromValue(
    allocator: std.mem.Allocator,
    visible_agents: *std.ArrayListUnmanaged([]u8),
    value: std.json.Value,
) !void {
    if (value != .array) return;

    for (visible_agents.items) |agent| allocator.free(agent);
    visible_agents.clearRetainingCapacity();

    for (value.array.items) |item| {
        if (item != .string or item.string.len == 0) continue;
        if (sliceListContains(visible_agents.items, item.string)) continue;
        try visible_agents.append(allocator, try allocator.dupe(u8, item.string));
    }
}

fn replaceWorkspaceLinksFromValue(
    allocator: std.mem.Allocator,
    workspace_links: *std.ArrayListUnmanaged(WorkspaceLink),
    value: std.json.Value,
) !void {
    if (value != .array) return;

    for (workspace_links.items) |*link| link.deinit(allocator);
    workspace_links.clearRetainingCapacity();

    for (value.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const raw_node_id = obj.get("node_id") orelse continue;
        if (raw_node_id != .string or raw_node_id.string.len == 0) continue;
        const resource = if (obj.get("resource")) |raw_resource|
            if (raw_resource == .string and raw_resource.string.len > 0) raw_resource.string else "fs"
        else
            "fs";
        const name = if (obj.get("name")) |raw_name|
            if (raw_name == .string and raw_name.string.len > 0) raw_name.string else null
        else
            null;

        const resolved_name = if (name) |provided|
            try allocator.dupe(u8, provided)
        else
            try std.fmt.allocPrint(allocator, "{s}::{s}", .{ raw_node_id.string, resource });
        errdefer allocator.free(resolved_name);

        var link = WorkspaceLink{
            .name = resolved_name,
            .node_id = try allocator.dupe(u8, raw_node_id.string),
            .resource = try allocator.dupe(u8, resource),
        };
        errdefer link.deinit(allocator);
        try workspace_links.append(allocator, link);
    }
}

fn sliceListContains(items: []const []u8, value: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

test "workspace_policy: defaults provide a usable workspace view" {
    const allocator = std.testing.allocator;
    var policy = try loadWorkspacePolicy(
        allocator,
        .{
            .agent_id = "spider-monkey",
            .workspace_id = "workspace-demo",
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
        },
    );
    defer policy.deinit(allocator);

    try std.testing.expectEqualStrings("workspace-demo", policy.workspace_id);
    try std.testing.expect(policy.nodes.items.len > 0);
    try std.testing.expect(policy.workspace_links.items.len > 0);
    try std.testing.expect(policy.visible_agents.items.len > 0);
}

test "workspace_policy: load reapplies agent policy after project policy" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_root);

    const agent_id = "agent-alpha";
    const project_id = "project-alpha";

    const agent_dir = try std.fs.path.join(allocator, &.{ tmp_root, "agents", agent_id });
    defer allocator.free(agent_dir);
    try std.fs.cwd().makePath(agent_dir);

    const agent_policy_path = try std.fs.path.join(allocator, &.{ agent_dir, "agent_policy.json" });
    defer allocator.free(agent_policy_path);
    try std.fs.cwd().writeFile(.{
        .sub_path = agent_policy_path,
        .data = "{" ++
            "\"project_id\":\"project-alpha\"," ++
            "\"visible_agents\":[\"agent-only\"]," ++
            "\"nodes\":[{" ++
            "\"id\":\"agent-node\"," ++
            "\"resources\":{\"fs\":false,\"camera\":false,\"screen\":false,\"user\":false}," ++
            "\"terminals\":[]" ++
            "}]," ++
            "\"project_links\":[]" ++
            "}",
    });

    const project_dir = try std.fs.path.join(allocator, &.{ tmp_root, "projects", project_id });
    defer allocator.free(project_dir);
    try std.fs.cwd().makePath(project_dir);

    const project_policy_path = try std.fs.path.join(allocator, &.{ project_dir, "project_policy.json" });
    defer allocator.free(project_policy_path);
    try std.fs.cwd().writeFile(.{
        .sub_path = project_policy_path,
        .data = "{" ++
            "\"visible_agents\":[\"project-only\"]," ++
            "\"nodes\":[{" ++
            "\"id\":\"project-node\"," ++
            "\"resources\":{\"fs\":true,\"camera\":false,\"screen\":false,\"user\":false}," ++
            "\"terminals\":[\"1\"]" ++
            "}]" ++
            "}",
    });

    const agents_dir = try std.fs.path.join(allocator, &.{ tmp_root, "agents" });
    defer allocator.free(agents_dir);
    const projects_dir = try std.fs.path.join(allocator, &.{ tmp_root, "projects" });
    defer allocator.free(projects_dir);

    var policy = try loadWorkspacePolicy(
        allocator,
        .{
            .agent_id = agent_id,
            .workspace_id = project_id,
            .agents_dir = agents_dir,
            .projects_dir = projects_dir,
        },
    );
    defer policy.deinit(allocator);

    try std.testing.expectEqualStrings(project_id, policy.workspace_id);
    try std.testing.expectEqual(@as(usize, 1), policy.nodes.items.len);
    try std.testing.expectEqualStrings("agent-node", policy.nodes.items[0].id);
    try std.testing.expect(!sliceListContains(policy.visible_agents.items, "project-only"));
    try std.testing.expect(sliceListContains(policy.visible_agents.items, agent_id));
    try std.testing.expect(sliceListContains(policy.visible_agents.items, "agent-only"));
    try std.testing.expectEqual(@as(usize, 1), policy.workspace_links.items.len);
    try std.testing.expectEqualStrings("agent-node", policy.workspace_links.items[0].node_id);
}
