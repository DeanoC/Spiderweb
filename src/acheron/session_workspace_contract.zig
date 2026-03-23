const std = @import("std");
const unified = @import("spider-protocol").unified;
const workspace_policy = @import("../workspaces/policy.zig");

pub const workspace_entrypoint_relative_namespace_root = "../../..";
pub const workspace_managed_root_name = ".spiderweb";
pub const workspace_managed_root_relative = "./.spiderweb";
pub const workspace_managed_shared_data_dir_name = "shared_data";
pub const workspace_managed_control_dir_name = "control";
pub const workspace_managed_catalog_dir_name = "catalog";
pub const workspace_managed_venoms_dir_name = "venoms";
pub const workspace_agents_contract_path = "/nodes/local/fs/AGENTS.md";
pub const namespace_agents_contract_path = "/AGENTS.md";
pub const workspace_agents_heading = "# Spiderweb Workspace Agent Contract";
pub const workspace_agents_managed_begin = "<!-- SPIDERWEB:BEGIN MANAGED -->";
pub const workspace_agents_managed_end = "<!-- SPIDERWEB:END MANAGED -->";

pub const BootstrapRequiredVenom = struct {
    venom_id: []const u8,
    invoke_path: ?[]const u8 = null,
};

pub const bootstrap_required_venoms = [_]BootstrapRequiredVenom{
    .{ .venom_id = "terminal", .invoke_path = "/.spiderweb/venoms/terminal/control/invoke.json" },
    .{ .venom_id = "git", .invoke_path = "/.spiderweb/venoms/git/control/invoke.json" },
    .{ .venom_id = "search_code", .invoke_path = "/.spiderweb/venoms/search_code/control/invoke.json" },
    .{ .venom_id = "library" },
    .{ .venom_id = "events" },
};

const BootstrapContractPaths = struct {
    protocol_path: []const u8,
    workspace_meta_dir: []const u8,
    quickref_path: []const u8,
    bootstrap_path: []const u8,
    workspace_status_path: []const u8,
    packages_path: []const u8,
    providers_path: []const u8,
    bindings_path: []const u8,
    shared_data_root: []const u8,
    world_seed_path: []const u8,
    items_seed_path: []const u8,
    puzzle_seed_path: []const u8,
    control_root: []const u8,
    catalog_root: []const u8,
    venom_root: []const u8,
    ensure_home_path: []const u8,
    repair_bind_path: []const u8,
    register_runtime_path: []const u8,
    target_template: []const u8,

    fn init(allocator: std.mem.Allocator, workspace_id: []const u8) !BootstrapContractPaths {
        _ = workspace_id;
        return .{
            .protocol_path = try workspaceManagedPath(allocator, "protocol.json"),
            .workspace_meta_dir = try workspaceManagedPath(allocator, null),
            .quickref_path = try workspaceManagedPath(allocator, "agent_bootstrap_quickref.json"),
            .bootstrap_path = try workspaceManagedPath(allocator, "agent_bootstrap.json"),
            .workspace_status_path = try workspaceManagedPath(allocator, "workspace_status.json"),
            .packages_path = try workspaceManagedCatalogPath(allocator, "packages.json"),
            .providers_path = try workspaceManagedCatalogPath(allocator, "providers.json"),
            .bindings_path = try workspaceManagedCatalogPath(allocator, "bindings.json"),
            .shared_data_root = try workspaceManagedPath(allocator, "shared_data"),
            .world_seed_path = try workspaceManagedSharedDataPath(allocator, "world_seed.json"),
            .items_seed_path = try workspaceManagedSharedDataPath(allocator, "items_seed.json"),
            .puzzle_seed_path = try workspaceManagedSharedDataPath(allocator, "puzzle_seed.json"),
            .control_root = try workspaceManagedControlPath(allocator, null),
            .catalog_root = try workspaceManagedCatalogPath(allocator, null),
            .venom_root = try workspaceManagedVenomsPath(allocator, null),
            .ensure_home_path = try workspaceManagedControlPath(allocator, "workspace/home/control/ensure.json"),
            .repair_bind_path = try workspaceManagedControlPath(allocator, "workspace/binds/control/bind.json"),
            .register_runtime_path = try workspaceManagedControlPath(allocator, "runtimes/control/register.json"),
            .target_template = try workspaceManagedVenomsPath(allocator, "{venom_id}"),
        };
    }

    fn deinit(self: BootstrapContractPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.protocol_path);
        allocator.free(self.workspace_meta_dir);
        allocator.free(self.quickref_path);
        allocator.free(self.bootstrap_path);
        allocator.free(self.workspace_status_path);
        allocator.free(self.packages_path);
        allocator.free(self.providers_path);
        allocator.free(self.bindings_path);
        allocator.free(self.shared_data_root);
        allocator.free(self.world_seed_path);
        allocator.free(self.items_seed_path);
        allocator.free(self.puzzle_seed_path);
        allocator.free(self.control_root);
        allocator.free(self.catalog_root);
        allocator.free(self.venom_root);
        allocator.free(self.ensure_home_path);
        allocator.free(self.repair_bind_path);
        allocator.free(self.register_runtime_path);
        allocator.free(self.target_template);
    }
};

pub fn buildWorkspaceContractsJson(session: anytype, workspace_id: []const u8) ![]u8 {
    const workspace_metadata_files = [_][]const u8{
        "topology.json",
        "nodes.json",
        "agents.json",
        "sources.json",
        "contracts.json",
        "paths.json",
        "summary.json",
        "agent_bootstrap.json",
        "agent_bootstrap_quickref.json",
        "alerts.json",
        "workspace_status.json",
        "mounts.json",
        "desired_mounts.json",
        "actual_mounts.json",
        "binds.json",
        "packages.json",
        "providers.json",
        "bindings.json",
        "drift.json",
        "reconcile.json",
        "availability.json",
        "health.json",
    };

    var out = std.io.Writer.Allocating.init(session.allocator);
    errdefer out.deinit();

    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("version");
    try jw.write("acheron-namespace-workspace-contract");
    try jw.objectField("workspace_id");
    try jw.write(workspace_id);
    try jw.objectField("top_level_roots");
    try jw.write(.{ "/.spiderweb" });
    try jw.objectField("workspace_metadata_files");
    try jw.write(workspace_metadata_files);
    try jw.objectField("links");
    try jw.beginObject();
    try jw.objectField("managed_root");
    try jw.write("/.spiderweb");
    try jw.objectField("control_root");
    try jw.write("/.spiderweb/control");
    try jw.objectField("catalog_root");
    try jw.write("/.spiderweb/catalog");
    try jw.objectField("venoms_root");
    try jw.write("/.spiderweb/venoms");
    try jw.objectField("workspace_status");
    try jw.write("/.spiderweb/workspace_status.json");
    try jw.objectField("workspace_binds");
    try jw.write("/.spiderweb/catalog/bindings.json");
    try jw.objectField("packages");
    try jw.write("/.spiderweb/catalog/packages.json");
    try jw.objectField("providers");
    try jw.write("/.spiderweb/catalog/providers.json");
    try jw.objectField("bindings");
    try jw.write("/.spiderweb/catalog/bindings.json");
    try jw.objectField("agent_bootstrap");
    try jw.write("/.spiderweb/agent_bootstrap.json");
    try jw.objectField("agent_bootstrap_quickref");
    try jw.write("/.spiderweb/agent_bootstrap_quickref.json");
    try jw.objectField("workspace_agents_contract");
    try jw.write("/AGENTS.md");
    try jw.objectField("workspace_agents_contract_persisted");
    try jw.write(workspace_agents_contract_path);
    try jw.endObject();
    try jw.endObject();
    return try out.toOwnedSlice();
}

pub fn buildWorkspacePathsJson(session: anytype, policy: workspace_policy.WorkspacePolicy) ![]u8 {
    var out = std.io.Writer.Allocating.init(session.allocator);
    errdefer out.deinit();

    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("workspace_id");
    try jw.write(policy.workspace_id);
    try jw.objectField("managed_root");
    try jw.write("/.spiderweb");
    try jw.objectField("control");
    try jw.beginObject();
    try jw.objectField("root");
    try jw.write("/.spiderweb/control");
    try jw.objectField("workspace_home");
    try jw.write("/.spiderweb/control/workspace/home");
    try jw.objectField("workspace_mounts");
    try jw.write("/.spiderweb/control/workspace/mounts");
    try jw.objectField("workspace_binds");
    try jw.write("/.spiderweb/control/workspace/binds");
    try jw.objectField("runtimes");
    try jw.write("/.spiderweb/control/runtimes");
    try jw.endObject();
    try jw.objectField("catalog");
    try jw.beginObject();
    try jw.objectField("root");
    try jw.write("/.spiderweb/catalog");
    try jw.objectField("packages");
    try jw.write("/.spiderweb/catalog/packages.json");
    try jw.objectField("providers");
    try jw.write("/.spiderweb/catalog/providers.json");
    try jw.objectField("bindings");
    try jw.write("/.spiderweb/catalog/bindings.json");
    try jw.endObject();
    try jw.objectField("venoms");
    try jw.beginObject();
    try jw.objectField("root");
    try jw.write("/.spiderweb/venoms");
    try jw.endObject();
    try jw.objectField("bootstrap");
    try jw.beginObject();
    try jw.objectField("meta");
    try jw.write("/.spiderweb/agent_bootstrap.json");
    try jw.objectField("quickref");
    try jw.write("/.spiderweb/agent_bootstrap_quickref.json");
    try jw.objectField("workspace_contract");
    try jw.beginObject();
    try jw.objectField("namespace_alias");
    try jw.write("/AGENTS.md");
    try jw.objectField("workspace_path");
    try jw.write(workspace_agents_contract_path);
    try jw.endObject();
    try jw.endObject();
    try jw.endObject();
    return try out.toOwnedSlice();
}

pub fn buildAgentBootstrapQuickrefJson(session: anytype, workspace_id: []const u8, agent_id: []const u8) ![]u8 {
    const paths = try BootstrapContractPaths.init(session.allocator, workspace_id);
    defer paths.deinit(session.allocator);

    const discovery_order = [_][]const u8{
        "./AGENTS.md",
        paths.protocol_path,
        paths.quickref_path,
        paths.bootstrap_path,
        paths.world_seed_path,
        paths.items_seed_path,
        paths.puzzle_seed_path,
    };

    var out = std.io.Writer.Allocating.init(session.allocator);
    errdefer out.deinit();

    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("version");
    try jw.write("spiderweb-agent-bootstrap-quickref-v1");
    try jw.objectField("workspace_id");
    try jw.write(workspace_id);
    try jw.objectField("agent_id");
    try jw.write(agent_id);
    try jw.objectField("workspace_write_root");
    try jw.write(".");
    try jw.objectField("shared_data_root");
    try jw.write(paths.shared_data_root);
    try jw.objectField("venom_root");
    try jw.write(paths.venom_root);
    try jw.objectField("control_root");
    try jw.write(paths.control_root);
    try jw.objectField("catalog_root");
    try jw.write(paths.catalog_root);

    try jw.objectField("workspace_contract");
    try jw.beginObject();
    try jw.objectField("entrypoint_path");
    try jw.write("./AGENTS.md");
    try jw.objectField("managed_root");
    try jw.write("./.spiderweb");
    try jw.endObject();

    try jw.objectField("paths");
    try jw.beginObject();
    try jw.objectField("protocol");
    try jw.write(paths.protocol_path);
    try jw.objectField("workspace_meta_dir");
    try jw.write(paths.workspace_meta_dir);
    try jw.objectField("quickref");
    try jw.write(paths.quickref_path);
    try jw.objectField("bootstrap");
    try jw.write(paths.bootstrap_path);
    try jw.objectField("workspace_status");
    try jw.write(paths.workspace_status_path);
    try jw.objectField("packages");
    try jw.write(paths.packages_path);
    try jw.objectField("providers");
    try jw.write(paths.providers_path);
    try jw.objectField("bindings");
    try jw.write(paths.bindings_path);
    try jw.objectField("shared_data_root");
    try jw.write(paths.shared_data_root);
    try jw.objectField("venom_root");
    try jw.write(paths.venom_root);
    try jw.objectField("control_root");
    try jw.write(paths.control_root);
    try jw.objectField("catalog_root");
    try jw.write(paths.catalog_root);
    try jw.objectField("workspace_write_root");
    try jw.write(".");
    try jw.endObject();

    try jw.objectField("discovery_order");
    try jw.write(discovery_order);

    try jw.objectField("fallback_meta");
    try jw.beginObject();
    try jw.objectField("packages");
    try jw.write(paths.packages_path);
    try jw.objectField("providers");
    try jw.write(paths.providers_path);
    try jw.objectField("bindings");
    try jw.write(paths.bindings_path);
    try jw.endObject();

    try jw.objectField("required_venoms");
    const present_count = try writeBootstrapRequiredVenoms(session, &jw);

    try jw.objectField("all_required_venoms_present");
    try jw.write(present_count == bootstrap_required_venoms.len);
    try jw.objectField("required_venom_count");
    try jw.write(bootstrap_required_venoms.len);
    try jw.objectField("required_venoms_present_count");
    try jw.write(present_count);

    try jw.objectField("control_writes");
    try jw.beginObject();
    try jw.objectField("ensure_home");
    try jw.write(paths.ensure_home_path);
    try jw.objectField("repair_bind");
    try jw.write(paths.repair_bind_path);
    try jw.objectField("runtime_attach");
    try jw.write(paths.register_runtime_path);
    try jw.endObject();

    try jw.objectField("implementation_hint");
    try jw.beginObject();
    try jw.objectField("prefer_quickref_over_raw_catalog_enumeration");
    try jw.write(true);
    try jw.objectField("proceed_directly_when_ready");
    try jw.write(true);
    try jw.endObject();

    try jw.endObject();
    return try out.toOwnedSlice();
}

pub fn buildAgentBootstrapJson(session: anytype, workspace_id: []const u8, agent_id: []const u8) ![]u8 {
    const paths = try BootstrapContractPaths.init(session.allocator, workspace_id);
    defer paths.deinit(session.allocator);

    const required_reads = [_][]const u8{
        "./AGENTS.md",
        paths.protocol_path,
        paths.quickref_path,
        paths.bootstrap_path,
        paths.world_seed_path,
        paths.items_seed_path,
        paths.puzzle_seed_path,
    };
    const fallback_reads = [_][]const u8{
        paths.packages_path,
        paths.providers_path,
        paths.bindings_path,
        paths.workspace_status_path,
    };
    const required_venom_ids = [_][]const u8{ "terminal", "git", "search_code", "library", "events" };
    const default_worker_venoms = [_][]const u8{ "memory", "sub_brains" };

    var out = std.io.Writer.Allocating.init(session.allocator);
    errdefer out.deinit();

    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("version");
    try jw.write("spiderweb-agent-bootstrap-v1");
    try jw.objectField("workspace_id");
    try jw.write(workspace_id);
    try jw.objectField("agent_id");
    try jw.write(agent_id);
    try jw.objectField("workspace_write_root");
    try jw.write(".");
    try jw.objectField("shared_data_root");
    try jw.write(paths.shared_data_root);

    try jw.objectField("workspace_contract");
    try jw.beginObject();
    try jw.objectField("entrypoint_path");
    try jw.write("./AGENTS.md");
    try jw.objectField("task_source");
    try jw.write("user_prompt");
    try jw.objectField("managed_root");
    try jw.write("./.spiderweb");
    try jw.endObject();

    try jw.objectField("paths");
    try jw.beginObject();
    try jw.objectField("protocol");
    try jw.write(paths.protocol_path);
    try jw.objectField("quickref");
    try jw.write(paths.quickref_path);
    try jw.objectField("bootstrap");
    try jw.write(paths.bootstrap_path);
    try jw.objectField("workspace_status");
    try jw.write(paths.workspace_status_path);
    try jw.objectField("packages");
    try jw.write(paths.packages_path);
    try jw.objectField("providers");
    try jw.write(paths.providers_path);
    try jw.objectField("bindings");
    try jw.write(paths.bindings_path);
    try jw.objectField("shared_data_root");
    try jw.write(paths.shared_data_root);
    try jw.objectField("control_root");
    try jw.write(paths.control_root);
    try jw.objectField("catalog_root");
    try jw.write(paths.catalog_root);
    try jw.objectField("venom_root");
    try jw.write(paths.venom_root);
    try jw.objectField("workspace_write_root");
    try jw.write(".");
    try jw.endObject();

    try jw.objectField("venom_preference");
    try jw.beginObject();
    try jw.objectField("preferred_root");
    try jw.write(paths.venom_root);
    try jw.endObject();

    try jw.objectField("required_reads");
    try jw.write(required_reads);
    try jw.objectField("fallback_reads");
    try jw.write(fallback_reads);

    try jw.objectField("bootstrap_sequence");
    try jw.beginArray();

    try jw.beginObject();
    try jw.objectField("step");
    try jw.write("ensure_home");
    try jw.objectField("control_path");
    try jw.write("./.spiderweb/control/workspace/home");
    try jw.objectField("invoke_path");
    try jw.write(paths.ensure_home_path);
    try jw.objectField("payload");
    try jw.beginObject();
    try jw.objectField("agent_id");
    try jw.write(agent_id);
    try jw.objectField("workspace_id");
    try jw.write(workspace_id);
    try jw.endObject();
    try jw.objectField("required");
    try jw.write(true);
    try jw.endObject();

    try jw.beginObject();
    try jw.objectField("step");
    try jw.write("verify_capability_bindings");
    try jw.objectField("venom_root");
    try jw.write("./.spiderweb/venoms");
    try jw.objectField("required_venoms");
    try jw.write(required_venom_ids);
    try jw.objectField("repair_invoke_path");
    try jw.write(paths.repair_bind_path);
    try jw.objectField("target_template");
    try jw.write(paths.target_template);
    try jw.objectField("required");
    try jw.write(true);
    try jw.endObject();

    try jw.beginObject();
    try jw.objectField("step");
    try jw.write("optional_runtime_attach");
    try jw.objectField("control_path");
    try jw.write("./.spiderweb/control/runtimes");
    try jw.objectField("invoke_path");
    try jw.write(paths.register_runtime_path);
    try jw.objectField("default_venoms");
    try jw.write(default_worker_venoms);
    try jw.objectField("required");
    try jw.write(false);
    try jw.endObject();

    try jw.endArray();

    try jw.objectField("persistence");
    try jw.beginObject();
    try jw.objectField("shared_workspace_binds");
    try jw.write("persistent");
    try jw.objectField("shared_workspace_mounts");
    try jw.write("persistent");
    try jw.objectField("agent_home");
    try jw.write("durable_per_agent");
    try jw.objectField("worker_loopback");
    try jw.write("ephemeral");
    try jw.endObject();

    try jw.objectField("detach");
    try jw.beginObject();
    try jw.objectField("shared_changes");
    try jw.write("keep");
    try jw.objectField("worker_state");
    try jw.write("detach_or_ttl_cleanup");
    try jw.endObject();

    try jw.endObject();
    return try out.toOwnedSlice();
}

pub fn seedWorkspaceAgentsContract(session: anytype, workspace_id: []const u8, local_fs_world_prefix: []const u8) !void {
    const managed_block = try buildWorkspaceAgentsManagedBlock(session, workspace_id);
    defer session.allocator.free(managed_block);

    const existing = try readExistingWorkspaceAgentsContract(session);
    defer if (existing) |value| session.allocator.free(value);
    const merged = try mergeWorkspaceAgentsContract(session, managed_block, existing);
    defer session.allocator.free(merged);

    var workspace_file_id: u32 = 0;
    var namespace_file_id: u32 = 0;

    const local_fs_dir = session.resolveAbsolutePathNoBinds(local_fs_world_prefix);
    if (local_fs_dir) |dir_id| {
        if (session.lookupChild(dir_id, "AGENTS.md")) |file_id| {
            workspace_file_id = file_id;
        } else {
            workspace_file_id = try session.addFile(dir_id, "AGENTS.md", merged, true, .none);
        }
    }

    if (session.lookupChild(session.root_id, "AGENTS.md")) |file_id| {
        namespace_file_id = file_id;
    } else {
        namespace_file_id = try session.addFile(session.root_id, "AGENTS.md", merged, false, .none);
    }

    if (workspace_file_id != 0) {
        try session.registerNodeAliasPair(workspace_file_id, namespace_file_id);
        try session.setFileContent(workspace_file_id, merged);
    } else {
        try session.setFileContent(namespace_file_id, merged);
    }

    session.writeWorkspaceFile(workspace_agents_contract_path, merged) catch {};
}

fn namespacePathToEntrypointRelative(allocator: std.mem.Allocator, namespace_path: []const u8) ![]u8 {
    if (std.mem.eql(u8, namespace_path, "/")) {
        return allocator.dupe(u8, workspace_entrypoint_relative_namespace_root);
    }
    if (std.mem.eql(u8, namespace_path, "/AGENTS.md")) {
        return allocator.dupe(u8, "./AGENTS.md");
    }
    if (std.mem.eql(u8, namespace_path, "/meta/protocol.json")) {
        return workspaceManagedPath(allocator, "protocol.json");
    }
    if (std.mem.eql(u8, namespace_path, "/shared_data")) {
        return workspaceManagedChildPath(allocator, workspace_managed_shared_data_dir_name, null);
    }
    if (std.mem.startsWith(u8, namespace_path, "/shared_data/")) {
        return workspaceManagedSharedDataPath(allocator, namespace_path["/shared_data/".len..]);
    }
    if (std.mem.startsWith(u8, namespace_path, "/services/")) {
        const tail = namespace_path["/services/".len..];
        if (std.mem.startsWith(u8, tail, "home")) {
            return workspaceManagedControlPath(allocator, "workspace/home");
        }
        if (std.mem.startsWith(u8, tail, "mounts")) {
            return workspaceManagedControlPath(allocator, "workspace/mounts");
        }
        if (std.mem.startsWith(u8, tail, "workers")) {
            return workspaceManagedControlPath(allocator, "runtimes");
        }
        return workspaceManagedVenomsPath(allocator, tail);
    }
    if (std.mem.startsWith(u8, namespace_path, "/nodes/local/venoms/")) {
        const tail = namespace_path["/nodes/local/venoms/".len..];
        if (std.mem.startsWith(u8, tail, "home")) {
            return workspaceManagedControlPath(allocator, "workspace/home");
        }
        if (std.mem.startsWith(u8, tail, "mounts")) {
            return workspaceManagedControlPath(allocator, "workspace/mounts");
        }
        if (std.mem.startsWith(u8, tail, "workers")) {
            return workspaceManagedControlPath(allocator, "runtimes");
        }
        return workspaceManagedVenomsPath(allocator, tail);
    }
    if (std.mem.endsWith(u8, namespace_path, "/meta/agent_bootstrap_quickref.json")) {
        return workspaceManagedPath(allocator, "agent_bootstrap_quickref.json");
    }
    if (std.mem.endsWith(u8, namespace_path, "/meta/agent_bootstrap.json")) {
        return workspaceManagedPath(allocator, "agent_bootstrap.json");
    }
    if (std.mem.endsWith(u8, namespace_path, "/meta/workspace_status.json")) {
        return workspaceManagedPath(allocator, "workspace_status.json");
    }
    if (std.mem.endsWith(u8, namespace_path, "/meta/packages.json")) {
        return workspaceManagedCatalogPath(allocator, "packages.json");
    }
    if (std.mem.endsWith(u8, namespace_path, "/meta/providers.json")) {
        return workspaceManagedCatalogPath(allocator, "providers.json");
    }
    if (std.mem.endsWith(u8, namespace_path, "/meta/bindings.json")) {
        return workspaceManagedCatalogPath(allocator, "bindings.json");
    }
    if (std.mem.endsWith(u8, namespace_path, "/meta/mounted_services.json")) {
        return workspaceManagedCatalogPath(allocator, "bindings.json");
    }
    if (std.mem.endsWith(u8, namespace_path, "/meta/venom_packages.json")) {
        return workspaceManagedCatalogPath(allocator, "packages.json");
    }
    if (std.mem.eql(u8, namespace_path, "/nodes/local/fs")) {
        return allocator.dupe(u8, ".");
    }
    if (std.mem.startsWith(u8, namespace_path, "/nodes/local/fs/")) {
        return allocator.dupe(u8, namespace_path["/nodes/local/fs/".len..]);
    }
    if (namespace_path.len > 1 and namespace_path[0] == '/') {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{
            workspace_entrypoint_relative_namespace_root,
            namespace_path[1..],
        });
    }
    return allocator.dupe(u8, namespace_path);
}

fn workspaceManagedPath(allocator: std.mem.Allocator, leaf: ?[]const u8) ![]u8 {
    return if (leaf) |value|
        std.fmt.allocPrint(allocator, "{s}/{s}", .{ workspace_managed_root_relative, value })
    else
        allocator.dupe(u8, workspace_managed_root_relative);
}

fn workspaceManagedChildPath(allocator: std.mem.Allocator, child_dir: []const u8, leaf: ?[]const u8) ![]u8 {
    return if (leaf) |value|
        std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ workspace_managed_root_relative, child_dir, value })
    else
        std.fmt.allocPrint(allocator, "{s}/{s}", .{ workspace_managed_root_relative, child_dir });
}

fn workspaceManagedSharedDataPath(allocator: std.mem.Allocator, leaf: []const u8) ![]u8 {
    return workspaceManagedChildPath(allocator, workspace_managed_shared_data_dir_name, leaf);
}

fn workspaceManagedControlPath(allocator: std.mem.Allocator, leaf: ?[]const u8) ![]u8 {
    return workspaceManagedChildPath(allocator, workspace_managed_control_dir_name, leaf);
}

fn workspaceManagedCatalogPath(allocator: std.mem.Allocator, leaf: ?[]const u8) ![]u8 {
    return workspaceManagedChildPath(allocator, workspace_managed_catalog_dir_name, leaf);
}

fn workspaceManagedVenomsPath(allocator: std.mem.Allocator, leaf: ?[]const u8) ![]u8 {
    return workspaceManagedChildPath(allocator, workspace_managed_venoms_dir_name, leaf);
}

fn writeBootstrapRequiredVenoms(session: anytype, jw: *std.json.Stringify) !usize {
    var present_count: usize = 0;
    try jw.beginArray();
    for (bootstrap_required_venoms) |venom| {
        const bind_path = try workspaceManagedVenomsPath(session.allocator, venom.venom_id);
        defer session.allocator.free(bind_path);

        const present = session.resolveManagedCapabilityVenomTargetPath(venom.venom_id) catch null != null;
        if (present) present_count += 1;

        const invoke_path = if (venom.invoke_path) |value|
            try session.allocator.dupe(u8, value)
        else
            null;
        defer if (invoke_path) |value| session.allocator.free(value);

        try jw.beginObject();
        try jw.objectField("venom_id");
        try jw.write(venom.venom_id);
        try jw.objectField("path");
        try jw.write(bind_path);
        try jw.objectField("present");
        try jw.write(present);
        try jw.objectField("invoke_path");
        try jw.write(invoke_path);
        try jw.endObject();
    }
    try jw.endArray();
    return present_count;
}

fn buildWorkspaceAgentsManagedBlock(session: anytype, workspace_id: []const u8) ![]u8 {
    const paths = try BootstrapContractPaths.init(session.allocator, workspace_id);
    defer paths.deinit(session.allocator);

    var available_services = std.ArrayListUnmanaged(u8){};
    defer available_services.deinit(session.allocator);
    var missing_services = std.ArrayListUnmanaged(u8){};
    defer missing_services.deinit(session.allocator);

    for (bootstrap_required_venoms) |service| {
        const bind_path = try std.fmt.allocPrint(session.allocator, "/.spiderweb/venoms/{s}", .{service.venom_id});
        defer session.allocator.free(bind_path);
        const target = if ((session.resolveManagedCapabilityVenomTargetPath(service.venom_id) catch null) != null) &available_services else &missing_services;
        if (target.items.len != 0) try target.appendSlice(session.allocator, ", ");
        try target.appendSlice(session.allocator, service.venom_id);
    }

    const available_text = if (available_services.items.len != 0)
        available_services.items
    else
        "none";
    const missing_text = if (missing_services.items.len != 0)
        missing_services.items
    else
        "none";
    const vision_text = "Workspace intent is tracked by Spiderweb workspace metadata. Follow future workspace-owned guidance files if they are materialized under .spiderweb/.";

    return std.fmt.allocPrint(
        session.allocator,
        \\# Spiderweb Workspace Agent Contract
        \\
        \\{s}
        \\This section is generated by Spiderweb. Follow it first. Workspace-owner notes live below the managed block and are preserved across updates.
        \\
        \\## What This Folder Is
        \\You are in a mounted Spiderweb workspace. The workspace itself is the durable collaboration surface; agents may come and go.
        \\In the normal interactive flow, the agent starts in this directory, so `.` is the workspace write root. Spiderweb projects the required bootstrap, control, catalog, and venom surfaces into `./.spiderweb/` as part of this same mounted workspace contract, so you do not need to climb out of this directory with `..`.
        \\
        \\## Workspace Intent
        \\{s}
        \\
        \\## Required Bootstrap Flow
        \\1. Read `AGENTS.md` first.
        \\2. Read only these required files, in order, using paths relative to this directory:
        \\   - `{s}`
        \\   - `{s}`
        \\   - `{s}`
        \\   - `{s}`
        \\   - `{s}`
        \\   - `{s}`
        \\3. Use `{s}/*` as the preferred capability surface, `{s}/*` for workspace/runtime control, and `{s}/*` for discovery metadata.
        \\4. If `{s}` succeeds and `agent_bootstrap_quickref.json` says `all_required_venoms_present=true`, treat bootstrap as complete immediately and start implementation. Do not keep exploring or re-probing after that point.
        \\5. Keep workspace writes inside the current directory `.` unless the user prompt explicitly says otherwise.
        \\6. When creating or fixing workspace files, rewrite the whole target file in one pass. Do not append partial repair fragments to an existing file. If you need to create multiple files, write them in separate commands so one long shell command cannot partially fail the whole set.
        \\7. If `game.py` fails `py_compile` or the walkthrough run, delete and recreate `game.py` from scratch before retrying. If a regenerated `game.py` still fails `py_compile`, replace it with another full rewrite immediately instead of inspecting the broken file tail or attempting partial edits.
        \\8. Once `python3 -m py_compile game.py` succeeds, do not rewrite `game.py` again unless `python3 game.py < walkthrough.txt` or `python3 validate_game.py --workspace . --shared-data {s} --output game_validation.json` exits non-zero.
        \\9. Treat `python3 game.py < walkthrough.txt` as successful when it exits with code `0`, even if stdout contains repeated input prompts such as `> `. Treat `python3 validate_game.py --workspace . --shared-data {s} --output game_validation.json` as successful when it exits with code `0`. Do not rerun either command through nested shell wrappers or alternate redirection forms unless the command itself failed.
        \\10. Do not run broad scans such as `find`, `rg --files`, or recursive `ls` across `/.spiderweb/control`, `/.spiderweb/catalog`, or `/.spiderweb/venoms`. Read only the exact listed files directly.
        \\
        \\## Namespace Paths
        \\- Current working directory: `.`
        \\- This file: `./AGENTS.md`
        \\- Spiderweb-managed entrypoint root: `./.spiderweb`
        \\- Shared data root from here: `{s}`
        \\- Control root from here: `{s}`
        \\- Catalog root from here: `{s}`
        \\- Venom root from here: `{s}`
        \\
        \\## Current Capability Surface
        \\- Present required venoms: {s}
        \\- Missing optional/repairable venoms: {s}
        \\
        \\## Task Source
        \\For this milestone, the concrete task comes from the user prompt after bootstrap. Do not assume there is a `TASK.md`.
        \\After the required reads above, move directly into implementation and validation unless a required service is genuinely missing.
        \\If the user asks for the standard text-adventure task, completion means:
        \\- Write `game.py`, `game_manifest.json`, `walkthrough.txt`, and `README.md` in the current directory.
        \\- Keep the lantern behind all seeded puzzle gates. Do not leave alternate exits or shortcuts that bypass a required seeded puzzle.
        \\- Run `python3 -m py_compile game.py`.
        \\- Run `python3 game.py < walkthrough.txt`.
        \\- Run `python3 validate_game.py --workspace . --shared-data {s} --output game_validation.json`.
        \\- If a validation step fails, fix the project files and rerun only the failed step.
        \\- If a file-write command times out or fails partway through, check exactly which target files landed and then rewrite only the missing or incomplete files cleanly.
        \\- A `0` exit code from the walkthrough or validator means the step succeeded; do not retry just because stdout includes prompts or because the game appears to wait for redirected input.
        \\- Do not stop after creating partial outputs. Finish when all required files exist and validation succeeds.
        \\
        \\## Future Workspace Guidance
        \\If the workspace later materializes extra guidance files under `.spiderweb/`, treat them as workspace-owned guidance in addition to the user prompt.
        \\
        \\{s}
    ,
        .{
            workspace_agents_managed_begin,
            vision_text,
            paths.protocol_path,
            paths.quickref_path,
            paths.bootstrap_path,
            paths.world_seed_path,
            paths.items_seed_path,
            paths.puzzle_seed_path,
            paths.venom_root,
            paths.control_root,
            paths.catalog_root,
            paths.ensure_home_path,
            paths.shared_data_root,
            paths.shared_data_root,
            paths.shared_data_root,
            paths.control_root,
            paths.catalog_root,
            paths.venom_root,
            available_text,
            missing_text,
            paths.shared_data_root,
            workspace_agents_managed_end,
        },
    );
}

fn mergeWorkspaceAgentsContract(session: anytype, managed_block: []const u8, existing: ?[]const u8) ![]u8 {
    const placeholder =
        "## Workspace Owner Notes\n\nAdd custom workspace-specific rules here. Spiderweb preserves everything outside the managed block.\n";

    if (existing) |current| {
        const begin_index = std.mem.indexOf(u8, current, workspace_agents_managed_begin);
        const end_index = std.mem.indexOf(u8, current, workspace_agents_managed_end);
        if (begin_index != null and end_index != null and end_index.? >= begin_index.?) {
            const suffix_start = end_index.? + workspace_agents_managed_end.len;
            const prefix = trimWorkspaceAgentsPrefixNoise(current[0..begin_index.?]);
            const suffix = current[suffix_start..];
            return std.fmt.allocPrint(session.allocator, "{s}{s}{s}", .{ prefix, managed_block, suffix });
        }
        const cleaned_current = trimWorkspaceAgentsPrefixNoise(current);
        if (std.mem.trim(u8, cleaned_current, " \t\r\n").len != 0) {
            return std.fmt.allocPrint(
                session.allocator,
                "{s}\n\n{s}\n{s}",
                .{ managed_block, placeholder, cleaned_current },
            );
        }
    }

    return std.fmt.allocPrint(session.allocator, "{s}\n\n{s}", .{ managed_block, placeholder });
}

fn trimWorkspaceAgentsPrefixNoise(current: []const u8) []const u8 {
    var cursor: usize = 0;
    var removed_heading = false;

    while (cursor < current.len) {
        const remaining = current[cursor..];
        const trimmed = std.mem.trimLeft(u8, remaining, " \t\r\n");
        const skipped = remaining.len - trimmed.len;

        if (!std.mem.startsWith(u8, trimmed, workspace_agents_heading)) break;

        const after_heading = trimmed[workspace_agents_heading.len..];
        if (after_heading.len != 0 and after_heading[0] != '\n' and after_heading[0] != '\r') break;

        cursor += skipped + workspace_agents_heading.len;
        if (after_heading.len >= 2 and after_heading[0] == '\r' and after_heading[1] == '\n') {
            cursor += 2;
        } else if (after_heading.len >= 1 and (after_heading[0] == '\n' or after_heading[0] == '\r')) {
            cursor += 1;
        }
        removed_heading = true;
    }

    if (!removed_heading) return current;
    return std.mem.trimLeft(u8, current[cursor..], " \t\r\n");
}

fn readExistingWorkspaceAgentsContract(session: anytype) !?[]u8 {
    const host_path = session.resolveWorkspaceHostPath(workspace_agents_contract_path) catch return null;
    defer session.allocator.free(host_path);

    const safe_host_path = (try session.resolveLocalFsSafeHostPath(host_path)) orelse return null;
    defer session.allocator.free(safe_host_path);

    var file = if (std.fs.path.isAbsolute(safe_host_path))
        std.fs.openFileAbsolute(safe_host_path, .{}) catch return null
    else
        std.fs.cwd().openFile(safe_host_path, .{}) catch return null;
    defer file.close();

    return try file.readToEndAlloc(session.allocator, 1024 * 1024);
}
