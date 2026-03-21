const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("errno.h");
    @cInclude("sys/stat.h");
});
const unified = @import("spider-protocol").unified;
const protocol = @import("spider-protocol").protocol;
const shared_exec = @import("spiderweb_node").chat_runtime_exec;
const runtime_handle_mod = @import("../agents/runtime_handle.zig");
const tool_executor_mod = @import("ziggy-tool-runtime").tool_executor;
const shared_node = @import("spiderweb_node");
const workspace_policy = @import("../workspaces/policy.zig");
const control_plane_mod = @import("control_plane.zig");
const acheron_router = @import("router.zig");
const mission_store_mod = @import("../mission_store.zig");
const events_venom = @import("../venoms/events.zig");
const pairing_venom = @import("../venoms/pairing.zig");
const terminal_venom = @import("../venoms/terminal.zig");
const mounts_venom = @import("../venoms/mounts.zig");
const home_venom = @import("../venoms/home.zig");
const workers_venom = @import("../venoms/workers.zig");
const venom_packages_service_venom = @import("../venoms/venom_packages_service.zig");
const workspaces_venom = @import("../venoms/workspaces.zig");
const git_venom = @import("../venoms/git.zig");
const github_pr_venom = @import("../venoms/github_pr.zig");
const missions_venom = @import("../venoms/missions.zig");
const pr_review_venom = @import("../venoms/pr_review.zig");
const venom_packages = @import("../venom_packages.zig");
const venom_package = @import("../venom_package.zig");

var direct_builtin_shell_exec_mutex: std.Thread.Mutex = .{};

const NodeKind = enum {
    dir,
    file,
};

const SpecialKind = enum {
    none,
    agent_venoms_index,
    node_venom_events_log,
    home_invoke,
    home_ensure,
    workers_invoke,
    workers_register,
    workers_heartbeat,
    workers_detach,
    venom_packages_invoke,
    venom_packages_list,
    venom_packages_get,
    venom_packages_install,
    venom_packages_remove,
    projects_invoke,
    projects_list,
    projects_get,
    projects_up,
    git_invoke,
    git_sync_checkout,
    git_status,
    git_diff_range,
    github_pr_invoke,
    github_pr_sync,
    github_pr_ingest_event,
    github_pr_publish_review,
    pr_review_invoke,
    pr_review_configure_repo,
    pr_review_get_repo,
    pr_review_list_repos,
    pr_review_intake,
    pr_review_start,
    pr_review_sync,
    pr_review_run_validation,
    pr_review_record_validation,
    pr_review_draft_review,
    pr_review_save_draft,
    pr_review_record_review,
    pr_review_advance,
    missions_invoke,
    missions_invoke_service,
    missions_create,
    missions_list,
    missions_get,
    missions_heartbeat,
    missions_checkpoint,
    missions_bootstrap_contract,
    missions_recover,
    missions_request_approval,
    missions_approve,
    missions_reject,
    missions_resume,
    missions_block,
    missions_complete,
    missions_fail,
    missions_cancel,
    mounts_invoke,
    mounts_list,
    mounts_mount,
    mounts_mkdir,
    mounts_unmount,
    mounts_bind,
    mounts_unbind,
    mounts_resolve,
    event_wait_config,
    event_signal,
    event_next,
    pairing_refresh,
    pairing_approve,
    pairing_deny,
    pairing_invites_refresh,
    pairing_invites_create,
    terminal_v2_invoke,
    terminal_v2_create,
    terminal_v2_resume,
    terminal_v2_close,
    terminal_v2_exec,
    terminal_v2_write,
    terminal_v2_read,
    terminal_v2_resize,
};

const default_wait_timeout_ms: i64 = events_venom.default_wait_timeout_ms;
const wait_poll_interval_ms: u64 = events_venom.wait_poll_interval_ms;
const debug_stream_log_max_bytes: usize = 2 * 1024 * 1024;
const max_signal_events: usize = events_venom.max_signal_events;
const local_fs_world_prefix = "/nodes/local/fs";
const workspace_entrypoint_relative_namespace_root = "../../..";
const workspace_managed_root_name = ".spiderweb";
const workspace_managed_root_relative = "./.spiderweb";
const workspace_managed_root_absolute = local_fs_world_prefix ++ "/" ++ workspace_managed_root_name;
const workspace_managed_shared_data_dir_name = "shared_data";
const workspace_managed_services_dir_name = "services";
const workspace_managed_local_venoms_dir_name = "local_venoms";
const workspace_managed_services_absolute_prefix = workspace_managed_root_absolute ++ "/" ++ workspace_managed_services_dir_name ++ "/";
const workspace_agents_contract_path = "/nodes/local/fs/AGENTS.md";
const namespace_agents_contract_path = "/AGENTS.md";
const workspace_agents_heading = "# Spiderweb Workspace Agent Contract";
const workspace_agents_managed_begin = "<!-- SPIDERWEB:BEGIN MANAGED -->";
const workspace_agents_managed_end = "<!-- SPIDERWEB:END MANAGED -->";
const worker_reap_grace_ms: i64 = 60_000;
const acheron_protocol_json =
    "{\"channel\":\"acheron\",\"version\":\"acheron-1\",\"layout\":\"acheron-namespace-project-contract-v2\",\"ops\":[\"t_version\",\"t_attach\",\"t_walk\",\"t_open\",\"t_read\",\"t_write\",\"t_stat\",\"t_clunk\",\"t_flush\"]}";

const BootstrapRequiredService = struct {
    id: []const u8,
    ensure_path: ?[]const u8 = null,
    invoke_path: ?[]const u8 = null,
};

const bootstrap_required_services = [_]BootstrapRequiredService{
    .{ .id = "home", .ensure_path = "/services/home/control/ensure.json", .invoke_path = "/services/home/control/invoke.json" },
    .{ .id = "mounts", .invoke_path = "/services/mounts/control/bind.json" },
    .{ .id = "workers", .invoke_path = "/services/workers/control/register.json" },
    .{ .id = "terminal", .invoke_path = "/services/terminal/control/invoke.json" },
    .{ .id = "git", .invoke_path = "/services/git/control/invoke.json" },
    .{ .id = "search_code", .invoke_path = "/services/search_code/control/invoke.json" },
    .{ .id = "library" },
    .{ .id = "events" },
};

const WaitSourceKind = events_venom.WaitSourceKind;
const WaitSource = events_venom.WaitSource;
const SignalEventType = events_venom.SignalEventType;
const SignalEvent = events_venom.SignalEvent;
const WaitCandidate = events_venom.WaitCandidate;

const WriteOutcome = struct {
    written: usize,
};

const BoundVenomProxyPath = struct {
    venom_id: []const u8,
    remote_path: []const u8,
    project_id: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
    provider_node_id: ?[]const u8 = null,
    provider_export_name: ?[]const u8 = null,
};

const BoundVenomProxyAttrSummary = struct {
    kind: NodeKind,
    writable: bool,
    mode: ?u32 = null,
    size: ?u64 = null,
};

const PathBindKind = enum {
    workspace,
    workspace_mount,
    managed_entrypoint,
};

const PathBind = struct {
    kind: PathBindKind = .workspace,
    bind_path: []u8,
    target_path: []u8,

    fn deinit(self: *PathBind, allocator: std.mem.Allocator) void {
        allocator.free(self.bind_path);
        allocator.free(self.target_path);
        self.* = undefined;
    }
};

const ScopedVenomBinding = struct {
    venom_id: []u8,
    scope: []u8,
    venom_path: []u8,
    provider_node_id: ?[]u8 = null,
    provider_venom_path: ?[]u8 = null,
    endpoint_path: ?[]u8 = null,
    invoke_path: ?[]u8 = null,

    fn deinit(self: *ScopedVenomBinding, allocator: std.mem.Allocator) void {
        allocator.free(self.venom_id);
        allocator.free(self.scope);
        allocator.free(self.venom_path);
        if (self.provider_node_id) |value| allocator.free(value);
        if (self.provider_venom_path) |value| allocator.free(value);
        if (self.endpoint_path) |value| allocator.free(value);
        if (self.invoke_path) |value| allocator.free(value);
        self.* = undefined;
    }
};

const PairingAction = pairing_venom.Action;

const TerminalSession = terminal_venom.SessionState;

const Node = struct {
    id: u32,
    parent: ?u32,
    kind: NodeKind,
    name: []u8,
    writable: bool,
    content: []u8,
    reported_mode: ?u32 = null,
    reported_size: ?u64 = null,
    last_dynamic_refresh_ms: i64 = 0,
    dynamic_refresh_in_progress: bool = false,
    children: std.StringHashMapUnmanaged(u32) = .{},
    special: SpecialKind = .none,

    fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.content);
        self.children.deinit(allocator);
        self.* = undefined;
    }
};

const slow_dynamic_directory_refresh_warn_ms: u64 = 100;

const FidState = struct {
    node_id: u32,
    is_open: bool = false,
    mode: []const u8 = "r",
    pending_special_write: ?[]u8 = null,

    fn deinit(self: *FidState, allocator: std.mem.Allocator) void {
        if (self.pending_special_write) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const ToolPayloadErrorInfo = struct {
    code: []u8,
    message: []u8,

    pub fn deinit(self: ToolPayloadErrorInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.message);
    }
};

pub const AgentRunSuccessInfo = struct {
    run_id: []u8,
    state: []u8,
    assistant_output: ?[]u8 = null,
    step_count: u64 = 0,
    checkpoint_seq: u64 = 0,

    pub fn deinit(self: *AgentRunSuccessInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
        allocator.free(self.state);
        if (self.assistant_output) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const AgentRunOutcome = union(enum) {
    success: AgentRunSuccessInfo,
    failure: ToolPayloadErrorInfo,

    pub fn deinit(self: *AgentRunOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .success => |*value| value.deinit(allocator),
            .failure => |value| value.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const InternalFsrpcErrorInfo = struct {
    code: []u8,
    message: []u8,

    pub fn deinit(self: InternalFsrpcErrorInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.message);
    }
};

const MountGraphSourceRecord = struct {
    id: []u8,
    mount_path: []u8,
    fs_url: []u8,
    export_name: ?[]u8 = null,
    writable: bool = false,

    fn deinit(self: *MountGraphSourceRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.mount_path);
        allocator.free(self.fs_url);
        if (self.export_name) |value| allocator.free(value);
        self.* = undefined;
    }
};

const WorkspaceMountProxyRoot = struct {
    node_id: []u8,
    export_name: ?[]u8 = null,

    fn deinit(self: *WorkspaceMountProxyRoot, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
        if (self.export_name) |value| allocator.free(value);
        self.* = undefined;
    }
};

const BoundVenomRouteMode = enum {
    client_visible,
    server_internal,
};

const MountGraphNodeRecord = struct {
    id: u64,
    parent_id: ?u64,
    name: []u8,
    path: []u8,
    kind: []const u8,
    mode: u32,
    writable: bool,
    size: usize,
    canonical_node_id: ?u64 = null,
    content_mode: ?[]const u8 = null,
    inline_content_b64: ?[]u8 = null,
    source_id: ?[]const u8 = null,

    fn deinit(self: *MountGraphNodeRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        if (self.inline_content_b64) |value| allocator.free(value);
        self.* = undefined;
    }
};

const InternalFsrpcIds = struct {
    attach_fid: u32,
    walk_fid: u32,
    tag_base: u32,
};

const WorkerPresence = struct {
    agent_id: []u8,
    last_seen_ms: i64,
    expires_at_ms: i64,

    fn deinit(self: *WorkerPresence, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_id);
        self.* = undefined;
    }
};

const LocalFsLockEntry = struct {
    file: std.fs.File,

    fn deinit(self: *LocalFsLockEntry) void {
        self.file.close();
        self.* = undefined;
    }
};

fn deinitResponseFrames(allocator: std.mem.Allocator, frames: [][]u8) void {
    for (frames) |frame| allocator.free(frame);
    allocator.free(frames);
}

fn pathExistsAbsolute(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn ensureAbsoluteDirectoryExists(dir_path: []const u8) !void {
    if (!std.fs.path.isAbsolute(dir_path)) return error.InvalidPath;
    var root_dir = try std.fs.openDirAbsolute("/", .{});
    defer root_dir.close();
    const rel_dir = std.mem.trimLeft(u8, dir_path, "/");
    if (rel_dir.len == 0) return;
    root_dir.makePath(rel_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

fn deleteAbsoluteTreeIfPresent(dir_path: []const u8) !void {
    if (!std.fs.path.isAbsolute(dir_path)) return error.InvalidPath;
    var root_dir = try std.fs.openDirAbsolute("/", .{});
    defer root_dir.close();
    const rel_dir = std.mem.trimLeft(u8, dir_path, "/");
    if (rel_dir.len == 0) return;
    root_dir.deleteTree(rel_dir) catch return;
}

fn sanitizePathComponent(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len == 0) return allocator.dupe(u8, "unknown");
    var out = try allocator.alloc(u8, raw.len);
    for (raw, 0..) |char, idx| {
        out[idx] = if (std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.')
            char
        else
            '_';
    }
    return out;
}

fn appendExistingBindArg(
    allocator: std.mem.Allocator,
    argv: *std.ArrayListUnmanaged([]const u8),
    flag: []const u8,
    source: []const u8,
    target: []const u8,
) !void {
    if (!pathExistsAbsolute(source)) return;
    try argv.append(allocator, flag);
    try argv.append(allocator, source);
    try argv.append(allocator, target);
}

pub const Session = struct {
    pub const NamespaceOptions = struct {
        project_id: ?[]const u8 = null,
        project_token: ?[]const u8 = null,
        namespace_mount_url: ?[]const u8 = null,
        namespace_session_key: ?[]const u8 = null,
        agents_dir: []const u8 = "agents",
        assets_dir: []const u8 = "templates",
        projects_dir: []const u8 = "projects",
        local_fs_export_root: ?[]const u8 = null,
        sandbox_mounts_root: ?[]const u8 = null,
        sandbox_launcher: ?[]const u8 = null,
        sandbox_fs_mount_bin: ?[]const u8 = null,
        control_plane: ?*control_plane_mod.ControlPlane = null,
        mission_store: ?*mission_store_mod.MissionStore = null,
        namespace_auth_token: ?[]const u8 = null,
        control_operator_token: ?[]const u8 = null,
        actor_type: ?[]const u8 = null,
        actor_id: ?[]const u8 = null,
        is_admin: bool = false,
    };

    allocator: std.mem.Allocator,
    runtime_handle: *runtime_handle_mod.RuntimeHandle,
    agent_id: []u8,
    actor_type: []u8,
    actor_id: []u8,
    project_id: ?[]u8 = null,
    active_namespace_project_id: ?[]u8 = null,
    project_token: ?[]u8 = null,
    namespace_mount_url: ?[]u8 = null,
    namespace_session_key: ?[]u8 = null,
    agents_dir: []u8,
    assets_dir: []u8,
    projects_dir: []u8,
    local_fs_export_root: ?[]u8 = null,
    sandbox_mounts_root: ?[]u8 = null,
    sandbox_launcher: ?[]u8 = null,
    sandbox_fs_mount_bin: ?[]u8 = null,
    control_plane: ?*control_plane_mod.ControlPlane = null,
    mission_store: ?*mission_store_mod.MissionStore = null,
    namespace_auth_token: ?[]u8 = null,
    control_operator_token: ?[]u8 = null,
    is_admin: bool = false,

    nodes: std.AutoHashMapUnmanaged(u32, Node) = .{},
    fids: std.AutoHashMapUnmanaged(u32, FidState) = .{},
    next_node_id: u32 = 1,
    next_internal_fsrpc_seq: u32 = 1,

    root_id: u32 = 0,
    nodes_root_id: u32 = 0,
    agent_venoms_index_id: u32 = 0,
    active_agent_venoms_index_id: u32 = 0,
    active_project_venoms_index_id: u32 = 0,
    node_venom_events_log_id: u32 = 0,
    event_next_id: u32 = 0,
    pairing_pending_id: u32 = 0,
    pairing_last_result_id: u32 = 0,
    pairing_last_error_id: u32 = 0,
    pairing_invites_active_id: u32 = 0,
    pairing_invites_last_result_id: u32 = 0,
    pairing_invites_last_error_id: u32 = 0,
    terminal_status_id: u32 = 0,
    terminal_result_id: u32 = 0,
    terminal_sessions_id: u32 = 0,
    terminal_current_id: u32 = 0,
    sub_brains_status_id: u32 = 0,
    sub_brains_result_id: u32 = 0,
    agents_status_id: u32 = 0,
    agents_result_id: u32 = 0,
    projects_status_id: u32 = 0,
    projects_result_id: u32 = 0,
    git_status_id: u32 = 0,
    git_result_id: u32 = 0,
    git_status_alias_id: u32 = 0,
    git_result_alias_id: u32 = 0,
    github_pr_status_id: u32 = 0,
    github_pr_result_id: u32 = 0,
    github_pr_status_alias_id: u32 = 0,
    github_pr_result_alias_id: u32 = 0,
    pr_review_status_id: u32 = 0,
    pr_review_result_id: u32 = 0,
    pr_review_status_alias_id: u32 = 0,
    pr_review_result_alias_id: u32 = 0,
    missions_status_id: u32 = 0,
    missions_result_id: u32 = 0,
    missions_status_alias_id: u32 = 0,
    missions_result_alias_id: u32 = 0,
    mounts_status_id: u32 = 0,
    mounts_result_id: u32 = 0,
    mounts_status_alias_id: u32 = 0,
    mounts_result_alias_id: u32 = 0,
    home_status_id: u32 = 0,
    home_result_id: u32 = 0,
    home_status_alias_id: u32 = 0,
    home_result_alias_id: u32 = 0,
    workers_status_id: u32 = 0,
    workers_result_id: u32 = 0,
    workers_status_alias_id: u32 = 0,
    workers_result_alias_id: u32 = 0,
    venom_packages_status_id: u32 = 0,
    venom_packages_result_id: u32 = 0,
    venom_packages_status_alias_id: u32 = 0,
    venom_packages_result_alias_id: u32 = 0,
    wait_sources: std.ArrayListUnmanaged(WaitSource) = .{},
    wait_timeout_ms: i64 = default_wait_timeout_ms,
    wait_event_seq: u64 = 1,
    signal_events: std.ArrayListUnmanaged(SignalEvent) = .{},
    next_signal_seq: u64 = 1,
    terminal_sessions: std.StringHashMapUnmanaged(TerminalSession) = .{},
    current_terminal_session_id: ?[]u8 = null,
    next_terminal_session_seq: u64 = 1,
    worker_presence: std.StringHashMapUnmanaged(WorkerPresence) = .{},
    local_fs_lock_files: std.StringHashMapUnmanaged(LocalFsLockEntry) = .{},
    project_binds: std.ArrayListUnmanaged(PathBind) = .{},
    scoped_venom_bindings: std.ArrayListUnmanaged(ScopedVenomBinding) = .{},
    node_aliases: std.AutoHashMapUnmanaged(u32, u32) = .{},
    workspace_mount_fs_auth_tokens: std.StringHashMapUnmanaged([]u8) = .{},
    workspace_mount_fs_urls: std.StringHashMapUnmanaged([]u8) = .{},
    workspace_mount_proxy_roots: std.StringHashMapUnmanaged(WorkspaceMountProxyRoot) = .{},
    namespace_mount_dir: ?[]u8 = null,
    namespace_mount_point: ?[]u8 = null,
    namespace_mount_child: ?std.process.Child = null,
    namespace_mount_ready: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        runtime_handle: *runtime_handle_mod.RuntimeHandle,
        agent_id: []const u8,
    ) !Session {
        return initWithOptions(allocator, runtime_handle, agent_id, .{});
    }

    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        runtime_handle: *runtime_handle_mod.RuntimeHandle,
        agent_id: []const u8,
        options: NamespaceOptions,
    ) !Session {
        const owned_agent = try allocator.dupe(u8, agent_id);
        errdefer allocator.free(owned_agent);
        const owned_project = if (options.project_id) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_project) |value| allocator.free(value);
        const owned_project_token = if (options.project_token) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_project_token) |value| allocator.free(value);
        const owned_namespace_mount_url = if (options.namespace_mount_url) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_namespace_mount_url) |value| allocator.free(value);
        const owned_namespace_session_key = if (options.namespace_session_key) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_namespace_session_key) |value| allocator.free(value);
        const actor_type_value = options.actor_type orelse "agent";
        const owned_actor_type = try allocator.dupe(u8, actor_type_value);
        errdefer allocator.free(owned_actor_type);
        const actor_id_value = options.actor_id orelse agent_id;
        const owned_actor_id = try allocator.dupe(u8, actor_id_value);
        errdefer allocator.free(owned_actor_id);
        const owned_agents_dir = try allocator.dupe(u8, options.agents_dir);
        errdefer allocator.free(owned_agents_dir);
        const owned_assets_dir = try allocator.dupe(u8, options.assets_dir);
        errdefer allocator.free(owned_assets_dir);
        const owned_projects_dir = try allocator.dupe(u8, options.projects_dir);
        errdefer allocator.free(owned_projects_dir);
        const owned_local_fs_export_root = if (options.local_fs_export_root) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_local_fs_export_root) |value| allocator.free(value);
        const owned_sandbox_mounts_root = if (options.sandbox_mounts_root) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_sandbox_mounts_root) |value| allocator.free(value);
        const owned_sandbox_launcher = if (options.sandbox_launcher) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_sandbox_launcher) |value| allocator.free(value);
        const owned_sandbox_fs_mount_bin = if (options.sandbox_fs_mount_bin) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_sandbox_fs_mount_bin) |value| allocator.free(value);
        const owned_control_operator_token = if (options.control_operator_token) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_control_operator_token) |value| allocator.free(value);
        const owned_namespace_auth_token = if (options.namespace_auth_token) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_namespace_auth_token) |value| allocator.free(value);
        runtime_handle.retain();
        errdefer runtime_handle.release();

        var self = Session{
            .allocator = allocator,
            .runtime_handle = runtime_handle,
            .agent_id = owned_agent,
            .actor_type = owned_actor_type,
            .actor_id = owned_actor_id,
            .project_id = owned_project,
            .project_token = owned_project_token,
            .namespace_mount_url = owned_namespace_mount_url,
            .namespace_session_key = owned_namespace_session_key,
            .agents_dir = owned_agents_dir,
            .assets_dir = owned_assets_dir,
            .projects_dir = owned_projects_dir,
            .local_fs_export_root = owned_local_fs_export_root,
            .sandbox_mounts_root = owned_sandbox_mounts_root,
            .sandbox_launcher = owned_sandbox_launcher,
            .sandbox_fs_mount_bin = owned_sandbox_fs_mount_bin,
            .control_plane = options.control_plane,
            .mission_store = options.mission_store,
            .namespace_auth_token = owned_namespace_auth_token,
            .control_operator_token = owned_control_operator_token,
            .is_admin = options.is_admin,
        };
        try self.seedNamespace();
        return self;
    }

    pub fn deinit(self: *Session) void {
        self.clearWaitSources();
        self.clearSignalEvents();
        self.clearTerminalSessions();
        self.clearProjectBinds();
        self.clearScopedVenomBindings();
        self.clearWorkerPresence();
        self.clearLocalFsLockFiles();
        self.node_aliases.deinit(self.allocator);
        self.clearWorkspaceMountFsAuthTokens();
        self.clearWorkspaceMountFsUrls();
        self.clearWorkspaceMountProxyRoots();
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            var node = entry.value_ptr.*;
            node.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        var fid_it = self.fids.iterator();
        while (fid_it.next()) |entry| {
            var state = entry.value_ptr.*;
            state.deinit(self.allocator);
        }
        self.fids.deinit(self.allocator);
        self.allocator.free(self.agent_id);
        self.allocator.free(self.actor_type);
        self.allocator.free(self.actor_id);
        if (self.project_id) |value| self.allocator.free(value);
        if (self.active_namespace_project_id) |value| self.allocator.free(value);
        if (self.project_token) |value| self.allocator.free(value);
        if (self.namespace_mount_url) |value| self.allocator.free(value);
        if (self.namespace_session_key) |value| self.allocator.free(value);
        self.allocator.free(self.agents_dir);
        self.allocator.free(self.assets_dir);
        self.allocator.free(self.projects_dir);
        if (self.local_fs_export_root) |value| self.allocator.free(value);
        self.cleanupNamespaceMount();
        if (self.sandbox_mounts_root) |value| self.allocator.free(value);
        if (self.sandbox_launcher) |value| self.allocator.free(value);
        if (self.sandbox_fs_mount_bin) |value| self.allocator.free(value);
        if (self.namespace_auth_token) |value| self.allocator.free(value);
        if (self.control_operator_token) |value| self.allocator.free(value);
        self.runtime_handle.release();
        self.* = undefined;
    }

    pub fn terminalNamespaceMode(self: *const Session) []const u8 {
        return if (self.canUseNamespaceShellExec()) "attached-live" else "runtime-local";
    }

    pub fn terminalPathModel(self: *const Session) []const u8 {
        return if (self.canUseNamespaceShellExec()) "shared-absolute" else "localfs-only";
    }

    pub fn terminalSupportsInteractiveSessions(self: *const Session) bool {
        _ = self;
        return builtin.os.tag == .linux;
    }

    fn canUseNamespaceShellExec(self: *const Session) bool {
        return self.terminalSupportsInteractiveSessions() and
            self.project_id != null and
            self.namespace_mount_url != null and
            self.namespace_session_key != null and
            self.sandbox_mounts_root != null and
            self.sandbox_launcher != null and
            self.sandbox_fs_mount_bin != null;
    }

    fn buildUnsupportedInteractiveTerminalError(self: *Session, tag: u16) ![]u8 {
        return unified.buildFsrpcError(
            self.allocator,
            tag,
            "unsupported",
            "interactive terminal sessions are currently supported on Linux only",
        );
    }

    fn cleanupNamespaceMount(self: *Session) void {
        if (self.namespace_mount_child) |*child| {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
        }
        self.namespace_mount_child = null;

        if (self.namespace_mount_dir) |dir_path| {
            deleteAbsoluteTreeIfPresent(dir_path) catch {};
            self.allocator.free(dir_path);
            self.namespace_mount_dir = null;
        }
        if (self.namespace_mount_point) |mount_point| {
            self.allocator.free(mount_point);
            self.namespace_mount_point = null;
        }
        self.namespace_mount_ready = false;
    }

    fn clearWorkerPresence(self: *Session) void {
        var it = self.worker_presence.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var presence = entry.value_ptr.*;
            presence.deinit(self.allocator);
        }
        self.worker_presence.deinit(self.allocator);
        self.worker_presence = .{};
    }

    fn clearLocalFsLockFiles(self: *Session) void {
        var it = self.local_fs_lock_files.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var lock_entry = entry.value_ptr.*;
            lock_entry.deinit();
        }
        self.local_fs_lock_files.deinit(self.allocator);
        self.local_fs_lock_files = .{};
    }

    pub fn setRuntimeBinding(
        self: *Session,
        runtime_handle: *runtime_handle_mod.RuntimeHandle,
        agent_id: []const u8,
    ) anyerror!void {
        try self.setRuntimeBindingWithOptions(
            runtime_handle,
            agent_id,
            .{
                .project_id = self.project_id,
                .project_token = self.project_token,
                .namespace_mount_url = self.namespace_mount_url,
                .namespace_session_key = self.namespace_session_key,
                .agents_dir = self.agents_dir,
                .assets_dir = self.assets_dir,
                .projects_dir = self.projects_dir,
                .local_fs_export_root = self.local_fs_export_root,
                .sandbox_mounts_root = self.sandbox_mounts_root,
                .sandbox_launcher = self.sandbox_launcher,
                .sandbox_fs_mount_bin = self.sandbox_fs_mount_bin,
                .control_plane = self.control_plane,
                .mission_store = self.mission_store,
                .namespace_auth_token = self.namespace_auth_token,
                .control_operator_token = self.control_operator_token,
                .actor_type = self.actor_type,
                .actor_id = self.actor_id,
                .is_admin = self.is_admin,
            },
        );
    }

    pub fn setRuntimeBindingWithOptions(
        self: *Session,
        runtime_handle: *runtime_handle_mod.RuntimeHandle,
        agent_id: []const u8,
        options: NamespaceOptions,
    ) anyerror!void {
        const rebound = try Session.initWithOptions(self.allocator, runtime_handle, agent_id, options);

        var previous = self.*;
        self.* = rebound;
        previous.deinit();
    }

    fn shouldEmitRuntimeDebugFrames(self: *const Session) bool {
        _ = self;
        return false;
    }

    fn recordRuntimeFrameForDebug(self: *Session, request_id: []const u8, frame: []const u8) !void {
        _ = self;
        _ = request_id;
        _ = frame;
    }

    fn syncNodeVenomEventsLogFromControlPlane(self: *Session) !void {
        if (self.node_venom_events_log_id == 0) return;
        const plane = self.control_plane orelse return;
        const snapshot = try plane.snapshotNodeVenomEvents(
            self.allocator,
            self.project_id,
            self.agent_id,
            self.project_token,
            self.is_admin,
            0,
        );
        defer self.allocator.free(snapshot);
        try self.setFileContent(self.node_venom_events_log_id, snapshot);
    }

    pub fn handle(self: *Session, msg: *const unified.ParsedMessage) ![]u8 {
        const msg_type = msg.acheron_type orelse {
            return unified.buildFsrpcError(self.allocator, msg.tag, "invalid_type", "missing acheron message type");
        };

        return switch (msg_type) {
            .t_version => self.handleVersion(msg),
            .t_attach => self.handleAttach(msg),
            .t_walk => self.handleWalk(msg),
            .t_open => self.handleOpen(msg),
            .t_read => self.handleRead(msg),
            .t_write => self.handleWrite(msg),
            .t_stat => self.handleStat(msg),
            .t_clunk => self.handleClunk(msg),
            .t_flush => self.handleFlush(msg),
            else => unified.buildFsrpcError(self.allocator, msg.tag, "unsupported", "unsupported acheron operation"),
        };
    }

    fn handleVersion(self: *Session, msg: *const unified.ParsedMessage) ![]u8 {
        const msize = msg.msize orelse 1_048_576;
        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"msize\":{d},\"version\":\"acheron-1\"}}",
            .{msize},
        );
        defer self.allocator.free(payload);
        return unified.buildFsrpcResponse(self.allocator, .r_version, msg.tag, payload);
    }

    fn handleAttach(self: *Session, msg: *const unified.ParsedMessage) ![]u8 {
        const fid = msg.fid orelse return unified.buildFsrpcError(self.allocator, msg.tag, "invalid", "fid is required");
        try self.fids.put(self.allocator, fid, .{ .node_id = self.root_id });

        const escaped_project_id = if (self.project_id) |project_id|
            try unified.jsonEscape(self.allocator, project_id)
        else
            null;
        defer if (escaped_project_id) |value| self.allocator.free(value);
        const project_id_json = if (escaped_project_id) |value|
            try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{value})
        else
            try self.allocator.dupe(u8, "null");
        defer self.allocator.free(project_id_json);
        const debug_visible = self.lookupChild(self.root_id, "debug") != null;
        const services_visible = self.lookupChild(self.root_id, "services") != null;
        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"qid\":{{\"path\":{d},\"type\":\"dir\"}},\"layout\":\"spiderweb-fs\",\"project_id\":{s},\"roots\":[\"nodes\",\"agents\",\"global\"{s}{s}],\"dynamic_bind_paths\":{s},\"bind_count\":{d}}}",
            .{
                self.root_id,
                project_id_json,
                if (services_visible) ",\"services\"" else "",
                if (debug_visible) ",\"debug\"" else "",
                if (self.project_binds.items.len > 0) "true" else "false",
                self.project_binds.items.len,
            },
        );
        defer self.allocator.free(payload);
        return unified.buildFsrpcResponse(self.allocator, .r_attach, msg.tag, payload);
    }

    fn handleWalk(self: *Session, msg: *const unified.ParsedMessage) ![]u8 {
        const fid = msg.fid orelse return unified.buildFsrpcError(self.allocator, msg.tag, "invalid", "fid is required");
        const newfid = msg.newfid orelse return unified.buildFsrpcError(self.allocator, msg.tag, "invalid", "newfid is required");

        const start = self.fids.get(fid) orelse return unified.buildFsrpcError(self.allocator, msg.tag, "enoent", "unknown fid");
        var node_id = start.node_id;

        for (msg.path) |segment| {
            if (std.mem.eql(u8, segment, ".")) continue;
            if (std.mem.eql(u8, segment, "..")) {
                if (self.nodes.get(node_id)) |current| {
                    if (current.parent) |parent_id| node_id = parent_id;
                }
                continue;
            }

            self.refreshDynamicDirectory(node_id) catch |err| {
                std.log.warn("dynamic directory refresh failed during walk: {s}", .{@errorName(err)});
            };
            const next = (try self.resolveWalkChild(node_id, segment)) orelse {
                return unified.buildFsrpcError(self.allocator, msg.tag, "enoent", "walk segment not found");
            };
            node_id = next;
        }

        try self.fids.put(self.allocator, newfid, .{ .node_id = node_id });
        const node = self.nodes.get(node_id) orelse return unified.buildFsrpcError(self.allocator, msg.tag, "eio", "missing node");

        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"qid\":{{\"path\":{d},\"type\":\"{s}\"}},\"walked\":{d}}}",
            .{ node_id, kindName(node.kind), msg.path.len },
        );
        defer self.allocator.free(payload);
        return unified.buildFsrpcResponse(self.allocator, .r_walk, msg.tag, payload);
    }

    fn handleOpen(self: *Session, msg: *const unified.ParsedMessage) ![]u8 {
        const fid = msg.fid orelse return unified.buildFsrpcError(self.allocator, msg.tag, "invalid", "fid is required");

        var state = self.fids.get(fid) orelse return unified.buildFsrpcError(self.allocator, msg.tag, "enoent", "unknown fid");
        const node = self.nodes.get(state.node_id) orelse return unified.buildFsrpcError(self.allocator, msg.tag, "eio", "missing node");

        const mode = msg.mode orelse "r";
        const wants_write = std.mem.indexOfScalar(u8, mode, 'w') != null;
        if (node.kind == .dir and wants_write) {
            return unified.buildFsrpcError(self.allocator, msg.tag, "eisdir", "directories are read-only opens");
        }
        if (node.kind == .file and wants_write and !node.writable) {
            return unified.buildFsrpcError(self.allocator, msg.tag, "eperm", "file is read-only");
        }

        state.is_open = true;
        state.mode = mode;
        try self.fids.put(self.allocator, fid, state);

        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"qid\":{{\"path\":{d},\"type\":\"{s}\"}},\"iounit\":65536}}",
            .{ node.id, kindName(node.kind) },
        );
        defer self.allocator.free(payload);
        return unified.buildFsrpcResponse(self.allocator, .r_open, msg.tag, payload);
    }

    fn handleRead(self: *Session, msg: *const unified.ParsedMessage) ![]u8 {
        const fid = msg.fid orelse return unified.buildFsrpcError(self.allocator, msg.tag, "invalid", "fid is required");
        const offset = msg.offset orelse 0;
        const count = msg.count orelse 65536;

        const state = self.fids.get(fid) orelse return unified.buildFsrpcError(self.allocator, msg.tag, "enoent", "unknown fid");
        const node = self.nodes.get(state.node_id) orelse return unified.buildFsrpcError(self.allocator, msg.tag, "eio", "missing node");

        if (node.kind == .dir) {
            self.refreshDynamicDirectory(state.node_id) catch |err| {
                std.log.warn("dynamic directory refresh failed during read: {s}", .{@errorName(err)});
            };
        }

        var data_owned: ?[]u8 = null;
        defer if (data_owned) |value| self.allocator.free(value);

        const data = switch (node.kind) {
            .dir => blk: {
                data_owned = try self.renderDirListing(state.node_id);
                break :blk data_owned.?;
            },
            .file => blk: {
                var used_bound_proxy = false;
                if (try self.tryReadBoundVenomProxyFile(state.node_id)) |proxied| {
                    defer self.allocator.free(proxied);
                    try self.setFileContent(state.node_id, proxied);
                    used_bound_proxy = true;
                }
                if (offset == 0 and !used_bound_proxy) {
                    _ = try self.syncLocalFsFileNode(state.node_id);
                    switch (node.special) {
                        .agent_venoms_index => {
                            try self.refreshScopedVenomIndexes();
                        },
                        .node_venom_events_log => {
                            try self.syncNodeVenomEventsLogFromControlPlane();
                        },
                        .event_next => {
                            data_owned = try self.handleEventNextRead();
                            try self.setFileContent(state.node_id, data_owned.?);
                        },
                        else => {},
                    }
                }
                const refreshed = self.nodes.get(state.node_id) orelse {
                    return unified.buildFsrpcError(self.allocator, msg.tag, "eio", "missing node");
                };
                break :blk refreshed.content;
            },
        };

        const start = std.math.cast(usize, offset) orelse {
            return unified.buildFsrpcError(self.allocator, msg.tag, "invalid", "read offset is out of range");
        };

        if (start >= data.len) {
            const payload = "{\"data_b64\":\"\",\"n\":0,\"eof\":true}";
            return unified.buildFsrpcResponse(self.allocator, .r_read, msg.tag, payload);
        }

        const requested_end = std.math.add(usize, start, @as(usize, count)) catch std.math.maxInt(usize);
        const end = @min(data.len, requested_end);
        const chunk = data[start..end];
        const encoded = try unified.encodeDataB64(self.allocator, chunk);
        defer self.allocator.free(encoded);

        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"data_b64\":\"{s}\",\"n\":{d},\"eof\":{s}}}",
            .{ encoded, chunk.len, if (end >= data.len) "true" else "false" },
        );
        defer self.allocator.free(payload);
        return unified.buildFsrpcResponse(self.allocator, .r_read, msg.tag, payload);
    }

    fn refreshDynamicDirectory(self: *Session, dir_id: u32) !void {
        const now_ms = std.time.milliTimestamp();
        const previous_refresh_ms = blk: {
            const node = self.nodes.getPtr(dir_id) orelse return;
            if (node.kind != .dir) return;
            if (node.dynamic_refresh_in_progress) return;
            const previous = node.last_dynamic_refresh_ms;
            node.last_dynamic_refresh_ms = now_ms;
            node.dynamic_refresh_in_progress = true;
            break :blk previous;
        };
        defer {
            if (self.nodes.getPtr(dir_id)) |node| {
                node.dynamic_refresh_in_progress = false;
            }
        }
        errdefer {
            if (self.nodes.getPtr(dir_id)) |node| {
                node.last_dynamic_refresh_ms = previous_refresh_ms;
            }
        }
        var timer = try std.time.Timer.start();

        try self.reapExpiredWorkerNodes();
        try self.refreshWorkerPresenceStatuses();
        if (dir_id == self.nodes_root_id) {
            try self.addNodeDirectoriesFromControlPlane(self.nodes_root_id);
        }
        try self.refreshLocalFsDirectory(dir_id);
        try self.refreshBoundVenomProxyDirectory(dir_id);

        const elapsed_ms = timer.read() / std.time.ns_per_ms;
        if (elapsed_ms >= slow_dynamic_directory_refresh_warn_ms) {
            const absolute_path = try self.nodeAbsolutePath(dir_id);
            defer self.allocator.free(absolute_path);
            std.log.warn("slow dynamic directory refresh: {d}ms path={s}", .{ elapsed_ms, absolute_path });
        }
    }

    fn refreshLocalFsDirectory(self: *Session, dir_id: u32) !void {
        const host_path = (try self.localFsNodeHostPath(dir_id)) orelse return;
        defer self.allocator.free(host_path);

        var host_dir = if (std.fs.path.isAbsolute(host_path))
            std.fs.openDirAbsolute(host_path, .{ .iterate = true }) catch return
        else
            std.fs.cwd().openDir(host_path, .{ .iterate = true }) catch return;
        defer host_dir.close();

        var iterator = host_dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.name.len == 0) continue;
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
            if (self.lookupChild(dir_id, entry.name) != null) continue;

            switch (entry.kind) {
                .directory => _ = try self.addDir(dir_id, entry.name, false),
                .file, .sym_link, .unknown => _ = try self.addFile(dir_id, entry.name, "", true, .none),
                else => {},
            }
        }
    }

    fn localFsNodeHostPath(self: *Session, node_id: u32) !?[]u8 {
        if (self.local_fs_export_root == null) return null;
        const absolute_path = try self.nodeAbsolutePath(node_id);
        defer self.allocator.free(absolute_path);
        if (!pathMatchesPrefixBoundary(absolute_path, local_fs_world_prefix)) return null;
        return try self.resolveMissionContractHostPath(absolute_path);
    }

    fn resolveLocalFsSafeHostPath(self: *Session, host_path: []const u8) !?[]u8 {
        const export_root = self.local_fs_export_root orelse return null;
        const resolved_root = if (std.fs.path.isAbsolute(export_root))
            std.fs.realpathAlloc(self.allocator, export_root) catch return null
        else
            std.fs.cwd().realpathAlloc(self.allocator, export_root) catch return null;
        defer self.allocator.free(resolved_root);

        const resolved_host = if (std.fs.path.isAbsolute(host_path))
            std.fs.realpathAlloc(self.allocator, host_path) catch return null
        else
            std.fs.cwd().realpathAlloc(self.allocator, host_path) catch return null;
        errdefer self.allocator.free(resolved_host);

        if (!hostPathMatchesPrefixBoundary(resolved_host, resolved_root)) return null;
        return resolved_host;
    }

    fn syncLocalFsFileNode(self: *Session, node_id: u32) !bool {
        const host_path = (try self.localFsNodeHostPath(node_id)) orelse return false;
        defer self.allocator.free(host_path);

        const safe_host_path = (try self.resolveLocalFsSafeHostPath(host_path)) orelse return false;
        defer self.allocator.free(safe_host_path);

        var file = if (std.fs.path.isAbsolute(safe_host_path))
            std.fs.openFileAbsolute(safe_host_path, .{}) catch return false
        else
            std.fs.cwd().openFile(safe_host_path, .{}) catch return false;
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);
        try self.setFileContent(node_id, content);
        return true;
    }

    fn specialWriteErrorResponse(
        self: *Session,
        raw_tag: ?u32,
        special: SpecialKind,
        err: anyerror,
    ) ![]u8 {
        const tag: u16 = @intCast(raw_tag orelse 0);
        return switch (special) {
            .terminal_v2_invoke => switch (err) {
                error.InvalidPayload => unified.buildFsrpcError(
                    self.allocator,
                    tag,
                    "invalid",
                    "terminal invoke payload must include op=create|resume|close|write|read|resize|exec or matching fields",
                ),
                error.TerminalSessionNotFound => unified.buildFsrpcError(self.allocator, tag, "enoent", "terminal session not found"),
                error.TerminalSessionClosed => unified.buildFsrpcError(self.allocator, tag, "eperm", "terminal session is closed"),
                error.UnsupportedPlatform => self.buildUnsupportedInteractiveTerminalError(tag),
                error.TerminalPtyUnavailable => unified.buildFsrpcError(self.allocator, tag, "unavailable", "pty backend unavailable: install util-linux script"),
                else => err,
            },
            .terminal_v2_create => switch (err) {
                error.InvalidPayload => unified.buildFsrpcError(self.allocator, tag, "invalid", "terminal create payload must be a JSON object with optional session_id/label/cwd"),
                error.UnsupportedPlatform => self.buildUnsupportedInteractiveTerminalError(tag),
                error.TerminalPtyUnavailable => unified.buildFsrpcError(self.allocator, tag, "unavailable", "pty backend unavailable: install util-linux script"),
                else => err,
            },
            .terminal_v2_resume => switch (err) {
                error.InvalidPayload => unified.buildFsrpcError(self.allocator, tag, "invalid", "terminal resume payload must include session_id"),
                error.TerminalSessionNotFound => unified.buildFsrpcError(self.allocator, tag, "enoent", "terminal session not found"),
                error.TerminalSessionClosed => unified.buildFsrpcError(self.allocator, tag, "eperm", "terminal session is closed"),
                error.UnsupportedPlatform => self.buildUnsupportedInteractiveTerminalError(tag),
                else => err,
            },
            .terminal_v2_close => switch (err) {
                error.InvalidPayload => unified.buildFsrpcError(self.allocator, tag, "invalid", "terminal close payload must include session_id when no current session exists"),
                error.TerminalSessionNotFound => unified.buildFsrpcError(self.allocator, tag, "enoent", "terminal session not found"),
                error.TerminalSessionClosed => unified.buildFsrpcError(self.allocator, tag, "eperm", "terminal session is closed"),
                error.UnsupportedPlatform => self.buildUnsupportedInteractiveTerminalError(tag),
                else => err,
            },
            .terminal_v2_exec => switch (err) {
                error.InvalidPayload => unified.buildFsrpcError(self.allocator, tag, "invalid", "terminal exec payload must include command or argv (optional session_id/cwd/timeout_ms)"),
                error.TerminalSessionNotFound => unified.buildFsrpcError(self.allocator, tag, "enoent", "terminal session not found"),
                error.TerminalSessionClosed => unified.buildFsrpcError(self.allocator, tag, "eperm", "terminal session is closed"),
                error.UnsupportedPlatform => self.buildUnsupportedInteractiveTerminalError(tag),
                error.TerminalPtyUnavailable => unified.buildFsrpcError(self.allocator, tag, "unavailable", "pty backend unavailable: install util-linux script"),
                else => err,
            },
            .terminal_v2_write => switch (err) {
                error.InvalidPayload => unified.buildFsrpcError(self.allocator, tag, "invalid", "terminal write payload must include input/command/data_b64 (optional session_id)"),
                error.TerminalSessionNotFound => unified.buildFsrpcError(self.allocator, tag, "enoent", "terminal session not found"),
                error.TerminalSessionClosed => unified.buildFsrpcError(self.allocator, tag, "eperm", "terminal session is closed"),
                error.UnsupportedPlatform => self.buildUnsupportedInteractiveTerminalError(tag),
                else => err,
            },
            .terminal_v2_read => switch (err) {
                error.InvalidPayload => unified.buildFsrpcError(self.allocator, tag, "invalid", "terminal read payload must be object with optional session_id/max_bytes/timeout_ms"),
                error.TerminalSessionNotFound => unified.buildFsrpcError(self.allocator, tag, "enoent", "terminal session not found"),
                error.TerminalSessionClosed => unified.buildFsrpcError(self.allocator, tag, "eperm", "terminal session is closed"),
                error.UnsupportedPlatform => self.buildUnsupportedInteractiveTerminalError(tag),
                else => err,
            },
            .terminal_v2_resize => switch (err) {
                error.InvalidPayload => unified.buildFsrpcError(self.allocator, tag, "invalid", "terminal resize payload must include cols and rows (optional session_id)"),
                error.TerminalSessionNotFound => unified.buildFsrpcError(self.allocator, tag, "enoent", "terminal session not found"),
                error.TerminalSessionClosed => unified.buildFsrpcError(self.allocator, tag, "eperm", "terminal session is closed"),
                error.UnsupportedPlatform => self.buildUnsupportedInteractiveTerminalError(tag),
                else => err,
            },
            else => err,
        };
    }

    fn executeNodeWrite(self: *Session, node_id: u32, special: SpecialKind, offset: u64, data: []const u8) !WriteOutcome {
        return switch (special) {
            .event_wait_config => self.handleEventWaitConfigWrite(node_id, data),
            .event_signal => self.handleEventSignalWrite(node_id, data),
            .mounts_invoke, .mounts_list, .mounts_mount, .mounts_mkdir, .mounts_unmount, .mounts_bind, .mounts_unbind, .mounts_resolve => self.handleMountsNamespaceWrite(special, node_id, data),
            .home_invoke, .home_ensure => self.handleHomeNamespaceWrite(special, node_id, data),
            .workers_invoke, .workers_register, .workers_heartbeat, .workers_detach => self.handleWorkersNamespaceWrite(special, node_id, data),
            .venom_packages_invoke, .venom_packages_list, .venom_packages_get, .venom_packages_install, .venom_packages_remove => self.handleVenomPackagesNamespaceWrite(special, node_id, data),
            .projects_invoke, .projects_list, .projects_get, .projects_up => self.handleWorkspacesNamespaceWrite(special, node_id, data),
            .git_invoke, .git_sync_checkout, .git_status, .git_diff_range => self.handleGitNamespaceWrite(special, node_id, data),
            .github_pr_invoke, .github_pr_sync, .github_pr_ingest_event, .github_pr_publish_review => self.handleGitHubPrNamespaceWrite(special, node_id, data),
            .pr_review_invoke, .pr_review_configure_repo, .pr_review_get_repo, .pr_review_list_repos, .pr_review_intake, .pr_review_start, .pr_review_sync, .pr_review_run_validation, .pr_review_record_validation, .pr_review_draft_review, .pr_review_save_draft, .pr_review_record_review, .pr_review_advance => self.handlePrReviewNamespaceWrite(special, node_id, data),
            .missions_invoke, .missions_invoke_service, .missions_create, .missions_list, .missions_get, .missions_heartbeat, .missions_checkpoint, .missions_bootstrap_contract, .missions_recover, .missions_request_approval, .missions_approve, .missions_reject, .missions_resume, .missions_block, .missions_complete, .missions_fail, .missions_cancel => self.handleMissionsNamespaceWrite(special, node_id, data),
            .pairing_refresh => self.handlePairingControlWrite(.refresh, data),
            .pairing_approve => self.handlePairingControlWrite(.approve, data),
            .pairing_deny => self.handlePairingControlWrite(.deny, data),
            .pairing_invites_refresh => self.handlePairingControlWrite(.invites_refresh, data),
            .pairing_invites_create => self.handlePairingControlWrite(.invites_create, data),
            .terminal_v2_invoke => self.handleTerminalV2InvokeWrite(node_id, data),
            .terminal_v2_create => self.handleTerminalV2CreateWrite(node_id, data),
            .terminal_v2_resume => self.handleTerminalV2ResumeWrite(node_id, data),
            .terminal_v2_close => self.handleTerminalV2CloseWrite(node_id, data),
            .terminal_v2_exec => self.handleTerminalV2ExecWrite(node_id, data),
            .terminal_v2_write => self.handleTerminalV2WriteWrite(node_id, data),
            .terminal_v2_read => self.handleTerminalV2ReadWrite(node_id, data),
            .terminal_v2_resize => self.handleTerminalV2ResizeWrite(node_id, data),
            .none, .agent_venoms_index, .node_venom_events_log, .event_next => blk: {
                try self.writeFileContent(node_id, offset, data);
                break :blk .{ .written = data.len };
            },
        };
    }

    fn handleWrite(self: *Session, msg: *const unified.ParsedMessage) ![]u8 {
        const fid = msg.fid orelse return unified.buildFsrpcError(self.allocator, msg.tag, "invalid", "fid is required");
        const data = msg.data orelse return unified.buildFsrpcError(self.allocator, msg.tag, "invalid", "write requires data");
        const offset = msg.offset orelse 0;

        var state = self.fids.get(fid) orelse return unified.buildFsrpcError(self.allocator, msg.tag, "enoent", "unknown fid");
        const node = self.nodes.get(state.node_id) orelse return unified.buildFsrpcError(self.allocator, msg.tag, "eio", "missing node");
        if (node.kind != .file) return unified.buildFsrpcError(self.allocator, msg.tag, "eisdir", "write requires file fid");
        if (!node.writable) return unified.buildFsrpcError(self.allocator, msg.tag, "eperm", "file is read-only");

        var written: usize = data.len;

        if (isTerminalV2Special(node.special) and !self.canInvokeTerminalNamespace(state.node_id)) {
            return unified.buildFsrpcError(self.allocator, msg.tag, "eperm", "terminal invoke access denied by permissions");
        }

        if (try self.tryWriteBoundVenomProxyFile(state.node_id, offset, data)) |proxied| {
            written = proxied.written;
        } else if (specialWriteCommitsOnClose(node.special)) {
            self.appendPendingSpecialWrite(&state, state.node_id, offset, data) catch |err| switch (err) {
                error.InvalidOffset => return unified.buildFsrpcError(self.allocator, msg.tag, "invalid", "write offset is out of range"),
                else => return err,
            };
            try self.fids.put(self.allocator, fid, state);
            written = data.len;
        } else {
            const outcome = self.executeNodeWrite(state.node_id, node.special, offset, data) catch |err| {
                return self.specialWriteErrorResponse(msg.tag, node.special, err);
            };
            written = outcome.written;
        }

        const payload = try std.fmt.allocPrint(self.allocator, "{{\"n\":{d}}}", .{written});
        defer self.allocator.free(payload);
        return unified.buildFsrpcResponse(self.allocator, .r_write, msg.tag, payload);
    }

    fn handleStat(self: *Session, msg: *const unified.ParsedMessage) ![]u8 {
        const fid = msg.fid orelse return unified.buildFsrpcError(self.allocator, msg.tag, "invalid", "fid is required");
        const state = self.fids.get(fid) orelse return unified.buildFsrpcError(self.allocator, msg.tag, "enoent", "unknown fid");
        const node = self.nodes.get(state.node_id) orelse return unified.buildFsrpcError(self.allocator, msg.tag, "eio", "missing node");

        if (node.kind != .dir) {
            if (try self.buildBoundVenomProxyStatPayload(state.node_id)) |payload| {
                defer self.allocator.free(payload);
                return unified.buildFsrpcResponse(self.allocator, .r_stat, msg.tag, payload);
            }
        }

        const escaped_name = try unified.jsonEscape(self.allocator, node.name);
        defer self.allocator.free(escaped_name);

        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":{d},\"name\":\"{s}\",\"kind\":\"{s}\",\"size\":{d},\"mode\":{d},\"writable\":{s}}}",
            .{ node.id, escaped_name, kindName(node.kind), effectiveNodeSizeU64(node), effectiveNodeMode(node), if (node.writable) "true" else "false" },
        );
        defer self.allocator.free(payload);
        return unified.buildFsrpcResponse(self.allocator, .r_stat, msg.tag, payload);
    }

    fn handleClunk(self: *Session, msg: *const unified.ParsedMessage) ![]u8 {
        const fid = msg.fid orelse return unified.buildFsrpcError(self.allocator, msg.tag, "invalid", "fid is required");
        if (self.fids.fetchRemove(fid)) |entry| {
            var state = entry.value;
            defer state.deinit(self.allocator);
            if (state.pending_special_write) |payload| {
                const node = self.nodes.get(state.node_id) orelse {
                    return unified.buildFsrpcError(self.allocator, msg.tag, "eio", "missing node");
                };
                if (isTerminalV2Special(node.special) and !self.canInvokeTerminalNamespace(state.node_id)) {
                    return unified.buildFsrpcError(self.allocator, msg.tag, "eperm", "terminal invoke access denied by permissions");
                }
                _ = self.executeNodeWrite(state.node_id, node.special, 0, payload) catch |err| {
                    return self.specialWriteErrorResponse(msg.tag, node.special, err);
                };
            }
        }
        return unified.buildFsrpcResponse(self.allocator, .r_clunk, msg.tag, "{}");
    }

    fn handleFlush(self: *Session, msg: *const unified.ParsedMessage) ![]u8 {
        return unified.buildFsrpcResponse(self.allocator, .r_flush, msg.tag, "{}");
    }

    fn seedNamespace(self: *Session) !void {
        var policy = try workspace_policy.loadWorkspacePolicy(
            self.allocator,
            .{
                .agent_id = self.agent_id,
                .project_id = self.project_id,
                .agents_dir = self.agents_dir,
                .projects_dir = self.projects_dir,
            },
        );
        defer policy.deinit(self.allocator);
        if (self.active_namespace_project_id) |value| self.allocator.free(value);
        self.active_namespace_project_id = try self.allocator.dupe(u8, policy.project_id);
        const show_debug = policy.show_debug or self.is_admin;

        self.root_id = try self.addDir(null, "/", false);
        const nodes_root = try self.addDir(self.root_id, "nodes", false);
        self.nodes_root_id = nodes_root;
        const agents_root = try self.addDir(self.root_id, "agents", false);
        const projects_root = try self.addDir(self.root_id, "projects", false);
        const global_root = try self.addDir(self.root_id, "global", false);
        const meta_root = try self.addDir(self.root_id, "meta", false);
        const debug_root: ?u32 = if (show_debug)
            try self.addDir(self.root_id, "debug", false)
        else
            null;

        try self.addDirectoryDescriptors(
            nodes_root,
            "Nodes",
            "{\"kind\":\"collection\",\"entries\":\"node directories\",\"shape\":\"/nodes/<node_id>/{services,fs,camera,screen,user,terminal}\"}",
            "{\"read\":true,\"write\":false}",
            "Connected node resources are surfaced here.",
        );
        try self.addDirectoryDescriptors(
            agents_root,
            "Agents",
            "{\"kind\":\"collection\",\"entries\":\"agent directories\",\"shape\":\"/agents/<agent_id>\"}",
            "{\"read\":true,\"write\":true}",
            "Agent identities attached to this project namespace.",
        );
        try self.addDirectoryDescriptors(
            projects_root,
            "Projects",
            "{\"kind\":\"collection\",\"entries\":\"project directories\",\"shape\":\"/projects/<project_id>/{fs,nodes,agents,meta}\"}",
            "{\"read\":true,\"write\":false}",
            "Attached-session compatibility view for project metadata and links.",
        );
        try self.addDirectoryDescriptors(
            global_root,
            "Global",
            "{\"kind\":\"collection\",\"entries\":\"global namespaces\",\"shape\":\"/global/<venom_id>\"}",
            "{\"read\":true,\"write\":false}",
            "System-wide stable namespaces shared across agents/projects.",
        );
        try self.addNodeDirectoriesFromControlPlane(nodes_root);
        for (policy.nodes.items) |node| {
            if (self.lookupChild(nodes_root, node.id) != null) continue;
            try self.addNodeDirectory(nodes_root, node, false);
        }
        try self.seedLocalCatalogServiceNamespaces(global_root);

        const active_agent_dir = try self.addDir(agents_root, self.agent_id, false);
        _ = try self.addFile(active_agent_dir, "README.md", "Active agent identity in this project namespace.\n", false, .none);
        const active_agent_venoms_dir = try self.addDir(active_agent_dir, "venoms", false);
        try self.addDirectoryDescriptors(
            active_agent_venoms_dir,
            "Agent Venoms",
            "{\"kind\":\"venom_index\",\"files\":[\"VENOMS.json\"],\"roots\":[\"/agents/<agent_id>/venoms/<venom_id>\",\"/nodes/<node_id>/venoms/<venom_id>\"]}",
            "{\"discover\":true,\"invoke_via_paths\":true}",
            "Active-agent Venom bindings plus raw node Venom discovery.",
        );
        self.active_agent_venoms_index_id = try self.addFile(
            active_agent_venoms_dir,
            "VENOMS.json",
            "[]",
            false,
            .agent_venoms_index,
        );
        const agent_venoms_dir = try self.addDir(global_root, "venoms", false);
        try self.addDirectoryDescriptors(
            agent_venoms_dir,
            "Venoms",
            "{\"kind\":\"venom_index\",\"files\":[\"VENOMS.json\",\"node-venom-events.ndjson\"],\"roots\":[\"/nodes/<node_id>/venoms/<venom_id>\",\"/global/<venom_id>\"]}",
            "{\"discover\":true,\"invoke_via_paths\":true}",
            "Project-wide Venom discovery index plus retained node Venom change history.",
        );
        self.agent_venoms_index_id = try self.addFile(
            agent_venoms_dir,
            "VENOMS.json",
            "[]",
            false,
            .agent_venoms_index,
        );
        self.node_venom_events_log_id = try self.addFile(
            agent_venoms_dir,
            "node-venom-events.ndjson",
            "",
            false,
            .node_venom_events_log,
        );

        for (policy.visible_agents.items) |agent_name| {
            if (std.mem.eql(u8, agent_name, "self")) continue;
            if (std.mem.eql(u8, agent_name, self.agent_id)) continue;
            const agent_dir = try self.addDir(agents_root, agent_name, false);
            _ = try self.addFile(agent_dir, "README.md", "Visible peer agent entry.\n", false, .none);
            const link = try std.fmt.allocPrint(self.allocator, "/agents/{s}\n", .{agent_name});
            defer self.allocator.free(link);
            _ = try self.addFile(agent_dir, "LINK.txt", link, false, .none);
        }

        const project_dir = try self.addDir(projects_root, policy.project_id, false);
        const project_fs_dir = try self.addDir(project_dir, "fs", false);
        const project_nodes_dir = try self.addDir(project_dir, "nodes", false);
        const project_agents_dir = try self.addDir(project_dir, "agents", false);
        const project_meta_dir = try self.addDir(project_dir, "meta", false);
        const project_venoms_dir = try self.addDir(project_dir, "venoms", false);
        try self.addDirectoryDescriptors(
            project_dir,
            "Project",
            "{\"kind\":\"project\",\"children\":[\"fs\",\"nodes\",\"agents\",\"venoms\",\"meta\"]}",
            "{\"read\":true,\"write\":false}",
            "Attached-session compatibility projection for the active project.",
        );
        try self.addDirectoryDescriptors(
            project_fs_dir,
            "Project Mounts",
            "{\"kind\":\"collection\",\"entries\":\"mount links\",\"source\":\"control.workspace_status mounts\"}",
            "{\"read\":true,\"write\":false}",
            "Mount links for the active project compatibility view.",
        );
        try self.addDirectoryDescriptors(
            project_nodes_dir,
            "Project Nodes",
            "{\"kind\":\"collection\",\"entries\":\"node links\",\"source\":\"control.workspace_status selected mounts\"}",
            "{\"read\":true,\"write\":false}",
            "Node links for the active project compatibility view.",
        );
        try self.addDirectoryDescriptors(
            project_agents_dir,
            "Project Agents",
            "{\"kind\":\"collection\",\"entries\":\"agent links\",\"scope\":\"project\",\"targets\":\"/projects/<project_id>/agents/<agent_id>\"}",
            "{\"read\":true,\"write\":false}",
            "Agent links visible within this project context.",
        );
        try self.addDirectoryDescriptors(
            project_venoms_dir,
            "Project Venoms",
            "{\"kind\":\"venom_index\",\"files\":[\"VENOMS.json\"],\"roots\":[\"/projects/<project_id>/venoms/<venom_id>\",\"/nodes/<node_id>/venoms/<venom_id>\"]}",
            "{\"discover\":true,\"invoke_via_paths\":true}",
            "Project-scoped Venom bindings plus raw node Venom discovery.",
        );
        self.active_project_venoms_index_id = try self.addFile(
            project_venoms_dir,
            "VENOMS.json",
            "[]",
            false,
            .agent_venoms_index,
        );
        try self.addDirectoryDescriptors(
            project_meta_dir,
            "Project Metadata",
            "{\"kind\":\"metadata\",\"files\":[\"topology.json\",\"nodes.json\",\"agents.json\",\"sources.json\",\"contracts.json\",\"paths.json\",\"summary.json\",\"agent_bootstrap.json\",\"agent_bootstrap_quickref.json\",\"alerts.json\",\"workspace_status.json\",\"mounts.json\",\"desired_mounts.json\",\"actual_mounts.json\",\"binds.json\",\"mounted_services.json\",\"venom_packages.json\",\"drift.json\",\"reconcile.json\",\"availability.json\",\"health.json\"]}",
            "{\"read\":true,\"write\":false}",
            "Project topology, bootstrap guidance, and availability metadata.",
        );

        const workspace_status_json = try self.loadProjectWorkspaceStatus(policy.project_id);
        defer if (workspace_status_json) |value| self.allocator.free(value);
        const loaded_live_mounts = if (workspace_status_json) |json|
            try self.addProjectFsLinksFromWorkspaceStatus(project_fs_dir, nodes_root, policy, json)
        else
            false;
        if (!loaded_live_mounts) try self.addProjectFsLinksFromPolicy(project_fs_dir, policy);
        try self.addProjectNodeLinksFromPolicy(project_nodes_dir, policy);
        const loaded_live_nodes = if (workspace_status_json) |json|
            try self.addProjectNodeLinksFromWorkspaceStatus(project_nodes_dir, policy, json)
        else
            false;

        const active_agent_target = try std.fmt.allocPrint(
            self.allocator,
            "/projects/{s}/agents/{s}\n",
            .{ policy.project_id, self.agent_id },
        );
        defer self.allocator.free(active_agent_target);
        _ = try self.addFile(project_agents_dir, self.agent_id, active_agent_target, false, .none);
        for (policy.visible_agents.items) |agent_name| {
            if (std.mem.eql(u8, agent_name, "self")) continue;
            if (std.mem.eql(u8, agent_name, self.agent_id)) continue;
            const target = try std.fmt.allocPrint(
                self.allocator,
                "/projects/{s}/agents/{s}\n",
                .{ policy.project_id, agent_name },
            );
            defer self.allocator.free(target);
            _ = try self.addFile(project_agents_dir, agent_name, target, false, .none);
        }

        try self.addProjectMetaFiles(
            project_meta_dir,
            policy,
            workspace_status_json,
            loaded_live_mounts,
            loaded_live_nodes,
        );

        if (debug_root) |dir_id| {
            try self.addDirectoryDescriptors(
                dir_id,
                "Debug",
                "{\"kind\":\"debug\",\"entries\":[\"README.md\",\"pairing\"]}",
                "{\"read\":true,\"write\":false}",
                "Privileged debug surface.",
            );
            try self.addDebugPairingSurface(dir_id);
        }

        try self.addDirectoryDescriptors(
            meta_root,
            "Meta",
            "{\"kind\":\"meta\",\"entries\":[\"protocol.json\",\"view.json\",\"agent_bootstrap.json\",\"agent_bootstrap_quickref.json\",\"workspace_status.json\",\"workspace_availability.json\",\"workspace_health.json\",\"workspace_alerts.json\",\"workspace_binds.json\",\"workspace_services.json\",\"venom_packages.json\"]}",
            "{\"read\":true,\"write\":false}",
            "Attached-session compatibility metadata.",
        );
        _ = try self.addFile(meta_root, "protocol.json", acheron_protocol_json, false, .none);
        const escaped_agent = try unified.jsonEscape(self.allocator, self.agent_id);
        defer self.allocator.free(escaped_agent);
        const escaped_project = try unified.jsonEscape(self.allocator, policy.project_id);
        defer self.allocator.free(escaped_project);
        const view_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"agent_id\":\"{s}\",\"project_id\":\"{s}\",\"show_debug\":{s},\"nodes\":{d},\"visible_agents\":{d},\"project_links\":{d}}}",
            .{
                escaped_agent,
                escaped_project,
                if (show_debug) "true" else "false",
                policy.nodes.items.len,
                policy.visible_agents.items.len,
                policy.project_links.items.len,
            },
        );
        defer self.allocator.free(view_json);
        _ = try self.addFile(meta_root, "view.json", view_json, false, .none);
        const agent_bootstrap_json = try self.buildAgentBootstrapJson(policy.project_id, self.agent_id);
        defer self.allocator.free(agent_bootstrap_json);
        _ = try self.addFile(meta_root, "agent_bootstrap.json", agent_bootstrap_json, false, .none);
        if (workspace_status_json) |status_json| {
            _ = try self.addFile(meta_root, "workspace_status.json", status_json, false, .none);
            if (try self.extractWorkspaceAvailability(status_json)) |availability_json| {
                defer self.allocator.free(availability_json);
                _ = try self.addFile(meta_root, "workspace_availability.json", availability_json, false, .none);
            } else {
                _ = try self.addFile(meta_root, "workspace_availability.json", "{\"mounts_total\":0,\"online\":0,\"degraded\":0,\"missing\":0}", false, .none);
            }
            if (try self.extractWorkspaceHealth(status_json)) |health_json| {
                defer self.allocator.free(health_json);
                _ = try self.addFile(meta_root, "workspace_health.json", health_json, false, .none);
            } else {
                _ = try self.addFile(meta_root, "workspace_health.json", "{\"state\":\"unknown\",\"availability\":{\"mounts_total\":0,\"online\":0,\"degraded\":0,\"missing\":0},\"drift_count\":0,\"reconcile_state\":\"unknown\",\"queue_depth\":0}", false, .none);
            }
            if (try self.extractWorkspaceAlerts(status_json)) |alerts_json| {
                defer self.allocator.free(alerts_json);
                _ = try self.addFile(meta_root, "workspace_alerts.json", alerts_json, false, .none);
            } else {
                _ = try self.addFile(meta_root, "workspace_alerts.json", "[]", false, .none);
            }
        } else {
            const fallback_status = try self.buildFallbackWorkspaceStatusJson(policy);
            defer self.allocator.free(fallback_status);
            _ = try self.addFile(meta_root, "workspace_status.json", fallback_status, false, .none);
            _ = try self.addFile(meta_root, "workspace_availability.json", "{\"mounts_total\":0,\"online\":0,\"degraded\":0,\"missing\":0}", false, .none);
            _ = try self.addFile(meta_root, "workspace_health.json", "{\"state\":\"unknown\",\"availability\":{\"mounts_total\":0,\"online\":0,\"degraded\":0,\"missing\":0},\"drift_count\":0,\"reconcile_state\":\"unknown\",\"queue_depth\":0}", false, .none);
            _ = try self.addFile(meta_root, "workspace_alerts.json", "[]", false, .none);
        }

        try self.refreshProjectBindsFromControlPlane();
        if (workspace_status_json) |status_json| {
            try self.appendWorkspaceMountAliasesFromWorkspaceStatus(status_json);
        }
        try self.materializeProjectBindPrefixDirectories();
        if (self.lookupChild(self.root_id, "services")) |services_root| {
            try self.addDirectoryDescriptors(
                services_root,
                "Services",
                "{\"kind\":\"collection\",\"entries\":\"workspace service binds\",\"shape\":\"/services/<venom_id>/{README.md,SCHEMA.json,CAPS.json,OPS.json,STATUS.json,status.json,result.json,control/*}\"}",
                "{\"read\":true,\"write\":false}",
                "Workspace-bound service paths projected from the active workspace binds.",
            );
        }

        try self.registerExistingGlobalVenomBinding(global_root, "events", "project_namespace");
        try self.registerExistingGlobalVenomBinding(global_root, "search_code", "project_namespace");
        try self.registerExistingGlobalVenomBinding(global_root, "terminal", "project_namespace");
        try self.registerExistingGlobalVenomBinding(global_root, "mounts", "project_namespace");
        try self.registerExistingGlobalVenomBinding(global_root, "workers", "project_namespace");
        try self.registerExistingGlobalVenomBinding(global_root, "workspaces", "project_namespace");
        try self.registerExistingGlobalVenomBinding(global_root, "git", "project_namespace");
        try self.registerExistingGlobalVenomBinding(global_root, "github_pr", "project_namespace");
        try self.registerExistingGlobalVenomBinding(global_root, "missions", "project_namespace");
        try self.registerExistingGlobalVenomBinding(global_root, "pr_review", "project_namespace");
        try self.registerExistingGlobalVenomBinding(global_root, "library", "global_namespace");
        const preferred_fs_node_id = try self.resolvePreferredBoundVenomNodeId("fs");
        defer if (preferred_fs_node_id) |value| self.allocator.free(value);
        _ = try self.seedBoundGlobalFsNamespace(global_root, preferred_fs_node_id orelse "local");
        try self.seedActiveScopedVenomBindings(active_agent_venoms_dir, project_venoms_dir, policy.project_id);
        try self.refreshScopedVenomIndexes();
        try self.addWorkspaceServiceDiscoveryFiles(meta_root, project_meta_dir, policy.project_id);
        try self.seedWorkspaceAgentsContract(policy.project_id);
    }

    fn addProjectMetaFiles(
        self: *Session,
        project_meta_dir: u32,
        policy: workspace_policy.WorkspacePolicy,
        workspace_status_json: ?[]const u8,
        loaded_live_mounts: bool,
        loaded_live_nodes: bool,
    ) anyerror!void {
        const topology_json = try self.buildProjectTopologyJson(policy);
        defer self.allocator.free(topology_json);
        _ = try self.addFile(project_meta_dir, "topology.json", topology_json, false, .none);
        const agents_json = try self.buildProjectAgentsJson(policy);
        defer self.allocator.free(agents_json);
        _ = try self.addFile(project_meta_dir, "agents.json", agents_json, false, .none);
        const contracts_json = try self.buildProjectContractsJson(policy.project_id);
        defer self.allocator.free(contracts_json);
        _ = try self.addFile(project_meta_dir, "contracts.json", contracts_json, false, .none);
        const paths_json = try self.buildProjectPathsJson(policy);
        defer self.allocator.free(paths_json);
        _ = try self.addFile(project_meta_dir, "paths.json", paths_json, false, .none);
        const agent_bootstrap_json = try self.buildAgentBootstrapJson(policy.project_id, self.agent_id);
        defer self.allocator.free(agent_bootstrap_json);
        _ = try self.addFile(project_meta_dir, "agent_bootstrap.json", agent_bootstrap_json, false, .none);

        if (workspace_status_json) |status_json| {
            var nodes_from_workspace = false;
            if (try self.extractWorkspaceNodes(status_json)) |nodes_json| {
                defer self.allocator.free(nodes_json);
                _ = try self.addFile(project_meta_dir, "nodes.json", nodes_json, false, .none);
                nodes_from_workspace = true;
            } else {
                const fallback_nodes = try self.buildFallbackProjectNodesJson(policy);
                defer self.allocator.free(fallback_nodes);
                _ = try self.addFile(project_meta_dir, "nodes.json", fallback_nodes, false, .none);
            }
            const sources_json = try self.buildProjectSourcesJson(
                policy.project_id,
                true,
                loaded_live_mounts,
                loaded_live_nodes,
                nodes_from_workspace,
            );
            defer self.allocator.free(sources_json);
            _ = try self.addFile(project_meta_dir, "sources.json", sources_json, false, .none);
            const summary_json = try self.buildProjectSummaryJson(
                policy,
                status_json,
                loaded_live_mounts,
                loaded_live_nodes,
                nodes_from_workspace,
            );
            defer self.allocator.free(summary_json);
            _ = try self.addFile(project_meta_dir, "summary.json", summary_json, false, .none);
            if (try self.extractWorkspaceAlerts(status_json)) |alerts_json| {
                defer self.allocator.free(alerts_json);
                _ = try self.addFile(project_meta_dir, "alerts.json", alerts_json, false, .none);
            } else {
                _ = try self.addFile(project_meta_dir, "alerts.json", "[]", false, .none);
            }
            _ = try self.addFile(project_meta_dir, "workspace_status.json", status_json, false, .none);
            if (try self.extractWorkspaceMounts(status_json)) |mounts_json| {
                defer self.allocator.free(mounts_json);
                _ = try self.addFile(project_meta_dir, "mounts.json", mounts_json, false, .none);
            } else {
                _ = try self.addFile(project_meta_dir, "mounts.json", "[]", false, .none);
            }
            if (try self.extractWorkspaceDesiredMounts(status_json)) |desired_mounts_json| {
                defer self.allocator.free(desired_mounts_json);
                _ = try self.addFile(project_meta_dir, "desired_mounts.json", desired_mounts_json, false, .none);
            } else {
                _ = try self.addFile(project_meta_dir, "desired_mounts.json", "[]", false, .none);
            }
            if (try self.extractWorkspaceActualMounts(status_json)) |actual_mounts_json| {
                defer self.allocator.free(actual_mounts_json);
                _ = try self.addFile(project_meta_dir, "actual_mounts.json", actual_mounts_json, false, .none);
            } else {
                _ = try self.addFile(project_meta_dir, "actual_mounts.json", "[]", false, .none);
            }
            if (try self.extractWorkspaceDrift(status_json)) |drift_json| {
                defer self.allocator.free(drift_json);
                _ = try self.addFile(project_meta_dir, "drift.json", drift_json, false, .none);
            } else {
                _ = try self.addFile(project_meta_dir, "drift.json", "{\"count\":0,\"items\":[]}", false, .none);
            }
            if (try self.extractWorkspaceReconcile(status_json)) |reconcile_json| {
                defer self.allocator.free(reconcile_json);
                _ = try self.addFile(project_meta_dir, "reconcile.json", reconcile_json, false, .none);
            } else {
                _ = try self.addFile(project_meta_dir, "reconcile.json", "{\"reconcile_state\":\"unknown\",\"last_reconcile_ms\":0,\"last_success_ms\":0,\"last_error\":null,\"queue_depth\":0}", false, .none);
            }
            if (try self.extractWorkspaceAvailability(status_json)) |availability_json| {
                defer self.allocator.free(availability_json);
                _ = try self.addFile(project_meta_dir, "availability.json", availability_json, false, .none);
            } else {
                _ = try self.addFile(project_meta_dir, "availability.json", "{\"mounts_total\":0,\"online\":0,\"degraded\":0,\"missing\":0}", false, .none);
            }
            if (try self.extractWorkspaceHealth(status_json)) |health_json| {
                defer self.allocator.free(health_json);
                _ = try self.addFile(project_meta_dir, "health.json", health_json, false, .none);
            } else {
                _ = try self.addFile(project_meta_dir, "health.json", "{\"state\":\"unknown\",\"availability\":{\"mounts_total\":0,\"online\":0,\"degraded\":0,\"missing\":0},\"drift_count\":0,\"reconcile_state\":\"unknown\",\"queue_depth\":0}", false, .none);
            }
            return;
        }

        const fallback_status = try self.buildFallbackWorkspaceStatusJson(policy);
        defer self.allocator.free(fallback_status);
        const fallback_nodes = try self.buildFallbackProjectNodesJson(policy);
        defer self.allocator.free(fallback_nodes);
        _ = try self.addFile(project_meta_dir, "nodes.json", fallback_nodes, false, .none);
        const fallback_sources = try self.buildProjectSourcesJson(policy.project_id, false, false, false, false);
        defer self.allocator.free(fallback_sources);
        _ = try self.addFile(project_meta_dir, "sources.json", fallback_sources, false, .none);
        const fallback_summary = try self.buildProjectSummaryJson(policy, null, false, false, false);
        defer self.allocator.free(fallback_summary);
        _ = try self.addFile(project_meta_dir, "summary.json", fallback_summary, false, .none);
        _ = try self.addFile(project_meta_dir, "alerts.json", "[]", false, .none);
        _ = try self.addFile(project_meta_dir, "workspace_status.json", fallback_status, false, .none);
        _ = try self.addFile(project_meta_dir, "mounts.json", "[]", false, .none);
        _ = try self.addFile(project_meta_dir, "desired_mounts.json", "[]", false, .none);
        _ = try self.addFile(project_meta_dir, "actual_mounts.json", "[]", false, .none);
        _ = try self.addFile(project_meta_dir, "drift.json", "{\"count\":0,\"items\":[]}", false, .none);
        _ = try self.addFile(project_meta_dir, "reconcile.json", "{\"reconcile_state\":\"unknown\",\"last_reconcile_ms\":0,\"last_success_ms\":0,\"last_error\":null,\"queue_depth\":0}", false, .none);
        _ = try self.addFile(project_meta_dir, "availability.json", "{\"mounts_total\":0,\"online\":0,\"degraded\":0,\"missing\":0}", false, .none);
        _ = try self.addFile(project_meta_dir, "health.json", "{\"state\":\"unknown\",\"availability\":{\"mounts_total\":0,\"online\":0,\"degraded\":0,\"missing\":0},\"drift_count\":0,\"reconcile_state\":\"unknown\",\"queue_depth\":0}", false, .none);
    }

    fn addWorkspaceServiceDiscoveryFiles(self: *Session, meta_root: u32, project_meta_dir: u32, project_id: []const u8) !void {
        const quickref_json = try self.buildAgentBootstrapQuickrefJson(project_id, self.agent_id);
        defer self.allocator.free(quickref_json);
        _ = try self.addFile(project_meta_dir, "agent_bootstrap_quickref.json", quickref_json, false, .none);
        _ = try self.addFile(meta_root, "agent_bootstrap_quickref.json", quickref_json, false, .none);

        const binds_json = try self.buildProjectBindsArrayJson();
        defer self.allocator.free(binds_json);
        _ = try self.addFile(project_meta_dir, "binds.json", binds_json, false, .none);
        _ = try self.addFile(meta_root, "workspace_binds.json", binds_json, false, .none);

        const services_json = try self.buildMountedServicesJson();
        defer self.allocator.free(services_json);
        _ = try self.addFile(project_meta_dir, "mounted_services.json", services_json, false, .none);
        _ = try self.addFile(meta_root, "workspace_services.json", services_json, false, .none);

        const packages_json = try self.buildVenomPackagesJson();
        defer self.allocator.free(packages_json);
        _ = try self.addFile(project_meta_dir, "venom_packages.json", packages_json, false, .none);
        _ = try self.addFile(meta_root, "venom_packages.json", packages_json, false, .none);
    }

    pub fn refreshWorkspaceServiceDiscoveryFiles(self: *Session) !void {
        const meta_root = self.lookupChild(self.root_id, "meta") orelse return;
        const projects_root = self.lookupChild(self.root_id, "projects") orelse return;
        const active_project_id = self.active_namespace_project_id orelse self.project_id orelse return;
        const project_dir = self.lookupChild(projects_root, active_project_id) orelse return;
        const project_meta_dir = self.lookupChild(project_dir, "meta") orelse return;
        return self.addWorkspaceServiceDiscoveryFiles(meta_root, project_meta_dir, active_project_id);
    }

    fn buildVenomPackagesJson(self: *Session) ![]u8 {
        if (self.control_plane) |plane| {
            return plane.listVenomPackages();
        }
        return venom_packages.buildPackagesJson(self.allocator);
    }

    fn buildProjectBindsArrayJson(self: *Session) ![]u8 {
        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(self.allocator);
        try out.append(self.allocator, '[');
        var first = true;
        for (self.project_binds.items) |bind| {
            if (bind.kind != .workspace) continue;
            if (!first) try out.append(self.allocator, ',');
            first = false;
            const escaped_bind = try unified.jsonEscape(self.allocator, bind.bind_path);
            defer self.allocator.free(escaped_bind);
            const escaped_target = try unified.jsonEscape(self.allocator, bind.target_path);
            defer self.allocator.free(escaped_target);
            try out.writer(self.allocator).print(
                "{{\"bind_path\":\"{s}\",\"target_path\":\"{s}\"}}",
                .{ escaped_bind, escaped_target },
            );
        }
        try out.append(self.allocator, ']');
        return out.toOwnedSlice(self.allocator);
    }

    fn hasProjectBindPath(self: *Session, bind_path: []const u8) bool {
        for (self.project_binds.items) |bind| {
            if (bind.kind != .workspace) continue;
            if (std.mem.eql(u8, bind.bind_path, bind_path)) return true;
        }
        return false;
    }

    fn appendWorkspaceMountAliasesFromWorkspaceStatus(self: *Session, workspace_status_json: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, workspace_status_json, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const mounts_value = parsed.value.object.get("mounts") orelse return;
        if (mounts_value != .array) return;

        for (mounts_value.array.items) |mount_value| {
            if (mount_value != .object) continue;

            const mount_path_value = mount_value.object.get("mount_path") orelse continue;
            const node_id_value = mount_value.object.get("node_id") orelse continue;
            if (mount_path_value != .string or mount_path_value.string.len == 0) continue;
            if (node_id_value != .string or node_id_value.string.len == 0) continue;

            if (mount_value.object.get("fs_auth_token")) |auth_value| {
                if (auth_value == .string and auth_value.string.len > 0) {
                    try self.rememberWorkspaceMountFsAuthToken(node_id_value.string, auth_value.string);
                }
            }
            if (mount_value.object.get("fs_url")) |fs_url_value| {
                if (fs_url_value == .string and fs_url_value.string.len > 0) {
                    try self.rememberWorkspaceMountFsUrl(node_id_value.string, fs_url_value.string);
                }
            }

            const normalized_mount_path = try normalizeMountGraphPath(self.allocator, mount_path_value.string);
            defer self.allocator.free(normalized_mount_path);
            if (std.mem.eql(u8, normalized_mount_path, "/")) continue;

            const export_name = if (mount_value.object.get("export_name")) |value|
                if (value == .string and value.string.len > 0) value.string else null
            else
                null;

            const target_path = (try self.resolveWorkspaceMountAliasTargetPath(
                node_id_value.string,
                export_name,
            )) orelse continue;
            defer self.allocator.free(target_path);

            if (std.mem.eql(u8, normalized_mount_path, target_path)) continue;
            try self.appendProjectBind(.workspace_mount, normalized_mount_path, target_path);
        }
    }

    fn resolveWorkspaceMountAliasTargetPath(
        self: *Session,
        node_id: []const u8,
        export_name: ?[]const u8,
    ) !?[]u8 {
        if (export_name) |value| {
            if (try self.ensureWorkspaceMountProxyRoot(node_id, value)) {
                const export_target = try std.fmt.allocPrint(self.allocator, "/nodes/{s}/{s}", .{ node_id, value });
                errdefer self.allocator.free(export_target);
                try self.rememberWorkspaceMountProxyRoot(export_target, node_id, value);
                return export_target;
            }
        }

        if (try self.ensureWorkspaceMountProxyRoot(node_id, "fs")) {
            return try std.fmt.allocPrint(self.allocator, "/nodes/{s}/fs", .{node_id});
        }

        return null;
    }

    fn rememberWorkspaceMountFsAuthToken(self: *Session, node_id: []const u8, auth_token: []const u8) !void {
        const gop = try self.workspace_mount_fs_auth_tokens.getOrPut(self.allocator, node_id);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, node_id);
        } else {
            self.allocator.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = try self.allocator.dupe(u8, auth_token);
    }

    fn rememberWorkspaceMountFsUrl(self: *Session, node_id: []const u8, fs_url: []const u8) !void {
        const gop = try self.workspace_mount_fs_urls.getOrPut(self.allocator, node_id);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, node_id);
        } else {
            self.allocator.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = try self.allocator.dupe(u8, fs_url);
    }

    fn rememberWorkspaceMountProxyRoot(
        self: *Session,
        proxy_root: []const u8,
        node_id: []const u8,
        export_name: ?[]const u8,
    ) !void {
        const gop = try self.workspace_mount_proxy_roots.getOrPut(self.allocator, proxy_root);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, proxy_root);
            gop.value_ptr.* = .{
                .node_id = try self.allocator.dupe(u8, node_id),
                .export_name = if (export_name) |value| try self.allocator.dupe(u8, value) else null,
            };
            return;
        }

        self.allocator.free(gop.value_ptr.node_id);
        gop.value_ptr.node_id = try self.allocator.dupe(u8, node_id);
        if (gop.value_ptr.export_name) |value| self.allocator.free(value);
        gop.value_ptr.export_name = if (export_name) |value| try self.allocator.dupe(u8, value) else null;
    }

    fn ensureWorkspaceMountProxyRoot(self: *Session, node_id: []const u8, root_name: []const u8) !bool {
        const nodes_root = if (self.nodes_root_id != 0) self.nodes_root_id else return false;
        const node_dir = blk: {
            if (self.lookupChild(nodes_root, node_id)) |existing| break :blk existing;
            try self.addNodeDirectoriesFromControlPlane(nodes_root);
            break :blk self.lookupChild(nodes_root, node_id) orelse return false;
        };

        if (self.lookupChild(node_dir, root_name) == null) {
            _ = try self.addDir(node_dir, root_name, false);
        }
        return true;
    }

    fn buildMountedServicesJson(self: *Session) ![]u8 {
        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(self.allocator);
        try out.append(self.allocator, '[');
        var first = true;

        for (self.project_binds.items) |bind| {
            if (bind.kind != .workspace) continue;
            if (!first) try out.append(self.allocator, ',');
            first = false;
            try self.appendMountedServiceBindJson(&out, bind);
        }

        for (self.scoped_venom_bindings.items) |binding| {
            if (!first) try out.append(self.allocator, ',');
            first = false;
            try self.appendDirectMountedServiceJson(&out, binding);
        }

        try out.append(self.allocator, ']');
        return out.toOwnedSlice(self.allocator);
    }

    fn appendMountedServiceBindJson(self: *Session, out: *std.ArrayListUnmanaged(u8), bind: PathBind) !void {
        var selected: ?*const ScopedVenomBinding = null;
        for (self.scoped_venom_bindings.items) |*binding| {
            if (!pathMatchesPrefixBoundary(bind.target_path, binding.venom_path)) continue;
            if (selected == null or binding.venom_path.len > selected.?.venom_path.len) selected = binding;
        }

        const escaped_bind = try unified.jsonEscape(self.allocator, bind.bind_path);
        defer self.allocator.free(escaped_bind);
        const escaped_target = try unified.jsonEscape(self.allocator, bind.target_path);
        defer self.allocator.free(escaped_target);

        if (selected) |binding| {
            const escaped_venom_id = try unified.jsonEscape(self.allocator, binding.venom_id);
            defer self.allocator.free(escaped_venom_id);
            const escaped_scope = try unified.jsonEscape(self.allocator, binding.scope);
            defer self.allocator.free(escaped_scope);
            const escaped_source = try unified.jsonEscape(self.allocator, binding.venom_path);
            defer self.allocator.free(escaped_source);
            const invoke_json = if (binding.invoke_path) |invoke_path| blk: {
                if (try self.rebaseBoundServicePath(bind.bind_path, bind.target_path, invoke_path)) |rebased| {
                    defer self.allocator.free(rebased);
                    const escaped = try unified.jsonEscape(self.allocator, rebased);
                    defer self.allocator.free(escaped);
                    break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
                }
                break :blk try self.allocator.dupe(u8, "null");
            } else try self.allocator.dupe(u8, "null");
            defer self.allocator.free(invoke_json);
            const provider_node_json = if (binding.provider_node_id) |value| blk: {
                const escaped = try unified.jsonEscape(self.allocator, value);
                defer self.allocator.free(escaped);
                break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
            } else try self.allocator.dupe(u8, "null");
            defer self.allocator.free(provider_node_json);
            const provider_path_json = if (binding.provider_venom_path) |value| blk: {
                const escaped = try unified.jsonEscape(self.allocator, value);
                defer self.allocator.free(escaped);
                break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
            } else try self.allocator.dupe(u8, "null");
            defer self.allocator.free(provider_path_json);
            const endpoint_json = if (binding.endpoint_path) |value| blk: {
                const escaped = try unified.jsonEscape(self.allocator, value);
                defer self.allocator.free(escaped);
                break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
            } else try self.allocator.dupe(u8, "null");
            defer self.allocator.free(endpoint_json);

            try out.writer(self.allocator).print(
                "{{\"kind\":\"venom\",\"exposure\":\"project_bind\",\"venom_id\":\"{s}\",\"scope\":\"{s}\",\"path\":\"{s}\",\"target_path\":\"{s}\",\"source_path\":\"{s}\",\"provider_node_id\":{s},\"provider_venom_path\":{s},\"endpoint_path\":{s},\"invoke_path\":{s}}}",
                .{
                    escaped_venom_id,
                    escaped_scope,
                    escaped_bind,
                    escaped_target,
                    escaped_source,
                    provider_node_json,
                    provider_path_json,
                    endpoint_json,
                    invoke_json,
                },
            );
            return;
        }

        try out.writer(self.allocator).print(
            "{{\"kind\":\"path_bind\",\"exposure\":\"project_bind\",\"path\":\"{s}\",\"target_path\":\"{s}\"}}",
            .{ escaped_bind, escaped_target },
        );
    }

    fn appendDirectMountedServiceJson(self: *Session, out: *std.ArrayListUnmanaged(u8), binding: ScopedVenomBinding) !void {
        const escaped_venom_id = try unified.jsonEscape(self.allocator, binding.venom_id);
        defer self.allocator.free(escaped_venom_id);
        const escaped_scope = try unified.jsonEscape(self.allocator, binding.scope);
        defer self.allocator.free(escaped_scope);
        const escaped_path = try unified.jsonEscape(self.allocator, binding.venom_path);
        defer self.allocator.free(escaped_path);
        const provider_node_json = if (binding.provider_node_id) |value| blk: {
            const escaped = try unified.jsonEscape(self.allocator, value);
            defer self.allocator.free(escaped);
            break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
        } else try self.allocator.dupe(u8, "null");
        defer self.allocator.free(provider_node_json);
        const provider_path_json = if (binding.provider_venom_path) |value| blk: {
            const escaped = try unified.jsonEscape(self.allocator, value);
            defer self.allocator.free(escaped);
            break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
        } else try self.allocator.dupe(u8, "null");
        defer self.allocator.free(provider_path_json);
        const endpoint_json = if (binding.endpoint_path) |value| blk: {
            const escaped = try unified.jsonEscape(self.allocator, value);
            defer self.allocator.free(escaped);
            break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
        } else try self.allocator.dupe(u8, "null");
        defer self.allocator.free(endpoint_json);
        const invoke_json = if (binding.invoke_path) |value| blk: {
            const escaped = try unified.jsonEscape(self.allocator, value);
            defer self.allocator.free(escaped);
            break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
        } else try self.allocator.dupe(u8, "null");
        defer self.allocator.free(invoke_json);

        try out.writer(self.allocator).print(
            "{{\"kind\":\"venom\",\"exposure\":\"direct\",\"venom_id\":\"{s}\",\"scope\":\"{s}\",\"path\":\"{s}\",\"provider_node_id\":{s},\"provider_venom_path\":{s},\"endpoint_path\":{s},\"invoke_path\":{s}}}",
            .{
                escaped_venom_id,
                escaped_scope,
                escaped_path,
                provider_node_json,
                provider_path_json,
                endpoint_json,
                invoke_json,
            },
        );
    }

    fn rebaseBoundServicePath(
        self: *Session,
        bind_path: []const u8,
        target_path: []const u8,
        absolute_path: []const u8,
    ) !?[]u8 {
        if (!pathMatchesPrefixBoundary(absolute_path, target_path)) return null;
        const suffix = absolute_path[target_path.len..];
        if (suffix.len == 0) return try self.allocator.dupe(u8, bind_path);
        if (std.mem.eql(u8, bind_path, "/")) return try std.fmt.allocPrint(self.allocator, "{s}", .{suffix});
        return try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ bind_path, suffix });
    }

    fn addDebugPairingSurface(self: *Session, debug_root: u32) !void {
        return pairing_venom.seedDebugSurface(self, debug_root);
    }

    pub fn refreshProjectBindsFromControlPlane(self: *Session) !void {
        self.clearProjectBinds();
        const plane = self.control_plane orelse return;
        const project_id = self.project_id orelse return;
        const escaped_project = try unified.jsonEscape(self.allocator, project_id);
        defer self.allocator.free(escaped_project);
        const payload = if (self.project_token) |token| blk: {
            const escaped_token = try unified.jsonEscape(self.allocator, token);
            defer self.allocator.free(escaped_token);
            break :blk try std.fmt.allocPrint(
                self.allocator,
                "{{\"project_id\":\"{s}\",\"project_token\":\"{s}\"}}",
                .{ escaped_project, escaped_token },
            );
        } else try std.fmt.allocPrint(self.allocator, "{{\"project_id\":\"{s}\"}}", .{escaped_project});
        defer self.allocator.free(payload);

        const binds_json = plane.listProjectBindsWithRole(payload, self.is_admin) catch return;
        defer self.allocator.free(binds_json);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, binds_json, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const binds_value = parsed.value.object.get("binds") orelse return;
        if (binds_value != .array) return;
        for (binds_value.array.items) |bind_value| {
            if (bind_value != .object) continue;
            const bind_path = bind_value.object.get("bind_path") orelse continue;
            const target_path = bind_value.object.get("target_path") orelse continue;
            if (bind_path != .string or bind_path.string.len == 0) continue;
            if (target_path != .string or target_path.string.len == 0) continue;
            try self.appendProjectBind(.workspace, bind_path.string, target_path.string);
        }
        try self.appendManagedWorkspaceEntrypointBinds();
    }

    fn appendProjectBind(self: *Session, kind: PathBindKind, bind_path: []const u8, target_path: []const u8) !void {
        for (self.project_binds.items) |*existing| {
            if (!std.mem.eql(u8, existing.bind_path, bind_path)) continue;
            if (existing.kind == kind and std.mem.eql(u8, existing.target_path, target_path)) return;
            self.allocator.free(existing.target_path);
            existing.target_path = try self.allocator.dupe(u8, target_path);
            existing.kind = kind;
            return;
        }

        try self.project_binds.append(self.allocator, .{
            .kind = kind,
            .bind_path = try self.allocator.dupe(u8, bind_path),
            .target_path = try self.allocator.dupe(u8, target_path),
        });
    }

    fn appendManagedWorkspaceEntrypointBinds(self: *Session) !void {
        const project_id = self.active_namespace_project_id orelse self.project_id orelse return;

        const quickref_target = try std.fmt.allocPrint(self.allocator, "/projects/{s}/meta/agent_bootstrap_quickref.json", .{project_id});
        defer self.allocator.free(quickref_target);
        const bootstrap_target = try std.fmt.allocPrint(self.allocator, "/projects/{s}/meta/agent_bootstrap.json", .{project_id});
        defer self.allocator.free(bootstrap_target);
        const workspace_status_target = try std.fmt.allocPrint(self.allocator, "/projects/{s}/meta/workspace_status.json", .{project_id});
        defer self.allocator.free(workspace_status_target);
        const mounted_services_target = try std.fmt.allocPrint(self.allocator, "/projects/{s}/meta/mounted_services.json", .{project_id});
        defer self.allocator.free(mounted_services_target);
        const venom_packages_target = try std.fmt.allocPrint(self.allocator, "/projects/{s}/meta/venom_packages.json", .{project_id});
        defer self.allocator.free(venom_packages_target);

        const managed_bind_specs = [_]struct { bind_path: []const u8, target_path: []const u8 }{
            .{ .bind_path = workspace_managed_root_absolute ++ "/protocol.json", .target_path = "/meta/protocol.json" },
            .{ .bind_path = workspace_managed_root_absolute ++ "/shared_data", .target_path = "/shared_data" },
            .{ .bind_path = workspace_managed_root_absolute ++ "/services", .target_path = "/services" },
            .{ .bind_path = workspace_managed_root_absolute ++ "/local_venoms", .target_path = "/nodes/local/venoms" },
        };

        for (managed_bind_specs) |spec| {
            try self.appendProjectBind(.managed_entrypoint, spec.bind_path, spec.target_path);
        }

        try self.appendProjectBind(.managed_entrypoint, workspace_managed_root_absolute ++ "/agent_bootstrap_quickref.json", quickref_target);
        try self.appendProjectBind(.managed_entrypoint, workspace_managed_root_absolute ++ "/agent_bootstrap.json", bootstrap_target);
        try self.appendProjectBind(.managed_entrypoint, workspace_managed_root_absolute ++ "/workspace_status.json", workspace_status_target);
        try self.appendProjectBind(.managed_entrypoint, workspace_managed_root_absolute ++ "/mounted_services.json", mounted_services_target);
        try self.appendProjectBind(.managed_entrypoint, workspace_managed_root_absolute ++ "/venom_packages.json", venom_packages_target);
    }

    fn materializeProjectBindPrefixDirectories(self: *Session) !void {
        for (self.project_binds.items) |bind| {
            try self.materializeBindPrefixDirectories(bind.bind_path);
        }
    }

    fn materializeBindPrefixDirectories(self: *Session, bind_path: []const u8) !void {
        var segments = std.ArrayListUnmanaged([]const u8){};
        defer segments.deinit(self.allocator);

        var iter = std.mem.splitScalar(u8, bind_path, '/');
        while (iter.next()) |segment| {
            if (segment.len == 0) continue;
            try segments.append(self.allocator, segment);
        }
        if (segments.items.len <= 1) return;

        var parent_id = self.root_id;
        for (segments.items[0 .. segments.items.len - 1]) |segment| {
            const existing = self.lookupChild(parent_id, segment);
            if (existing) |child_id| {
                const child = self.nodes.get(child_id) orelse return error.MissingNode;
                if (child.kind != .dir) return error.InvalidPayload;
                parent_id = child_id;
                continue;
            }
            parent_id = try self.addDir(parent_id, segment, false);
        }
    }

    fn addNodeDirectoriesFromControlPlane(self: *Session, nodes_root: u32) !void {
        const plane = self.control_plane orelse return;
        const payload_json = plane.listNodes() catch return;
        defer self.allocator.free(payload_json);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload_json, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const nodes_value = parsed.value.object.get("nodes") orelse return;
        if (nodes_value != .array) return;

        for (nodes_value.array.items) |node_value| {
            if (node_value != .object) continue;
            const node_id_value = node_value.object.get("node_id") orelse continue;
            if (node_id_value != .string or node_id_value.string.len == 0) continue;
            if (self.lookupChild(nodes_root, node_id_value.string) != null) continue;

            const fs_available = blk: {
                if (node_value.object.get("fs_url")) |fs_url_value| {
                    if (fs_url_value == .string and fs_url_value.string.len > 0) break :blk true;
                }
                break :blk false;
            };

            var discovered = workspace_policy.WorkspaceNodePolicy{
                .id = try self.allocator.dupe(u8, node_id_value.string),
                .resources = .{
                    .fs = fs_available,
                    .camera = false,
                    .screen = false,
                    .user = false,
                },
            };
            defer {
                self.allocator.free(discovered.id);
                for (discovered.terminals.items) |terminal_id| self.allocator.free(terminal_id);
                discovered.terminals.deinit(self.allocator);
            }
            try self.addNodeDirectory(nodes_root, discovered, false);
        }
    }

    fn lookupLocalNodeVenomsRoot(self: *Session) ?u32 {
        const nodes_root = self.lookupChild(self.root_id, "nodes") orelse return null;
        const local_node_dir = self.lookupChild(nodes_root, "local") orelse return null;
        return self.lookupChild(local_node_dir, "venoms");
    }

    fn buildNodeVenomsIndexJson(self: *Session, venoms_root_id: u32) ![]u8 {
        const venoms_root = self.nodes.get(venoms_root_id) orelse return error.MissingNode;
        if (venoms_root.kind != .dir) return error.NotDir;

        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(self.allocator);
        try out.append(self.allocator, '[');
        var first = true;

        var it = venoms_root.children.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "VENOMS.json")) continue;

            const venom_dir_id = entry.value_ptr.*;
            const venom_dir = self.nodes.get(venom_dir_id) orelse continue;
            if (venom_dir.kind != .dir) continue;
            if (!self.canInvokeVenomDirectory(venom_dir_id)) continue;

            const status_id = self.lookupChild(venom_dir_id, "STATUS.json") orelse continue;
            const status_node = self.nodes.get(status_id) orelse continue;
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, status_node.content, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;

            const status_obj = parsed.value.object;
            const venom_id = if (status_obj.get("venom_id")) |value|
                if (value == .string and value.string.len > 0) value.string else entry.key_ptr.*
            else
                entry.key_ptr.*;
            const kind = if (status_obj.get("kind")) |value|
                if (value == .string and value.string.len > 0) value.string else "service"
            else
                "service";
            const state = if (status_obj.get("state")) |value|
                if (value == .string and value.string.len > 0) value.string else "namespace"
            else
                "namespace";
            const endpoint = if (status_obj.get("endpoint")) |value|
                if (value == .string and value.string.len > 0) value.string else ""
            else
                "";
            try self.appendVenomIndexEntry(&out, &first, venom_id, kind, state, endpoint);
        }

        try out.append(self.allocator, ']');
        return out.toOwnedSlice(self.allocator);
    }

    fn refreshNodeVenomsIndex(self: *Session, node_id: []const u8) !void {
        const nodes_root = self.lookupChild(self.root_id, "nodes") orelse return;
        const node_dir_id = self.lookupChild(nodes_root, node_id) orelse return;
        const venoms_root_id = self.lookupChild(node_dir_id, "venoms") orelse return;
        const index_id = self.lookupChild(venoms_root_id, "VENOMS.json") orelse return;
        const content = try self.buildNodeVenomsIndexJson(venoms_root_id);
        defer self.allocator.free(content);
        try self.setFileContent(index_id, content);
    }

    fn cloneNodeSubtree(self: *Session, source_id: u32, target_parent_id: u32, alias_name: ?[]const u8) !u32 {
        const source = self.nodes.get(source_id) orelse return error.MissingNode;
        const name = alias_name orelse source.name;
        const target_id = switch (source.kind) {
            .dir => try self.addDir(target_parent_id, name, source.writable),
            .file => try self.addFile(target_parent_id, name, source.content, source.writable, source.special),
        };
        try self.registerNodeAliasPair(source_id, target_id);
        if (source.kind == .dir) {
            var it = source.children.iterator();
            while (it.next()) |entry| {
                _ = try self.cloneNodeSubtree(entry.value_ptr.*, target_id, null);
            }
        }
        return target_id;
    }

    fn registerNodeAliasPair(self: *Session, source_id: u32, alias_id: u32) !void {
        if (source_id == 0 or alias_id == 0 or source_id == alias_id) return;
        try self.node_aliases.put(self.allocator, source_id, alias_id);
        try self.node_aliases.put(self.allocator, alias_id, source_id);
    }

    pub fn ensureAliasedSubtree(self: *Session, source_id: u32) !void {
        const source = self.nodes.get(source_id) orelse return error.MissingNode;
        if (self.node_aliases.get(source_id)) |alias_id| {
            if (source.kind == .file) {
                try self.setFileContentRaw(alias_id, source.content);
                return;
            }
            var existing_it = source.children.iterator();
            while (existing_it.next()) |entry| {
                try self.ensureAliasedSubtree(entry.value_ptr.*);
            }
            return;
        }

        const parent_id = source.parent orelse return;
        const alias_parent_id = self.node_aliases.get(parent_id) orelse return;
        const alias_id = if (self.lookupChild(alias_parent_id, source.name)) |existing|
            existing
        else switch (source.kind) {
            .dir => try self.addDir(alias_parent_id, source.name, source.writable),
            .file => try self.addFile(alias_parent_id, source.name, source.content, source.writable, source.special),
        };
        try self.registerNodeAliasPair(source_id, alias_id);

        if (source.kind == .file) {
            try self.setFileContentRaw(alias_id, source.content);
            return;
        }

        var child_it = source.children.iterator();
        while (child_it.next()) |entry| {
            try self.ensureAliasedSubtree(entry.value_ptr.*);
        }
    }

    fn resolvePreferredLocalCatalogProviderNodeId(self: *Session, venom_id: []const u8) !?[]u8 {
        const plane = self.control_plane orelse return null;
        var provider = (try plane.resolvePreferredVenomProvider(
            self.allocator,
            venom_id,
            &.{ "spiderweb-local", "local" },
        )) orelse return null;
        defer provider.deinit(self.allocator);
        return try self.allocator.dupe(u8, provider.node_id);
    }

    fn resolveCatalogControlPlaneNodeId(self: *Session, node_id: []const u8) !?[]u8 {
        if (!std.mem.eql(u8, node_id, "local")) return try self.allocator.dupe(u8, node_id);
        return self.resolvePreferredLocalCatalogProviderNodeId("fs");
    }

    fn registerLocalCatalogVenomBinding(self: *Session, venom_id: []const u8, scope: []const u8) !void {
        const local_venoms_root = self.lookupLocalNodeVenomsRoot() orelse return;
        const venom_dir_id = self.lookupChild(local_venoms_root, venom_id) orelse return;
        const venom_path = try std.fmt.allocPrint(self.allocator, "/nodes/local/venoms/{s}", .{venom_id});
        defer self.allocator.free(venom_path);
        const endpoint_path = blk: {
            if (try self.firstVenomMountPath(venom_dir_id)) |value| break :blk value;
            break :blk try self.venomEndpointPath(venom_dir_id);
        };
        defer if (endpoint_path) |value| self.allocator.free(value);
        const preferred_provider_node_id = try self.resolvePreferredLocalCatalogProviderNodeId(venom_id);
        defer if (preferred_provider_node_id) |value| self.allocator.free(value);
        const provider_node_id = preferred_provider_node_id orelse "local";
        const provider_venom_path = if (preferred_provider_node_id) |value|
            try std.fmt.allocPrint(self.allocator, "/nodes/{s}/venoms/{s}", .{ value, venom_id })
        else
            try self.allocator.dupe(u8, venom_path);
        defer self.allocator.free(provider_venom_path);
        const invoke_path = try self.deriveVenomInvokePath(provider_node_id, venom_id, venom_dir_id);
        defer if (invoke_path) |value| self.allocator.free(value);

        try self.registerScopedVenomBinding(
            venom_id,
            scope,
            venom_path,
            provider_node_id,
            provider_venom_path,
            endpoint_path,
            invoke_path,
        );
    }

    fn cloneLocalCatalogVenomAlias(self: *Session, source_dir: u32, global_root: u32, venom_id: []const u8) !u32 {
        return self.cloneNodeSubtree(source_dir, global_root, venom_id);
    }

    fn seedLocalCatalogServiceNamespaces(self: *Session, global_root: u32) !void {
        const local_venoms_root = self.lookupLocalNodeVenomsRoot() orelse return;

        const library_dir = try self.addDir(local_venoms_root, "library", false);
        try self.seedGlobalLibraryNamespaceAt(library_dir, "/nodes/local/venoms/library");
        try self.seedBuiltinPackageMetadata(library_dir, "library");
        _ = try self.cloneLocalCatalogVenomAlias(library_dir, global_root, "library");

        const venom_packages_dir = try self.addDir(local_venoms_root, "venom_packages", false);
        try self.seedVenomPackagesNamespaceAt(venom_packages_dir, "/nodes/local/venoms/venom_packages");
        try self.seedBuiltinPackageMetadata(venom_packages_dir, "venom_packages");
        const venom_packages_alias_dir = try self.cloneLocalCatalogVenomAlias(venom_packages_dir, global_root, "venom_packages");
        self.venom_packages_status_alias_id = self.lookupChild(venom_packages_alias_dir, "status.json") orelse 0;
        self.venom_packages_result_alias_id = self.lookupChild(venom_packages_alias_dir, "result.json") orelse 0;

        const events_dir = try self.addDir(local_venoms_root, "events", false);
        try self.seedEventsNamespaceAt(events_dir, "/nodes/local/venoms/events");
        try self.seedBuiltinPackageMetadata(events_dir, "events");
        _ = try self.cloneLocalCatalogVenomAlias(events_dir, global_root, "events");

        const home_dir = try self.addDir(local_venoms_root, "home", false);
        try self.seedAgentHomeNamespaceAt(home_dir, "/nodes/local/venoms/home");
        try self.seedBuiltinPackageMetadata(home_dir, "home");
        const home_alias_dir = try self.cloneLocalCatalogVenomAlias(home_dir, global_root, "home");
        self.home_status_alias_id = self.lookupChild(home_alias_dir, "status.json") orelse 0;
        self.home_result_alias_id = self.lookupChild(home_alias_dir, "result.json") orelse 0;

        const workers_dir = try self.addDir(local_venoms_root, "workers", false);
        try workers_venom.seedNamespaceAt(self, workers_dir, "/nodes/local/venoms/workers");
        try self.seedBuiltinPackageMetadata(workers_dir, "workers");
        const workers_alias_dir = try self.cloneLocalCatalogVenomAlias(workers_dir, global_root, "workers");
        self.workers_status_alias_id = self.lookupChild(workers_alias_dir, "status.json") orelse 0;
        self.workers_result_alias_id = self.lookupChild(workers_alias_dir, "result.json") orelse 0;

        if (self.lookupChild(local_venoms_root, "search_code")) |search_code_dir| {
            _ = try self.cloneLocalCatalogVenomAlias(search_code_dir, global_root, "search_code");
        }

        if (self.lookupChild(local_venoms_root, "terminal")) |terminal_dir| {
            _ = try self.cloneLocalCatalogVenomAlias(terminal_dir, global_root, "terminal");
        }

        const mounts_dir = try self.addDir(local_venoms_root, "mounts", false);
        try self.seedAgentMountsNamespaceAt(mounts_dir, "/nodes/local/venoms/mounts");
        try self.seedBuiltinPackageMetadata(mounts_dir, "mounts");
        const mounts_alias_dir = try self.cloneLocalCatalogVenomAlias(mounts_dir, global_root, "mounts");
        self.mounts_status_alias_id = self.lookupChild(mounts_alias_dir, "status.json") orelse 0;
        self.mounts_result_alias_id = self.lookupChild(mounts_alias_dir, "result.json") orelse 0;

        const workspaces_dir = try self.addDir(local_venoms_root, "workspaces", false);
        try self.seedAgentWorkspacesNamespaceAt(workspaces_dir, "/nodes/local/venoms/workspaces");
        try self.seedBuiltinPackageMetadata(workspaces_dir, "workspaces");
        _ = try self.cloneLocalCatalogVenomAlias(workspaces_dir, global_root, "workspaces");

        if (self.lookupChild(local_venoms_root, "git")) |git_dir| {
            const git_alias_dir = try self.cloneLocalCatalogVenomAlias(git_dir, global_root, "git");
            self.git_status_alias_id = self.lookupChild(git_alias_dir, "status.json") orelse 0;
            self.git_result_alias_id = self.lookupChild(git_alias_dir, "result.json") orelse 0;
        }

        if (self.local_fs_export_root != null) {
            const github_pr_dir = try self.addDir(local_venoms_root, "github_pr", false);
            try self.seedAgentGitHubPrNamespaceAt(github_pr_dir, "/nodes/local/venoms/github_pr");
            try self.seedBuiltinPackageMetadata(github_pr_dir, "github_pr");
            const github_pr_alias_dir = try self.cloneLocalCatalogVenomAlias(github_pr_dir, global_root, "github_pr");
            self.github_pr_status_alias_id = self.lookupChild(github_pr_alias_dir, "status.json") orelse 0;
            self.github_pr_result_alias_id = self.lookupChild(github_pr_alias_dir, "result.json") orelse 0;
        }

        if (self.mission_store != null) {
            const missions_dir = try self.addDir(local_venoms_root, "missions", false);
            try self.seedAgentMissionsNamespaceAt(missions_dir, "/nodes/local/venoms/missions");
            try self.seedBuiltinPackageMetadata(missions_dir, "missions");
            const missions_alias_dir = try self.cloneLocalCatalogVenomAlias(missions_dir, global_root, "missions");
            self.missions_status_alias_id = self.lookupChild(missions_alias_dir, "status.json") orelse 0;
            self.missions_result_alias_id = self.lookupChild(missions_alias_dir, "result.json") orelse 0;

            if (self.local_fs_export_root != null) {
                const pr_review_dir = try self.addDir(local_venoms_root, "pr_review", false);
                try self.seedAgentPrReviewNamespaceAt(pr_review_dir, "/nodes/local/venoms/pr_review");
                try self.seedBuiltinPackageMetadata(pr_review_dir, "pr_review");
                const pr_review_alias_dir = try self.cloneLocalCatalogVenomAlias(pr_review_dir, global_root, "pr_review");
                self.pr_review_status_alias_id = self.lookupChild(pr_review_alias_dir, "status.json") orelse 0;
                self.pr_review_result_alias_id = self.lookupChild(pr_review_alias_dir, "result.json") orelse 0;
            }
        }

        try self.refreshNodeVenomsIndex("local");
        try self.registerLocalCatalogVenomBinding("library", "node_catalog");
        try self.registerLocalCatalogVenomBinding("venom_packages", "node_catalog");
        try self.registerLocalCatalogVenomBinding("events", "node_catalog");
        try self.registerLocalCatalogVenomBinding("workers", "node_catalog");
        try self.registerLocalCatalogVenomBinding("search_code", "node_catalog");
        try self.registerLocalCatalogVenomBinding("terminal", "node_catalog");
        try self.registerLocalCatalogVenomBinding("mounts", "node_catalog");
        try self.registerLocalCatalogVenomBinding("agents", "node_catalog");
        try self.registerLocalCatalogVenomBinding("workspaces", "node_catalog");
        try self.registerLocalCatalogVenomBinding("git", "node_catalog");
        if (self.local_fs_export_root != null) {
            try self.registerLocalCatalogVenomBinding("github_pr", "node_catalog");
        }
        if (self.mission_store != null) {
            try self.registerLocalCatalogVenomBinding("missions", "node_catalog");
            if (self.local_fs_export_root != null) {
                try self.registerLocalCatalogVenomBinding("pr_review", "node_catalog");
            }
        }
    }

    fn addProjectFsLinksFromPolicy(
        self: *Session,
        project_fs_dir: u32,
        policy: workspace_policy.WorkspacePolicy,
    ) anyerror!void {
        for (policy.project_links.items) |link| {
            const target = try std.fmt.allocPrint(self.allocator, "/nodes/{s}/{s}\n", .{ link.node_id, link.resource });
            defer self.allocator.free(target);
            _ = try self.addFile(project_fs_dir, link.name, target, false, .none);
        }
    }

    fn addProjectFsLinksFromWorkspaceStatus(
        self: *Session,
        project_fs_dir: u32,
        nodes_root: u32,
        policy: workspace_policy.WorkspacePolicy,
        workspace_status_json: []const u8,
    ) !bool {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, workspace_status_json, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        const mounts_value = parsed.value.object.get("mounts") orelse return false;
        if (mounts_value != .array or mounts_value.array.items.len == 0) return false;

        var added = false;
        for (mounts_value.array.items) |mount_value| {
            if (mount_value != .object) continue;
            const node_id_value = mount_value.object.get("node_id") orelse continue;
            if (node_id_value != .string or node_id_value.string.len == 0) continue;
            if (!try self.ensurePolicyNodeFsTarget(nodes_root, policy, node_id_value.string)) continue;
            const mount_path_value = mount_value.object.get("mount_path") orelse continue;
            if (mount_path_value != .string or mount_path_value.string.len == 0) continue;
            const export_name = if (mount_value.object.get("export_name")) |value|
                if (value == .string and value.string.len > 0) value.string else null
            else
                null;

            const link_name = try projectMountPathToLinkName(self.allocator, mount_path_value.string);
            defer self.allocator.free(link_name);
            if (self.lookupChild(project_fs_dir, link_name) != null) continue;

            const proxy_target = (try self.resolveWorkspaceMountAliasTargetPath(
                node_id_value.string,
                export_name,
            )) orelse continue;
            defer self.allocator.free(proxy_target);
            const target = try std.fmt.allocPrint(self.allocator, "{s}\n", .{proxy_target});
            defer self.allocator.free(target);
            _ = try self.addFile(project_fs_dir, link_name, target, false, .none);
            added = true;
        }
        return added;
    }

    fn ensurePolicyNodeFsTarget(
        self: *Session,
        nodes_root: u32,
        policy: workspace_policy.WorkspacePolicy,
        node_id: []const u8,
    ) !bool {
        for (policy.nodes.items) |node| {
            if (!std.mem.eql(u8, node.id, node_id)) continue;
            if (!node.resources.fs) return false;

            if (self.lookupChild(nodes_root, node_id)) |node_dir| {
                if (self.lookupChild(node_dir, "fs") == null) {
                    _ = try self.addDir(node_dir, "fs", false);
                }
                return true;
            }

            try self.addNodeDirectory(nodes_root, node, false);
            return true;
        }
        return false;
    }

    fn addProjectNodeLinksFromPolicy(
        self: *Session,
        project_nodes_dir: u32,
        policy: workspace_policy.WorkspacePolicy,
    ) anyerror!void {
        for (policy.nodes.items) |node| {
            if (self.lookupChild(project_nodes_dir, node.id) != null) continue;
            const target = try std.fmt.allocPrint(self.allocator, "/nodes/{s}\n", .{node.id});
            defer self.allocator.free(target);
            _ = try self.addFile(project_nodes_dir, node.id, target, false, .none);
        }
    }

    fn addProjectNodeLinksFromWorkspaceStatus(
        self: *Session,
        project_nodes_dir: u32,
        policy: workspace_policy.WorkspacePolicy,
        workspace_status_json: []const u8,
    ) !bool {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, workspace_status_json, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        const mounts_value = parsed.value.object.get("mounts") orelse return false;
        if (mounts_value != .array or mounts_value.array.items.len == 0) return false;

        var added = false;
        for (mounts_value.array.items) |mount_value| {
            if (mount_value != .object) continue;
            const node_id_value = mount_value.object.get("node_id") orelse continue;
            if (node_id_value != .string or node_id_value.string.len == 0) continue;
            if (!policyIncludesNode(policy, node_id_value.string)) continue;
            if (self.lookupChild(project_nodes_dir, node_id_value.string) != null) continue;
            const target = try std.fmt.allocPrint(self.allocator, "/nodes/{s}\n", .{node_id_value.string});
            defer self.allocator.free(target);
            _ = try self.addFile(project_nodes_dir, node_id_value.string, target, false, .none);
            added = true;
        }
        return added;
    }

    fn policyAllowsNodeFs(policy: workspace_policy.WorkspacePolicy, node_id: []const u8) bool {
        for (policy.nodes.items) |node| {
            if (!std.mem.eql(u8, node.id, node_id)) continue;
            return node.resources.fs;
        }
        return false;
    }

    fn policyIncludesNode(policy: workspace_policy.WorkspacePolicy, node_id: []const u8) bool {
        for (policy.nodes.items) |node| {
            if (std.mem.eql(u8, node.id, node_id)) return true;
        }
        return false;
    }

    fn addNodeDirectory(
        self: *Session,
        nodes_root: u32,
        node: workspace_policy.WorkspaceNodePolicy,
        discovered_from_workspace: bool,
    ) !void {
        const node_dir = try self.addDir(nodes_root, node.id, false);
        var resource_view = try self.addNodeVenoms(node_dir, node);
        defer resource_view.deinit(self.allocator);

        const node_schema = "{\"kind\":\"node\",\"children\":\"services + mount roots\"}";
        const node_caps = try std.fmt.allocPrint(
            self.allocator,
            "{{\"fs\":{s},\"camera\":{s},\"screen\":{s},\"user\":{s},\"terminal\":{s}}}",
            .{
                if (resource_view.fs) "true" else "false",
                if (resource_view.camera) "true" else "false",
                if (resource_view.screen) "true" else "false",
                if (resource_view.user) "true" else "false",
                if (resource_view.terminals.items.len > 0) "true" else "false",
            },
        );
        defer self.allocator.free(node_caps);
        try self.addDirectoryDescriptors(
            node_dir,
            "Node Endpoint",
            node_schema,
            node_caps,
            if (discovered_from_workspace)
                "Node discovered from live project workspace mounts."
            else
                "Node resource roots. Entries may be unavailable based on policy.",
        );
        try self.addNodeRuntimeMetadataFiles(node_dir, node.id, discovered_from_workspace);

        if (resource_view.fs and self.lookupChild(node_dir, "fs") == null) _ = try self.addDir(node_dir, "fs", false);
        if (resource_view.camera and self.lookupChild(node_dir, "camera") == null) _ = try self.addDir(node_dir, "camera", false);
        if (resource_view.screen and self.lookupChild(node_dir, "screen") == null) _ = try self.addDir(node_dir, "screen", false);
        if (resource_view.user and self.lookupChild(node_dir, "user") == null) _ = try self.addDir(node_dir, "user", false);
        if (resource_view.terminals.items.len > 0) {
            const terminal_root = if (self.lookupChild(node_dir, "terminal")) |existing| existing else try self.addDir(node_dir, "terminal", false);
            for (resource_view.terminals.items) |terminal_id| {
                if (self.lookupChild(terminal_root, terminal_id) == null) {
                    _ = try self.addDir(terminal_root, terminal_id, false);
                }
            }
        }

        for (resource_view.roots.items) |root_name| {
            if (self.lookupChild(node_dir, root_name) == null) {
                _ = try self.addDir(node_dir, root_name, false);
            }
        }
    }

    fn addNodeRuntimeMetadataFiles(
        self: *Session,
        node_dir: u32,
        node_id: []const u8,
        discovered_from_workspace: bool,
    ) !void {
        if (try self.loadNodeControlPayload(node_id)) |node_payload_json| {
            defer self.allocator.free(node_payload_json);
            _ = try self.addFile(node_dir, "NODE.json", node_payload_json, false, .none);
            if (try self.buildNodeStatusFromControlPayload(node_id, node_payload_json)) |status_json| {
                defer self.allocator.free(status_json);
                _ = try self.addFile(node_dir, "STATUS.json", status_json, false, .none);
                return;
            }
        }

        const fallback_status = try self.buildFallbackNodeStatusJson(node_id, discovered_from_workspace);
        defer self.allocator.free(fallback_status);
        _ = try self.addFile(node_dir, "STATUS.json", fallback_status, false, .none);
    }

    fn loadNodeControlPayload(self: *Session, node_id: []const u8) !?[]u8 {
        const plane = self.control_plane orelse return null;
        const catalog_node_id = (try self.resolveCatalogControlPlaneNodeId(node_id)) orelse return null;
        defer self.allocator.free(catalog_node_id);
        const escaped_node_id = try unified.jsonEscape(self.allocator, catalog_node_id);
        defer self.allocator.free(escaped_node_id);
        const request_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"node_id\":\"{s}\"}}",
            .{escaped_node_id},
        );
        defer self.allocator.free(request_json);
        return plane.getNode(request_json) catch null;
    }

    fn buildNodeStatusFromControlPayload(
        self: *Session,
        node_id: []const u8,
        node_payload_json: []const u8,
    ) !?[]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, node_payload_json, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const node_value = parsed.value.object.get("node") orelse return null;
        if (node_value != .object) return null;

        const node_name = if (node_value.object.get("node_name")) |value|
            if (value == .string and value.string.len > 0) value.string else node_id
        else
            node_id;
        const fs_url = if (node_value.object.get("fs_url")) |value|
            if (value == .string) value.string else ""
        else
            "";
        const lease_expires_at_ms = if (node_value.object.get("lease_expires_at_ms")) |value|
            if (value == .integer) value.integer else @as(i64, 0)
        else
            0;
        const last_seen_ms = if (node_value.object.get("last_seen_ms")) |value|
            if (value == .integer) value.integer else @as(i64, 0)
        else
            0;
        const joined_at_ms = if (node_value.object.get("joined_at_ms")) |value|
            if (value == .integer) value.integer else @as(i64, 0)
        else
            0;

        const online = lease_expires_at_ms > std.time.milliTimestamp();
        const escaped_node_id = try unified.jsonEscape(self.allocator, node_id);
        defer self.allocator.free(escaped_node_id);
        const escaped_node_name = try unified.jsonEscape(self.allocator, node_name);
        defer self.allocator.free(escaped_node_name);
        const escaped_fs_url = try unified.jsonEscape(self.allocator, fs_url);
        defer self.allocator.free(escaped_fs_url);

        const status_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"node_id\":\"{s}\",\"node_name\":\"{s}\",\"state\":\"{s}\",\"online\":{s},\"lease_expires_at_ms\":{d},\"last_seen_ms\":{d},\"joined_at_ms\":{d},\"fs_url\":\"{s}\",\"source\":\"control_plane\"}}",
            .{
                escaped_node_id,
                escaped_node_name,
                if (online) "online" else "degraded",
                if (online) "true" else "false",
                lease_expires_at_ms,
                last_seen_ms,
                joined_at_ms,
                escaped_fs_url,
            },
        );
        return status_json;
    }

    fn buildFallbackNodeStatusJson(
        self: *Session,
        node_id: []const u8,
        discovered_from_workspace: bool,
    ) ![]u8 {
        const escaped_node_id = try unified.jsonEscape(self.allocator, node_id);
        defer self.allocator.free(escaped_node_id);
        return std.fmt.allocPrint(
            self.allocator,
            "{{\"node_id\":\"{s}\",\"state\":\"{s}\",\"online\":{s},\"source\":\"{s}\"}}",
            .{
                escaped_node_id,
                if (discovered_from_workspace) "unknown" else "configured",
                if (discovered_from_workspace) "false" else "true",
                if (discovered_from_workspace) "workspace_discovery" else "policy",
            },
        );
    }

    pub fn addDirectoryDescriptors(
        self: *Session,
        dir_id: u32,
        title: []const u8,
        schema_json: []const u8,
        caps_json: []const u8,
        instructions: []const u8,
    ) !void {
        const readme = try std.fmt.allocPrint(
            self.allocator,
            "# {s}\n\n{s}\n",
            .{ title, instructions },
        );
        defer self.allocator.free(readme);
        _ = try self.addFile(dir_id, "README.md", readme, false, .none);
        _ = try self.addFile(dir_id, "SCHEMA.json", schema_json, false, .none);
        _ = try self.addFile(dir_id, "CAPS.json", caps_json, false, .none);
    }

    pub fn ensureWorkerLoopbackNode(self: *Session, worker_id: []const u8, agent_id: []const u8, venoms: []const []const u8) !void {
        const nodes_root = self.lookupChild(self.root_id, "nodes") orelse return error.InvalidPayload;
        const node_dir_id = if (self.lookupChild(nodes_root, worker_id)) |existing|
            existing
        else
            try self.addDir(nodes_root, worker_id, false);

        try self.ensureWorkerFile(node_dir_id, "README.md", "External worker node projected into this mounted workspace session.\n", false, .none);
        try self.ensureWorkerFile(node_dir_id, "SCHEMA.json", "{\"kind\":\"node\",\"children\":\"venoms + worker metadata\"}", false, .none);
        try self.ensureWorkerFile(node_dir_id, "CAPS.json", "{\"worker_owned\":true,\"venoms\":true}", false, .none);
        const status_json = try self.renderWorkerNodeStatusJson(worker_id, agent_id);
        defer self.allocator.free(status_json);
        try self.ensureWorkerFile(node_dir_id, "STATUS.json", status_json, false, .none);
        try self.ensureWorkerFile(node_dir_id, "NODE.json", status_json, false, .none);

        const venoms_root_id = if (self.lookupChild(node_dir_id, "venoms")) |existing|
            existing
        else
            try self.addDir(node_dir_id, "venoms", false);
        try self.ensureWorkerFile(
            venoms_root_id,
            "README.md",
            "Worker-owned loopback venoms. External agents may read and write these files directly within the mounted workspace.\n",
            false,
            .none,
        );
        try self.ensureWorkerFile(
            venoms_root_id,
            "SCHEMA.json",
            "{\"kind\":\"collection\",\"entries\":\"worker venoms\",\"shape\":\"/nodes/<worker_id>/venoms/<venom_id>/{README.md,SCHEMA.json,CAPS.json,OPS.json,STATUS.json,status.json,result.json,control/*}\"}",
            false,
            .none,
        );
        try self.ensureWorkerFile(venoms_root_id, "CAPS.json", "{\"discover\":true,\"invoke_via_paths\":true,\"worker_owned\":true}", false, .none);
        try self.ensureWorkerFile(venoms_root_id, "VENOMS.json", "[]", false, .none);

        for (venoms) |venom_id| {
            if (std.mem.eql(u8, venom_id, "memory")) {
                const memory_dir_id = if (self.lookupChild(venoms_root_id, "memory")) |existing|
                    existing
                else
                    try self.addDir(venoms_root_id, "memory", false);
                const base_path = try std.fmt.allocPrint(self.allocator, "/nodes/{s}/venoms/memory", .{worker_id});
                defer self.allocator.free(base_path);
                try workers_venom.seedPassiveWorkerMemoryNamespaceAt(self, memory_dir_id, base_path, worker_id, agent_id);
                try self.seedBuiltinPackageMetadata(memory_dir_id, "memory");
            } else if (std.mem.eql(u8, venom_id, "sub_brains")) {
                const sub_brains_dir_id = if (self.lookupChild(venoms_root_id, "sub_brains")) |existing|
                    existing
                else
                    try self.addDir(venoms_root_id, "sub_brains", false);
                const base_path = try std.fmt.allocPrint(self.allocator, "/nodes/{s}/venoms/sub_brains", .{worker_id});
                defer self.allocator.free(base_path);
                try workers_venom.seedPassiveWorkerSubBrainsNamespaceAt(self, sub_brains_dir_id, base_path, worker_id, agent_id);
                try self.seedBuiltinPackageMetadata(sub_brains_dir_id, "sub_brains");
            } else {
                var package = (try self.cloneWorkerVenomPackage(venom_id)) orelse continue;
                defer package.deinit(self.allocator);

                const venom_dir_id = if (self.lookupChild(venoms_root_id, venom_id)) |existing|
                    existing
                else
                    try self.addDir(venoms_root_id, venom_id, false);
                const base_path = try std.fmt.allocPrint(self.allocator, "/nodes/{s}/venoms/{s}", .{ worker_id, venom_id });
                defer self.allocator.free(base_path);
                try self.seedGenericWorkerLoopbackVenomNamespaceAt(venom_dir_id, base_path, worker_id, agent_id, package);
            }
        }

        try self.refreshNodeVenomsIndex(worker_id);
        try self.refreshScopedVenomIndexes();
    }

    pub fn recordWorkerHeartbeat(self: *Session, worker_id: []const u8, agent_id: []const u8, ttl_ms: u64) !void {
        const now_ms = std.time.milliTimestamp();
        const expires_at_ms = now_ms + @as(i64, @intCast(ttl_ms));
        const entry = try self.worker_presence.getOrPut(self.allocator, worker_id);
        if (entry.found_existing) {
            if (!std.mem.eql(u8, entry.value_ptr.agent_id, agent_id)) {
                self.allocator.free(entry.value_ptr.agent_id);
                entry.value_ptr.agent_id = try self.allocator.dupe(u8, agent_id);
            }
            entry.value_ptr.last_seen_ms = now_ms;
            entry.value_ptr.expires_at_ms = expires_at_ms;
            return;
        }

        entry.key_ptr.* = try self.allocator.dupe(u8, worker_id);
        entry.value_ptr.* = .{
            .agent_id = try self.allocator.dupe(u8, agent_id),
            .last_seen_ms = now_ms,
            .expires_at_ms = expires_at_ms,
        };
    }

    pub fn detachWorkerLoopbackNode(self: *Session, worker_id: []const u8) anyerror!void {
        if (self.worker_presence.fetchRemove(worker_id)) |removed| {
            self.allocator.free(removed.key);
            var presence = removed.value;
            presence.deinit(self.allocator);
        }

        const nodes_root = self.lookupChild(self.root_id, "nodes") orelse return;
        const worker_node_dir_id = self.lookupChild(nodes_root, worker_id) orelse return;

        try self.deleteNodeRecursive(worker_node_dir_id);
        try self.refreshScopedVenomIndexes();
    }

    fn refreshWorkerPresenceStatuses(self: *Session) !void {
        var it = self.worker_presence.iterator();
        while (it.next()) |entry| {
            const worker_id = entry.key_ptr.*;
            const presence = entry.value_ptr.*;
            const nodes_root = self.lookupChild(self.root_id, "nodes") orelse continue;
            const node_dir_id = self.lookupChild(nodes_root, worker_id) orelse continue;
            const status_json = try self.renderWorkerNodeStatusJson(worker_id, presence.agent_id);
            defer self.allocator.free(status_json);
            if (self.lookupChild(node_dir_id, "STATUS.json")) |status_id| {
                try self.setFileContent(status_id, status_json);
            }
            if (self.lookupChild(node_dir_id, "NODE.json")) |node_json_id| {
                try self.setFileContent(node_json_id, status_json);
            }
        }
    }

    fn reapExpiredWorkerNodes(self: *Session) !void {
        var expired = std.ArrayListUnmanaged([]const u8){};
        defer expired.deinit(self.allocator);

        const now_ms = std.time.milliTimestamp();
        var it = self.worker_presence.iterator();
        while (it.next()) |entry| {
            const presence = entry.value_ptr.*;
            if (presence.expires_at_ms <= 0) continue;
            if (now_ms <= presence.expires_at_ms + worker_reap_grace_ms) continue;
            try expired.append(self.allocator, try self.allocator.dupe(u8, entry.key_ptr.*));
        }
        defer for (expired.items) |worker_id| self.allocator.free(worker_id);

        for (expired.items) |worker_id| {
            try self.detachWorkerLoopbackNode(worker_id);
        }
    }

    fn renderWorkerNodeStatusJson(self: *Session, worker_id: []const u8, default_agent_id: []const u8) ![]u8 {
        const now_ms = std.time.milliTimestamp();
        var agent_id = default_agent_id;
        var last_seen_ms: i64 = 0;
        var expires_at_ms: i64 = 0;
        if (self.worker_presence.get(worker_id)) |presence| {
            agent_id = presence.agent_id;
            last_seen_ms = presence.last_seen_ms;
            expires_at_ms = presence.expires_at_ms;
        }
        const online = expires_at_ms > now_ms;
        return std.fmt.allocPrint(
            self.allocator,
            "{{\"node_id\":\"{s}\",\"node_name\":\"{s}\",\"state\":\"{s}\",\"online\":{s},\"agent_id\":\"{s}\",\"last_seen_ms\":{d},\"expires_at_ms\":{d},\"source\":\"worker_registration\"}}",
            .{
                worker_id,
                worker_id,
                if (online) "worker_attached" else "worker_stale",
                if (online) "true" else "false",
                agent_id,
                last_seen_ms,
                expires_at_ms,
            },
        );
    }

    fn deleteNodeRecursive(self: *Session, node_id: u32) !void {
        if (node_id == self.root_id) return;
        const node = self.nodes.get(node_id) orelse return;

        var child_ids = std.ArrayListUnmanaged(u32){};
        defer child_ids.deinit(self.allocator);
        if (node.kind == .dir) {
            var it = node.children.iterator();
            while (it.next()) |entry| {
                try child_ids.append(self.allocator, entry.value_ptr.*);
            }
        }
        for (child_ids.items) |child_id| {
            try self.deleteNodeRecursive(child_id);
        }

        if (self.node_aliases.fetchRemove(node_id)) |removed_alias| {
            _ = self.node_aliases.remove(removed_alias.value);
        }

        if (node.parent) |parent_id| {
            var parent = self.nodes.getPtr(parent_id) orelse return error.MissingNode;
            _ = parent.children.fetchRemove(node.name);
        }

        const removed = self.nodes.fetchRemove(node_id) orelse return;
        var doomed = removed.value;
        doomed.deinit(self.allocator);
    }

    fn ensureWorkerFile(
        self: *Session,
        parent_id: u32,
        name: []const u8,
        content: []const u8,
        writable: bool,
        special: SpecialKind,
    ) !void {
        if (self.lookupChild(parent_id, name)) |existing| {
            try self.setFileContent(existing, content);
            return;
        }
        _ = try self.addFile(parent_id, name, content, writable, special);
    }

    fn seedAgentHomeNamespace(self: *Session, home_dir: u32) !void {
        return home_venom.seedNamespace(self, home_dir);
    }

    fn seedAgentHomeNamespaceAt(self: *Session, home_dir: u32, base_path: []const u8) !void {
        return home_venom.seedNamespaceAt(self, home_dir, base_path);
    }

    fn seedVenomPackagesNamespaceAt(self: *Session, packages_dir: u32, base_path: []const u8) !void {
        return venom_packages_service_venom.seedNamespaceAt(self, packages_dir, base_path);
    }

    fn seedAgentTerminalNamespace(self: *Session, terminal_dir: u32) !void {
        return terminal_venom.seedNamespace(self, terminal_dir);
    }

    fn seedAgentTerminalNamespaceAt(self: *Session, terminal_dir: u32, base_path: []const u8) !void {
        return terminal_venom.seedNamespaceAt(self, terminal_dir, base_path);
    }

    fn seedAgentGitNamespace(self: *Session, git_dir: u32) !void {
        return git_venom.seedNamespace(self, git_dir);
    }

    fn seedAgentGitNamespaceAt(self: *Session, git_dir: u32, base_path: []const u8) !void {
        return git_venom.seedNamespaceAt(self, git_dir, base_path);
    }

    fn seedAgentGitHubPrNamespace(self: *Session, github_pr_dir: u32) !void {
        return github_pr_venom.seedNamespace(self, github_pr_dir);
    }

    fn seedAgentGitHubPrNamespaceAt(self: *Session, github_pr_dir: u32, base_path: []const u8) !void {
        return github_pr_venom.seedNamespaceAt(self, github_pr_dir, base_path);
    }

    fn seedAgentMountsNamespace(self: *Session, mounts_dir: u32) !void {
        return mounts_venom.seedNamespace(self, mounts_dir);
    }

    fn seedAgentMountsNamespaceAt(self: *Session, mounts_dir: u32, base_path: []const u8) !void {
        return mounts_venom.seedNamespaceAt(self, mounts_dir, base_path);
    }

    fn seedAgentWorkspacesNamespace(self: *Session, workspaces_dir: u32) !void {
        return self.seedAgentWorkspacesNamespaceAt(workspaces_dir, "/global/workspaces");
    }

    fn seedAgentWorkspacesNamespaceAt(self: *Session, workspaces_dir: u32, base_path: []const u8) !void {
        return workspaces_venom.seedNamespaceAt(self, workspaces_dir, base_path);
    }

    fn seedEventsNamespaceAt(self: *Session, events_dir: u32, base_path: []const u8) !void {
        return events_venom.seedNamespaceAt(self, events_dir, base_path);
    }

    fn seedAgentPrReviewNamespace(self: *Session, pr_review_dir: u32) !void {
        return pr_review_venom.seedNamespace(self, pr_review_dir);
    }

    fn seedAgentPrReviewNamespaceAt(self: *Session, pr_review_dir: u32, base_path: []const u8) !void {
        return pr_review_venom.seedNamespaceAt(self, pr_review_dir, base_path);
    }

    fn seedGlobalLibraryNamespace(self: *Session, library_dir: u32) !void {
        return self.seedGlobalLibraryNamespaceAt(library_dir, "/global/library");
    }

    fn seedGlobalLibraryNamespaceAt(self: *Session, library_dir: u32, base_path: []const u8) !void {
        const escaped_base_path = try unified.jsonEscape(self.allocator, base_path);
        defer self.allocator.free(escaped_base_path);
        const shape_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"kind\":\"venom\",\"venom_id\":\"library\",\"shape\":\"{s}/{{Index.md,README.md,SCHEMA.json,CAPS.json,OPS.json,PERMISSIONS.json,STATUS.json,topics/*,use-cases/*}}\"}}",
            .{escaped_base_path},
        );
        defer self.allocator.free(shape_json);
        try self.addDirectoryDescriptors(
            library_dir,
            "Global Library",
            shape_json,
            "{\"invoke\":false,\"operations\":[],\"discoverable\":true,\"read_only\":true}",
            "Stable, system-wide documentation for common Spiderweb/Acheron operations.",
        );
        _ = try self.addFile(
            library_dir,
            "OPS.json",
            "{\"model\":\"static_docs\",\"transport\":\"filesystem\",\"paths\":{\"index\":\"Index.md\",\"topics\":\"topics/*\",\"use_cases\":\"use-cases/*\"},\"operations\":{}}",
            false,
            .none,
        );
        _ = try self.addFile(
            library_dir,
            "PERMISSIONS.json",
            "{\"default\":\"allow-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"scope\":\"global\"}",
            false,
            .none,
        );
        _ = try self.addFile(
            library_dir,
            "STATUS.json",
            "{\"venom_id\":\"library\",\"state\":\"namespace\",\"has_invoke\":false}",
            false,
            .none,
        );
        const topics_dir = try self.addDir(library_dir, "topics", false);
        const index_content = try self.loadGlobalLibraryIndexFromAssets();
        defer self.allocator.free(index_content);
        _ = try self.addFile(
            library_dir,
            "Index.md",
            index_content,
            false,
            .none,
        );

        const loaded_topics = try self.seedGlobalLibraryTopicsFromAssets(topics_dir);
        if (!loaded_topics) try self.seedDefaultGlobalLibraryTopics(topics_dir);

        const use_cases_dir = try self.addDir(library_dir, "use-cases", false);
        _ = try self.seedGlobalLibrarySubtreeFromAssets(use_cases_dir, "use-cases");
    }

    fn loadGlobalLibraryIndexFromAssets(self: *Session) ![]u8 {
        const index_path = try std.fs.path.join(self.allocator, &.{ self.assets_dir, "library", "Index.md" });
        defer self.allocator.free(index_path);
        return std.fs.cwd().readFileAlloc(self.allocator, index_path, 512 * 1024) catch
            self.allocator.dupe(u8, defaultGlobalLibraryIndexMd());
    }

    fn seedGlobalLibraryTopicsFromAssets(self: *Session, topics_dir: u32) !bool {
        const topics_path = try std.fs.path.join(self.allocator, &.{ self.assets_dir, "library", "topics" });
        defer self.allocator.free(topics_path);

        var topics_fs = std.fs.cwd().openDir(topics_path, .{ .iterate = true }) catch return false;
        defer topics_fs.close();

        var iterator = topics_fs.iterate();
        var loaded_any = false;
        while (try iterator.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
            const content = topics_fs.readFileAlloc(self.allocator, entry.name, 512 * 1024) catch continue;
            defer self.allocator.free(content);
            _ = try self.addFile(topics_dir, entry.name, content, false, .none);
            loaded_any = true;
        }
        return loaded_any;
    }

    fn seedGlobalLibrarySubtreeFromAssets(
        self: *Session,
        parent_dir: u32,
        relative_subtree: []const u8,
    ) !bool {
        const host_path = try std.fs.path.join(self.allocator, &.{ self.assets_dir, "library", relative_subtree });
        defer self.allocator.free(host_path);

        var host_dir = std.fs.cwd().openDir(host_path, .{ .iterate = true }) catch return false;
        defer host_dir.close();

        var iterator = host_dir.iterate();
        var loaded_any = false;
        while (try iterator.next()) |entry| {
            switch (entry.kind) {
                .file => {
                    const content = host_dir.readFileAlloc(self.allocator, entry.name, 512 * 1024) catch continue;
                    defer self.allocator.free(content);
                    _ = try self.addFile(parent_dir, entry.name, content, false, .none);
                    loaded_any = true;
                },
                .directory => {
                    const child_dir = try self.addDir(parent_dir, entry.name, false);
                    const child_relative = try std.fs.path.join(self.allocator, &.{ relative_subtree, entry.name });
                    defer self.allocator.free(child_relative);
                    if (try self.seedGlobalLibrarySubtreeFromAssets(child_dir, child_relative)) {
                        loaded_any = true;
                    }
                },
                else => {},
            }
        }
        return loaded_any;
    }

    fn seedDefaultGlobalLibraryTopics(self: *Session, topics_dir: u32) !void {
        _ = try self.addFile(
            topics_dir,
            "getting-started.md",
            defaultGlobalLibraryTopicGettingStarted(),
            false,
            .none,
        );
        _ = try self.addFile(
            topics_dir,
            "service-discovery.md",
            defaultGlobalLibraryTopicServiceDiscovery(),
            false,
            .none,
        );
        _ = try self.addFile(
            topics_dir,
            "events-and-waits.md",
            defaultGlobalLibraryTopicEventsAndWaits(),
            false,
            .none,
        );
        _ = try self.addFile(
            topics_dir,
            "search-services.md",
            defaultGlobalLibraryTopicSearchServices(),
            false,
            .none,
        );
        _ = try self.addFile(
            topics_dir,
            "terminal-workflows.md",
            defaultGlobalLibraryTopicTerminalWorkflows(),
            false,
            .none,
        );
        _ = try self.addFile(
            topics_dir,
            "memory-workflows.md",
            defaultGlobalLibraryTopicMemoryWorkflows(),
            false,
            .none,
        );
        _ = try self.addFile(
            topics_dir,
            "project-mounts-and-binds.md",
            defaultGlobalLibraryTopicProjectMountsAndBinds(),
            false,
            .none,
        );
        _ = try self.addFile(
            topics_dir,
            "agent-management-and-sub-brains.md",
            defaultGlobalLibraryTopicAgentManagementAndSubBrains(),
            false,
            .none,
        );
    }

    fn handleTerminalV2InvokeWrite(self: *Session, invoke_node_id: u32, raw_input: []const u8) anyerror!WriteOutcome {
        return .{ .written = try terminal_venom.handleInvokeWrite(self, invoke_node_id, raw_input) };
    }

    fn handleTerminalV2CreateWrite(self: *Session, create_node_id: u32, raw_input: []const u8) anyerror!WriteOutcome {
        return .{ .written = try terminal_venom.handleCreateWrite(self, create_node_id, raw_input) };
    }

    fn handleTerminalV2ResumeWrite(self: *Session, resume_node_id: u32, raw_input: []const u8) anyerror!WriteOutcome {
        return .{ .written = try terminal_venom.handleResumeWrite(self, resume_node_id, raw_input) };
    }

    fn handleTerminalV2CloseWrite(self: *Session, close_node_id: u32, raw_input: []const u8) anyerror!WriteOutcome {
        return .{ .written = try terminal_venom.handleCloseWrite(self, close_node_id, raw_input) };
    }

    fn handleTerminalV2WriteWrite(self: *Session, write_node_id: u32, raw_input: []const u8) anyerror!WriteOutcome {
        return .{ .written = try terminal_venom.handleWriteWrite(self, write_node_id, raw_input) };
    }

    fn handleTerminalV2ReadWrite(self: *Session, read_node_id: u32, raw_input: []const u8) anyerror!WriteOutcome {
        return .{ .written = try terminal_venom.handleReadWrite(self, read_node_id, raw_input) };
    }

    fn handleTerminalV2ResizeWrite(self: *Session, resize_node_id: u32, raw_input: []const u8) anyerror!WriteOutcome {
        return .{ .written = try terminal_venom.handleResizeWrite(self, resize_node_id, raw_input) };
    }

    fn handleTerminalV2ExecWrite(self: *Session, exec_node_id: u32, raw_input: []const u8) anyerror!WriteOutcome {
        return .{ .written = try terminal_venom.handleExecWrite(self, exec_node_id, raw_input) };
    }

    pub fn buildTerminalExecArgsJson(
        self: *Session,
        obj: std.json.ObjectMap,
        session_cwd: ?[]const u8,
    ) ![]u8 {
        return terminal_venom.buildExecArgsJson(self, obj, session_cwd);
    }

    pub fn appendShellSingleQuoted(self: *Session, out: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
        return terminal_venom.appendShellSingleQuoted(self, out, value);
    }

    pub fn sessionJsonObjectOptionalString(self: *Session, obj: std.json.ObjectMap, key: []const u8) !?[]const u8 {
        _ = self;
        return jsonObjectOptionalString(obj, key);
    }

    pub fn sessionJsonObjectOptionalBool(self: *Session, obj: std.json.ObjectMap, key: []const u8) !?bool {
        _ = self;
        return jsonObjectOptionalBool(obj, key);
    }

    pub fn sessionJsonObjectOptionalU64(self: *Session, obj: std.json.ObjectMap, key: []const u8) !?u64 {
        _ = self;
        return jsonObjectOptionalU64(obj, key);
    }

    fn buildProjectTopologyJson(self: *Session, policy: workspace_policy.WorkspacePolicy) ![]u8 {
        const escaped_project = try unified.jsonEscape(self.allocator, policy.project_id);
        defer self.allocator.free(escaped_project);
        const escaped_agent = try unified.jsonEscape(self.allocator, self.agent_id);
        defer self.allocator.free(escaped_agent);

        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(self.allocator);
        try out.writer(self.allocator).print(
            "{{\"project_id\":\"{s}\",\"agent_id\":\"{s}\",\"nodes\":[",
            .{ escaped_project, escaped_agent },
        );
        for (policy.nodes.items, 0..) |node, idx| {
            if (idx != 0) try out.append(self.allocator, ',');
            const escaped_node_id = try unified.jsonEscape(self.allocator, node.id);
            defer self.allocator.free(escaped_node_id);
            try out.writer(self.allocator).print(
                "{{\"id\":\"{s}\",\"resources\":{{\"fs\":{s},\"camera\":{s},\"screen\":{s},\"user\":{s}}},\"terminals\":[",
                .{
                    escaped_node_id,
                    if (node.resources.fs) "true" else "false",
                    if (node.resources.camera) "true" else "false",
                    if (node.resources.screen) "true" else "false",
                    if (node.resources.user) "true" else "false",
                },
            );
            for (node.terminals.items, 0..) |terminal_id, term_idx| {
                if (term_idx != 0) try out.append(self.allocator, ',');
                const escaped_terminal = try unified.jsonEscape(self.allocator, terminal_id);
                defer self.allocator.free(escaped_terminal);
                try out.writer(self.allocator).print("\"{s}\"", .{escaped_terminal});
            }
            try out.appendSlice(self.allocator, "]}");
        }
        try out.appendSlice(self.allocator, "],\"project_links\":[");
        for (policy.project_links.items, 0..) |link, idx| {
            if (idx != 0) try out.append(self.allocator, ',');
            const target = try std.fmt.allocPrint(self.allocator, "/nodes/{s}/{s}", .{ link.node_id, link.resource });
            defer self.allocator.free(target);
            const escaped_name = try unified.jsonEscape(self.allocator, link.name);
            defer self.allocator.free(escaped_name);
            const escaped_node_id = try unified.jsonEscape(self.allocator, link.node_id);
            defer self.allocator.free(escaped_node_id);
            const escaped_resource = try unified.jsonEscape(self.allocator, link.resource);
            defer self.allocator.free(escaped_resource);
            const escaped_target = try unified.jsonEscape(self.allocator, target);
            defer self.allocator.free(escaped_target);
            try out.writer(self.allocator).print(
                "{{\"name\":\"{s}\",\"node_id\":\"{s}\",\"resource\":\"{s}\",\"target\":\"{s}\"}}",
                .{ escaped_name, escaped_node_id, escaped_resource, escaped_target },
            );
        }
        try out.appendSlice(self.allocator, "]}");
        return out.toOwnedSlice(self.allocator);
    }

    fn buildFallbackProjectNodesJson(self: *Session, policy: workspace_policy.WorkspacePolicy) ![]u8 {
        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "[");
        for (policy.nodes.items, 0..) |node, idx| {
            if (idx != 0) try out.append(self.allocator, ',');
            const escaped_node_id = try unified.jsonEscape(self.allocator, node.id);
            defer self.allocator.free(escaped_node_id);
            try out.writer(self.allocator).print(
                "{{\"node_id\":\"{s}\",\"state\":\"unknown\",\"mounts\":0}}",
                .{escaped_node_id},
            );
        }
        try out.appendSlice(self.allocator, "]");
        return out.toOwnedSlice(self.allocator);
    }

    fn buildProjectAgentsJson(self: *Session, policy: workspace_policy.WorkspacePolicy) ![]u8 {
        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "[");
        const escaped_self_name = try unified.jsonEscape(self.allocator, self.agent_id);
        defer self.allocator.free(escaped_self_name);
        const self_target = try std.fmt.allocPrint(self.allocator, "/agents/{s}", .{self.agent_id});
        defer self.allocator.free(self_target);
        const escaped_self_target = try unified.jsonEscape(self.allocator, self_target);
        defer self.allocator.free(escaped_self_target);
        try out.writer(self.allocator).print(
            "{{\"name\":\"{s}\",\"target\":\"{s}\",\"kind\":\"active\"}}",
            .{ escaped_self_name, escaped_self_target },
        );
        for (policy.visible_agents.items) |agent_name| {
            if (std.mem.eql(u8, agent_name, "self")) continue;
            if (std.mem.eql(u8, agent_name, self.agent_id)) continue;
            const escaped_agent_name = try unified.jsonEscape(self.allocator, agent_name);
            defer self.allocator.free(escaped_agent_name);
            const target = try std.fmt.allocPrint(self.allocator, "/agents/{s}", .{agent_name});
            defer self.allocator.free(target);
            const escaped_target = try unified.jsonEscape(self.allocator, target);
            defer self.allocator.free(escaped_target);
            try out.writer(self.allocator).print(
                ",{{\"name\":\"{s}\",\"target\":\"{s}\",\"kind\":\"visible\"}}",
                .{ escaped_agent_name, escaped_target },
            );
        }
        try out.appendSlice(self.allocator, "]");
        return out.toOwnedSlice(self.allocator);
    }

    fn buildProjectContractsJson(self: *Session, project_id: []const u8) ![]u8 {
        const workspace_binds = try std.fmt.allocPrint(self.allocator, "/projects/{s}/meta/binds.json", .{project_id});
        defer self.allocator.free(workspace_binds);
        const workspace_services = try std.fmt.allocPrint(self.allocator, "/projects/{s}/meta/mounted_services.json", .{project_id});
        defer self.allocator.free(workspace_services);
        const venom_packages_path = try std.fmt.allocPrint(self.allocator, "/projects/{s}/meta/venom_packages.json", .{project_id});
        defer self.allocator.free(venom_packages_path);
        const agent_bootstrap = try std.fmt.allocPrint(self.allocator, "/projects/{s}/meta/agent_bootstrap.json", .{project_id});
        defer self.allocator.free(agent_bootstrap);
        const agent_bootstrap_quickref = try std.fmt.allocPrint(self.allocator, "/projects/{s}/meta/agent_bootstrap_quickref.json", .{project_id});
        defer self.allocator.free(agent_bootstrap_quickref);

        const project_metadata_files = [_][]const u8{
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
            "mounted_services.json",
            "venom_packages.json",
            "drift.json",
            "reconcile.json",
            "availability.json",
            "health.json",
        };

        var out = std.io.Writer.Allocating.init(self.allocator);
        errdefer out.deinit();

        var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField("version");
        try jw.write("acheron-namespace-project-contract-v2");
        try jw.objectField("project_id");
        try jw.write(project_id);
        try jw.objectField("top_level_roots");
        try jw.write(.{ "/nodes", "/agents", "/global", "/services" });
        try jw.objectField("project_metadata_files");
        try jw.write(project_metadata_files);
        try jw.objectField("links");
        try jw.beginObject();
        try jw.objectField("nodes_root");
        try jw.write("/nodes");
        try jw.objectField("agents_root");
        try jw.write("/agents");
        try jw.objectField("global_root");
        try jw.write("/global");
        try jw.objectField("services_root");
        try jw.write("/services");
        try jw.objectField("workspace_control");
        try jw.write("/global/workspaces");
        try jw.objectField("workspace_status");
        try jw.write("/global/workspaces/control/invoke.json");
        try jw.objectField("workspace_binds");
        try jw.write(workspace_binds);
        try jw.objectField("workspace_services");
        try jw.write(workspace_services);
        try jw.objectField("venom_packages");
        try jw.write(venom_packages_path);
        try jw.objectField("agent_bootstrap");
        try jw.write(agent_bootstrap);
        try jw.objectField("agent_bootstrap_quickref");
        try jw.write(agent_bootstrap_quickref);
        try jw.objectField("workspace_agents_contract");
        try jw.write("/AGENTS.md");
        try jw.objectField("workspace_agents_contract_persisted");
        try jw.write(workspace_agents_contract_path);
        try jw.endObject();
        try jw.endObject();
        return try out.toOwnedSlice();
    }

    fn buildProjectPathsJson(self: *Session, policy: workspace_policy.WorkspacePolicy) ![]u8 {
        const mounted_services_meta = try std.fmt.allocPrint(self.allocator, "/projects/{s}/meta/mounted_services.json", .{policy.project_id});
        defer self.allocator.free(mounted_services_meta);
        const packages_meta = try std.fmt.allocPrint(self.allocator, "/projects/{s}/meta/venom_packages.json", .{policy.project_id});
        defer self.allocator.free(packages_meta);
        const bootstrap_meta = try std.fmt.allocPrint(self.allocator, "/projects/{s}/meta/agent_bootstrap.json", .{policy.project_id});
        defer self.allocator.free(bootstrap_meta);
        const bootstrap_quickref = try std.fmt.allocPrint(self.allocator, "/projects/{s}/meta/agent_bootstrap_quickref.json", .{policy.project_id});
        defer self.allocator.free(bootstrap_quickref);

        var out = std.io.Writer.Allocating.init(self.allocator);
        errdefer out.deinit();

        var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField("project_id");
        try jw.write(policy.project_id);
        try jw.objectField("nodes_root");
        try jw.write("/nodes");
        try jw.objectField("agents_root");
        try jw.write("/agents");
        try jw.objectField("services");
        try jw.beginObject();
        try jw.objectField("root");
        try jw.write("/services");
        try jw.objectField("mounted_services_meta");
        try jw.write(mounted_services_meta);
        try jw.endObject();
        try jw.objectField("packages");
        try jw.beginObject();
        try jw.objectField("meta");
        try jw.write(packages_meta);
        try jw.endObject();
        try jw.objectField("bootstrap");
        try jw.beginObject();
        try jw.objectField("meta");
        try jw.write(bootstrap_meta);
        try jw.objectField("quickref");
        try jw.write(bootstrap_quickref);
        try jw.objectField("workspace_contract");
        try jw.beginObject();
        try jw.objectField("namespace_alias");
        try jw.write("/AGENTS.md");
        try jw.objectField("workspace_path");
        try jw.write(workspace_agents_contract_path);
        try jw.endObject();
        try jw.endObject();
        try jw.objectField("global");
        try jw.beginObject();
        try jw.objectField("root");
        try jw.write("/global");
        try jw.objectField("library");
        try jw.write("/global/library");
        try jw.objectField("workspaces");
        try jw.write("/global/workspaces");
        try jw.objectField("mounts");
        try jw.write("/global/mounts");
        try jw.endObject();
        try jw.endObject();
        return try out.toOwnedSlice();
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
        if (std.mem.eql(u8, namespace_path, "/services")) {
            return workspaceManagedServicesPath(allocator, null);
        }
        if (std.mem.startsWith(u8, namespace_path, "/services/")) {
            return workspaceManagedServicesPath(allocator, namespace_path["/services/".len..]);
        }
        if (std.mem.eql(u8, namespace_path, "/nodes/local/venoms")) {
            return workspaceManagedChildPath(allocator, workspace_managed_local_venoms_dir_name, null);
        }
        if (std.mem.startsWith(u8, namespace_path, "/nodes/local/venoms/")) {
            return workspaceManagedLocalVenomsPath(allocator, namespace_path["/nodes/local/venoms/".len..]);
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
        if (std.mem.endsWith(u8, namespace_path, "/meta/mounted_services.json")) {
            return workspaceManagedPath(allocator, "mounted_services.json");
        }
        if (std.mem.endsWith(u8, namespace_path, "/meta/venom_packages.json")) {
            return workspaceManagedPath(allocator, "venom_packages.json");
        }
        if (std.mem.eql(u8, namespace_path, local_fs_world_prefix)) {
            return allocator.dupe(u8, ".");
        }
        if (std.mem.startsWith(u8, namespace_path, local_fs_world_prefix ++ "/")) {
            return allocator.dupe(u8, namespace_path[local_fs_world_prefix.len + 1 ..]);
        }
        if (namespace_path.len > 1 and namespace_path[0] == '/') {
            return std.fmt.allocPrint(allocator, "{s}/{s}", .{
                workspace_entrypoint_relative_namespace_root,
                namespace_path[1..],
            });
        }
        return allocator.dupe(u8, namespace_path);
    }

    fn relativeProjectMetaPath(allocator: std.mem.Allocator, project_id: []const u8, leaf: ?[]const u8) ![]u8 {
        const namespace_path = if (leaf) |value|
            try std.fmt.allocPrint(allocator, "/projects/{s}/meta/{s}", .{ project_id, value })
        else
            try std.fmt.allocPrint(allocator, "/projects/{s}/meta", .{project_id});
        defer allocator.free(namespace_path);
        return namespacePathToEntrypointRelative(allocator, namespace_path);
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

    fn workspaceManagedServicesPath(allocator: std.mem.Allocator, leaf: ?[]const u8) ![]u8 {
        return workspaceManagedChildPath(allocator, workspace_managed_services_dir_name, leaf);
    }

    fn workspaceManagedLocalVenomsPath(allocator: std.mem.Allocator, leaf: ?[]const u8) ![]u8 {
        return workspaceManagedChildPath(allocator, workspace_managed_local_venoms_dir_name, leaf);
    }

    const BootstrapContractPaths = struct {
        protocol_path: []const u8,
        project_meta_dir: []const u8,
        quickref_path: []const u8,
        bootstrap_path: []const u8,
        workspace_status_path: []const u8,
        venom_packages_path: []const u8,
        mounted_services_path: []const u8,
        shared_data_root: []const u8,
        world_seed_path: []const u8,
        items_seed_path: []const u8,
        puzzle_seed_path: []const u8,
        service_root: []const u8,
        ensure_home_path: []const u8,
        repair_bind_path: []const u8,
        register_worker_path: []const u8,
        local_venoms_root: []const u8,
        target_template: []const u8,
        missions_service_root: []const u8,

        fn init(allocator: std.mem.Allocator, project_id: []const u8) !BootstrapContractPaths {
            _ = project_id;
            return .{
                .protocol_path = try workspaceManagedPath(allocator, "protocol.json"),
                .project_meta_dir = try workspaceManagedPath(allocator, null),
                .quickref_path = try workspaceManagedPath(allocator, "agent_bootstrap_quickref.json"),
                .bootstrap_path = try workspaceManagedPath(allocator, "agent_bootstrap.json"),
                .workspace_status_path = try workspaceManagedPath(allocator, "workspace_status.json"),
                .venom_packages_path = try workspaceManagedPath(allocator, "venom_packages.json"),
                .mounted_services_path = try workspaceManagedPath(allocator, "mounted_services.json"),
                .shared_data_root = try workspaceManagedPath(allocator, "shared_data"),
                .world_seed_path = try workspaceManagedSharedDataPath(allocator, "world_seed.json"),
                .items_seed_path = try workspaceManagedSharedDataPath(allocator, "items_seed.json"),
                .puzzle_seed_path = try workspaceManagedSharedDataPath(allocator, "puzzle_seed.json"),
                .service_root = try workspaceManagedServicesPath(allocator, null),
                .ensure_home_path = try workspaceManagedServicesPath(allocator, "home/control/ensure.json"),
                .repair_bind_path = try workspaceManagedServicesPath(allocator, "mounts/control/bind.json"),
                .register_worker_path = try workspaceManagedServicesPath(allocator, "workers/control/register.json"),
                .local_venoms_root = try workspaceManagedChildPath(allocator, workspace_managed_local_venoms_dir_name, null),
                .target_template = try workspaceManagedLocalVenomsPath(allocator, "{venom_id}"),
                .missions_service_root = try workspaceManagedServicesPath(allocator, "missions"),
            };
        }

        fn deinit(self: BootstrapContractPaths, allocator: std.mem.Allocator) void {
            allocator.free(self.protocol_path);
            allocator.free(self.project_meta_dir);
            allocator.free(self.quickref_path);
            allocator.free(self.bootstrap_path);
            allocator.free(self.workspace_status_path);
            allocator.free(self.venom_packages_path);
            allocator.free(self.mounted_services_path);
            allocator.free(self.shared_data_root);
            allocator.free(self.world_seed_path);
            allocator.free(self.items_seed_path);
            allocator.free(self.puzzle_seed_path);
            allocator.free(self.service_root);
            allocator.free(self.ensure_home_path);
            allocator.free(self.repair_bind_path);
            allocator.free(self.register_worker_path);
            allocator.free(self.local_venoms_root);
            allocator.free(self.target_template);
            allocator.free(self.missions_service_root);
        }
    };

    fn writeBootstrapRequiredServices(self: *Session, jw: *std.json.Stringify) !usize {
        var present_count: usize = 0;
        try jw.beginArray();
        for (bootstrap_required_services) |service| {
            const bind_namespace_path = try std.fmt.allocPrint(self.allocator, "/services/{s}", .{service.id});
            defer self.allocator.free(bind_namespace_path);
            const bind_path = try namespacePathToEntrypointRelative(self.allocator, bind_namespace_path);
            defer self.allocator.free(bind_path);

            const present = self.hasProjectBindPath(bind_namespace_path);
            if (present) present_count += 1;

            const ensure_path = if (service.ensure_path) |value|
                try namespacePathToEntrypointRelative(self.allocator, value)
            else
                null;
            defer if (ensure_path) |value| self.allocator.free(value);

            const invoke_path = if (service.invoke_path) |value|
                try namespacePathToEntrypointRelative(self.allocator, value)
            else
                null;
            defer if (invoke_path) |value| self.allocator.free(value);

            try jw.beginObject();
            try jw.objectField("service_id");
            try jw.write(service.id);
            try jw.objectField("path");
            try jw.write(bind_path);
            try jw.objectField("present");
            try jw.write(present);
            try jw.objectField("ensure_path");
            try jw.write(ensure_path);
            try jw.objectField("invoke_path");
            try jw.write(invoke_path);
            try jw.endObject();
        }
        try jw.endArray();
        return present_count;
    }

    fn buildAgentBootstrapQuickrefJson(self: *Session, project_id: []const u8, agent_id: []const u8) ![]u8 {
        const paths = try BootstrapContractPaths.init(self.allocator, project_id);
        defer paths.deinit(self.allocator);

        const discovery_order = [_][]const u8{
            "./AGENTS.md",
            paths.protocol_path,
            paths.quickref_path,
            paths.bootstrap_path,
            paths.world_seed_path,
            paths.items_seed_path,
            paths.puzzle_seed_path,
        };

        var out = std.io.Writer.Allocating.init(self.allocator);
        errdefer out.deinit();

        var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField("version");
        try jw.write("spiderweb-agent-bootstrap-quickref-v1");
        try jw.objectField("project_id");
        try jw.write(project_id);
        try jw.objectField("agent_id");
        try jw.write(agent_id);
        try jw.objectField("project_write_root");
        try jw.write(".");
        try jw.objectField("shared_data_root");
        try jw.write(paths.shared_data_root);
        try jw.objectField("service_root");
        try jw.write(paths.service_root);

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
        try jw.objectField("project_meta_dir");
        try jw.write(paths.project_meta_dir);
        try jw.objectField("quickref");
        try jw.write(paths.quickref_path);
        try jw.objectField("bootstrap");
        try jw.write(paths.bootstrap_path);
        try jw.objectField("workspace_status");
        try jw.write(paths.workspace_status_path);
        try jw.objectField("venom_packages");
        try jw.write(paths.venom_packages_path);
        try jw.objectField("mounted_services");
        try jw.write(paths.mounted_services_path);
        try jw.objectField("shared_data_root");
        try jw.write(paths.shared_data_root);
        try jw.objectField("service_root");
        try jw.write(paths.service_root);
        try jw.objectField("project_write_root");
        try jw.write(".");
        try jw.endObject();

        try jw.objectField("discovery_order");
        try jw.write(discovery_order);

        try jw.objectField("fallback_meta");
        try jw.beginObject();
        try jw.objectField("mounted_services");
        try jw.write(paths.mounted_services_path);
        try jw.objectField("venom_packages");
        try jw.write(paths.venom_packages_path);
        try jw.endObject();

        try jw.objectField("required_services");
        const present_count = try self.writeBootstrapRequiredServices(&jw);

        try jw.objectField("all_required_services_present");
        try jw.write(present_count == bootstrap_required_services.len);
        try jw.objectField("required_service_count");
        try jw.write(bootstrap_required_services.len);
        try jw.objectField("required_services_present_count");
        try jw.write(present_count);

        try jw.objectField("control_writes");
        try jw.beginObject();
        try jw.objectField("ensure_home");
        try jw.write(paths.ensure_home_path);
        try jw.objectField("repair_bind");
        try jw.write(paths.repair_bind_path);
        try jw.endObject();

        try jw.objectField("implementation_hint");
        try jw.beginObject();
        try jw.objectField("prefer_quickref_over_raw_service_enumeration");
        try jw.write(true);
        try jw.objectField("proceed_directly_when_ready");
        try jw.write(true);
        try jw.endObject();

        try jw.endObject();
        return try out.toOwnedSlice();
    }

    fn buildAgentBootstrapJson(self: *Session, project_id: []const u8, agent_id: []const u8) ![]u8 {
        const paths = try BootstrapContractPaths.init(self.allocator, project_id);
        defer paths.deinit(self.allocator);

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
            paths.mounted_services_path,
            paths.workspace_status_path,
            paths.venom_packages_path,
        };
        const required_service_ids = [_][]const u8{ "home", "mounts", "workers", "terminal", "git", "search_code", "library", "events" };
        const default_worker_venoms = [_][]const u8{ "memory", "sub_brains" };
        const fallback_roots = [_][]const u8{paths.local_venoms_root};

        var out = std.io.Writer.Allocating.init(self.allocator);
        errdefer out.deinit();

        var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField("version");
        try jw.write("spiderweb-agent-bootstrap-v1");
        try jw.objectField("project_id");
        try jw.write(project_id);
        try jw.objectField("agent_id");
        try jw.write(agent_id);
        try jw.objectField("project_write_root");
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
        try jw.objectField("venom_packages");
        try jw.write(paths.venom_packages_path);
        try jw.objectField("mounted_services");
        try jw.write(paths.mounted_services_path);
        try jw.objectField("shared_data_root");
        try jw.write(paths.shared_data_root);
        try jw.objectField("service_root");
        try jw.write(paths.service_root);
        try jw.objectField("project_write_root");
        try jw.write(".");
        try jw.endObject();

        try jw.objectField("service_preference");
        try jw.beginObject();
        try jw.objectField("preferred_root");
        try jw.write(paths.service_root);
        try jw.objectField("fallback_roots");
        try jw.write(fallback_roots);
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
        try jw.objectField("service");
        try jw.write("./.spiderweb/services/home");
        try jw.objectField("invoke_path");
        try jw.write(paths.ensure_home_path);
        try jw.objectField("payload");
        try jw.beginObject();
        try jw.objectField("agent_id");
        try jw.write(agent_id);
        try jw.objectField("project_id");
        try jw.write(project_id);
        try jw.endObject();
        try jw.objectField("required");
        try jw.write(true);
        try jw.endObject();

        try jw.beginObject();
        try jw.objectField("step");
        try jw.write("verify_generic_services");
        try jw.objectField("service");
        try jw.write("./.spiderweb/services/mounts");
        try jw.objectField("required_services");
        try jw.write(required_service_ids);
        try jw.objectField("repair_invoke_path");
        try jw.write(paths.repair_bind_path);
        try jw.objectField("target_template");
        try jw.write(paths.target_template);
        try jw.objectField("required");
        try jw.write(true);
        try jw.endObject();

        try jw.beginObject();
        try jw.objectField("step");
        try jw.write("optional_worker_register");
        try jw.objectField("service");
        try jw.write("./.spiderweb/services/workers");
        try jw.objectField("invoke_path");
        try jw.write(paths.register_worker_path);
        try jw.objectField("default_venoms");
        try jw.write(default_worker_venoms);
        try jw.objectField("required");
        try jw.write(false);
        try jw.endObject();

        try jw.endArray();

        try jw.objectField("persistence");
        try jw.beginObject();
        try jw.objectField("shared_project_binds");
        try jw.write("persistent");
        try jw.objectField("shared_project_mounts");
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

    fn buildWorkspaceAgentsManagedBlock(self: *Session, project_id: []const u8) ![]u8 {
        const paths = try BootstrapContractPaths.init(self.allocator, project_id);
        defer paths.deinit(self.allocator);

        var available_services = std.ArrayListUnmanaged(u8){};
        defer available_services.deinit(self.allocator);
        var missing_services = std.ArrayListUnmanaged(u8){};
        defer missing_services.deinit(self.allocator);

        for (bootstrap_required_services) |service| {
            const bind_path = try std.fmt.allocPrint(self.allocator, "/services/{s}", .{service.id});
            defer self.allocator.free(bind_path);
            const target = if (self.hasProjectBindPath(bind_path)) &available_services else &missing_services;
            if (target.items.len != 0) try target.appendSlice(self.allocator, ", ");
            try target.appendSlice(self.allocator, service.id);
        }

        const available_text = if (available_services.items.len != 0)
            available_services.items
        else
            "none";
        const missing_text = if (missing_services.items.len != 0)
            missing_services.items
        else
            "none";
        const vision_text = "Project vision is tracked by Spiderweb project metadata and mission sources. Follow future workspace mission files when they are materialized.";

        return std.fmt.allocPrint(
            self.allocator,
            \\# Spiderweb Workspace Agent Contract
            \\
            \\{s}
            \\This section is generated by Spiderweb. Follow it first. Workspace-owner notes live below the managed block and are preserved across updates.
            \\
            \\## What This Folder Is
            \\You are in a mounted Spiderweb workspace. The workspace itself is the durable collaboration surface; agents may come and go.
            \\In the normal interactive flow, the agent starts in this directory, so `.` is the project write root. Spiderweb projects the required bootstrap and service surfaces into `./.spiderweb/` as part of this same mounted workspace contract, so you do not need to climb out of this directory with `..`.
            \\
            \\## Project Vision
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
            \\3. Use `{s}/*` as the preferred service surface. Only use fallback roots from `agent_bootstrap.json` if a required service is missing.
            \\4. If `{s}` succeeds and `agent_bootstrap_quickref.json` says `all_required_services_present=true`, treat bootstrap as complete immediately and start implementation. Do not keep exploring or re-probing services after that point.
            \\5. Keep project writes inside the current directory `.` unless the user prompt explicitly says otherwise.
            \\6. When creating or fixing project files, rewrite the whole target file in one pass. Do not append partial repair fragments to an existing file. If you need to create multiple files, write them in separate commands so one long shell command cannot partially fail the whole set.
            \\7. If `game.py` fails `py_compile` or the walkthrough run, delete and recreate `game.py` from scratch before retrying. If a regenerated `game.py` still fails `py_compile`, replace it with another full rewrite immediately instead of inspecting the broken file tail or attempting partial edits.
            \\8. Once `python3 -m py_compile game.py` succeeds, do not rewrite `game.py` again unless `python3 game.py < walkthrough.txt` or `python3 validate_game.py --workspace . --shared-data {s} --output game_validation.json` exits non-zero.
            \\9. Treat `python3 game.py < walkthrough.txt` as successful when it exits with code `0`, even if stdout contains repeated input prompts such as `> `. Treat `python3 validate_game.py --workspace . --shared-data {s} --output game_validation.json` as successful when it exits with code `0`. Do not rerun either command through nested shell wrappers or alternate redirection forms unless the command itself failed.
            \\10. Do not run broad scans such as `find`, `rg --files`, or recursive `ls` across `services/`, `projects/`, or `meta/`. Read only the exact listed files directly.
            \\
            \\## Namespace Paths
            \\- Current working directory: `.`
            \\- This file: `./AGENTS.md`
            \\- Spiderweb-managed entrypoint root: `./.spiderweb`
            \\- Shared data root from here: `{s}`
            \\- Service root from here: `{s}`
            \\- Fallback local venom root from here: `{s}`
            \\
            \\## Current Service Surface
            \\- Present required services: {s}
            \\- Missing optional/repairable services: {s}
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
            \\## Future Missions
            \\If the workspace later materializes mission files under `.spiderweb/` or exposes `{s}`, treat them as workspace-owned guidance in addition to the user prompt.
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
                paths.service_root,
                paths.ensure_home_path,
                paths.shared_data_root,
                paths.shared_data_root,
                paths.shared_data_root,
                paths.service_root,
                paths.local_venoms_root,
                available_text,
                missing_text,
                paths.shared_data_root,
                paths.missions_service_root,
                workspace_agents_managed_end,
            },
        );
    }

    fn mergeWorkspaceAgentsContract(self: *Session, managed_block: []const u8, existing: ?[]const u8) ![]u8 {
        const placeholder =
            "## Workspace Owner Notes\n\nAdd custom workspace-specific rules here. Spiderweb preserves everything outside the managed block.\n";

        if (existing) |current| {
            const begin_index = std.mem.indexOf(u8, current, workspace_agents_managed_begin);
            const end_index = std.mem.indexOf(u8, current, workspace_agents_managed_end);
            if (begin_index != null and end_index != null and end_index.? >= begin_index.?) {
                const suffix_start = end_index.? + workspace_agents_managed_end.len;
                const prefix = trimWorkspaceAgentsPrefixNoise(current[0..begin_index.?]);
                const suffix = current[suffix_start..];
                return std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ prefix, managed_block, suffix });
            }
            const cleaned_current = trimWorkspaceAgentsPrefixNoise(current);
            if (std.mem.trim(u8, cleaned_current, " \t\r\n").len != 0) {
                return std.fmt.allocPrint(
                    self.allocator,
                    "{s}\n\n{s}\n{s}",
                    .{ managed_block, placeholder, cleaned_current },
                );
            }
        }

        return std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ managed_block, placeholder });
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

    fn readExistingWorkspaceAgentsContract(self: *Session) !?[]u8 {
        const host_path = self.resolveMissionContractHostPath(workspace_agents_contract_path) catch return null;
        defer self.allocator.free(host_path);

        const safe_host_path = (try self.resolveLocalFsSafeHostPath(host_path)) orelse return null;
        defer self.allocator.free(safe_host_path);

        var file = if (std.fs.path.isAbsolute(safe_host_path))
            std.fs.openFileAbsolute(safe_host_path, .{}) catch return null
        else
            std.fs.cwd().openFile(safe_host_path, .{}) catch return null;
        defer file.close();

        const existing = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        return existing;
    }

    fn seedWorkspaceAgentsContract(self: *Session, project_id: []const u8) !void {
        const managed_block = try self.buildWorkspaceAgentsManagedBlock(project_id);
        defer self.allocator.free(managed_block);

        const existing = try self.readExistingWorkspaceAgentsContract();
        defer if (existing) |value| self.allocator.free(value);
        const merged = try self.mergeWorkspaceAgentsContract(managed_block, existing);
        defer self.allocator.free(merged);

        var workspace_file_id: u32 = 0;
        var namespace_file_id: u32 = 0;

        const local_fs_dir = self.resolveAbsolutePathNoBinds(local_fs_world_prefix);
        if (local_fs_dir) |dir_id| {
            if (self.lookupChild(dir_id, "AGENTS.md")) |file_id| {
                workspace_file_id = file_id;
            } else {
                workspace_file_id = try self.addFile(dir_id, "AGENTS.md", merged, true, .none);
            }
        }

        if (self.lookupChild(self.root_id, "AGENTS.md")) |file_id| {
            namespace_file_id = file_id;
        } else {
            namespace_file_id = try self.addFile(self.root_id, "AGENTS.md", merged, false, .none);
        }

        if (workspace_file_id != 0) {
            try self.registerNodeAliasPair(workspace_file_id, namespace_file_id);
            try self.setFileContent(workspace_file_id, merged);
        } else {
            try self.setFileContent(namespace_file_id, merged);
        }

        self.writeMissionContractFile(workspace_agents_contract_path, merged) catch {};
    }

    fn buildProjectSourcesJson(
        self: *Session,
        project_id: []const u8,
        has_workspace_status: bool,
        fs_from_workspace: bool,
        project_nodes_from_workspace: bool,
        nodes_meta_from_workspace: bool,
    ) ![]u8 {
        const escaped_project_id = try unified.jsonEscape(self.allocator, project_id);
        defer self.allocator.free(escaped_project_id);
        return std.fmt.allocPrint(
            self.allocator,
            "{{\"project_id\":\"{s}\",\"workspace_status\":\"{s}\",\"project_fs\":\"{s}\",\"project_nodes\":\"{s}\",\"nodes_meta\":\"{s}\",\"project_binds\":\"control_plane\",\"mounted_services\":\"namespace_projection\"}}",
            .{
                escaped_project_id,
                if (has_workspace_status) "control_plane" else "policy",
                if (fs_from_workspace) "workspace_mounts" else "policy_links",
                if (project_nodes_from_workspace) "workspace_mounts" else "policy_nodes",
                if (nodes_meta_from_workspace) "workspace_mounts" else "policy_nodes",
            },
        );
    }

    fn buildProjectSummaryJson(
        self: *Session,
        policy: workspace_policy.WorkspacePolicy,
        workspace_status_json: ?[]const u8,
        loaded_live_mounts: bool,
        loaded_live_nodes: bool,
        nodes_meta_from_workspace: bool,
    ) ![]u8 {
        const escaped_project_id = try unified.jsonEscape(self.allocator, policy.project_id);
        defer self.allocator.free(escaped_project_id);

        var policy_agent_links: usize = 1;
        for (policy.visible_agents.items) |agent_name| {
            if (std.mem.eql(u8, agent_name, "self")) continue;
            if (std.mem.eql(u8, agent_name, self.agent_id)) continue;
            policy_agent_links += 1;
        }

        var workspace_mount_links: usize = 0;
        var workspace_node_links: usize = 0;
        var reconcile_state: []const u8 = "unknown";
        var reconcile_state_owned: ?[]u8 = null;
        defer if (reconcile_state_owned) |owned| self.allocator.free(owned);
        var queue_depth: i64 = 0;
        var health_state: []const u8 = "unknown";

        if (workspace_status_json) |status_json| {
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, status_json, .{}) catch null;
            if (parsed) |*status_parsed| {
                defer status_parsed.deinit();
                if (status_parsed.value == .object) {
                    if (status_parsed.value.object.get("reconcile_state")) |value| {
                        if (value == .string and value.string.len > 0) {
                            reconcile_state_owned = try self.allocator.dupe(u8, value.string);
                            reconcile_state = reconcile_state_owned.?;
                        }
                    }
                    if (status_parsed.value.object.get("queue_depth")) |value| {
                        if (value == .integer and value.integer >= 0) queue_depth = value.integer;
                    }

                    var missing: i64 = 0;
                    var degraded: i64 = 0;
                    var drift_count: i64 = 0;
                    if (status_parsed.value.object.get("availability")) |availability_value| {
                        if (availability_value == .object) {
                            if (availability_value.object.get("missing")) |value| {
                                if (value == .integer and value.integer >= 0) missing = value.integer;
                            }
                            if (availability_value.object.get("degraded")) |value| {
                                if (value == .integer and value.integer >= 0) degraded = value.integer;
                            }
                        }
                    }
                    if (status_parsed.value.object.get("drift")) |drift_value| {
                        if (drift_value == .object) {
                            if (drift_value.object.get("count")) |value| {
                                if (value == .integer and value.integer >= 0) drift_count = value.integer;
                            }
                        }
                    }

                    if (status_parsed.value.object.get("mounts")) |mounts_value| {
                        if (mounts_value == .array) {
                            workspace_mount_links = mounts_value.array.items.len;
                            var nodes_seen = std.StringHashMapUnmanaged(void){};
                            defer nodes_seen.deinit(self.allocator);
                            for (mounts_value.array.items) |mount_value| {
                                if (mount_value != .object) continue;
                                const node_id_value = mount_value.object.get("node_id") orelse continue;
                                if (node_id_value != .string or node_id_value.string.len == 0) continue;
                                if (!nodes_seen.contains(node_id_value.string)) {
                                    try nodes_seen.put(self.allocator, node_id_value.string, {});
                                }
                            }
                            workspace_node_links = nodes_seen.count();
                        }
                    }

                    health_state = if (missing > 0)
                        "missing"
                    else if (degraded > 0 or drift_count > 0 or queue_depth > 0 or std.mem.eql(u8, reconcile_state, "degraded"))
                        "degraded"
                    else if (std.mem.eql(u8, reconcile_state, "unknown"))
                        "unknown"
                    else
                        "healthy";
                }
            }
        }

        const source_workspace_status = if (workspace_status_json != null) "control_plane" else "policy";
        const source_project_fs = if (loaded_live_mounts) "workspace_mounts" else "policy_links";
        const source_project_nodes = if (loaded_live_nodes) "workspace_mounts" else "policy_nodes";
        const source_nodes_meta = if (nodes_meta_from_workspace) "workspace_mounts" else "policy_nodes";
        const project_mount_links = if (loaded_live_mounts and workspace_mount_links > 0) workspace_mount_links else policy.project_links.items.len;
        const project_node_links = if (loaded_live_nodes and workspace_node_links > 0) workspace_node_links else policy.nodes.items.len;

        const escaped_health_state = try unified.jsonEscape(self.allocator, health_state);
        defer self.allocator.free(escaped_health_state);
        const escaped_reconcile_state = try unified.jsonEscape(self.allocator, reconcile_state);
        defer self.allocator.free(escaped_reconcile_state);

        return std.fmt.allocPrint(
            self.allocator,
            "{{\"project_id\":\"{s}\",\"sources\":{{\"workspace_status\":\"{s}\",\"project_fs\":\"{s}\",\"project_nodes\":\"{s}\",\"nodes_meta\":\"{s}\"}},\"counts\":{{\"policy_nodes\":{d},\"policy_links\":{d},\"visible_agents\":{d},\"project_agent_links\":{d},\"project_node_links\":{d},\"project_mount_links\":{d}}},\"health\":{{\"state\":\"{s}\",\"reconcile_state\":\"{s}\",\"queue_depth\":{d}}}}}",
            .{
                escaped_project_id,
                source_workspace_status,
                source_project_fs,
                source_project_nodes,
                source_nodes_meta,
                policy.nodes.items.len,
                policy.project_links.items.len,
                policy.visible_agents.items.len,
                policy_agent_links,
                project_node_links,
                project_mount_links,
                escaped_health_state,
                escaped_reconcile_state,
                queue_depth,
            },
        );
    }

    fn extractWorkspaceAlerts(self: *Session, workspace_status_json: []const u8) !?[]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, workspace_status_json, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;

        var missing: i64 = 0;
        var degraded: i64 = 0;
        var drift_count: i64 = 0;
        var queue_depth: i64 = 0;
        var reconcile_state: []const u8 = "unknown";

        if (parsed.value.object.get("availability")) |availability_value| {
            if (availability_value == .object) {
                if (availability_value.object.get("missing")) |value| {
                    if (value == .integer and value.integer >= 0) missing = value.integer;
                }
                if (availability_value.object.get("degraded")) |value| {
                    if (value == .integer and value.integer >= 0) degraded = value.integer;
                }
            }
        }
        if (parsed.value.object.get("drift")) |drift_value| {
            if (drift_value == .object) {
                if (drift_value.object.get("count")) |value| {
                    if (value == .integer and value.integer >= 0) drift_count = value.integer;
                }
            }
        }
        if (parsed.value.object.get("queue_depth")) |value| {
            if (value == .integer and value.integer >= 0) queue_depth = value.integer;
        }
        if (parsed.value.object.get("reconcile_state")) |value| {
            if (value == .string and value.string.len > 0) reconcile_state = value.string;
        }

        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "[");
        var first = true;

        if (missing > 0) {
            if (!first) try out.append(self.allocator, ',');
            first = false;
            try out.writer(self.allocator).print(
                "{{\"id\":\"missing_mounts\",\"severity\":\"error\",\"count\":{d},\"message\":\"missing mounts detected\"}}",
                .{missing},
            );
        }
        if (degraded > 0) {
            if (!first) try out.append(self.allocator, ',');
            first = false;
            try out.writer(self.allocator).print(
                "{{\"id\":\"degraded_mounts\",\"severity\":\"warning\",\"count\":{d},\"message\":\"degraded mounts detected\"}}",
                .{degraded},
            );
        }
        if (drift_count > 0) {
            if (!first) try out.append(self.allocator, ',');
            first = false;
            try out.writer(self.allocator).print(
                "{{\"id\":\"workspace_drift\",\"severity\":\"warning\",\"count\":{d},\"message\":\"workspace drift detected\"}}",
                .{drift_count},
            );
        }
        if (std.mem.eql(u8, reconcile_state, "degraded")) {
            if (!first) try out.append(self.allocator, ',');
            first = false;
            try out.appendSlice(self.allocator, "{\"id\":\"reconcile_degraded\",\"severity\":\"warning\",\"message\":\"reconcile state degraded\"}");
        }
        if (queue_depth > 0) {
            if (!first) try out.append(self.allocator, ',');
            first = false;
            try out.writer(self.allocator).print(
                "{{\"id\":\"reconcile_queue\",\"severity\":\"info\",\"count\":{d},\"message\":\"reconcile queue pending\"}}",
                .{queue_depth},
            );
        }

        try out.appendSlice(self.allocator, "]");
        const rendered = try out.toOwnedSlice(self.allocator);
        return rendered;
    }

    fn loadProjectWorkspaceStatus(self: *Session, project_id: []const u8) !?[]u8 {
        const plane = self.control_plane orelse return null;
        const escaped_project_id = try unified.jsonEscape(self.allocator, project_id);
        defer self.allocator.free(escaped_project_id);
        const request_json = if (self.project_token) |token| blk: {
            const escaped_token = try unified.jsonEscape(self.allocator, token);
            defer self.allocator.free(escaped_token);
            break :blk try std.fmt.allocPrint(
                self.allocator,
                "{{\"project_id\":\"{s}\",\"project_token\":\"{s}\"}}",
                .{ escaped_project_id, escaped_token },
            );
        } else try std.fmt.allocPrint(
            self.allocator,
            "{{\"project_id\":\"{s}\"}}",
            .{escaped_project_id},
        );
        defer self.allocator.free(request_json);

        if (plane.workspaceStatusWithRole(self.agent_id, request_json, self.is_admin) catch null) |status_json| {
            if (try self.workspaceStatusMatchesProject(status_json, project_id)) {
                return status_json;
            }
            self.allocator.free(status_json);
        }

        if (plane.workspaceStatusWithRole(self.agent_id, null, self.is_admin) catch null) |status_json| {
            if (try self.workspaceStatusMatchesProject(status_json, project_id)) {
                return status_json;
            }
            self.allocator.free(status_json);
        }

        return null;
    }

    fn workspaceStatusMatchesProject(
        self: *Session,
        workspace_status_json: []const u8,
        expected_project_id: []const u8,
    ) !bool {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, workspace_status_json, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        const project_id_value = parsed.value.object.get("project_id") orelse return false;
        if (project_id_value != .string) return false;
        return std.mem.eql(u8, project_id_value.string, expected_project_id);
    }

    fn extractWorkspaceAvailability(self: *Session, workspace_status_json: []const u8) !?[]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, workspace_status_json, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const availability_value = parsed.value.object.get("availability") orelse return null;
        if (availability_value != .object) return null;
        const rendered = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(availability_value, .{})});
        return rendered;
    }

    fn extractWorkspaceNodes(self: *Session, workspace_status_json: []const u8) !?[]u8 {
        const NodeSummary = struct {
            node_id: []const u8,
            state_rank: u8,
            mounts: u32,
        };
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, workspace_status_json, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const mounts_value = parsed.value.object.get("mounts") orelse return null;
        if (mounts_value != .array) return null;

        var summaries = std.ArrayListUnmanaged(NodeSummary){};
        defer summaries.deinit(self.allocator);
        for (mounts_value.array.items) |mount_value| {
            if (mount_value != .object) continue;
            const node_id_value = mount_value.object.get("node_id") orelse continue;
            if (node_id_value != .string or node_id_value.string.len == 0) continue;
            const state = if (mount_value.object.get("state")) |value|
                if (value == .string) value.string else "unknown"
            else
                "unknown";
            const rank = mountStateRank(state);

            var merged = false;
            for (summaries.items) |*entry| {
                if (!std.mem.eql(u8, entry.node_id, node_id_value.string)) continue;
                entry.mounts +%= 1;
                if (rank > entry.state_rank) entry.state_rank = rank;
                merged = true;
                break;
            }
            if (!merged) {
                try summaries.append(self.allocator, .{
                    .node_id = node_id_value.string,
                    .state_rank = rank,
                    .mounts = 1,
                });
            }
        }

        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "[");
        for (summaries.items, 0..) |entry, idx| {
            if (idx != 0) try out.append(self.allocator, ',');
            const escaped_node_id = try unified.jsonEscape(self.allocator, entry.node_id);
            defer self.allocator.free(escaped_node_id);
            const state = mountStateNameFromRank(entry.state_rank);
            try out.writer(self.allocator).print(
                "{{\"node_id\":\"{s}\",\"state\":\"{s}\",\"mounts\":{d}}}",
                .{ escaped_node_id, state, entry.mounts },
            );
        }
        try out.appendSlice(self.allocator, "]");
        const rendered = try out.toOwnedSlice(self.allocator);
        return rendered;
    }

    fn mountStateRank(state: []const u8) u8 {
        if (std.mem.eql(u8, state, "missing")) return 3;
        if (std.mem.eql(u8, state, "degraded")) return 2;
        if (std.mem.eql(u8, state, "online")) return 1;
        return 0;
    }

    fn mountStateNameFromRank(rank: u8) []const u8 {
        return switch (rank) {
            3 => "missing",
            2 => "degraded",
            1 => "online",
            else => "unknown",
        };
    }

    fn extractWorkspaceMounts(self: *Session, workspace_status_json: []const u8) !?[]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, workspace_status_json, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const mounts_value = parsed.value.object.get("mounts") orelse return null;
        if (mounts_value != .array) return null;
        const rendered = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(mounts_value, .{})});
        return rendered;
    }

    fn extractWorkspaceDesiredMounts(self: *Session, workspace_status_json: []const u8) !?[]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, workspace_status_json, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const mounts_value = parsed.value.object.get("desired_mounts") orelse return null;
        if (mounts_value != .array) return null;
        const rendered = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(mounts_value, .{})});
        return rendered;
    }

    fn extractWorkspaceActualMounts(self: *Session, workspace_status_json: []const u8) !?[]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, workspace_status_json, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const mounts_value = parsed.value.object.get("actual_mounts") orelse return null;
        if (mounts_value != .array) return null;
        const rendered = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(mounts_value, .{})});
        return rendered;
    }

    fn extractWorkspaceDrift(self: *Session, workspace_status_json: []const u8) !?[]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, workspace_status_json, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const drift_value = parsed.value.object.get("drift") orelse return null;
        if (drift_value != .object) return null;
        const rendered = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(drift_value, .{})});
        return rendered;
    }

    fn extractWorkspaceReconcile(self: *Session, workspace_status_json: []const u8) !?[]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, workspace_status_json, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;

        const reconcile_state = blk: {
            if (parsed.value.object.get("reconcile_state")) |value| {
                if (value == .string and value.string.len > 0) break :blk value.string;
            }
            break :blk "unknown";
        };
        const last_reconcile_ms: i64 = blk: {
            if (parsed.value.object.get("last_reconcile_ms")) |value| {
                if (value == .integer) break :blk value.integer;
            }
            break :blk 0;
        };
        const last_success_ms: i64 = blk: {
            if (parsed.value.object.get("last_success_ms")) |value| {
                if (value == .integer) break :blk value.integer;
            }
            break :blk 0;
        };
        const queue_depth: i64 = blk: {
            if (parsed.value.object.get("queue_depth")) |value| {
                if (value == .integer and value.integer >= 0) break :blk value.integer;
            }
            break :blk 0;
        };
        const last_error_json = if (parsed.value.object.get("last_error")) |value|
            try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(value, .{})})
        else
            try self.allocator.dupe(u8, "null");
        defer self.allocator.free(last_error_json);
        const escaped_state = try unified.jsonEscape(self.allocator, reconcile_state);
        defer self.allocator.free(escaped_state);

        const rendered = try std.fmt.allocPrint(
            self.allocator,
            "{{\"reconcile_state\":\"{s}\",\"last_reconcile_ms\":{d},\"last_success_ms\":{d},\"last_error\":{s},\"queue_depth\":{d}}}",
            .{ escaped_state, last_reconcile_ms, last_success_ms, last_error_json, queue_depth },
        );
        return rendered;
    }

    fn extractWorkspaceHealth(self: *Session, workspace_status_json: []const u8) !?[]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, workspace_status_json, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;

        var mounts_total: i64 = 0;
        var online: i64 = 0;
        var degraded: i64 = 0;
        var missing: i64 = 0;
        if (parsed.value.object.get("availability")) |availability_value| {
            if (availability_value == .object) {
                if (availability_value.object.get("mounts_total")) |value| {
                    if (value == .integer and value.integer >= 0) mounts_total = value.integer;
                }
                if (availability_value.object.get("online")) |value| {
                    if (value == .integer and value.integer >= 0) online = value.integer;
                }
                if (availability_value.object.get("degraded")) |value| {
                    if (value == .integer and value.integer >= 0) degraded = value.integer;
                }
                if (availability_value.object.get("missing")) |value| {
                    if (value == .integer and value.integer >= 0) missing = value.integer;
                }
            }
        }

        var drift_count: i64 = 0;
        if (parsed.value.object.get("drift")) |drift_value| {
            if (drift_value == .object) {
                if (drift_value.object.get("count")) |value| {
                    if (value == .integer and value.integer >= 0) drift_count = value.integer;
                }
            }
        }

        const reconcile_state = blk: {
            if (parsed.value.object.get("reconcile_state")) |value| {
                if (value == .string and value.string.len > 0) break :blk value.string;
            }
            break :blk "unknown";
        };
        const queue_depth: i64 = blk: {
            if (parsed.value.object.get("queue_depth")) |value| {
                if (value == .integer and value.integer >= 0) break :blk value.integer;
            }
            break :blk 0;
        };
        const state = blk: {
            if (missing > 0) break :blk "missing";
            if (degraded > 0 or drift_count > 0 or queue_depth > 0 or std.mem.eql(u8, reconcile_state, "degraded")) {
                break :blk "degraded";
            }
            if (std.mem.eql(u8, reconcile_state, "unknown")) break :blk "unknown";
            break :blk "healthy";
        };

        const escaped_state = try unified.jsonEscape(self.allocator, state);
        defer self.allocator.free(escaped_state);
        const escaped_reconcile_state = try unified.jsonEscape(self.allocator, reconcile_state);
        defer self.allocator.free(escaped_reconcile_state);

        const rendered = try std.fmt.allocPrint(
            self.allocator,
            "{{\"state\":\"{s}\",\"availability\":{{\"mounts_total\":{d},\"online\":{d},\"degraded\":{d},\"missing\":{d}}},\"drift_count\":{d},\"reconcile_state\":\"{s}\",\"queue_depth\":{d}}}",
            .{ escaped_state, mounts_total, online, degraded, missing, drift_count, escaped_reconcile_state, queue_depth },
        );
        return rendered;
    }

    fn buildFallbackWorkspaceStatusJson(self: *Session, policy: workspace_policy.WorkspacePolicy) ![]u8 {
        const escaped_agent = try unified.jsonEscape(self.allocator, self.agent_id);
        defer self.allocator.free(escaped_agent);
        const escaped_project = try unified.jsonEscape(self.allocator, policy.project_id);
        defer self.allocator.free(escaped_project);

        return std.fmt.allocPrint(
            self.allocator,
            "{{\"agent_id\":\"{s}\",\"project_id\":\"{s}\",\"template_id\":null,\"source\":\"policy\",\"workspace_root\":null,\"mounts\":[],\"desired_mounts\":[],\"actual_mounts\":[],\"drift\":{{\"count\":0,\"items\":[]}},\"availability\":{{\"mounts_total\":0,\"online\":0,\"degraded\":0,\"missing\":0}},\"reconcile_state\":\"unknown\",\"last_reconcile_ms\":0,\"last_success_ms\":0,\"last_error\":null,\"queue_depth\":0}}",
            .{ escaped_agent, escaped_project },
        );
    }

    const NodeResourceView = struct {
        fs: bool = false,
        camera: bool = false,
        screen: bool = false,
        user: bool = false,
        terminals: std.ArrayListUnmanaged([]u8) = .{},
        roots: std.ArrayListUnmanaged([]u8) = .{},

        fn deinit(self: *NodeResourceView, allocator: std.mem.Allocator) void {
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

    fn projectAllowsAction(self: *Session, action: control_plane_mod.ProjectAction) bool {
        const plane = self.control_plane orelse return true;
        const project_id = self.project_id orelse return true;
        return plane.projectAllowsAction(project_id, self.agent_id, action, self.project_token, self.is_admin);
    }

    fn canAccessVenomWithPermissions(self: *Session, permissions_json: []const u8) bool {
        if (!self.projectAllowsAction(.invoke)) return false;
        if (self.is_admin) return true;
        if (permissions_json.len == 0) return true;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, permissions_json, .{}) catch return true;
        defer parsed.deinit();
        if (parsed.value != .object) return true;

        const obj = parsed.value.object;

        const require_project_token = blk: {
            if (obj.get("require_project_token")) |value| {
                if (value == .bool) break :blk value.bool;
            }
            if (obj.get("project_token_required")) |value| {
                if (value == .bool) break :blk value.bool;
            }
            break :blk false;
        };
        if (require_project_token and self.project_token == null) return false;

        if (obj.get("allow_roles")) |roles| {
            if (roles == .array) {
                for (roles.array.items) |role| {
                    if (role != .string) continue;
                    if (std.mem.eql(u8, role.string, "user")) return true;
                    if (std.mem.eql(u8, role.string, "*")) return true;
                    if (std.mem.eql(u8, role.string, "all")) return true;
                }
                return false;
            }
        }

        if (obj.get("default")) |value| {
            if (value == .string) {
                if (std.mem.eql(u8, value.string, "deny-by-default")) return false;
                if (std.mem.eql(u8, value.string, "deny")) return false;
            }
        }

        return true;
    }

    pub fn canInvokeVenomDirectory(self: *Session, venom_dir_id: u32) bool {
        const permissions_id = self.lookupChild(venom_dir_id, "PERMISSIONS.json") orelse {
            return self.canAccessVenomWithPermissions("");
        };
        const permissions_node = self.nodes.get(permissions_id) orelse {
            return self.canAccessVenomWithPermissions("");
        };
        return self.canAccessVenomWithPermissions(permissions_node.content);
    }

    fn canInvokeTerminalNamespace(self: *Session, terminal_node_id: u32) bool {
        const terminal_node = self.nodes.get(terminal_node_id) orelse return false;
        const control_dir_id = terminal_node.parent orelse return false;
        const venom_dir_id = (self.nodes.get(control_dir_id) orelse return false).parent orelse return false;
        if (!self.canInvokeVenomDirectory(venom_dir_id)) return false;
        if (!self.is_admin and std.mem.eql(u8, self.actor_type, "user")) return false;
        return true;
    }

    fn specialWriteCommitsOnClose(special: SpecialKind) bool {
        return switch (special) {
            .none,
            .agent_venoms_index,
            .node_venom_events_log,
            => false,
            else => true,
        };
    }

    fn appendPendingSpecialWrite(
        self: *Session,
        state: *FidState,
        node_id: u32,
        offset: u64,
        data: []const u8,
    ) !void {
        const base_offset = std.math.cast(usize, offset) orelse return error.InvalidOffset;
        const current_opt = state.pending_special_write;
        const current_len: usize = if (current_opt) |current| current.len else 0;
        const required_len = std.math.add(usize, base_offset, data.len) catch return error.InvalidOffset;

        var next_owned: ?[]u8 = null;
        errdefer if (next_owned) |value| self.allocator.free(value);

        var target: []u8 = if (current_opt) |current| current else &.{};
        if (required_len > current_len) {
            const next = try self.allocator.alloc(u8, required_len);
            @memset(next, 0);
            if (current_opt) |current| {
                if (current.len > 0) @memcpy(next[0..current.len], current);
            }
            next_owned = next;
            target = next;
        }

        if (data.len > 0) {
            @memcpy(target[base_offset .. base_offset + data.len], data);
        }
        try self.setFileContent(state.node_id, target);
        if (next_owned) |next| {
            if (current_opt) |current| self.allocator.free(current);
            state.pending_special_write = next;
        }
        _ = node_id;
    }

    fn isTerminalV2Special(special: SpecialKind) bool {
        return switch (special) {
            .terminal_v2_invoke,
            .terminal_v2_create,
            .terminal_v2_resume,
            .terminal_v2_close,
            .terminal_v2_exec,
            .terminal_v2_write,
            .terminal_v2_read,
            .terminal_v2_resize,
            => true,
            else => false,
        };
    }

    fn appendVenomIndexEntry(
        self: *Session,
        out: *std.ArrayListUnmanaged(u8),
        first: *bool,
        venom_id: []const u8,
        kind: []const u8,
        state: []const u8,
        endpoint: []const u8,
    ) !void {
        if (!first.*) try out.append(self.allocator, ',');
        first.* = false;
        const escaped_venom_id = try unified.jsonEscape(self.allocator, venom_id);
        defer self.allocator.free(escaped_venom_id);
        const escaped_kind = try unified.jsonEscape(self.allocator, kind);
        defer self.allocator.free(escaped_kind);
        const escaped_state = try unified.jsonEscape(self.allocator, state);
        defer self.allocator.free(escaped_state);
        const escaped_endpoint = try unified.jsonEscape(self.allocator, endpoint);
        defer self.allocator.free(escaped_endpoint);
        try out.writer(self.allocator).print(
            "{{\"venom_id\":\"{s}\",\"kind\":\"{s}\",\"state\":\"{s}\",\"endpoint\":\"{s}\"}}",
            .{ escaped_venom_id, escaped_kind, escaped_state, escaped_endpoint },
        );
    }

    fn addNodeVenoms(self: *Session, node_dir: u32, node: workspace_policy.WorkspaceNodePolicy) !NodeResourceView {
        var view = NodeResourceView{};
        errdefer view.deinit(self.allocator);

        const venoms_root = try self.addDir(node_dir, "venoms", false);
        try self.addDirectoryDescriptors(
            venoms_root,
            "Node Venoms",
            "{\"kind\":\"collection\",\"entries\":\"venom_id\",\"shape\":\"/nodes/<node_id>/venoms/<venom_id>/{README.md,SCHEMA.json,TEMPLATE.json,CAPS.json,MOUNTS.json,OPS.json,RUNTIME.json,HOST.json,PERMISSIONS.json,STATUS.json}\"}",
            "{\"read\":true,\"write\":false}",
            "Node Venom descriptors mirrored from the node Venom catalog.",
        );
        var services_index = std.ArrayListUnmanaged(u8){};
        defer services_index.deinit(self.allocator);
        try services_index.append(self.allocator, '[');
        var services_index_first = true;

        switch (try self.loadNodeVenomsFromControlPlane(node.id)) {
            .catalog => |catalog_value| {
                var catalog = catalog_value;
                defer catalog.deinit(self.allocator);
                for (catalog.items.items) |venom| {
                    if (!self.canAccessVenomWithPermissions(venom.permissions_json)) continue;
                    try self.addNodeVenomEntry(
                        venoms_root,
                        venom.venom_id,
                        venom.package_id,
                        venom.instance_id,
                        venom.kind,
                        venom.version,
                        venom.state,
                        venom.provider_scope,
                        venom.categories_json,
                        venom.hosts_json,
                        venom.projection_modes_json,
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
                        self.allocator,
                        node.id,
                        venom.kind,
                        venom.venom_id,
                        venom.endpoint,
                        venom.mounts_json,
                    );
                    try self.appendVenomIndexEntry(
                        &services_index,
                        &services_index_first,
                        venom.venom_id,
                        venom.kind,
                        venom.state,
                        venom.endpoint,
                    );
                }
                try services_index.append(self.allocator, ']');
                const services_index_json = try services_index.toOwnedSlice(self.allocator);
                defer self.allocator.free(services_index_json);
                _ = try self.addFile(venoms_root, "VENOMS.json", services_index_json, false, .none);
                return view;
            },
            .empty => {
                try services_index.append(self.allocator, ']');
                const services_index_json = try services_index.toOwnedSlice(self.allocator);
                defer self.allocator.free(services_index_json);
                _ = try self.addFile(venoms_root, "VENOMS.json", services_index_json, false, .none);
                return view;
            },
            .unavailable => {},
        }

        if (node.resources.fs) {
            const caps = "{\"rw\":true}";
            const mounts = try std.fmt.allocPrint(
                self.allocator,
                "[{{\"mount_id\":\"fs\",\"mount_path\":\"/nodes/{s}/fs\",\"state\":\"online\"}}]",
                .{node.id},
            );
            defer self.allocator.free(mounts);
            const endpoint = try std.fmt.allocPrint(self.allocator, "/nodes/{s}/fs", .{node.id});
            defer self.allocator.free(endpoint);
            const permissions = "{\"default\":\"allow-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"scope\":\"project\"}";
            if (self.canAccessVenomWithPermissions(permissions)) {
                try self.addNodeVenomEntry(
                    venoms_root,
                    "fs",
                    "fs",
                    "local:fs",
                    "fs",
                    "1",
                    "online",
                    "node_export",
                    "[\"filesystem\"]",
                    "[\"node\"]",
                    "[\"node_export\"]",
                    "{}",
                    endpoint,
                    caps,
                    mounts,
                    "{\"model\":\"namespace\"}",
                    "{\"type\":\"builtin\"}",
                    permissions,
                    "{\"model\":\"filesystem\"}",
                    null,
                    "Project node filesystem export.",
                );
                try self.addNodeVenomEntry(
                    venoms_root,
                    "fs",
                    "fs",
                    "local:fs",
                    "fs",
                    "1",
                    "online",
                    "node_export",
                    "[\"filesystem\"]",
                    "[\"node\"]",
                    "[\"node_export\"]",
                    "{}",
                    endpoint,
                    caps,
                    mounts,
                    "{\"model\":\"namespace\"}",
                    "{\"type\":\"builtin\"}",
                    permissions,
                    "{\"model\":\"filesystem\"}",
                    null,
                    "Project node filesystem export.",
                );
                try view.observe(self.allocator, node.id, "fs", "fs", endpoint, mounts);
                try self.appendVenomIndexEntry(&services_index, &services_index_first, "fs", "fs", "online", endpoint);
            }
        }
        if (node.resources.camera) {
            const caps = "{\"still\":true}";
            const mounts = try std.fmt.allocPrint(
                self.allocator,
                "[{{\"mount_id\":\"camera\",\"mount_path\":\"/nodes/{s}/camera\",\"state\":\"online\"}}]",
                .{node.id},
            );
            defer self.allocator.free(mounts);
            const endpoint = try std.fmt.allocPrint(self.allocator, "/nodes/{s}/camera", .{node.id});
            defer self.allocator.free(endpoint);
            const permissions = "{\"default\":\"allow-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"scope\":\"node\"}";
            if (self.canAccessVenomWithPermissions(permissions)) {
                try self.addNodeVenomEntry(
                    venoms_root,
                    "camera",
                    "camera",
                    "local:camera",
                    "camera",
                    "1",
                    "online",
                    "node_export",
                    "[\"camera\"]",
                    "[\"node\"]",
                    "[\"node_export\"]",
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
                try self.addNodeVenomEntry(
                    venoms_root,
                    "camera",
                    "camera",
                    "local:camera",
                    "camera",
                    "1",
                    "online",
                    "node_export",
                    "[\"camera\"]",
                    "[\"node\"]",
                    "[\"node_export\"]",
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
                try view.observe(self.allocator, node.id, "camera", "camera", endpoint, mounts);
                try self.appendVenomIndexEntry(&services_index, &services_index_first, "camera", "camera", "online", endpoint);
            }
        }
        if (node.resources.screen) {
            const caps = "{\"capture\":true}";
            const mounts = try std.fmt.allocPrint(
                self.allocator,
                "[{{\"mount_id\":\"screen\",\"mount_path\":\"/nodes/{s}/screen\",\"state\":\"online\"}}]",
                .{node.id},
            );
            defer self.allocator.free(mounts);
            const endpoint = try std.fmt.allocPrint(self.allocator, "/nodes/{s}/screen", .{node.id});
            defer self.allocator.free(endpoint);
            const permissions = "{\"default\":\"allow-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"scope\":\"node\"}";
            if (self.canAccessVenomWithPermissions(permissions)) {
                try self.addNodeVenomEntry(
                    venoms_root,
                    "screen",
                    "screen",
                    "local:screen",
                    "screen",
                    "1",
                    "online",
                    "node_export",
                    "[\"screen\"]",
                    "[\"node\"]",
                    "[\"node_export\"]",
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
                try self.addNodeVenomEntry(
                    venoms_root,
                    "screen",
                    "screen",
                    "local:screen",
                    "screen",
                    "1",
                    "online",
                    "node_export",
                    "[\"screen\"]",
                    "[\"node\"]",
                    "[\"node_export\"]",
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
                try view.observe(self.allocator, node.id, "screen", "screen", endpoint, mounts);
                try self.appendVenomIndexEntry(&services_index, &services_index_first, "screen", "screen", "online", endpoint);
            }
        }
        if (node.resources.user) {
            const caps = "{\"interaction\":true}";
            const mounts = try std.fmt.allocPrint(
                self.allocator,
                "[{{\"mount_id\":\"user\",\"mount_path\":\"/nodes/{s}/user\",\"state\":\"online\"}}]",
                .{node.id},
            );
            defer self.allocator.free(mounts);
            const endpoint = try std.fmt.allocPrint(self.allocator, "/nodes/{s}/user", .{node.id});
            defer self.allocator.free(endpoint);
            const permissions = "{\"default\":\"allow-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"scope\":\"node\"}";
            if (self.canAccessVenomWithPermissions(permissions)) {
                try self.addNodeVenomEntry(
                    venoms_root,
                    "user",
                    "user",
                    "local:user",
                    "user",
                    "1",
                    "online",
                    "node_export",
                    "[\"user_interaction\"]",
                    "[\"node\"]",
                    "[\"node_export\"]",
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
                try self.addNodeVenomEntry(
                    venoms_root,
                    "user",
                    "user",
                    "local:user",
                    "user",
                    "1",
                    "online",
                    "node_export",
                    "[\"user_interaction\"]",
                    "[\"node\"]",
                    "[\"node_export\"]",
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
                try view.observe(self.allocator, node.id, "user", "user", endpoint, mounts);
                try self.appendVenomIndexEntry(&services_index, &services_index_first, "user", "user", "online", endpoint);
            }
        }

        for (node.terminals.items) |terminal_id| {
            const venom_id = try std.fmt.allocPrint(self.allocator, "terminal-{s}", .{terminal_id});
            defer self.allocator.free(venom_id);
            const endpoint = try std.fmt.allocPrint(self.allocator, "/nodes/{s}/terminal/{s}", .{ node.id, terminal_id });
            defer self.allocator.free(endpoint);
            const escaped_terminal_id = try unified.jsonEscape(self.allocator, terminal_id);
            defer self.allocator.free(escaped_terminal_id);
            const caps = try std.fmt.allocPrint(
                self.allocator,
                "{{\"pty\":true,\"terminal_id\":\"{s}\"}}",
                .{escaped_terminal_id},
            );
            defer self.allocator.free(caps);
            const mounts = try std.fmt.allocPrint(
                self.allocator,
                "[{{\"mount_id\":\"{s}\",\"mount_path\":\"/nodes/{s}/terminal/{s}\",\"state\":\"online\"}}]",
                .{ venom_id, node.id, terminal_id },
            );
            defer self.allocator.free(mounts);
            const permissions = "{\"default\":\"allow-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"scope\":\"node\"}";
            if (self.canAccessVenomWithPermissions(permissions)) {
                try self.addNodeVenomEntry(
                    venoms_root,
                    venom_id,
                    "terminal",
                    venom_id,
                    "terminal",
                    "1",
                    "online",
                    "node_export",
                    "[\"terminal\",\"exec\"]",
                    "[\"node\"]",
                    "[\"node_export\"]",
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
                try self.addNodeVenomEntry(
                    venoms_root,
                    venom_id,
                    "terminal",
                    venom_id,
                    "terminal",
                    "1",
                    "online",
                    "node_export",
                    "[\"terminal\",\"exec\"]",
                    "[\"node\"]",
                    "[\"node_export\"]",
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
                try view.observe(self.allocator, node.id, "terminal", venom_id, endpoint, mounts);
                try self.appendVenomIndexEntry(&services_index, &services_index_first, venom_id, "terminal", "online", endpoint);
            }
        }

        try services_index.append(self.allocator, ']');
        const services_index_json = try services_index.toOwnedSlice(self.allocator);
        defer self.allocator.free(services_index_json);
        _ = try self.addFile(venoms_root, "VENOMS.json", services_index_json, false, .none);
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
            provider_scope: []u8,
            categories_json: []u8,
            hosts_json: []u8,
            projection_modes_json: []u8,
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
                allocator.free(self.provider_scope);
                allocator.free(self.categories_json);
                allocator.free(self.hosts_json);
                allocator.free(self.projection_modes_json);
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

    fn loadNodeVenomsFromControlPlane(self: *Session, node_id: []const u8) !NodeVenomCatalogResult {
        const plane = self.control_plane orelse return .unavailable;
        const catalog_node_id = (try self.resolveCatalogControlPlaneNodeId(node_id)) orelse return .unavailable;
        defer self.allocator.free(catalog_node_id);
        const escaped_node_id = try unified.jsonEscape(self.allocator, catalog_node_id);
        defer self.allocator.free(escaped_node_id);
        const request_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"node_id\":\"{s}\"}}",
            .{escaped_node_id},
        );
        defer self.allocator.free(request_json);

        const response_json = plane.nodeVenomGet(request_json) catch return .unavailable;
        defer self.allocator.free(response_json);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response_json, .{}) catch return .unavailable;
        defer parsed.deinit();
        if (parsed.value != .object) return .unavailable;
        const venoms_val = parsed.value.object.get("venoms") orelse return .unavailable;
        if (venoms_val != .array) return .unavailable;
        if (venoms_val.array.items.len == 0) return .empty;

        var catalog = NodeVenomCatalog{};
        errdefer catalog.deinit(self.allocator);

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
                try self.allocator.dupe(u8, endpoint)
            else
                try std.fmt.allocPrint(self.allocator, "/nodes/{s}/venoms/{s}", .{ node_id, venom_id_val.string });
            errdefer self.allocator.free(resolved_endpoint);

            const package_id = if (item.object.get("package_id")) |value|
                if (value == .string and value.string.len > 0)
                    try self.allocator.dupe(u8, value.string)
                else
                    try self.allocator.dupe(u8, venom_id_val.string)
            else
                try self.allocator.dupe(u8, venom_id_val.string);
            errdefer self.allocator.free(package_id);

            const instance_id = if (item.object.get("instance_id")) |value|
                if (value == .string and value.string.len > 0)
                    try self.allocator.dupe(u8, value.string)
                else
                    null
            else
                null;
            errdefer if (instance_id) |value| self.allocator.free(value);

            const provider_scope = if (item.object.get("provider_scope")) |value|
                if (value == .string and value.string.len > 0)
                    try self.allocator.dupe(u8, value.string)
                else
                    try self.allocator.dupe(u8, "node_export")
            else
                try self.allocator.dupe(u8, "node_export");
            errdefer self.allocator.free(provider_scope);

            const categories_json = if (item.object.get("categories")) |value|
                if (value == .array)
                    try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(value, .{})})
                else
                    try self.allocator.dupe(u8, "[]")
            else
                try self.allocator.dupe(u8, "[]");
            errdefer self.allocator.free(categories_json);

            const hosts_json = if (item.object.get("hosts")) |value|
                if (value == .array)
                    try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(value, .{})})
                else
                    try self.allocator.dupe(u8, "[]")
            else
                try self.allocator.dupe(u8, "[]");
            errdefer self.allocator.free(hosts_json);

            const projection_modes_json = if (item.object.get("projection_modes")) |value|
                if (value == .array)
                    try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(value, .{})})
                else
                    try self.allocator.dupe(u8, "[]")
            else
                try self.allocator.dupe(u8, "[]");
            errdefer self.allocator.free(projection_modes_json);

            const requirements_json = if (item.object.get("requirements")) |value|
                if (value == .object)
                    try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(value, .{})})
                else
                    try self.allocator.dupe(u8, "{}")
            else
                try self.allocator.dupe(u8, "{}");
            errdefer self.allocator.free(requirements_json);

            const version = if (item.object.get("version")) |value|
                if (value == .string and value.string.len > 0)
                    try self.allocator.dupe(u8, value.string)
                else
                    try self.allocator.dupe(u8, "1")
            else
                try self.allocator.dupe(u8, "1");
            errdefer self.allocator.free(version);

            const caps_json = if (item.object.get("capabilities")) |caps|
                if (caps == .object)
                    try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(caps, .{})})
                else
                    try self.allocator.dupe(u8, "{}")
            else
                try self.allocator.dupe(u8, "{}");
            errdefer self.allocator.free(caps_json);

            const mounts_json = if (item.object.get("mounts")) |mounts|
                if (mounts == .array)
                    try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(mounts, .{})})
                else
                    try self.allocator.dupe(u8, "[]")
            else
                try self.allocator.dupe(u8, "[]");
            errdefer self.allocator.free(mounts_json);

            const ops_json = if (item.object.get("ops")) |ops|
                if (ops == .object)
                    try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(ops, .{})})
                else
                    try self.allocator.dupe(u8, "{}")
            else
                try self.allocator.dupe(u8, "{}");
            errdefer self.allocator.free(ops_json);

            const runtime_json = if (item.object.get("runtime")) |runtime|
                if (runtime == .object)
                    try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(runtime, .{})})
                else
                    try self.allocator.dupe(u8, "{}")
            else
                try self.allocator.dupe(u8, "{}");
            errdefer self.allocator.free(runtime_json);

            const permissions_json = if (item.object.get("permissions")) |permissions|
                if (permissions == .object)
                    try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(permissions, .{})})
                else
                    try self.allocator.dupe(u8, "{}")
            else
                try self.allocator.dupe(u8, "{}");
            errdefer self.allocator.free(permissions_json);

            const schema_json = if (item.object.get("schema")) |schema|
                if (schema == .object)
                    try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(schema, .{})})
                else
                    try self.allocator.dupe(u8, "{}")
            else
                try self.allocator.dupe(u8, "{}");
            errdefer self.allocator.free(schema_json);

            const invoke_template_json = if (item.object.get("invoke_template")) |invoke_template|
                if (invoke_template == .object)
                    try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(invoke_template, .{})})
                else
                    null
            else
                null;
            errdefer if (invoke_template_json) |value| self.allocator.free(value);

            const help_md = if (item.object.get("help_md")) |help|
                if (help == .string and help.string.len > 0)
                    try self.allocator.dupe(u8, help.string)
                else
                    null
            else
                null;
            errdefer if (help_md) |value| self.allocator.free(value);

            try catalog.items.append(self.allocator, .{
                .venom_id = try self.allocator.dupe(u8, venom_id_val.string),
                .package_id = package_id,
                .instance_id = instance_id,
                .kind = try self.allocator.dupe(u8, kind_val.string),
                .version = version,
                .state = try self.allocator.dupe(u8, state),
                .provider_scope = provider_scope,
                .categories_json = categories_json,
                .hosts_json = hosts_json,
                .projection_modes_json = projection_modes_json,
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
            catalog.deinit(self.allocator);
            return .empty;
        }
        return .{ .catalog = catalog };
    }

    fn addNodeVenomEntry(
        self: *Session,
        services_root: u32,
        venom_id: []const u8,
        package_id: []const u8,
        instance_id: ?[]const u8,
        kind: []const u8,
        version: []const u8,
        state: []const u8,
        provider_scope: []const u8,
        categories_json: []const u8,
        hosts_json: []const u8,
        projection_modes_json: []const u8,
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
        const venom_dir = try self.addDir(services_root, venom_id, false);

        const escaped_venom_id = try unified.jsonEscape(self.allocator, venom_id);
        defer self.allocator.free(escaped_venom_id);
        const escaped_kind = try unified.jsonEscape(self.allocator, kind);
        defer self.allocator.free(escaped_kind);
        const escaped_state = try unified.jsonEscape(self.allocator, state);
        defer self.allocator.free(escaped_state);
        const escaped_endpoint = try unified.jsonEscape(self.allocator, endpoint);
        defer self.allocator.free(escaped_endpoint);

        const readme = if (help_md) |value|
            value
        else
            "# Venom metadata for this node capability.\n";
        _ = try self.addFile(venom_dir, "README.md", readme, false, .none);
        const package_json = try self.renderNodeVenomPackageJson(
            package_id,
            kind,
            version,
            provider_scope,
            categories_json,
            hosts_json,
            projection_modes_json,
            requirements_json,
            caps_json,
            ops_json,
            runtime_json,
            permissions_json,
            schema_json,
            help_md,
        );
        defer self.allocator.free(package_json);
        _ = try self.addFile(venom_dir, "PACKAGE.json", package_json, false, .none);
        _ = try self.addFile(venom_dir, "SCHEMA.json", schema_json, false, .none);
        _ = try self.addFile(venom_dir, "CAPS.json", caps_json, false, .none);
        _ = try self.addFile(venom_dir, "MOUNTS.json", mounts_json, false, .none);
        _ = try self.addFile(venom_dir, "OPS.json", ops_json, false, .none);
        _ = try self.addFile(venom_dir, "RUNTIME.json", runtime_json, false, .none);
        if (invoke_template_json) |value| {
            _ = try self.addFile(venom_dir, "TEMPLATE.json", value, false, .none);
        }
        const host_json = try self.renderNodeVenomHostJson(runtime_json);
        defer self.allocator.free(host_json);
        _ = try self.addFile(venom_dir, "HOST.json", host_json, false, .none);
        _ = try self.addFile(venom_dir, "PERMISSIONS.json", permissions_json, false, .none);

        const escaped_package_id = try unified.jsonEscape(self.allocator, package_id);
        defer self.allocator.free(escaped_package_id);
        const escaped_provider_scope = try unified.jsonEscape(self.allocator, provider_scope);
        defer self.allocator.free(escaped_provider_scope);
        const instance_id_json = if (instance_id) |value| blk: {
            const escaped_instance_id = try unified.jsonEscape(self.allocator, value);
            defer self.allocator.free(escaped_instance_id);
            break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped_instance_id});
        } else try self.allocator.dupe(u8, "null");
        defer self.allocator.free(instance_id_json);

        const status = try std.fmt.allocPrint(
            self.allocator,
            "{{\"venom_id\":\"{s}\",\"package_id\":\"{s}\",\"instance_id\":{s},\"kind\":\"{s}\",\"state\":\"{s}\",\"provider_scope\":\"{s}\",\"endpoint\":\"{s}\"}}",
            .{ escaped_venom_id, escaped_package_id, instance_id_json, escaped_kind, escaped_state, escaped_provider_scope, escaped_endpoint },
        );
        defer self.allocator.free(status);
        _ = try self.addFile(venom_dir, "STATUS.json", status, false, .none);
    }

    fn renderNodeVenomPackageJson(
        self: *Session,
        venom_id: []const u8,
        kind: []const u8,
        version: []const u8,
        provider_scope: []const u8,
        categories_json: []const u8,
        hosts_json: []const u8,
        projection_modes_json: []const u8,
        requirements_json: []const u8,
        capabilities_json: []const u8,
        ops_json: []const u8,
        runtime_json: []const u8,
        permissions_json: []const u8,
        schema_json: []const u8,
        help_md: ?[]const u8,
    ) ![]u8 {
        const escaped_venom_id = try unified.jsonEscape(self.allocator, venom_id);
        defer self.allocator.free(escaped_venom_id);
        const escaped_kind = try unified.jsonEscape(self.allocator, kind);
        defer self.allocator.free(escaped_kind);
        const escaped_version = try unified.jsonEscape(self.allocator, version);
        defer self.allocator.free(escaped_version);
        const escaped_provider_scope = try unified.jsonEscape(self.allocator, provider_scope);
        defer self.allocator.free(escaped_provider_scope);

        if (help_md) |help| {
            const escaped_help = try unified.jsonEscape(self.allocator, help);
            defer self.allocator.free(escaped_help);
            return std.fmt.allocPrint(
                self.allocator,
                "{{\"venom_id\":\"{s}\",\"kind\":\"{s}\",\"version\":\"{s}\",\"categories\":{s},\"hosts\":{s},\"projection_modes\":{s},\"requirements\":{s},\"capabilities\":{s},\"ops\":{s},\"runtime\":{s},\"permissions\":{s},\"schema\":{s},\"provider_scope\":\"{s}\",\"help_md\":\"{s}\"}}",
                .{ escaped_venom_id, escaped_kind, escaped_version, categories_json, hosts_json, projection_modes_json, requirements_json, capabilities_json, ops_json, runtime_json, permissions_json, schema_json, escaped_provider_scope, escaped_help },
            );
        }

        return std.fmt.allocPrint(
            self.allocator,
            "{{\"venom_id\":\"{s}\",\"kind\":\"{s}\",\"version\":\"{s}\",\"categories\":{s},\"hosts\":{s},\"projection_modes\":{s},\"requirements\":{s},\"capabilities\":{s},\"ops\":{s},\"runtime\":{s},\"permissions\":{s},\"schema\":{s},\"provider_scope\":\"{s}\"}}",
            .{ escaped_venom_id, escaped_kind, escaped_version, categories_json, hosts_json, projection_modes_json, requirements_json, capabilities_json, ops_json, runtime_json, permissions_json, schema_json, escaped_provider_scope },
        );
    }

    fn renderNodeVenomHostJson(self: *Session, runtime_json: []const u8) ![]u8 {
        var runtime_kind: []const u8 = "builtin";
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, runtime_json, .{}) catch {
            return shared_node.service_runtime_host.renderMetadataJson(self.allocator, runtime_kind);
        };
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("type")) |runtime_type| {
                if (runtime_type == .string and runtime_type.string.len > 0) {
                    runtime_kind = runtime_type.string;
                }
            }
        }
        return shared_node.service_runtime_host.renderMetadataJson(self.allocator, runtime_kind);
    }

    fn copyOptionalServiceFile(self: *Session, source_dir_id: u32, target_dir_id: u32, name: []const u8) !void {
        const source_id = self.lookupChild(source_dir_id, name) orelse return;
        const source_node = self.nodes.get(source_id) orelse return;
        if (source_node.kind != .file) return;
        _ = try self.addFile(target_dir_id, name, source_node.content, false, .none);
    }

    fn seedBuiltinPackageMetadata(self: *Session, venom_dir_id: u32, venom_id: []const u8) !void {
        const spec = venom_packages.findBuiltinPackage(venom_id) orelse return;
        const package_json = try venom_packages.renderPackageMetadataJson(self.allocator, spec);
        defer self.allocator.free(package_json);
        _ = try self.addFile(venom_dir_id, "PACKAGE.json", package_json, false, .none);
    }

    fn cloneWorkerVenomPackage(self: *Session, venom_id: []const u8) !?venom_package.VenomPackage {
        if (self.control_plane) |control_plane| {
            return control_plane.cloneVenomPackage(self.allocator, venom_id);
        }
        return venom_packages.cloneBuiltinPackage(self.allocator, venom_id);
    }

    fn seedPackageMetadata(self: *Session, venom_dir_id: u32, package: venom_package.VenomPackage) !void {
        if (self.lookupChild(venom_dir_id, "PACKAGE.json") != null) return;
        var package_json = std.ArrayListUnmanaged(u8){};
        defer package_json.deinit(self.allocator);
        try venom_package.appendPackageJson(self.allocator, &package_json, package);
        _ = try self.addFile(venom_dir_id, "PACKAGE.json", package_json.items, false, .none);
    }

    fn seedGenericWorkerLoopbackVenomNamespaceAt(
        self: *Session,
        venom_dir_id: u32,
        base_path: []const u8,
        worker_id: []const u8,
        agent_id: []const u8,
        package: venom_package.VenomPackage,
    ) !void {
        const escaped_base_path = try unified.jsonEscape(self.allocator, base_path);
        defer self.allocator.free(escaped_base_path);
        const shape_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"kind\":\"venom\",\"venom_id\":\"{s}\",\"shape\":\"{s}/{{README.md,SCHEMA.json,CAPS.json,OPS.json,RUNTIME.json,PERMISSIONS.json,PACKAGE.json,STATUS.json,status.json,result.json,control/*}}\"}}",
            .{ package.venom_id, escaped_base_path },
        );
        defer self.allocator.free(shape_json);

        const readme = package.help_md orelse "Worker-owned loopback venom projected for an attached external worker.\n";
        try self.ensureWorkerFile(venom_dir_id, "README.md", readme, false, .none);
        try self.ensureWorkerFile(venom_dir_id, "SCHEMA.json", shape_json, false, .none);
        try self.ensureWorkerFile(venom_dir_id, "CAPS.json", package.capabilities_json, false, .none);
        try self.ensureWorkerFile(venom_dir_id, "OPS.json", package.ops_json, false, .none);
        try self.ensureWorkerFile(venom_dir_id, "RUNTIME.json", package.runtime_json, false, .none);
        try self.ensureWorkerFile(venom_dir_id, "PERMISSIONS.json", package.permissions_json, false, .none);
        try self.seedPackageMetadata(venom_dir_id, package);

        const status_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"venom_id\":\"{s}\",\"state\":\"worker_loopback\",\"has_invoke\":true,\"owner\":\"worker\",\"worker_id\":\"{s}\",\"agent_id\":\"{s}\"}}",
            .{ package.venom_id, worker_id, agent_id },
        );
        defer self.allocator.free(status_json);
        try self.ensureWorkerFile(venom_dir_id, "STATUS.json", status_json, false, .none);
        try self.ensureWorkerFile(venom_dir_id, "status.json", "{\"state\":\"idle\",\"tool\":null,\"updated_at_ms\":0,\"error\":null}", true, .none);
        try self.ensureWorkerFile(venom_dir_id, "result.json", "{\"ok\":false,\"result\":null,\"error\":null}", true, .none);

        const control_dir = if (self.lookupChild(venom_dir_id, "control")) |existing|
            existing
        else
            try self.addDir(venom_dir_id, "control", false);
        try self.ensureWorkerFile(control_dir, "README.md", "External worker watches and writes this loopback venom namespace directly.\n", false, .none);
        try self.seedWorkerControlFilesFromOpsJson(control_dir, package.ops_json);
    }

    fn seedWorkerControlFilesFromOpsJson(self: *Session, control_dir: u32, ops_json: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, ops_json, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        if (parsed.value.object.get("invoke")) |invoke_value| {
            if (invoke_value == .string and invoke_value.string.len > 0) {
                try self.ensureWorkerControlFileFromPath(control_dir, invoke_value.string);
            }
        }
        if (parsed.value.object.get("paths")) |paths_value| {
            if (paths_value != .object) return;
            var it = paths_value.object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* != .string or entry.value_ptr.string.len == 0) continue;
                try self.ensureWorkerControlFileFromPath(control_dir, entry.value_ptr.string);
            }
        }
    }

    fn ensureWorkerControlFileFromPath(self: *Session, control_dir: u32, raw_path: []const u8) !void {
        var relative = raw_path;
        if (std.mem.startsWith(u8, relative, "control/")) {
            relative = relative["control/".len..];
        }
        const name = std.fs.path.basename(relative);
        if (name.len == 0) return;
        try self.ensureWorkerFile(control_dir, name, "", true, .none);
    }

    fn seedActiveScopedVenomBindings(
        self: *Session,
        active_agent_venoms_dir: u32,
        project_venoms_dir: u32,
        active_project_id: []const u8,
    ) !void {
        const agent_prefix = try std.fmt.allocPrint(self.allocator, "/agents/{s}/venoms", .{self.agent_id});
        defer self.allocator.free(agent_prefix);
        const project_prefix = try std.fmt.allocPrint(self.allocator, "/projects/{s}/venoms", .{active_project_id});
        defer self.allocator.free(project_prefix);

        inline for ([_][]const u8{ "events", "fs" }) |venom_id| {
            const preferred_agent_node_id = try self.resolvePreferredBoundVenomNodeIdForContext(
                venom_id,
                active_project_id,
                self.agent_id,
            );
            defer if (preferred_agent_node_id) |value| self.allocator.free(value);
            _ = try self.addDir(active_agent_venoms_dir, venom_id, false);
            _ = try self.registerBoundVenomAliasOnly(
                agent_prefix,
                venom_id,
                "agent_binding",
                preferred_agent_node_id,
                active_project_id,
                self.agent_id,
            );

            const preferred_project_node_id = try self.resolvePreferredBoundVenomNodeIdForContext(
                venom_id,
                active_project_id,
                null,
            );
            defer if (preferred_project_node_id) |value| self.allocator.free(value);
            _ = try self.addDir(project_venoms_dir, venom_id, false);
            _ = try self.registerBoundVenomAliasOnly(
                project_prefix,
                venom_id,
                "project_binding",
                preferred_project_node_id,
                active_project_id,
                self.agent_id,
            );
        }
    }

    fn seedBoundNodeVenomNamespace(
        self: *Session,
        global_root: u32,
        venom_id: []const u8,
        preferred_node_id: []const u8,
    ) !bool {
        return self.seedBoundNodeVenomNamespaceAt(global_root, "/global", venom_id, "global_binding", preferred_node_id);
    }

    fn seedBoundNodeVenomNamespaceAt(
        self: *Session,
        alias_root: u32,
        alias_base_path: []const u8,
        venom_id: []const u8,
        scope: []const u8,
        preferred_node_id: ?[]const u8,
    ) !bool {
        const nodes_root = self.lookupChild(self.root_id, "nodes") orelse return false;

        var selected_node_id: ?[]const u8 = null;
        var selected_venom_dir_id: ?u32 = null;

        if (preferred_node_id) |selected| {
            const preferred_node_dir_id = self.lookupChild(nodes_root, selected);
            if (preferred_node_dir_id) |node_dir_id| {
                if (self.lookupChild(node_dir_id, "venoms")) |venoms_root_id| {
                    if (self.lookupChild(venoms_root_id, venom_id)) |venom_dir_id| {
                        selected_node_id = selected;
                        selected_venom_dir_id = venom_dir_id;
                    }
                }
            }
        }

        if (selected_venom_dir_id == null) {
            const nodes_root_node = self.nodes.get(nodes_root) orelse return false;
            var node_it = nodes_root_node.children.iterator();
            while (node_it.next()) |entry| {
                const node_name = entry.key_ptr.*;
                const node_dir_id = entry.value_ptr.*;
                const venoms_root_id = self.lookupChild(node_dir_id, "venoms") orelse continue;
                const venom_dir_id = self.lookupChild(venoms_root_id, venom_id) orelse continue;
                selected_node_id = node_name;
                selected_venom_dir_id = venom_dir_id;
                break;
            }
        }

        const provider_node_id = selected_node_id orelse return false;
        const provider_dir_id = selected_venom_dir_id orelse return false;

        const alias_dir_id = try self.addDir(alias_root, venom_id, false);
        try self.copyOptionalServiceFile(provider_dir_id, alias_dir_id, "README.md");
        try self.copyOptionalServiceFile(provider_dir_id, alias_dir_id, "SCHEMA.json");
        try self.copyOptionalServiceFile(provider_dir_id, alias_dir_id, "CAPS.json");
        try self.copyOptionalServiceFile(provider_dir_id, alias_dir_id, "MOUNTS.json");
        try self.copyOptionalServiceFile(provider_dir_id, alias_dir_id, "OPS.json");
        try self.copyOptionalServiceFile(provider_dir_id, alias_dir_id, "RUNTIME.json");
        try self.copyOptionalServiceFile(provider_dir_id, alias_dir_id, "TEMPLATE.json");
        try self.copyOptionalServiceFile(provider_dir_id, alias_dir_id, "HOST.json");
        try self.copyOptionalServiceFile(provider_dir_id, alias_dir_id, "PERMISSIONS.json");
        try self.copyOptionalServiceFile(provider_dir_id, alias_dir_id, "STATUS.json");

        const venom_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ alias_base_path, venom_id });
        defer self.allocator.free(venom_path);
        const provider_venom_path = try std.fmt.allocPrint(
            self.allocator,
            "/nodes/{s}/venoms/{s}",
            .{ provider_node_id, venom_id },
        );
        defer self.allocator.free(provider_venom_path);
        const endpoint_path = blk: {
            if (try self.firstVenomMountPath(provider_dir_id)) |value| break :blk value;
            break :blk try self.venomEndpointPath(provider_dir_id);
        };
        defer if (endpoint_path) |value| self.allocator.free(value);
        const invoke_path = try self.deriveVenomInvokePath(provider_node_id, venom_id, provider_dir_id);
        defer if (invoke_path) |value| self.allocator.free(value);

        try self.registerScopedVenomBinding(
            venom_id,
            scope,
            venom_path,
            provider_node_id,
            provider_venom_path,
            endpoint_path,
            invoke_path,
        );
        return true;
    }

    fn resolvePreferredBoundVenomNodeId(self: *Session, venom_id: []const u8) !?[]u8 {
        return self.resolvePreferredBoundVenomNodeIdForContext(venom_id, null, null);
    }

    fn resolvePreferredBoundVenomNodeIdForContext(
        self: *Session,
        venom_id: []const u8,
        project_id: ?[]const u8,
        agent_id: ?[]const u8,
    ) !?[]u8 {
        const plane = self.control_plane orelse return null;
        var provider = (try plane.resolvePreferredVenomProviderForContext(
            self.allocator,
            venom_id,
            &.{ "spiderapp-default", "spiderweb-local", "local" },
            project_id,
            agent_id,
        )) orelse return null;
        defer provider.deinit(self.allocator);
        return try self.allocator.dupe(u8, provider.node_id);
    }

    pub fn addDir(self: *Session, parent: ?u32, name: []const u8, writable: bool) !u32 {
        return self.addNode(parent, name, .dir, "", writable, .none);
    }

    pub fn addFile(self: *Session, parent: u32, name: []const u8, content: []const u8, writable: bool, special: SpecialKind) !u32 {
        return self.addNode(parent, name, .file, content, writable, special);
    }

    fn copyNodeBytes(self: *Session, value: []const u8) ![]u8 {
        const copy = try self.allocator.alloc(u8, value.len);
        std.mem.copyForwards(u8, copy, value);
        return copy;
    }

    fn addNode(
        self: *Session,
        parent: ?u32,
        name: []const u8,
        kind: NodeKind,
        content: []const u8,
        writable: bool,
        special: SpecialKind,
    ) !u32 {
        const node_id = self.next_node_id;
        self.next_node_id += 1;

        const node = Node{
            .id = node_id,
            .parent = parent,
            .kind = kind,
            .name = try self.copyNodeBytes(name),
            .writable = writable,
            .content = try self.copyNodeBytes(content),
            .special = special,
        };

        try self.nodes.put(self.allocator, node_id, node);

        if (parent) |parent_id| {
            const child_name = (self.nodes.get(node_id) orelse return error.MissingNode).name;
            var parent_node = self.nodes.getPtr(parent_id) orelse return error.MissingNode;
            try parent_node.children.put(self.allocator, child_name, node_id);
        }

        return node_id;
    }

    pub fn lookupChild(self: *Session, parent_id: u32, name: []const u8) ?u32 {
        const parent = self.nodes.get(parent_id) orelse return null;
        return parent.children.get(name);
    }

    fn resolveWalkChild(self: *Session, parent_id: u32, name: []const u8) !?u32 {
        const parent_path = try self.nodeAbsolutePath(parent_id);
        defer self.allocator.free(parent_path);
        const child_path = if (std.mem.eql(u8, parent_path, "/"))
            try std.fmt.allocPrint(self.allocator, "/{s}", .{name})
        else
            try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ parent_path, name });
        defer self.allocator.free(child_path);

        if (self.project_binds.items.len > 0) {
            const resolved_path = try self.resolveBoundPath(child_path);
            defer if (resolved_path) |value| self.allocator.free(value);
            if (resolved_path) |value| {
                if (!std.mem.eql(u8, value, child_path)) {
                    if (self.resolveAbsolutePathNoBinds(value)) |resolved_id| return resolved_id;
                }
            }
        }

        if (self.lookupChild(parent_id, name)) |child| return child;
        if (self.project_binds.items.len == 0) return null;

        const projected_parent_path = try self.resolveProjectedPathForBoundTarget(parent_path);
        defer if (projected_parent_path) |value| self.allocator.free(value);
        if (projected_parent_path) |value| {
            if (!std.mem.eql(u8, value, parent_path)) {
                const projected_child_path = if (std.mem.eql(u8, value, "/"))
                    try std.fmt.allocPrint(self.allocator, "/{s}", .{name})
                else
                    try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ value, name });
                defer self.allocator.free(projected_child_path);

                const rebound = try self.resolveBoundPath(projected_child_path);
                defer if (rebound) |resolved| self.allocator.free(resolved);
                if (rebound) |resolved| {
                    if (!std.mem.eql(u8, resolved, projected_child_path)) {
                        if (self.resolveAbsolutePathNoBinds(resolved)) |resolved_id| return resolved_id;
                    }
                }

                if (self.resolveAbsolutePathNoBinds(projected_child_path)) |resolved_id| return resolved_id;
            }
        }

        const resolved_path = try self.resolveBoundPath(child_path);
        defer if (resolved_path) |value| self.allocator.free(value);
        if (resolved_path == null) return null;
        return self.resolveAbsolutePathNoBinds(resolved_path.?);
    }

    fn resolveBoundPath(self: *Session, path: []const u8) !?[]u8 {
        if (self.project_binds.items.len == 0) return null;

        var current_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(current_path);
        var changed = false;
        var depth: usize = 0;
        while (depth < 16) : (depth += 1) {
            const rebound = try self.resolveBoundPathOnce(current_path) orelse {
                if (!changed) {
                    self.allocator.free(current_path);
                    return null;
                }
                return current_path;
            };
            if (std.mem.eql(u8, rebound, current_path)) {
                self.allocator.free(current_path);
                return rebound;
            }
            changed = true;
            self.allocator.free(current_path);
            current_path = rebound;
        }
        self.allocator.free(current_path);
        return error.InvalidPath;
    }

    fn resolveProjectedPathForBoundTarget(self: *Session, path: []const u8) !?[]u8 {
        if (self.project_binds.items.len == 0) return null;

        var selected: ?PathBind = null;
        for (self.project_binds.items) |bind| {
            if (!pathMatchesPrefixBoundary(path, bind.target_path)) continue;
            if (selected == null or bind.target_path.len > selected.?.target_path.len) selected = bind;
        }

        if (selected) |bind| {
            const suffix = path[bind.target_path.len..];
            if (suffix.len == 0) return try self.allocator.dupe(u8, bind.bind_path);
            if (std.mem.eql(u8, bind.bind_path, "/")) return try std.fmt.allocPrint(self.allocator, "{s}", .{suffix});
            return try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ bind.bind_path, suffix });
        }
        return null;
    }

    fn resolveBoundPathOnce(self: *Session, path: []const u8) !?[]u8 {
        if (self.project_binds.items.len == 0) return null;
        var selected: ?PathBind = null;
        for (self.project_binds.items) |bind| {
            if (!pathMatchesPrefixBoundary(path, bind.bind_path)) continue;
            if (selected == null or bind.bind_path.len > selected.?.bind_path.len) selected = bind;
        }
        if (selected) |bind| {
            const suffix = path[bind.bind_path.len..];
            if (suffix.len == 0) return try self.allocator.dupe(u8, bind.target_path);
            if (std.mem.eql(u8, bind.target_path, "/")) return try std.fmt.allocPrint(self.allocator, "{s}", .{suffix});
            return try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ bind.target_path, suffix });
        }
        return null;
    }

    pub fn resolvePreferredServicePath(self: *Session, service_id: []const u8, suffix: []const u8) ![]u8 {
        const workspace_path = if (suffix.len == 0)
            try std.fmt.allocPrint(self.allocator, "/services/{s}", .{service_id})
        else
            try std.fmt.allocPrint(self.allocator, "/services/{s}{s}", .{ service_id, suffix });
        errdefer self.allocator.free(workspace_path);

        const rebound = try self.resolveBoundPath(workspace_path);
        if (rebound) |value| {
            self.allocator.free(value);
            return workspace_path;
        }

        self.allocator.free(workspace_path);
        return if (suffix.len == 0)
            try std.fmt.allocPrint(self.allocator, "/global/{s}", .{service_id})
        else
            try std.fmt.allocPrint(self.allocator, "/global/{s}{s}", .{ service_id, suffix });
    }

    pub fn resolveAbsolutePathNoBinds(self: *Session, path: []const u8) ?u32 {
        if (!std.mem.startsWith(u8, path, "/")) return null;
        if (std.mem.eql(u8, path, "/")) return self.root_id;
        var node_id = self.root_id;
        var iter = std.mem.splitScalar(u8, path, '/');
        while (iter.next()) |segment| {
            if (segment.len == 0) continue;
            const next = self.lookupChild(node_id, segment) orelse return null;
            node_id = next;
        }
        return node_id;
    }

    fn resolveAbsolutePathForMountGraphNoBinds(self: *Session, path: []const u8) !?u32 {
        if (!std.mem.startsWith(u8, path, "/")) return null;
        if (std.mem.eql(u8, path, "/")) return self.root_id;

        var node_id = self.root_id;
        var iter = std.mem.splitScalar(u8, path, '/');
        while (iter.next()) |segment| {
            if (segment.len == 0) continue;
            self.refreshDynamicDirectory(node_id) catch {};
            node_id = self.lookupChild(node_id, segment) orelse return null;
        }
        return node_id;
    }

    fn nodeAbsolutePath(self: *Session, node_id: u32) ![]u8 {
        if (node_id == self.root_id) return self.allocator.dupe(u8, "/");
        var names = std.ArrayListUnmanaged([]const u8){};
        defer names.deinit(self.allocator);

        var cursor = node_id;
        while (true) {
            const node = self.nodes.get(cursor) orelse break;
            if (node.parent == null) break;
            try names.append(self.allocator, node.name);
            cursor = node.parent.?;
        }
        if (names.items.len == 0) return self.allocator.dupe(u8, "/");

        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(self.allocator);
        for (names.items, 0..) |_, idx| {
            const rev_idx = names.items.len - idx - 1;
            try out.append(self.allocator, '/');
            try out.appendSlice(self.allocator, names.items[rev_idx]);
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn renderDirListing(self: *Session, node_id: u32) ![]u8 {
        const node = self.nodes.get(node_id) orelse return error.MissingNode;
        if (node.kind != .dir) return error.NotDir;

        var names = std.ArrayListUnmanaged([]const u8){};
        defer names.deinit(self.allocator);

        var collect_it = node.children.iterator();
        while (collect_it.next()) |entry| {
            try names.append(self.allocator, entry.key_ptr.*);
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.lessThan(u8, lhs, rhs);
            }
        }.lessThan);

        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.allocator);
        var seen = std.StringHashMapUnmanaged(void){};
        defer seen.deinit(self.allocator);

        var first = true;
        for (names.items) |name| {
            if (!first) try out.append(self.allocator, '\n');
            first = false;
            try out.appendSlice(self.allocator, name);
            try seen.put(self.allocator, name, {});
        }

        if (self.project_binds.items.len > 0) {
            const dir_path = try self.nodeAbsolutePath(node_id);
            defer self.allocator.free(dir_path);

            for (self.project_binds.items) |bind| {
                const child_name = immediateBoundChildName(dir_path, bind.bind_path) orelse continue;
                if (seen.contains(child_name)) continue;
                if (!first) try out.append(self.allocator, '\n');
                first = false;
                try out.appendSlice(self.allocator, child_name);
                try seen.put(self.allocator, child_name, {});
            }

            const projected_dir_path = try self.resolveProjectedPathForBoundTarget(dir_path);
            defer if (projected_dir_path) |value| self.allocator.free(value);
            if (projected_dir_path) |value| {
                if (!std.mem.eql(u8, value, dir_path)) {
                    for (self.project_binds.items) |bind| {
                        const child_name = immediateBoundChildName(value, bind.bind_path) orelse continue;
                        if (seen.contains(child_name)) continue;
                        if (!first) try out.append(self.allocator, '\n');
                        first = false;
                        try out.appendSlice(self.allocator, child_name);
                        try seen.put(self.allocator, child_name, {});
                    }
                }
            }
        }

        return out.toOwnedSlice(self.allocator);
    }

    fn writeFileContentRaw(self: *Session, node_id: u32, offset: u64, data: []const u8) !void {
        const node_ptr = self.nodes.getPtr(node_id) orelse return error.MissingNode;
        if (node_ptr.kind != .file) return error.NotFile;

        const base_offset = std.math.cast(usize, offset) orelse return error.InvalidOffset;
        const required_len = std.math.add(usize, base_offset, data.len) catch return error.InvalidOffset;
        if (required_len <= node_ptr.content.len) {
            @memcpy(node_ptr.content[base_offset .. base_offset + data.len], data);
            return;
        }

        var next = try self.allocator.alloc(u8, required_len);
        @memset(next, 0);
        if (node_ptr.content.len > 0) {
            @memcpy(next[0..node_ptr.content.len], node_ptr.content);
        }
        @memcpy(next[base_offset .. base_offset + data.len], data);

        self.allocator.free(node_ptr.content);
        node_ptr.content = next;
    }

    fn writeFileContent(self: *Session, node_id: u32, offset: u64, data: []const u8) !void {
        try self.writeFileContentRaw(node_id, offset, data);
        if (self.node_aliases.get(node_id)) |alias_id| {
            if (alias_id != node_id) {
                const node = self.nodes.get(node_id) orelse return error.MissingNode;
                try self.setFileContentRaw(alias_id, node.content);
            }
        }
    }

    fn setFileContentRaw(self: *Session, node_id: u32, data: []const u8) !void {
        const node_ptr = self.nodes.getPtr(node_id) orelse return error.MissingNode;
        if (node_ptr.kind != .file) return error.NotFile;
        self.allocator.free(node_ptr.content);
        node_ptr.content = try self.allocator.dupe(u8, data);
    }

    pub fn setFileContent(self: *Session, node_id: u32, data: []const u8) !void {
        try self.setFileContentRaw(node_id, data);
        if (self.node_aliases.get(node_id)) |alias_id| {
            if (alias_id != node_id) try self.setFileContentRaw(alias_id, data);
        }
    }

    pub fn setMirroredFileContent(self: *Session, primary_id: u32, alias_id: u32, data: []const u8) !void {
        if (primary_id != 0) try self.setFileContent(primary_id, data);
        if (alias_id != 0 and alias_id != primary_id) try self.setFileContent(alias_id, data);
    }

    fn tryReadBoundVenomProxyFile(self: *Session, node_id: u32) !?[]u8 {
        const absolute_path = try self.nodeAbsolutePath(node_id);
        defer self.allocator.free(absolute_path);

        if (try self.readBoundVenomProxyFileByPath(absolute_path)) |value| return value;
        return null;
    }

    fn readBoundVenomProxyFileByPath(self: *Session, absolute_path: []const u8) !?[]u8 {
        const proxy = (try self.boundVenomProxyPathForAbsolutePath(absolute_path)) orelse return null;
        if (std.mem.eql(u8, proxy.remote_path, "/")) return null;

        var router = (try self.boundVenomRouterForProxy(proxy, .server_internal)) orelse return null;
        defer router.deinit();
        defer self.allocator.free(proxy.remote_path);
        const file = router.open(proxy.remote_path, 0) catch return null;
        defer router.close(file) catch {};
        return router.read(file, 0, 1024 * 1024) catch null;
    }

    fn tryWriteBoundVenomProxyFile(self: *Session, node_id: u32, offset: u64, data: []const u8) !?WriteOutcome {
        const absolute_path = try self.nodeAbsolutePath(node_id);
        defer self.allocator.free(absolute_path);

        if (try self.boundVenomProxyPathForAbsolutePath(absolute_path)) |proxy| {
            defer self.allocator.free(proxy.remote_path);
            if (std.mem.eql(u8, proxy.remote_path, "/")) return null;
            return self.writeBoundGenericProxy(proxy, offset, data);
        }
        return null;
    }

    fn writeBoundGenericProxy(
        self: *Session,
        proxy: BoundVenomProxyPath,
        offset: u64,
        data: []const u8,
    ) !?WriteOutcome {
        var router = (try self.boundVenomRouterForProxy(proxy, .server_internal)) orelse return null;
        defer router.deinit();
        const file = router.open(proxy.remote_path, 1) catch return null;
        defer router.close(file) catch {};
        const result_json = router.writeResult(file, offset, data) catch return null;
        defer self.allocator.free(result_json);

        var outcome = WriteOutcome{ .written = data.len };
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, result_json, .{}) catch return outcome;
        defer parsed.deinit();
        if (parsed.value != .object) return outcome;
        if (parsed.value.object.get("n")) |value| {
            if (value == .integer and value.integer >= 0) outcome.written = @intCast(value.integer);
        }
        return outcome;
    }

    fn buildBoundVenomProxyStatPayload(self: *Session, node_id: u32) !?[]u8 {
        const absolute_path = try self.nodeAbsolutePath(node_id);
        defer self.allocator.free(absolute_path);
        const proxy = (try self.boundVenomProxyPathForAbsolutePath(absolute_path)) orelse return null;
        defer self.allocator.free(proxy.remote_path);

        var router = (try self.boundVenomRouterForProxy(proxy, .server_internal)) orelse return null;
        defer router.deinit();
        const attr_json = router.getattr(proxy.remote_path) catch return null;
        defer self.allocator.free(attr_json);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, attr_json, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;

        const node = self.nodes.get(node_id) orelse return null;
        const escaped_name = try unified.jsonEscape(self.allocator, node.name);
        defer self.allocator.free(escaped_name);

        const mode: u32 = if (parsed.value.object.get("m")) |value|
            switch (value) {
                .integer => if (value.integer >= 0) @intCast(value.integer) else effectiveNodeMode(node),
                else => effectiveNodeMode(node),
            }
        else
            effectiveNodeMode(node);
        const summary = parseBoundVenomProxyAttr(parsed.value) orelse BoundVenomProxyAttrSummary{
            .kind = node.kind,
            .writable = node.writable,
            .mode = node.reported_mode,
            .size = node.reported_size,
        };
        const size: u64 = if (parsed.value.object.get("sz")) |value|
            switch (value) {
                .integer => if (value.integer >= 0) @intCast(value.integer) else effectiveNodeSizeU64(node),
                else => effectiveNodeSizeU64(node),
            }
        else
            effectiveNodeSizeU64(node);
        const projected_writable = if (isManagedSharedDataProjectedPath(absolute_path)) false else summary.writable;
        const projected_mode = if (isManagedSharedDataProjectedPath(absolute_path))
            readonlyMode(mode, summary.kind)
        else
            mode;

        return try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":{d},\"name\":\"{s}\",\"kind\":\"{s}\",\"size\":{d},\"mode\":{d},\"writable\":{s}}}",
            .{ node.id, escaped_name, kindName(summary.kind), size, projected_mode, if (projected_writable) "true" else "false" },
        );
    }

    fn boundVenomProxyPathForAbsolutePath(self: *Session, absolute_path: []const u8) !?BoundVenomProxyPath {
        if (try self.workspaceMountProxyPathForAbsolutePath(absolute_path)) |proxy| return proxy;
        if (parseNodeFsProxyPath(absolute_path)) |value| {
            return .{
                .venom_id = "fs",
                .remote_path = try self.allocator.dupe(u8, value.remote_path),
                .project_id = self.active_namespace_project_id orelse self.project_id,
                .provider_node_id = value.node_id,
                .provider_export_name = null,
            };
        }
        const service_match = parseServiceScopedVenomAliasPrefix(self, absolute_path);
        if (service_match) |value| {
            return .{
                .venom_id = value.venom_id,
                .remote_path = try self.allocator.dupe(u8, value.remote_path),
                .project_id = value.project_id,
            };
        }
        const global_match = parseScopedVenomAliasPrefix(absolute_path, "/global/");
        if (global_match) |value| {
            return .{
                .venom_id = value.venom_id,
                .remote_path = try self.allocator.dupe(u8, value.remote_path),
            };
        }
        const agent_match = parseEntityScopedVenomAliasPrefix(absolute_path, "/agents/", "/venoms/");
        if (agent_match) |value| {
            return .{
                .venom_id = value.venom_id,
                .remote_path = try self.allocator.dupe(u8, value.remote_path),
                .agent_id = value.entity_id,
            };
        }
        const project_match = parseEntityScopedVenomAliasPrefix(absolute_path, "/projects/", "/venoms/");
        if (project_match) |value| {
            return .{
                .venom_id = value.venom_id,
                .remote_path = try self.allocator.dupe(u8, value.remote_path),
                .project_id = value.entity_id,
            };
        }
        return null;
    }

    fn workspaceMountProxyPathForAbsolutePath(self: *Session, absolute_path: []const u8) !?BoundVenomProxyPath {
        var best_root: ?[]const u8 = null;
        var best_match: ?WorkspaceMountProxyRoot = null;
        var it = self.workspace_mount_proxy_roots.iterator();
        while (it.next()) |entry| {
            const proxy_root = entry.key_ptr.*;
            if (!pathMatchesPrefixBoundary(absolute_path, proxy_root)) continue;
            if (best_root) |existing| {
                if (existing.len >= proxy_root.len) continue;
            }
            best_root = proxy_root;
            best_match = entry.value_ptr.*;
        }

        const proxy_root = best_root orelse return null;
        const proxy_match = best_match orelse return null;
        const remote_path = if (std.mem.eql(u8, absolute_path, proxy_root))
            try self.allocator.dupe(u8, "/")
        else
            try self.allocator.dupe(u8, absolute_path[proxy_root.len..]);
        return .{
            .venom_id = "fs",
            .remote_path = remote_path,
            .project_id = self.active_namespace_project_id orelse self.project_id,
            .provider_node_id = proxy_match.node_id,
            .provider_export_name = proxy_match.export_name,
        };
    }

    fn refreshBoundVenomProxyDirectory(self: *Session, dir_id: u32) !void {
        const absolute_path = try self.nodeAbsolutePath(dir_id);
        defer self.allocator.free(absolute_path);

        const proxy = (try self.boundVenomProxyPathForAbsolutePath(absolute_path)) orelse return;
        defer self.allocator.free(proxy.remote_path);

        var router = (try self.boundVenomRouterForProxy(proxy, .server_internal)) orelse return;
        defer router.deinit();
        std.log.warn(
            "mounted export refresh start: path={s} remote={s} node={s} export={s}",
            .{
                absolute_path,
                proxy.remote_path,
                proxy.provider_node_id orelse "(none)",
                proxy.provider_export_name orelse "(none)",
            },
        );

        var seen_names = std.ArrayListUnmanaged([]u8){};
        defer {
            for (seen_names.items) |name| self.allocator.free(name);
            seen_names.deinit(self.allocator);
        }
        var cookie: u64 = 0;
        while (true) {
            const listing_json = router.readdir(proxy.remote_path, cookie, 4096) catch |err| {
                std.log.warn(
                    "bound venom proxy refresh failed: path={s} remote={s} err={s}",
                    .{ absolute_path, proxy.remote_path, @errorName(err) },
                );
                return;
            };
            defer self.allocator.free(listing_json);
            std.log.warn(
                "mounted export refresh page: path={s} remote={s} cookie={d} bytes={d}",
                .{ absolute_path, proxy.remote_path, cookie, listing_json.len },
            );
            const next_cookie = try self.applyBoundVenomProxyListing(dir_id, listing_json, &seen_names);
            if (next_cookie == 0 or next_cookie <= cookie) break;
            cookie = next_cookie;
        }
        try self.pruneBoundVenomProxyChildren(dir_id, seen_names.items);
    }

    fn boundVenomRouterForProxy(self: *Session, proxy: BoundVenomProxyPath, route_mode: BoundVenomRouteMode) !?acheron_router.Router {
        if (proxy.provider_node_id) |node_id| {
            if (proxy.provider_export_name == null) {
                const scoped_project_id = proxy.project_id orelse self.active_namespace_project_id orelse self.project_id;
                if (scoped_project_id != null and !self.isBoundVenomNodeAllowed(scoped_project_id, proxy.agent_id, node_id)) {
                    return null;
                }
            }
            const plane = self.control_plane orelse return null;
            return self.boundVenomRouterForNode(plane, proxy.venom_id, node_id, proxy.provider_export_name, route_mode);
        }
        return self.boundVenomRouter(proxy.venom_id, proxy.project_id, proxy.agent_id);
    }

    fn applyBoundVenomProxyListing(
        self: *Session,
        parent_id: u32,
        listing_json: []const u8,
        seen_names: *std.ArrayListUnmanaged([]u8),
    ) anyerror!u64 {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, listing_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return 0;

        const next_cookie = parseReaddirNextCookie(parsed.value.object);
        const ents = parsed.value.object.get("ents") orelse return next_cookie;
        if (ents != .array) return next_cookie;
        for (ents.array.items) |entry| {
            if (entry != .object) continue;
            const name_val = entry.object.get("name") orelse continue;
            const attr_val = entry.object.get("attr") orelse continue;
            if (name_val != .string or name_val.string.len == 0) continue;
            if (std.mem.eql(u8, name_val.string, ".") or std.mem.eql(u8, name_val.string, "..")) continue;
            try self.noteBoundVenomProxyChildSeen(seen_names, name_val.string);
            try self.upsertBoundVenomProxyChild(parent_id, name_val.string, attr_val);
        }
        return next_cookie;
    }

    fn parseReaddirNextCookie(obj: std.json.ObjectMap) u64 {
        if (obj.get("eof")) |value| {
            if (value == .bool and value.bool) return 0;
        }
        if (obj.get("next_cookie")) |value| {
            if (value == .integer and value.integer >= 0) return @intCast(value.integer);
        }
        if (obj.get("next")) |value| {
            if (value == .integer and value.integer >= 0) return @intCast(value.integer);
        }
        return 0;
    }

    fn upsertBoundVenomProxyChild(self: *Session, parent_id: u32, name: []const u8, attr_val: std.json.Value) !void {
        const summary = parseBoundVenomProxyAttr(attr_val) orelse return;
        if (self.lookupChild(parent_id, name)) |child_id| {
            const child = self.nodes.getPtr(child_id) orelse return;
            child.kind = summary.kind;
            child.writable = summary.writable;
            child.reported_mode = summary.mode;
            child.reported_size = summary.size;
            return;
        }
        switch (summary.kind) {
            .dir => {
                const child_id = try self.addDir(parent_id, name, false);
                const child = self.nodes.getPtr(child_id) orelse return error.MissingNode;
                child.reported_mode = summary.mode;
                child.reported_size = summary.size;
            },
            .file => {
                const child_id = try self.addFile(parent_id, name, "", summary.writable, .none);
                const child = self.nodes.getPtr(child_id) orelse return error.MissingNode;
                child.reported_mode = summary.mode;
                child.reported_size = summary.size;
            },
        }
    }

    fn noteBoundVenomProxyChildSeen(
        self: *Session,
        seen_names: *std.ArrayListUnmanaged([]u8),
        name: []const u8,
    ) !void {
        for (seen_names.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }
        try seen_names.append(self.allocator, try self.allocator.dupe(u8, name));
    }

    fn pruneBoundVenomProxyChildren(self: *Session, parent_id: u32, seen_names: []const []const u8) !void {
        const parent = self.nodes.get(parent_id) orelse return;
        var doomed = std.ArrayListUnmanaged(u32){};
        defer doomed.deinit(self.allocator);

        var it = parent.children.iterator();
        while (it.next()) |entry| {
            if (containsBoundVenomProxyChildName(seen_names, entry.key_ptr.*)) continue;
            try doomed.append(self.allocator, entry.value_ptr.*);
        }
        for (doomed.items) |child_id| {
            try self.deleteNodeRecursive(child_id);
        }
    }

    fn containsBoundVenomProxyChildName(seen_names: []const []const u8, name: []const u8) bool {
        for (seen_names) |seen| {
            if (std.mem.eql(u8, seen, name)) return true;
        }
        return false;
    }

    fn boundVenomRouter(
        self: *Session,
        venom_id: []const u8,
        project_id: ?[]const u8,
        agent_id: ?[]const u8,
    ) !?acheron_router.Router {
        const plane = self.control_plane orelse return null;
        var provider = (try plane.resolvePreferredVenomProviderForContext(
            self.allocator,
            venom_id,
            &.{ "spiderapp-default", "spiderweb-local", "local" },
            project_id,
            agent_id,
        ));
        defer if (provider) |*value| value.deinit(self.allocator);
        if (provider) |value| {
            if (self.isBoundVenomNodeAllowed(project_id, agent_id, value.node_id)) {
                if (try self.boundVenomRouterForNode(plane, venom_id, value.node_id, null, .client_visible)) |router| return router;
            }
        }

        const nodes_root = self.lookupChild(self.root_id, "nodes") orelse return null;
        const nodes_root_node = self.nodes.get(nodes_root) orelse return null;
        var node_it = nodes_root_node.children.iterator();
        while (node_it.next()) |entry| {
            const node_name = entry.key_ptr.*;
            const node_dir_id = entry.value_ptr.*;
            const venoms_root_id = self.lookupChild(node_dir_id, "venoms") orelse continue;
            _ = self.lookupChild(venoms_root_id, venom_id) orelse continue;
            if (!self.isBoundVenomNodeAllowed(project_id, agent_id, node_name)) continue;
            if (try self.boundVenomRouterForNode(plane, venom_id, node_name, null, .client_visible)) |router| return router;
        }

        return null;
    }

    fn boundVenomRouterForNode(
        self: *Session,
        plane: *control_plane_mod.ControlPlane,
        venom_id: []const u8,
        node_id: []const u8,
        export_name: ?[]const u8,
        route_mode: BoundVenomRouteMode,
    ) !?acheron_router.Router {
        const workspace_mount_auth_token = self.workspace_mount_fs_auth_tokens.get(node_id);
        const workspace_mount_fs_url = self.workspace_mount_fs_urls.get(node_id);
        const routed_fs_url = if (workspace_mount_auth_token != null)
            try self.buildNamespaceRoutedNodeFsUrl(node_id)
        else
            null;
        defer if (routed_fs_url) |value| self.allocator.free(value);
        const fs_url = blk: {
            // Clients should always stay on Spiderweb's routed authority.
            // Server-internal namespace refreshes can talk to mounted export
            // endpoints directly so Spiderweb does not deadlock routing back
            // through itself while composing the namespace view.
            if (route_mode == .server_internal and export_name != null) {
                if (workspace_mount_fs_url) |value| break :blk value;
                if (routed_fs_url) |value| break :blk value;
            } else {
                if (routed_fs_url) |value| break :blk value;
                if (export_name != null) {
                    if (workspace_mount_fs_url) |value| break :blk value;
                }
            }
            const node_payload_req = try std.fmt.allocPrint(self.allocator, "{{\"node_id\":\"{s}\"}}", .{node_id});
            defer self.allocator.free(node_payload_req);
            const node_payload = plane.getNode(node_payload_req) catch return null;
            defer self.allocator.free(node_payload);

            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, node_payload, .{}) catch return null;
            defer parsed.deinit();
            if (parsed.value != .object) return null;
            const fs_url_val = parsed.value.object.get("fs_url") orelse return null;
            if (fs_url_val != .string or fs_url_val.string.len == 0) return null;
            break :blk fs_url_val.string;
        };
        if (std.mem.eql(u8, venom_id, "fs") and export_name != null) {
            std.log.warn(
                "mounted export router selected: mode={s} node={s} export={s} url={s} auth={s}",
                .{
                    @tagName(route_mode),
                    node_id,
                    export_name.?,
                    fs_url,
                    if (workspace_mount_auth_token != null) "present" else "missing",
                },
            );
        }
        const selected_export_name = if (std.mem.eql(u8, venom_id, "fs")) export_name else venom_id;

        return try acheron_router.Router.init(self.allocator, &[_]acheron_router.EndpointConfig{.{
            .name = node_id,
            .url = fs_url,
            .export_name = selected_export_name,
            .mount_path = "/",
            .auth_token = workspace_mount_auth_token,
        }});
    }

    fn seedBoundGlobalFsNamespace(
        self: *Session,
        global_root: u32,
        preferred_node_id: []const u8,
    ) !bool {
        const alias_dir_id = try self.addDir(global_root, "fs", false);
        _ = alias_dir_id;
        return self.registerBoundVenomAliasOnly("/global", "fs", "global_binding", preferred_node_id, null, null);
    }

    fn isBoundVenomNodeAllowed(
        self: *Session,
        project_id: ?[]const u8,
        agent_id: ?[]const u8,
        node_id: []const u8,
    ) bool {
        const scoped_project_id = project_id orelse return true;
        const plane = self.control_plane orelse return false;
        return plane.projectAllowsNodeVenomEvent(
            scoped_project_id,
            if (agent_id) |value| value else self.agent_id,
            self.project_token,
            node_id,
            self.is_admin,
        );
    }

    fn registerBoundVenomAliasOnly(
        self: *Session,
        alias_base_path: []const u8,
        venom_id: []const u8,
        scope: []const u8,
        preferred_node_id: ?[]const u8,
        project_id: ?[]const u8,
        agent_id: ?[]const u8,
    ) !bool {
        const nodes_root = self.lookupChild(self.root_id, "nodes") orelse return false;

        var selected_node_id: ?[]const u8 = null;
        var selected_venom_dir_id: ?u32 = null;

        if (preferred_node_id) |selected| {
            const preferred_node_dir_id = self.lookupChild(nodes_root, selected);
            if (preferred_node_dir_id) |node_dir_id| {
                if (self.lookupChild(node_dir_id, "venoms")) |venoms_root_id| {
                    if (self.lookupChild(venoms_root_id, venom_id)) |venom_dir_id| {
                        if (self.isBoundVenomNodeAllowed(project_id, agent_id, selected)) {
                            selected_node_id = selected;
                            selected_venom_dir_id = venom_dir_id;
                        }
                    }
                }
            }
        }

        if (selected_venom_dir_id == null) {
            const nodes_root_node = self.nodes.get(nodes_root) orelse return false;
            var node_it = nodes_root_node.children.iterator();
            while (node_it.next()) |entry| {
                const node_name = entry.key_ptr.*;
                const node_dir_id = entry.value_ptr.*;
                const venoms_root_id = self.lookupChild(node_dir_id, "venoms") orelse continue;
                const venom_dir_id = self.lookupChild(venoms_root_id, venom_id) orelse continue;
                if (!self.isBoundVenomNodeAllowed(project_id, agent_id, node_name)) continue;
                selected_node_id = node_name;
                selected_venom_dir_id = venom_dir_id;
                break;
            }
        }

        const provider_node_id = selected_node_id orelse return false;
        const provider_dir_id = selected_venom_dir_id orelse return false;
        const venom_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ alias_base_path, venom_id });
        defer self.allocator.free(venom_path);
        const provider_venom_path = try std.fmt.allocPrint(
            self.allocator,
            "/nodes/{s}/venoms/{s}",
            .{ provider_node_id, venom_id },
        );
        defer self.allocator.free(provider_venom_path);
        const endpoint_path = blk: {
            if (try self.firstVenomMountPath(provider_dir_id)) |value| break :blk value;
            break :blk try self.venomEndpointPath(provider_dir_id);
        };
        defer if (endpoint_path) |value| self.allocator.free(value);
        const invoke_path = try self.deriveVenomInvokePath(provider_node_id, venom_id, provider_dir_id);
        defer if (invoke_path) |value| self.allocator.free(value);

        try self.registerScopedVenomBinding(
            venom_id,
            scope,
            venom_path,
            provider_node_id,
            provider_venom_path,
            endpoint_path,
            invoke_path,
        );
        return true;
    }

    fn handlePairingControlWrite(self: *Session, action: PairingAction, raw_input: []const u8) !WriteOutcome {
        return .{ .written = try pairing_venom.handleControlWrite(self, action, raw_input) };
    }

    pub fn renderJsonValueToWriter(self: *Session, writer: anytype, value: std.json.Value) !void {
        switch (value) {
            .null => try writer.writeAll("null"),
            .bool => |v| try writer.writeAll(if (v) "true" else "false"),
            .integer => |v| try writer.print("{d}", .{v}),
            .float => |v| try writer.print("{d}", .{v}),
            .number_string => |v| try writer.writeAll(v),
            .string => |v| try writeJsonString(writer, v),
            .array => |arr| {
                try writer.writeByte('[');
                for (arr.items, 0..) |item, idx| {
                    if (idx != 0) try writer.writeByte(',');
                    try self.renderJsonValueToWriter(writer, item);
                }
                try writer.writeByte(']');
            },
            .object => |obj| {
                try writer.writeByte('{');
                var first = true;
                var it = obj.iterator();
                while (it.next()) |entry| {
                    if (!first) try writer.writeByte(',');
                    first = false;
                    try writeJsonString(writer, entry.key_ptr.*);
                    try writer.writeByte(':');
                    try self.renderJsonValueToWriter(writer, entry.value_ptr.*);
                }
                try writer.writeByte('}');
            },
        }
    }

    fn handleMountsNamespaceWrite(self: *Session, special: SpecialKind, node_id: u32, raw_input: []const u8) !WriteOutcome {
        return .{ .written = try mounts_venom.handleNamespaceWrite(self, special, node_id, raw_input) };
    }

    fn handleHomeNamespaceWrite(self: *Session, special: SpecialKind, node_id: u32, raw_input: []const u8) !WriteOutcome {
        return .{ .written = try home_venom.handleNamespaceWrite(self, special, node_id, raw_input) };
    }

    fn handleWorkersNamespaceWrite(self: *Session, special: SpecialKind, node_id: u32, raw_input: []const u8) !WriteOutcome {
        return .{ .written = try workers_venom.handleNamespaceWrite(self, special, node_id, raw_input) };
    }

    fn handleVenomPackagesNamespaceWrite(self: *Session, special: SpecialKind, node_id: u32, raw_input: []const u8) !WriteOutcome {
        return .{ .written = try venom_packages_service_venom.handleNamespaceWrite(self, special, node_id, raw_input) };
    }

    pub fn normalizeLocalFsRelativePath(self: *Session, raw_path: []const u8) ![]u8 {
        return mounts_venom.normalizeLocalFsRelativePath(self, raw_path);
    }

    pub fn ensurePathExists(path: []const u8) !void {
        return mounts_venom.ensurePathExists(path);
    }

    pub fn isToolAllowedForCurrentAgent(self: *Session, tool_name: []const u8) !bool {
        _ = self;
        _ = tool_name;
        return true;
    }

    fn extractOptionalStringByNames(
        obj: std.json.ObjectMap,
        candidate_names: []const []const u8,
    ) ?[]const u8 {
        for (candidate_names) |field| {
            if (obj.get(field)) |value| {
                if (value == .string and value.string.len > 0) return value.string;
            }
        }
        return null;
    }

    pub const WorkspaceOp = workspaces_venom.Op;

    pub const GitOp = git_venom.Op;

    pub const GitHubPrOp = github_pr_venom.Op;

    pub const PrReviewOp = pr_review_venom.Op;

    fn handleWorkspacesNamespaceWrite(self: *Session, special: SpecialKind, node_id: u32, raw_input: []const u8) !WriteOutcome {
        return .{ .written = try workspaces_venom.handleNamespaceWrite(self, special, node_id, raw_input) };
    }

    pub const ParsedShellExecResult = git_venom.ParsedShellExecResult;

    pub const ShellExecOutcome = union(enum) {
        success: ParsedShellExecResult,
        failure: ToolPayloadErrorInfo,

        pub fn deinit(self: *ShellExecOutcome, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .success => |*value| value.deinit(allocator),
                .failure => |*value| value.deinit(allocator),
            }
            self.* = undefined;
        }
    };

    fn handleGitNamespaceWrite(self: *Session, special: SpecialKind, node_id: u32, raw_input: []const u8) !WriteOutcome {
        const input = std.mem.trim(u8, raw_input, " \t\r\n");
        const payload = if (input.len == 0) "{}" else input;
        try self.setFileContent(node_id, payload);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch return error.InvalidPayload;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidPayload;
        const obj = parsed.value.object;

        const op = switch (special) {
            .git_sync_checkout => GitOp.sync_checkout,
            .git_status => GitOp.status,
            .git_diff_range => GitOp.diff_range,
            .git_invoke => blk: {
                const op_raw = blk2: {
                    if (obj.get("op")) |value| if (value == .string and value.string.len > 0) break :blk2 value.string;
                    if (obj.get("operation")) |value| if (value == .string and value.string.len > 0) break :blk2 value.string;
                    if (obj.get("tool")) |value| if (value == .string and value.string.len > 0) break :blk2 value.string;
                    if (obj.get("tool_name")) |value| if (value == .string and value.string.len > 0) break :blk2 value.string;
                    break :blk2 null;
                } orelse return error.InvalidPayload;
                break :blk parseGitOp(op_raw) orelse return error.InvalidPayload;
            },
            else => return error.InvalidPayload,
        };

        const args_obj = blk: {
            if (obj.get("arguments")) |value| {
                if (value != .object) return error.InvalidPayload;
                break :blk value.object;
            }
            if (obj.get("args")) |value| {
                if (value != .object) return error.InvalidPayload;
                break :blk value.object;
            }
            break :blk obj;
        };

        return self.executeGitOp(op, args_obj, raw_input.len);
    }

    fn handleGitHubPrNamespaceWrite(self: *Session, special: SpecialKind, node_id: u32, raw_input: []const u8) !WriteOutcome {
        return .{ .written = try github_pr_venom.handleNamespaceWrite(self, special, node_id, raw_input) };
    }

    fn parseGitOp(raw: []const u8) ?GitOp {
        return git_venom.parseOp(raw);
    }

    fn gitOperationName(op: GitOp) []const u8 {
        return git_venom.operationName(op);
    }

    fn gitStatusToolName(op: GitOp) []const u8 {
        return git_venom.statusToolName(op);
    }

    fn executeGitOp(self: *Session, op: GitOp, args_obj: std.json.ObjectMap, written: usize) !WriteOutcome {
        const tool_name = gitStatusToolName(op);
        const running_status = try self.buildServiceInvokeStatusJson("running", tool_name, null);
        defer self.allocator.free(running_status);
        try self.setMirroredFileContent(self.git_status_id, self.git_status_alias_id, running_status);

        const result_payload = self.executeGitOpPayload(op, args_obj) catch |err| {
            const error_message = @errorName(err);
            const failed_status = try self.buildServiceInvokeStatusJson("failed", tool_name, error_message);
            defer self.allocator.free(failed_status);
            try self.setMirroredFileContent(self.git_status_id, self.git_status_alias_id, failed_status);
            const failed_result = try self.buildGitFailureResultJson(op, "invalid_payload", error_message);
            defer self.allocator.free(failed_result);
            try self.setMirroredFileContent(self.git_result_id, self.git_result_alias_id, failed_result);
            return err;
        };
        defer self.allocator.free(result_payload);

        if (try self.extractErrorMessageFromToolPayload(result_payload)) |message| {
            defer self.allocator.free(message);
            const failed_status = try self.buildServiceInvokeStatusJson("failed", tool_name, message);
            defer self.allocator.free(failed_status);
            try self.setMirroredFileContent(self.git_status_id, self.git_status_alias_id, failed_status);
        } else {
            const done_status = try self.buildServiceInvokeStatusJson("done", tool_name, null);
            defer self.allocator.free(done_status);
            try self.setMirroredFileContent(self.git_status_id, self.git_status_alias_id, done_status);
        }
        try self.setMirroredFileContent(self.git_result_id, self.git_result_alias_id, result_payload);
        return .{ .written = written };
    }

    fn executeGitOpPayload(self: *Session, op: GitOp, args_obj: std.json.ObjectMap) ![]u8 {
        return git_venom.executeOpPayload(self, op, args_obj);
    }

    pub fn buildCliCommand(self: *Session, program: []const u8, argv: []const []const u8) ![]u8 {
        return git_venom.buildCliCommand(self, program, argv);
    }

    pub fn runShellExecCommand(self: *Session, command: []const u8, cwd: ?[]const u8, timeout_ms: u64) !ShellExecOutcome {
        const args_json = try self.buildShellExecArgsJson(command, cwd, timeout_ms);
        defer self.allocator.free(args_json);
        const payload_json = try self.executeServiceToolCall("shell_exec", args_json);
        defer self.allocator.free(payload_json);

        if (try self.extractErrorInfoFromToolPayload(payload_json)) |info| {
            return .{ .failure = info };
        }
        return .{ .success = try self.parseShellExecPayload(payload_json) };
    }

    fn buildShellExecArgsJson(self: *Session, command: []const u8, cwd: ?[]const u8, timeout_ms: u64) ![]u8 {
        return git_venom.buildShellExecArgsJson(self, command, cwd, timeout_ms);
    }

    pub fn parseShellExecPayload(self: *Session, payload_json: []const u8) !ParsedShellExecResult {
        return git_venom.parseShellExecPayload(self, payload_json);
    }

    fn normalizeJsonText(self: *Session, raw: []const u8) ![]u8 {
        return git_venom.normalizeJsonText(self, raw);
    }

    pub fn buildGitSuccessResultJson(self: *Session, op: GitOp, result_json: []const u8) ![]u8 {
        return git_venom.buildGitSuccessResultJson(self, op, result_json);
    }

    pub fn buildGitFailureResultJson(self: *Session, op: GitOp, code: []const u8, message: []const u8) ![]u8 {
        return git_venom.buildGitFailureResultJson(self, op, code, message);
    }

    pub fn buildGitHubPrSuccessResultJson(self: *Session, op: GitHubPrOp, result_json: []const u8) ![]u8 {
        return github_pr_venom.buildGitHubPrSuccessResultJson(self, op, result_json);
    }

    pub fn buildGitHubPrFailureResultJson(self: *Session, op: GitHubPrOp, code: []const u8, message: []const u8) ![]u8 {
        return github_pr_venom.buildGitHubPrFailureResultJson(self, op, code, message);
    }

    fn handlePrReviewNamespaceWrite(self: *Session, special: SpecialKind, node_id: u32, raw_input: []const u8) !WriteOutcome {
        return .{ .written = try pr_review_venom.handleNamespaceWrite(self, special, node_id, raw_input) };
    }

    pub const PrReviewResolvedContract = pr_review_venom.ResolvedContract;
    pub const PrReviewContextSnapshot = pr_review_venom.ContextSnapshot;
    pub const PrReviewStateSnapshot = pr_review_venom.StateSnapshot;
    pub const PrReviewRepoConfigSnapshot = pr_review_venom.RepoConfigSnapshot;

    pub fn bootstrapPrReviewMission(self: *Session, args_obj: std.json.ObjectMap) !mission_store_mod.MissionRecord {
        return pr_review_venom.bootstrapMission(self, args_obj);
    }

    pub fn resolvePrReviewMissionContract(self: *Session, mission: mission_store_mod.MissionRecord) !PrReviewResolvedContract {
        return pr_review_venom.resolveMissionContract(self, mission);
    }

    pub fn buildPrReviewRunId(self: *Session, repo_key: []const u8, pr_number: u64) ![]u8 {
        return pr_review_venom.buildRunId(self, repo_key, pr_number);
    }

    pub fn loadConfiguredPrReviewRepo(self: *Session, repo_key: []const u8) !?PrReviewRepoConfigSnapshot {
        return pr_review_venom.loadConfiguredRepo(self, repo_key);
    }

    pub fn findActivePrReviewMissionByRunId(
        self: *Session,
        store: *mission_store_mod.MissionStore,
        run_id: []const u8,
        project_id: ?[]const u8,
    ) !?mission_store_mod.MissionRecord {
        return pr_review_venom.findActiveMissionByRunId(self, store, run_id, project_id);
    }

    pub fn normalizeLocalWorkspaceAbsolutePath(self: *Session, raw_path: []const u8) ![]u8 {
        const normalized = try self.normalizeMissionAbsolutePath(raw_path);
        errdefer self.allocator.free(normalized);
        const host_path = try self.resolveMissionContractHostPath(normalized);
        self.allocator.free(host_path);
        return normalized;
    }

    pub fn readMissionContractFile(self: *Session, absolute_path: []const u8, max_bytes: usize) ![]u8 {
        const host_path = try self.resolveMissionContractHostPath(absolute_path);
        defer self.allocator.free(host_path);
        if (std.fs.path.isAbsolute(host_path)) {
            const file = try std.fs.openFileAbsolute(host_path, .{});
            defer file.close();
            return file.readToEndAlloc(self.allocator, max_bytes);
        }
        return std.fs.cwd().readFileAlloc(self.allocator, host_path, max_bytes);
    }

    pub fn loadPrReviewContextSnapshot(self: *Session, context_path: []const u8) !PrReviewContextSnapshot {
        return pr_review_venom.loadContextSnapshot(self, context_path);
    }

    pub fn loadPrReviewStateSnapshot(self: *Session, state_path: []const u8) !PrReviewStateSnapshot {
        return pr_review_venom.loadStateSnapshot(self, state_path);
    }

    pub fn replaceOwnedString(self: *Session, target: *[]u8, value: []const u8) !void {
        const copy = try self.allocator.dupe(u8, value);
        self.allocator.free(target.*);
        target.* = copy;
    }

    pub fn replaceOptionalOwnedString(self: *Session, target: *?[]u8, value: ?[]const u8) !void {
        if (target.*) |existing| self.allocator.free(existing);
        target.* = if (value) |slice| try self.allocator.dupe(u8, slice) else null;
    }

    pub fn replaceOwnedJsonValue(self: *Session, target: *[]u8, value: std.json.Value, default_json: []const u8) !void {
        const rendered = if (value == .null)
            try self.allocator.dupe(u8, default_json)
        else
            try self.renderJsonValue(value);
        self.allocator.free(target.*);
        target.* = rendered;
    }

    pub fn findJsonObjectFieldByNames(_: *Session, obj: std.json.ObjectMap, names: []const []const u8) ?std.json.Value {
        for (names) |name| {
            if (obj.get(name)) |value| return value;
        }
        return null;
    }

    pub fn formatJsonString(self: *Session, value: []const u8) ![]u8 {
        const escaped = try unified.jsonEscape(self.allocator, value);
        defer self.allocator.free(escaped);
        return std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
    }

    fn renderPrReviewStringArg(
        self: *Session,
        overrides: ?std.json.ObjectMap,
        names: []const []const u8,
        default: ?[]const u8,
    ) ![]u8 {
        return pr_review_venom.renderPrReviewStringArg(self, overrides, names, default);
    }

    fn renderPrReviewU64Arg(
        self: *Session,
        overrides: ?std.json.ObjectMap,
        names: []const []const u8,
        default: ?u64,
    ) ![]u8 {
        return pr_review_venom.renderPrReviewU64Arg(self, overrides, names, default);
    }

    fn renderPrReviewBoolArg(
        self: *Session,
        overrides: ?std.json.ObjectMap,
        names: []const []const u8,
        default: ?bool,
    ) ![]u8 {
        return pr_review_venom.renderPrReviewBoolArg(self, overrides, names, default);
    }

    pub fn buildPrReviewGitHubSyncRequestJson(
        self: *Session,
        context: PrReviewContextSnapshot,
        overrides: ?std.json.ObjectMap,
    ) ![]u8 {
        return pr_review_venom.buildPrReviewGitHubSyncRequestJson(self, context, overrides);
    }

    pub fn buildPrReviewGitSyncCheckoutRequestJson(
        self: *Session,
        context: PrReviewContextSnapshot,
        overrides: ?std.json.ObjectMap,
    ) ![]u8 {
        return pr_review_venom.buildPrReviewGitSyncCheckoutRequestJson(self, context, overrides);
    }

    pub fn buildPrReviewGitStatusRequestJson(
        self: *Session,
        context: PrReviewContextSnapshot,
        overrides: ?std.json.ObjectMap,
    ) ![]u8 {
        return pr_review_venom.buildPrReviewGitStatusRequestJson(self, context, overrides);
    }

    pub fn buildPrReviewGitDiffRangeRequestJson(
        self: *Session,
        context: PrReviewContextSnapshot,
        overrides: ?std.json.ObjectMap,
    ) ![]u8 {
        return pr_review_venom.buildPrReviewGitDiffRangeRequestJson(self, context, overrides);
    }

    pub fn buildPrReviewGitHubPublishRequestJson(
        self: *Session,
        context: PrReviewContextSnapshot,
        recommendation_value: std.json.Value,
        review_comment: ?[]const u8,
        thread_actions_value: ?std.json.Value,
        overrides: ?std.json.ObjectMap,
    ) ![]u8 {
        return pr_review_venom.buildPrReviewGitHubPublishRequestJson(
            self,
            context,
            recommendation_value,
            review_comment,
            thread_actions_value,
            overrides,
        );
    }

    pub fn buildPrReviewTerminalCreateRequestJson(self: *Session, checkout_path: []const u8) ![]u8 {
        return pr_review_venom.buildPrReviewTerminalCreateRequestJson(self, checkout_path);
    }

    pub fn buildPrReviewValidationExecRequestJson(
        self: *Session,
        command_value: std.json.Value,
        checkout_path: []const u8,
    ) ![]u8 {
        return pr_review_venom.buildPrReviewValidationExecRequestJson(self, command_value, checkout_path);
    }

    fn buildPrReviewServiceArtifactPayloadJson(
        self: *Session,
        service_path: []const u8,
        invoke_path: []const u8,
        request_payload_json: []const u8,
        result_payload_json: []const u8,
        status_payload_json: ?[]const u8,
    ) ![]u8 {
        return pr_review_venom.buildPrReviewServiceArtifactPayloadJson(
            self,
            service_path,
            invoke_path,
            request_payload_json,
            result_payload_json,
            status_payload_json,
        );
    }

    pub fn invokePrReviewServiceCapture(
        self: *Session,
        store: *mission_store_mod.MissionStore,
        mission_id: []const u8,
        stage: []const u8,
        summary: []const u8,
        service_path: []const u8,
        invoke_path: []const u8,
        request_payload: []const u8,
        artifact_root: []const u8,
        artifact_relative_path: []const u8,
        artifact_kind: []const u8,
    ) !pr_review_venom.ServiceCapture {
        return pr_review_venom.invokePrReviewServiceCapture(
            self,
            store,
            mission_id,
            stage,
            summary,
            service_path,
            invoke_path,
            request_payload,
            artifact_root,
            artifact_relative_path,
            artifact_kind,
        );
    }

    pub fn applyPrReviewContextFromGitHubSyncPayload(
        self: *Session,
        context: *PrReviewContextSnapshot,
        state: *PrReviewStateSnapshot,
        payload_json: []const u8,
    ) !void {
        return pr_review_venom.applyPrReviewContextFromGitHubSyncPayload(self, context, state, payload_json);
    }

    pub fn extractTerminalExitCodeFromToolPayload(self: *Session, payload_json: []const u8) !?i32 {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const result_value = parsed.value.object.get("result") orelse return null;
        if (result_value != .object) return null;
        const exit_code_value = result_value.object.get("exit_code") orelse return null;
        return switch (exit_code_value) {
            .integer => @intCast(exit_code_value.integer),
            .float => |value| blk: {
                if (std.math.floor(value) != value) return error.InvalidPayload;
                break :blk @as(i32, @intFromFloat(value));
            },
            else => return error.InvalidPayload,
        };
    }

    pub fn applyPrReviewContextFromGitSyncPayload(
        self: *Session,
        context: *PrReviewContextSnapshot,
        state: *PrReviewStateSnapshot,
        payload_json: []const u8,
    ) !void {
        return pr_review_venom.applyPrReviewContextFromGitSyncPayload(self, context, state, payload_json);
    }

    pub fn applyPrReviewContextFromGitStatusPayload(
        self: *Session,
        context: *PrReviewContextSnapshot,
        state: *PrReviewStateSnapshot,
        payload_json: []const u8,
    ) !void {
        return pr_review_venom.applyPrReviewContextFromGitStatusPayload(self, context, state, payload_json);
    }

    pub fn applyPrReviewCommonStateFields(self: *Session, args_obj: std.json.ObjectMap, state: *PrReviewStateSnapshot) !void {
        return pr_review_venom.applyPrReviewCommonStateFields(self, args_obj, state);
    }

    fn resolvePrReviewArtifactPath(self: *Session, artifact_root: []const u8, artifact_relative_path: []const u8) ![]u8 {
        return pr_review_venom.resolvePrReviewArtifactPath(self, artifact_root, artifact_relative_path);
    }

    pub fn writePrReviewJsonArtifact(self: *Session, artifact_root: []const u8, artifact_relative_path: []const u8, value: std.json.Value) ![]u8 {
        return pr_review_venom.writePrReviewJsonArtifact(self, artifact_root, artifact_relative_path, value);
    }

    pub fn writePrReviewArtifactPayload(self: *Session, artifact_root: []const u8, artifact_relative_path: []const u8, payload_json: []const u8) ![]u8 {
        return pr_review_venom.writePrReviewArtifactPayload(self, artifact_root, artifact_relative_path, payload_json);
    }

    pub fn writePrReviewTextArtifact(self: *Session, artifact_root: []const u8, artifact_relative_path: []const u8, content: []const u8) ![]u8 {
        return pr_review_venom.writePrReviewTextArtifact(self, artifact_root, artifact_relative_path, content);
    }

    pub fn buildPrReviewContextPayloadJson(
        self: *Session,
        provider: []const u8,
        repo_key: []const u8,
        pr_number: u64,
        pr_url: []const u8,
        base_branch: []const u8,
        base_sha: []const u8,
        head_branch: []const u8,
        head_sha: []const u8,
        checkout_path: []const u8,
        review_policy_paths_json: []const u8,
        default_review_commands_json: []const u8,
        approval_policy_json: []const u8,
    ) ![]u8 {
        return pr_review_venom.buildPrReviewContextPayloadJson(
            self,
            provider,
            repo_key,
            pr_number,
            pr_url,
            base_branch,
            base_sha,
            head_branch,
            head_sha,
            checkout_path,
            review_policy_paths_json,
            default_review_commands_json,
            approval_policy_json,
        );
    }

    pub fn buildDefaultPrReviewStatePayloadJson(self: *Session, head_sha: []const u8) ![]u8 {
        return pr_review_venom.buildDefaultPrReviewStatePayloadJson(self, head_sha);
    }

    pub fn buildPrReviewStatePayloadJson(self: *Session, state: PrReviewStateSnapshot) ![]u8 {
        return pr_review_venom.buildPrReviewStatePayloadJson(self, state);
    }

    pub fn buildPrReviewStartDetailJson(
        self: *Session,
        mission_json: []const u8,
        provider: []const u8,
        repo_key: []const u8,
        pr_number: u64,
        pr_url: []const u8,
        checkout_path: []const u8,
        context_path: []const u8,
        state_path: []const u8,
        artifact_root: []const u8,
    ) ![]u8 {
        return pr_review_venom.buildPrReviewStartDetailJson(
            self,
            mission_json,
            provider,
            repo_key,
            pr_number,
            pr_url,
            checkout_path,
            context_path,
            state_path,
            artifact_root,
        );
    }

    pub fn buildPrReviewIntakeDetailJson(
        self: *Session,
        mission_json: []const u8,
        provider: []const u8,
        repo_key: []const u8,
        pr_number: u64,
        pr_url: []const u8,
        checkout_path: []const u8,
        context_path: []const u8,
        state_path: []const u8,
        artifact_root: []const u8,
        provider_sync_path: ?[]const u8,
    ) ![]u8 {
        return pr_review_venom.buildPrReviewIntakeDetailJson(
            self,
            mission_json,
            provider,
            repo_key,
            pr_number,
            pr_url,
            checkout_path,
            context_path,
            state_path,
            artifact_root,
            provider_sync_path,
        );
    }

    pub fn buildPrReviewSyncDetailJson(
        self: *Session,
        mission_json: []const u8,
        phase: []const u8,
        state_path: []const u8,
        thread_actions_path: ?[]const u8,
        provider_sync_path: ?[]const u8,
        checkout_sync_path: ?[]const u8,
        repo_status_path: ?[]const u8,
        diff_range_path: ?[]const u8,
    ) ![]u8 {
        return pr_review_venom.buildPrReviewSyncDetailJson(
            self,
            mission_json,
            phase,
            state_path,
            thread_actions_path,
            provider_sync_path,
            checkout_sync_path,
            repo_status_path,
            diff_range_path,
        );
    }

    pub fn buildPrReviewValidationDetailJson(
        self: *Session,
        mission_json: []const u8,
        phase: []const u8,
        state_path: []const u8,
        validation_path: []const u8,
        session_create_path: ?[]const u8,
        command_paths_json: []const u8,
        session_close_path: ?[]const u8,
    ) ![]u8 {
        return pr_review_venom.buildPrReviewValidationDetailJson(
            self,
            mission_json,
            phase,
            state_path,
            validation_path,
            session_create_path,
            command_paths_json,
            session_close_path,
        );
    }

    pub fn buildPrReviewReviewDetailJson(
        self: *Session,
        mission_json: []const u8,
        phase: []const u8,
        state_path: []const u8,
        findings_path: []const u8,
        recommendation_path: []const u8,
        review_comment_path: ?[]const u8,
        thread_actions_path: ?[]const u8,
        publish_review_path: ?[]const u8,
    ) ![]u8 {
        return pr_review_venom.buildPrReviewReviewDetailJson(
            self,
            mission_json,
            phase,
            state_path,
            findings_path,
            recommendation_path,
            review_comment_path,
            thread_actions_path,
            publish_review_path,
        );
    }

    pub fn buildPrReviewSuccessResultJson(self: *Session, op: PrReviewOp, result_json: []const u8) ![]u8 {
        return pr_review_venom.buildPrReviewSuccessResultJson(self, op, result_json);
    }

    pub fn buildPrReviewPartialFailureResultJson(
        self: *Session,
        op: PrReviewOp,
        result_json: []const u8,
        code: []const u8,
        message: []const u8,
    ) ![]u8 {
        return pr_review_venom.buildPrReviewPartialFailureResultJson(self, op, result_json, code, message);
    }

    pub fn buildPrReviewFailureResultJson(self: *Session, op: PrReviewOp, code: []const u8, message: []const u8) ![]u8 {
        return pr_review_venom.buildPrReviewFailureResultJson(self, op, code, message);
    }

    pub fn buildPrReviewValidationReportJson(
        self: *Session,
        status: []const u8,
        summary: []const u8,
        session_create_path: ?[]const u8,
        commands_json: []const u8,
        session_close_path: ?[]const u8,
    ) ![]u8 {
        return pr_review_venom.buildPrReviewValidationReportJson(
            self,
            status,
            summary,
            session_create_path,
            commands_json,
            session_close_path,
        );
    }

    pub fn buildPrReviewValidationCommandEntryJson(
        self: *Session,
        index: usize,
        request_payload_json: []const u8,
        capture_path: []const u8,
        result_payload_json: []const u8,
        exit_code: ?i32,
        error_code: ?[]const u8,
        error_message: ?[]const u8,
    ) ![]u8 {
        return pr_review_venom.buildPrReviewValidationCommandEntryJson(
            self,
            index,
            request_payload_json,
            capture_path,
            result_payload_json,
            exit_code,
            error_code,
            error_message,
        );
    }

    fn seedAgentMissionsNamespace(self: *Session, missions_dir: u32) !void {
        return missions_venom.seedNamespace(self, missions_dir);
    }

    fn seedAgentMissionsNamespaceAt(self: *Session, missions_dir: u32, base_path: []const u8) !void {
        return missions_venom.seedNamespaceAt(self, missions_dir, base_path);
    }

    pub const MissionOp = missions_venom.Op;

    fn handleMissionsNamespaceWrite(self: *Session, special: SpecialKind, node_id: u32, raw_input: []const u8) !WriteOutcome {
        return .{ .written = try missions_venom.handleNamespaceWrite(self, special, node_id, raw_input) };
    }

    const ResolvedMissionBootstrapContract = missions_venom.ResolvedBootstrapContract;

    pub fn parseMissionContractInput(self: *Session, args_obj: std.json.ObjectMap) !?mission_store_mod.MissionContractInput {
        return missions_venom.parseMissionContractInput(self, args_obj);
    }

    pub fn parseMissionContractUpdateInput(self: *Session, args_obj: std.json.ObjectMap) !?mission_store_mod.MissionContractUpdateInput {
        return missions_venom.parseMissionContractUpdateInput(self, args_obj);
    }

    pub fn resolveMissionBootstrapContract(
        self: *Session,
        mission: mission_store_mod.MissionRecord,
        args_obj: std.json.ObjectMap,
    ) !ResolvedMissionBootstrapContract {
        return missions_venom.resolveMissionBootstrapContract(self, mission, args_obj);
    }

    pub fn resolveMissionContractHostPath(self: *Session, absolute_path: []const u8) ![]u8 {
        return missions_venom.resolveContractHostPath(self, absolute_path);
    }

    pub fn ensureMissionContractDirectory(self: *Session, absolute_path: []const u8) !void {
        return missions_venom.ensureContractDirectory(self, absolute_path);
    }

    pub fn writeMissionContractFile(self: *Session, absolute_path: []const u8, content: []const u8) !void {
        return missions_venom.writeContractFile(self, absolute_path, content);
    }

    pub fn normalizeMissionAbsolutePath(self: *Session, raw: []const u8) ![]u8 {
        return missions_venom.normalizeMissionAbsolutePath(self, raw);
    }

    pub fn deriveMissionServiceInvokePath(self: *Session, service_path: []const u8) ![]u8 {
        return missions_venom.deriveMissionServiceInvokePath(self, service_path);
    }

    pub fn buildMissionServiceInvokeRequestPayload(self: *Session, args_obj: std.json.ObjectMap) ![]u8 {
        return missions_venom.buildMissionServiceInvokeRequestPayload(self, args_obj);
    }

    pub fn buildMissionServiceInvocationDetailJson(
        self: *Session,
        mission_json: []const u8,
        service_path: []const u8,
        invoke_path: []const u8,
        request_payload_json: []const u8,
        result_payload_json: []const u8,
        status_payload_json: ?[]const u8,
    ) ![]u8 {
        return missions_venom.buildMissionServiceInvocationDetailJson(
            self,
            mission_json,
            service_path,
            invoke_path,
            request_payload_json,
            result_payload_json,
            status_payload_json,
        );
    }

    pub fn buildMissionBootstrapContractDetailJson(
        self: *Session,
        mission_json: []const u8,
        context_path: []const u8,
        state_path: []const u8,
        artifact_root: []const u8,
    ) ![]u8 {
        return missions_venom.buildMissionBootstrapContractDetailJson(self, mission_json, context_path, state_path, artifact_root);
    }

    pub fn buildMissionSuccessResultJson(self: *Session, op: MissionOp, result_json: []const u8) ![]u8 {
        return missions_venom.buildMissionSuccessResultJson(self, op, result_json);
    }

    pub fn buildMissionPartialFailureResultJson(
        self: *Session,
        op: MissionOp,
        result_json: []const u8,
        code: []const u8,
        message: []const u8,
    ) ![]u8 {
        return missions_venom.buildMissionPartialFailureResultJson(self, op, result_json, code, message);
    }

    pub fn buildMissionListJson(self: *Session, missions: []const mission_store_mod.MissionRecord) ![]u8 {
        return missions_venom.buildMissionListJson(self, missions);
    }

    pub fn buildMissionRecordJson(self: *Session, mission: mission_store_mod.MissionRecord) ![]u8 {
        return missions_venom.buildMissionRecordJson(self, mission);
    }

    pub fn buildMissionContractJson(self: *Session, contract: mission_store_mod.MissionContract) ![]u8 {
        return missions_venom.buildMissionContractJson(self, contract);
    }

    pub fn buildMissionArtifactJson(self: *Session, artifact: mission_store_mod.MissionArtifact) ![]u8 {
        return missions_venom.buildMissionArtifactJson(self, artifact);
    }

    pub fn buildMissionEventJson(self: *Session, event: mission_store_mod.MissionEvent) ![]u8 {
        return missions_venom.buildMissionEventJson(self, event);
    }

    pub fn buildMissionApprovalJson(self: *Session, approval: mission_store_mod.MissionApproval) ![]u8 {
        return missions_venom.buildMissionApprovalJson(self, approval);
    }

    pub fn renderJsonValue(self: *Session, value: std.json.Value) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(value, .{})});
    }

    fn nextInternalFsrpcIds(self: *Session) InternalFsrpcIds {
        const seq = self.next_internal_fsrpc_seq;
        self.next_internal_fsrpc_seq +%= 1;
        if (self.next_internal_fsrpc_seq == 0) self.next_internal_fsrpc_seq = 1;
        return .{
            .attach_fid = 0x7000_0000 +% (seq *% 2),
            .walk_fid = 0x7000_0001 +% (seq *% 2),
            .tag_base = 0x7100_0000 +% (seq *% 8),
        };
    }

    fn ensureNamespaceMount(self: *Session) ![]const u8 {
        if (!self.canUseNamespaceShellExec()) return error.UnsupportedPlatform;
        if (self.namespace_mount_point) |mount_point| {
            if (self.namespace_mount_ready) return mount_point;
        }

        self.cleanupNamespaceMount();

        const sandbox_mounts_root = self.sandbox_mounts_root orelse return error.InvalidState;
        const project_id = self.project_id orelse return error.InvalidState;
        const namespace_mount_url = self.namespace_mount_url orelse return error.InvalidState;
        const namespace_session_key = self.namespace_session_key orelse return error.InvalidState;
        const sandbox_fs_mount_bin = self.sandbox_fs_mount_bin orelse return error.InvalidState;
        const helper_session_key = try self.buildTerminalHelperSessionKey(namespace_session_key);
        defer self.allocator.free(helper_session_key);
        const probe_session_key = try self.buildTerminalProbeSessionKey(namespace_session_key);
        defer self.allocator.free(probe_session_key);

        const project_component = try sanitizePathComponent(self.allocator, project_id);
        defer self.allocator.free(project_component);
        const agent_component = try sanitizePathComponent(self.allocator, self.agent_id);
        defer self.allocator.free(agent_component);
        const session_component = try sanitizePathComponent(self.allocator, helper_session_key);
        defer self.allocator.free(session_component);

        var mount_dir = try std.fs.path.join(
            self.allocator,
            &.{ sandbox_mounts_root, "terminal-ns", project_component, agent_component, session_component },
        );
        errdefer if (mount_dir.len > 0) self.allocator.free(mount_dir);
        var mount_point = try std.fs.path.join(self.allocator, &.{ mount_dir, "mount" });
        errdefer if (mount_point.len > 0) self.allocator.free(mount_point);
        try ensureAbsoluteDirectoryExists(mount_point);

        var argv = std.ArrayListUnmanaged([]const u8){};
        defer argv.deinit(self.allocator);
        try argv.append(self.allocator, sandbox_fs_mount_bin);
        try argv.append(self.allocator, "--namespace-url");
        try argv.append(self.allocator, namespace_mount_url);
        try argv.append(self.allocator, "--workspace-id");
        try argv.append(self.allocator, project_id);
        if (self.namespace_auth_token orelse self.control_operator_token orelse self.project_token) |token| {
            try argv.append(self.allocator, "--auth-token");
            try argv.append(self.allocator, token);
        }
        try argv.append(self.allocator, "--agent-id");
        try argv.append(self.allocator, self.agent_id);
        try argv.append(self.allocator, "--session-key");
        try argv.append(self.allocator, helper_session_key);
        try argv.append(self.allocator, "--namespace-keepalive-interval-ms");
        try argv.append(self.allocator, "15000");
        try argv.append(self.allocator, "mount");
        try argv.append(self.allocator, mount_point);

        var child = std.process.Child.init(argv.items, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Inherit;
        try child.spawn();

        self.namespace_mount_dir = mount_dir;
        self.namespace_mount_point = mount_point;
        self.namespace_mount_child = child;
        mount_dir = mount_dir[0..0];
        mount_point = mount_point[0..0];
        errdefer self.cleanupNamespaceMount();

        try self.waitForNamespaceMountReady(probe_session_key);
        self.namespace_mount_ready = true;
        return self.namespace_mount_point.?;
    }

    fn buildTerminalHelperSessionKey(self: *Session, base_session_key: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "termns-{s}", .{base_session_key});
    }

    fn buildTerminalProbeSessionKey(self: *Session, base_session_key: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "termprobe-{s}", .{base_session_key});
    }

    fn waitForNamespaceMountReady(self: *Session, probe_session_key: []const u8) !void {
        var attempt: usize = 0;
        while (attempt < 200) : (attempt += 1) {
            if (try self.probeNamespaceMountReady(probe_session_key)) return;
            std.Thread.sleep(25 * std.time.ns_per_ms);
        }
        self.cleanupNamespaceMount();
        return error.Timeout;
    }

    fn probeNamespaceMountReady(self: *Session, probe_session_key: []const u8) !bool {
        const sandbox_fs_mount_bin = self.sandbox_fs_mount_bin orelse return error.InvalidState;
        const namespace_mount_url = self.namespace_mount_url orelse return error.InvalidState;
        const project_id = self.project_id orelse return error.InvalidState;

        var argv = std.ArrayListUnmanaged([]const u8){};
        defer argv.deinit(self.allocator);
        try argv.append(self.allocator, sandbox_fs_mount_bin);
        try argv.append(self.allocator, "--namespace-url");
        try argv.append(self.allocator, namespace_mount_url);
        try argv.append(self.allocator, "--workspace-id");
        try argv.append(self.allocator, project_id);
        if (self.namespace_auth_token orelse self.control_operator_token orelse self.project_token) |token| {
            try argv.append(self.allocator, "--auth-token");
            try argv.append(self.allocator, token);
        }
        try argv.append(self.allocator, "--agent-id");
        try argv.append(self.allocator, self.agent_id);
        try argv.append(self.allocator, "--session-key");
        try argv.append(self.allocator, probe_session_key);
        try argv.append(self.allocator, "readdir");
        try argv.append(self.allocator, "/");

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv.items,
            .max_output_bytes = 64 * 1024,
        }) catch return false;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        return switch (result.term) {
            .Exited => |code| code == 0 and std.mem.indexOf(u8, result.stdout, "\"meta\"") != null,
            else => false,
        };
    }

    fn executeNamespaceShellExecPayload(self: *Session, args_obj: std.json.ObjectMap) ![]u8 {
        const mount_point = try self.ensureNamespaceMount();
        const command = if (args_obj.get("command")) |value|
            if (value == .string) value.string else return error.InvalidPayload
        else
            return error.InvalidPayload;
        const timeout_ms = if (args_obj.get("timeout_ms")) |value| switch (value) {
            .integer => |raw| blk: {
                if (raw < 0) return error.InvalidPayload;
                break :blk @as(u64, @intCast(raw));
            },
            .float => |raw| blk: {
                if (raw < 0 or std.math.floor(raw) != raw) return error.InvalidPayload;
                break :blk @as(u64, @intFromFloat(raw));
            },
            .null => null,
            else => return error.InvalidPayload,
        } else null;
        const cwd_value = if (args_obj.get("cwd")) |value|
            if (value == .string) value.string else if (value == .null) null else return error.InvalidPayload
        else
            null;
        const namespace_cwd = try self.resolveNamespaceShellCwd(cwd_value);
        defer self.allocator.free(namespace_cwd);

        var argv = std.ArrayListUnmanaged([]const u8){};
        defer argv.deinit(self.allocator);
        var owned_bind_sources = std.ArrayListUnmanaged([]u8){};
        defer {
            for (owned_bind_sources.items) |source| self.allocator.free(source);
            owned_bind_sources.deinit(self.allocator);
        }
        const sandbox_launcher = self.sandbox_launcher orelse return error.InvalidState;
        try argv.append(self.allocator, sandbox_launcher);
        try argv.append(self.allocator, "--die-with-parent");
        try argv.append(self.allocator, "--proc");
        try argv.append(self.allocator, "/proc");
        try argv.append(self.allocator, "--dev");
        try argv.append(self.allocator, "/dev");
        try argv.append(self.allocator, "--tmpfs");
        try argv.append(self.allocator, "/tmp");
        try argv.append(self.allocator, "--setenv");
        try argv.append(self.allocator, "HOME");
        try argv.append(self.allocator, "/tmp");
        try argv.append(self.allocator, "--setenv");
        try argv.append(self.allocator, "TMPDIR");
        try argv.append(self.allocator, "/tmp");
        try argv.append(self.allocator, "--setenv");
        try argv.append(self.allocator, "PATH");
        try argv.append(self.allocator, "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");

        try appendExistingBindArg(self.allocator, &argv, "--ro-bind", "/bin", "/bin");
        try appendExistingBindArg(self.allocator, &argv, "--ro-bind", "/usr", "/usr");
        try appendExistingBindArg(self.allocator, &argv, "--ro-bind", "/lib", "/lib");
        try appendExistingBindArg(self.allocator, &argv, "--ro-bind", "/lib64", "/lib64");
        try appendExistingBindArg(self.allocator, &argv, "--ro-bind", "/sbin", "/sbin");
        try appendExistingBindArg(self.allocator, &argv, "--ro-bind", "/etc", "/etc");
        try appendExistingBindArg(self.allocator, &argv, "--ro-bind", "/opt", "/opt");
        try appendExistingBindArg(self.allocator, &argv, "--ro-bind", "/run", "/run");

        try self.appendNamespaceBindArg(&argv, &owned_bind_sources, mount_point, "meta", "/meta");
        try self.appendNamespaceBindArg(&argv, &owned_bind_sources, mount_point, "projects", "/projects");
        try self.appendNamespaceBindArg(&argv, &owned_bind_sources, mount_point, "services", "/services");
        try self.appendNamespaceBindArg(&argv, &owned_bind_sources, mount_point, "shared_data", "/shared_data");
        try self.appendNamespaceBindArg(&argv, &owned_bind_sources, mount_point, "nodes", "/nodes");
        try self.appendNamespaceBindArg(&argv, &owned_bind_sources, mount_point, "global", "/global");
        try self.appendNamespaceBindArg(&argv, &owned_bind_sources, mount_point, "agents", "/agents");

        try argv.append(self.allocator, "--chdir");
        try argv.append(self.allocator, namespace_cwd);

        const shell_path = if (pathExistsAbsolute("/bin/bash")) "/bin/bash" else "/bin/sh";
        const timeout_path = "/usr/bin/timeout";
        var timeout_arg: ?[]u8 = null;
        defer if (timeout_arg) |value| self.allocator.free(value);
        if (timeout_ms) |value| {
            if (value > 0 and pathExistsAbsolute(timeout_path)) {
                const timeout_secs = @max(@as(u64, 1), (value + 999) / 1000);
                timeout_arg = try std.fmt.allocPrint(self.allocator, "{d}s", .{timeout_secs});
                try argv.append(self.allocator, timeout_path);
                try argv.append(self.allocator, "--signal=TERM");
                try argv.append(self.allocator, "--kill-after=2s");
                try argv.append(self.allocator, timeout_arg.?);
            }
        }
        try argv.append(self.allocator, shell_path);
        try argv.append(self.allocator, "-lc");
        try argv.append(self.allocator, command);

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv.items,
            .max_output_bytes = 8 * 1024 * 1024,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        const exit_code: i32 = switch (result.term) {
            .Exited => |code| @intCast(code),
            .Signal => |sig| 128 + @as(i32, @intCast(sig)),
            else => 1,
        };
        return self.buildShellExecPayloadJson(exit_code, result.stdout, result.stderr);
    }

    fn resolveNamespaceShellCwd(self: *Session, cwd_value: ?[]const u8) ![]u8 {
        if (cwd_value) |value| {
            if (value.len > 0 and value[0] == '/') return self.allocator.dupe(u8, value);
            if (value.len == 0 or std.mem.eql(u8, value, ".")) return self.allocator.dupe(u8, local_fs_world_prefix);
            return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ local_fs_world_prefix, std.mem.trimLeft(u8, value, "./") });
        }
        return self.allocator.dupe(u8, local_fs_world_prefix);
    }

    fn appendNamespaceBindArg(
        self: *Session,
        argv: *std.ArrayListUnmanaged([]const u8),
        owned_bind_sources: *std.ArrayListUnmanaged([]u8),
        mount_point: []const u8,
        relative: []const u8,
        target: []const u8,
    ) !void {
        const source = try std.fs.path.join(self.allocator, &.{ mount_point, relative });
        if (!pathExistsAbsolute(source)) return;
        try owned_bind_sources.append(self.allocator, source);
        try argv.append(self.allocator, "--bind");
        try argv.append(self.allocator, source);
        try argv.append(self.allocator, target);
    }

    fn buildShellExecPayloadJson(self: *Session, exit_code: i32, stdout: []const u8, stderr: []const u8) ![]u8 {
        const escaped_stdout = try unified.jsonEscape(self.allocator, stdout);
        defer self.allocator.free(escaped_stdout);
        const escaped_stderr = try unified.jsonEscape(self.allocator, stderr);
        defer self.allocator.free(escaped_stderr);
        return std.fmt.allocPrint(
            self.allocator,
            "{{\"exit_code\":{d},\"stdout\":\"{s}\",\"stderr\":\"{s}\"}}",
            .{ exit_code, escaped_stdout, escaped_stderr },
        );
    }

    fn allocAbsolutePathSegments(self: *Session, absolute_path: []const u8) anyerror![][]u8 {
        if (absolute_path.len == 0 or absolute_path[0] != '/') return error.InvalidPayload;
        var count: usize = 0;
        var iter = std.mem.splitScalar(u8, absolute_path, '/');
        while (iter.next()) |segment| {
            if (segment.len == 0) continue;
            count += 1;
        }

        var segments = try self.allocator.alloc([]u8, count);
        errdefer self.allocator.free(segments);

        var index: usize = 0;
        errdefer {
            var cleanup_index: usize = 0;
            while (cleanup_index < index) : (cleanup_index += 1) self.allocator.free(segments[cleanup_index]);
        }

        iter = std.mem.splitScalar(u8, absolute_path, '/');
        while (iter.next()) |segment| {
            if (segment.len == 0) continue;
            segments[index] = try self.allocator.dupe(u8, segment);
            index += 1;
        }
        return segments;
    }

    fn internalClunk(self: *Session, fid: u32, tag: u32) void {
        var clunk = unified.ParsedMessage{
            .channel = .acheron,
            .acheron_type = .t_clunk,
            .tag = tag,
            .fid = fid,
        };
        const frame = self.handle(&clunk) catch return;
        self.allocator.free(frame);
    }

    fn parseInternalFsrpcError(self: *Session, frame: []const u8) anyerror!?InternalFsrpcErrorInfo {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame, .{}) catch return error.InvalidPayload;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidPayload;
        const ok_value = parsed.value.object.get("ok") orelse return error.InvalidPayload;
        if (ok_value == .bool and ok_value.bool) return null;

        const error_value = parsed.value.object.get("error") orelse return error.InvalidPayload;
        if (error_value != .object) return error.InvalidPayload;
        const code = if (error_value.object.get("code")) |value|
            if (value == .string and value.string.len > 0) value.string else "internal_error"
        else
            "internal_error";
        const message = if (error_value.object.get("message")) |value|
            if (value == .string and value.string.len > 0) value.string else "internal fsrpc request failed"
        else
            "internal fsrpc request failed";
        return .{
            .code = try self.allocator.dupe(u8, code),
            .message = try self.allocator.dupe(u8, message),
        };
    }

    pub fn writeInternalPath(self: *Session, absolute_path: []const u8, data: []const u8) anyerror!?InternalFsrpcErrorInfo {
        const ids = self.nextInternalFsrpcIds();
        const segments = try self.allocAbsolutePathSegments(absolute_path);
        defer freePathSegments(self.allocator, segments);
        defer self.internalClunk(ids.walk_fid, ids.tag_base + 4);
        defer self.internalClunk(ids.attach_fid, ids.tag_base + 5);

        var attach = unified.ParsedMessage{
            .channel = .acheron,
            .acheron_type = .t_attach,
            .tag = ids.tag_base,
            .fid = ids.attach_fid,
        };
        const attach_frame = try self.handle(&attach);
        defer self.allocator.free(attach_frame);
        if (try self.parseInternalFsrpcError(attach_frame)) |err| return err;

        var walk = unified.ParsedMessage{
            .channel = .acheron,
            .acheron_type = .t_walk,
            .tag = ids.tag_base + 1,
            .fid = ids.attach_fid,
            .newfid = ids.walk_fid,
            .path = segments,
        };
        const walk_frame = try self.handle(&walk);
        defer self.allocator.free(walk_frame);
        if (try self.parseInternalFsrpcError(walk_frame)) |err| return err;

        var open = unified.ParsedMessage{
            .channel = .acheron,
            .acheron_type = .t_open,
            .tag = ids.tag_base + 2,
            .fid = ids.walk_fid,
            .mode = @constCast("w"),
        };
        const open_frame = try self.handle(&open);
        defer self.allocator.free(open_frame);
        if (try self.parseInternalFsrpcError(open_frame)) |err| return err;

        var write = unified.ParsedMessage{
            .channel = .acheron,
            .acheron_type = .t_write,
            .tag = ids.tag_base + 3,
            .fid = ids.walk_fid,
            .offset = 0,
            .data = @constCast(data),
        };
        const write_frame = try self.handle(&write);
        defer self.allocator.free(write_frame);
        if (try self.parseInternalFsrpcError(write_frame)) |err| return err;
        return null;
    }

    pub fn tryReadInternalPath(self: *Session, absolute_path: []const u8) anyerror!?[]u8 {
        return self.readInternalPathMaterialized(absolute_path, null) catch |err| switch (err) {
            error.FileNotFound,
            error.AccessDenied,
            error.IsDir,
            error.NotDir,
            error.OperationNotSupported,
            => null,
            else => return err,
        };
    }

    fn readInternalPathMaterialized(
        self: *Session,
        absolute_path: []const u8,
        max_bytes: ?usize,
    ) ![]u8 {
        const ids = self.nextInternalFsrpcIds();
        const segments = try self.allocAbsolutePathSegments(absolute_path);
        defer freePathSegments(self.allocator, segments);
        defer self.internalClunk(ids.walk_fid, ids.tag_base + 4);
        defer self.internalClunk(ids.attach_fid, ids.tag_base + 5);

        var attach = unified.ParsedMessage{
            .channel = .acheron,
            .acheron_type = .t_attach,
            .tag = ids.tag_base,
            .fid = ids.attach_fid,
        };
        const attach_frame = try self.handle(&attach);
        defer self.allocator.free(attach_frame);
        if (try self.parseInternalFsrpcError(attach_frame)) |err| {
            defer err.deinit(self.allocator);
            return mapInternalMountReadError(err.code);
        }

        var walk = unified.ParsedMessage{
            .channel = .acheron,
            .acheron_type = .t_walk,
            .tag = ids.tag_base + 1,
            .fid = ids.attach_fid,
            .newfid = ids.walk_fid,
            .path = segments,
        };
        const walk_frame = try self.handle(&walk);
        defer self.allocator.free(walk_frame);
        if (try self.parseInternalFsrpcError(walk_frame)) |err| {
            defer err.deinit(self.allocator);
            return mapInternalMountReadError(err.code);
        }

        var open = unified.ParsedMessage{
            .channel = .acheron,
            .acheron_type = .t_open,
            .tag = ids.tag_base + 2,
            .fid = ids.walk_fid,
            .mode = @constCast("r"),
        };
        const open_frame = try self.handle(&open);
        defer self.allocator.free(open_frame);
        if (try self.parseInternalFsrpcError(open_frame)) |err| {
            defer err.deinit(self.allocator);
            return mapInternalMountReadError(err.code);
        }

        const max_total = max_bytes orelse std.math.maxInt(usize);
        var offset: u64 = 0;
        var content = std.ArrayListUnmanaged(u8){};
        errdefer content.deinit(self.allocator);

        while (content.items.len < max_total) {
            const remaining = max_total - content.items.len;
            const request_count: usize = @min(remaining, 1_048_576);
            if (request_count == 0) break;

            var read = unified.ParsedMessage{
                .channel = .acheron,
                .acheron_type = .t_read,
                .tag = ids.tag_base + 3,
                .fid = ids.walk_fid,
                .offset = offset,
                .count = @intCast(request_count),
            };
            const read_frame = try self.handle(&read);
            defer self.allocator.free(read_frame);
            if (try self.parseInternalFsrpcError(read_frame)) |err| {
                defer err.deinit(self.allocator);
                return mapInternalMountReadError(err.code);
            }

            const chunk = try self.decodeAcheronReadPayload(read_frame);
            defer self.allocator.free(chunk);
            if (chunk.len == 0) break;

            try content.appendSlice(self.allocator, chunk);
            offset = std.math.add(u64, offset, @as(u64, chunk.len)) catch return error.InvalidOffset;
            if (chunk.len < request_count) break;
        }
        return content.toOwnedSlice(self.allocator);
    }

    pub fn readMountGraphFile(self: *Session, absolute_path: []const u8, offset: u64, max_bytes: usize) ![]u8 {
        const start = std.math.cast(usize, offset) orelse return error.InvalidOffset;
        const required_len = std.math.add(usize, start, max_bytes) catch return error.InvalidOffset;
        const content = try self.readInternalPathMaterialized(absolute_path, required_len);
        defer self.allocator.free(content);

        if (start >= content.len) return self.allocator.dupe(u8, "");
        const end = @min(content.len, required_len);
        return self.allocator.dupe(u8, content[start..end]);
    }

    pub fn writeMountGraphFile(self: *Session, absolute_path: []const u8, data: []const u8) !void {
        if (try self.writeInternalPath(absolute_path, data)) |info| {
            defer info.deinit(self.allocator);
            return mapInternalMountWriteError(info.code);
        }
    }

    pub fn tryWriteLocalFsBackedMountFile(self: *Session, absolute_path: []const u8, data: []const u8) !bool {
        const normalized_path = std.mem.trimRight(u8, absolute_path, "/");
        const host_path = (try self.tryResolveMutableLocalFsBackedHostPath(normalized_path)) orelse return false;
        defer self.allocator.free(host_path);

        const host_parent = std.fs.path.dirname(host_path) orelse return false;
        var parent_dir = if (std.fs.path.isAbsolute(host_parent))
            std.fs.openDirAbsolute(host_parent, .{}) catch |err| switch (err) {
                error.FileNotFound,
                error.NotDir,
                => return false,
                else => return err,
            }
        else
            std.fs.cwd().openDir(host_parent, .{}) catch |err| switch (err) {
                error.FileNotFound,
                error.NotDir,
                => return false,
                else => return err,
            };
        parent_dir.close();

        const file = if (std.fs.path.isAbsolute(host_path))
            std.fs.createFileAbsolute(host_path, .{ .truncate = true }) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return err,
            }
        else
            std.fs.cwd().createFile(host_path, .{ .truncate = true }) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return err,
            };
        defer file.close();
        try file.writeAll(data);

        try self.refreshLocalFsBackedAbsolutePath(normalized_path);
        return true;
    }

    pub fn tryMkdirLocalFsBackedMountPath(self: *Session, absolute_path: []const u8) !bool {
        const normalized_path = std.mem.trimRight(u8, absolute_path, "/");
        const host_path = (try self.tryResolveMutableLocalFsBackedHostPath(normalized_path)) orelse return false;
        defer self.allocator.free(host_path);

        if (std.fs.path.isAbsolute(host_path))
            try std.fs.makeDirAbsolute(host_path)
        else
            try std.fs.cwd().makeDir(host_path);

        try self.refreshLocalFsBackedAbsolutePath(normalized_path);
        return true;
    }

    pub fn tryUnlinkLocalFsBackedMountPath(self: *Session, absolute_path: []const u8) !bool {
        const normalized_path = std.mem.trimRight(u8, absolute_path, "/");
        const host_path = (try self.tryResolveMutableLocalFsBackedHostPath(normalized_path)) orelse return false;
        defer self.allocator.free(host_path);

        if (std.fs.path.isAbsolute(host_path))
            try std.fs.deleteFileAbsolute(host_path)
        else
            try std.fs.cwd().deleteFile(host_path);

        try self.removeLocalFsBackedAbsolutePathFromMountGraph(normalized_path);
        try self.refreshLocalFsBackedParentAbsolutePath(normalized_path);
        return true;
    }

    pub fn tryRmdirLocalFsBackedMountPath(self: *Session, absolute_path: []const u8) !bool {
        const normalized_path = std.mem.trimRight(u8, absolute_path, "/");
        const host_path = (try self.tryResolveMutableLocalFsBackedHostPath(normalized_path)) orelse return false;
        defer self.allocator.free(host_path);

        if (std.fs.path.isAbsolute(host_path))
            try std.fs.deleteDirAbsolute(host_path)
        else
            try std.fs.cwd().deleteDir(host_path);

        try self.removeLocalFsBackedAbsolutePathFromMountGraph(normalized_path);
        try self.refreshLocalFsBackedParentAbsolutePath(normalized_path);
        return true;
    }

    pub fn tryRenameLocalFsBackedMountPath(self: *Session, old_absolute_path: []const u8, new_absolute_path: []const u8) !bool {
        const normalized_old_path = std.mem.trimRight(u8, old_absolute_path, "/");
        const normalized_new_path = std.mem.trimRight(u8, new_absolute_path, "/");
        const old_host_path = (try self.tryResolveMutableLocalFsBackedHostPath(normalized_old_path)) orelse return false;
        defer self.allocator.free(old_host_path);
        const new_host_path = (try self.tryResolveMutableLocalFsBackedHostPath(normalized_new_path)) orelse return false;
        defer self.allocator.free(new_host_path);

        if (std.fs.path.isAbsolute(old_host_path) and std.fs.path.isAbsolute(new_host_path))
            try std.fs.renameAbsolute(old_host_path, new_host_path)
        else
            try std.fs.cwd().rename(old_host_path, new_host_path);

        try self.removeLocalFsBackedAbsolutePathFromMountGraph(normalized_old_path);
        try self.refreshLocalFsBackedParentAbsolutePath(normalized_old_path);
        try self.refreshLocalFsBackedAbsolutePath(normalized_new_path);
        return true;
    }

    pub fn tryReadlinkLocalFsBackedMountPath(self: *Session, absolute_path: []const u8) !?[]u8 {
        const normalized_path = std.mem.trimRight(u8, absolute_path, "/");
        const host_path = (try self.tryResolveReadableLocalFsBackedHostPath(normalized_path)) orelse return null;
        defer self.allocator.free(host_path);

        var buffer_len: usize = 256;
        while (buffer_len <= 64 * 1024) : (buffer_len *= 2) {
            const buffer = try self.allocator.alloc(u8, buffer_len);
            defer self.allocator.free(buffer);
            const target = try std.posix.readlink(host_path, buffer);
            if (target.len < buffer_len) return try self.allocator.dupe(u8, target);
        }
        return error.NameTooLong;
    }

    pub fn trySymlinkLocalFsBackedMountPath(self: *Session, target: []const u8, link_absolute_path: []const u8) !bool {
        const normalized_link_path = std.mem.trimRight(u8, link_absolute_path, "/");
        const host_link_path = (try self.tryResolveMutableLocalFsBackedHostPath(normalized_link_path)) orelse return false;
        defer self.allocator.free(host_link_path);

        const host_parent = std.fs.path.dirname(host_link_path) orelse return false;
        var parent_dir = if (std.fs.path.isAbsolute(host_parent))
            std.fs.openDirAbsolute(host_parent, .{}) catch |err| switch (err) {
                error.FileNotFound,
                error.NotDir,
                => return false,
                else => return err,
            }
        else
            std.fs.cwd().openDir(host_parent, .{}) catch |err| switch (err) {
                error.FileNotFound,
                error.NotDir,
                => return false,
                else => return err,
            };
        parent_dir.close();

        if (std.fs.path.isAbsolute(host_link_path))
            try std.fs.symLinkAbsolute(target, host_link_path, .{})
        else
            try std.fs.cwd().symLink(target, host_link_path, .{});

        try self.refreshLocalFsBackedAbsolutePath(normalized_link_path);
        return true;
    }

    pub fn trySetxattrLocalFsBackedMountPath(self: *Session, absolute_path: []const u8, name: []const u8, value: []const u8, flags: u32) !bool {
        const normalized_path = std.mem.trimRight(u8, absolute_path, "/");
        const host_path = (try self.tryResolveMutableLocalFsBackedHostPath(normalized_path)) orelse return false;
        defer self.allocator.free(host_path);

        try shared_node.fs_local_source_adapter.setXattrAbsolute(self.allocator, host_path, name, value, flags);
        try self.refreshLocalFsBackedAbsolutePath(normalized_path);
        return true;
    }

    pub fn tryGetxattrLocalFsBackedMountPath(self: *Session, absolute_path: []const u8, name: []const u8) !?[]u8 {
        const normalized_path = std.mem.trimRight(u8, absolute_path, "/");
        const host_path = (try self.tryResolveReadableLocalFsBackedHostPath(normalized_path)) orelse return null;
        defer self.allocator.free(host_path);

        return try shared_node.fs_local_source_adapter.getXattrAbsolute(self.allocator, host_path, name);
    }

    pub fn tryListxattrLocalFsBackedMountPath(self: *Session, absolute_path: []const u8) !?[]u8 {
        const normalized_path = std.mem.trimRight(u8, absolute_path, "/");
        const host_path = (try self.tryResolveReadableLocalFsBackedHostPath(normalized_path)) orelse return null;
        defer self.allocator.free(host_path);

        return try shared_node.fs_local_source_adapter.listXattrAbsolute(self.allocator, host_path);
    }

    pub fn tryRemovexattrLocalFsBackedMountPath(self: *Session, absolute_path: []const u8, name: []const u8) !bool {
        const normalized_path = std.mem.trimRight(u8, absolute_path, "/");
        const host_path = (try self.tryResolveMutableLocalFsBackedHostPath(normalized_path)) orelse return false;
        defer self.allocator.free(host_path);

        try shared_node.fs_local_source_adapter.removeXattrAbsolute(self.allocator, host_path, name);
        try self.refreshLocalFsBackedAbsolutePath(normalized_path);
        return true;
    }

    pub fn tryLockLocalFsBackedMountPath(self: *Session, absolute_path: []const u8, mode_name: []const u8, wait: bool) !bool {
        const normalized_path = std.mem.trimRight(u8, absolute_path, "/");
        const mode: shared_node.fs_local_source_adapter.LockMode = if (std.mem.eql(u8, mode_name, "shared"))
            .shared
        else if (std.mem.eql(u8, mode_name, "exclusive"))
            .exclusive
        else if (std.mem.eql(u8, mode_name, "unlock"))
            .unlock
        else
            return error.InvalidArgument;

        if (mode == .unlock) {
            if (self.local_fs_lock_files.fetchRemove(normalized_path)) |removed| {
                self.allocator.free(removed.key);
                var entry = removed.value;
                defer entry.deinit();
                try shared_node.fs_local_source_adapter.lockFile(&entry.file, .unlock, true);
            }
            return true;
        }

        if (self.local_fs_lock_files.getPtr(normalized_path)) |entry| {
            try shared_node.fs_local_source_adapter.lockFile(&entry.file, mode, wait);
            return true;
        }

        const host_path = (try self.tryResolveReadableLocalFsBackedHostPath(normalized_path)) orelse return false;
        defer self.allocator.free(host_path);

        var file = if (std.fs.path.isAbsolute(host_path))
            std.fs.openFileAbsolute(host_path, .{ .mode = .read_only }) catch |err| switch (err) {
                error.FileNotFound,
                error.NotDir,
                => return false,
                else => return err,
            }
        else
            std.fs.cwd().openFile(host_path, .{ .mode = .read_only }) catch |err| switch (err) {
                error.FileNotFound,
                error.NotDir,
                => return false,
                else => return err,
            };
        errdefer file.close();

        try shared_node.fs_local_source_adapter.lockFile(&file, mode, wait);
        const owned_key = try self.allocator.dupe(u8, normalized_path);
        errdefer self.allocator.free(owned_key);
        try self.local_fs_lock_files.put(self.allocator, owned_key, .{
            .file = file,
        });
        return true;
    }

    pub fn trySetattrLocalFsBackedMountPath(
        self: *Session,
        absolute_path: []const u8,
        mode: ?u32,
        uid: ?u32,
        gid: ?u32,
        flags: ?u32,
        at_ns: ?i64,
        mt_ns: ?i64,
    ) !bool {
        const normalized_path = std.mem.trimRight(u8, absolute_path, "/");
        const host_path = (try self.tryResolveMutableLocalFsBackedHostPath(normalized_path)) orelse return false;
        defer self.allocator.free(host_path);

        const maybe_dir = if (std.fs.path.isAbsolute(host_path))
            std.fs.openDirAbsolute(host_path, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound,
                => return false,
                error.NotDir => null,
                else => return err,
            }
        else
            std.fs.cwd().openDir(host_path, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound,
                => return false,
                error.NotDir => null,
                else => return err,
            };

        if (maybe_dir) |dir_value| {
            var dir = dir_value;
            defer dir.close();

            if (mode) |value| try dir.chmod(@intCast(value & 0o7777));
            if (uid != null or gid != null) try dir.chown(uid, gid);

            if (at_ns != null or mt_ns != null) {
                const dir_file: std.fs.File = .{ .handle = dir.fd };
                const existing = try dir_file.stat();
                try dir_file.updateTimes(
                    at_ns orelse @intCast(existing.atime),
                    mt_ns orelse @intCast(existing.mtime),
                );
            }
        } else {
            var file = if (std.fs.path.isAbsolute(host_path))
                std.fs.openFileAbsolute(host_path, .{ .mode = .read_write }) catch |err| switch (err) {
                    error.FileNotFound,
                    error.NotDir,
                    => return false,
                    else => return err,
                }
            else
                std.fs.cwd().openFile(host_path, .{ .mode = .read_write }) catch |err| switch (err) {
                    error.FileNotFound,
                    error.NotDir,
                    => return false,
                    else => return err,
                };
            defer file.close();

            if (mode) |value| try file.chmod(@intCast(value & 0o7777));
            if (uid != null or gid != null) try file.chown(uid, gid);

            if (at_ns != null or mt_ns != null) {
                const existing = try file.stat();
                try file.updateTimes(
                    at_ns orelse @intCast(existing.atime),
                    mt_ns orelse @intCast(existing.mtime),
                );
            }
        }

        if (flags) |value| switch (builtin.os.tag) {
            .macos, .ios => {
                const path_z = try self.allocator.dupeZ(u8, host_path);
                defer self.allocator.free(path_z);
                if (c.chflags(path_z.ptr, value) != 0) {
                    return switch (std.c._errno().*) {
                        c.EACCES => error.AccessDenied,
                        c.EPERM => error.AccessDenied,
                        c.EROFS => error.ReadOnlyFileSystem,
                        c.EINVAL => error.InvalidArgument,
                        else => error.OperationNotSupported,
                    };
                }
            },
            else => if (value != 0) return error.OperationNotSupported,
        };

        try self.refreshLocalFsBackedAbsolutePath(normalized_path);
        return true;
    }

    pub fn buildMountGraphSnapshotPayload(
        self: *Session,
        workspace_json: []const u8,
        session_key: []const u8,
    ) ![]u8 {
        return self.buildMountGraphSnapshotPayloadForPath(workspace_json, session_key, "/", 1);
    }

    pub fn buildMountGraphSnapshotPayloadForPath(
        self: *Session,
        workspace_json: []const u8,
        session_key: []const u8,
        requested_path: []const u8,
        max_depth: u32,
    ) ![]u8 {
        const normalized_requested_path = try normalizeMountGraphPath(self.allocator, requested_path);
        defer self.allocator.free(normalized_requested_path);

        var sources = try self.parseMountGraphSources(workspace_json);
        defer {
            for (sources.items) |*source| source.deinit(self.allocator);
            sources.deinit(self.allocator);
        }

        var export_root_writable = std.StringHashMapUnmanaged(bool){};
        defer export_root_writable.deinit(self.allocator);
        for (sources.items) |source| {
            if (!mountGraphSourceRelevantToScope(normalized_requested_path, source.mount_path)) continue;
            try export_root_writable.put(self.allocator, source.mount_path, source.writable);
        }

        var nodes = std.ArrayListUnmanaged(MountGraphNodeRecord){};
        defer {
            for (nodes.items) |*node| node.deinit(self.allocator);
            nodes.deinit(self.allocator);
        }
        var path_to_index = std.StringHashMapUnmanaged(usize){};
        defer path_to_index.deinit(self.allocator);
        var next_overlay_id: u64 = self.next_node_id;
        if (std.mem.eql(u8, normalized_requested_path, "/")) {
            try self.appendMountGraphSubtree(
                &nodes,
                &path_to_index,
                self.root_id,
                "/",
                &export_root_writable,
                &next_overlay_id,
                max_depth,
            );
        } else {
            var requested_target = try self.resolveMountGraphRequestedTarget(normalized_requested_path);
            defer requested_target.deinit(self.allocator);
            self.refreshDynamicDirectory(requested_target.node_id) catch {};

            if (requested_target.projected) {
                try self.appendProjectedMountGraphRequestedPath(
                    &nodes,
                    &path_to_index,
                        normalized_requested_path,
                        requested_target.actual_path,
                        requested_target.node_id,
                        &export_root_writable,
                        &next_overlay_id,
                        max_depth,
                    );
            } else {
                try self.appendMountGraphAncestorChain(
                        &nodes,
                        &path_to_index,
                        requested_target.node_id,
                        &export_root_writable,
                    );
                    try self.appendMountGraphSubtree(
                        &nodes,
                        &path_to_index,
                        requested_target.node_id,
                        normalized_requested_path,
                        &export_root_writable,
                        &next_overlay_id,
                        max_depth,
                    );
            }
        }
        for (sources.items) |*source| {
            if (!mountGraphSourceRelevantToScope(normalized_requested_path, source.mount_path)) continue;
            try self.overlayMountGraphSource(
                &nodes,
                &path_to_index,
                source,
                &next_overlay_id,
            );
        }

        std.mem.sort(MountGraphSourceRecord, sources.items, {}, struct {
            fn lessThan(_: void, lhs: MountGraphSourceRecord, rhs: MountGraphSourceRecord) bool {
                return std.mem.lessThan(u8, lhs.mount_path, rhs.mount_path);
            }
        }.lessThan);
        std.mem.sort(MountGraphNodeRecord, nodes.items, {}, struct {
            fn lessThan(_: void, lhs: MountGraphNodeRecord, rhs: MountGraphNodeRecord) bool {
                return std.mem.lessThan(u8, lhs.path, rhs.path);
            }
        }.lessThan);

        const nodes_json = try self.buildMountGraphNodesJson(nodes.items);
        defer self.allocator.free(nodes_json);
        const sources_json = try self.buildMountGraphSourcesJson(sources.items);
        defer self.allocator.free(sources_json);

        const mount_session_id = try std.fmt.allocPrint(
            self.allocator,
            "mount-v2:{s}:{s}",
            .{ self.agent_id, session_key },
        );
        defer self.allocator.free(mount_session_id);
        const escaped_mount_session_id = try unified.jsonEscape(self.allocator, mount_session_id);
        defer self.allocator.free(escaped_mount_session_id);

        const payload_without_generation = try std.fmt.allocPrint(
            self.allocator,
            "{{\"mount_session_id\":\"{s}\",\"graph_generation\":0,\"root_node_id\":{d},\"nodes\":{s},\"sources\":{s}}}",
            .{ escaped_mount_session_id, self.root_id, nodes_json, sources_json },
        );
        defer self.allocator.free(payload_without_generation);
        const graph_generation = std.hash.Wyhash.hash(0, payload_without_generation);

        return std.fmt.allocPrint(
            self.allocator,
            "{{\"mount_session_id\":\"{s}\",\"graph_generation\":{d},\"root_node_id\":{d},\"nodes\":{s},\"sources\":{s}}}",
            .{ escaped_mount_session_id, graph_generation, self.root_id, nodes_json, sources_json },
        );
    }

    const MountGraphRequestedTarget = struct {
        node_id: u32,
        actual_path: []u8,
        projected: bool,

        fn deinit(self: *MountGraphRequestedTarget, allocator: std.mem.Allocator) void {
            allocator.free(self.actual_path);
            self.* = undefined;
        }
    };

    fn resolveMountGraphRequestedTarget(
        self: *Session,
        normalized_requested_path: []const u8,
    ) !MountGraphRequestedTarget {
        if (try self.resolveBoundPath(normalized_requested_path)) |rebound| {
            if (!std.mem.eql(u8, rebound, normalized_requested_path)) {
                if (try self.resolveAbsolutePathForMountGraphNoBinds(rebound)) |rebound_node_id| {
                    return .{
                        .node_id = rebound_node_id,
                        .actual_path = rebound,
                        .projected = true,
                    };
                }
                self.allocator.free(rebound);
            } else {
                self.allocator.free(rebound);
            }
        }

        if (try self.resolveAbsolutePathForMountGraphNoBinds(normalized_requested_path)) |node_id| {
            return .{
                .node_id = node_id,
                .actual_path = try self.allocator.dupe(u8, normalized_requested_path),
                .projected = false,
            };
        }

        const rebound = try self.resolveBoundPath(normalized_requested_path) orelse return error.FileNotFound;
        errdefer self.allocator.free(rebound);
        const node_id = try self.resolveAbsolutePathForMountGraphNoBinds(rebound) orelse return error.FileNotFound;
        return .{
            .node_id = node_id,
            .actual_path = rebound,
            .projected = !std.mem.eql(u8, rebound, normalized_requested_path),
        };
    }

    fn decodeAcheronReadPayload(self: *Session, frame: []const u8) anyerror![]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame, .{}) catch return error.InvalidPayload;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidPayload;

        const payload = parsed.value.object.get("payload") orelse return error.InvalidPayload;
        if (payload != .object) return error.InvalidPayload;
        const data_b64 = payload.object.get("data_b64") orelse return error.InvalidPayload;
        if (data_b64 != .string) return error.InvalidPayload;

        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(data_b64.string);
        const decoded = try self.allocator.alloc(u8, decoded_len);
        errdefer self.allocator.free(decoded);
        try std.base64.standard.Decoder.decode(decoded, data_b64.string);
        return decoded;
    }

    fn parseMountGraphSources(self: *Session, workspace_json: []const u8) !std.ArrayListUnmanaged(MountGraphSourceRecord) {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, workspace_json, .{});
        defer parsed.deinit();

        var out = std.ArrayListUnmanaged(MountGraphSourceRecord){};
        errdefer {
            for (out.items) |*source| source.deinit(self.allocator);
            out.deinit(self.allocator);
        }

        if (parsed.value != .object) return out;
        const mounts_value = parsed.value.object.get("mounts") orelse return out;
        if (mounts_value != .array) return out;

        for (mounts_value.array.items) |mount_value| {
            if (mount_value != .object) continue;
            const mount_path_raw = mount_value.object.get("mount_path") orelse continue;
            const fs_url_raw = mount_value.object.get("fs_url") orelse continue;
            if (mount_path_raw != .string or fs_url_raw != .string) continue;

            const normalized_path = try normalizeMountGraphPath(self.allocator, mount_path_raw.string);
            errdefer self.allocator.free(normalized_path);
            if (isSyntheticBrowseLocalMountGraphPath(normalized_path)) {
                self.allocator.free(normalized_path);
                continue;
            }
            const source_id = try self.allocator.dupe(u8, normalized_path);
            errdefer self.allocator.free(source_id);
            const fs_url = try self.rewriteMountGraphSourceFsUrl(fs_url_raw.string);
            errdefer self.allocator.free(fs_url);
            const export_name = if (mount_value.object.get("export_name")) |value|
                if (value == .string and value.string.len > 0) try self.allocator.dupe(u8, value.string) else null
            else
                null;
            errdefer if (export_name) |value| self.allocator.free(value);
            const node_id = if (mount_value.object.get("node_id")) |value|
                if (value == .string and value.string.len > 0) value.string else null
            else
                null;

            try out.append(self.allocator, .{
                .id = source_id,
                .mount_path = normalized_path,
                .fs_url = fs_url,
                .export_name = export_name,
                .writable = self.inferMountGraphSourceWritable(normalized_path, node_id, export_name),
            });
        }
        return out;
    }

    fn inferMountGraphSourceWritable(
        self: *Session,
        mount_path: []const u8,
        node_id: ?[]const u8,
        export_name: ?[]const u8,
    ) bool {
        if (std.mem.eql(u8, mount_path, local_fs_world_prefix)) return true;
        if (std.mem.eql(u8, mount_path, "/shared_data")) return false;

        const resolved_node_id = node_id orelse return false;
        const plane = self.control_plane orelse return false;
        var router = (self.boundVenomRouterForNode(
            plane,
            "fs",
            resolved_node_id,
            export_name,
            .server_internal,
        ) catch null) orelse return false;
        defer router.deinit();

        const attr_json = router.getattr("/") catch return false;
        defer self.allocator.free(attr_json);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, attr_json, .{}) catch return false;
        defer parsed.deinit();
        const summary = parseBoundVenomProxyAttr(parsed.value) orelse return false;
        return summary.writable;
    }

    fn rewriteMountGraphSourceFsUrl(self: *Session, raw_fs_url: []const u8) ![]u8 {
        const namespace_mount_url = self.namespace_mount_url orelse return self.allocator.dupe(u8, raw_fs_url);
        return rewriteLocalOnlyWsUrlToNamespaceAuthority(self.allocator, raw_fs_url, namespace_mount_url);
    }

    fn buildNamespaceRoutedNodeFsUrl(self: *Session, node_id: []const u8) !?[]u8 {
        const namespace_mount_url = self.namespace_mount_url orelse return null;
        const namespace_url = parseWsUrlParts(namespace_mount_url) orelse return null;
        const routed = try std.fmt.allocPrint(
            self.allocator,
            "{s}://{s}/fs/node/{s}",
            .{ namespace_url.scheme, namespace_url.authority, node_id },
        );
        return routed;
    }

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
            return .{
                .scheme = scheme,
                .authority = rest,
                .path = "/",
            };
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

    fn rewriteLocalOnlyWsUrlToNamespaceAuthority(
        allocator: std.mem.Allocator,
        raw_fs_url: []const u8,
        namespace_mount_url: []const u8,
    ) ![]u8 {
        const fs_url = parseWsUrlParts(raw_fs_url) orelse return allocator.dupe(u8, raw_fs_url);
        if (!wsAuthorityIsLocalOnly(fs_url.authority)) return allocator.dupe(u8, raw_fs_url);

        const namespace_url = parseWsUrlParts(namespace_mount_url) orelse return allocator.dupe(u8, raw_fs_url);
        return std.fmt.allocPrint(
            allocator,
            "{s}://{s}{s}",
            .{ namespace_url.scheme, namespace_url.authority, fs_url.path },
        );
    }

    fn isSyntheticBrowseLocalMountGraphPath(path: []const u8) bool {
        if (path.len == 0 or std.mem.eql(u8, path, "/")) return false;
        const trimmed = if (path[0] == '/') path[1..] else path;

        var segments_storage: [8][]const u8 = undefined;
        var segment_count: usize = 0;
        var iter = std.mem.splitScalar(u8, trimmed, '/');
        while (iter.next()) |segment| {
            if (segment.len == 0) continue;
            if (segment_count == segments_storage.len) return false;
            segments_storage[segment_count] = segment;
            segment_count += 1;
        }

        const segments = segments_storage[0..segment_count];
        if (matchesSyntheticBrowseLocalSuffix(segments)) return true;
        if (segments.len < 5) return false;
        if (!std.mem.eql(u8, segments[0], "nodes")) return false;
        if (!std.mem.eql(u8, segments[2], "projects")) return false;
        return matchesSyntheticBrowseLocalSuffix(segments[4..]);
    }

    fn matchesSyntheticBrowseLocalSuffix(segments: []const []const u8) bool {
        if (segments.len == 1) {
            return std.mem.eql(u8, segments[0], "agents") or
                std.mem.eql(u8, segments[0], "meta");
        }
        return false;
    }

    test "synthetic browse-local mount graph paths stay graph-backed" {
        try std.testing.expect(isSyntheticBrowseLocalMountGraphPath("/agents"));
        try std.testing.expect(isSyntheticBrowseLocalMountGraphPath("/meta"));
        try std.testing.expect(isSyntheticBrowseLocalMountGraphPath("/nodes/local/projects/proj-1/agents"));
        try std.testing.expect(isSyntheticBrowseLocalMountGraphPath("/nodes/local/projects/proj-1/meta"));

        try std.testing.expect(!isSyntheticBrowseLocalMountGraphPath("/"));
        try std.testing.expect(!isSyntheticBrowseLocalMountGraphPath("/nodes/local/fs"));
        try std.testing.expect(!isSyntheticBrowseLocalMountGraphPath("/nodes/local/projects/proj-1/fs/local::fs"));
        try std.testing.expect(!isSyntheticBrowseLocalMountGraphPath("/services"));
        try std.testing.expect(!isSyntheticBrowseLocalMountGraphPath("/global/chat"));
        try std.testing.expect(!isSyntheticBrowseLocalMountGraphPath("/global/jobs"));
        try std.testing.expect(!isSyntheticBrowseLocalMountGraphPath("/foo/meta"));
    }

    test "mount graph rewrites local-only fs sources to the connected namespace authority" {
        const allocator = std.testing.allocator;
        const rewritten = try rewriteLocalOnlyWsUrlToNamespaceAuthority(
            allocator,
            "ws://127.0.0.1:18790/fs",
            "ws://192.168.10.101:18790/",
        );
        defer allocator.free(rewritten);
        try std.testing.expectEqualStrings("ws://192.168.10.101:18790/fs", rewritten);

        const preserved = try rewriteLocalOnlyWsUrlToNamespaceAuthority(
            allocator,
            "ws://edge-box.local:18790/fs",
            "ws://192.168.10.101:18790/",
        );
        defer allocator.free(preserved);
        try std.testing.expectEqualStrings("ws://edge-box.local:18790/fs", preserved);
    }

    test "acheron_session: buildNamespaceRoutedNodeFsUrl uses namespace authority for node routes" {
        const allocator = std.testing.allocator;
        const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
            allocator,
            "execution_failed",
            "runtime unavailable",
        );
        defer runtime_handle.destroy();

        var session = try Session.initWithOptions(
            allocator,
            runtime_handle,
            "codex",
            .{
                .project_id = "proj-1",
                .namespace_mount_url = "wss://namespace.example.test:4443/",
                .agents_dir = ".does-not-exist",
                .projects_dir = ".does-not-exist",
            },
        );
        defer session.deinit();

        const routed = (try session.buildNamespaceRoutedNodeFsUrl("node-3")) orelse return error.TestExpectedResponse;
        defer allocator.free(routed);
        try std.testing.expectEqualStrings("wss://namespace.example.test:4443/fs/node/node-3", routed);
    }

    fn appendMountGraphAncestorChain(
        self: *Session,
        nodes: *std.ArrayListUnmanaged(MountGraphNodeRecord),
        path_to_index: *std.StringHashMapUnmanaged(usize),
        node_id: u32,
        export_root_writable: *const std.StringHashMapUnmanaged(bool),
    ) !void {
        var chain = std.ArrayListUnmanaged(u32){};
        defer chain.deinit(self.allocator);

        var cursor: ?u32 = node_id;
        while (cursor) |current| {
            try chain.append(self.allocator, current);
            cursor = (self.nodes.get(current) orelse return error.MissingNode).parent;
        }

        var index = chain.items.len;
        while (index > 0) {
            index -= 1;
            const current_id = chain.items[index];
            const absolute_path = try self.nodeAbsolutePath(current_id);
            defer self.allocator.free(absolute_path);
            try self.appendMountGraphNode(
                nodes,
                path_to_index,
                current_id,
                absolute_path,
                export_root_writable,
            );
        }
    }

    fn appendProjectedMountGraphRequestedPath(
        self: *Session,
        nodes: *std.ArrayListUnmanaged(MountGraphNodeRecord),
        path_to_index: *std.StringHashMapUnmanaged(usize),
        requested_path: []const u8,
        actual_path: []const u8,
        actual_node_id: u32,
        export_root_writable: *const std.StringHashMapUnmanaged(bool),
        next_overlay_id: *u64,
        max_depth: u32,
    ) !void {
        const segments = try self.allocAbsolutePathSegments(requested_path);
        defer freePathSegments(self.allocator, segments);

        var projected_prefix = std.ArrayListUnmanaged(u8){};
        defer projected_prefix.deinit(self.allocator);

        var current_parent_id: u64 = self.root_id;
        var projected_node_id: u64 = self.root_id;

        for (segments, 0..) |segment, index| {
            try projected_prefix.append(self.allocator, '/');
            try projected_prefix.appendSlice(self.allocator, segment);

            const projected_path = try self.allocator.dupe(u8, projected_prefix.items);
            defer self.allocator.free(projected_path);

            var source_path = if (index + 1 == segments.len)
                try self.allocator.dupe(u8, actual_path)
            else blk: {
                const rebound = try self.resolveBoundPath(projected_path);
                if (rebound) |value| break :blk value;
                break :blk try self.allocator.dupe(u8, projected_path);
            };
            defer self.allocator.free(source_path);

            const source_node_id = if (index + 1 == segments.len)
                actual_node_id
            else blk: {
                if (try self.resolveAbsolutePathForMountGraphNoBinds(source_path)) |resolved_id| {
                    break :blk resolved_id;
                }
                if (!std.mem.eql(u8, source_path, projected_path)) {
                    self.allocator.free(source_path);
                    source_path = try self.allocator.dupe(u8, projected_path);
                    break :blk (try self.resolveAbsolutePathForMountGraphNoBinds(source_path) orelse return error.FileNotFound);
                }
                return error.FileNotFound;
            };

            projected_node_id = try self.appendProjectedMountGraphNode(
                nodes,
                path_to_index,
                source_node_id,
                projected_path,
                current_parent_id,
                export_root_writable,
                next_overlay_id,
            );
            current_parent_id = projected_node_id;
        }

        const requested_node = self.nodes.get(actual_node_id) orelse return error.MissingNode;
        if (max_depth == 0 or requested_node.kind != .dir) return;

        try self.appendMountGraphProjectedChildren(
            nodes,
            path_to_index,
            actual_node_id,
            actual_path,
            requested_path,
            projected_node_id,
            export_root_writable,
            next_overlay_id,
            max_depth,
        );
    }

    fn appendMountGraphNode(
        self: *Session,
        nodes: *std.ArrayListUnmanaged(MountGraphNodeRecord),
        path_to_index: *std.StringHashMapUnmanaged(usize),
        node_id: u32,
        absolute_path: []const u8,
        export_root_writable: *const std.StringHashMapUnmanaged(bool),
    ) !void {
        if (path_to_index.contains(absolute_path)) return;

        const node = self.nodes.get(node_id) orelse return error.MissingNode;

        const alias_target = self.node_aliases.get(node_id);
        const canonical_node_id: ?u64 = if (alias_target) |target| @min(node_id, target) else null;
        const export_root_writable_flag = export_root_writable.get(absolute_path);
        const is_export_root = export_root_writable_flag != null;
        const kind_name: []const u8 = if (is_export_root)
            "export_root"
        else switch (node.kind) {
            .dir => "synthetic_directory",
            .file => "synthetic_file",
        };

        const content_mode = mountGraphContentMode(node, is_export_root);
        const inline_content_b64 = if (content_mode != null and std.mem.eql(u8, content_mode.?, "inline_snapshot"))
            try unified.encodeDataB64(self.allocator, node.content)
        else
            null;
        errdefer if (inline_content_b64) |value| self.allocator.free(value);

        const name = if (std.mem.eql(u8, absolute_path, "/"))
            try self.allocator.dupe(u8, "/")
        else
            try self.allocator.dupe(u8, node.name);
        errdefer self.allocator.free(name);
        const path = try self.allocator.dupe(u8, absolute_path);
        errdefer self.allocator.free(path);

        try nodes.append(self.allocator, .{
            .id = node_id,
            .parent_id = if (node.parent) |parent_id| @as(u64, parent_id) else null,
            .name = name,
            .path = path,
            .kind = kind_name,
            .mode = if (is_export_root)
                (if (export_root_writable_flag.?) 0o040755 else 0o040555)
            else
                effectiveNodeMode(node),
            .writable = if (export_root_writable_flag) |value| value else node.writable,
            .size = if (node.kind == .file and !is_export_root) effectiveNodeSize(node) else 0,
            .canonical_node_id = canonical_node_id,
            .content_mode = content_mode,
            .inline_content_b64 = inline_content_b64,
        });
        try path_to_index.put(self.allocator, path, nodes.items.len - 1);
    }

    fn appendMountGraphSubtree(
        self: *Session,
        nodes: *std.ArrayListUnmanaged(MountGraphNodeRecord),
        path_to_index: *std.StringHashMapUnmanaged(usize),
        node_id: u32,
        absolute_path: []const u8,
        export_root_writable: *const std.StringHashMapUnmanaged(bool),
        next_overlay_id: *u64,
        remaining_depth: u32,
    ) anyerror!void {
        try self.appendMountGraphNode(
            nodes,
            path_to_index,
            node_id,
            absolute_path,
            export_root_writable,
        );

        const node = self.nodes.get(node_id) orelse return error.MissingNode;
        if (remaining_depth == 0 or export_root_writable.contains(absolute_path) or node.kind != .dir) return;
        const current_index = path_to_index.get(absolute_path) orelse return error.MissingNode;
        const current_parent_id = nodes.items[current_index].id;

        try self.appendMountGraphProjectedChildren(
            nodes,
            path_to_index,
            node_id,
            absolute_path,
            absolute_path,
            current_parent_id,
            export_root_writable,
            next_overlay_id,
            remaining_depth,
        );
    }

    fn appendMountGraphProjectedChildren(
        self: *Session,
        nodes: *std.ArrayListUnmanaged(MountGraphNodeRecord),
        path_to_index: *std.StringHashMapUnmanaged(usize),
        source_node_id: u32,
        source_absolute_path: []const u8,
        projected_parent_path: []const u8,
        projected_parent_id: u64,
        export_root_writable: *const std.StringHashMapUnmanaged(bool),
        next_overlay_id: *u64,
        remaining_depth: u32,
    ) anyerror!void {
        const source_node = self.nodes.get(source_node_id) orelse return error.MissingNode;

        var child_names = std.ArrayListUnmanaged([]const u8){};
        defer child_names.deinit(self.allocator);
        var seen_names = std.StringHashMapUnmanaged(void){};
        defer seen_names.deinit(self.allocator);

        var it = source_node.children.iterator();
        while (it.next()) |entry| {
            if (seen_names.contains(entry.key_ptr.*)) continue;
            try child_names.append(self.allocator, entry.key_ptr.*);
            try seen_names.put(self.allocator, entry.key_ptr.*, {});
        }

        if (self.project_binds.items.len > 0) {
            for (self.project_binds.items) |bind| {
                const child_name = immediateBoundChildName(projected_parent_path, bind.bind_path) orelse continue;
                if (seen_names.contains(child_name)) continue;
                try child_names.append(self.allocator, child_name);
                try seen_names.put(self.allocator, child_name, {});
            }

            if (!std.mem.eql(u8, source_absolute_path, projected_parent_path)) {
                for (self.project_binds.items) |bind| {
                    const child_name = immediateBoundChildName(source_absolute_path, bind.bind_path) orelse continue;
                    if (seen_names.contains(child_name)) continue;
                    try child_names.append(self.allocator, child_name);
                    try seen_names.put(self.allocator, child_name, {});
                }
            }
        }
        std.mem.sort([]const u8, child_names.items, {}, struct {
            fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.lessThan(u8, lhs, rhs);
            }
        }.lessThan);

        for (child_names.items) |child_name| {
            const source_child_path = if (std.mem.eql(u8, source_absolute_path, "/"))
                try std.fmt.allocPrint(self.allocator, "/{s}", .{child_name})
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ source_absolute_path, child_name });
            defer self.allocator.free(source_child_path);

            const projected_child_path = if (std.mem.eql(u8, projected_parent_path, "/"))
                try std.fmt.allocPrint(self.allocator, "/{s}", .{child_name})
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ projected_parent_path, child_name });
            defer self.allocator.free(projected_child_path);

            if (source_node.children.get(child_name)) |child_id| {
                if (std.mem.eql(u8, source_child_path, projected_child_path)) {
                    try self.appendMountGraphSubtree(
                        nodes,
                        path_to_index,
                        child_id,
                        projected_child_path,
                        export_root_writable,
                        next_overlay_id,
                        remaining_depth - 1,
                    );
                } else {
                    try self.appendProjectedMountGraphSubtree(
                        nodes,
                        path_to_index,
                        child_id,
                        source_child_path,
                        projected_child_path,
                        projected_parent_id,
                        export_root_writable,
                        next_overlay_id,
                        remaining_depth - 1,
                    );
                }
                continue;
            }

            if (try self.resolveAbsolutePathForMountGraphNoBinds(projected_child_path)) |projected_child_id| {
                try self.appendProjectedMountGraphSubtree(
                    nodes,
                    path_to_index,
                    projected_child_id,
                    projected_child_path,
                    projected_child_path,
                    projected_parent_id,
                    export_root_writable,
                    next_overlay_id,
                    remaining_depth - 1,
                );
                continue;
            }

            const rebound_lookup_path = projected_child_path;
            const rebound_path = try self.resolveBoundPath(rebound_lookup_path) orelse continue;
            defer self.allocator.free(rebound_path);
            const child_id = try self.resolveAbsolutePathForMountGraphNoBinds(rebound_path) orelse continue;
            try self.appendProjectedMountGraphSubtree(
                nodes,
                path_to_index,
                child_id,
                rebound_lookup_path,
                projected_child_path,
                projected_parent_id,
                export_root_writable,
                next_overlay_id,
                remaining_depth - 1,
            );
        }
    }

    fn appendProjectedMountGraphSubtree(
        self: *Session,
        nodes: *std.ArrayListUnmanaged(MountGraphNodeRecord),
        path_to_index: *std.StringHashMapUnmanaged(usize),
        source_node_id: u32,
        source_absolute_path: []const u8,
        projected_path: []const u8,
        projected_parent_id: u64,
        export_root_writable: *const std.StringHashMapUnmanaged(bool),
        next_overlay_id: *u64,
        remaining_depth: u32,
    ) anyerror!void {
        const projected_id = try self.appendProjectedMountGraphNode(
            nodes,
            path_to_index,
            source_node_id,
            projected_path,
            projected_parent_id,
            export_root_writable,
            next_overlay_id,
        );

        const source_node = self.nodes.get(source_node_id) orelse return error.MissingNode;
        if (remaining_depth == 0 or export_root_writable.contains(projected_path) or source_node.kind != .dir) return;

        try self.appendMountGraphProjectedChildren(
            nodes,
            path_to_index,
            source_node_id,
            source_absolute_path,
            projected_path,
            projected_id,
            export_root_writable,
            next_overlay_id,
            remaining_depth,
        );
    }

    fn appendProjectedMountGraphNode(
        self: *Session,
        nodes: *std.ArrayListUnmanaged(MountGraphNodeRecord),
        path_to_index: *std.StringHashMapUnmanaged(usize),
        source_node_id: u32,
        projected_path: []const u8,
        projected_parent_id: u64,
        export_root_writable: *const std.StringHashMapUnmanaged(bool),
        next_overlay_id: *u64,
    ) anyerror!u64 {
        if (path_to_index.get(projected_path)) |existing_index| {
            return nodes.items[existing_index].id;
        }

        const source_node = self.nodes.get(source_node_id) orelse return error.MissingNode;
        const alias_target = self.node_aliases.get(source_node_id);
        const canonical_node_id: ?u64 = if (alias_target) |target|
            @as(u64, @min(source_node_id, target))
        else
            @as(u64, source_node_id);
        const export_root_writable_flag = export_root_writable.get(projected_path);
        const is_export_root = export_root_writable_flag != null;
        const forced_readonly = isManagedSharedDataProjectedPath(projected_path);
        const content_mode = if (forced_readonly and !is_export_root and source_node.kind == .file)
            "remote_read"
        else
            mountGraphContentMode(source_node, is_export_root);
        const inline_content_b64 = if (content_mode != null and std.mem.eql(u8, content_mode.?, "inline_snapshot"))
            try unified.encodeDataB64(self.allocator, source_node.content)
        else
            null;
        errdefer if (inline_content_b64) |value| self.allocator.free(value);

        const name = if (std.mem.eql(u8, projected_path, "/"))
            try self.allocator.dupe(u8, "/")
        else blk: {
            const slash_idx = std.mem.lastIndexOfScalar(u8, projected_path, '/') orelse return error.InvalidPath;
            break :blk try self.allocator.dupe(u8, projected_path[slash_idx + 1 ..]);
        };
        errdefer self.allocator.free(name);
        const path = try self.allocator.dupe(u8, projected_path);
        errdefer self.allocator.free(path);

        const new_id = next_overlay_id.*;
        next_overlay_id.* += 1;
        try nodes.append(self.allocator, .{
            .id = new_id,
            .parent_id = projected_parent_id,
            .name = name,
            .path = path,
            .kind = if (is_export_root)
                "export_root"
            else switch (source_node.kind) {
                .dir => "synthetic_directory",
                .file => "synthetic_file",
            },
            .mode = if (is_export_root)
                (if (export_root_writable_flag.?) 0o040755 else 0o040555)
            else if (forced_readonly)
                readonlyMode(effectiveNodeMode(source_node), source_node.kind)
            else
                effectiveNodeMode(source_node),
            .writable = if (forced_readonly)
                false
            else if (export_root_writable_flag) |value|
                value
            else
                source_node.writable,
            .size = if (source_node.kind == .file and !is_export_root) effectiveNodeSize(source_node) else 0,
            .canonical_node_id = canonical_node_id,
            .content_mode = content_mode,
            .inline_content_b64 = inline_content_b64,
        });
        try path_to_index.put(self.allocator, path, nodes.items.len - 1);
        return new_id;
    }

    fn mountGraphSourceRelevantToScope(scope_path: []const u8, source_path: []const u8) bool {
        if (std.mem.eql(u8, scope_path, "/")) return true;
        return pathMatchesPrefixBoundary(source_path, scope_path) or pathMatchesPrefixBoundary(scope_path, source_path);
    }

    fn overlayMountGraphSource(
        self: *Session,
        nodes: *std.ArrayListUnmanaged(MountGraphNodeRecord),
        path_to_index: *std.StringHashMapUnmanaged(usize),
        source: *const MountGraphSourceRecord,
        next_overlay_id: *u64,
    ) !void {
        if (std.mem.eql(u8, source.mount_path, "/")) return;

        var current_parent_path: []const u8 = "/";
        var current_parent_id: u64 = self.root_id;
        const segments = try self.allocAbsolutePathSegments(source.mount_path);
        defer freePathSegments(self.allocator, segments);

        for (segments, 0..) |segment, index| {
            const is_last = index + 1 == segments.len;
            const current_path = if (std.mem.eql(u8, current_parent_path, "/"))
                try std.fmt.allocPrint(self.allocator, "/{s}", .{segment})
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ current_parent_path, segment });
            defer self.allocator.free(current_path);

            if (path_to_index.get(current_path)) |existing_index| {
                current_parent_path = nodes.items[existing_index].path;
                current_parent_id = nodes.items[existing_index].id;
                if (is_last) {
                    var existing = &nodes.items[existing_index];
                    existing.kind = "export_root";
                    existing.mode = if (source.writable) 0o040755 else 0o040555;
                    existing.writable = source.writable;
                    existing.size = 0;
                    existing.content_mode = null;
                    if (existing.inline_content_b64) |value| {
                        self.allocator.free(value);
                        existing.inline_content_b64 = null;
                    }
                    existing.source_id = source.id;
                }
                continue;
            }

            const owned_name = try self.allocator.dupe(u8, segment);
            errdefer self.allocator.free(owned_name);
            const owned_path = try self.allocator.dupe(u8, current_path);
            errdefer self.allocator.free(owned_path);
            const new_id = next_overlay_id.*;
            next_overlay_id.* += 1;
            try nodes.append(self.allocator, .{
                .id = new_id,
                .parent_id = current_parent_id,
                .name = owned_name,
                .path = owned_path,
                .kind = if (is_last) "export_root" else "synthetic_directory",
                .mode = if (is_last and !source.writable) 0o040555 else 0o040755,
                .writable = if (is_last) source.writable else false,
                .size = 0,
                .canonical_node_id = null,
                .content_mode = null,
                .inline_content_b64 = null,
                .source_id = if (is_last) source.id else null,
            });
            try path_to_index.put(self.allocator, owned_path, nodes.items.len - 1);
            current_parent_path = nodes.items[nodes.items.len - 1].path;
            current_parent_id = new_id;
        }
    }

    fn buildMountGraphNodesJson(self: *Session, nodes: []const MountGraphNodeRecord) ![]u8 {
        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "[");
        for (nodes, 0..) |node, index| {
            if (index != 0) try out.append(self.allocator, ',');

            const escaped_name = try unified.jsonEscape(self.allocator, node.name);
            defer self.allocator.free(escaped_name);
            const escaped_path = try unified.jsonEscape(self.allocator, node.path);
            defer self.allocator.free(escaped_path);
            const parent_id_json = if (node.parent_id) |value|
                try std.fmt.allocPrint(self.allocator, "{d}", .{value})
            else
                try self.allocator.dupe(u8, "null");
            defer self.allocator.free(parent_id_json);
            const canonical_json = if (node.canonical_node_id) |value|
                try std.fmt.allocPrint(self.allocator, "{d}", .{value})
            else
                try self.allocator.dupe(u8, "null");
            defer self.allocator.free(canonical_json);
            const content_mode_json = if (node.content_mode) |value| blk: {
                const escaped = try unified.jsonEscape(self.allocator, value);
                defer self.allocator.free(escaped);
                break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
            } else try self.allocator.dupe(u8, "null");
            defer self.allocator.free(content_mode_json);
            const inline_content_json = if (node.inline_content_b64) |value| blk: {
                const escaped = try unified.jsonEscape(self.allocator, value);
                defer self.allocator.free(escaped);
                break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
            } else try self.allocator.dupe(u8, "null");
            defer self.allocator.free(inline_content_json);
            const source_id_json = if (node.source_id) |value| blk: {
                const escaped = try unified.jsonEscape(self.allocator, value);
                defer self.allocator.free(escaped);
                break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
            } else try self.allocator.dupe(u8, "null");
            defer self.allocator.free(source_id_json);

            try out.writer(self.allocator).print(
                "{{\"id\":{d},\"parent_id\":{s},\"name\":\"{s}\",\"path\":\"{s}\",\"kind\":\"{s}\",\"mode\":{d},\"writable\":{s},\"size\":{d},\"canonical_node_id\":{s},\"content_mode\":{s},\"inline_content_b64\":{s},\"source_id\":{s}}}",
                .{
                    node.id,
                    parent_id_json,
                    escaped_name,
                    escaped_path,
                    node.kind,
                    node.mode,
                    if (node.writable) "true" else "false",
                    node.size,
                    canonical_json,
                    content_mode_json,
                    inline_content_json,
                    source_id_json,
                },
            );
        }
        try out.appendSlice(self.allocator, "]");
        return out.toOwnedSlice(self.allocator);
    }

    fn buildMountGraphSourcesJson(self: *Session, sources: []const MountGraphSourceRecord) ![]u8 {
        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "[");
        for (sources, 0..) |source, index| {
            if (index != 0) try out.append(self.allocator, ',');
            const escaped_id = try unified.jsonEscape(self.allocator, source.id);
            defer self.allocator.free(escaped_id);
            const escaped_mount_path = try unified.jsonEscape(self.allocator, source.mount_path);
            defer self.allocator.free(escaped_mount_path);
            const escaped_fs_url = try unified.jsonEscape(self.allocator, source.fs_url);
            defer self.allocator.free(escaped_fs_url);
            const export_name_json = if (source.export_name) |value| blk: {
                const escaped = try unified.jsonEscape(self.allocator, value);
                defer self.allocator.free(escaped);
                break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
            } else try self.allocator.dupe(u8, "null");
            defer self.allocator.free(export_name_json);

            try out.writer(self.allocator).print(
                "{{\"id\":\"{s}\",\"mount_path\":\"{s}\",\"fs_url\":\"{s}\",\"export_name\":{s},\"writable\":{s}}}",
                .{ escaped_id, escaped_mount_path, escaped_fs_url, export_name_json, if (source.writable) "true" else "false" },
            );
        }
        try out.appendSlice(self.allocator, "]");
        return out.toOwnedSlice(self.allocator);
    }

    fn normalizeMountGraphPath(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return allocator.dupe(u8, "/");
        if (trimmed.len == 1 and trimmed[0] == '/') return allocator.dupe(u8, "/");
        const without_trailing = std.mem.trimRight(u8, trimmed, "/");
        if (without_trailing.len == 0) return allocator.dupe(u8, "/");
        if (without_trailing[0] == '/') return allocator.dupe(u8, without_trailing);
        return std.fmt.allocPrint(allocator, "/{s}", .{without_trailing});
    }

    fn mountGraphContentMode(node: Node, is_export_root: bool) ?[]const u8 {
        if (is_export_root or node.kind != .file) return null;
        if (node.special != .none) {
            return if (node.writable or specialWriteCommitsOnClose(node.special))
                "remote_rw"
            else
                "remote_read";
        }
        if (node.writable) return "remote_rw";
        return "remote_read";
    }

    fn mapInternalMountWriteError(code: []const u8) anyerror {
        if (std.mem.eql(u8, code, "enoent")) return error.FileNotFound;
        if (std.mem.eql(u8, code, "eperm")) return error.AccessDenied;
        if (std.mem.eql(u8, code, "eacces")) return error.AccessDenied;
        if (std.mem.eql(u8, code, "eisdir")) return error.IsDir;
        if (std.mem.eql(u8, code, "enotdir")) return error.NotDir;
        if (std.mem.eql(u8, code, "invalid")) return error.InvalidPayload;
        return error.OperationNotSupported;
    }

    fn refreshLocalFsBackedAbsolutePath(self: *Session, absolute_path: []const u8) !void {
        const parent_path = namespaceAbsolutePathParent(absolute_path) orelse return;
        const child_name = namespaceAbsolutePathBaseName(absolute_path) orelse return;
        const parent_id = (try self.resolveAbsolutePathForMountGraphNoBinds(parent_path)) orelse return;

        try self.refreshDynamicDirectory(parent_id);
        if (self.lookupChild(parent_id, child_name)) |child_id| {
            _ = try self.syncLocalFsFileNode(child_id);
        }
    }

    fn refreshLocalFsBackedParentAbsolutePath(self: *Session, absolute_path: []const u8) !void {
        const parent_path = namespaceAbsolutePathParent(absolute_path) orelse return;
        const parent_id = (try self.resolveAbsolutePathForMountGraphNoBinds(parent_path)) orelse return;
        try self.refreshDynamicDirectory(parent_id);
    }

    fn removeLocalFsBackedAbsolutePathFromMountGraph(self: *Session, absolute_path: []const u8) !void {
        const parent_path = namespaceAbsolutePathParent(absolute_path) orelse return;
        const child_name = namespaceAbsolutePathBaseName(absolute_path) orelse return;
        const parent_id = (try self.resolveAbsolutePathForMountGraphNoBinds(parent_path)) orelse return;
        const child_id = self.lookupChild(parent_id, child_name) orelse return;
        try self.deleteNodeRecursive(child_id);
    }

    fn tryResolveMutableLocalFsBackedHostPath(self: *Session, absolute_path: []const u8) !?[]u8 {
        const normalized_path = std.mem.trimRight(u8, absolute_path, "/");
        if (!pathMatchesPrefixBoundary(normalized_path, local_fs_world_prefix)) return null;
        if (std.mem.eql(u8, normalized_path, local_fs_world_prefix)) return null;

        if (std.mem.startsWith(u8, normalized_path, workspace_managed_root_absolute ++ "/shared_data")) return null;
        if (std.mem.startsWith(u8, normalized_path, workspace_managed_root_absolute ++ "/services")) return null;

        return self.resolveMissionContractHostPath(normalized_path) catch null;
    }

    fn tryResolveReadableLocalFsBackedHostPath(self: *Session, absolute_path: []const u8) !?[]u8 {
        const normalized_path = std.mem.trimRight(u8, absolute_path, "/");
        if (!pathMatchesPrefixBoundary(normalized_path, local_fs_world_prefix)) return null;
        if (std.mem.eql(u8, normalized_path, local_fs_world_prefix)) return null;
        return self.resolveMissionContractHostPath(normalized_path) catch null;
    }

    fn namespaceAbsolutePathParent(path: []const u8) ?[]const u8 {
        const trimmed = std.mem.trimRight(u8, path, "/");
        if (trimmed.len == 0 or trimmed[0] != '/') return null;
        if (std.mem.eql(u8, trimmed, "/")) return null;
        const slash_idx = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return null;
        if (slash_idx == 0) return "/";
        return trimmed[0..slash_idx];
    }

    fn namespaceAbsolutePathBaseName(path: []const u8) ?[]const u8 {
        const trimmed = std.mem.trimRight(u8, path, "/");
        if (trimmed.len == 0 or trimmed[0] != '/') return null;
        if (std.mem.eql(u8, trimmed, "/")) return null;
        const slash_idx = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return null;
        return trimmed[slash_idx + 1 ..];
    }

    fn mapInternalMountReadError(code: []const u8) anyerror {
        if (std.mem.eql(u8, code, "enoent")) return error.FileNotFound;
        if (std.mem.eql(u8, code, "eperm")) return error.AccessDenied;
        if (std.mem.eql(u8, code, "eacces")) return error.AccessDenied;
        if (std.mem.eql(u8, code, "eisdir")) return error.IsDir;
        if (std.mem.eql(u8, code, "enotdir")) return error.NotDir;
        if (std.mem.eql(u8, code, "invalid")) return error.InvalidPayload;
        return error.OperationNotSupported;
    }

    fn executeDirectBuiltinToolCall(self: *Session, tool_name: []const u8, args_json: []const u8) !?[]u8 {
        if (!std.mem.eql(u8, tool_name, "shell_exec")) return null;

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, args_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidPayload;

        const source_args = parsed.value.object;
        if (self.canUseNamespaceShellExec()) {
            return self.executeNamespaceShellExecPayload(source_args) catch |err| blk: {
                const message = try std.fmt.allocPrint(
                    self.allocator,
                    "namespace-backed shell_exec failed: {s}",
                    .{@errorName(err)},
                );
                defer self.allocator.free(message);
                break :blk try self.buildServiceInvokeFailureResultJson(@errorName(err), message);
            };
        }
        const command = if (source_args.get("command")) |value|
            if (value == .string) value.string else return error.InvalidPayload
        else
            return error.InvalidPayload;
        const timeout_ms = if (source_args.get("timeout_ms")) |value| switch (value) {
            .integer => |raw| blk: {
                if (raw < 0) return error.InvalidPayload;
                break :blk @as(u64, @intCast(raw));
            },
            .float => |raw| blk: {
                if (raw < 0 or std.math.floor(raw) != raw) return error.InvalidPayload;
                break :blk @as(u64, @intFromFloat(raw));
            },
            .null => null,
            else => return error.InvalidPayload,
        } else null;
        const cwd = if (source_args.get("cwd")) |value|
            if (value == .string) value.string else if (value == .null) null else return error.InvalidPayload
        else
            null;

        const direct_workspace_root = if (cwd) |value| blk: {
            if (!pathMatchesPrefixBoundary(value, local_fs_world_prefix)) break :blk null;
            break :blk try self.resolveMissionContractHostPath(local_fs_world_prefix);
        } else null;
        defer if (direct_workspace_root) |value| self.allocator.free(value);

        const resolved_cwd = if (cwd) |value| blk: {
            if (!pathMatchesPrefixBoundary(value, local_fs_world_prefix)) {
                break :blk try self.allocator.dupe(u8, value);
            }
            if (std.mem.eql(u8, value, local_fs_world_prefix)) {
                break :blk try self.allocator.dupe(u8, ".");
            }
            const relative = std.mem.trimLeft(u8, value[local_fs_world_prefix.len..], "/");
            if (relative.len == 0) {
                break :blk try self.allocator.dupe(u8, ".");
            }
            break :blk try self.allocator.dupe(u8, relative);
        } else null;
        defer if (resolved_cwd) |value| self.allocator.free(value);

        const escaped_command = try unified.jsonEscape(self.allocator, command);
        defer self.allocator.free(escaped_command);
        const cwd_fragment = if (resolved_cwd) |value| blk: {
            const escaped_cwd = try unified.jsonEscape(self.allocator, value);
            defer self.allocator.free(escaped_cwd);
            break :blk try std.fmt.allocPrint(self.allocator, ",\"cwd\":\"{s}\"", .{escaped_cwd});
        } else try self.allocator.dupe(u8, "");
        defer self.allocator.free(cwd_fragment);
        const timeout_fragment = if (timeout_ms) |value|
            try std.fmt.allocPrint(self.allocator, ",\"timeout_ms\":{d}", .{value})
        else
            try self.allocator.dupe(u8, "");
        defer self.allocator.free(timeout_fragment);

        const direct_args_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"command\":\"{s}\"{s}{s}}}",
            .{ escaped_command, timeout_fragment, cwd_fragment },
        );
        defer self.allocator.free(direct_args_json);

        var direct_parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, direct_args_json, .{});
        defer direct_parsed.deinit();
        if (direct_parsed.value != .object) return error.InvalidPayload;

        var original_cwd: ?[]u8 = null;
        if (direct_workspace_root) |workspace_root| {
            direct_builtin_shell_exec_mutex.lock();
            errdefer direct_builtin_shell_exec_mutex.unlock();

            original_cwd = try std.process.getCwdAlloc(self.allocator);
            errdefer if (original_cwd) |value| self.allocator.free(value);
            try std.process.changeCurDir(workspace_root);
        }
        defer {
            if (direct_workspace_root != null) {
                if (original_cwd) |value| {
                    std.process.changeCurDir(value) catch {};
                    self.allocator.free(value);
                }
                direct_builtin_shell_exec_mutex.unlock();
            }
        }

        var result = tool_executor_mod.BuiltinTools.shellExec(self.allocator, direct_parsed.value.object);
        defer result.deinit(self.allocator);
        return switch (result) {
            .success => |success| try self.allocator.dupe(u8, success.payload_json),
            .failure => |failure| try self.buildServiceInvokeFailureResultJson(@tagName(failure.code), failure.message),
        };
    }

    pub fn executeServiceToolCall(self: *Session, tool_name: []const u8, args_json: []const u8) ![]u8 {
        if (try self.executeDirectBuiltinToolCall(tool_name, args_json)) |payload| {
            return payload;
        }

        const escaped_tool_name = try unified.jsonEscape(self.allocator, tool_name);
        defer self.allocator.free(escaped_tool_name);
        const control_payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"tool_name\":\"{s}\",\"arguments\":{s}}}",
            .{ escaped_tool_name, args_json },
        );
        defer self.allocator.free(control_payload);
        const escaped_control_payload = try unified.jsonEscape(self.allocator, control_payload);
        defer self.allocator.free(escaped_control_payload);
        const request_id = try std.fmt.allocPrint(
            self.allocator,
            "service-invoke-{s}-{d}",
            .{ escaped_tool_name, std.time.milliTimestamp() },
        );
        defer self.allocator.free(request_id);
        const escaped_request_id = try unified.jsonEscape(self.allocator, request_id);
        defer self.allocator.free(escaped_request_id);
        const runtime_req = try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":\"{s}\",\"type\":\"agent.control\",\"action\":\"tool.call\",\"content\":\"{s}\"}}",
            .{ escaped_request_id, escaped_control_payload },
        );
        defer self.allocator.free(runtime_req);

        var responses: ?[][]u8 = null;
        if (self.runtime_handle.handleMessageFramesWithDebug(runtime_req, self.shouldEmitRuntimeDebugFrames())) |frames| {
            responses = frames;
        } else |err| {
            const normalized = shared_exec.normalizeRuntimeFailureForAgent("runtime_error", @errorName(err));
            return self.buildServiceInvokeFailureResultJson(normalized.code, normalized.message);
        }
        defer if (responses) |frames| deinitResponseFrames(self.allocator, frames);

        var content_payload: ?[]u8 = null;
        defer if (content_payload) |value| self.allocator.free(value);

        if (responses) |frames| {
            for (frames) |frame| {
                try self.recordRuntimeFrameForDebug(request_id, frame);

                var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame, .{}) catch continue;
                defer parsed.deinit();
                if (parsed.value != .object) continue;
                const obj = parsed.value.object;
                const type_value = obj.get("type") orelse continue;
                if (type_value != .string) continue;

                if (std.mem.eql(u8, type_value.string, "session.receive")) {
                    if (obj.get("content")) |content| {
                        if (content == .string) {
                            if (content_payload) |old| self.allocator.free(old);
                            content_payload = try self.allocator.dupe(u8, content.string);
                        }
                    }
                } else if (std.mem.eql(u8, type_value.string, "error")) {
                    const code = if (obj.get("code")) |value|
                        if (value == .string) value.string else "runtime_error"
                    else
                        "runtime_error";
                    const message = if (obj.get("message")) |value|
                        if (value == .string) value.string else "runtime tool call failed"
                    else
                        "runtime tool call failed";
                    const normalized = shared_exec.normalizeRuntimeFailureForAgent(code, message);
                    return self.buildServiceInvokeFailureResultJson(normalized.code, normalized.message);
                }
            }
        }

        if (content_payload) |payload| {
            if (shared_exec.isInternalRuntimeLoopGuardText(payload)) {
                const normalized = shared_exec.normalizeRuntimeFailureForAgent("execution_failed", payload);
                return self.buildServiceInvokeFailureResultJson(normalized.code, normalized.message);
            }
            var payload_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch {
                return self.buildServiceInvokeFailureResultJson("invalid_result_payload", "tool payload was not valid JSON");
            };
            payload_parsed.deinit();
            return self.allocator.dupe(u8, payload);
        }
        return self.buildServiceInvokeFailureResultJson("missing_result", "tool call produced no session.receive payload");
    }

    pub fn executeAgentRun(self: *Session, goal: []const u8, resume_run_id: ?[]const u8) !AgentRunOutcome {
        const trimmed_goal = std.mem.trim(u8, goal, " \t\r\n");
        if (trimmed_goal.len == 0) {
            return .{ .failure = .{
                .code = try self.allocator.dupe(u8, "invalid_goal"),
                .message = try self.allocator.dupe(u8, "agent run goal must not be empty"),
            } };
        }

        const request_id = try std.fmt.allocPrint(self.allocator, "agent-run-{d}", .{std.time.milliTimestamp()});
        defer self.allocator.free(request_id);
        const escaped_request_id = try unified.jsonEscape(self.allocator, request_id);
        defer self.allocator.free(escaped_request_id);
        const escaped_goal = try unified.jsonEscape(self.allocator, trimmed_goal);
        defer self.allocator.free(escaped_goal);

        const runtime_req = if (resume_run_id) |run_id| blk: {
            const escaped_run_id = try unified.jsonEscape(self.allocator, run_id);
            defer self.allocator.free(escaped_run_id);
            break :blk try std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":\"{s}\",\"type\":\"agent.run.resume\",\"action\":\"{s}\",\"content\":\"{s}\"}}",
                .{ escaped_request_id, escaped_run_id, escaped_goal },
            );
        } else try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":\"{s}\",\"type\":\"agent.run.start\",\"content\":\"{s}\"}}",
            .{ escaped_request_id, escaped_goal },
        );
        defer self.allocator.free(runtime_req);

        const frames = self.runtime_handle.handleMessageFramesWithDebug(runtime_req, self.shouldEmitRuntimeDebugFrames()) catch |err| {
            const normalized = shared_exec.normalizeRuntimeFailureForAgent("runtime_error", @errorName(err));
            return .{ .failure = .{
                .code = try self.allocator.dupe(u8, normalized.code),
                .message = try self.allocator.dupe(u8, normalized.message),
            } };
        };
        defer deinitResponseFrames(self.allocator, frames);

        var run_id: ?[]u8 = null;
        defer if (run_id) |value| self.allocator.free(value);
        var state: ?[]u8 = null;
        defer if (state) |value| self.allocator.free(value);
        var assistant_output: ?[]u8 = null;
        defer if (assistant_output) |value| self.allocator.free(value);
        var step_count: u64 = 0;
        var checkpoint_seq: u64 = 0;

        for (frames) |frame| {
            try self.recordRuntimeFrameForDebug(request_id, frame);

            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const obj = parsed.value.object;
            const type_value = obj.get("type") orelse continue;
            if (type_value != .string) continue;

            if (std.mem.eql(u8, type_value.string, "error")) {
                const code = if (obj.get("code")) |value|
                    if (value == .string and value.string.len > 0) value.string else "runtime_error"
                else
                    "runtime_error";
                const message = if (obj.get("message")) |value|
                    if (value == .string and value.string.len > 0) value.string else "runtime agent run failed"
                else
                    "runtime agent run failed";
                const normalized = shared_exec.normalizeRuntimeFailureForAgent(code, message);
                return .{ .failure = .{
                    .code = try self.allocator.dupe(u8, normalized.code),
                    .message = try self.allocator.dupe(u8, normalized.message),
                } };
            }

            if (std.mem.eql(u8, type_value.string, "agent.run.ack") or std.mem.eql(u8, type_value.string, "agent.run.state")) {
                if (obj.get("run_id")) |value| {
                    if (value == .string and value.string.len > 0) {
                        if (run_id) |old| self.allocator.free(old);
                        run_id = try self.allocator.dupe(u8, value.string);
                    }
                }
                if (obj.get("state")) |value| {
                    if (value == .string and value.string.len > 0) {
                        if (state) |old| self.allocator.free(old);
                        state = try self.allocator.dupe(u8, value.string);
                    }
                }
                if (obj.get("step_count")) |value| {
                    if (value == .integer and value.integer >= 0) step_count = @intCast(value.integer);
                }
                if (obj.get("checkpoint_seq")) |value| {
                    if (value == .integer and value.integer >= 0) checkpoint_seq = @intCast(value.integer);
                }
                continue;
            }

            if (std.mem.eql(u8, type_value.string, "agent.run.event")) {
                const event_type = if (obj.get("event_type")) |value|
                    if (value == .string) value.string else ""
                else
                    "";
                if (!std.mem.eql(u8, event_type, "assistant.output")) continue;
                const payload = obj.get("payload") orelse continue;
                if (payload != .object) continue;
                const assistant = payload.object.get("assistant") orelse continue;
                if (assistant != .string) continue;
                if (assistant_output) |old| self.allocator.free(old);
                assistant_output = try self.allocator.dupe(u8, assistant.string);
            }
        }

        const owned_run_id = if (run_id) |value|
            try self.allocator.dupe(u8, value)
        else
            return .{ .failure = .{
                .code = try self.allocator.dupe(u8, "missing_run_id"),
                .message = try self.allocator.dupe(u8, "runtime agent run produced no run_id"),
            } };
        errdefer self.allocator.free(owned_run_id);
        const owned_state = if (state) |value|
            try self.allocator.dupe(u8, value)
        else
            return .{ .failure = .{
                .code = try self.allocator.dupe(u8, "missing_run_state"),
                .message = try self.allocator.dupe(u8, "runtime agent run produced no state"),
            } };
        errdefer self.allocator.free(owned_state);
        const owned_assistant_output = if (assistant_output) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_assistant_output) |value| self.allocator.free(value);

        return .{ .success = .{
            .run_id = owned_run_id,
            .state = owned_state,
            .assistant_output = owned_assistant_output,
            .step_count = step_count,
            .checkpoint_seq = checkpoint_seq,
        } };
    }

    pub fn buildServiceInvokeStatusJson(
        self: *Session,
        state: []const u8,
        tool_name: ?[]const u8,
        error_message: ?[]const u8,
    ) ![]u8 {
        const escaped_state = try unified.jsonEscape(self.allocator, state);
        defer self.allocator.free(escaped_state);
        const tool_json = if (tool_name) |value| blk: {
            const escaped = try unified.jsonEscape(self.allocator, value);
            defer self.allocator.free(escaped);
            break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
        } else try self.allocator.dupe(u8, "null");
        defer self.allocator.free(tool_json);
        const error_json = if (error_message) |value| blk: {
            const escaped = try unified.jsonEscape(self.allocator, value);
            defer self.allocator.free(escaped);
            break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
        } else try self.allocator.dupe(u8, "null");
        defer self.allocator.free(error_json);
        return std.fmt.allocPrint(
            self.allocator,
            "{{\"state\":\"{s}\",\"tool\":{s},\"updated_at_ms\":{d},\"error\":{s}}}",
            .{ escaped_state, tool_json, std.time.milliTimestamp(), error_json },
        );
    }

    pub fn buildServiceInvokeFailureResultJson(self: *Session, code: []const u8, message: []const u8) ![]u8 {
        const escaped_code = try unified.jsonEscape(self.allocator, code);
        defer self.allocator.free(escaped_code);
        const escaped_message = try unified.jsonEscape(self.allocator, message);
        defer self.allocator.free(escaped_message);
        return std.fmt.allocPrint(
            self.allocator,
            "{{\"ok\":false,\"result\":null,\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}",
            .{ escaped_code, escaped_message },
        );
    }

    pub fn extractErrorInfoFromToolPayload(self: *Session, payload_json: []const u8) !?ToolPayloadErrorInfo {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload_json, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const error_value = parsed.value.object.get("error") orelse return null;
        if (error_value == .null) return null;
        if (error_value == .string) {
            return .{
                .code = try self.allocator.dupe(u8, "service_error"),
                .message = try self.allocator.dupe(u8, error_value.string),
            };
        }
        if (error_value != .object) return null;
        const code = if (error_value.object.get("code")) |code_value|
            if (code_value == .string and code_value.string.len > 0) code_value.string else "service_error"
        else
            "service_error";
        const message = if (error_value.object.get("message")) |message_value|
            if (message_value == .string and message_value.string.len > 0) message_value.string else "tool returned error"
        else
            "tool returned error";
        return .{
            .code = try self.allocator.dupe(u8, code),
            .message = try self.allocator.dupe(u8, message),
        };
    }

    pub fn extractErrorMessageFromToolPayload(self: *Session, payload_json: []const u8) !?[]u8 {
        if (try self.extractErrorInfoFromToolPayload(payload_json)) |info| {
            defer self.allocator.free(info.code);
            return info.message;
        }
        return null;
    }

    fn clearWaitSources(self: *Session) void {
        return events_venom.clearWaitSources(self);
    }

    fn clearSignalEvents(self: *Session) void {
        return events_venom.clearSignalEvents(self);
    }

    fn clearProjectBinds(self: *Session) void {
        for (self.project_binds.items) |*bind| bind.deinit(self.allocator);
        self.project_binds.deinit(self.allocator);
        self.project_binds = .{};
    }

    fn clearWorkspaceMountFsAuthTokens(self: *Session) void {
        var it = self.workspace_mount_fs_auth_tokens.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.workspace_mount_fs_auth_tokens.deinit(self.allocator);
        self.workspace_mount_fs_auth_tokens = .{};
    }

    fn clearWorkspaceMountFsUrls(self: *Session) void {
        var it = self.workspace_mount_fs_urls.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.workspace_mount_fs_urls.deinit(self.allocator);
        self.workspace_mount_fs_urls = .{};
    }

    fn clearWorkspaceMountProxyRoots(self: *Session) void {
        var it = self.workspace_mount_proxy_roots.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.workspace_mount_proxy_roots.deinit(self.allocator);
        self.workspace_mount_proxy_roots = .{};
    }

    fn clearScopedVenomBindings(self: *Session) void {
        for (self.scoped_venom_bindings.items) |*binding| binding.deinit(self.allocator);
        self.scoped_venom_bindings.deinit(self.allocator);
        self.scoped_venom_bindings = .{};
    }

    fn handleEventWaitConfigWrite(self: *Session, node_id: u32, raw_input: []const u8) !WriteOutcome {
        return .{ .written = try events_venom.handleWaitConfigWrite(self, node_id, raw_input) };
    }

    fn handleEventSignalWrite(self: *Session, node_id: u32, raw_input: []const u8) !WriteOutcome {
        return .{ .written = try events_venom.handleSignalWrite(self, node_id, raw_input) };
    }

    fn handleEventNextRead(self: *Session) ![]u8 {
        return events_venom.handleNextRead(self);
    }

    fn refreshScopedVenomIndexes(self: *Session) !void {
        try self.refreshVenomsIndexFile(self.agent_venoms_index_id, "/global/", "global");

        if (self.active_agent_venoms_index_id != 0) {
            const prefix = try std.fmt.allocPrint(self.allocator, "/agents/{s}/venoms/", .{self.agent_id});
            defer self.allocator.free(prefix);
            try self.refreshVenomsIndexFile(self.active_agent_venoms_index_id, prefix, self.agent_id);
        }

        if (self.active_project_venoms_index_id != 0 and self.active_namespace_project_id != null) {
            const prefix = try std.fmt.allocPrint(self.allocator, "/projects/{s}/venoms/", .{self.active_namespace_project_id.?});
            defer self.allocator.free(prefix);
            try self.refreshVenomsIndexFile(self.active_project_venoms_index_id, prefix, self.active_namespace_project_id.?);
        }
    }

    fn refreshVenomsIndexFile(self: *Session, node_id: u32, binding_prefix: []const u8, binding_owner_id: []const u8) !void {
        const index_json = try self.buildScopedVenomsIndexJson(binding_prefix, binding_owner_id);
        defer self.allocator.free(index_json);
        try self.setFileContent(node_id, index_json);
    }

    fn buildScopedVenomsIndexJson(self: *Session, binding_prefix: []const u8, binding_owner_id: []const u8) ![]u8 {
        // Keep node discovery fresh so newly joined nodes are visible in service index reads.
        self.refreshDynamicDirectory(self.nodes_root_id) catch {};

        const nodes_root = self.nodes.get(self.nodes_root_id) orelse return self.allocator.dupe(u8, "[]");
        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(self.allocator);
        try out.append(self.allocator, '[');

        var first = true;
        var node_it = nodes_root.children.iterator();
        while (node_it.next()) |node_entry| {
            const node_id = node_entry.key_ptr.*;
            const node_dir_id = node_entry.value_ptr.*;
            const node_dir = self.nodes.get(node_dir_id) orelse continue;
            if (node_dir.kind != .dir) continue;

            const services_root_id = self.lookupChild(node_dir_id, "venoms") orelse continue;
            const services_root = self.nodes.get(services_root_id) orelse continue;
            if (services_root.kind != .dir) continue;

            var venom_it = services_root.children.iterator();
            while (venom_it.next()) |venom_entry| {
                const venom_id = venom_entry.key_ptr.*;
                const venom_dir_id = venom_entry.value_ptr.*;
                const venom_dir = self.nodes.get(venom_dir_id) orelse continue;
                if (venom_dir.kind != .dir) continue;

                const venom_path = try std.fmt.allocPrint(
                    self.allocator,
                    "/nodes/{s}/venoms/{s}",
                    .{ node_id, venom_id },
                );
                defer self.allocator.free(venom_path);
                const endpoint_path = blk: {
                    if (try self.firstVenomMountPath(venom_dir_id)) |value| break :blk value;
                    break :blk try self.venomEndpointPath(venom_dir_id);
                };
                defer if (endpoint_path) |value| self.allocator.free(value);
                const invoke_path = try self.deriveVenomInvokePath(node_id, venom_id, venom_dir_id);
                defer if (invoke_path) |value| self.allocator.free(value);

                try self.appendAgentVenomIndexEntry(
                    &out,
                    &first,
                    node_id,
                    venom_id,
                    venom_path,
                    endpoint_path,
                    invoke_path,
                    "node",
                    null,
                    null,
                );
            }
        }

        try self.appendScopedVenomBindingIndexEntriesForPrefix(&out, &first, binding_prefix, binding_owner_id);
        try out.append(self.allocator, ']');
        return out.toOwnedSlice(self.allocator);
    }

    fn appendAgentVenomIndexEntry(
        self: *Session,
        out: *std.ArrayListUnmanaged(u8),
        first: *bool,
        node_id: []const u8,
        venom_id: []const u8,
        venom_path: []const u8,
        endpoint_path: ?[]const u8,
        invoke_path: ?[]const u8,
        scope: []const u8,
        provider_node_id: ?[]const u8,
        provider_venom_path: ?[]const u8,
    ) !void {
        const escaped_node_id = try unified.jsonEscape(self.allocator, node_id);
        defer self.allocator.free(escaped_node_id);
        const escaped_venom_id = try unified.jsonEscape(self.allocator, venom_id);
        defer self.allocator.free(escaped_venom_id);
        const escaped_venom_path = try unified.jsonEscape(self.allocator, venom_path);
        defer self.allocator.free(escaped_venom_path);
        const escaped_scope = try unified.jsonEscape(self.allocator, scope);
        defer self.allocator.free(escaped_scope);

        const endpoint_json = if (endpoint_path) |value| blk: {
            const escaped = try unified.jsonEscape(self.allocator, value);
            defer self.allocator.free(escaped);
            break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
        } else try self.allocator.dupe(u8, "null");
        defer self.allocator.free(endpoint_json);

        const invoke_json = if (invoke_path) |value| blk: {
            const escaped = try unified.jsonEscape(self.allocator, value);
            defer self.allocator.free(escaped);
            break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
        } else try self.allocator.dupe(u8, "null");
        defer self.allocator.free(invoke_json);

        const provider_node_json = if (provider_node_id) |value| blk: {
            const escaped = try unified.jsonEscape(self.allocator, value);
            defer self.allocator.free(escaped);
            break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
        } else try self.allocator.dupe(u8, "null");
        defer self.allocator.free(provider_node_json);

        const provider_path_json = if (provider_venom_path) |value| blk: {
            const escaped = try unified.jsonEscape(self.allocator, value);
            defer self.allocator.free(escaped);
            break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
        } else try self.allocator.dupe(u8, "null");
        defer self.allocator.free(provider_path_json);

        if (!first.*) try out.append(self.allocator, ',');
        first.* = false;
        try out.writer(self.allocator).print(
            "{{\"node_id\":\"{s}\",\"venom_id\":\"{s}\",\"venom_path\":\"{s}\",\"endpoint_path\":{s},\"invoke_path\":{s},\"has_invoke\":{s},\"scope\":\"{s}\",\"provider_node_id\":{s},\"provider_venom_path\":{s}}}",
            .{
                escaped_node_id,
                escaped_venom_id,
                escaped_venom_path,
                endpoint_json,
                invoke_json,
                if (invoke_path != null) "true" else "false",
                escaped_scope,
                provider_node_json,
                provider_path_json,
            },
        );
    }

    fn appendScopedVenomBindingIndexEntriesForPrefix(
        self: *Session,
        out: *std.ArrayListUnmanaged(u8),
        first: *bool,
        binding_prefix: []const u8,
        binding_owner_id: []const u8,
    ) !void {
        for (self.scoped_venom_bindings.items) |binding| {
            if (!std.mem.startsWith(u8, binding.venom_path, binding_prefix)) continue;
            try self.appendAgentVenomIndexEntry(
                out,
                first,
                binding_owner_id,
                binding.venom_id,
                binding.venom_path,
                binding.endpoint_path,
                binding.invoke_path,
                binding.scope,
                binding.provider_node_id,
                binding.provider_venom_path,
            );
        }
    }

    fn registerScopedVenomBinding(
        self: *Session,
        venom_id: []const u8,
        scope: []const u8,
        venom_path: []const u8,
        provider_node_id: ?[]const u8,
        provider_venom_path: ?[]const u8,
        endpoint_path: ?[]const u8,
        invoke_path: ?[]const u8,
    ) !void {
        try self.scoped_venom_bindings.append(self.allocator, .{
            .venom_id = try self.allocator.dupe(u8, venom_id),
            .scope = try self.allocator.dupe(u8, scope),
            .venom_path = try self.allocator.dupe(u8, venom_path),
            .provider_node_id = if (provider_node_id) |value| try self.allocator.dupe(u8, value) else null,
            .provider_venom_path = if (provider_venom_path) |value| try self.allocator.dupe(u8, value) else null,
            .endpoint_path = if (endpoint_path) |value| try self.allocator.dupe(u8, value) else null,
            .invoke_path = if (invoke_path) |value| try self.allocator.dupe(u8, value) else null,
        });
    }

    fn registerExistingGlobalVenomBinding(
        self: *Session,
        global_root: u32,
        venom_id: []const u8,
        scope: []const u8,
    ) !void {
        const venom_dir_id = self.lookupChild(global_root, venom_id) orelse return;
        const venom_dir = self.nodes.get(venom_dir_id) orelse return;
        if (venom_dir.kind != .dir) return;

        const venom_path = try std.fmt.allocPrint(self.allocator, "/global/{s}", .{venom_id});
        defer self.allocator.free(venom_path);
        const invoke_path = if (self.venomCapsInvoke(venom_dir_id)) blk: {
            const invoke_target = try self.resolveNodeVenomInvokeTarget(venom_dir_id);
            defer self.allocator.free(invoke_target);
            break :blk try self.pathWithInvokeTarget(venom_path, invoke_target);
        } else null;
        defer if (invoke_path) |value| self.allocator.free(value);

        const local_provider_dir_id = blk: {
            const local_venoms_root = self.lookupLocalNodeVenomsRoot() orelse break :blk null;
            break :blk self.lookupChild(local_venoms_root, venom_id);
        };

        var explicit_provider = if (local_provider_dir_id == null) blk: {
            const plane = self.control_plane orelse break :blk null;
            break :blk try plane.resolveExplicitPreferredVenomProvider(self.allocator, venom_id);
        } else null;
        defer if (explicit_provider) |*value| value.deinit(self.allocator);

        const provider_node_id = if (local_provider_dir_id != null)
            if (try self.resolvePreferredLocalCatalogProviderNodeId(venom_id)) |resolved|
                resolved
            else
                try self.allocator.dupe(u8, "local")
        else if (explicit_provider) |provider|
            try self.allocator.dupe(u8, provider.node_id)
        else
            null;
        defer if (provider_node_id) |value| self.allocator.free(value);
        const provider_venom_path = if (provider_node_id) |node_id|
            try std.fmt.allocPrint(self.allocator, "/nodes/{s}/venoms/{s}", .{ node_id, venom_id })
        else
            null;
        defer if (provider_venom_path) |value| self.allocator.free(value);
        const provider_invoke_path = if (local_provider_dir_id) |provider_dir_id|
            try self.deriveVenomInvokePath(provider_node_id orelse "local", venom_id, provider_dir_id)
        else if (explicit_provider) |provider| blk: {
            const nodes_root = self.lookupChild(self.root_id, "nodes") orelse break :blk null;
            const node_dir_id = self.lookupChild(nodes_root, provider.node_id) orelse break :blk null;
            const venoms_root_id = self.lookupChild(node_dir_id, "venoms") orelse break :blk null;
            const provider_dir_id = self.lookupChild(venoms_root_id, venom_id) orelse break :blk null;
            break :blk try self.deriveVenomInvokePath(provider.node_id, venom_id, provider_dir_id);
        } else null;
        defer if (provider_invoke_path) |value| self.allocator.free(value);

        try self.registerScopedVenomBinding(
            venom_id,
            scope,
            venom_path,
            provider_node_id,
            provider_venom_path,
            if (provider_venom_path != null) provider_venom_path else venom_path,
            if (provider_invoke_path != null) provider_invoke_path else invoke_path,
        );
    }

    pub fn deriveVenomInvokePath(
        self: *Session,
        node_id: []const u8,
        venom_id: []const u8,
        venom_dir_id: u32,
    ) !?[]u8 {
        if (!self.venomCapsInvoke(venom_dir_id)) return null;

        const invoke_target = try self.resolveNodeVenomInvokeTarget(venom_dir_id);
        defer self.allocator.free(invoke_target);

        if (isWorldAbsolutePath(invoke_target)) {
            return try self.allocator.dupe(u8, invoke_target);
        }
        const invoke_suffix = std.mem.trimLeft(u8, invoke_target, "/");
        if (invoke_suffix.len == 0) return null;

        if (try self.firstVenomMountPath(venom_dir_id)) |mount_path| {
            defer self.allocator.free(mount_path);
            return try self.pathWithInvokeTarget(mount_path, invoke_suffix);
        }

        if (try self.venomEndpointPath(venom_dir_id)) |endpoint_path| {
            defer self.allocator.free(endpoint_path);
            return try self.pathWithInvokeTarget(endpoint_path, invoke_suffix);
        }

        return try std.fmt.allocPrint(
            self.allocator,
            "/nodes/{s}/venoms/{s}/{s}",
            .{ node_id, venom_id, invoke_suffix },
        );
    }

    pub fn pathWithInvokeSuffix(self: *Session, base_path: []const u8) ![]u8 {
        const trimmed = std.mem.trimRight(u8, base_path, "/");
        if (trimmed.len == 0) return self.allocator.dupe(u8, "/control/invoke.json");
        if (std.mem.endsWith(u8, trimmed, "/control/invoke.json")) {
            return self.allocator.dupe(u8, trimmed);
        }
        return std.fmt.allocPrint(self.allocator, "{s}/control/invoke.json", .{trimmed});
    }

    pub fn pathWithInvokeTarget(self: *Session, base_path: []const u8, invoke_suffix: []const u8) ![]u8 {
        const base_trimmed = std.mem.trimRight(u8, base_path, "/");
        if (invoke_suffix.len == 0) return self.allocator.dupe(u8, base_trimmed);
        if (base_trimmed.len == 0) {
            return std.fmt.allocPrint(self.allocator, "/{s}", .{invoke_suffix});
        }
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_trimmed, invoke_suffix });
    }

    pub fn resolveNodeVenomInvokeTarget(self: *Session, venom_dir_id: u32) ![]u8 {
        const default_target = "/control/invoke.json";
        const ops_id = self.lookupChild(venom_dir_id, "OPS.json") orelse return self.allocator.dupe(u8, default_target);
        const ops_node = self.nodes.get(ops_id) orelse return self.allocator.dupe(u8, default_target);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, ops_node.content, .{}) catch return self.allocator.dupe(u8, default_target);
        defer parsed.deinit();
        if (parsed.value != .object) return self.allocator.dupe(u8, default_target);

        const candidate = blk: {
            if (parsed.value.object.get("invoke")) |invoke_value| {
                if (invoke_value == .string and invoke_value.string.len > 0) {
                    break :blk invoke_value.string;
                }
            }
            if (parsed.value.object.get("paths")) |paths_value| {
                if (paths_value == .object) {
                    if (paths_value.object.get("invoke")) |invoke_value| {
                        if (invoke_value == .string and invoke_value.string.len > 0) {
                            break :blk invoke_value.string;
                        }
                    }
                }
            }
            break :blk null;
        };

        if (candidate) |value| {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            if (trimmed.len > 0) return self.allocator.dupe(u8, trimmed);
        }
        return self.allocator.dupe(u8, default_target);
    }

    fn firstVenomMountPath(self: *Session, venom_dir_id: u32) !?[]u8 {
        const mounts_id = self.lookupChild(venom_dir_id, "MOUNTS.json") orelse return null;
        const mounts_node = self.nodes.get(mounts_id) orelse return null;
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, mounts_node.content, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .array) return null;

        for (parsed.value.array.items) |mount_value| {
            if (mount_value != .object) continue;
            const mount_path_value = mount_value.object.get("mount_path") orelse continue;
            if (mount_path_value != .string or mount_path_value.string.len == 0) continue;
            return try self.allocator.dupe(u8, mount_path_value.string);
        }
        return null;
    }

    fn venomEndpointPath(self: *Session, venom_dir_id: u32) !?[]u8 {
        const status_id = self.lookupChild(venom_dir_id, "STATUS.json") orelse return null;
        const status_node = self.nodes.get(status_id) orelse return null;
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, status_node.content, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const endpoint_value = parsed.value.object.get("endpoint") orelse return null;
        if (endpoint_value != .string or endpoint_value.string.len == 0) return null;
        return try self.allocator.dupe(u8, endpoint_value.string);
    }

    fn venomCapsInvoke(self: *Session, venom_dir_id: u32) bool {
        const caps_id = self.lookupChild(venom_dir_id, "CAPS.json") orelse return false;
        const caps_node = self.nodes.get(caps_id) orelse return false;
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, caps_node.content, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        const invoke_value = parsed.value.object.get("invoke") orelse return false;
        return invoke_value == .bool and invoke_value.bool;
    }

    fn clearTerminalSessions(self: *Session) void {
        if (self.current_terminal_session_id) |value| self.allocator.free(value);
        self.current_terminal_session_id = null;
        var it = self.terminal_sessions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var session = entry.value_ptr.*;
            session.deinit(self.allocator);
        }
        self.terminal_sessions.deinit(self.allocator);
        self.terminal_sessions = .{};
    }
};

fn isWorldAbsolutePath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/nodes/") or
        std.mem.startsWith(u8, path, "/agents/") or
        std.mem.startsWith(u8, path, "/services/") or
        std.mem.startsWith(u8, path, "/global/") or
        std.mem.startsWith(u8, path, "/debug/");
}

fn defaultGlobalLibraryIndexMd() []const u8 {
    return "# Spiderweb Global Library\n\n" ++
        "- [Getting Started](/nodes/local/venoms/library/topics/getting-started.md)\n" ++
        "- [Service Discovery](/nodes/local/venoms/library/topics/service-discovery.md)\n" ++
        "- [Events and Waits](/nodes/local/venoms/library/topics/events-and-waits.md)\n" ++
        "- [Search Services](/nodes/local/venoms/library/topics/search-services.md)\n" ++
        "- [Terminal Workflows](/nodes/local/venoms/library/topics/terminal-workflows.md)\n" ++
        "- [Memory Workflows](/nodes/local/venoms/library/topics/memory-workflows.md)\n" ++
        "- [Project Mounts and Binds](/nodes/local/venoms/library/topics/project-mounts-and-binds.md)\n" ++
        "- [Agent Management and Sub-Brains](/nodes/local/venoms/library/topics/agent-management-and-sub-brains.md)\n";
}

fn defaultGlobalLibraryTopicGettingStarted() []const u8 {
    return "# Getting Started\n\n" ++
        "1. Discover mounted workspace services in `/meta/workspace_services.json` or `/projects/<project_id>/meta/mounted_services.json`.\n" ++
        "2. Use `/services/<venom_id>` when the workspace binds a service, then fall back to `/nodes/local/venoms/<venom_id>` for local catalog access.\n" ++
        "3. Register external workers through `/services/workers/control/register.json` before expecting worker-owned venoms like memory or sub_brains to appear.\n" ++
        "4. Read each Venom `README.md`, `SCHEMA.json`, `TEMPLATE.json`, `HOST.json`, and `CAPS.json` before using it.\n" ++
        "5. Use `/services/library` when bound, otherwise `/nodes/local/venoms/library`, for system guides.\n";
}

fn defaultGlobalLibraryTopicServiceDiscovery() []const u8 {
    return "# Venom Discovery\n\n" ++
        "- Node Venoms: `/nodes/<node_id>/venoms/<venom_id>`\n" ++
        "- Local built-in Venoms: `/nodes/local/venoms/<venom_id>`\n" ++
        "- Workspace service namespaces: `/services/<venom_id>`\n" ++
        "- Global shared namespaces: `/global/<venom_id>`\n" ++
        "- Start with `/meta/workspace_services.json`, `/projects/<project_id>/meta/mounted_services.json`, or `/nodes/local/venoms/VENOMS.json`.\n" ++
        "- Service Venoms should expose `TEMPLATE.json` and `HOST.json` alongside `SCHEMA.json`, `OPS.json`, and `STATUS.json`.\n" ++
        "- Common workspace Venoms include: home, mounts, workers, terminal, git, search_code, library, and events.\n";
}

fn defaultGlobalLibraryTopicEventsAndWaits() []const u8 {
    return "# Events and Waits\n\n" ++
        "Use single-source blocking reads first for deterministic waits.\n" ++
        "Use `/services/events/control/wait.json` + `/services/events/next.json` when the workspace binds events, otherwise use `/nodes/local/venoms/events/control/wait.json` + `/nodes/local/venoms/events/next.json`.\n";
}

fn defaultGlobalLibraryTopicSearchServices() []const u8 {
    return "# Search Services\n\n" ++
        "Use `/services/search_code` for repository-local search when the workspace binds it, otherwise use `/nodes/local/venoms/search_code`.\n" ++
        "Drive it through `control/invoke.json`, then check `status.json` and `result.json`.\n";
}

fn defaultGlobalLibraryTopicTerminalWorkflows() []const u8 {
    return "# Terminal Workflows\n\n" ++
        "Use `/services/terminal/control/*.json` for sessionized shell execution when bound, otherwise use `/nodes/local/venoms/terminal/control/*.json`.\n" ++
        "Prefer `create` + `write/read` for interactive loops and `exec` for single command tasks.\n";
}

fn defaultGlobalLibraryTopicMemoryWorkflows() []const u8 {
    return "# Memory Workflows\n\n" ++
        "Use worker-owned memory venom paths after registering a worker node (for example `/nodes/<worker-node>/venoms/memory/control/*.json`). Spiderweb does not provide a canonical shared memory venom for Spider Monkey.\n" ++
        "Use `search` before creating duplicate memories.\n";
}

fn defaultGlobalLibraryTopicProjectMountsAndBinds() []const u8 {
    return "# Project Mounts and Binds\n\n" ++
        "Use `/services/mounts/control/mount.json`, `mkdir.json`, and `unmount.json` for project mounts when the workspace binds the mounts service.\n" ++
        "The canonical local origin is `/nodes/local/venoms/mounts/*`, with `/global/mounts/*` retained as a compatibility alias.\n" ++
        "Use `/services/mounts/control/bind.json` and `resolve.json` for stable project paths.\n";
}

fn defaultGlobalLibraryTopicAgentManagementAndSubBrains() []const u8 {
    return "# Agent Management and Sub-Brains\n\n" ++
        "Spiderweb no longer provisions or manages internal agents.\n" ++
        "Use `/global/workspaces` for list/get/up and worker-owned `/nodes/<worker-node>/venoms/sub_brains/*` for private sub-brain control.\n";
}

fn pathMatchesPrefixBoundary(path: []const u8, prefix: []const u8) bool {
    if (std.mem.eql(u8, path, prefix)) return true;
    if (prefix.len == 0) return false;
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len > prefix.len and path[prefix.len] == '/';
}

fn immediateBoundChildName(dir_path: []const u8, bind_path: []const u8) ?[]const u8 {
    const suffix = if (std.mem.eql(u8, dir_path, "/")) blk: {
        if (!std.mem.startsWith(u8, bind_path, "/")) return null;
        if (bind_path.len <= 1) return null;
        break :blk bind_path[1..];
    } else blk: {
        if (!pathMatchesPrefixBoundary(bind_path, dir_path)) return null;
        if (bind_path.len <= dir_path.len + 1) return null;
        break :blk bind_path[dir_path.len + 1 ..];
    };

    const slash_idx = std.mem.indexOfScalar(u8, suffix, '/') orelse suffix.len;
    if (slash_idx == 0) return null;
    return suffix[0..slash_idx];
}

test "immediateBoundChildName returns direct bind child for directory" {
    try std.testing.expectEqualStrings("home", immediateBoundChildName("/services", "/services/home").?);
    try std.testing.expectEqualStrings("services", immediateBoundChildName("/", "/services/home").?);
    try std.testing.expectEqualStrings("codex", immediateBoundChildName("/agents", "/agents/codex/home").?);
    try std.testing.expect(immediateBoundChildName("/services", "/nodes/local/venoms/home") == null);
    try std.testing.expect(immediateBoundChildName("/services/home", "/services/home") == null);
}

fn hostPathMatchesPrefixBoundary(path: []const u8, prefix: []const u8) bool {
    if (builtin.os.tag != .windows) return pathMatchesPrefixBoundary(path, prefix);
    if (std.mem.eql(u8, path, prefix)) return true;
    if (prefix.len == 0 or path.len < prefix.len) return false;

    for (prefix, 0..) |prefix_ch, idx| {
        const path_ch = path[idx];
        const normalized_path = if (path_ch == '\\') '/' else std.ascii.toLower(path_ch);
        const normalized_prefix = if (prefix_ch == '\\') '/' else std.ascii.toLower(prefix_ch);
        if (normalized_path != normalized_prefix) return false;
    }

    if (prefix[prefix.len - 1] == '/' or prefix[prefix.len - 1] == '\\') return true;
    const boundary = path[prefix.len];
    return boundary == '/' or boundary == '\\';
}

const ParsedScopedVenomAlias = struct {
    venom_id: []const u8,
    remote_path: []const u8,
};

const ParsedEntityScopedVenomAlias = struct {
    entity_id: []const u8,
    venom_id: []const u8,
    remote_path: []const u8,
};

const ParsedServiceScopedVenomAlias = struct {
    project_id: []const u8,
    venom_id: []const u8,
    remote_path: []const u8,
};

const ParsedNodeVenomServicePath = struct {
    node_id: []const u8,
    venom_id: []const u8,
};

const ParsedNodeFsProxyPath = struct {
    node_id: []const u8,
    remote_path: []const u8,
};

fn parseScopedVenomAliasPrefix(path: []const u8, prefix: []const u8) ?ParsedScopedVenomAlias {
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const tail = path[prefix.len..];
    if (tail.len == 0) return null;
    const slash_index = std.mem.indexOfScalar(u8, tail, '/') orelse tail.len;
    const venom_id = tail[0..slash_index];
    if (venom_id.len == 0) return null;
    const remote_path = if (slash_index == tail.len) "/" else tail[slash_index..];
    return .{
        .venom_id = venom_id,
        .remote_path = remote_path,
    };
}

fn parseEntityScopedVenomAliasPrefix(
    path: []const u8,
    entity_prefix: []const u8,
    venoms_segment: []const u8,
) ?ParsedEntityScopedVenomAlias {
    if (!std.mem.startsWith(u8, path, entity_prefix)) return null;
    const after_prefix = path[entity_prefix.len..];
    const entity_end = std.mem.indexOfScalar(u8, after_prefix, '/') orelse return null;
    const entity_id = after_prefix[0..entity_end];
    if (entity_id.len == 0) return null;
    const after_entity = after_prefix[entity_end..];
    if (!std.mem.startsWith(u8, after_entity, venoms_segment)) return null;
    const after_venoms = after_entity[venoms_segment.len..];
    if (after_venoms.len == 0) return null;
    const venom_end = std.mem.indexOfScalar(u8, after_venoms, '/') orelse after_venoms.len;
    const venom_id = after_venoms[0..venom_end];
    if (venom_id.len == 0) return null;
    const remote_path = if (venom_end == after_venoms.len) "/" else after_venoms[venom_end..];
    return .{
        .entity_id = entity_id,
        .venom_id = venom_id,
        .remote_path = remote_path,
    };
}

fn parseServiceScopedVenomAliasPrefix(self: *Session, path: []const u8) ?ParsedServiceScopedVenomAlias {
    const project_id = self.active_namespace_project_id orelse self.project_id orelse return null;
    const parsed = parseScopedVenomAliasPrefix(path, "/services/") orelse
        parseScopedVenomAliasPrefix(path, workspace_managed_services_absolute_prefix) orelse
        return null;
    return .{
        .project_id = project_id,
        .venom_id = parsed.venom_id,
        .remote_path = parsed.remote_path,
    };
}

fn parseNodeVenomServicePath(path: []const u8) ?ParsedNodeVenomServicePath {
    if (!std.mem.startsWith(u8, path, "/nodes/")) return null;
    const after_prefix = path["/nodes/".len..];
    const node_end = std.mem.indexOfScalar(u8, after_prefix, '/') orelse return null;
    const node_id = after_prefix[0..node_end];
    if (node_id.len == 0) return null;
    const after_node = after_prefix[node_end..];
    if (!std.mem.startsWith(u8, after_node, "/venoms/")) return null;
    const after_venoms = after_node["/venoms/".len..];
    if (after_venoms.len == 0) return null;
    const venom_end = std.mem.indexOfScalar(u8, after_venoms, '/') orelse after_venoms.len;
    const venom_id = after_venoms[0..venom_end];
    if (venom_id.len == 0) return null;
    return .{
        .node_id = node_id,
        .venom_id = venom_id,
    };
}

fn parseNodeFsProxyPath(path: []const u8) ?ParsedNodeFsProxyPath {
    if (!std.mem.startsWith(u8, path, "/nodes/")) return null;
    const after_prefix = path["/nodes/".len..];
    const node_end = std.mem.indexOfScalar(u8, after_prefix, '/') orelse return null;
    const node_id = after_prefix[0..node_end];
    if (node_id.len == 0 or std.mem.eql(u8, node_id, "local")) return null;
    const after_node = after_prefix[node_end..];
    if (!std.mem.startsWith(u8, after_node, "/fs")) return null;
    if (after_node.len == "/fs".len) {
        return .{
            .node_id = node_id,
            .remote_path = "/",
        };
    }
    if (after_node["/fs".len] != '/') return null;
    return .{
        .node_id = node_id,
        .remote_path = after_node["/fs".len..],
    };
}

fn boundVenomRemoteSuffix(allocator: std.mem.Allocator, absolute_path: []const u8, prefix: []const u8) ![]u8 {
    if (!pathMatchesPrefixBoundary(absolute_path, prefix)) return error.InvalidPath;
    if (std.mem.eql(u8, absolute_path, prefix)) return allocator.dupe(u8, "/");
    return std.fmt.allocPrint(allocator, "{s}", .{absolute_path[prefix.len..]});
}

fn parseBoundVenomProxyAttr(attr_val: std.json.Value) ?BoundVenomProxyAttrSummary {
    if (attr_val != .object) return null;

    const mode: ?u32 = if (attr_val.object.get("m")) |value|
        switch (value) {
            .integer => if (value.integer >= 0) @intCast(value.integer) else return null,
            else => return null,
        }
    else
        null;
    const effective_mode = mode orelse 0;

    const kind: NodeKind = if (attr_val.object.get("k")) |value|
        switch (value) {
            .integer => switch (value.integer) {
                2 => .dir,
                1 => .file,
                else => if ((effective_mode & 0o170000) == 0o040000) .dir else .file,
            },
            else => if ((effective_mode & 0o170000) == 0o040000) .dir else .file,
        }
    else if ((effective_mode & 0o170000) == 0o040000)
        .dir
    else
        .file;

    const size: ?u64 = if (attr_val.object.get("sz")) |value|
        switch (value) {
            .integer => if (value.integer >= 0) @intCast(value.integer) else return null,
            else => return null,
        }
    else
        null;

    return .{
        .kind = kind,
        .writable = (effective_mode & 0o222) != 0,
        .mode = mode,
        .size = size,
    };
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |char| {
        switch (char) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (char < 0x20) {
                try writer.print("\\u00{x:0>2}", .{char});
            } else {
                try writer.writeByte(char);
            },
        }
    }
    try writer.writeByte('"');
}

fn jsonObjectOptionalString(obj: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    if (obj.get(key)) |value| {
        if (value == .null) return null;
        if (value != .string) return error.InvalidPayload;
        return value.string;
    }
    return null;
}

fn jsonObjectOptionalBool(obj: std.json.ObjectMap, key: []const u8) !?bool {
    if (obj.get(key)) |value| {
        if (value == .null) return null;
        if (value != .bool) return error.InvalidPayload;
        return value.bool;
    }
    return null;
}

fn jsonObjectOptionalU64(obj: std.json.ObjectMap, key: []const u8) !?u64 {
    if (obj.get(key)) |value| {
        if (value == .null) return null;
        return switch (value) {
            .integer => |signed| blk: {
                if (signed < 0) return error.InvalidPayload;
                break :blk @as(u64, @intCast(signed));
            },
            .float => |float_value| blk: {
                if (float_value < 0) return error.InvalidPayload;
                if (std.math.floor(float_value) != float_value) return error.InvalidPayload;
                if (float_value > @as(f64, @floatFromInt(std.math.maxInt(u64)))) return error.InvalidPayload;
                break :blk @as(u64, @intFromFloat(float_value));
            },
            else => return error.InvalidPayload,
        };
    }
    return null;
}

fn sameOptionalString(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |left_value| {
        const right_value = right orelse return false;
        return std.mem.eql(u8, left_value, right_value);
    }
    return right == null;
}

fn isActiveMissionState(state: mission_store_mod.MissionState) bool {
    return switch (state) {
        .completed, .failed, .cancelled => false,
        else => true,
    };
}

fn kindName(kind: NodeKind) []const u8 {
    return switch (kind) {
        .dir => "dir",
        .file => "file",
    };
}

fn nodeMode(node: Node) u32 {
    return switch (node.kind) {
        .dir => 0o040755,
        .file => if (node.writable) 0o100644 else 0o100444,
    };
}

fn effectiveNodeMode(node: Node) u32 {
    return node.reported_mode orelse nodeMode(node);
}

fn effectiveNodeSize(node: Node) usize {
    if (node.kind != .file) return 0;
    if (node.reported_size) |size| {
        return std.math.cast(usize, size) orelse std.math.maxInt(usize);
    }
    return node.content.len;
}

fn effectiveNodeSizeU64(node: Node) u64 {
    if (node.kind != .file) return 0;
    return node.reported_size orelse node.content.len;
}

fn isManagedSharedDataProjectedPath(path: []const u8) bool {
    const managed_root = workspace_managed_root_absolute ++ "/" ++ workspace_managed_shared_data_dir_name;
    return std.mem.eql(u8, path, managed_root) or pathMatchesPrefixBoundary(path, managed_root);
}

fn readonlyMode(mode: u32, kind: NodeKind) u32 {
    const base: u32 = if (mode == 0) switch (kind) {
        .dir => @as(u32, 0o040755),
        .file => @as(u32, 0o100644),
    } else mode;
    return base & ~@as(u32, 0o222);
}

fn projectMountPathToLinkName(allocator: std.mem.Allocator, mount_path: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "mount::");

    const trimmed = std.mem.trim(u8, mount_path, "/");
    if (trimmed.len == 0) {
        try out.appendSlice(allocator, "root");
        return out.toOwnedSlice(allocator);
    }

    var part_it = std.mem.tokenizeScalar(u8, trimmed, '/');
    var first = true;
    while (part_it.next()) |part| {
        if (part.len == 0) continue;
        if (!first) try out.appendSlice(allocator, "::");
        first = false;
        try out.appendSlice(allocator, part);
    }
    if (first) try out.appendSlice(allocator, "root");
    return out.toOwnedSlice(allocator);
}

fn allocPathSegments(allocator: std.mem.Allocator, segments: []const []const u8) ![][]u8 {
    var path = try allocator.alloc([]u8, segments.len);
    errdefer allocator.free(path);
    var filled: usize = 0;
    errdefer {
        var idx: usize = 0;
        while (idx < filled) : (idx += 1) allocator.free(path[idx]);
    }
    for (segments, 0..) |segment, idx| {
        path[idx] = try allocator.dupe(u8, segment);
        filled = idx + 1;
    }
    return path;
}

fn freePathSegments(allocator: std.mem.Allocator, path: [][]u8) void {
    for (path) |segment| allocator.free(segment);
    allocator.free(path);
}

fn protocolWriteFile(
    session: *Session,
    allocator: std.mem.Allocator,
    attach_fid: u32,
    walk_fid: u32,
    segments: []const []const u8,
    data: []const u8,
    tag_base: u16,
) !void {
    var attach = unified.ParsedMessage{
        .channel = .acheron,
        .acheron_type = .t_attach,
        .tag = tag_base,
        .fid = attach_fid,
    };
    const attach_res = try session.handle(&attach);
    defer allocator.free(attach_res);
    try std.testing.expect(std.mem.indexOf(u8, attach_res, "acheron.r_attach") != null);

    const path = try allocPathSegments(allocator, segments);
    defer freePathSegments(allocator, path);
    var walk = unified.ParsedMessage{
        .channel = .acheron,
        .acheron_type = .t_walk,
        .tag = tag_base + 1,
        .fid = attach_fid,
        .newfid = walk_fid,
        .path = path,
    };
    const walk_res = try session.handle(&walk);
    defer allocator.free(walk_res);
    try std.testing.expect(std.mem.indexOf(u8, walk_res, "acheron.r_walk") != null);

    var open = unified.ParsedMessage{
        .channel = .acheron,
        .acheron_type = .t_open,
        .tag = tag_base + 2,
        .fid = walk_fid,
        .mode = "w",
    };
    const open_res = try session.handle(&open);
    defer allocator.free(open_res);
    try std.testing.expect(std.mem.indexOf(u8, open_res, "acheron.r_open") != null);

    var write = unified.ParsedMessage{
        .channel = .acheron,
        .acheron_type = .t_write,
        .tag = tag_base + 3,
        .fid = walk_fid,
        .offset = 0,
        .data = data,
    };
    const write_res = try session.handle(&write);
    defer allocator.free(write_res);
    try std.testing.expect(std.mem.indexOf(u8, write_res, "acheron.r_write") != null);

    var clunk = unified.ParsedMessage{
        .channel = .acheron,
        .acheron_type = .t_clunk,
        .tag = tag_base + 4,
        .fid = walk_fid,
    };
    const clunk_res = try session.handle(&clunk);
    defer allocator.free(clunk_res);
    try std.testing.expect(std.mem.indexOf(u8, clunk_res, "acheron.r_clunk") != null);
}

fn protocolWriteFileExpectError(
    session: *Session,
    allocator: std.mem.Allocator,
    attach_fid: u32,
    walk_fid: u32,
    segments: []const []const u8,
    data: []const u8,
    tag_base: u16,
    expected_error_code: []const u8,
) ![]u8 {
    var attach = unified.ParsedMessage{
        .channel = .acheron,
        .acheron_type = .t_attach,
        .tag = tag_base,
        .fid = attach_fid,
    };
    const attach_res = try session.handle(&attach);
    defer allocator.free(attach_res);
    try std.testing.expect(std.mem.indexOf(u8, attach_res, "acheron.r_attach") != null);

    const path = try allocPathSegments(allocator, segments);
    defer freePathSegments(allocator, path);
    var walk = unified.ParsedMessage{
        .channel = .acheron,
        .acheron_type = .t_walk,
        .tag = tag_base + 1,
        .fid = attach_fid,
        .newfid = walk_fid,
        .path = path,
    };
    const walk_res = try session.handle(&walk);
    defer allocator.free(walk_res);
    try std.testing.expect(std.mem.indexOf(u8, walk_res, "acheron.r_walk") != null);

    var open = unified.ParsedMessage{
        .channel = .acheron,
        .acheron_type = .t_open,
        .tag = tag_base + 2,
        .fid = walk_fid,
        .mode = "w",
    };
    const open_res = try session.handle(&open);
    defer allocator.free(open_res);
    try std.testing.expect(std.mem.indexOf(u8, open_res, "acheron.r_open") != null);

    var write = unified.ParsedMessage{
        .channel = .acheron,
        .acheron_type = .t_write,
        .tag = tag_base + 3,
        .fid = walk_fid,
        .offset = 0,
        .data = data,
    };
    const write_res = try session.handle(&write);
    errdefer allocator.free(write_res);
    if (std.mem.indexOf(u8, write_res, "acheron.error") != null) {
        if (expected_error_code.len > 0) {
            const pattern = try std.fmt.allocPrint(allocator, "\"code\":\"{s}\"", .{expected_error_code});
            defer allocator.free(pattern);
            try std.testing.expect(std.mem.indexOf(u8, write_res, pattern) != null);
        }
        return write_res;
    }

    var clunk = unified.ParsedMessage{
        .channel = .acheron,
        .acheron_type = .t_clunk,
        .tag = tag_base + 4,
        .fid = walk_fid,
    };
    allocator.free(write_res);
    const clunk_res = try session.handle(&clunk);
    errdefer allocator.free(clunk_res);
    try std.testing.expect(std.mem.indexOf(u8, clunk_res, "acheron.error") != null);
    if (expected_error_code.len > 0) {
        const pattern = try std.fmt.allocPrint(allocator, "\"code\":\"{s}\"", .{expected_error_code});
        defer allocator.free(pattern);
        try std.testing.expect(std.mem.indexOf(u8, clunk_res, pattern) != null);
    }
    return clunk_res;
}

fn protocolReadFile(
    session: *Session,
    allocator: std.mem.Allocator,
    attach_fid: u32,
    walk_fid: u32,
    segments: []const []const u8,
    tag_base: u16,
) ![]u8 {
    var attach = unified.ParsedMessage{
        .channel = .acheron,
        .acheron_type = .t_attach,
        .tag = tag_base,
        .fid = attach_fid,
    };
    const attach_res = try session.handle(&attach);
    defer allocator.free(attach_res);
    try std.testing.expect(std.mem.indexOf(u8, attach_res, "acheron.r_attach") != null);

    const path = try allocPathSegments(allocator, segments);
    defer freePathSegments(allocator, path);
    var walk = unified.ParsedMessage{
        .channel = .acheron,
        .acheron_type = .t_walk,
        .tag = tag_base + 1,
        .fid = attach_fid,
        .newfid = walk_fid,
        .path = path,
    };
    const walk_res = try session.handle(&walk);
    defer allocator.free(walk_res);
    try std.testing.expect(std.mem.indexOf(u8, walk_res, "acheron.r_walk") != null);

    var open = unified.ParsedMessage{
        .channel = .acheron,
        .acheron_type = .t_open,
        .tag = tag_base + 2,
        .fid = walk_fid,
        .mode = "r",
    };
    const open_res = try session.handle(&open);
    defer allocator.free(open_res);
    try std.testing.expect(std.mem.indexOf(u8, open_res, "acheron.r_open") != null);

    var read = unified.ParsedMessage{
        .channel = .acheron,
        .acheron_type = .t_read,
        .tag = tag_base + 3,
        .fid = walk_fid,
        .offset = 0,
        .count = 1_048_576,
    };
    const read_res = try session.handle(&read);
    defer allocator.free(read_res);
    return decodeReadResponseData(allocator, read_res);
}

test "acheron_session: terminal control writes commit on clunk after chunked appends" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "agent-under-test",
        .{
            .actor_type = "agent",
            .actor_id = "agent-under-test",
        },
    );
    defer session.deinit();

    var attach = unified.ParsedMessage{
        .channel = .acheron,
        .acheron_type = .t_attach,
        .tag = 4000,
        .fid = 500,
    };
    const attach_res = try session.handle(&attach);
    defer allocator.free(attach_res);

    const path = try allocPathSegments(allocator, &.{ "nodes", "local", "venoms", "terminal", "control", "create.json" });
    defer freePathSegments(allocator, path);
    var walk = unified.ParsedMessage{
        .channel = .acheron,
        .acheron_type = .t_walk,
        .tag = 4001,
        .fid = 500,
        .newfid = 501,
        .path = path,
    };
    const walk_res = try session.handle(&walk);
    defer allocator.free(walk_res);

    var open = unified.ParsedMessage{
        .channel = .acheron,
        .acheron_type = .t_open,
        .tag = 4002,
        .fid = 501,
        .mode = "w",
    };
    const open_res = try session.handle(&open);
    defer allocator.free(open_res);

    var write_a = unified.ParsedMessage{
        .channel = .acheron,
        .acheron_type = .t_write,
        .tag = 4003,
        .fid = 501,
        .offset = 0,
        .data = "{\"session_id\":\"split",
    };
    const write_a_res = try session.handle(&write_a);
    defer allocator.free(write_a_res);
    try std.testing.expect(std.mem.indexOf(u8, write_a_res, "\"n\":20") != null);

    var write_b = unified.ParsedMessage{
        .channel = .acheron,
        .acheron_type = .t_write,
        .tag = 4004,
        .fid = 501,
        .offset = 20,
        .data = "-session\",\"label\":\"chunked\"}",
    };
    const write_b_res = try session.handle(&write_b);
    defer allocator.free(write_b_res);
    try std.testing.expect(std.mem.indexOf(u8, write_b_res, "\"n\":28") != null);

    const before_clunk = try protocolReadFile(
        &session,
        allocator,
        502,
        503,
        &.{ "nodes", "local", "venoms", "terminal", "current.json" },
        4005,
    );
    defer allocator.free(before_clunk);
    try std.testing.expect(std.mem.indexOf(u8, before_clunk, "\"session\":null") != null);

    var clunk = unified.ParsedMessage{
        .channel = .acheron,
        .acheron_type = .t_clunk,
        .tag = 4006,
        .fid = 501,
    };
    const clunk_res = try session.handle(&clunk);
    defer allocator.free(clunk_res);
    try std.testing.expect(std.mem.indexOf(u8, clunk_res, "acheron.r_clunk") != null);

    const after_clunk = try protocolReadFile(
        &session,
        allocator,
        504,
        505,
        &.{ "nodes", "local", "venoms", "terminal", "current.json" },
        4007,
    );
    defer allocator.free(after_clunk);
    try std.testing.expect(std.mem.indexOf(u8, after_clunk, "split-session") != null);
}

test "acheron_session: terminal metadata disables interactive sessions off linux" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "agent-under-test",
        .{
            .actor_type = "agent",
            .actor_id = "agent-under-test",
        },
    );
    defer session.deinit();

    const create_error = try protocolWriteFileExpectError(
        &session,
        allocator,
        4050,
        4051,
        &.{ "nodes", "local", "venoms", "terminal", "control", "create.json" },
        "{}",
        4052,
        "unsupported",
    );
    defer allocator.free(create_error);

    const status_json = try protocolReadFile(
        &session,
        allocator,
        4053,
        4054,
        &.{ "nodes", "local", "venoms", "terminal", "STATUS.json" },
        4055,
    );
    defer allocator.free(status_json);
    try std.testing.expect(std.mem.indexOf(u8, status_json, "\"interactive\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_json, "\"sessionized\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_json, "\"pty\":false") != null);
}

fn runTestCommandCapture(
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
    argv: []const []const u8,
) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
    });
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| {
            if (code == 0) return result.stdout;
            allocator.free(result.stdout);
            return error.TestExpectedResponse;
        },
        else => {
            allocator.free(result.stdout);
            return error.TestExpectedResponse;
        },
    }
}

fn extractMissionIdFromResultPayload(
    allocator: std.mem.Allocator,
    result_payload: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result_payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.TestExpectedResponse;
    const result_value = parsed.value.object.get("result") orelse return error.TestExpectedResponse;
    if (result_value != .object) return error.TestExpectedResponse;
    const mission_value = result_value.object.get("mission") orelse return error.TestExpectedResponse;
    if (mission_value != .object) return error.TestExpectedResponse;
    const mission_id_value = mission_value.object.get("mission_id") orelse return error.TestExpectedResponse;
    if (mission_id_value != .string or mission_id_value.string.len == 0) return error.TestExpectedResponse;
    return allocator.dupe(u8, mission_id_value.string);
}

fn decodeReadResponseData(allocator: std.mem.Allocator, frame: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, frame, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.TestExpectedResponse;

    const payload = parsed.value.object.get("payload") orelse return error.TestExpectedResponse;
    if (payload != .object) return error.TestExpectedResponse;
    const data_b64 = payload.object.get("data_b64") orelse return error.TestExpectedResponse;
    if (data_b64 != .string) return error.TestExpectedResponse;

    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(data_b64.string);
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, data_b64.string);
    return decoded;
}

test "acheron_session: preferred service paths use workspace bindings when available" {
    const allocator = std.testing.allocator;

    var control_plane = control_plane_mod.ControlPlane.init(allocator);
    defer control_plane.deinit();

    const project_json = try control_plane.createProject(
        "{\"name\":\"SessionServicePaths\",\"vision\":\"SessionServicePaths\",\"template_id\":\"github\"}",
    );
    defer allocator.free(project_json);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer parsed_project.deinit();
    const project_id = parsed_project.value.object.get("project_id").?.string;
    const project_token = parsed_project.value.object.get("project_token").?.string;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var bound_session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "default",
        .{
            .project_id = project_id,
            .project_token = project_token,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .control_plane = &control_plane,
        },
    );
    defer bound_session.deinit();

    const bound_github_path = try bound_session.resolvePreferredServicePath("github_pr", "/control/sync.json");
    defer allocator.free(bound_github_path);
    try std.testing.expectEqualStrings("/services/github_pr/control/sync.json", bound_github_path);

    const bound_missions_path = try bound_session.resolvePreferredServicePath("missions", "/control/request_approval.json");
    defer allocator.free(bound_missions_path);
    try std.testing.expectEqualStrings("/services/missions/control/request_approval.json", bound_missions_path);

    var unbound_session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "default",
        .{
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
        },
    );
    defer unbound_session.deinit();

    const unbound_github_path = try unbound_session.resolvePreferredServicePath("github_pr", "/control/sync.json");
    defer allocator.free(unbound_github_path);
    try std.testing.expectEqualStrings("/global/github_pr/control/sync.json", unbound_github_path);
}

test "acheron_session: workspace AGENTS contract is seeded and preserves user notes" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "exports/AGENTS.md",
        .data = "## Workspace Owner Notes\n\nKeep custom lint rules in mind.\n",
    });

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    var control_plane = control_plane_mod.ControlPlane.init(allocator);
    defer control_plane.deinit();

    const project_json = try control_plane.createProject(
        "{\"name\":\"AgentsSeeded\",\"vision\":\"Deliver the mounted workspace contract\"}",
    );
    defer allocator.free(project_json);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer parsed_project.deinit();
    const project_id = parsed_project.value.object.get("project_id").?.string;
    const project_token = parsed_project.value.object.get("project_token").?.string;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "codex",
        .{
            .project_id = project_id,
            .project_token = project_token,
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .control_plane = &control_plane,
            .actor_type = "agent",
            .actor_id = "codex",
        },
    );
    defer session.deinit();

    const namespace_agents = try session.tryReadInternalPath("/AGENTS.md");
    defer if (namespace_agents) |value| allocator.free(value);
    try std.testing.expect(namespace_agents != null);
    try std.testing.expect(std.mem.indexOf(u8, namespace_agents.?, workspace_agents_managed_begin) != null);
    try std.testing.expect(std.mem.indexOf(u8, namespace_agents.?, "Project vision is tracked by Spiderweb project metadata") != null);
    try std.testing.expect(std.mem.indexOf(u8, namespace_agents.?, "Keep custom lint rules in mind.") != null);
    try std.testing.expect(std.mem.indexOf(u8, namespace_agents.?, "./.spiderweb/protocol.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, namespace_agents.?, "./.spiderweb/services/home/control/ensure.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, namespace_agents.?, "./.spiderweb/local_venoms") != null);
    try std.testing.expect(std.mem.indexOf(u8, namespace_agents.?, "../../..") == null);
    try std.testing.expect(std.mem.indexOf(u8, namespace_agents.?, "TASK.md") == null);

    const workspace_agents = try session.tryReadInternalPath("/nodes/local/fs/AGENTS.md");
    defer if (workspace_agents) |value| allocator.free(value);
    try std.testing.expect(workspace_agents != null);
    try std.testing.expectEqualStrings(namespace_agents.?, workspace_agents.?);

    const quickref_path = try std.fmt.allocPrint(allocator, "/projects/{s}/meta/agent_bootstrap_quickref.json", .{project_id});
    defer allocator.free(quickref_path);
    const quickref_json = try session.tryReadInternalPath(quickref_path);
    defer if (quickref_json) |value| allocator.free(value);
    try std.testing.expect(quickref_json != null);
    try std.testing.expect(std.mem.indexOf(u8, quickref_json.?, "\"project_write_root\":\".\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, quickref_json.?, "\"service_root\":\"./.spiderweb/services\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, quickref_json.?, "\"./AGENTS.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, quickref_json.?, "\"protocol\":\"./.spiderweb/protocol.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, quickref_json.?, "\"namespace_root\"") == null);

    const bootstrap_path = try std.fmt.allocPrint(allocator, "/projects/{s}/meta/agent_bootstrap.json", .{project_id});
    defer allocator.free(bootstrap_path);
    const bootstrap_json = try session.tryReadInternalPath(bootstrap_path);
    defer if (bootstrap_json) |value| allocator.free(value);
    try std.testing.expect(bootstrap_json != null);
    try std.testing.expect(std.mem.indexOf(u8, bootstrap_json.?, "\"required_reads\":[\"./AGENTS.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bootstrap_json.?, "\"./.spiderweb/agent_bootstrap_quickref.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bootstrap_json.?, "\"preferred_root\":\"./.spiderweb/services\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bootstrap_json.?, "\"service\":\"./.spiderweb/services/home\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bootstrap_json.?, "\"fallback_roots\":[\"./.spiderweb/local_venoms\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bootstrap_json.?, "\"namespace_root\"") == null);

    const workspace_bootstrap_paths = [_][]const u8{
        "/nodes/local/fs/.spiderweb/protocol.json",
        "/nodes/local/fs/.spiderweb/agent_bootstrap_quickref.json",
        "/nodes/local/fs/.spiderweb/agent_bootstrap.json",
        "/nodes/local/fs/.spiderweb/workspace_status.json",
        "/nodes/local/fs/.spiderweb/mounted_services.json",
        "/nodes/local/fs/.spiderweb/venom_packages.json",
        "/nodes/local/fs/.spiderweb/services/home/control/ensure.json",
        "/nodes/local/fs/.spiderweb/services/mounts/control/bind.json",
        "/nodes/local/fs/.spiderweb/local_venoms/home/control/ensure.json",
    };
    for (workspace_bootstrap_paths) |path| {
        const content = try session.tryReadInternalPath(path);
        defer if (content) |value| allocator.free(value);
        try std.testing.expect(content != null);
    }

    tmp_dir.dir.access("exports/.spiderweb", .{}) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const workspace_agents_id = session.resolveAbsolutePathNoBinds("/nodes/local/fs/AGENTS.md") orelse return error.MissingNode;
    try session.setFileContent(workspace_agents_id, "# User Override\n");

    const namespace_agents_updated = try session.tryReadInternalPath("/AGENTS.md");
    defer if (namespace_agents_updated) |value| allocator.free(value);
    try std.testing.expect(namespace_agents_updated != null);
    try std.testing.expectEqualStrings("# User Override\n", namespace_agents_updated.?);
}

test "acheron_session: workspace mount aliases project live mounts into the namespace" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "exports/AGENTS.md",
        .data = "## Workspace Owner Notes\n\nKeep shared inputs mounted.\n",
    });

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    var control_plane = control_plane_mod.ControlPlane.init(allocator);
    defer control_plane.deinit();

    const remote_joined = try control_plane.ensureNode("edge-remote", "ws://127.0.0.1:28891/fs", 60_000);
    defer allocator.free(remote_joined);
    var remote_parsed = try std.json.parseFromSlice(std.json.Value, allocator, remote_joined, .{});
    defer remote_parsed.deinit();
    const remote_node_id = remote_parsed.value.object.get("node_id").?.string;

    const project_up = try control_plane.projectUp(
        "codex",
        try std.fmt.allocPrint(
            allocator,
            "{{\"name\":\"MountAliasProject\",\"vision\":\"Project mounts must be visible from the namespace itself\",\"desired_mounts\":[{{\"mount_path\":\"/shared_data\",\"node_id\":\"{s}\",\"export_name\":\"shared\"}}]}}",
            .{remote_node_id},
        ),
    );
    defer allocator.free(project_up);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_up, .{});
    defer parsed_project.deinit();
    const project_id = parsed_project.value.object.get("project_id").?.string;
    const project_token = parsed_project.value.object.get("project_token").?.string;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "codex",
        .{
            .project_id = project_id,
            .project_token = project_token,
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .control_plane = &control_plane,
            .actor_type = "agent",
            .actor_id = "codex",
        },
    );
    defer session.deinit();

    const remote_export_path = try std.fmt.allocPrint(allocator, "/nodes/{s}/shared", .{remote_node_id});
    defer allocator.free(remote_export_path);
    const remote_export_dir = session.resolveAbsolutePathNoBinds(remote_export_path) orelse return error.MissingNode;
    _ = try session.addFile(remote_export_dir, "world_seed.json", "{\"world\":\"ok\"}\n", false, .none);

    const root_listing = try session.renderDirListing(session.root_id);
    defer allocator.free(root_listing);
    try std.testing.expect(std.mem.indexOf(u8, root_listing, "shared_data") != null);

    const shared_data_file = try session.tryReadInternalPath("/shared_data/world_seed.json");
    defer if (shared_data_file) |value| allocator.free(value);
    try std.testing.expect(shared_data_file != null);
    try std.testing.expectEqualStrings("{\"world\":\"ok\"}\n", shared_data_file.?);

    const project_local_shared = try session.tryReadInternalPath("/nodes/local/fs/.spiderweb/shared_data/world_seed.json");
    defer if (project_local_shared) |value| allocator.free(value);
    try std.testing.expect(project_local_shared != null);
    try std.testing.expectEqualStrings("{\"world\":\"ok\"}\n", project_local_shared.?);

    const binds_json = try session.buildProjectBindsArrayJson();
    defer allocator.free(binds_json);
    try std.testing.expect(std.mem.indexOf(u8, binds_json, "\"bind_path\":\"/shared_data\"") == null);
    var found_workspace_mount = false;
    for (session.project_binds.items) |bind| {
        if (bind.kind != .workspace_mount) continue;
        if (!std.mem.eql(u8, bind.bind_path, "/shared_data")) continue;
        found_workspace_mount = true;
        const expected_target = try std.fmt.allocPrint(allocator, "/nodes/{s}/shared", .{remote_node_id});
        defer allocator.free(expected_target);
        try std.testing.expectEqualStrings(expected_target, bind.target_path);
    }
    try std.testing.expect(found_workspace_mount);
}

test "acheron_session: workspace bind overrides the host local fs path" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "exports/local-only.txt",
        .data = "local\n",
    });

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    var control_plane = control_plane_mod.ControlPlane.init(allocator);
    defer control_plane.deinit();

    const remote_joined = try control_plane.ensureNode("workspace-remote", "ws://127.0.0.1:28892/fs", 60_000);
    defer allocator.free(remote_joined);
    var remote_parsed = try std.json.parseFromSlice(std.json.Value, allocator, remote_joined, .{});
    defer remote_parsed.deinit();
    const remote_node_id = remote_parsed.value.object.get("node_id").?.string;

    const project_up = try control_plane.projectUp(
        "codex",
        try std.fmt.allocPrint(
            allocator,
            "{{\"name\":\"WorkspaceBindOverride\",\"vision\":\"Project binds must override host local fs paths\",\"desired_mounts\":[{{\"mount_path\":\"/nodes/local/fs\",\"node_id\":\"{s}\",\"export_name\":\"workspace\"}}]}}",
            .{remote_node_id},
        ),
    );
    defer allocator.free(project_up);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_up, .{});
    defer parsed_project.deinit();
    const project_id = parsed_project.value.object.get("project_id").?.string;
    const project_token = parsed_project.value.object.get("project_token").?.string;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "codex",
        .{
            .project_id = project_id,
            .project_token = project_token,
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .control_plane = &control_plane,
            .actor_type = "agent",
            .actor_id = "codex",
        },
    );
    defer session.deinit();

    const remote_export_path = try std.fmt.allocPrint(allocator, "/nodes/{s}/workspace", .{remote_node_id});
    defer allocator.free(remote_export_path);
    const remote_export_dir = session.resolveAbsolutePathNoBinds(remote_export_path) orelse return error.MissingNode;
    _ = try session.addFile(remote_export_dir, "remote.txt", "remote\n", false, .none);

    const rebound_remote = try session.tryReadInternalPath("/nodes/local/fs/remote.txt");
    defer if (rebound_remote) |value| allocator.free(value);
    try std.testing.expect(rebound_remote != null);
    try std.testing.expectEqualStrings("remote\n", rebound_remote.?);

    const shadowed_local = try session.tryReadInternalPath("/nodes/local/fs/local-only.txt");
    defer if (shadowed_local) |value| allocator.free(value);
    try std.testing.expect(shadowed_local == null);
}

test "acheron_session: admin namespace sessions retain workspace mount auth tokens" {
    const allocator = std.testing.allocator;

    var control_plane = control_plane_mod.ControlPlane.init(allocator);
    defer control_plane.deinit();

    const remote_joined = try control_plane.ensureNode("workspace-remote", "ws://127.0.0.1:28893/fs", 60_000);
    defer allocator.free(remote_joined);
    var remote_parsed = try std.json.parseFromSlice(std.json.Value, allocator, remote_joined, .{});
    defer remote_parsed.deinit();
    const remote_node_id = remote_parsed.value.object.get("node_id").?.string;

    const project_up = try control_plane.projectUp(
        "codex",
        try std.fmt.allocPrint(
            allocator,
            "{{\"name\":\"AdminMountTokens\",\"vision\":\"Admin namespace sessions must retain workspace mount auth tokens\",\"desired_mounts\":[{{\"mount_path\":\"/shared_data\",\"node_id\":\"{s}\",\"export_name\":\"shared\"}}]}}",
            .{remote_node_id},
        ),
    );
    defer allocator.free(project_up);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_up, .{});
    defer parsed_project.deinit();
    const project_id = parsed_project.value.object.get("project_id").?.string;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "codex",
        .{
            .project_id = project_id,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .control_plane = &control_plane,
            .actor_type = "agent",
            .actor_id = "codex",
            .is_admin = true,
        },
    );
    defer session.deinit();

    try std.testing.expect(session.workspace_mount_fs_auth_tokens.get(remote_node_id) != null);
    try std.testing.expect(session.workspace_mount_fs_urls.get(remote_node_id) != null);

    var router = (try session.boundVenomRouterForNode(&control_plane, "fs", remote_node_id, "shared", .client_visible)) orelse return error.TestExpectedResponse;
    defer router.deinit();
    const status_json = try router.statusJson(false);
    defer allocator.free(status_json);
    try std.testing.expect(std.mem.indexOf(u8, status_json, "\"url\":\"ws://127.0.0.1:28893/fs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_json, "\"export\":\"shared\"") != null);
}

test "acheron_session: mounted workspace proxy routers prefer routed Spiderweb node urls" {
    const allocator = std.testing.allocator;

    var control_plane = control_plane_mod.ControlPlane.init(allocator);
    defer control_plane.deinit();

    const remote_joined = try control_plane.ensureNode("workspace-remote", "ws://127.0.0.1:28893/fs", 60_000);
    defer allocator.free(remote_joined);
    var remote_parsed = try std.json.parseFromSlice(std.json.Value, allocator, remote_joined, .{});
    defer remote_parsed.deinit();
    const remote_node_id = remote_parsed.value.object.get("node_id").?.string;

    const project_up = try control_plane.projectUp(
        "codex",
        try std.fmt.allocPrint(
            allocator,
            "{{\"name\":\"RoutedWorkspaceProxy\",\"vision\":\"Mounted workspace proxy routers should stay on Spiderweb's routed authority\",\"desired_mounts\":[{{\"mount_path\":\"/shared_data\",\"node_id\":\"{s}\",\"export_name\":\"shared\"}}]}}",
            .{remote_node_id},
        ),
    );
    defer allocator.free(project_up);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_up, .{});
    defer parsed_project.deinit();
    const project_id = parsed_project.value.object.get("project_id").?.string;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "codex",
        .{
            .project_id = project_id,
            .namespace_mount_url = "ws://127.0.0.1:18790/",
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .control_plane = &control_plane,
            .actor_type = "agent",
            .actor_id = "codex",
            .is_admin = true,
        },
    );
    defer session.deinit();

    try std.testing.expect(session.workspace_mount_fs_auth_tokens.get(remote_node_id) != null);
    try std.testing.expect(session.workspace_mount_fs_urls.get(remote_node_id) != null);

    var router = (try session.boundVenomRouterForNode(&control_plane, "fs", remote_node_id, "shared", .client_visible)) orelse return error.TestExpectedResponse;
    defer router.deinit();
    const status_json = try router.statusJson(false);
    defer allocator.free(status_json);
    try std.testing.expect(std.mem.indexOf(u8, status_json, "\"url\":\"ws://127.0.0.1:18790/fs/node/") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_json, "\"export\":\"shared\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_json, "\"has_auth\":true") != null);
}

test "acheron_session: server-internal mounted export routers prefer direct node fs urls" {
    const allocator = std.testing.allocator;

    var control_plane = control_plane_mod.ControlPlane.init(allocator);
    defer control_plane.deinit();

    const remote_joined = try control_plane.ensureNode("workspace-remote", "ws://127.0.0.1:28893/fs", 60_000);
    defer allocator.free(remote_joined);
    var remote_parsed = try std.json.parseFromSlice(std.json.Value, allocator, remote_joined, .{});
    defer remote_parsed.deinit();
    const remote_node_id = remote_parsed.value.object.get("node_id").?.string;

    const project_up = try control_plane.projectUp(
        "codex",
        try std.fmt.allocPrint(
            allocator,
            "{{\"name\":\"InternalWorkspaceProxy\",\"vision\":\"Server-internal mounted export refreshes should talk directly to mounted node endpoints\",\"desired_mounts\":[{{\"mount_path\":\"/shared_data\",\"node_id\":\"{s}\",\"export_name\":\"shared\"}}]}}",
            .{remote_node_id},
        ),
    );
    defer allocator.free(project_up);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_up, .{});
    defer parsed_project.deinit();
    const project_id = parsed_project.value.object.get("project_id").?.string;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "codex",
        .{
            .project_id = project_id,
            .namespace_mount_url = "ws://127.0.0.1:18790/",
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .control_plane = &control_plane,
            .actor_type = "agent",
            .actor_id = "codex",
            .is_admin = true,
        },
    );
    defer session.deinit();

    var router = (try session.boundVenomRouterForNode(&control_plane, "fs", remote_node_id, "shared", .server_internal)) orelse return error.TestExpectedResponse;
    defer router.deinit();
    const status_json = try router.statusJson(false);
    defer allocator.free(status_json);
    try std.testing.expect(std.mem.indexOf(u8, status_json, "\"url\":\"ws://127.0.0.1:28893/fs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_json, "\"export\":\"shared\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_json, "\"has_auth\":true") != null);
}

test "acheron_session: workspace mount aliases still apply when the namespace path already exists" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    var control_plane = control_plane_mod.ControlPlane.init(allocator);
    defer control_plane.deinit();

    const remote_joined = try control_plane.ensureNode("workspace-remote", "ws://127.0.0.1:28894/fs", 60_000);
    defer allocator.free(remote_joined);
    var remote_parsed = try std.json.parseFromSlice(std.json.Value, allocator, remote_joined, .{});
    defer remote_parsed.deinit();
    const remote_node_id = remote_parsed.value.object.get("node_id").?.string;

    const project_json = try control_plane.createProject(
        "{\"name\":\"WorkspaceAliasCollision\",\"vision\":\"Workspace aliases should override existing namespace paths\"}",
    );
    defer allocator.free(project_json);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer parsed_project.deinit();
    const project_id = parsed_project.value.object.get("project_id").?.string;
    const project_token = parsed_project.value.object.get("project_token").?.string;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "codex",
        .{
            .project_id = project_id,
            .project_token = project_token,
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .control_plane = &control_plane,
            .actor_type = "agent",
            .actor_id = "codex",
        },
    );
    defer session.deinit();

    const nodes_root = session.lookupChild(session.root_id, "nodes") orelse return error.MissingNode;
    const local_dir = if (session.lookupChild(nodes_root, "local")) |existing|
        existing
    else
        try session.addDir(nodes_root, "local", false);
    if (session.lookupChild(local_dir, "fs") == null) {
        _ = try session.addDir(local_dir, "fs", false);
    }

    const workspace_status_json = try std.fmt.allocPrint(
        allocator,
        "{{\"mounts\":[{{\"mount_path\":\"/nodes/local/fs\",\"node_id\":\"{s}\",\"export_name\":\"workspace\"}}]}}",
        .{remote_node_id},
    );
    defer allocator.free(workspace_status_json);

    try session.appendWorkspaceMountAliasesFromWorkspaceStatus(workspace_status_json);

    var found_workspace_mount = false;
    for (session.project_binds.items) |bind| {
        if (bind.kind != .workspace_mount) continue;
        if (!std.mem.eql(u8, bind.bind_path, "/nodes/local/fs")) continue;
        found_workspace_mount = true;
        const expected_target = try std.fmt.allocPrint(allocator, "/nodes/{s}/workspace", .{remote_node_id});
        defer allocator.free(expected_target);
        try std.testing.expectEqualStrings(expected_target, bind.target_path);
    }
    try std.testing.expect(found_workspace_mount);
}

test "acheron_session: bound venom proxy refresh ignores dot entries" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    var control_plane = control_plane_mod.ControlPlane.init(allocator);
    defer control_plane.deinit();

    const project_json = try control_plane.createProject(
        "{\"name\":\"BoundProxyDotEntries\",\"vision\":\"Ignore protocol dot entries when materializing routed listings\"}",
    );
    defer allocator.free(project_json);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer parsed_project.deinit();
    const project_id = parsed_project.value.object.get("project_id").?.string;
    const project_token = parsed_project.value.object.get("project_token").?.string;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "codex",
        .{
            .project_id = project_id,
            .project_token = project_token,
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .control_plane = &control_plane,
            .actor_type = "agent",
            .actor_id = "codex",
        },
    );
    defer session.deinit();

    const parent_id = try session.addDir(session.root_id, "proxy-test", false);
    _ = try session.addFile(parent_id, "stale.txt", "", false, .none);

    var seen_names = std.ArrayListUnmanaged([]u8){};
    defer {
        for (seen_names.items) |name| allocator.free(name);
        seen_names.deinit(allocator);
    }

    const listing_json =
        "{\"ents\":[{\"name\":\".\",\"attr\":{\"k\":2,\"m\":16877}},{\"name\":\"..\",\"attr\":{\"k\":2,\"m\":16877}},{\"name\":\"world_seed.json\",\"attr\":{\"k\":1,\"m\":33188}}],\"next_cookie\":0}";

    const next_cookie = try session.applyBoundVenomProxyListing(parent_id, listing_json, &seen_names);
    try std.testing.expectEqual(@as(u64, 0), next_cookie);
    try session.pruneBoundVenomProxyChildren(parent_id, seen_names.items);

    try std.testing.expect(session.lookupChild(parent_id, ".") == null);
    try std.testing.expect(session.lookupChild(parent_id, "..") == null);
    try std.testing.expect(session.lookupChild(parent_id, "stale.txt") == null);
    try std.testing.expect(session.lookupChild(parent_id, "world_seed.json") != null);

    const parent = session.nodes.get(parent_id) orelse return error.MissingNode;
    try std.testing.expectEqual(@as(usize, 1), parent.children.count());
}

test "acheron_session: bound venom proxy readdir eof suppresses repeated next_cookie" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"ents\":[],\"next_cookie\":5,\"eof\":true}",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 0), Session.parseReaddirNextCookie(parsed.value.object));
}

test "acheron_session: mount graph snapshots resolve projected workspace mount roots directly" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    var control_plane = control_plane_mod.ControlPlane.init(allocator);
    defer control_plane.deinit();

    const remote_joined = try control_plane.ensureNode("edge-remote", "ws://127.0.0.1:28891/fs", 60_000);
    defer allocator.free(remote_joined);
    var remote_parsed = try std.json.parseFromSlice(std.json.Value, allocator, remote_joined, .{});
    defer remote_parsed.deinit();
    const remote_node_id = remote_parsed.value.object.get("node_id").?.string;

    const project_up = try control_plane.projectUp(
        "codex",
        try std.fmt.allocPrint(
            allocator,
            "{{\"name\":\"MountGraphProjectedRoot\",\"vision\":\"Projected workspace mounts stay directly addressable\",\"desired_mounts\":[{{\"mount_path\":\"/shared_data\",\"node_id\":\"{s}\",\"export_name\":\"shared\"}}]}}",
            .{remote_node_id},
        ),
    );
    defer allocator.free(project_up);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_up, .{});
    defer parsed_project.deinit();
    const project_id = parsed_project.value.object.get("project_id").?.string;
    const project_token = parsed_project.value.object.get("project_token").?.string;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "codex",
        .{
            .project_id = project_id,
            .project_token = project_token,
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .control_plane = &control_plane,
            .actor_type = "agent",
            .actor_id = "codex",
        },
    );
    defer session.deinit();

    const remote_export_path = try std.fmt.allocPrint(allocator, "/nodes/{s}/shared", .{remote_node_id});
    defer allocator.free(remote_export_path);
    const remote_export_dir = session.resolveAbsolutePathNoBinds(remote_export_path) orelse return error.MissingNode;
    _ = try session.addFile(remote_export_dir, "world_seed.json", "{\"world\":\"ok\"}\n", false, .none);

    const workspace_req = try std.fmt.allocPrint(allocator, "{{\"project_id\":\"{s}\"}}", .{project_id});
    defer allocator.free(workspace_req);
    const workspace_json = try control_plane.workspaceStatusWithRole("codex", workspace_req, true);
    defer allocator.free(workspace_json);

    const snapshot_json = try session.buildMountGraphSnapshotPayloadForPath(
        workspace_json,
        "mount-test",
        "/shared_data",
        2,
    );
    defer allocator.free(snapshot_json);

    var parsed_snapshot = try std.json.parseFromSlice(std.json.Value, allocator, snapshot_json, .{});
    defer parsed_snapshot.deinit();
    const nodes_value = parsed_snapshot.value.object.get("nodes") orelse return error.MissingNode;
    try std.testing.expect(nodes_value == .array);

    var found_shared_root = false;
    var found_world_seed = false;
    for (nodes_value.array.items) |node_value| {
        if (node_value != .object) continue;
        const path_value = node_value.object.get("path") orelse continue;
        if (path_value != .string) continue;

        if (std.mem.eql(u8, path_value.string, "/shared_data")) {
            found_shared_root = true;
            try std.testing.expectEqualStrings("export_root", node_value.object.get("kind").?.string);
        } else if (std.mem.eql(u8, path_value.string, "/shared_data/world_seed.json")) {
            found_world_seed = true;
        }
    }

    try std.testing.expect(found_shared_root);
    try std.testing.expect(found_world_seed);
}

test "acheron_session: mount graph export roots preserve source writability" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "codex",
        .{
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .actor_type = "agent",
            .actor_id = "codex",
        },
    );
    defer session.deinit();

    const snapshot_json = try session.buildMountGraphSnapshotPayloadForPath(
        "{\"mounts\":[{\"mount_path\":\"/nodes/local/fs\",\"node_id\":\"node-2\",\"export_name\":\"workspace\",\"fs_url\":\"ws://127.0.0.1:1/fs/node/node-2\"},{\"mount_path\":\"/shared_data\",\"node_id\":\"node-3\",\"export_name\":\"shared\",\"fs_url\":\"ws://127.0.0.1:1/fs/node/node-3\"}]}",
        "mount-test",
        "/",
        2,
    );
    defer allocator.free(snapshot_json);

    var parsed_snapshot = try std.json.parseFromSlice(std.json.Value, allocator, snapshot_json, .{});
    defer parsed_snapshot.deinit();
    const nodes_value = parsed_snapshot.value.object.get("nodes") orelse return error.MissingNode;
    try std.testing.expect(nodes_value == .array);

    var found_local_root = false;
    var found_shared_root = false;
    for (nodes_value.array.items) |node_value| {
        if (node_value != .object) continue;
        const path_value = node_value.object.get("path") orelse continue;
        if (path_value != .string) continue;

        if (std.mem.eql(u8, path_value.string, "/nodes/local/fs")) {
            found_local_root = true;
            try std.testing.expectEqualStrings("export_root", node_value.object.get("kind").?.string);
            try std.testing.expect(node_value.object.get("writable").?.bool);
            try std.testing.expectEqual(@as(i64, 0o040755), node_value.object.get("mode").?.integer);
        } else if (std.mem.eql(u8, path_value.string, "/shared_data")) {
            found_shared_root = true;
            try std.testing.expectEqualStrings("export_root", node_value.object.get("kind").?.string);
            try std.testing.expect(!node_value.object.get("writable").?.bool);
            try std.testing.expectEqual(@as(i64, 0o040555), node_value.object.get("mode").?.integer);
        }
    }

    try std.testing.expect(found_local_root);
    try std.testing.expect(found_shared_root);
}

test "acheron_session: mount graph snapshots honor workspace bind overrides for local fs" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "exports/local-only.txt",
        .data = "local\n",
    });

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    var control_plane = control_plane_mod.ControlPlane.init(allocator);
    defer control_plane.deinit();

    const remote_joined = try control_plane.ensureNode("workspace-remote", "ws://127.0.0.1:28893/fs", 60_000);
    defer allocator.free(remote_joined);
    var remote_parsed = try std.json.parseFromSlice(std.json.Value, allocator, remote_joined, .{});
    defer remote_parsed.deinit();
    const remote_node_id = remote_parsed.value.object.get("node_id").?.string;

    const project_up = try control_plane.projectUp(
        "codex",
        try std.fmt.allocPrint(
            allocator,
            "{{\"name\":\"MountGraphLocalFsOverride\",\"vision\":\"Mount graph should snapshot the workspace bind instead of the host local fs\",\"desired_mounts\":[{{\"mount_path\":\"/nodes/local/fs\",\"node_id\":\"{s}\",\"export_name\":\"workspace\"}}]}}",
            .{remote_node_id},
        ),
    );
    defer allocator.free(project_up);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_up, .{});
    defer parsed_project.deinit();
    const project_id = parsed_project.value.object.get("project_id").?.string;
    const project_token = parsed_project.value.object.get("project_token").?.string;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "codex",
        .{
            .project_id = project_id,
            .project_token = project_token,
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .control_plane = &control_plane,
            .actor_type = "agent",
            .actor_id = "codex",
        },
    );
    defer session.deinit();

    const remote_export_path = try std.fmt.allocPrint(allocator, "/nodes/{s}/workspace", .{remote_node_id});
    defer allocator.free(remote_export_path);
    const remote_export_dir = session.resolveAbsolutePathNoBinds(remote_export_path) orelse return error.MissingNode;
    _ = try session.addFile(remote_export_dir, "remote.txt", "remote\n", false, .none);

    const workspace_req = try std.fmt.allocPrint(allocator, "{{\"project_id\":\"{s}\"}}", .{project_id});
    defer allocator.free(workspace_req);
    const workspace_json = try control_plane.workspaceStatusWithRole("codex", workspace_req, true);
    defer allocator.free(workspace_json);

    const snapshot_json = try session.buildMountGraphSnapshotPayloadForPath(
        workspace_json,
        "mount-test",
        "/nodes/local/fs",
        2,
    );
    defer allocator.free(snapshot_json);

    var parsed_snapshot = try std.json.parseFromSlice(std.json.Value, allocator, snapshot_json, .{});
    defer parsed_snapshot.deinit();
    const nodes_value = parsed_snapshot.value.object.get("nodes") orelse return error.MissingNode;
    try std.testing.expect(nodes_value == .array);

    var found_remote_file = false;
    var found_shadowed_local = false;
    var found_managed_root = false;
    var found_managed_protocol = false;
    for (nodes_value.array.items) |node_value| {
        if (node_value != .object) continue;
        const path_value = node_value.object.get("path") orelse continue;
        if (path_value != .string) continue;

        if (std.mem.eql(u8, path_value.string, "/nodes/local/fs/remote.txt")) {
            found_remote_file = true;
        } else if (std.mem.eql(u8, path_value.string, "/nodes/local/fs/local-only.txt")) {
            found_shadowed_local = true;
        } else if (std.mem.eql(u8, path_value.string, "/nodes/local/fs/.spiderweb")) {
            found_managed_root = true;
        } else if (std.mem.eql(u8, path_value.string, "/nodes/local/fs/.spiderweb/protocol.json")) {
            found_managed_protocol = true;
        }
    }

    try std.testing.expect(found_remote_file);
    try std.testing.expect(!found_shadowed_local);
    try std.testing.expect(found_managed_root);
    try std.testing.expect(found_managed_protocol);
}

test "acheron_session: projected workspace .spiderweb snapshot keeps protocol file under workspace mount override" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    var control_plane = control_plane_mod.ControlPlane.init(allocator);
    defer control_plane.deinit();

    const remote_joined = try control_plane.ensureNode("workspace-remote", "ws://127.0.0.1:28893/fs", 60_000);
    defer allocator.free(remote_joined);
    var remote_parsed = try std.json.parseFromSlice(std.json.Value, allocator, remote_joined, .{});
    defer remote_parsed.deinit();
    const remote_node_id = remote_parsed.value.object.get("node_id").?.string;

    const project_up = try control_plane.projectUp(
        "codex",
        try std.fmt.allocPrint(
            allocator,
            "{{\"name\":\"MountGraphProjectedManagedRoot\",\"vision\":\"Projected Spiderweb bootstrap stays visible under workspace mounts\",\"desired_mounts\":[{{\"mount_path\":\"/nodes/local/fs\",\"node_id\":\"{s}\",\"export_name\":\"workspace\"}}]}}",
            .{remote_node_id},
        ),
    );
    defer allocator.free(project_up);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_up, .{});
    defer parsed_project.deinit();
    const project_id = parsed_project.value.object.get("project_id").?.string;
    const project_token = parsed_project.value.object.get("project_token").?.string;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "codex",
        .{
            .project_id = project_id,
            .project_token = project_token,
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .control_plane = &control_plane,
            .actor_type = "agent",
            .actor_id = "codex",
        },
    );
    defer session.deinit();

    const workspace_req = try std.fmt.allocPrint(allocator, "{{\"project_id\":\"{s}\"}}", .{project_id});
    defer allocator.free(workspace_req);
    const workspace_json = try control_plane.workspaceStatusWithRole("codex", workspace_req, true);
    defer allocator.free(workspace_json);

    const snapshot_json = try session.buildMountGraphSnapshotPayloadForPath(
        workspace_json,
        "mount-test",
        "/nodes/local/fs/.spiderweb",
        1,
    );
    defer allocator.free(snapshot_json);

    var parsed_snapshot = try std.json.parseFromSlice(std.json.Value, allocator, snapshot_json, .{});
    defer parsed_snapshot.deinit();
    const nodes_value = parsed_snapshot.value.object.get("nodes") orelse return error.MissingNode;
    try std.testing.expect(nodes_value == .array);

    var found_protocol = false;
    for (nodes_value.array.items) |node_value| {
        if (node_value != .object) continue;
        const path_value = node_value.object.get("path") orelse continue;
        if (path_value != .string) continue;
        if (std.mem.eql(u8, path_value.string, "/nodes/local/fs/.spiderweb/protocol.json")) {
            found_protocol = true;
            break;
        }
    }

    try std.testing.expect(found_protocol);
}

test "acheron_session: projected managed .spiderweb survives broader workspace mount rebound" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    var control_plane = control_plane_mod.ControlPlane.init(allocator);
    defer control_plane.deinit();

    const remote_joined = try control_plane.ensureNode("workspace-remote", "ws://127.0.0.1:28893/fs", 60_000);
    defer allocator.free(remote_joined);
    var remote_parsed = try std.json.parseFromSlice(std.json.Value, allocator, remote_joined, .{});
    defer remote_parsed.deinit();
    const remote_node_id = remote_parsed.value.object.get("node_id").?.string;

    const project_up = try control_plane.projectUp(
        "codex",
        try std.fmt.allocPrint(
            allocator,
            "{{\"name\":\"MountGraphProjectedManagedFallback\",\"vision\":\"Managed Spiderweb subtree should win when the rebound export lacks it\",\"desired_mounts\":[{{\"mount_path\":\"/nodes/local/fs\",\"node_id\":\"{s}\",\"export_name\":\"workspace\"}}]}}",
            .{remote_node_id},
        ),
    );
    defer allocator.free(project_up);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_up, .{});
    defer parsed_project.deinit();
    const project_id = parsed_project.value.object.get("project_id").?.string;
    const project_token = parsed_project.value.object.get("project_token").?.string;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "codex",
        .{
            .project_id = project_id,
            .project_token = project_token,
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .control_plane = &control_plane,
            .actor_type = "user",
            .actor_id = "access",
            .is_admin = true,
        },
    );
    defer session.deinit();

    const workspace_req = try std.fmt.allocPrint(allocator, "{{\"project_id\":\"{s}\"}}", .{project_id});
    defer allocator.free(workspace_req);
    const workspace_json = try control_plane.workspaceStatusWithRole("codex", workspace_req, true);
    defer allocator.free(workspace_json);

    const rebound_path = try std.fmt.allocPrint(allocator, "/nodes/{s}/workspace/.spiderweb", .{remote_node_id});
    defer allocator.free(rebound_path);
    try std.testing.expectError(
        error.FileNotFound,
        session.buildMountGraphSnapshotPayloadForPath(
            workspace_json,
            "mount-test",
            rebound_path,
            1,
        ),
    );

    const projected_snapshot = try session.buildMountGraphSnapshotPayloadForPath(
        workspace_json,
        "mount-test",
        "/nodes/local/fs/.spiderweb",
        1,
    );
    defer allocator.free(projected_snapshot);

    try std.testing.expect(std.mem.indexOf(u8, projected_snapshot, "\"/nodes/local/fs/.spiderweb/protocol.json\"") != null);

    const projected_file_snapshot = try session.buildMountGraphSnapshotPayloadForPath(
        workspace_json,
        "mount-test",
        "/nodes/local/fs/.spiderweb/protocol.json",
        1,
    );
    defer allocator.free(projected_file_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, projected_file_snapshot, "\"/nodes/local/fs/.spiderweb/protocol.json\"") != null);
}

test "acheron_session: projected managed services keep bind-only children under workspace mounts" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    var control_plane = control_plane_mod.ControlPlane.init(allocator);
    defer control_plane.deinit();

    const remote_joined = try control_plane.ensureNode("workspace-remote", "ws://127.0.0.1:28893/fs", 60_000);
    defer allocator.free(remote_joined);
    var remote_parsed = try std.json.parseFromSlice(std.json.Value, allocator, remote_joined, .{});
    defer remote_parsed.deinit();
    const remote_node_id = remote_parsed.value.object.get("node_id").?.string;

    const project_up = try control_plane.projectUp(
        "codex",
        try std.fmt.allocPrint(
            allocator,
            "{{\"name\":\"MountGraphProjectedManagedServices\",\"vision\":\"Projected managed service mirrors keep bind-only children\",\"desired_mounts\":[{{\"mount_path\":\"/nodes/local/fs\",\"node_id\":\"{s}\",\"export_name\":\"workspace\"}}]}}",
            .{remote_node_id},
        ),
    );
    defer allocator.free(project_up);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_up, .{});
    defer parsed_project.deinit();
    const project_id = parsed_project.value.object.get("project_id").?.string;
    const project_token = parsed_project.value.object.get("project_token").?.string;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "codex",
        .{
            .project_id = project_id,
            .project_token = project_token,
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .control_plane = &control_plane,
            .actor_type = "agent",
            .actor_id = "codex",
        },
    );
    defer session.deinit();

    const workspace_req = try std.fmt.allocPrint(allocator, "{{\"project_id\":\"{s}\"}}", .{project_id});
    defer allocator.free(workspace_req);
    const workspace_json = try control_plane.workspaceStatusWithRole("codex", workspace_req, true);
    defer allocator.free(workspace_json);

    const snapshot_json = try session.buildMountGraphSnapshotPayloadForPath(
        workspace_json,
        "mount-test",
        "/nodes/local/fs/.spiderweb/services",
        2,
    );
    defer allocator.free(snapshot_json);

    try std.testing.expect(std.mem.indexOf(u8, snapshot_json, "\"/nodes/local/fs/.spiderweb/services/home\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot_json, "\"/nodes/local/fs/.spiderweb/services/mounts\"") != null);
}

test "acheron_session: workspace mount proxy roots preserve mounted export names" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    var control_plane = control_plane_mod.ControlPlane.init(allocator);
    defer control_plane.deinit();

    const remote_joined = try control_plane.ensureNode("edge-remote", "ws://127.0.0.1:28891/fs", 60_000);
    defer allocator.free(remote_joined);
    var remote_parsed = try std.json.parseFromSlice(std.json.Value, allocator, remote_joined, .{});
    defer remote_parsed.deinit();
    const remote_node_id = remote_parsed.value.object.get("node_id").?.string;

    const project_up = try control_plane.projectUp(
        "codex",
        try std.fmt.allocPrint(
            allocator,
            "{{\"name\":\"MountProxyProject\",\"vision\":\"Mounted exports keep their export names\",\"desired_mounts\":[{{\"mount_path\":\"/shared_data\",\"node_id\":\"{s}\",\"export_name\":\"shared\"}}]}}",
            .{remote_node_id},
        ),
    );
    defer allocator.free(project_up);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_up, .{});
    defer parsed_project.deinit();
    const project_id = parsed_project.value.object.get("project_id").?.string;
    const project_token = parsed_project.value.object.get("project_token").?.string;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "codex",
        .{
            .project_id = project_id,
            .project_token = project_token,
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .control_plane = &control_plane,
            .actor_type = "agent",
            .actor_id = "codex",
        },
    );
    defer session.deinit();

    const shared_proxy_path = try std.fmt.allocPrint(allocator, "/nodes/{s}/shared/world_seed.json", .{remote_node_id});
    defer allocator.free(shared_proxy_path);
    const shared_proxy = (try session.boundVenomProxyPathForAbsolutePath(shared_proxy_path)) orelse return error.MissingNode;
    defer allocator.free(shared_proxy.remote_path);
    try std.testing.expectEqualStrings("fs", shared_proxy.venom_id);
    try std.testing.expectEqualStrings(remote_node_id, shared_proxy.provider_node_id.?);
    try std.testing.expectEqualStrings("shared", shared_proxy.provider_export_name.?);
    try std.testing.expectEqualStrings("/world_seed.json", shared_proxy.remote_path);

    const generic_fs_proxy_path = try std.fmt.allocPrint(allocator, "/nodes/{s}/fs/world_seed.json", .{remote_node_id});
    defer allocator.free(generic_fs_proxy_path);
    const generic_fs_proxy = (try session.boundVenomProxyPathForAbsolutePath(generic_fs_proxy_path)) orelse return error.MissingNode;
    defer allocator.free(generic_fs_proxy.remote_path);
    try std.testing.expectEqualStrings(remote_node_id, generic_fs_proxy.provider_node_id.?);
    try std.testing.expect(generic_fs_proxy.provider_export_name == null);
    try std.testing.expectEqualStrings("/world_seed.json", generic_fs_proxy.remote_path);
}

test "acheron_session: workspace AGENTS contract strips repeated heading noise" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "exports/AGENTS.md",
        .data =
            \\# Spiderweb Workspace Agent Contract
            \\
            \\# Spiderweb Workspace Agent Contract
            \\
            \\# Spiderweb Workspace Agent Contract
            \\
            \\<!-- SPIDERWEB:BEGIN MANAGED -->
            \\stale managed block
            \\<!-- SPIDERWEB:END MANAGED -->
            \\
            \\## Workspace Owner Notes
            \\
            \\Keep custom lint rules in mind.
            \\
        ,
    });

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    var control_plane = control_plane_mod.ControlPlane.init(allocator);
    defer control_plane.deinit();

    const project_json = try control_plane.createProject(
        "{\"name\":\"AgentsHeadingNoise\",\"vision\":\"Keep generated headers singular\"}",
    );
    defer allocator.free(project_json);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer parsed_project.deinit();
    const project_id = parsed_project.value.object.get("project_id").?.string;
    const project_token = parsed_project.value.object.get("project_token").?.string;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "codex",
        .{
            .project_id = project_id,
            .project_token = project_token,
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .control_plane = &control_plane,
            .actor_type = "agent",
            .actor_id = "codex",
        },
    );
    defer session.deinit();

    const namespace_agents = try session.tryReadInternalPath("/AGENTS.md");
    defer if (namespace_agents) |value| allocator.free(value);
    try std.testing.expect(namespace_agents != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, namespace_agents.?, workspace_agents_heading));
    try std.testing.expect(std.mem.indexOf(u8, namespace_agents.?, "Keep custom lint rules in mind.") != null);
    try std.testing.expect(std.mem.indexOf(u8, namespace_agents.?, "Keep generated headers singular") != null);
}

test "acheron_session: mount graph snapshot keeps synthetic file contents remote by default" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "exports/AGENTS.md",
        .data = "## Workspace Owner Notes\n\nKeep custom lint rules in mind.\n",
    });

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    var control_plane = control_plane_mod.ControlPlane.init(allocator);
    defer control_plane.deinit();

    const project_json = try control_plane.createProject(
        "{\"name\":\"MountGraphContentMode\",\"vision\":\"Keep mount attach structural and fast\"}",
    );
    defer allocator.free(project_json);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer parsed_project.deinit();
    const project_id = parsed_project.value.object.get("project_id").?.string;
    const project_token = parsed_project.value.object.get("project_token").?.string;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "codex",
        .{
            .project_id = project_id,
            .project_token = project_token,
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .control_plane = &control_plane,
            .actor_type = "agent",
            .actor_id = "codex",
        },
    );
    defer session.deinit();

    const snapshot_json = try session.buildMountGraphSnapshotPayload("{\"mounts\":[]}", "mount-test");
    defer allocator.free(snapshot_json);

    var parsed_snapshot = try std.json.parseFromSlice(std.json.Value, allocator, snapshot_json, .{});
    defer parsed_snapshot.deinit();
    const nodes_value = parsed_snapshot.value.object.get("nodes") orelse return error.MissingNode;
    try std.testing.expect(nodes_value == .array);

    var found_agents = false;
    var found_protocol = false;
    for (nodes_value.array.items) |node_value| {
        if (node_value != .object) continue;
        const path_value = node_value.object.get("path") orelse continue;
        if (path_value != .string) continue;
        if (!std.mem.eql(u8, path_value.string, "/AGENTS.md") and !std.mem.eql(u8, path_value.string, "/meta/protocol.json")) {
            continue;
        }

        const content_mode = node_value.object.get("content_mode") orelse return error.InvalidPayload;
        try std.testing.expect(content_mode == .string);
        try std.testing.expectEqualStrings("remote_read", content_mode.string);

        const inline_content = node_value.object.get("inline_content_b64") orelse return error.InvalidPayload;
        try std.testing.expect(inline_content == .null);

        if (std.mem.eql(u8, path_value.string, "/AGENTS.md")) {
            found_agents = true;
        } else if (std.mem.eql(u8, path_value.string, "/meta/protocol.json")) {
            found_protocol = true;
        }
    }

    try std.testing.expect(found_agents);
    try std.testing.expect(found_protocol);
}

test "acheron_session: mount graph snapshot preserves alias directory and file kinds" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "exports/AGENTS.md",
        .data = "## Workspace Owner Notes\n\nKeep alias kinds honest.\n",
    });

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    var control_plane = control_plane_mod.ControlPlane.init(allocator);
    defer control_plane.deinit();

    const project_json = try control_plane.createProject(
        "{\"name\":\"MountGraphAliasKinds\",\"vision\":\"Keep alias nodes traversable\"}",
    );
    defer allocator.free(project_json);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer parsed_project.deinit();
    const project_id = parsed_project.value.object.get("project_id").?.string;
    const project_token = parsed_project.value.object.get("project_token").?.string;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "codex",
        .{
            .project_id = project_id,
            .project_token = project_token,
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .control_plane = &control_plane,
            .actor_type = "agent",
            .actor_id = "codex",
        },
    );
    defer session.deinit();

    const snapshot_json = try session.buildMountGraphSnapshotPayload("{\"mounts\":[]}", "mount-test");
    defer allocator.free(snapshot_json);

    var parsed_snapshot = try std.json.parseFromSlice(std.json.Value, allocator, snapshot_json, .{});
    defer parsed_snapshot.deinit();
    const nodes_value = parsed_snapshot.value.object.get("nodes") orelse return error.MissingNode;
    try std.testing.expect(nodes_value == .array);

    var found_agents_alias = false;
    var found_mounts_alias = false;
    for (nodes_value.array.items) |node_value| {
        if (node_value != .object) continue;
        const path_value = node_value.object.get("path") orelse continue;
        if (path_value != .string) continue;

        if (std.mem.eql(u8, path_value.string, "/AGENTS.md")) {
            try std.testing.expectEqualStrings("synthetic_file", node_value.object.get("kind").?.string);
            try std.testing.expect(node_value.object.get("canonical_node_id").? != .null);
            found_agents_alias = true;
        } else if (std.mem.eql(u8, path_value.string, "/global/mounts")) {
            try std.testing.expectEqualStrings("synthetic_directory", node_value.object.get("kind").?.string);
            try std.testing.expect(node_value.object.get("canonical_node_id").? != .null);
            found_mounts_alias = true;
        }
    }

    try std.testing.expect(found_agents_alias);
    try std.testing.expect(found_mounts_alias);
}

test "acheron_session: mount graph snapshot projects managed .spiderweb children alongside local entries" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports/.spiderweb/agents/codex/home");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "exports/AGENTS.md",
        .data = "## Workspace Owner Notes\n\nKeep project-local bootstrap stable.\n",
    });

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    var control_plane = control_plane_mod.ControlPlane.init(allocator);
    defer control_plane.deinit();

    const project_json = try control_plane.createProject(
        "{\"name\":\"MountGraphManagedEntrypoint\",\"vision\":\"Keep project-local managed bootstrap visible\"}",
    );
    defer allocator.free(project_json);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer parsed_project.deinit();
    const project_id = parsed_project.value.object.get("project_id").?.string;
    const project_token = parsed_project.value.object.get("project_token").?.string;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "codex",
        .{
            .project_id = project_id,
            .project_token = project_token,
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .control_plane = &control_plane,
            .actor_type = "agent",
            .actor_id = "codex",
        },
    );
    defer session.deinit();

    const snapshot_json = try session.buildMountGraphSnapshotPayloadForPath(
        "{\"mounts\":[]}",
        "mount-test",
        "/nodes/local/fs/.spiderweb",
        2,
    );
    defer allocator.free(snapshot_json);

    var parsed_snapshot = try std.json.parseFromSlice(std.json.Value, allocator, snapshot_json, .{});
    defer parsed_snapshot.deinit();
    const nodes_value = parsed_snapshot.value.object.get("nodes") orelse return error.MissingNode;
    try std.testing.expect(nodes_value == .array);

    var found_agents_dir = false;
    var found_protocol_file = false;
    var found_services_dir = false;
    for (nodes_value.array.items) |node_value| {
        if (node_value != .object) continue;
        const path_value = node_value.object.get("path") orelse continue;
        if (path_value != .string) continue;

        if (std.mem.eql(u8, path_value.string, "/nodes/local/fs/.spiderweb/agents")) {
            found_agents_dir = true;
        } else if (std.mem.eql(u8, path_value.string, "/nodes/local/fs/.spiderweb/protocol.json")) {
            found_protocol_file = true;
            try std.testing.expectEqualStrings("synthetic_file", node_value.object.get("kind").?.string);
            try std.testing.expect(node_value.object.get("canonical_node_id").? != .null);
        } else if (std.mem.eql(u8, path_value.string, "/nodes/local/fs/.spiderweb/services")) {
            found_services_dir = true;
            try std.testing.expectEqualStrings("synthetic_directory", node_value.object.get("kind").?.string);
            try std.testing.expect(node_value.object.get("canonical_node_id").? != .null);
        }
    }

    try std.testing.expect(found_agents_dir);
    try std.testing.expect(found_protocol_file);
    try std.testing.expect(found_services_dir);
}

test "acheron_session: projected workspace managed files remain readable through mount graph reads" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports/.spiderweb/agents/codex/home");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "exports/AGENTS.md",
        .data = "## Workspace Owner Notes\n\nKeep projected reads stable.\n",
    });

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    var control_plane = control_plane_mod.ControlPlane.init(allocator);
    defer control_plane.deinit();

    const remote_joined = try control_plane.ensureNode("workspace-remote", "ws://127.0.0.1:28893/fs", 60_000);
    defer allocator.free(remote_joined);
    var remote_parsed = try std.json.parseFromSlice(std.json.Value, allocator, remote_joined, .{});
    defer remote_parsed.deinit();
    const remote_node_id = remote_parsed.value.object.get("node_id").?.string;

    const project_up = try control_plane.projectUp(
        "codex",
        try std.fmt.allocPrint(
            allocator,
            "{{\"name\":\"MountGraphReadableManagedFiles\",\"vision\":\"Projected managed files must stay readable under workspace mounts\",\"desired_mounts\":[{{\"mount_path\":\"/nodes/local/fs\",\"node_id\":\"{s}\",\"export_name\":\"workspace\"}},{{\"mount_path\":\"/shared_data\",\"node_id\":\"{s}\",\"export_name\":\"shared\"}}]}}",
            .{ remote_node_id, remote_node_id },
        ),
    );
    defer allocator.free(project_up);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_up, .{});
    defer parsed_project.deinit();
    const project_id = parsed_project.value.object.get("project_id").?.string;
    const project_token = parsed_project.value.object.get("project_token").?.string;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "codex",
        .{
            .project_id = project_id,
            .project_token = project_token,
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .control_plane = &control_plane,
            .actor_type = "agent",
            .actor_id = "codex",
        },
    );
    defer session.deinit();

    const shared_export_path = try std.fmt.allocPrint(allocator, "/nodes/{s}/shared", .{remote_node_id});
    defer allocator.free(shared_export_path);
    const shared_export_dir = session.resolveAbsolutePathNoBinds(shared_export_path) orelse return error.MissingNode;
    _ = try session.addFile(shared_export_dir, "world_seed.json", "{\"world\":\"ok\"}\n", false, .none);

    const workspace_req = try std.fmt.allocPrint(allocator, "{{\"project_id\":\"{s}\"}}", .{project_id});
    defer allocator.free(workspace_req);
    const workspace_json = try control_plane.workspaceStatusWithRole("codex", workspace_req, true);
    defer allocator.free(workspace_json);

    const snapshot_json = try session.buildMountGraphSnapshotPayloadForPath(
        workspace_json,
        "mount-test",
        "/nodes/local/fs/.spiderweb",
        2,
    );
    defer allocator.free(snapshot_json);

    var parsed_snapshot = try std.json.parseFromSlice(std.json.Value, allocator, snapshot_json, .{});
    defer parsed_snapshot.deinit();
    const nodes_value = parsed_snapshot.value.object.get("nodes") orelse return error.MissingNode;
    try std.testing.expect(nodes_value == .array);

    var found_protocol = false;
    var found_world_seed = false;
    for (nodes_value.array.items) |node_value| {
        if (node_value != .object) continue;
        const path_value = node_value.object.get("path") orelse continue;
        if (path_value != .string) continue;

        if (std.mem.eql(u8, path_value.string, "/nodes/local/fs/.spiderweb/protocol.json")) {
            found_protocol = true;
            try std.testing.expect(node_value.object.get("size").?.integer > 0);
            try std.testing.expectEqualStrings("remote_read", node_value.object.get("content_mode").?.string);
        } else if (std.mem.eql(u8, path_value.string, "/nodes/local/fs/.spiderweb/shared_data/world_seed.json")) {
            found_world_seed = true;
            try std.testing.expect(node_value.object.get("size").?.integer > 0);
            try std.testing.expectEqualStrings("remote_read", node_value.object.get("content_mode").?.string);
        }
    }

    try std.testing.expect(found_protocol);
    try std.testing.expect(found_world_seed);

    const expected_protocol = try session.tryReadInternalPath("/nodes/local/fs/.spiderweb/protocol.json");
    defer if (expected_protocol) |value| allocator.free(value);
    try std.testing.expect(expected_protocol != null);

    const expected_world_seed = try session.tryReadInternalPath("/nodes/local/fs/.spiderweb/shared_data/world_seed.json");
    defer if (expected_world_seed) |value| allocator.free(value);
    try std.testing.expect(expected_world_seed != null);

    const protocol_via_mount_read = try session.readMountGraphFile("/nodes/local/fs/.spiderweb/protocol.json", 0, 4096);
    defer allocator.free(protocol_via_mount_read);
    try std.testing.expectEqualStrings(expected_protocol.?, protocol_via_mount_read);

    const world_seed_via_mount_read = try session.readMountGraphFile("/nodes/local/fs/.spiderweb/shared_data/world_seed.json", 0, 4096);
    defer allocator.free(world_seed_via_mount_read);
    try std.testing.expectEqualStrings(expected_world_seed.?, world_seed_via_mount_read);
}

test "acheron_session: projected managed shared_data snapshot preserves proxy attrs" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports/.spiderweb/agents/codex/home");

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    var control_plane = control_plane_mod.ControlPlane.init(allocator);
    defer control_plane.deinit();

    const remote_joined = try control_plane.ensureNode("workspace-remote", "ws://127.0.0.1:28893/fs", 60_000);
    defer allocator.free(remote_joined);
    var remote_parsed = try std.json.parseFromSlice(std.json.Value, allocator, remote_joined, .{});
    defer remote_parsed.deinit();
    const remote_node_id = remote_parsed.value.object.get("node_id").?.string;

    const project_up = try control_plane.projectUp(
        "codex",
        try std.fmt.allocPrint(
            allocator,
            "{{\"name\":\"MountGraphManagedSharedDataProxyAttrs\",\"vision\":\"Projected managed shared_data should keep proxy attrs in the mount graph\",\"desired_mounts\":[{{\"mount_path\":\"/nodes/local/fs\",\"node_id\":\"{s}\",\"export_name\":\"workspace\"}},{{\"mount_path\":\"/shared_data\",\"node_id\":\"{s}\",\"export_name\":\"shared\"}}]}}",
            .{ remote_node_id, remote_node_id },
        ),
    );
    defer allocator.free(project_up);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_up, .{});
    defer parsed_project.deinit();
    const project_id = parsed_project.value.object.get("project_id").?.string;
    const project_token = parsed_project.value.object.get("project_token").?.string;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "codex",
        .{
            .project_id = project_id,
            .project_token = project_token,
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .control_plane = &control_plane,
            .actor_type = "agent",
            .actor_id = "codex",
        },
    );
    defer session.deinit();

    const shared_export_path = try std.fmt.allocPrint(allocator, "/nodes/{s}/shared", .{remote_node_id});
    defer allocator.free(shared_export_path);
    const shared_export_dir = session.resolveAbsolutePathNoBinds(shared_export_path) orelse return error.MissingNode;
    const world_seed_id = try session.addFile(shared_export_dir, "world_seed.json", "", true, .none);
    const world_seed_node = session.nodes.getPtr(world_seed_id) orelse return error.MissingNode;
    world_seed_node.reported_mode = 0o100644;
    world_seed_node.reported_size = 15;

    const workspace_req = try std.fmt.allocPrint(allocator, "{{\"project_id\":\"{s}\"}}", .{project_id});
    defer allocator.free(workspace_req);
    const workspace_json = try control_plane.workspaceStatusWithRole("codex", workspace_req, true);
    defer allocator.free(workspace_json);

    const snapshot_json = try session.buildMountGraphSnapshotPayloadForPath(
        workspace_json,
        "mount-test",
        "/nodes/local/fs/.spiderweb/shared_data",
        1,
    );
    defer allocator.free(snapshot_json);

    var parsed_snapshot = try std.json.parseFromSlice(std.json.Value, allocator, snapshot_json, .{});
    defer parsed_snapshot.deinit();
    const nodes_value = parsed_snapshot.value.object.get("nodes") orelse return error.MissingNode;
    try std.testing.expect(nodes_value == .array);

    var found_world_seed = false;
    for (nodes_value.array.items) |node_value| {
        if (node_value != .object) continue;
        const path_value = node_value.object.get("path") orelse continue;
        if (path_value != .string) continue;
        if (!std.mem.eql(u8, path_value.string, "/nodes/local/fs/.spiderweb/shared_data/world_seed.json")) continue;

        found_world_seed = true;
        try std.testing.expectEqual(@as(i64, 15), node_value.object.get("size").?.integer);
        try std.testing.expectEqualStrings("remote_read", node_value.object.get("content_mode").?.string);
        try std.testing.expect(node_value.object.get("writable").?.bool == false);
        try std.testing.expectEqual(@as(i64, 0o100444), node_value.object.get("mode").?.integer);
    }

    try std.testing.expect(found_world_seed);
}

test "acheron_session: rebound workspace parents can walk projected managed shared_data binds" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports/.spiderweb/agents/codex/home");

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    var control_plane = control_plane_mod.ControlPlane.init(allocator);
    defer control_plane.deinit();

    const remote_joined = try control_plane.ensureNode("workspace-remote", "ws://127.0.0.1:28893/fs", 60_000);
    defer allocator.free(remote_joined);
    var remote_parsed = try std.json.parseFromSlice(std.json.Value, allocator, remote_joined, .{});
    defer remote_parsed.deinit();
    const remote_node_id = remote_parsed.value.object.get("node_id").?.string;

    const project_up = try control_plane.projectUp(
        "codex",
        try std.fmt.allocPrint(
            allocator,
            "{{\"name\":\"MountGraphReboundManagedSharedData\",\"vision\":\"Projected managed shared_data stays walkable from rebound workspace parents\",\"desired_mounts\":[{{\"mount_path\":\"/nodes/local/fs\",\"node_id\":\"{s}\",\"export_name\":\"workspace\"}},{{\"mount_path\":\"/shared_data\",\"node_id\":\"{s}\",\"export_name\":\"shared\"}}]}}",
            .{ remote_node_id, remote_node_id },
        ),
    );
    defer allocator.free(project_up);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_up, .{});
    defer parsed_project.deinit();
    const project_id = parsed_project.value.object.get("project_id").?.string;
    const project_token = parsed_project.value.object.get("project_token").?.string;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "codex",
        .{
            .project_id = project_id,
            .project_token = project_token,
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .control_plane = &control_plane,
            .actor_type = "agent",
            .actor_id = "codex",
        },
    );
    defer session.deinit();

    const shared_export_path = try std.fmt.allocPrint(allocator, "/nodes/{s}/shared", .{remote_node_id});
    defer allocator.free(shared_export_path);
    const shared_export_dir = session.resolveAbsolutePathNoBinds(shared_export_path) orelse return error.MissingNode;
    _ = try session.addFile(shared_export_dir, "world_seed.json", "{\"world\":\"ok\"}\n", false, .none);

    const rebound_managed_dir_path = try std.fmt.allocPrint(allocator, "/nodes/{s}/workspace/.spiderweb", .{remote_node_id});
    defer allocator.free(rebound_managed_dir_path);
    const rebound_managed_dir = session.resolveAbsolutePathNoBinds(rebound_managed_dir_path) orelse return error.MissingNode;

    const shared_data_dir = try session.resolveWalkChild(rebound_managed_dir, "shared_data") orelse return error.MissingNode;
    const world_seed_id = try session.resolveWalkChild(shared_data_dir, "world_seed.json") orelse return error.MissingNode;

    const world_seed_path = try session.nodeAbsolutePath(world_seed_id);
    defer allocator.free(world_seed_path);
    try std.testing.expectEqualStrings("/shared_data/world_seed.json", world_seed_path);
}

test "acheron_session: readMountGraphFile preserves internal file-type errors" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports/child");

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "default",
        .{
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
        },
    );
    defer session.deinit();

    try std.testing.expectError(
        error.IsDir,
        session.readMountGraphFile("/nodes/local/fs/child", 0, 16),
    );
}

test "acheron_session: readMountGraphFile reads beyond the first chunk" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");

    const prefix_len: usize = 1_048_576;
    const total_len = prefix_len + 32;
    var content = try allocator.alloc(u8, total_len);
    defer allocator.free(content);
    @memset(content[0..prefix_len], 'a');
    @memset(content[prefix_len..], 'b');
    try tmp_dir.dir.writeFile(.{
        .sub_path = "exports/big.txt",
        .data = content,
    });

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "default",
        .{
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
        },
    );
    defer session.deinit();

    const tail = try session.readMountGraphFile("/nodes/local/fs/big.txt", prefix_len, 32);
    defer allocator.free(tail);
    try std.testing.expectEqual(@as(usize, 32), tail.len);
    for (tail) |byte| try std.testing.expectEqual(@as(u8, 'b'), byte);
}

test "acheron_session: services terminal exec updates live service status and result" {
    const allocator = std.testing.allocator;

    var control_plane = control_plane_mod.ControlPlane.init(allocator);
    defer control_plane.deinit();

    const project_json = try control_plane.createProject(
        "{\"name\":\"ServiceTerminalExec\",\"vision\":\"ServiceTerminalExec\",\"template_id\":\"dev\"}",
    );
    defer allocator.free(project_json);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer parsed_project.deinit();
    const project_id = parsed_project.value.object.get("project_id").?.string;
    const project_token = parsed_project.value.object.get("project_token").?.string;

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "default",
        .{
            .project_id = project_id,
            .project_token = project_token,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
            .control_plane = &control_plane,
        },
    );
    defer session.deinit();

    try protocolWriteFile(
        &session,
        allocator,
        510,
        511,
        &.{ "services", "terminal", "control", "exec.json" },
        "{\"command\":\"printf terminal-ok\"}",
        1200,
    );

    const terminal_status = try protocolReadFile(
        &session,
        allocator,
        512,
        513,
        &.{ "services", "terminal", "status.json" },
        1205,
    );
    defer allocator.free(terminal_status);
    try std.testing.expect(std.mem.indexOf(u8, terminal_status, "\"state\":\"done\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal_status, "\"tool\":\"shell_exec\"") != null);

    const terminal_result = try protocolReadFile(
        &session,
        allocator,
        514,
        515,
        &.{ "services", "terminal", "result.json" },
        1210,
    );
    defer allocator.free(terminal_result);
    try std.testing.expect(std.mem.indexOf(u8, terminal_result, "\"operation\":\"exec\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal_result, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal_result, "dGVybWluYWwtb2s=") != null);
}

test "acheron_session: missions namespace enforces mission ownership across agents" {
    const allocator = std.testing.allocator;

    var mission_store = try mission_store_mod.MissionStore.initWithPath(allocator, null);
    defer mission_store.deinit();

    const runtime_handle_a = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle_a.destroy();

    const runtime_handle_b = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle_b.destroy();

    var session_a = try Session.initWithOptions(
        allocator,
        runtime_handle_a,
        "agent-a",
        .{
            .mission_store = &mission_store,
            .actor_type = "agent",
            .actor_id = "worker-a",
        },
    );
    defer session_a.deinit();

    var session_b = try Session.initWithOptions(
        allocator,
        runtime_handle_b,
        "agent-b",
        .{
            .mission_store = &mission_store,
            .actor_type = "agent",
            .actor_id = "worker-b",
        },
    );
    defer session_b.deinit();

    try protocolWriteFile(
        &session_a,
        allocator,
        380,
        381,
        &.{ "agents", "self", "missions", "control", "create.json" },
        "{\"use_case\":\"pr_review\",\"title\":\"Review PR 91\"}",
        980,
    );

    const create_result = try protocolReadFile(
        &session_a,
        allocator,
        382,
        383,
        &.{ "agents", "self", "missions", "result.json" },
        981,
    );
    defer allocator.free(create_result);
    const mission_id = try extractMissionIdFromResultPayload(allocator, create_result);
    defer allocator.free(mission_id);

    try protocolWriteFile(
        &session_b,
        allocator,
        384,
        385,
        &.{ "agents", "self", "missions", "control", "list.json" },
        "{}",
        982,
    );

    const list_result = try protocolReadFile(
        &session_b,
        allocator,
        386,
        387,
        &.{ "agents", "self", "missions", "result.json" },
        983,
    );
    defer allocator.free(list_result);
    try std.testing.expect(std.mem.indexOf(u8, list_result, "\"operation\":\"list\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_result, "\"count\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_result, mission_id) == null);

    const get_payload = try std.fmt.allocPrint(allocator, "{{\"mission_id\":\"{s}\"}}", .{mission_id});
    defer allocator.free(get_payload);
    const get_error = try protocolWriteFileExpectError(
        &session_b,
        allocator,
        388,
        389,
        &.{ "agents", "self", "missions", "control", "get.json" },
        get_payload,
        984,
        "forbidden",
    );
    defer allocator.free(get_error);

    const resume_payload = try std.fmt.allocPrint(allocator, "{{\"mission_id\":\"{s}\",\"stage\":\"reviewing\"}}", .{mission_id});
    defer allocator.free(resume_payload);
    const resume_error = try protocolWriteFileExpectError(
        &session_b,
        allocator,
        390,
        391,
        &.{ "agents", "self", "missions", "control", "resume.json" },
        resume_payload,
        985,
        "forbidden",
    );
    defer allocator.free(resume_error);
}

test "acheron_session: pr_review run_validation denied when shell_exec is blocked" {
    const allocator = std.testing.allocator;

    var mission_store = try mission_store_mod.MissionStore.initWithPath(allocator, null);
    defer mission_store.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");
    try tmp_dir.dir.makePath("agents");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "agents/reviewer-denied_config.json",
        .data = "{\"agent_id\":\"reviewer-denied\",\"primary\":{\"denied_tools\":[\"shell_exec\"]}}",
    });

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);
    const agents_dir = try std.fs.path.join(allocator, &.{ root, "agents" });
    defer allocator.free(agents_dir);

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "reviewer-host",
        .{
            .mission_store = &mission_store,
            .local_fs_export_root = exports_dir,
            .agents_dir = agents_dir,
            .actor_type = "agent",
            .actor_id = "reviewer-denied",
        },
    );
    defer session.deinit();

    try protocolWriteFile(
        &session,
        allocator,
        732,
        733,
        &.{ "agents", "self", "pr_review", "control", "start.json" },
        "{\"repo_key\":\"DeanoC/Spiderweb\",\"pr_number\":129,\"default_review_commands\":[\"printf validation-ok\"]}",
        1816,
    );

    const start_result = try protocolReadFile(
        &session,
        allocator,
        734,
        735,
        &.{ "agents", "self", "pr_review", "result.json" },
        1817,
    );
    defer allocator.free(start_result);
    const mission_id = try extractMissionIdFromResultPayload(allocator, start_result);
    defer allocator.free(mission_id);

    const validation_payload = try std.fmt.allocPrint(allocator, "{{\"mission_id\":\"{s}\"}}", .{mission_id});
    defer allocator.free(validation_payload);
    try protocolWriteFile(
        &session,
        allocator,
        736,
        737,
        &.{ "agents", "self", "pr_review", "control", "run_validation.json" },
        validation_payload,
        1818,
    );

    const pr_review_result = try protocolReadFile(
        &session,
        allocator,
        738,
        739,
        &.{ "agents", "self", "pr_review", "result.json" },
        1819,
    );
    defer allocator.free(pr_review_result);
    try std.testing.expect(std.mem.indexOf(u8, pr_review_result, "\"operation\":\"run_validation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pr_review_result, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, pr_review_result, "\"code\":\"tool_not_allowed\"") != null);

    const terminal_current = try protocolReadFile(
        &session,
        allocator,
        740,
        741,
        &.{ "nodes", "local", "venoms", "terminal", "current.json" },
        1820,
    );
    defer allocator.free(terminal_current);
    try std.testing.expect(std.mem.indexOf(u8, terminal_current, "\"session\":null") != null);
}

test "acheron_session: pr_review run_validation succeeds without interactive terminal sessions" {
    const allocator = std.testing.allocator;

    var mission_store = try mission_store_mod.MissionStore.initWithPath(allocator, null);
    defer mission_store.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "reviewer-host",
        .{
            .mission_store = &mission_store,
            .local_fs_export_root = exports_dir,
            .actor_type = "agent",
            .actor_id = "reviewer-host",
        },
    );
    defer session.deinit();

    try protocolWriteFile(
        &session,
        allocator,
        1821,
        1822,
        &.{ "agents", "self", "pr_review", "control", "start.json" },
        "{\"repo_key\":\"DeanoC/Spiderweb\",\"pr_number\":130,\"checkout_path\":\"/nodes/local/fs\",\"default_review_commands\":[\"printf validation-ok\"]}",
        1823,
    );

    const start_result = try protocolReadFile(
        &session,
        allocator,
        1824,
        1825,
        &.{ "agents", "self", "pr_review", "result.json" },
        1826,
    );
    defer allocator.free(start_result);
    const mission_id = try extractMissionIdFromResultPayload(allocator, start_result);
    defer allocator.free(mission_id);

    const validation_payload = try std.fmt.allocPrint(allocator, "{{\"mission_id\":\"{s}\"}}", .{mission_id});
    defer allocator.free(validation_payload);
    try protocolWriteFile(
        &session,
        allocator,
        1827,
        1828,
        &.{ "agents", "self", "pr_review", "control", "run_validation.json" },
        validation_payload,
        1829,
    );

    const pr_review_result = try protocolReadFile(
        &session,
        allocator,
        1830,
        1831,
        &.{ "agents", "self", "pr_review", "result.json" },
        1832,
    );
    defer allocator.free(pr_review_result);
    try std.testing.expect(std.mem.indexOf(u8, pr_review_result, "\"operation\":\"run_validation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, pr_review_result, "\"ok\":true") != null);

    const terminal_current = try protocolReadFile(
        &session,
        allocator,
        1833,
        1834,
        &.{ "nodes", "local", "venoms", "terminal", "current.json" },
        1835,
    );
    defer allocator.free(terminal_current);
    try std.testing.expect(std.mem.indexOf(u8, terminal_current, "\"session\":null") != null);
}

test "acheron_session: local fs export rejects symlink targets outside export root" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");
    try tmp_dir.dir.makePath("outside");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "outside/secret.txt",
        .data = "super-secret",
    });
    tmp_dir.dir.symLink("../outside/secret.txt", "exports/leak.txt", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.Unsupported => return error.SkipZigTest,
        else => return err,
    };

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "default",
        .{
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
        },
    );
    defer session.deinit();

    const leak = try session.tryReadInternalPath("/nodes/local/fs/leak.txt");
    defer if (leak) |value| allocator.free(value);
    try std.testing.expect(leak == null);
}

test "acheron_session: local fs mount path readlink and symlink controls use the export root" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "exports/target.txt",
        .data = "linked-content",
    });

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "default",
        .{
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
        },
    );
    defer session.deinit();

    try std.testing.expect(try session.trySymlinkLocalFsBackedMountPath("target.txt", "/nodes/local/fs/link.txt"));
    const target = (try session.tryReadlinkLocalFsBackedMountPath("/nodes/local/fs/link.txt")) orelse return error.TestUnexpectedResult;
    defer allocator.free(target);
    try std.testing.expectEqualStrings("target.txt", target);

    const linked = (try session.tryReadInternalPath("/nodes/local/fs/link.txt")) orelse return error.TestUnexpectedResult;
    defer allocator.free(linked);
    try std.testing.expectEqualStrings("linked-content", linked);
}

test "acheron_session: local fs refresh sees new files immediately" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "exports/first.txt",
        .data = "one",
    });

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "default",
        .{
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
        },
    );
    defer session.deinit();

    const local_fs_dir = session.resolveAbsolutePathNoBinds("/nodes/local/fs") orelse return error.MissingNode;

    try session.refreshDynamicDirectory(local_fs_dir);
    try std.testing.expect(session.lookupChild(local_fs_dir, "first.txt") != null);

    try tmp_dir.dir.writeFile(.{
        .sub_path = "exports/second.txt",
        .data = "two",
    });

    try session.refreshDynamicDirectory(local_fs_dir);
    try std.testing.expect(session.lookupChild(local_fs_dir, "second.txt") != null);
}

test "acheron_session: local fs backed mount writes can create missing project files" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "default",
        .{
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
        },
    );
    defer session.deinit();

    try std.testing.expect(try session.tryWriteLocalFsBackedMountFile("/nodes/local/fs/game.py", "print('ok')\n"));

    const created = try session.tryReadInternalPath("/nodes/local/fs/game.py");
    defer if (created) |value| allocator.free(value);
    try std.testing.expect(created != null);
    try std.testing.expectEqualStrings("print('ok')\n", created.?);
}

test "acheron_session: local fs backed mount writes do not materialize projected shared_data" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "default",
        .{
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
        },
    );
    defer session.deinit();

    try std.testing.expect(!(try session.tryWriteLocalFsBackedMountFile(
        "/nodes/local/fs/.spiderweb/shared_data/world_seed.json",
        "{\"bad\":true}",
    )));

    const host_path = try std.fs.path.join(allocator, &.{ exports_dir, ".spiderweb", "shared_data", "world_seed.json" });
    defer allocator.free(host_path);
    try std.testing.expect(!pathExistsAbsolute(host_path));
}

test "acheron_session: dynamic refresh skips re-entrant invocation" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("exports");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "exports/first.txt",
        .data = "one",
    });

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const exports_dir = try std.fs.path.join(allocator, &.{ root, "exports" });
    defer allocator.free(exports_dir);

    const runtime_handle = try runtime_handle_mod.RuntimeHandle.createUnavailable(
        allocator,
        "execution_failed",
        "runtime unavailable",
    );
    defer runtime_handle.destroy();

    var session = try Session.initWithOptions(
        allocator,
        runtime_handle,
        "default",
        .{
            .local_fs_export_root = exports_dir,
            .agents_dir = ".does-not-exist",
            .projects_dir = ".does-not-exist",
        },
    );
    defer session.deinit();

    const local_fs_dir = session.resolveAbsolutePathNoBinds("/nodes/local/fs") orelse return error.MissingNode;

    try session.refreshDynamicDirectory(local_fs_dir);
    try std.testing.expect(session.lookupChild(local_fs_dir, "first.txt") != null);

    const local_fs_node = session.nodes.getPtr(local_fs_dir) orelse return error.MissingNode;
    local_fs_node.dynamic_refresh_in_progress = true;
    defer local_fs_node.dynamic_refresh_in_progress = false;

    try tmp_dir.dir.writeFile(.{
        .sub_path = "exports/second.txt",
        .data = "two",
    });

    try session.refreshDynamicDirectory(local_fs_dir);
    try std.testing.expect(session.lookupChild(local_fs_dir, "second.txt") == null);

    local_fs_node.dynamic_refresh_in_progress = false;
    try session.refreshDynamicDirectory(local_fs_dir);
    try std.testing.expect(session.lookupChild(local_fs_dir, "second.txt") != null);
}

test "session: hostPathMatchesPrefixBoundary handles native separators" {
    if (builtin.os.tag == .windows) {
        try std.testing.expect(hostPathMatchesPrefixBoundary("C:\\root\\file.txt", "C:\\root"));
        try std.testing.expect(hostPathMatchesPrefixBoundary("C:\\root\\file.txt", "C:\\root\\"));
        try std.testing.expect(!hostPathMatchesPrefixBoundary("C:\\rooted\\file.txt", "C:\\root"));
    } else {
        try std.testing.expect(hostPathMatchesPrefixBoundary("/root/file.txt", "/root"));
        try std.testing.expect(hostPathMatchesPrefixBoundary("/root/file.txt", "/"));
        try std.testing.expect(!hostPathMatchesPrefixBoundary("/rooted/file.txt", "/root"));
    }
}

test "session: parseReaddirNextCookie accepts next" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"ents\":[],\"next\":18}", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 18), Session.parseReaddirNextCookie(parsed.value.object));
}

test "acheron_session: protocol json advertises the expected namespace ops" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, acheron_protocol_json, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("acheron", parsed.value.object.get("channel").?.string);
    try std.testing.expectEqualStrings("acheron-1", parsed.value.object.get("version").?.string);
    try std.testing.expectEqualStrings("acheron-namespace-project-contract-v2", parsed.value.object.get("layout").?.string);

    const ops = parsed.value.object.get("ops").?.array.items;
    const expected_ops = [_][]const u8{
        "t_version",
        "t_attach",
        "t_walk",
        "t_open",
        "t_read",
        "t_write",
        "t_stat",
        "t_clunk",
        "t_flush",
    };

    try std.testing.expectEqual(expected_ops.len, ops.len);
    for (expected_ops, ops) |expected, actual| {
        try std.testing.expect(actual == .string);
        try std.testing.expectEqualStrings(expected, actual.string);
    }
}

test "acheron_session: bootstrap required services match the external-agent core" {
    const expected = [_][]const u8{
        "home",
        "mounts",
        "workers",
        "terminal",
        "git",
        "search_code",
        "library",
        "events",
    };

    try std.testing.expectEqual(expected.len, bootstrap_required_services.len);
    for (expected, 0..) |venom_id, idx| {
        try std.testing.expectEqualStrings(venom_id, bootstrap_required_services[idx].venom_id);
    }
}
