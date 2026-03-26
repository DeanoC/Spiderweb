const std = @import("std");
const venom_catalog = @import("spiderweb_node").venom_catalog;
const venom_package_model = @import("../venom_package.zig");
const venom_packages = @import("../venom_packages.zig");
const venom_model = @import("../venom_model.zig");

const persistence_base_id = "spiderweb:control-plane:state";
const persistence_kind = "control_plane_state_v1";
const persistence_key_env = "SPIDERWEB_CONTROL_STATE_KEY_HEX";
const persistence_cipher = std.crypto.aead.aes_gcm.Aes256Gcm;
const persistence_aad = "spiderweb-control-plane-state-v1";
const max_snapshot_file_bytes: u64 = 256 * 1024 * 1024;
pub const host_workspace_id = "system";
const host_project_name = "Spiderweb Host";
const host_project_status = "active";
const host_project_vision = "Internal Spiderweb host state and integrations";
const host_workspace_mount_path = "/nodes/local/fs";
const host_workspace_mount_prefix = "/nodes/local/projects/" ++ host_workspace_id ++ "/";
const default_host_project_export_name = "host-workspace";
const host_internal_project_kind_name = "host_internal";
const normal_project_kind_name = "normal";
const default_project_template_id = "minimum";
const default_host_actor_id = "spiderweb";
const default_spider_web_root = "";
const default_platform_os = "unknown";
const default_platform_arch = "unknown";
const default_platform_runtime_kind = "unknown";
const node_venom_event_history_max_default: usize = 1024;

const WorkspaceKind = enum {
    normal,
    host_internal,
};

pub const ControlPlaneError = error{
    InvalidPayload,
    MissingField,
    TemplateNotFound,
    InviteNotFound,
    InviteExpired,
    InviteRedeemed,
    NodeNotFound,
    NodeAuthFailed,
    PendingJoinNotFound,
    WorkspaceNotFound,
    WorkspaceAuthFailed,
    WorkspaceProtected,
    WorkspaceAssignmentForbidden,
    WorkspacePolicyForbidden,
    MountConflict,
    MountNotFound,
    BindConflict,
    BindNotFound,
    VenomPackageNotFound,
    VenomPackageBuiltinProtected,
    VenomPackageHostUnsupported,
    VenomPackageProjectionUnsupported,
    VenomPackageRequirementsUnmet,
    VenomPackageRuntimeMismatch,
    AlreadyExists,
};

pub const WorkspaceAction = enum {
    read,
    observe,
    invoke,
    mount,
    bind,
    admin,
};

const AccessMode = enum {
    open,
    token,
    admin,
    deny,
};

const WorkspaceActionPolicy = struct {
    read: ?AccessMode = null,
    observe: ?AccessMode = null,
    invoke: ?AccessMode = null,
    mount: ?AccessMode = null,
    bind: ?AccessMode = null,
    admin: ?AccessMode = null,

    fn modeFor(self: *const WorkspaceActionPolicy, action: WorkspaceAction) ?AccessMode {
        return switch (action) {
            .read => self.read,
            .observe => self.observe,
            .invoke => self.invoke,
            .mount => self.mount,
            .bind => self.bind,
            .admin => self.admin,
        };
    }
};

const WorkspaceAgentAccessOverride = struct {
    agent_id: []u8,
    actions: WorkspaceActionPolicy = .{},

    fn deinit(self: *WorkspaceAgentAccessOverride, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_id);
        self.* = undefined;
    }
};

const WorkspaceAccessPolicy = struct {
    actions: WorkspaceActionPolicy = .{},
    agents: std.ArrayListUnmanaged(WorkspaceAgentAccessOverride) = .{},

    fn deinit(self: *WorkspaceAccessPolicy, allocator: std.mem.Allocator) void {
        for (self.agents.items) |*entry| entry.deinit(allocator);
        self.agents.deinit(allocator);
        self.* = undefined;
    }

    fn modeFor(self: *const WorkspaceAccessPolicy, actor_id: ?[]const u8, action: WorkspaceAction) ?AccessMode {
        if (actor_id) |actor| {
            for (self.agents.items) |entry| {
                if (!std.mem.eql(u8, entry.agent_id, actor)) continue;
                if (entry.actions.modeFor(action)) |mode| return mode;
                break;
            }
        }
        return self.actions.modeFor(action);
    }
};

const NodeLabel = struct {
    key: []u8,
    value: []u8,

    fn deinit(self: *NodeLabel, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
        self.* = undefined;
    }
};

pub const SpiderWebMountSpec = struct {
    mount_path: []const u8,
    export_name: []const u8,
};

pub const PreferredVenomProvider = struct {
    node_id: []u8,
    node_name: []u8,
    venom_id: []u8,
    host_type: []u8,
    endpoint_path: []u8,

    pub fn deinit(self: *PreferredVenomProvider, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
        allocator.free(self.node_name);
        allocator.free(self.venom_id);
        allocator.free(self.host_type);
        allocator.free(self.endpoint_path);
        self.* = undefined;
    }
};

const PreferredVenomProviderConstraints = struct {
    host_role: ?venom_model.HostRole = null,
    binding_scope: ?venom_model.BindingScope = null,
};

const PreferredVenomBindingScope = enum {
    global,
    project,
    agent,

    fn fromString(value: []const u8) ?PreferredVenomBindingScope {
        if (std.mem.eql(u8, value, "global")) return .global;
        if (std.mem.eql(u8, value, "project")) return .project;
        if (std.mem.eql(u8, value, "agent")) return .agent;
        return null;
    }

    fn asString(self: PreferredVenomBindingScope) []const u8 {
        return switch (self) {
            .global => "global",
            .project => "project",
            .agent => "agent",
        };
    }
};

const Invite = struct {
    id: []u8,
    token: []u8,
    created_at_ms: i64,
    expires_at_ms: i64,
    redeemed: bool = false,

    fn deinit(self: *Invite, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.token);
        self.* = undefined;
    }
};

const Node = struct {
    id: []u8,
    name: []u8,
    fs_url: []u8,
    secret: []u8,
    lease_token: []u8,
    platform_os: []u8,
    platform_arch: []u8,
    platform_runtime_kind: []u8,
    labels: std.ArrayListUnmanaged(NodeLabel) = .{},
    venoms: std.ArrayListUnmanaged(venom_catalog.VenomDescriptor) = .{},
    venom_package_ids: std.ArrayListUnmanaged(?[]u8) = .{},
    joined_at_ms: i64,
    last_seen_ms: i64,
    lease_expires_at_ms: i64,

    fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.fs_url);
        allocator.free(self.secret);
        allocator.free(self.lease_token);
        allocator.free(self.platform_os);
        allocator.free(self.platform_arch);
        allocator.free(self.platform_runtime_kind);
        for (self.labels.items) |*label| label.deinit(allocator);
        self.labels.deinit(allocator);
        venom_catalog.deinitVenoms(allocator, &self.venoms);
        for (self.venom_package_ids.items) |package_id| {
            if (package_id) |value| allocator.free(value);
        }
        self.venom_package_ids.deinit(allocator);
        self.* = undefined;
    }
};

const NodeVenomDigest = struct {
    venom_id: []u8,
    version: []u8,
    package_id: ?[]u8 = null,
    digest: u64,

    fn deinit(self: *NodeVenomDigest, allocator: std.mem.Allocator) void {
        allocator.free(self.venom_id);
        allocator.free(self.version);
        if (self.package_id) |value| allocator.free(value);
        self.* = undefined;
    }
};

const NodeVenomEventRecord = struct {
    timestamp_ms: i64,
    node_id: []u8,
    payload_json: []u8,

    fn deinit(self: *NodeVenomEventRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
        allocator.free(self.payload_json);
        self.* = undefined;
    }
};

const InstalledVenomRelease = struct {
    package_id: []u8,
    package: venom_package_model.VenomPackage,

    fn deinit(self: *InstalledVenomRelease, allocator: std.mem.Allocator) void {
        allocator.free(self.package_id);
        self.package.deinit(allocator);
        self.* = undefined;
    }
};

const PendingJoin = struct {
    id: []u8,
    node_name: []u8,
    fs_url: []u8,
    platform_os: []u8,
    platform_arch: []u8,
    platform_runtime_kind: []u8,
    requested_at_ms: i64,

    fn deinit(self: *PendingJoin, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.node_name);
        allocator.free(self.fs_url);
        allocator.free(self.platform_os);
        allocator.free(self.platform_arch);
        allocator.free(self.platform_runtime_kind);
        self.* = undefined;
    }
};

const WorkspaceMount = struct {
    mount_path: []u8,
    node_id: []u8,
    export_name: []u8,

    fn deinit(self: *WorkspaceMount, allocator: std.mem.Allocator) void {
        allocator.free(self.mount_path);
        allocator.free(self.node_id);
        allocator.free(self.export_name);
        self.* = undefined;
    }
};

const WorkspaceBind = struct {
    bind_path: []u8,
    target_path: []u8,

    fn deinit(self: *WorkspaceBind, allocator: std.mem.Allocator) void {
        allocator.free(self.bind_path);
        allocator.free(self.target_path);
        self.* = undefined;
    }
};

const WorkspaceTemplateBindSpec = struct {
    bind_path: []const u8,
    venom_id: []const u8,
    host_role: venom_model.HostRole = .spiderweb,
};

const WorkspaceTemplateSpec = struct {
    id: []const u8,
    description: []const u8,
    bind_specs: []const WorkspaceTemplateBindSpec,
};

const core_workspace_bind_specs = [_]WorkspaceTemplateBindSpec{
    .{ .bind_path = "/.spiderweb/control/workspace/mounts", .venom_id = "mounts" },
    .{ .bind_path = "/.spiderweb/control/workspace/home", .venom_id = "home" },
    .{ .bind_path = "/.spiderweb/control/packages", .venom_id = "packages" },
    .{ .bind_path = "/.spiderweb/control/runtimes", .venom_id = "runtimes" },
    .{ .bind_path = "/.spiderweb/venoms/terminal", .venom_id = "terminal", .host_role = .node },
    .{ .bind_path = "/.spiderweb/venoms/git", .venom_id = "git", .host_role = .node },
    .{ .bind_path = "/.spiderweb/venoms/search_code", .venom_id = "search_code", .host_role = .node },
};

const builtin_workspace_templates = [_]WorkspaceTemplateSpec{
    .{
        .id = default_project_template_id,
        .description = "Minimal external-agent workspace with canonical control and venom bindings under /.spiderweb.",
        .bind_specs = core_workspace_bind_specs[0..],
    },
    .{
        .id = "dev",
        .description = "Development workspace with canonical control and venom bindings under /.spiderweb.",
        .bind_specs = core_workspace_bind_specs[0..],
    },
};

const Workspace = struct {
    id: []u8,
    name: []u8,
    vision: []u8,
    status: []u8,
    template_id: []u8,
    kind: WorkspaceKind = .normal,
    is_delete_protected: bool = false,
    token_locked: bool = false,
    mutation_token: []u8,
    access_policy: WorkspaceAccessPolicy = .{},
    created_at_ms: i64,
    updated_at_ms: i64,
    mounts: std.ArrayListUnmanaged(WorkspaceMount) = .{},
    binds: std.ArrayListUnmanaged(WorkspaceBind) = .{},

    fn deinit(self: *Workspace, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.vision);
        allocator.free(self.status);
        allocator.free(self.template_id);
        allocator.free(self.mutation_token);
        self.access_policy.deinit(allocator);
        for (self.mounts.items) |*mount| mount.deinit(allocator);
        self.mounts.deinit(allocator);
        for (self.binds.items) |*bind| bind.deinit(allocator);
        self.binds.deinit(allocator);
        self.* = undefined;
    }
};

const ReconcileState = enum {
    idle,
    pending,
    running,
    degraded,
};

const DriftSeverity = enum {
    info,
    warning,
    err,
};

const ReconcileWorkspaceSummary = struct {
    drift_count: u32 = 0,
    queue_depth: u32 = 0,
    mounts_total: u32 = 0,
    online_mounts: u32 = 0,
    degraded_mounts: u32 = 0,
    missing_mounts: u32 = 0,
};

pub const ControlPlane = struct {
    allocator: std.mem.Allocator,
    host_actor_id: []const u8 = default_host_actor_id,
    spider_web_root: []const u8 = default_spider_web_root,
    node_venom_event_history_max: usize = node_venom_event_history_max_default,
    snapshot_directory: ?[]u8 = null,
    snapshot_filename: ?[]u8 = null,
    state_encryption_key: ?[persistence_cipher.key_length]u8 = null,
    mutex: std.Thread.Mutex = .{},

    invites: std.StringHashMapUnmanaged(Invite) = .{},
    nodes: std.StringHashMapUnmanaged(Node) = .{},
    pending_joins: std.StringHashMapUnmanaged(PendingJoin) = .{},
    workspaces: std.StringHashMapUnmanaged(Workspace) = .{},
    installed_venom_releases: std.ArrayListUnmanaged(InstalledVenomRelease) = .{},
    installed_venom_packages: std.ArrayListUnmanaged(venom_package_model.VenomPackage) = .{},
    active_workspace_by_agent: std.StringHashMapUnmanaged([]u8) = .{},
    preferred_venom_provider_by_scope_venom: std.StringHashMapUnmanaged([]u8) = .{},
    node_venom_event_history: std.ArrayListUnmanaged(NodeVenomEventRecord) = .{},

    next_invite_id: u64 = 1,
    next_node_id: u64 = 1,
    next_pending_join_id: u64 = 1,
    next_workspace_id: u64 = 1,

    invites_created_total: u64 = 0,
    invites_redeemed_total: u64 = 0,
    node_joins_total: u64 = 0,
    node_lease_refresh_total: u64 = 0,
    nodes_ensured_total: u64 = 0,
    node_deletes_total: u64 = 0,
    workspace_creates_total: u64 = 0,
    workspace_updates_total: u64 = 0,
    workspace_deletes_total: u64 = 0,
    mount_sets_total: u64 = 0,
    mount_removes_total: u64 = 0,
    workspace_token_rotates_total: u64 = 0,
    workspace_token_revokes_total: u64 = 0,
    workspace_activations_total: u64 = 0,
    lease_reap_nodes_total: u64 = 0,

    reconcile_state: ReconcileState = .pending,
    reconcile_last_reconcile_ms: i64 = 0,
    reconcile_last_success_ms: i64 = 0,
    reconcile_last_error: ?[]u8 = null,
    reconcile_queue_depth: u32 = 0,
    reconcile_failed_ops_total: u64 = 0,
    reconcile_cycles_total: u64 = 0,
    reconcile_requested_at_ms: i64 = 0,
    reconcile_debounce_ms: i64 = 250,
    reconcile_retry_backoff_ms: i64 = 100,
    reconcile_max_retries_per_cycle: u32 = 3,
    reconcile_last_failed_ops: std.ArrayListUnmanaged([]u8) = .{},

    pub const ActiveWorkspaceBinding = struct {
        agent_id: []u8,
        workspace_id: []u8,

        pub fn deinit(self: *ActiveWorkspaceBinding, allocator: std.mem.Allocator) void {
            allocator.free(self.agent_id);
            allocator.free(self.workspace_id);
            self.* = undefined;
        }
    };

    pub const InitOptions = struct {
        host_actor_id: []const u8 = default_host_actor_id,
        spider_web_root: []const u8 = default_spider_web_root,
        node_venom_event_history_max: usize = node_venom_event_history_max_default,
    };

    pub fn init(allocator: std.mem.Allocator) ControlPlane {
        return initWithOptions(allocator, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, options: InitOptions) ControlPlane {
        const host_actor_id = if (std.mem.trim(u8, options.host_actor_id, " \t\r\n").len > 0)
            options.host_actor_id
        else
            default_host_actor_id;
        const spider_web_root = if (std.mem.trim(u8, options.spider_web_root, " \t\r\n").len > 0)
            options.spider_web_root
        else
            default_spider_web_root;
        const node_venom_event_history_max = if (options.node_venom_event_history_max == 0)
            node_venom_event_history_max_default
        else
            options.node_venom_event_history_max;
        var plane: ControlPlane = .{
            .allocator = allocator,
            .host_actor_id = host_actor_id,
            .spider_web_root = spider_web_root,
            .node_venom_event_history_max = node_venom_event_history_max,
        };
        plane.ensureBuiltinHostProjectBestEffortLocked(std.time.milliTimestamp());
        return plane;
    }

    pub fn initWithPersistence(
        allocator: std.mem.Allocator,
        state_directory: []const u8,
        state_db_filename: []const u8,
    ) ControlPlane {
        return initWithPersistenceOptions(allocator, state_directory, state_db_filename, .{});
    }

    pub fn initWithPersistenceOptions(
        allocator: std.mem.Allocator,
        state_directory: []const u8,
        state_db_filename: []const u8,
        options: InitOptions,
    ) ControlPlane {
        var plane = ControlPlane.initWithOptions(allocator, options);
        plane.state_encryption_key = loadStateEncryptionKey(allocator);
        if (state_directory.len == 0 or state_db_filename.len == 0) return plane;

        plane.snapshot_directory = allocator.dupe(u8, state_directory) catch |err| {
            std.log.warn("control-plane persistence disabled: failed duplicating snapshot directory: {s}", .{@errorName(err)});
            return plane;
        };
        errdefer if (plane.snapshot_directory) |directory| allocator.free(directory);

        plane.snapshot_filename = allocator.dupe(u8, state_db_filename) catch |err| {
            std.log.warn("control-plane persistence disabled: failed duplicating snapshot filename: {s}", .{@errorName(err)});
            if (plane.snapshot_directory) |directory| allocator.free(directory);
            plane.snapshot_directory = null;
            return plane;
        };

        plane.loadSnapshotLocked() catch |err| {
            plane.clearState();
            plane.next_invite_id = 1;
            plane.next_node_id = 1;
            plane.next_pending_join_id = 1;
            plane.next_workspace_id = 1;
            std.log.warn("control-plane snapshot load failed: {s}", .{@errorName(err)});
        };
        plane.ensureBuiltinHostProjectBestEffortLocked(std.time.milliTimestamp());
        return plane;
    }

    fn ensureBuiltinHostProjectBestEffortLocked(self: *ControlPlane, now_ms: i64) void {
        self.ensureBuiltinHostProjectLocked(now_ms) catch |err| {
            std.log.warn("control-plane host project ensure failed: {s}", .{@errorName(err)});
        };
    }

    fn ensureBuiltinHostProjectLocked(self: *ControlPlane, now_ms: i64) !void {
        var changed = false;
        if (self.workspaces.getPtr(host_workspace_id)) |project| {
            if (project.kind != .host_internal) {
                project.kind = .host_internal;
                changed = true;
            }
            if (project.template_id.len != 0) {
                self.allocator.free(project.template_id);
                project.template_id = try self.allocator.dupe(u8, "");
                changed = true;
            }
            if (!project.token_locked) {
                project.token_locked = true;
                changed = true;
            }
            if (!project.is_delete_protected) {
                project.is_delete_protected = true;
                changed = true;
            }
            if (!std.mem.eql(u8, project.status, host_project_status)) {
                self.allocator.free(project.status);
                project.status = try self.allocator.dupe(u8, host_project_status);
                changed = true;
            }
            if (project.name.len == 0) {
                self.allocator.free(project.name);
                project.name = try self.allocator.dupe(u8, host_project_name);
                changed = true;
            }
            if (pruneLegacyWorkspaceAliasMountsIfReplacementLocked(self, project)) changed = true;
            if (changed) project.updated_at_ms = now_ms;
        } else {
            const project = Workspace{
                .id = try self.allocator.dupe(u8, host_workspace_id),
                .name = try self.allocator.dupe(u8, host_project_name),
                .vision = try self.allocator.dupe(u8, host_project_vision),
                .status = try self.allocator.dupe(u8, host_project_status),
                .template_id = try self.allocator.dupe(u8, ""),
                .kind = .host_internal,
                .is_delete_protected = true,
                .token_locked = true,
                .mutation_token = try makeToken(self.allocator, "ws"),
                .created_at_ms = now_ms,
                .updated_at_ms = now_ms,
            };
            errdefer {
                self.allocator.free(project.id);
                self.allocator.free(project.name);
                self.allocator.free(project.vision);
                self.allocator.free(project.status);
                self.allocator.free(project.template_id);
                self.allocator.free(project.mutation_token);
            }
            try self.workspaces.put(self.allocator, project.id, project);
            changed = true;
        }

        var active_it = self.active_workspace_by_agent.iterator();
        while (active_it.next()) |entry| {
            if (!std.mem.eql(u8, entry.value_ptr.*, host_workspace_id)) continue;
            self.allocator.free(entry.value_ptr.*);
            entry.value_ptr.* = try self.allocator.dupe(u8, "");
            changed = true;
        }

        var project_it = self.workspaces.valueIterator();
        while (project_it.next()) |project| {
            if (project.kind == .host_internal) continue;
            var project_changed = false;
            if (try ensureDefaultWorkspaceMountsLocked(self, project)) project_changed = true;
            if (try ensureWorkspaceTemplateBindsLocked(self, project)) project_changed = true;
            if (!project_changed) continue;
            project.updated_at_ms = now_ms;
            changed = true;
        }

        const host_project = getHostWorkspacePtrLocked(self) catch return;
        if (try ensureHostWorkspaceBindsLocked(self, host_project)) {
            host_project.updated_at_ms = now_ms;
            changed = true;
        }

        if (changed) self.persistSnapshotBestEffortLocked();
    }

    pub fn ensureSpiderWebMount(self: *ControlPlane, node_id: []const u8, export_name: []const u8) !void {
        const mount_specs = [_]SpiderWebMountSpec{
            .{ .mount_path = host_workspace_mount_path, .export_name = export_name },
        };
        return self.ensureSpiderWebMounts(node_id, &mount_specs);
    }

    pub fn ensureSpiderWebMounts(
        self: *ControlPlane,
        node_id: []const u8,
        mount_specs: []const SpiderWebMountSpec,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now_ms = std.time.milliTimestamp();
        _ = self.reapExpiredLeasesLocked(now_ms);
        try validateIdentifier(node_id, 128);
        if (mount_specs.len == 0) return ControlPlaneError.MissingField;
        if (!self.nodes.contains(node_id)) return ControlPlaneError.NodeNotFound;
        try self.ensureBuiltinHostProjectLocked(now_ms);
        const project = try getHostWorkspacePtrLocked(self);

        var normalized_paths = std.ArrayListUnmanaged([]u8){};
        defer {
            for (normalized_paths.items) |path| self.allocator.free(path);
            normalized_paths.deinit(self.allocator);
        }

        for (mount_specs) |spec| {
            try validateExportName(spec.export_name);
            const normalized = try normalizeMountPath(self.allocator, spec.mount_path);
            errdefer self.allocator.free(normalized);
            for (normalized_paths.items) |existing| {
                if (std.mem.eql(u8, existing, normalized)) {
                    self.allocator.free(normalized);
                    return ControlPlaneError.MountConflict;
                }
                if (mountPathsOverlap(existing, normalized)) {
                    self.allocator.free(normalized);
                    return ControlPlaneError.MountConflict;
                }
            }
            try normalized_paths.append(self.allocator, normalized);
        }

        var changed = false;
        for (mount_specs, 0..) |spec, idx| {
            const normalized = normalized_paths.items[idx];
            var existing_for_node: ?usize = null;

            var mount_idx: usize = 0;
            while (mount_idx < project.mounts.items.len) : (mount_idx += 1) {
                const existing = project.mounts.items[mount_idx];
                if (mountPathsOverlap(existing.mount_path, normalized) and !std.mem.eql(u8, existing.mount_path, normalized)) {
                    return ControlPlaneError.MountConflict;
                }
                if (std.mem.eql(u8, existing.mount_path, normalized) and std.mem.eql(u8, existing.node_id, node_id)) {
                    existing_for_node = mount_idx;
                }
            }
            for (project.binds.items) |existing_bind| {
                if (pathsConflict(existing_bind.bind_path, normalized)) {
                    return ControlPlaneError.MountConflict;
                }
            }

            if (existing_for_node) |existing_idx| {
                var existing_mount = &project.mounts.items[existing_idx];
                if (!std.mem.eql(u8, existing_mount.export_name, spec.export_name)) {
                    self.allocator.free(existing_mount.export_name);
                    existing_mount.export_name = try self.allocator.dupe(u8, spec.export_name);
                    changed = true;
                }
            } else {
                try project.mounts.append(self.allocator, .{
                    .mount_path = try self.allocator.dupe(u8, normalized),
                    .node_id = try self.allocator.dupe(u8, node_id),
                    .export_name = try self.allocator.dupe(u8, spec.export_name),
                });
                changed = true;
            }
        }

        if (!changed) return;
        project.updated_at_ms = now_ms;
        self.mount_sets_total +%= 1;
        self.persistSnapshotBestEffortLocked();
    }

    fn isHostActor(self: *const ControlPlane, agent_id: []const u8) bool {
        return std.mem.eql(u8, agent_id, self.host_actor_id);
    }

    pub fn workspaceAllowsAction(
        self: *ControlPlane,
        workspace_id: []const u8,
        agent_id: ?[]const u8,
        action: WorkspaceAction,
        workspace_token: ?[]const u8,
        is_admin: bool,
    ) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        const project = self.workspaces.get(workspace_id) orelse return false;
        const actor_is_primary = if (agent_id) |actor| self.isHostActor(actor) else false;
        if (actor_is_primary) return true;
        if (project.kind == .host_internal and !is_admin) {
            return false;
        }
        requireWorkspaceActionAccess(&project, action, agent_id, workspace_token, is_admin) catch return false;
        return true;
    }

    pub fn workspaceAllowsNodeVenomEvent(
        self: *ControlPlane,
        workspace_id: []const u8,
        agent_id: ?[]const u8,
        workspace_token: ?[]const u8,
        node_id: []const u8,
        is_admin: bool,
    ) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        const project = self.workspaces.get(workspace_id) orelse return false;
        const actor_is_primary = if (agent_id) |actor| self.isHostActor(actor) else false;
        if (project.kind == .host_internal and !is_admin) {
            if (!actor_is_primary) return false;
        }
        if (!actor_is_primary) {
            requireWorkspaceActionAccess(&project, .observe, agent_id, workspace_token, is_admin) catch return false;
        }

        for (project.mounts.items) |mount| {
            if (std.mem.eql(u8, mount.node_id, node_id)) return true;
        }
        return false;
    }

    fn appendNodeVenomEventLocked(self: *ControlPlane, node_id: []const u8, payload_json: []const u8) void {
        while (self.node_venom_event_history.items.len >= self.node_venom_event_history_max and
            self.node_venom_event_history.items.len > 0)
        {
            var dropped = self.node_venom_event_history.orderedRemove(0);
            dropped.deinit(self.allocator);
        }

        const node_copy = self.allocator.dupe(u8, node_id) catch return;
        errdefer self.allocator.free(node_copy);
        const payload_copy = self.allocator.dupe(u8, payload_json) catch return;
        errdefer self.allocator.free(payload_copy);
        self.node_venom_event_history.append(self.allocator, .{
            .timestamp_ms = std.time.milliTimestamp(),
            .node_id = node_copy,
            .payload_json = payload_copy,
        }) catch {
            self.allocator.free(node_copy);
            self.allocator.free(payload_copy);
        };
    }

    pub fn snapshotNodeVenomEvents(
        self: *ControlPlane,
        allocator: std.mem.Allocator,
        workspace_id: ?[]const u8,
        agent_id: ?[]const u8,
        workspace_token: ?[]const u8,
        is_admin: bool,
        replay_limit: usize,
    ) ![]u8 {
        var snapshot = std.ArrayListUnmanaged(NodeVenomEventRecord){};
        defer {
            for (snapshot.items) |*record| record.deinit(allocator);
            snapshot.deinit(allocator);
        }

        {
            self.mutex.lock();
            defer self.mutex.unlock();
            _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());
            for (self.node_venom_event_history.items) |record| {
                try snapshot.append(allocator, .{
                    .timestamp_ms = record.timestamp_ms,
                    .node_id = try allocator.dupe(u8, record.node_id),
                    .payload_json = try allocator.dupe(u8, record.payload_json),
                });
            }
        }

        var visible_indexes = std.ArrayListUnmanaged(usize){};
        defer visible_indexes.deinit(allocator);
        for (snapshot.items, 0..) |record, idx| {
            if (!is_admin) {
                const visible_project_id = workspace_id orelse continue;
                const visible_agent_id = agent_id orelse continue;
                if (!self.workspaceAllowsNodeVenomEvent(
                    visible_project_id,
                    visible_agent_id,
                    workspace_token,
                    record.node_id,
                    false,
                )) continue;
            }
            try visible_indexes.append(allocator, idx);
        }

        const limit = if (replay_limit == 0) visible_indexes.items.len else @min(replay_limit, visible_indexes.items.len);
        const start_index = visible_indexes.items.len - limit;

        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(allocator);
        for (visible_indexes.items[start_index..], 0..) |record_index, idx| {
            const record = snapshot.items[record_index];
            const escaped_node_id = try jsonEscape(allocator, record.node_id);
            defer allocator.free(escaped_node_id);
            if (idx != 0) try out.append(allocator, '\n');
            try out.writer(allocator).print(
                "{{\"timestamp_ms\":{d},\"node_id\":\"{s}\",\"payload\":{s}}}",
                .{ record.timestamp_ms, escaped_node_id, record.payload_json },
            );
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *ControlPlane) void {
        self.clearState();
        if (self.snapshot_directory) |directory| self.allocator.free(directory);
        if (self.snapshot_filename) |filename| self.allocator.free(filename);
    }

    pub fn dumpState(self: *ControlPlane) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.buildSnapshotJsonLocked();
    }

    pub fn loadState(self: *ControlPlane, snapshot_json: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.restoreSnapshotFromJsonLocked(snapshot_json);
        self.ensureBuiltinHostProjectBestEffortLocked(std.time.milliTimestamp());
    }

    fn clearState(self: *ControlPlane) void {
        var invite_it = self.invites.valueIterator();
        while (invite_it.next()) |invite| invite.deinit(self.allocator);
        self.invites.deinit(self.allocator);
        self.invites = .{};

        var node_it = self.nodes.valueIterator();
        while (node_it.next()) |node| node.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.nodes = .{};

        var pending_it = self.pending_joins.valueIterator();
        while (pending_it.next()) |pending| pending.deinit(self.allocator);
        self.pending_joins.deinit(self.allocator);
        self.pending_joins = .{};

        var project_it = self.workspaces.valueIterator();
        while (project_it.next()) |project| project.deinit(self.allocator);
        self.workspaces.deinit(self.allocator);
        self.workspaces = .{};

        for (self.installed_venom_releases.items) |*release| release.deinit(self.allocator);
        self.installed_venom_releases.deinit(self.allocator);
        self.installed_venom_releases = .{};

        venom_package_model.deinitPackages(self.allocator, &self.installed_venom_packages);

        var active_it = self.active_workspace_by_agent.iterator();
        while (active_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.active_workspace_by_agent.deinit(self.allocator);
        self.active_workspace_by_agent = .{};

        var preferred_venom_it = self.preferred_venom_provider_by_scope_venom.iterator();
        while (preferred_venom_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.preferred_venom_provider_by_scope_venom.deinit(self.allocator);
        self.preferred_venom_provider_by_scope_venom = .{};

        for (self.node_venom_event_history.items) |*record| record.deinit(self.allocator);
        self.node_venom_event_history.deinit(self.allocator);
        self.node_venom_event_history = .{};

        self.invites_created_total = 0;
        self.invites_redeemed_total = 0;
        self.node_joins_total = 0;
        self.node_lease_refresh_total = 0;
        self.nodes_ensured_total = 0;
        self.node_deletes_total = 0;
        self.workspace_creates_total = 0;
        self.workspace_updates_total = 0;
        self.workspace_deletes_total = 0;
        self.mount_sets_total = 0;
        self.mount_removes_total = 0;
        self.workspace_token_rotates_total = 0;
        self.workspace_token_revokes_total = 0;
        self.workspace_activations_total = 0;
        self.lease_reap_nodes_total = 0;
        self.next_pending_join_id = 1;

        if (self.reconcile_last_error) |value| {
            self.allocator.free(value);
            self.reconcile_last_error = null;
        }
        for (self.reconcile_last_failed_ops.items) |op| self.allocator.free(op);
        self.reconcile_last_failed_ops.deinit(self.allocator);
        self.reconcile_last_failed_ops = .{};
        self.reconcile_state = .pending;
        self.reconcile_last_reconcile_ms = 0;
        self.reconcile_last_success_ms = 0;
        self.reconcile_queue_depth = 0;
        self.reconcile_failed_ops_total = 0;
        self.reconcile_cycles_total = 0;
        self.reconcile_requested_at_ms = 0;
    }

    pub fn createNodeInvite(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;

        const expires_in_ms = getOptionalUnsigned(obj, "expires_in_ms", 30 * 60 * 1000) catch return ControlPlaneError.InvalidPayload;
        const now = std.time.milliTimestamp();

        const invite_id = try makeSequentialId(self.allocator, "invite", &self.next_invite_id);
        errdefer self.allocator.free(invite_id);
        const token = try makeToken(self.allocator, "inv");
        errdefer self.allocator.free(token);

        const invite = Invite{
            .id = invite_id,
            .token = token,
            .created_at_ms = now,
            .expires_at_ms = now + @as(i64, @intCast(expires_in_ms)),
            .redeemed = false,
        };
        try self.invites.put(self.allocator, invite.id, invite);
        self.invites_created_total +%= 1;
        self.persistSnapshotBestEffortLocked();

        const escaped_id = try jsonEscape(self.allocator, invite.id);
        defer self.allocator.free(escaped_id);
        const escaped_token = try jsonEscape(self.allocator, invite.token);
        defer self.allocator.free(escaped_token);

        return std.fmt.allocPrint(
            self.allocator,
            "{{\"invite_id\":\"{s}\",\"invite_token\":\"{s}\",\"created_at_ms\":{d},\"expires_at_ms\":{d}}}",
            .{ escaped_id, escaped_token, invite.created_at_ms, invite.expires_at_ms },
        );
    }

    pub fn listNodeInvites(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;

        const include_redeemed = getOptionalBool(obj, "include_redeemed", false) catch return ControlPlaneError.InvalidPayload;
        const include_expired = getOptionalBool(obj, "include_expired", false) catch return ControlPlaneError.InvalidPayload;
        const now = std.time.milliTimestamp();

        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "{\"invites\":[");
        var first = true;
        var invite_it = self.invites.valueIterator();
        while (invite_it.next()) |invite| {
            const expired = invite.expires_at_ms <= now;
            if (!include_redeemed and invite.redeemed) continue;
            if (!include_expired and expired) continue;
            if (!first) try out.append(self.allocator, ',');
            first = false;
            const escaped_id = try jsonEscape(self.allocator, invite.id);
            defer self.allocator.free(escaped_id);
            const escaped_token = try jsonEscape(self.allocator, invite.token);
            defer self.allocator.free(escaped_token);
            try out.writer(self.allocator).print(
                "{{\"invite_id\":\"{s}\",\"invite_token\":\"{s}\",\"created_at_ms\":{d},\"expires_at_ms\":{d},\"redeemed\":{s},\"expired\":{s}}}",
                .{
                    escaped_id,
                    escaped_token,
                    invite.created_at_ms,
                    invite.expires_at_ms,
                    if (invite.redeemed) "true" else "false",
                    if (expired) "true" else "false",
                },
            );
        }
        try out.appendSlice(self.allocator, "]}");
        return out.toOwnedSlice(self.allocator);
    }

    pub fn nodeJoinRequest(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;

        const node_name_raw = getOptionalString(obj, "node_name");
        const fs_url_raw = getOptionalString(obj, "fs_url") orelse "";
        if (node_name_raw) |name| try validateIdentifier(name, 128);
        if (fs_url_raw.len > 0) try validateFsUrl(fs_url_raw);
        var platform = parsePlatformFromPayloadValue(self.allocator, obj.get("platform")) catch return ControlPlaneError.InvalidPayload;
        defer platform.deinit(self.allocator);

        const request_id = try makeSequentialId(self.allocator, "pending-join", &self.next_pending_join_id);
        errdefer self.allocator.free(request_id);
        const node_name = if (node_name_raw) |value|
            try self.allocator.dupe(u8, value)
        else
            try self.allocator.dupe(u8, request_id);
        errdefer self.allocator.free(node_name);

        const pending = PendingJoin{
            .id = request_id,
            .node_name = node_name,
            .fs_url = try self.allocator.dupe(u8, fs_url_raw),
            .platform_os = try self.allocator.dupe(u8, platform.os),
            .platform_arch = try self.allocator.dupe(u8, platform.arch),
            .platform_runtime_kind = try self.allocator.dupe(u8, platform.runtime_kind),
            .requested_at_ms = std.time.milliTimestamp(),
        };
        errdefer {
            self.allocator.free(pending.fs_url);
            self.allocator.free(pending.platform_os);
            self.allocator.free(pending.platform_arch);
            self.allocator.free(pending.platform_runtime_kind);
        }
        try self.pending_joins.put(self.allocator, pending.id, pending);
        self.persistSnapshotBestEffortLocked();

        return appendPendingJoinJsonAlloc(self.allocator, pending);
    }

    pub fn listPendingNodeJoins(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        _ = payload_json;
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "{\"pending\":[");
        var first = true;
        var pending_it = self.pending_joins.valueIterator();
        while (pending_it.next()) |pending| {
            if (!first) try out.append(self.allocator, ',');
            first = false;
            const item = try appendPendingJoinJsonAlloc(self.allocator, pending.*);
            defer self.allocator.free(item);
            try out.appendSlice(self.allocator, item);
        }
        try out.appendSlice(self.allocator, "]}");
        return out.toOwnedSlice(self.allocator);
    }

    pub fn approvePendingNodeJoin(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;

        const request_id = getRequiredString(obj, "request_id") catch return ControlPlaneError.MissingField;
        try validateIdentifier(request_id, 128);
        const lease_ttl_ms = getOptionalUnsigned(obj, "lease_ttl_ms", 15 * 60 * 1000) catch return ControlPlaneError.InvalidPayload;

        const removed = self.pending_joins.fetchRemove(request_id) orelse return ControlPlaneError.PendingJoinNotFound;
        var pending = removed.value;
        defer pending.deinit(self.allocator);

        const now = std.time.milliTimestamp();
        const node_id = try makeSequentialId(self.allocator, "node", &self.next_node_id);
        errdefer self.allocator.free(node_id);

        const node = Node{
            .id = node_id,
            .name = try self.allocator.dupe(u8, pending.node_name),
            .fs_url = try self.allocator.dupe(u8, pending.fs_url),
            .secret = try makeToken(self.allocator, "secret"),
            .lease_token = try makeToken(self.allocator, "lease"),
            .platform_os = try self.allocator.dupe(u8, pending.platform_os),
            .platform_arch = try self.allocator.dupe(u8, pending.platform_arch),
            .platform_runtime_kind = try self.allocator.dupe(u8, pending.platform_runtime_kind),
            .joined_at_ms = now,
            .last_seen_ms = now,
            .lease_expires_at_ms = now + @as(i64, @intCast(lease_ttl_ms)),
        };
        errdefer {
            self.allocator.free(node.name);
            self.allocator.free(node.fs_url);
            self.allocator.free(node.secret);
            self.allocator.free(node.lease_token);
            self.allocator.free(node.platform_os);
            self.allocator.free(node.platform_arch);
            self.allocator.free(node.platform_runtime_kind);
        }
        try self.nodes.put(self.allocator, node.id, node);
        self.node_joins_total +%= 1;
        self.persistSnapshotBestEffortLocked();
        std.log.info("control-plane pending join approved: request={s} node={s}", .{ request_id, node.id });
        return self.renderNodeJoinPayload(node.id);
    }

    pub fn denyPendingNodeJoin(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;

        const request_id = getRequiredString(obj, "request_id") catch return ControlPlaneError.MissingField;
        try validateIdentifier(request_id, 128);
        const removed = self.pending_joins.fetchRemove(request_id) orelse return ControlPlaneError.PendingJoinNotFound;
        var pending = removed.value;
        pending.deinit(self.allocator);

        self.persistSnapshotBestEffortLocked();
        const escaped_request = try jsonEscape(self.allocator, request_id);
        defer self.allocator.free(escaped_request);
        return std.fmt.allocPrint(
            self.allocator,
            "{{\"denied\":true,\"request_id\":\"{s}\"}}",
            .{escaped_request},
        );
    }

    pub fn nodeVenomUpsert(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;

        const node_id = getRequiredString(obj, "node_id") catch return ControlPlaneError.MissingField;
        const node_secret = getRequiredString(obj, "node_secret") catch return ControlPlaneError.MissingField;
        try validateIdentifier(node_id, 128);
        try validateSecretToken(node_secret, 256);

        const node = self.nodes.getPtr(node_id) orelse return ControlPlaneError.NodeNotFound;
        if (!std.mem.eql(u8, node.secret, node_secret)) return ControlPlaneError.NodeAuthFailed;

        var previous = std.ArrayListUnmanaged(NodeVenomDigest){};
        defer deinitNodeVenomDigests(self.allocator, &previous);
        try snapshotNodeVenomDigests(self.allocator, node.venoms.items, node.venom_package_ids.items, &previous);

        const prospective_runtime_kind = extractProspectiveNodeRuntimeKind(node, obj.get("platform")) catch return ControlPlaneError.InvalidPayload;
        if (obj.get("venoms")) |venoms_value| {
            var next_venoms = std.ArrayListUnmanaged(venom_catalog.VenomDescriptor){};
            defer venom_catalog.deinitVenoms(self.allocator, &next_venoms);
            var package_ids = std.ArrayListUnmanaged(?[]const u8){};
            defer package_ids.deinit(self.allocator);
            try collectNodeVenomPackageIds(self.allocator, venoms_value, &package_ids);
            venom_catalog.replaceVenomsFromJsonValue(self.allocator, &next_venoms, venoms_value) catch return ControlPlaneError.InvalidPayload;
            try validateNodeVenomCatalogLocked(self, node.fs_url, prospective_runtime_kind, next_venoms.items, package_ids.items);
            var owned_package_ids = try cloneNodeVenomPackageIds(self.allocator, package_ids.items);
            errdefer deinitNodeVenomPackageIds(self.allocator, &owned_package_ids);
            venom_catalog.deinitVenoms(self.allocator, &node.venoms);
            deinitNodeVenomPackageIds(self.allocator, &node.venom_package_ids);
            node.venoms = next_venoms;
            next_venoms = .{};
            node.venom_package_ids = owned_package_ids;
            owned_package_ids = .{};
        } else {
            try validateNodeVenomCatalogLocked(self, node.fs_url, prospective_runtime_kind, node.venoms.items, node.venom_package_ids.items);
        }

        if (obj.get("platform")) |platform_value| {
            applyPlatformUpdateFromValue(self.allocator, node, platform_value) catch return ControlPlaneError.InvalidPayload;
        }
        if (obj.get("labels")) |labels_value| {
            replaceNodeLabelsFromValue(self.allocator, &node.labels, labels_value) catch return ControlPlaneError.InvalidPayload;
        }

        var current = std.ArrayListUnmanaged(NodeVenomDigest){};
        defer deinitNodeVenomDigests(self.allocator, &current);
        try snapshotNodeVenomDigests(self.allocator, node.venoms.items, node.venom_package_ids.items, &current);
        const delta_json = try renderNodeVenomDeltaJson(self.allocator, &previous, &current);
        defer self.allocator.free(delta_json);

        const response_payload = try self.renderNodeVenomPayload(node_id, delta_json);
        errdefer self.allocator.free(response_payload);
        self.appendNodeVenomEventLocked(node_id, response_payload);
        self.persistSnapshotBestEffortLocked();
        return response_payload;
    }

    pub fn nodeVenomGet(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;

        const node_id = getRequiredString(obj, "node_id") catch return ControlPlaneError.MissingField;
        try validateIdentifier(node_id, 128);
        _ = self.nodes.get(node_id) orelse return ControlPlaneError.NodeNotFound;
        return self.renderNodeVenomPayload(node_id, null);
    }

    pub fn listVenomPackages(self: *ControlPlane) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return venom_packages.buildCombinedPackagesJson(self.allocator, self.installed_venom_packages.items);
    }

    pub fn listVenomReleases(self: *ControlPlane) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.renderInstalledVenomReleasesJsonLocked();
    }

    pub fn getVenomPackage(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;

        const venom_id = getRequiredString(obj, "venom_id") catch return ControlPlaneError.MissingField;
        try validateIdentifier(venom_id, 128);
        return self.renderSingleVenomPackageJsonLocked(venom_id);
    }

    pub fn getVenomRelease(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const package_id = getRequiredString(payload.value.object, "venom_id") catch return ControlPlaneError.MissingField;
        const release_version = getOptionalString(payload.value.object, "release_version");
        try validateIdentifier(package_id, 128);
        if (release_version) |value| try validateDisplayString(value, 64);
        return self.renderSingleInstalledVenomReleaseJsonLocked(package_id, release_version);
    }

    pub fn installVenomPackage(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();

        var release = try parseInstalledVenomReleaseValue(self.allocator, payload.value);
        errdefer release.deinit(self.allocator);

        if (venom_packages.findBuiltinPackage(release.package_id) != null) {
            return ControlPlaneError.VenomPackageBuiltinProtected;
        }
        for (self.installed_venom_releases.items) |installed| {
            if (!std.mem.eql(u8, installed.package_id, release.package_id)) continue;
            if (std.mem.eql(u8, installed.package.release_version, release.package.release_version)) {
                return ControlPlaneError.AlreadyExists;
            }
        }

        if (release.package.enabled) {
            for (self.installed_venom_releases.items) |*installed| {
                if (!std.mem.eql(u8, installed.package_id, release.package_id)) continue;
                installed.package.enabled = false;
            }
        }

        try self.installed_venom_releases.append(self.allocator, release);
        try rebuildInstalledVenomPackagesFromReleasesLocked(self);
        self.persistSnapshotBestEffortLocked();
        return self.renderSingleInstalledVenomPackageJsonLocked(release.package_id);
    }

    pub fn enableVenomPackage(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;

        const venom_id = getRequiredString(obj, "venom_id") catch return ControlPlaneError.MissingField;
        const release_version = getOptionalString(obj, "release_version");
        try validateIdentifier(venom_id, 128);
        if (venom_packages.findBuiltinPackage(venom_id) != null) {
            return ControlPlaneError.VenomPackageBuiltinProtected;
        }

        var matched = false;
        const target_index = if (release_version) |requested| blk: {
            var found_index: ?usize = null;
            for (self.installed_venom_releases.items, 0..) |installed, idx| {
                if (!std.mem.eql(u8, installed.package_id, venom_id)) continue;
                if (!std.mem.eql(u8, installed.package.release_version, requested)) continue;
                found_index = idx;
                break;
            }
            break :blk found_index;
        } else findPreferredInstalledReleaseIndex(self.installed_venom_releases.items, venom_id);

        if (target_index) |idx| {
            matched = true;
            for (self.installed_venom_releases.items) |*installed| {
                if (!std.mem.eql(u8, installed.package_id, venom_id)) continue;
                installed.package.enabled = false;
            }
            self.installed_venom_releases.items[idx].package.enabled = true;
        }

        if (matched) {
            try rebuildInstalledVenomPackagesFromReleasesLocked(self);
            self.persistSnapshotBestEffortLocked();
            return self.renderSingleInstalledVenomPackageJsonLocked(venom_id);
        }
        return ControlPlaneError.VenomPackageNotFound;
    }

    pub fn disableVenomPackage(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;

        const venom_id = getRequiredString(obj, "venom_id") catch return ControlPlaneError.MissingField;
        const release_version = getOptionalString(obj, "release_version");
        try validateIdentifier(venom_id, 128);
        if (venom_packages.findBuiltinPackage(venom_id) != null) {
            return ControlPlaneError.VenomPackageBuiltinProtected;
        }

        var matched = false;
        for (self.installed_venom_releases.items) |*installed| {
            if (!std.mem.eql(u8, installed.package_id, venom_id)) continue;
            if (release_version) |requested| {
                if (!std.mem.eql(u8, installed.package.release_version, requested)) continue;
            }
            installed.package.enabled = false;
            matched = true;
            if (release_version != null) break;
        }
        if (matched) {
            try rebuildInstalledVenomPackagesFromReleasesLocked(self);
            self.persistSnapshotBestEffortLocked();
            return self.renderSingleInstalledVenomPackageJsonLocked(venom_id);
        }
        return ControlPlaneError.VenomPackageNotFound;
    }

    pub fn removeVenomPackage(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;

        const venom_id = getRequiredString(obj, "venom_id") catch return ControlPlaneError.MissingField;
        const release_version = getOptionalString(obj, "release_version");
        try validateIdentifier(venom_id, 128);
        if (venom_packages.findBuiltinPackage(venom_id) != null) {
            return ControlPlaneError.VenomPackageBuiltinProtected;
        }

        var removed_any = false;
        var idx: usize = 0;
        while (idx < self.installed_venom_releases.items.len) {
            const installed = self.installed_venom_releases.items[idx];
            if (!std.mem.eql(u8, installed.package_id, venom_id)) {
                idx += 1;
                continue;
            }
            if (release_version) |requested| {
                if (!std.mem.eql(u8, installed.package.release_version, requested)) {
                    idx += 1;
                    continue;
                }
            }
            var removed = self.installed_venom_releases.orderedRemove(idx);
            removed.deinit(self.allocator);
            removed_any = true;
            if (release_version != null) break;
        }

        if (removed_any) {
            try rebuildInstalledVenomPackagesFromReleasesLocked(self);
            self.persistSnapshotBestEffortLocked();
            const escaped_id = try jsonEscape(self.allocator, venom_id);
            defer self.allocator.free(escaped_id);
            const release_version_json = try optionalJsonStringField(self.allocator, release_version);
            defer self.allocator.free(release_version_json);
            return std.fmt.allocPrint(
                self.allocator,
                "{{\"removed\":true,\"venom_id\":\"{s}\",\"release_version\":{s}}}",
                .{ escaped_id, release_version_json },
            );
        }
        return ControlPlaneError.VenomPackageNotFound;
    }

    pub fn rollbackVenomPackage(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;

        const venom_id = getRequiredString(obj, "venom_id") catch return ControlPlaneError.MissingField;
        const release_version = getOptionalString(obj, "release_version");
        try validateIdentifier(venom_id, 128);
        if (release_version) |value| try validateDisplayString(value, 64);
        if (venom_packages.findBuiltinPackage(venom_id) != null) {
            return ControlPlaneError.VenomPackageBuiltinProtected;
        }

        const target_index = if (release_version) |requested|
            findInstalledReleaseIndex(self.installed_venom_releases.items, venom_id, requested)
        else
            findRollbackInstalledReleaseIndex(self.installed_venom_releases.items, venom_id);

        const idx = target_index orelse return ControlPlaneError.VenomPackageNotFound;

        for (self.installed_venom_releases.items) |*installed| {
            if (!std.mem.eql(u8, installed.package_id, venom_id)) continue;
            installed.package.enabled = false;
        }
        self.installed_venom_releases.items[idx].package.enabled = true;

        try rebuildInstalledVenomPackagesFromReleasesLocked(self);
        self.persistSnapshotBestEffortLocked();
        return self.renderSingleInstalledVenomPackageJsonLocked(venom_id);
    }

    pub fn cloneVenomPackage(
        self: *ControlPlane,
        allocator: std.mem.Allocator,
        venom_id: []const u8,
    ) !?venom_package_model.VenomPackage {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (try cloneVenomPackageLocked(self, allocator, venom_id)) |package| {
            return package;
        }
        return null;
    }

    pub fn validateRuntimeVenomInstantiation(
        self: *ControlPlane,
        requested_venoms: []const []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const runtime_host_capabilities = [_][]const u8{
            "external_runtime",
            "filesystem_loopback",
        };
        for (requested_venoms) |venom_id| {
            const package = lookupVenomPackageLocked(self, venom_id) orelse return ControlPlaneError.VenomPackageNotFound;
            try validateVenomPackageInstantiationLocked(
                self.allocator,
                package,
                "client",
                "runtime_private",
                requested_venoms,
                runtime_host_capabilities[0..],
                "{\"type\":\"external_runtime\"}",
            );
        }
    }

    pub fn resolvePreferredVenomProvider(
        self: *ControlPlane,
        allocator: std.mem.Allocator,
        venom_id: []const u8,
        preferred_node_names: []const []const u8,
    ) !?PreferredVenomProvider {
        return self.resolvePreferredVenomProviderForContext(allocator, venom_id, preferred_node_names, null, null);
    }

    pub fn resolvePreferredVenomProviderForContext(
        self: *ControlPlane,
        allocator: std.mem.Allocator,
        venom_id: []const u8,
        preferred_node_names: []const []const u8,
        workspace_id: ?[]const u8,
        agent_id: ?[]const u8,
    ) !?PreferredVenomProvider {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        return self.resolvePreferredVenomProviderForContextLocked(
            allocator,
            venom_id,
            preferred_node_names,
            workspace_id,
            agent_id,
            .{},
        );
    }

    fn resolvePreferredVenomProviderForContextLocked(
        self: *ControlPlane,
        allocator: std.mem.Allocator,
        venom_id: []const u8,
        preferred_node_names: []const []const u8,
        workspace_id: ?[]const u8,
        agent_id: ?[]const u8,
        constraints: PreferredVenomProviderConstraints,
    ) !?PreferredVenomProvider {
        if (venom_id.len == 0) return null;

        if (try self.cloneExplicitPreferredVenomProviderLocked(allocator, venom_id, .agent, agent_id, constraints)) |provider| {
            return provider;
        }
        if (try self.cloneExplicitPreferredVenomProviderLocked(allocator, venom_id, .project, workspace_id, constraints)) |provider| {
            return provider;
        }
        if (try self.cloneExplicitPreferredVenomProviderLocked(allocator, venom_id, .global, null, constraints)) |provider| {
            return provider;
        }

        for (preferred_node_names) |preferred_name| {
            if (preferred_name.len == 0) continue;
            if (try self.clonePreferredVenomProviderLocked(allocator, venom_id, preferred_name, true, constraints)) |provider| {
                return provider;
            }
        }
        return try self.clonePreferredVenomProviderLocked(allocator, venom_id, "", false, constraints);
    }

    pub fn resolveExplicitPreferredVenomProvider(
        self: *ControlPlane,
        allocator: std.mem.Allocator,
        venom_id: []const u8,
    ) !?PreferredVenomProvider {
        return self.resolveExplicitPreferredVenomProviderForScope(allocator, venom_id, .global, null);
    }

    fn resolveExplicitPreferredVenomProviderForScope(
        self: *ControlPlane,
        allocator: std.mem.Allocator,
        venom_id: []const u8,
        scope: PreferredVenomBindingScope,
        scope_id: ?[]const u8,
    ) !?PreferredVenomProvider {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());
        if (venom_id.len == 0) return null;
        return try self.cloneExplicitPreferredVenomProviderLocked(allocator, venom_id, scope, scope_id, .{});
    }

    pub fn bindPreferredVenomProvider(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;

        const venom_id = getRequiredString(obj, "venom_id") catch return ControlPlaneError.MissingField;
        try validateIdentifier(venom_id, 128);
        const node_id = getOptionalString(obj, "node_id");
        const scope = PreferredVenomBindingScope.fromString(getOptionalString(obj, "scope") orelse "global") orelse
            return ControlPlaneError.InvalidPayload;
        const workspace_id = getOptionalString(obj, "workspace_id");
        const agent_id = getOptionalString(obj, "agent_id");
        const scope_id = switch (scope) {
            .global => blk: {
                if (workspace_id != null or agent_id != null) return ControlPlaneError.InvalidPayload;
                break :blk null;
            },
            .project => blk: {
                const project = workspace_id orelse return ControlPlaneError.MissingField;
                if (agent_id != null) return ControlPlaneError.InvalidPayload;
                try validateIdentifier(project, 128);
                _ = self.workspaces.get(project) orelse return ControlPlaneError.WorkspaceNotFound;
                break :blk project;
            },
            .agent => blk: {
                const agent = agent_id orelse return ControlPlaneError.MissingField;
                if (workspace_id != null) return ControlPlaneError.InvalidPayload;
                try validateIdentifier(agent, 128);
                break :blk agent;
            },
        };
        const preferred_key = try self.preferredVenomBindingKeyLocked(scope, scope_id, venom_id);
        defer self.allocator.free(preferred_key);

        if (node_id) |selected_node_id| {
            try validateIdentifier(selected_node_id, 128);
            const node = self.nodes.getPtr(selected_node_id) orelse return ControlPlaneError.NodeNotFound;
            _ = findNodeVenom(node, venom_id) orelse return ControlPlaneError.NodeNotFound;

            const venom_key = try self.allocator.dupe(u8, preferred_key);
            errdefer self.allocator.free(venom_key);
            const node_value = try self.allocator.dupe(u8, selected_node_id);
            errdefer self.allocator.free(node_value);
            const entry = try self.preferred_venom_provider_by_scope_venom.getOrPut(self.allocator, venom_key);
            if (entry.found_existing) {
                self.allocator.free(venom_key);
                self.allocator.free(entry.value_ptr.*);
                entry.value_ptr.* = node_value;
            } else {
                entry.value_ptr.* = node_value;
            }
        } else if (self.preferred_venom_provider_by_scope_venom.fetchRemove(preferred_key)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value);
        }

        const node_json = if (node_id) |value|
            try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{value})
        else
            try self.allocator.dupe(u8, "null");
        defer self.allocator.free(node_json);
        const scope_id_json = if (scope_id) |value|
            try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{value})
        else
            try self.allocator.dupe(u8, "null");
        defer self.allocator.free(scope_id_json);
        return std.fmt.allocPrint(
            self.allocator,
            "{{\"venom_id\":\"{s}\",\"scope\":\"{s}\",\"scope_id\":{s},\"node_id\":{s}}}",
            .{ venom_id, scope.asString(), scope_id_json, node_json },
        );
    }

    pub fn nodeJoin(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;

        const invite_token = getRequiredString(obj, "invite_token") catch return ControlPlaneError.MissingField;
        const node_name_raw = getOptionalString(obj, "node_name");
        const fs_url_raw = getOptionalString(obj, "fs_url") orelse "";
        const lease_ttl_ms = getOptionalUnsigned(obj, "lease_ttl_ms", 15 * 60 * 1000) catch return ControlPlaneError.InvalidPayload;
        const now = std.time.milliTimestamp();
        if (node_name_raw) |name| try validateIdentifier(name, 128);
        if (fs_url_raw.len > 0) try validateFsUrl(fs_url_raw);

        var matched: ?*Invite = null;
        var invite_it = self.invites.valueIterator();
        while (invite_it.next()) |invite| {
            if (std.mem.eql(u8, invite.token, invite_token)) {
                matched = invite;
                break;
            }
        }
        const invite = matched orelse return ControlPlaneError.InviteNotFound;
        if (invite.redeemed) return ControlPlaneError.InviteRedeemed;
        if (invite.expires_at_ms <= now) return ControlPlaneError.InviteExpired;
        invite.redeemed = true;
        self.invites_redeemed_total +%= 1;

        const node_id = try makeSequentialId(self.allocator, "node", &self.next_node_id);
        errdefer self.allocator.free(node_id);
        const node_name = if (node_name_raw) |name|
            try self.allocator.dupe(u8, name)
        else
            try self.allocator.dupe(u8, node_id);
        errdefer self.allocator.free(node_name);
        const fs_url = try self.allocator.dupe(u8, fs_url_raw);
        errdefer self.allocator.free(fs_url);
        const node_secret = try makeToken(self.allocator, "secret");
        errdefer self.allocator.free(node_secret);
        const lease_token = try makeToken(self.allocator, "lease");
        errdefer self.allocator.free(lease_token);
        const platform_os = try self.allocator.dupe(u8, default_platform_os);
        errdefer self.allocator.free(platform_os);
        const platform_arch = try self.allocator.dupe(u8, default_platform_arch);
        errdefer self.allocator.free(platform_arch);
        const platform_runtime_kind = try self.allocator.dupe(u8, default_platform_runtime_kind);
        errdefer self.allocator.free(platform_runtime_kind);

        const node = Node{
            .id = node_id,
            .name = node_name,
            .fs_url = fs_url,
            .secret = node_secret,
            .lease_token = lease_token,
            .platform_os = platform_os,
            .platform_arch = platform_arch,
            .platform_runtime_kind = platform_runtime_kind,
            .joined_at_ms = now,
            .last_seen_ms = now,
            .lease_expires_at_ms = now + @as(i64, @intCast(lease_ttl_ms)),
        };
        try self.nodes.put(self.allocator, node.id, node);
        self.node_joins_total +%= 1;
        self.persistSnapshotBestEffortLocked();
        std.log.info("control-plane node joined: id={s} name={s} fs_url={s}", .{ node.id, node.name, node.fs_url });

        return self.renderNodeJoinPayload(node.id);
    }

    pub fn nodeEnsure(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;

        const node_name = getRequiredString(obj, "node_name") catch return ControlPlaneError.MissingField;
        const fs_url = getOptionalString(obj, "fs_url") orelse "";
        const lease_ttl_ms = getOptionalUnsigned(obj, "lease_ttl_ms", 15 * 60 * 1000) catch return ControlPlaneError.InvalidPayload;
        return self.ensureNode(node_name, fs_url, lease_ttl_ms);
    }

    pub fn refreshNodeLease(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;

        const node_id = getRequiredString(obj, "node_id") catch return ControlPlaneError.MissingField;
        const node_secret = getRequiredString(obj, "node_secret") catch return ControlPlaneError.MissingField;
        const lease_ttl_ms = getOptionalUnsigned(obj, "lease_ttl_ms", 15 * 60 * 1000) catch return ControlPlaneError.InvalidPayload;
        try validateIdentifier(node_id, 128);
        try validateSecretToken(node_secret, 256);

        const node = self.nodes.getPtr(node_id) orelse return ControlPlaneError.NodeNotFound;
        if (!std.mem.eql(u8, node.secret, node_secret)) return ControlPlaneError.NodeAuthFailed;

        if (getOptionalString(obj, "fs_url")) |next_fs_url| {
            try validateFsUrl(next_fs_url);
            self.allocator.free(node.fs_url);
            node.fs_url = try self.allocator.dupe(u8, next_fs_url);
        }

        self.allocator.free(node.lease_token);
        node.lease_token = try makeToken(self.allocator, "lease");
        node.last_seen_ms = std.time.milliTimestamp();
        node.lease_expires_at_ms = node.last_seen_ms + @as(i64, @intCast(lease_ttl_ms));
        self.node_lease_refresh_total +%= 1;
        self.persistSnapshotBestEffortLocked();
        std.log.info("control-plane node lease refreshed: id={s} expires_at={d}", .{ node.id, node.lease_expires_at_ms });

        return self.renderNodeJoinPayload(node.id);
    }

    pub fn authenticateNodeSession(self: *ControlPlane, node_id: []const u8, node_secret: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        try validateIdentifier(node_id, 128);
        try validateSecretToken(node_secret, 256);
        const node = self.nodes.getPtr(node_id) orelse return ControlPlaneError.NodeNotFound;
        if (!secureTokenEql(node.secret, node_secret)) return ControlPlaneError.NodeAuthFailed;
        node.last_seen_ms = std.time.milliTimestamp();
    }

    pub fn copyNodeSecret(self: *ControlPlane, allocator: std.mem.Allocator, node_id: []const u8) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        try validateIdentifier(node_id, 128);
        const node = self.nodes.get(node_id) orelse return null;
        return try allocator.dupe(u8, node.secret);
    }

    pub fn ensureNode(
        self: *ControlPlane,
        node_name: []const u8,
        fs_url: []const u8,
        lease_ttl_ms: u64,
    ) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        if (node_name.len == 0) return ControlPlaneError.InvalidPayload;
        try validateIdentifier(node_name, 128);
        if (fs_url.len > 0) try validateFsUrl(fs_url);

        const now = std.time.milliTimestamp();
        var existing_node: ?*Node = null;
        var node_it = self.nodes.valueIterator();
        while (node_it.next()) |node| {
            if (!std.mem.eql(u8, node.name, node_name)) continue;
            existing_node = node;
            break;
        }

        if (existing_node) |node| {
            self.allocator.free(node.fs_url);
            node.fs_url = try self.allocator.dupe(u8, fs_url);

            self.allocator.free(node.lease_token);
            node.lease_token = try makeToken(self.allocator, "lease");
            node.last_seen_ms = now;
            node.lease_expires_at_ms = now + @as(i64, @intCast(lease_ttl_ms));
            self.nodes_ensured_total +%= 1;
            self.persistSnapshotBestEffortLocked();
            std.log.info("control-plane node ensured (existing): id={s} name={s} fs_url={s}", .{ node.id, node.name, node.fs_url });

            return self.renderNodeJoinPayload(node.id);
        }

        const node_id = try makeSequentialId(self.allocator, "node", &self.next_node_id);
        errdefer self.allocator.free(node_id);
        const node = Node{
            .id = node_id,
            .name = try self.allocator.dupe(u8, node_name),
            .fs_url = try self.allocator.dupe(u8, fs_url),
            .secret = try makeToken(self.allocator, "secret"),
            .lease_token = try makeToken(self.allocator, "lease"),
            .platform_os = try self.allocator.dupe(u8, default_platform_os),
            .platform_arch = try self.allocator.dupe(u8, default_platform_arch),
            .platform_runtime_kind = try self.allocator.dupe(u8, default_platform_runtime_kind),
            .joined_at_ms = now,
            .last_seen_ms = now,
            .lease_expires_at_ms = now + @as(i64, @intCast(lease_ttl_ms)),
        };
        errdefer {
            self.allocator.free(node.name);
            self.allocator.free(node.fs_url);
            self.allocator.free(node.secret);
            self.allocator.free(node.lease_token);
            self.allocator.free(node.platform_os);
            self.allocator.free(node.platform_arch);
            self.allocator.free(node.platform_runtime_kind);
        }
        try self.nodes.put(self.allocator, node.id, node);
        self.nodes_ensured_total +%= 1;
        self.persistSnapshotBestEffortLocked();
        std.log.info("control-plane node ensured (new): id={s} name={s} fs_url={s}", .{ node.id, node.name, node.fs_url });

        return self.renderNodeJoinPayload(node.id);
    }

    pub fn listNodes(self: *ControlPlane) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.allocator);

        try out.appendSlice(self.allocator, "{\"nodes\":[");
        var first = true;
        var it = self.nodes.valueIterator();
        while (it.next()) |node| {
            if (!first) try out.append(self.allocator, ',');
            first = false;
            try appendNodeJson(self.allocator, &out, node.*);
        }
        try out.appendSlice(self.allocator, "]}");
        return out.toOwnedSlice(self.allocator);
    }

    pub fn getNode(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;
        const node_id = getRequiredString(obj, "node_id") catch return ControlPlaneError.MissingField;
        const node = self.nodes.get(node_id) orelse return ControlPlaneError.NodeNotFound;

        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "{\"node\":");
        try appendNodeJson(self.allocator, &out, node);
        try out.appendSlice(self.allocator, "}");
        return out.toOwnedSlice(self.allocator);
    }

    pub fn deleteNode(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;
        const node_id = getRequiredString(obj, "node_id") catch return ControlPlaneError.MissingField;
        const node_secret = getRequiredString(obj, "node_secret") catch return ControlPlaneError.MissingField;
        try validateIdentifier(node_id, 128);
        try validateSecretToken(node_secret, 256);

        const node = self.nodes.get(node_id) orelse return ControlPlaneError.NodeNotFound;
        if (!std.mem.eql(u8, node.secret, node_secret)) return ControlPlaneError.NodeAuthFailed;

        try self.deleteNodeByIdLocked(node_id, std.time.milliTimestamp());

        const escaped_id = try jsonEscape(self.allocator, node_id);
        defer self.allocator.free(escaped_id);
        return std.fmt.allocPrint(self.allocator, "{{\"deleted\":true,\"node_id\":\"{s}\"}}", .{escaped_id});
    }

    pub fn unregisterNodeById(self: *ControlPlane, node_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());
        try self.deleteNodeByIdLocked(node_id, std.time.milliTimestamp());
    }

    pub fn createWorkspace(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;

        const name_raw = getRequiredString(obj, "name") catch return ControlPlaneError.MissingField;
        const vision_raw = getRequiredString(obj, "vision") catch return ControlPlaneError.MissingField;
        const status_raw = getOptionalString(obj, "status") orelse "active";
        const template_id_raw = getOptionalString(obj, "template_id") orelse default_project_template_id;
        const now = std.time.milliTimestamp();
        try self.ensureBuiltinHostProjectLocked(now);
        try validateDisplayString(name_raw, 128);
        try validateIdentifier(status_raw, 64);
        try validateDisplayString(vision_raw, 1024);
        _ = resolveProjectTemplateSpec(template_id_raw) orelse return ControlPlaneError.InvalidPayload;

        var access_policy: WorkspaceAccessPolicy = .{};
        errdefer access_policy.deinit(self.allocator);
        if (obj.get("access_policy")) |value| {
            access_policy = try parseWorkspaceAccessPolicyValue(self.allocator, value);
        }

        const workspace_id = try makeSequentialId(self.allocator, "ws", &self.next_workspace_id);
        errdefer self.allocator.free(workspace_id);
        const mutation_token = try makeToken(self.allocator, "ws");
        errdefer self.allocator.free(mutation_token);

        const project = Workspace{
            .id = workspace_id,
            .name = try self.allocator.dupe(u8, name_raw),
            .vision = try self.allocator.dupe(u8, vision_raw),
            .status = try self.allocator.dupe(u8, status_raw),
            .template_id = try self.allocator.dupe(u8, template_id_raw),
            .token_locked = false,
            .mutation_token = mutation_token,
            .access_policy = access_policy,
            .created_at_ms = now,
            .updated_at_ms = now,
        };
        errdefer {
            self.allocator.free(project.name);
            self.allocator.free(project.vision);
            self.allocator.free(project.status);
            self.allocator.free(project.template_id);
            self.allocator.free(project.mutation_token);
        }
        try self.workspaces.put(self.allocator, project.id, project);
        const stored_project = self.workspaces.getPtr(workspace_id) orelse return error.WorkspaceNotFound;
        var project_changed = false;
        if (try ensureDefaultWorkspaceMountsLocked(self, stored_project)) {
            project_changed = true;
        }
        if (try ensureWorkspaceTemplateBindsLocked(self, stored_project)) {
            project_changed = true;
        }
        if (project_changed) {
            stored_project.updated_at_ms = now;
            self.mount_sets_total +%= 1;
            self.requestReconcileLocked(now);
            _ = try self.runReconcileCycleLocked(now, false);
        }
        self.workspace_creates_total +%= 1;
        self.persistSnapshotBestEffortLocked();

        return renderWorkspacePayload(self.allocator, stored_project.*, true);
    }

    pub fn updateWorkspace(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        return self.updateWorkspaceWithRole(payload_json, false);
    }

    pub fn updateWorkspaceWithRole(self: *ControlPlane, payload_json: ?[]const u8, is_admin: bool) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;
        const workspace_id = getRequiredString(obj, "workspace_id") catch return ControlPlaneError.MissingField;
        try validateIdentifier(workspace_id, 128);
        const workspace_token = getOptionalString(obj, "workspace_token");
        const project = try getPublicWorkspacePtrLocked(self, workspace_id);
        try requireWorkspaceAccessToken(project, workspace_token, is_admin);
        const next_name = getOptionalString(obj, "name");
        const next_vision = getOptionalString(obj, "vision");
        const next_status = getOptionalString(obj, "status");
        const next_access_policy = obj.get("access_policy");

        if (next_name) |value| {
            try validateDisplayString(value, 128);
            self.allocator.free(project.name);
            project.name = try self.allocator.dupe(u8, value);
        }
        if (next_vision) |value| {
            try validateDisplayString(value, 1024);
            self.allocator.free(project.vision);
            project.vision = try self.allocator.dupe(u8, value);
        }
        if (next_status) |value| {
            try validateIdentifier(value, 64);
            self.allocator.free(project.status);
            project.status = try self.allocator.dupe(u8, value);
        }
        if (next_access_policy) |value| {
            var parsed_policy = try parseWorkspaceAccessPolicyValue(self.allocator, value);
            errdefer parsed_policy.deinit(self.allocator);
            project.access_policy.deinit(self.allocator);
            project.access_policy = parsed_policy;
        }
        project.updated_at_ms = std.time.milliTimestamp();
        self.workspace_updates_total +%= 1;
        self.persistSnapshotBestEffortLocked();

        return renderWorkspacePayload(self.allocator, project.*, false);
    }

    pub fn deleteWorkspace(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        return self.deleteWorkspaceWithRole(payload_json, false);
    }

    pub fn deleteWorkspaceWithRole(self: *ControlPlane, payload_json: ?[]const u8, is_admin: bool) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;
        const workspace_id = getRequiredString(obj, "workspace_id") catch return ControlPlaneError.MissingField;
        try validateIdentifier(workspace_id, 128);
        const workspace_token = getOptionalString(obj, "workspace_token");

        const existing_project = try getPublicWorkspaceLocked(self, workspace_id);
        if (existing_project.is_delete_protected) return ControlPlaneError.WorkspaceProtected;
        try requireWorkspaceAccessToken(&existing_project, workspace_token, is_admin);
        const removed = self.workspaces.fetchRemove(workspace_id) orelse return ControlPlaneError.WorkspaceNotFound;
        var project = removed.value;
        defer project.deinit(self.allocator);

        var active_it = self.active_workspace_by_agent.iterator();
        while (active_it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.*, workspace_id)) {
                self.allocator.free(entry.value_ptr.*);
                entry.value_ptr.* = try self.allocator.dupe(u8, "");
            }
        }
        self.workspace_deletes_total +%= 1;
        self.persistSnapshotBestEffortLocked();

        const escaped = try jsonEscape(self.allocator, workspace_id);
        defer self.allocator.free(escaped);
        return std.fmt.allocPrint(self.allocator, "{{\"deleted\":true,\"workspace_id\":\"{s}\"}}", .{escaped});
    }

    pub fn listWorkspaces(self: *ControlPlane) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "{\"workspaces\":[");
        var first = true;
        var it = self.workspaces.valueIterator();
        while (it.next()) |project| {
            if (project.kind == .host_internal) continue;
            if (!first) try out.append(self.allocator, ',');
            first = false;
            try appendProjectSummaryJson(self.allocator, &out, project.*);
        }
        try out.appendSlice(self.allocator, "]}");
        return out.toOwnedSlice(self.allocator);
    }

    pub fn removeHostMount(
        self: *ControlPlane,
        mount_path_raw: []const u8,
        node_id_filter: ?[]const u8,
        export_name_filter: ?[]const u8,
    ) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now_ms = std.time.milliTimestamp();
        _ = self.reapExpiredLeasesLocked(now_ms);
        try self.ensureBuiltinHostProjectLocked(now_ms);
        if ((node_id_filter == null) != (export_name_filter == null)) return ControlPlaneError.MissingField;
        if (node_id_filter) |node_id| try validateIdentifier(node_id, 128);
        if (export_name_filter) |export_name| try validateExportName(export_name);

        const mount_path = try normalizeMountPath(self.allocator, mount_path_raw);
        defer self.allocator.free(mount_path);
        const project = try getHostWorkspacePtrLocked(self);
        const removed_count = removeWorkspaceMountEntriesLocked(
            self.allocator,
            project,
            mount_path,
            node_id_filter,
            export_name_filter,
        );
        if (removed_count == 0) return false;
        project.updated_at_ms = now_ms;
        self.mount_removes_total +%= removed_count;
        self.persistSnapshotBestEffortLocked();
        return true;
    }

    pub fn listWorkspaceTemplates(self: *ControlPlane) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "{\"templates\":[");
        for (builtin_workspace_templates, 0..) |template, idx| {
            if (idx != 0) try out.append(self.allocator, ',');
            try appendWorkspaceTemplateJson(self.allocator, &out, template);
        }
        try out.appendSlice(self.allocator, "]}");
        return out.toOwnedSlice(self.allocator);
    }

    pub fn getWorkspaceTemplate(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;
        const template_id = getRequiredString(obj, "template_id") catch return ControlPlaneError.MissingField;
        const template = resolveProjectTemplateSpec(template_id) orelse return ControlPlaneError.TemplateNotFound;

        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "{\"template\":");
        try appendWorkspaceTemplateJson(self.allocator, &out, template);
        try out.appendSlice(self.allocator, "}");
        return out.toOwnedSlice(self.allocator);
    }

    /// Resolve a deterministic "first" agent for a project from active bindings.
    /// Current ordering is lexical `agent_id` to keep selection stable across restarts.
    pub fn firstWorkspaceAgent(self: *ControlPlane, workspace_id: []const u8, include_primary: bool) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());
        if (!self.workspaces.contains(workspace_id)) return ControlPlaneError.WorkspaceNotFound;

        var selected: ?[]const u8 = null;
        var it = self.active_workspace_by_agent.iterator();
        while (it.next()) |entry| {
            const agent_id = entry.key_ptr.*;
            const active_project = entry.value_ptr.*;
            if (!std.mem.eql(u8, active_project, workspace_id)) continue;
            if (!include_primary and std.mem.eql(u8, agent_id, self.host_actor_id)) continue;
            if (selected == null or std.mem.lessThan(u8, agent_id, selected.?)) {
                selected = agent_id;
            }
        }
        if (selected) |agent_id| {
            const owned = try self.allocator.dupe(u8, agent_id);
            return owned;
        }
        return null;
    }

    pub fn agentActiveInWorkspace(self: *ControlPlane, agent_id: []const u8, workspace_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());
        const active_project_id = self.active_workspace_by_agent.get(agent_id) orelse return false;
        return std.mem.eql(u8, active_project_id, workspace_id);
    }

    pub fn workspaceHasMounts(self: *ControlPlane, workspace_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());
        const project = getPublicWorkspaceLocked(self, workspace_id) catch return false;
        return project.mounts.items.len > 0;
    }

    pub fn hostHasMounts(self: *ControlPlane) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());
        return hostWorkspaceHasMountsLocked(self);
    }

    pub fn snapshotActiveWorkspaceBindings(
        self: *ControlPlane,
        allocator: std.mem.Allocator,
        include_primary: bool,
    ) ![]ActiveWorkspaceBinding {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var bindings = std.ArrayListUnmanaged(ActiveWorkspaceBinding){};
        errdefer {
            for (bindings.items) |*item| item.deinit(allocator);
            bindings.deinit(allocator);
        }

        var it = self.active_workspace_by_agent.iterator();
        while (it.next()) |entry| {
            const agent_id = entry.key_ptr.*;
            const workspace_id = entry.value_ptr.*;
            if (workspace_id.len == 0) continue;
            if (!include_primary and std.mem.eql(u8, agent_id, self.host_actor_id)) continue;
            if (!self.workspaces.contains(workspace_id)) continue;

            try bindings.append(allocator, .{
                .agent_id = try allocator.dupe(u8, agent_id),
                .workspace_id = try allocator.dupe(u8, workspace_id),
            });
        }

        return bindings.toOwnedSlice(allocator);
    }

    pub fn getWorkspace(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        return self.getWorkspaceWithRole(payload_json, false);
    }

    pub fn getWorkspaceWithRole(self: *ControlPlane, payload_json: ?[]const u8, is_admin: bool) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;
        const workspace_id = getRequiredString(obj, "workspace_id") catch return ControlPlaneError.MissingField;
        const workspace_token = getOptionalString(obj, "workspace_token");
        const project = try getPublicWorkspaceLocked(self, workspace_id);
        try requireWorkspaceActionAccess(&project, .read, null, workspace_token, is_admin);

        return renderWorkspacePayload(self.allocator, project, false);
    }

    pub fn setWorkspaceMount(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        return self.setWorkspaceMountWithRole(payload_json, false);
    }

    pub fn setWorkspaceMountWithRole(self: *ControlPlane, payload_json: ?[]const u8, is_admin: bool) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;

        const workspace_id = getRequiredString(obj, "workspace_id") catch return ControlPlaneError.MissingField;
        const workspace_token = getOptionalString(obj, "workspace_token");
        const node_id = getRequiredString(obj, "node_id") catch return ControlPlaneError.MissingField;
        const export_name = getRequiredString(obj, "export_name") catch return ControlPlaneError.MissingField;
        const mount_path_raw = getRequiredString(obj, "mount_path") catch return ControlPlaneError.MissingField;
        try validateIdentifier(workspace_id, 128);
        try validateIdentifier(node_id, 128);
        try validateExportName(export_name);

        if (!self.nodes.contains(node_id)) return ControlPlaneError.NodeNotFound;
        const project = try getPublicWorkspacePtrLocked(self, workspace_id);
        try requireWorkspaceActionAccess(project, .mount, null, workspace_token, is_admin);

        const mount_path = try normalizeMountPath(self.allocator, mount_path_raw);
        errdefer self.allocator.free(mount_path);
        for (project.mounts.items) |existing| {
            if (std.mem.eql(u8, existing.mount_path, mount_path)) {
                if (std.mem.eql(u8, existing.node_id, node_id) and std.mem.eql(u8, existing.export_name, export_name)) {
                    self.allocator.free(mount_path);
                    return renderWorkspacePayload(self.allocator, project.*, false);
                }
                // Exact same mount path on different nodes is a failover group and is allowed.
                continue;
            }
            if (mountPathsOverlap(existing.mount_path, mount_path)) return ControlPlaneError.MountConflict;
        }
        for (project.binds.items) |existing_bind| {
            if (pathsConflict(existing_bind.bind_path, mount_path)) return ControlPlaneError.MountConflict;
        }

        try project.mounts.append(self.allocator, .{
            .mount_path = mount_path,
            .node_id = try self.allocator.dupe(u8, node_id),
            .export_name = try self.allocator.dupe(u8, export_name),
        });
        project.updated_at_ms = std.time.milliTimestamp();
        self.mount_sets_total +%= 1;
        self.persistSnapshotBestEffortLocked();
        std.log.info(
            "control-plane mount set: project={s} node={s} export={s} path={s}",
            .{ workspace_id, node_id, export_name, mount_path },
        );

        return renderWorkspacePayload(self.allocator, project.*, false);
    }

    pub fn removeWorkspaceMount(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        return self.removeWorkspaceMountWithRole(payload_json, false);
    }

    pub fn removeWorkspaceMountWithRole(self: *ControlPlane, payload_json: ?[]const u8, is_admin: bool) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;

        const workspace_id = getRequiredString(obj, "workspace_id") catch return ControlPlaneError.MissingField;
        const workspace_token = getOptionalString(obj, "workspace_token");
        const mount_path_raw = getRequiredString(obj, "mount_path") catch return ControlPlaneError.MissingField;
        const node_id_filter = getOptionalString(obj, "node_id");
        const export_name_filter = getOptionalString(obj, "export_name");
        try validateIdentifier(workspace_id, 128);
        if ((node_id_filter == null) != (export_name_filter == null)) return ControlPlaneError.MissingField;
        if (node_id_filter) |node_id| try validateIdentifier(node_id, 128);
        if (export_name_filter) |export_name| try validateExportName(export_name);
        const mount_path = try normalizeMountPath(self.allocator, mount_path_raw);
        defer self.allocator.free(mount_path);

        const project = try getPublicWorkspacePtrLocked(self, workspace_id);
        try requireWorkspaceActionAccess(project, .mount, null, workspace_token, is_admin);
        const removed_count = removeWorkspaceMountEntriesLocked(
            self.allocator,
            project,
            mount_path,
            node_id_filter,
            export_name_filter,
        );
        if (removed_count == 0) return ControlPlaneError.MountNotFound;
        project.updated_at_ms = std.time.milliTimestamp();
        self.mount_removes_total +%= removed_count;
        self.persistSnapshotBestEffortLocked();

        return renderWorkspacePayload(self.allocator, project.*, false);
    }

    pub fn listWorkspaceMounts(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        return self.listWorkspaceMountsWithRole(payload_json, false);
    }

    pub fn listWorkspaceMountsWithRole(self: *ControlPlane, payload_json: ?[]const u8, is_admin: bool) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;
        const workspace_id = getRequiredString(obj, "workspace_id") catch return ControlPlaneError.MissingField;
        const workspace_token = getOptionalString(obj, "workspace_token");
        const project = try getPublicWorkspaceLocked(self, workspace_id);
        try requireWorkspaceActionAccess(&project, .read, null, workspace_token, is_admin);

        const escaped_id = try jsonEscape(self.allocator, project.id);
        defer self.allocator.free(escaped_id);
        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.allocator);
        try out.writer(self.allocator).print("{{\"workspace_id\":\"{s}\",\"mounts\":[", .{escaped_id});
        for (project.mounts.items, 0..) |mount, idx| {
            if (idx != 0) try out.append(self.allocator, ',');
            try appendMountJson(self.allocator, &out, mount);
        }
        try out.appendSlice(self.allocator, "]}");
        return out.toOwnedSlice(self.allocator);
    }

    pub fn setWorkspaceBind(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        return self.setWorkspaceBindWithRole(payload_json, false);
    }

    pub fn setWorkspaceBindWithRole(self: *ControlPlane, payload_json: ?[]const u8, is_admin: bool) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;

        const workspace_id = getRequiredString(obj, "workspace_id") catch return ControlPlaneError.MissingField;
        const workspace_token = getOptionalString(obj, "workspace_token");
        const bind_path_raw = getRequiredString(obj, "bind_path") catch return ControlPlaneError.MissingField;
        const target_path_raw = getRequiredString(obj, "target_path") catch return ControlPlaneError.MissingField;
        try validateIdentifier(workspace_id, 128);

        const project = try getPublicWorkspacePtrLocked(self, workspace_id);
        try requireWorkspaceActionAccess(project, .bind, null, workspace_token, is_admin);

        const bind_path = try normalizeMountPath(self.allocator, bind_path_raw);
        errdefer self.allocator.free(bind_path);
        if (std.mem.eql(u8, bind_path, "/")) return ControlPlaneError.InvalidPayload;
        const target_path = try normalizeMountPath(self.allocator, target_path_raw);
        errdefer self.allocator.free(target_path);
        if (!workspacePathWithinBindAuthority(project, target_path)) return ControlPlaneError.BindConflict;

        for (project.mounts.items) |mount| {
            if (pathsConflict(mount.mount_path, bind_path)) return ControlPlaneError.BindConflict;
        }
        for (project.binds.items) |*existing| {
            if (std.mem.eql(u8, existing.bind_path, bind_path)) {
                if (std.mem.eql(u8, existing.target_path, target_path)) {
                    self.allocator.free(bind_path);
                    self.allocator.free(target_path);
                    return renderWorkspacePayload(self.allocator, project.*, false);
                }
                self.allocator.free(existing.target_path);
                existing.target_path = target_path;
                self.allocator.free(bind_path);
                project.updated_at_ms = std.time.milliTimestamp();
                self.persistSnapshotBestEffortLocked();
                return renderWorkspacePayload(self.allocator, project.*, false);
            }
            if (pathsConflict(existing.bind_path, bind_path)) return ControlPlaneError.BindConflict;
        }

        try project.binds.append(self.allocator, .{
            .bind_path = bind_path,
            .target_path = target_path,
        });
        project.updated_at_ms = std.time.milliTimestamp();
        self.persistSnapshotBestEffortLocked();
        return renderWorkspacePayload(self.allocator, project.*, false);
    }

    pub fn removeWorkspaceBind(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        return self.removeWorkspaceBindWithRole(payload_json, false);
    }

    pub fn removeWorkspaceBindWithRole(self: *ControlPlane, payload_json: ?[]const u8, is_admin: bool) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;

        const workspace_id = getRequiredString(obj, "workspace_id") catch return ControlPlaneError.MissingField;
        const workspace_token = getOptionalString(obj, "workspace_token");
        const bind_path_raw = getRequiredString(obj, "bind_path") catch return ControlPlaneError.MissingField;
        try validateIdentifier(workspace_id, 128);
        const bind_path = try normalizeMountPath(self.allocator, bind_path_raw);
        defer self.allocator.free(bind_path);

        const project = try getPublicWorkspacePtrLocked(self, workspace_id);
        try requireWorkspaceActionAccess(project, .bind, null, workspace_token, is_admin);

        var removed = false;
        var i: usize = 0;
        while (i < project.binds.items.len) {
            const bind = project.binds.items[i];
            if (!std.mem.eql(u8, bind.bind_path, bind_path)) {
                i += 1;
                continue;
            }
            var removed_bind = project.binds.orderedRemove(i);
            removed_bind.deinit(self.allocator);
            removed = true;
            break;
        }
        if (!removed) return ControlPlaneError.BindNotFound;
        project.updated_at_ms = std.time.milliTimestamp();
        self.persistSnapshotBestEffortLocked();
        return renderWorkspacePayload(self.allocator, project.*, false);
    }

    pub fn listWorkspaceBinds(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        return self.listWorkspaceBindsWithRole(payload_json, false);
    }

    pub fn listWorkspaceBindsWithRole(self: *ControlPlane, payload_json: ?[]const u8, is_admin: bool) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;
        const workspace_id = getRequiredString(obj, "workspace_id") catch return ControlPlaneError.MissingField;
        const workspace_token = getOptionalString(obj, "workspace_token");
        const project = try getPublicWorkspaceLocked(self, workspace_id);
        try requireWorkspaceActionAccess(&project, .read, null, workspace_token, is_admin);

        const escaped_id = try jsonEscape(self.allocator, project.id);
        defer self.allocator.free(escaped_id);
        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.allocator);
        try out.writer(self.allocator).print("{{\"workspace_id\":\"{s}\",\"binds\":[", .{escaped_id});
        for (project.binds.items, 0..) |bind, idx| {
            if (idx != 0) try out.append(self.allocator, ',');
            try appendBindJson(self.allocator, &out, bind);
        }
        try out.appendSlice(self.allocator, "]}");
        return out.toOwnedSlice(self.allocator);
    }

    pub fn resolveWorkspacePath(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        return self.resolveWorkspacePathWithRole(payload_json, false);
    }

    pub fn resolveWorkspacePathWithRole(self: *ControlPlane, payload_json: ?[]const u8, is_admin: bool) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;
        const workspace_id = getRequiredString(obj, "workspace_id") catch return ControlPlaneError.MissingField;
        const workspace_token = getOptionalString(obj, "workspace_token");
        const path_raw = getRequiredString(obj, "path") catch return ControlPlaneError.MissingField;
        const path = try normalizeMountPath(self.allocator, path_raw);
        defer self.allocator.free(path);

        const project = try getPublicWorkspaceLocked(self, workspace_id);
        try requireWorkspaceActionAccess(&project, .read, null, workspace_token, is_admin);

        const resolved_path = try resolveBoundPath(self.allocator, &project, path);
        defer if (resolved_path) |value| self.allocator.free(value);
        const escaped_project = try jsonEscape(self.allocator, project.id);
        defer self.allocator.free(escaped_project);
        const escaped_path = try jsonEscape(self.allocator, path);
        defer self.allocator.free(escaped_path);
        const resolved_json = if (resolved_path) |value| blk: {
            const escaped = try jsonEscape(self.allocator, value);
            defer self.allocator.free(escaped);
            break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
        } else try self.allocator.dupe(u8, "null");
        defer self.allocator.free(resolved_json);
        return std.fmt.allocPrint(
            self.allocator,
            "{{\"workspace_id\":\"{s}\",\"path\":\"{s}\",\"resolved_path\":{s},\"matched\":{s}}}",
            .{ escaped_project, escaped_path, resolved_json, if (resolved_path != null) "true" else "false" },
        );
    }

    pub fn rotateWorkspaceToken(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        return self.rotateWorkspaceTokenWithRole(payload_json, false);
    }

    pub fn rotateWorkspaceTokenWithRole(self: *ControlPlane, payload_json: ?[]const u8, is_admin: bool) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;
        const workspace_id = getRequiredString(obj, "workspace_id") catch return ControlPlaneError.MissingField;
        const current_token = getOptionalString(obj, "workspace_token");
        try validateIdentifier(workspace_id, 128);
        const project = try getPublicWorkspacePtrLocked(self, workspace_id);
        try requireWorkspaceAccessToken(project, current_token, is_admin);

        self.allocator.free(project.mutation_token);
        project.mutation_token = try makeToken(self.allocator, "ws");
        project.token_locked = true;
        project.updated_at_ms = std.time.milliTimestamp();
        self.workspace_token_rotates_total +%= 1;
        self.persistSnapshotBestEffortLocked();

        const escaped_project = try jsonEscape(self.allocator, workspace_id);
        defer self.allocator.free(escaped_project);
        const escaped_token = try jsonEscape(self.allocator, project.mutation_token);
        defer self.allocator.free(escaped_token);
        return std.fmt.allocPrint(
            self.allocator,
            "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"rotated\":true,\"updated_at_ms\":{d}}}",
            .{ escaped_project, escaped_token, project.updated_at_ms },
        );
    }

    pub fn revokeWorkspaceToken(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        return self.revokeWorkspaceTokenWithRole(payload_json, false);
    }

    pub fn revokeWorkspaceTokenWithRole(self: *ControlPlane, payload_json: ?[]const u8, is_admin: bool) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.reapExpiredLeasesLocked(std.time.milliTimestamp());

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;
        const workspace_id = getRequiredString(obj, "workspace_id") catch return ControlPlaneError.MissingField;
        const current_token = getOptionalString(obj, "workspace_token");
        try validateIdentifier(workspace_id, 128);
        const project = try getPublicWorkspacePtrLocked(self, workspace_id);
        try requireWorkspaceAccessToken(project, current_token, is_admin);

        project.token_locked = false;
        project.updated_at_ms = std.time.milliTimestamp();
        self.workspace_token_revokes_total +%= 1;
        self.persistSnapshotBestEffortLocked();

        const escaped_project = try jsonEscape(self.allocator, workspace_id);
        defer self.allocator.free(escaped_project);
        return std.fmt.allocPrint(
            self.allocator,
            "{{\"workspace_id\":\"{s}\",\"workspace_token\":null,\"revoked\":true,\"updated_at_ms\":{d}}}",
            .{ escaped_project, project.updated_at_ms },
        );
    }

    pub fn activateWorkspace(self: *ControlPlane, agent_id: []const u8, payload_json: ?[]const u8) ![]u8 {
        return self.activateWorkspaceWithRole(agent_id, payload_json, false);
    }

    pub fn activateHostWorkspace(self: *ControlPlane) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now_ms = std.time.milliTimestamp();
        _ = self.reapExpiredLeasesLocked(now_ms);
        try self.ensureBuiltinHostProjectLocked(now_ms);
        const project = try getHostWorkspacePtrLocked(self);

        self.workspace_activations_total +%= 1;
        if (project.mounts.items.len == 0 and self.spider_web_root.len > 0) {
            std.log.info("host project active without mount; waiting for local node registration (root={s})", .{self.spider_web_root});
        }

        return buildWorkspaceActivationPayload(self.allocator, self.host_actor_id, host_workspace_id);
    }

    pub fn activateWorkspaceWithRole(
        self: *ControlPlane,
        agent_id: []const u8,
        payload_json: ?[]const u8,
        is_admin: bool,
    ) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now_ms = std.time.milliTimestamp();
        _ = self.reapExpiredLeasesLocked(now_ms);

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;
        const workspace_id = getRequiredString(obj, "workspace_id") catch return ControlPlaneError.MissingField;
        try validateIdentifier(workspace_id, 128);
        const project = self.workspaces.getPtr(workspace_id) orelse return ControlPlaneError.WorkspaceNotFound;
        if (project.kind == .host_internal) return ControlPlaneError.WorkspaceNotFound;
        const is_host_actor = self.isHostActor(agent_id);
        if (is_host_actor and !std.mem.eql(u8, workspace_id, host_workspace_id)) {
            return ControlPlaneError.WorkspaceAssignmentForbidden;
        }

        const maybe_workspace_token = getOptionalString(obj, "workspace_token");
        try requireWorkspaceActionAccess(project, .read, agent_id, maybe_workspace_token, is_admin);
        if (try ensureDefaultWorkspaceMountsLocked(self, project)) {
            project.updated_at_ms = now_ms;
            self.mount_sets_total +%= 1;
            self.requestReconcileLocked(now_ms);
            _ = try self.runReconcileCycleLocked(now_ms, false);
        }

        try upsertActiveWorkspaceBindingLocked(self, agent_id, workspace_id);
        self.workspace_activations_total +%= 1;
        self.persistSnapshotBestEffortLocked();

        return buildWorkspaceActivationPayload(self.allocator, agent_id, workspace_id);
    }

    pub fn requestReconcile(self: *ControlPlane) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.requestReconcileLocked(std.time.milliTimestamp());
    }

    pub fn runReconcileCycle(self: *ControlPlane, force: bool) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now_ms = std.time.milliTimestamp();
        _ = self.reapExpiredLeasesLocked(now_ms);
        const ran = try self.runReconcileCycleLocked(now_ms, force);
        if (!ran) return null;
        return try self.buildReconcileStatusPayloadLocked(null, true);
    }

    pub fn reconcileStatus(self: *ControlPlane, payload_json: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now_ms = std.time.milliTimestamp();
        _ = self.reapExpiredLeasesLocked(now_ms);
        _ = try self.runReconcileCycleLocked(now_ms, false);
        return try self.buildReconcileStatusPayloadLocked(payload_json, true);
    }

    pub fn workspaceUp(self: *ControlPlane, agent_id: []const u8, payload_json: ?[]const u8) ![]u8 {
        return self.workspaceUpWithRole(agent_id, payload_json, false);
    }

    pub fn workspaceUpWithRole(
        self: *ControlPlane,
        agent_id: []const u8,
        payload_json: ?[]const u8,
        is_admin: bool,
    ) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now_ms = std.time.milliTimestamp();
        _ = self.reapExpiredLeasesLocked(now_ms);

        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        const obj = payload.value.object;

        const requested_workspace_id = getOptionalString(obj, "workspace_id");
        const requested_workspace_name = getOptionalString(obj, "name") orelse getOptionalString(obj, "workspace_name");
        const requested_workspace_vision = getOptionalString(obj, "vision");
        const requested_workspace_status = getOptionalString(obj, "status");
        const requested_workspace_template_id = getOptionalString(obj, "template_id");
        const requested_workspace_token = getOptionalString(obj, "workspace_token");
        const requested_workspace_access_policy = obj.get("access_policy");
        const activate = getOptionalBool(obj, "activate", true) catch return ControlPlaneError.InvalidPayload;
        if (requested_workspace_token) |workspace_token| try validateSecretToken(workspace_token, 256);

        const resolved_workspace = try resolveWorkspaceUpTargetLocked(
            self,
            requested_workspace_id,
            requested_workspace_name,
            requested_workspace_vision,
            requested_workspace_status,
            requested_workspace_template_id,
            requested_workspace_access_policy,
            now_ms,
        );
        const workspace = resolved_workspace.workspace;
        const created = resolved_workspace.created;
        var mounts_replaced = false;
        var binds_replaced = false;
        if (workspace.kind == .host_internal) return ControlPlaneError.WorkspaceNotFound;
        const is_host_actor = self.isHostActor(agent_id);
        if (!created) {
            try applyWorkspaceUpMetadataUpdatesLocked(
                self,
                workspace,
                agent_id,
                is_admin,
                is_host_actor,
                requested_workspace_token,
                requested_workspace_name,
                requested_workspace_vision,
                requested_workspace_status,
                requested_workspace_template_id,
                requested_workspace_access_policy,
                obj.get("desired_mounts") != null,
                obj.get("desired_binds") != null,
            );
        }

        mounts_replaced = try applyWorkspaceUpMountReplacementsLocked(self, workspace, obj.get("desired_mounts"), created);
        binds_replaced = try applyWorkspaceUpBindReplacementsLocked(self, workspace, obj.get("desired_binds"));

        if (try ensureWorkspaceTemplateBindsLocked(self, workspace)) binds_replaced = true;

        workspace.updated_at_ms = now_ms;
        if (!created) self.workspace_updates_total +%= 1;
        if (mounts_replaced) self.mount_sets_total +%= 1;

        if (activate) {
            if (is_host_actor and !std.mem.eql(u8, workspace.id, host_workspace_id)) {
                return ControlPlaneError.WorkspaceAssignmentForbidden;
            }
            if (workspace.kind == .host_internal and !(is_host_actor or is_admin)) {
                return ControlPlaneError.WorkspaceAssignmentForbidden;
            }
            try upsertActiveWorkspaceBindingLocked(self, agent_id, workspace.id);
            self.workspace_activations_total +%= 1;
        }

        self.requestReconcileLocked(now_ms);
        _ = try self.runReconcileCycleLocked(now_ms, false);
        self.persistSnapshotBestEffortLocked();

        return buildWorkspaceUpResultPayloadLocked(
            self,
            agent_id,
            workspace,
            is_admin,
            now_ms,
            created,
            activate,
        );
    }

    pub fn workspaceStatus(self: *ControlPlane, agent_id: []const u8, payload_json: ?[]const u8) ![]u8 {
        return self.workspaceStatusWithRole(agent_id, payload_json, false);
    }

    pub fn hostWorkspaceStatus(self: *ControlPlane) ![]u8 {
        return self.hostWorkspaceStatusWithRole(false);
    }

    pub fn hostWorkspaceStatusWithRole(self: *ControlPlane, is_admin: bool) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now_ms = std.time.milliTimestamp();
        _ = self.reapExpiredLeasesLocked(now_ms);
        _ = try self.runReconcileCycleLocked(now_ms, false);
        try self.ensureBuiltinHostProjectLocked(now_ms);
        return try self.renderWorkspaceStatusForProjectLocked(
            self.host_actor_id,
            host_workspace_id,
            null,
            is_admin,
            now_ms,
        );
    }

    pub fn workspaceStatusWithRole(
        self: *ControlPlane,
        agent_id: []const u8,
        payload_json: ?[]const u8,
        is_admin: bool,
    ) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now_ms = std.time.milliTimestamp();
        _ = self.reapExpiredLeasesLocked(now_ms);
        _ = try self.runReconcileCycleLocked(now_ms, false);

        var selected_workspace_id: ?[]const u8 = null;
        var selected_workspace_token: ?[]const u8 = null;
        var payload = try parsePayload(self.allocator, payload_json);
        defer payload.deinit();
        if (getOptionalString(payload.value.object, "workspace_id")) |workspace_id| {
            try validateIdentifier(workspace_id, 128);
            selected_workspace_id = workspace_id;
        }
        if (getOptionalString(payload.value.object, "workspace_token")) |workspace_token| {
            try validateSecretToken(workspace_token, 256);
            selected_workspace_token = workspace_token;
        }

        const escaped_agent = try jsonEscape(self.allocator, agent_id);
        defer self.allocator.free(escaped_agent);
        if (selected_workspace_id) |workspace_id| {
            const workspace = self.workspaces.get(workspace_id) orelse return ControlPlaneError.WorkspaceNotFound;
            if (workspace.kind == .host_internal) return ControlPlaneError.WorkspaceNotFound;
            try requireWorkspaceStatusAccessLocked(self, agent_id, &workspace, workspace_id, selected_workspace_token, is_admin);
            return try self.renderWorkspaceStatusForProjectLocked(
                agent_id,
                workspace_id,
                selected_workspace_token,
                is_admin,
                now_ms,
            );
        }
        if (resolveVisibleActiveWorkspaceIdLocked(self, agent_id)) |active_workspace_id| {
            return try self.renderWorkspaceStatusForProjectLocked(
                agent_id,
                active_workspace_id,
                null,
                is_admin,
                now_ms,
            );
        }

        return buildEmptyWorkspaceStatusPayloadLocked(self, agent_id);
    }

    fn requestReconcileLocked(self: *ControlPlane, now_ms: i64) void {
        self.reconcile_requested_at_ms = now_ms;
        if (self.reconcile_state == .idle) self.reconcile_state = .pending;
    }

    fn buildWorkspaceActivationPayload(
        allocator: std.mem.Allocator,
        agent_id: []const u8,
        workspace_id: []const u8,
    ) ![]u8 {
        const escaped_agent = try jsonEscape(allocator, agent_id);
        defer allocator.free(escaped_agent);
        const escaped_workspace = try jsonEscape(allocator, workspace_id);
        defer allocator.free(escaped_workspace);
        const escaped_root = try jsonEscape(allocator, "/");
        defer allocator.free(escaped_root);

        return std.fmt.allocPrint(
            allocator,
            "{{\"agent_id\":\"{s}\",\"workspace_id\":\"{s}\",\"workspace_root\":\"{s}\"}}",
            .{ escaped_agent, escaped_workspace, escaped_root },
        );
    }

    const ResolvedWorkspaceUpTarget = struct {
        workspace: *Workspace,
        created: bool,
    };

    fn resolveWorkspaceUpTargetLocked(
        self: *ControlPlane,
        requested_workspace_id: ?[]const u8,
        requested_workspace_name: ?[]const u8,
        requested_workspace_vision: ?[]const u8,
        requested_workspace_status: ?[]const u8,
        requested_workspace_template_id: ?[]const u8,
        requested_workspace_access_policy: ?std.json.Value,
        now_ms: i64,
    ) !ResolvedWorkspaceUpTarget {
        var workspace_ptr: ?*Workspace = null;

        if (requested_workspace_id) |workspace_id| {
            try validateIdentifier(workspace_id, 128);
            workspace_ptr = self.workspaces.getPtr(workspace_id);
            if (workspace_ptr == null) return ControlPlaneError.WorkspaceNotFound;
        } else if (requested_workspace_name) |workspace_name| {
            try validateDisplayString(workspace_name, 128);
            var project_it = self.workspaces.valueIterator();
            while (project_it.next()) |workspace| {
                if (std.mem.eql(u8, workspace.name, workspace_name)) {
                    workspace_ptr = workspace;
                    break;
                }
            }
        }

        if (workspace_ptr) |workspace| {
            return .{ .workspace = workspace, .created = false };
        }

        const workspace_name = requested_workspace_name orelse return ControlPlaneError.MissingField;
        const workspace_vision = requested_workspace_vision orelse return ControlPlaneError.MissingField;
        const workspace_status = requested_workspace_status orelse "active";
        const workspace_template_id = requested_workspace_template_id orelse default_project_template_id;
        try validateDisplayString(workspace_name, 128);
        try validateDisplayString(workspace_vision, 1024);
        try validateIdentifier(workspace_status, 64);
        _ = resolveProjectTemplateSpec(workspace_template_id) orelse return ControlPlaneError.InvalidPayload;

        const workspace_id = try makeSequentialId(self.allocator, "ws", &self.next_workspace_id);
        errdefer self.allocator.free(workspace_id);
        const mutation_token = try makeToken(self.allocator, "ws");
        errdefer self.allocator.free(mutation_token);
        var access_policy: WorkspaceAccessPolicy = .{};
        errdefer access_policy.deinit(self.allocator);
        if (requested_workspace_access_policy) |value| {
            access_policy = try parseWorkspaceAccessPolicyValue(self.allocator, value);
        }

        const workspace = Workspace{
            .id = workspace_id,
            .name = try self.allocator.dupe(u8, workspace_name),
            .vision = try self.allocator.dupe(u8, workspace_vision),
            .status = try self.allocator.dupe(u8, workspace_status),
            .template_id = try self.allocator.dupe(u8, workspace_template_id),
            .token_locked = false,
            .mutation_token = mutation_token,
            .access_policy = access_policy,
            .created_at_ms = now_ms,
            .updated_at_ms = now_ms,
        };
        errdefer {
            self.allocator.free(workspace.name);
            self.allocator.free(workspace.vision);
            self.allocator.free(workspace.status);
            self.allocator.free(workspace.template_id);
            self.allocator.free(workspace.mutation_token);
        }

        try self.workspaces.put(self.allocator, workspace.id, workspace);
        self.workspace_creates_total +%= 1;
        return .{
            .workspace = self.workspaces.getPtr(workspace_id).?,
            .created = true,
        };
    }

    fn applyWorkspaceUpMetadataUpdatesLocked(
        self: *ControlPlane,
        project: *Workspace,
        agent_id: []const u8,
        is_admin: bool,
        is_host_actor: bool,
        requested_project_token: ?[]const u8,
        requested_name: ?[]const u8,
        requested_vision: ?[]const u8,
        requested_status: ?[]const u8,
        requested_template_id: ?[]const u8,
        requested_access_policy_value: ?std.json.Value,
        wants_mount_update: bool,
        wants_bind_update: bool,
    ) !void {
        const wants_admin_update = requested_name != null or
            requested_vision != null or
            requested_status != null or
            requested_template_id != null or
            requested_access_policy_value != null;
        if (!is_host_actor) {
            if (wants_mount_update) {
                try requireWorkspaceActionAccess(project, .mount, agent_id, requested_project_token, is_admin);
            }
            if (wants_bind_update) {
                try requireWorkspaceActionAccess(project, .bind, agent_id, requested_project_token, is_admin);
            }
            if (wants_admin_update) {
                try requireWorkspaceActionAccess(project, .admin, agent_id, requested_project_token, is_admin);
            }
            if (!wants_mount_update and !wants_bind_update and !wants_admin_update) {
                try requireWorkspaceActionAccess(project, .read, agent_id, requested_project_token, is_admin);
            }
        } else if (requested_project_token) |workspace_token| {
            try validateSecretToken(workspace_token, 256);
            if (!workspaceTokenEnabled(project) or !secureTokenEql(project.mutation_token, workspace_token)) {
                return ControlPlaneError.WorkspaceAuthFailed;
            }
        }

        if (requested_name) |next_name| {
            try validateDisplayString(next_name, 128);
            self.allocator.free(project.name);
            project.name = try self.allocator.dupe(u8, next_name);
        }
        if (requested_vision) |next_vision| {
            try validateDisplayString(next_vision, 1024);
            self.allocator.free(project.vision);
            project.vision = try self.allocator.dupe(u8, next_vision);
        }
        if (requested_status) |next_status| {
            try validateIdentifier(next_status, 64);
            self.allocator.free(project.status);
            project.status = try self.allocator.dupe(u8, next_status);
        }
        if (requested_template_id) |template_id| {
            _ = resolveProjectTemplateSpec(template_id) orelse return ControlPlaneError.InvalidPayload;
            if (!std.mem.eql(u8, project.template_id, template_id)) {
                self.allocator.free(project.template_id);
                project.template_id = try self.allocator.dupe(u8, template_id);
            }
        }
        if (requested_access_policy_value) |value| {
            var parsed_policy = try parseWorkspaceAccessPolicyValue(self.allocator, value);
            errdefer parsed_policy.deinit(self.allocator);
            project.access_policy.deinit(self.allocator);
            project.access_policy = parsed_policy;
        }
    }

    fn applyWorkspaceUpMountReplacementsLocked(
        self: *ControlPlane,
        project: *Workspace,
        desired_mounts_value: ?std.json.Value,
        created: bool,
    ) !bool {
        if (desired_mounts_value) |desired_val| {
            if (project.kind == .host_internal) return ControlPlaneError.WorkspaceProtected;
            if (desired_val != .array) return ControlPlaneError.InvalidPayload;
            var next_mounts = std.ArrayListUnmanaged(WorkspaceMount){};
            errdefer {
                for (next_mounts.items) |*mount| mount.deinit(self.allocator);
                next_mounts.deinit(self.allocator);
            }

            for (desired_val.array.items) |item| {
                if (item != .object) return ControlPlaneError.InvalidPayload;
                const mount_obj = item.object;
                const node_id = getRequiredString(mount_obj, "node_id") catch return ControlPlaneError.MissingField;
                const export_name = getRequiredString(mount_obj, "export_name") catch return ControlPlaneError.MissingField;
                const mount_path_raw = getRequiredString(mount_obj, "mount_path") catch return ControlPlaneError.MissingField;
                try validateIdentifier(node_id, 128);
                try validateExportName(export_name);
                if (!self.nodes.contains(node_id)) return ControlPlaneError.NodeNotFound;
                const mount_path = try normalizeMountPath(self.allocator, mount_path_raw);
                errdefer self.allocator.free(mount_path);

                var duplicate_exact = false;
                for (next_mounts.items) |existing| {
                    if (std.mem.eql(u8, existing.mount_path, mount_path)) {
                        if (std.mem.eql(u8, existing.node_id, node_id) and std.mem.eql(u8, existing.export_name, export_name)) {
                            duplicate_exact = true;
                            break;
                        }
                        continue;
                    }
                    if (mountPathsOverlap(existing.mount_path, mount_path)) return ControlPlaneError.MountConflict;
                }
                for (project.binds.items) |existing_bind| {
                    if (pathsConflict(existing_bind.bind_path, mount_path)) return ControlPlaneError.MountConflict;
                }
                if (duplicate_exact) {
                    self.allocator.free(mount_path);
                    continue;
                }

                try next_mounts.append(self.allocator, .{
                    .mount_path = mount_path,
                    .node_id = try self.allocator.dupe(u8, node_id),
                    .export_name = try self.allocator.dupe(u8, export_name),
                });
            }

            for (project.mounts.items) |*mount| mount.deinit(self.allocator);
            project.mounts.deinit(self.allocator);
            project.mounts = next_mounts;
            return true;
        }

        if (created) {
            return ensureDefaultWorkspaceMountsLocked(self, project);
        }
        return false;
    }

    fn applyWorkspaceUpBindReplacementsLocked(
        self: *ControlPlane,
        project: *Workspace,
        desired_binds_value: ?std.json.Value,
    ) !bool {
        const desired_val = desired_binds_value orelse return false;
        if (project.kind == .host_internal) return ControlPlaneError.WorkspaceProtected;
        if (desired_val != .array) return ControlPlaneError.InvalidPayload;
        var next_binds = std.ArrayListUnmanaged(WorkspaceBind){};
        errdefer {
            for (next_binds.items) |*bind| bind.deinit(self.allocator);
            next_binds.deinit(self.allocator);
        }

        for (desired_val.array.items) |item| {
            if (item != .object) return ControlPlaneError.InvalidPayload;
            const bind_obj = item.object;
            const bind_path_raw = getRequiredString(bind_obj, "bind_path") catch return ControlPlaneError.MissingField;
            const target_path_raw = getRequiredString(bind_obj, "target_path") catch return ControlPlaneError.MissingField;
            const bind_path = try normalizeMountPath(self.allocator, bind_path_raw);
            errdefer self.allocator.free(bind_path);
            if (std.mem.eql(u8, bind_path, "/")) return ControlPlaneError.InvalidPayload;
            const target_path = try normalizeMountPath(self.allocator, target_path_raw);
            errdefer self.allocator.free(target_path);
            if (!workspacePathWithinBindAuthority(project, target_path)) return ControlPlaneError.BindConflict;

            for (project.mounts.items) |mount| {
                if (pathsConflict(mount.mount_path, bind_path)) return ControlPlaneError.BindConflict;
            }

            var duplicate_exact = false;
            for (next_binds.items) |existing| {
                if (std.mem.eql(u8, existing.bind_path, bind_path)) {
                    if (std.mem.eql(u8, existing.target_path, target_path)) {
                        duplicate_exact = true;
                        break;
                    }
                    return ControlPlaneError.BindConflict;
                }
                if (pathsConflict(existing.bind_path, bind_path)) return ControlPlaneError.BindConflict;
            }
            if (duplicate_exact) {
                self.allocator.free(bind_path);
                self.allocator.free(target_path);
                continue;
            }

            try next_binds.append(self.allocator, .{
                .bind_path = bind_path,
                .target_path = target_path,
            });
        }

        for (project.binds.items) |*bind| bind.deinit(self.allocator);
        project.binds.deinit(self.allocator);
        project.binds = next_binds;
        return true;
    }

    fn buildWorkspaceUpResultPayloadLocked(
        self: *ControlPlane,
        agent_id: []const u8,
        workspace: *Workspace,
        is_admin: bool,
        now_ms: i64,
        created: bool,
        activate: bool,
    ) ![]u8 {
        const workspace_json = try self.renderWorkspaceStatusForProjectLocked(
            agent_id,
            workspace.id,
            null,
            is_admin,
            now_ms,
        );
        defer self.allocator.free(workspace_json);
        const escaped_workspace = try jsonEscape(self.allocator, workspace.id);
        defer self.allocator.free(escaped_workspace);
        const workspace_token_json = if (workspaceTokenEnabled(workspace)) blk: {
            const escaped_token = try jsonEscape(self.allocator, workspace.mutation_token);
            defer self.allocator.free(escaped_token);
            break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped_token});
        } else try self.allocator.dupe(u8, "null");
        defer self.allocator.free(workspace_token_json);

        return std.fmt.allocPrint(
            self.allocator,
            "{{\"workspace_id\":\"{s}\",\"workspace_token\":{s},\"created\":{s},\"activated\":{s},\"workspace\":{s}}}",
            .{
                escaped_workspace,
                workspace_token_json,
                if (created) "true" else "false",
                if (activate) "true" else "false",
                workspace_json,
            },
        );
    }

    fn resolveVisibleActiveWorkspaceIdLocked(self: *ControlPlane, agent_id: []const u8) ?[]const u8 {
        const active_workspace_id = self.active_workspace_by_agent.get(agent_id) orelse return null;
        if (active_workspace_id.len == 0) return null;
        const active_workspace = self.workspaces.get(active_workspace_id) orelse return null;
        if (active_workspace.kind == .host_internal) {
            if (clearActiveWorkspaceBindingLocked(self, agent_id)) {
                self.persistSnapshotBestEffortLocked();
            }
            return null;
        }
        return active_workspace_id;
    }

    fn requireWorkspaceStatusAccessLocked(
        self: *ControlPlane,
        agent_id: []const u8,
        workspace: *const Workspace,
        workspace_id: []const u8,
        selected_workspace_token: ?[]const u8,
        is_admin: bool,
    ) !void {
        const is_host_actor = self.isHostActor(agent_id);
        if (is_host_actor and !is_admin and !std.mem.eql(u8, workspace_id, host_workspace_id)) {
            return ControlPlaneError.WorkspaceAssignmentForbidden;
        }
        if (is_admin) return;

        switch (resolveWorkspaceActionMode(workspace, .read, agent_id)) {
            .admin, .deny => return ControlPlaneError.WorkspacePolicyForbidden,
            .token => {
                if (selected_workspace_token) |workspace_token| {
                    try validateSecretToken(workspace_token, 256);
                    if (!workspaceTokenEnabled(workspace) or !secureTokenEql(workspace.mutation_token, workspace_token)) {
                        return ControlPlaneError.WorkspaceAuthFailed;
                    }
                    return;
                }
                if (is_host_actor) return;
                const active_workspace_id = self.active_workspace_by_agent.get(agent_id) orelse return ControlPlaneError.WorkspaceAuthFailed;
                if (!std.mem.eql(u8, active_workspace_id, workspace_id)) return ControlPlaneError.WorkspaceAuthFailed;
            },
            .open => {
                if (is_host_actor) return;
                const active_workspace_id = self.active_workspace_by_agent.get(agent_id) orelse return ControlPlaneError.WorkspaceAuthFailed;
                if (!std.mem.eql(u8, active_workspace_id, workspace_id)) return ControlPlaneError.WorkspaceAuthFailed;
            },
        }
    }

    fn buildEmptyWorkspaceStatusPayloadLocked(
        self: *ControlPlane,
        agent_id: []const u8,
    ) ![]u8 {
        const escaped_agent = try jsonEscape(self.allocator, agent_id);
        defer self.allocator.free(escaped_agent);
        const last_error_json = if (self.reconcile_last_error) |value| blk: {
            const escaped = try jsonEscape(self.allocator, value);
            defer self.allocator.free(escaped);
            break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
        } else try self.allocator.dupe(u8, "null");
        defer self.allocator.free(last_error_json);

        return std.fmt.allocPrint(
            self.allocator,
            "{{\"agent_id\":\"{s}\",\"workspace_id\":null,\"name\":null,\"workspace_name\":null,\"template_id\":null,\"workspace_root\":null,\"mounts\":[],\"desired_mounts\":[],\"actual_mounts\":[],\"drift\":{{\"count\":0,\"items\":[]}},\"availability\":{{\"mounts_total\":0,\"online\":0,\"degraded\":0,\"missing\":0}},\"reconcile_state\":\"{s}\",\"last_reconcile_ms\":{d},\"last_success_ms\":{d},\"last_error\":{s},\"queue_depth\":{d}}}",
            .{
                escaped_agent,
                reconcileStateName(self.reconcile_state),
                self.reconcile_last_reconcile_ms,
                self.reconcile_last_success_ms,
                last_error_json,
                self.reconcile_queue_depth,
            },
        );
    }

    fn clearReconcileFailureListLocked(self: *ControlPlane) void {
        for (self.reconcile_last_failed_ops.items) |value| self.allocator.free(value);
        self.reconcile_last_failed_ops.clearRetainingCapacity();
    }

    fn setReconcileLastErrorLocked(self: *ControlPlane, message: ?[]const u8) !void {
        if (self.reconcile_last_error) |value| {
            self.allocator.free(value);
            self.reconcile_last_error = null;
        }
        if (message) |value| {
            const copied = try self.allocator.dupe(u8, value);
            self.reconcile_last_error = copied;
        }
    }

    fn runReconcileCycleLocked(self: *ControlPlane, now_ms: i64, force: bool) !bool {
        const periodic_interval_ms: i64 = 5_000;
        if (!force) {
            if (self.reconcile_requested_at_ms != 0) {
                if (now_ms - self.reconcile_requested_at_ms < self.reconcile_debounce_ms) return false;
            } else if (self.reconcile_last_reconcile_ms != 0) {
                if (now_ms - self.reconcile_last_reconcile_ms < periodic_interval_ms) return false;
            }
        }

        self.reconcile_state = .running;
        self.reconcile_cycles_total +%= 1;

        var new_failed_ops = std.ArrayListUnmanaged([]u8){};
        var adopted_failed_ops = false;
        defer if (!adopted_failed_ops) {
            for (new_failed_ops.items) |value| self.allocator.free(value);
            new_failed_ops.deinit(self.allocator);
        };

        var queue_depth: u32 = 0;
        var project_it = self.workspaces.valueIterator();
        while (project_it.next()) |project| {
            var summary = try self.evaluateProjectDriftLocked(project.*, now_ms, null);
            var attempt: u32 = 0;
            while (summary.queue_depth > 0 and attempt + 1 < self.reconcile_max_retries_per_cycle) : (attempt += 1) {
                _ = self.reconcile_retry_backoff_ms;
                summary = try self.evaluateProjectDriftLocked(project.*, now_ms, null);
            }
            if (summary.queue_depth > 0) {
                const final_summary = try self.evaluateProjectDriftLocked(project.*, now_ms, &new_failed_ops);
                queue_depth +%= final_summary.queue_depth;
            }
        }

        self.clearReconcileFailureListLocked();
        self.reconcile_last_failed_ops = new_failed_ops;
        adopted_failed_ops = true;

        self.reconcile_queue_depth = queue_depth;
        self.reconcile_last_reconcile_ms = now_ms;
        self.reconcile_requested_at_ms = 0;

        if (queue_depth == 0 and self.reconcile_last_failed_ops.items.len == 0) {
            self.reconcile_state = .idle;
            self.reconcile_last_success_ms = now_ms;
            try self.setReconcileLastErrorLocked(null);
        } else {
            self.reconcile_state = .degraded;
            self.reconcile_failed_ops_total +%= @as(u64, @intCast(self.reconcile_last_failed_ops.items.len));
            if (self.reconcile_last_failed_ops.items.len > 0) {
                try self.setReconcileLastErrorLocked(self.reconcile_last_failed_ops.items[0]);
            } else {
                try self.setReconcileLastErrorLocked("reconcile queue is non-empty");
            }
        }

        return true;
    }

    fn buildReconcileStatusPayloadLocked(
        self: *ControlPlane,
        payload_json: ?[]const u8,
        include_projects: bool,
    ) ![]u8 {
        var selected_project_id: ?[]const u8 = null;
        if (payload_json != null) {
            var payload = try parsePayload(self.allocator, payload_json);
            defer payload.deinit();
            if (getOptionalString(payload.value.object, "workspace_id")) |workspace_id| {
                try validateIdentifier(workspace_id, 128);
                if (!self.workspaces.contains(workspace_id)) return ControlPlaneError.WorkspaceNotFound;
                selected_project_id = workspace_id;
            }
        }

        const last_error_json = if (self.reconcile_last_error) |value| blk: {
            const escaped = try jsonEscape(self.allocator, value);
            defer self.allocator.free(escaped);
            break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
        } else try self.allocator.dupe(u8, "null");
        defer self.allocator.free(last_error_json);

        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(self.allocator);
        try out.writer(self.allocator).print(
            "{{\"reconcile_state\":\"{s}\",\"last_reconcile_ms\":{d},\"last_success_ms\":{d},\"last_error\":{s},\"queue_depth\":{d},\"failed_ops_total\":{d},\"cycles_total\":{d},\"failed_ops\":[",
            .{
                reconcileStateName(self.reconcile_state),
                self.reconcile_last_reconcile_ms,
                self.reconcile_last_success_ms,
                last_error_json,
                self.reconcile_queue_depth,
                self.reconcile_failed_ops_total,
                self.reconcile_cycles_total,
            },
        );
        for (self.reconcile_last_failed_ops.items, 0..) |message, idx| {
            if (idx != 0) try out.append(self.allocator, ',');
            const escaped = try jsonEscape(self.allocator, message);
            defer self.allocator.free(escaped);
            try out.writer(self.allocator).print("\"{s}\"", .{escaped});
        }
        try out.appendSlice(self.allocator, "]");

        if (include_projects) {
            const now_ms = std.time.milliTimestamp();
            try out.appendSlice(self.allocator, ",\"projects\":[");
            var first = true;
            var project_it = self.workspaces.valueIterator();
            while (project_it.next()) |project| {
                if (selected_project_id) |selected| {
                    if (!std.mem.eql(u8, selected, project.id)) continue;
                }
                const summary = try self.evaluateProjectDriftLocked(project.*, now_ms, null);
                if (!first) try out.append(self.allocator, ',');
                first = false;
                const escaped_project = try jsonEscape(self.allocator, project.id);
                defer self.allocator.free(escaped_project);
                try out.writer(self.allocator).print(
                    "{{\"workspace_id\":\"{s}\",\"mounts\":{d},\"selected_mounts\":{d},\"online_mounts\":{d},\"degraded_mounts\":{d},\"missing_mounts\":{d},\"drift_count\":{d},\"queue_depth\":{d}}}",
                    .{
                        escaped_project,
                        project.mounts.items.len,
                        summary.mounts_total,
                        summary.online_mounts,
                        summary.degraded_mounts,
                        summary.missing_mounts,
                        summary.drift_count,
                        summary.queue_depth,
                    },
                );
            }
            try out.appendSlice(self.allocator, "]");
        }

        try out.appendSlice(self.allocator, "}");
        return out.toOwnedSlice(self.allocator);
    }

    fn renderWorkspaceStatusForProjectLocked(
        self: *ControlPlane,
        agent_id: []const u8,
        workspace_id: []const u8,
        workspace_token: ?[]const u8,
        is_admin: bool,
        now_ms: i64,
    ) ![]u8 {
        const project = self.workspaces.get(workspace_id) orelse return ControlPlaneError.WorkspaceNotFound;
        const workspace_root = "/";
        const include_node_secrets = is_admin or workspace_token != null or self.isHostActor(agent_id);
        const escaped_agent = try jsonEscape(self.allocator, agent_id);
        defer self.allocator.free(escaped_agent);
        const escaped_project = try jsonEscape(self.allocator, workspace_id);
        defer self.allocator.free(escaped_project);
        const escaped_name = try jsonEscape(self.allocator, project.name);
        defer self.allocator.free(escaped_name);
        const escaped_template_id = try jsonEscape(self.allocator, project.template_id);
        defer self.allocator.free(escaped_template_id);
        const escaped_root = try jsonEscape(self.allocator, workspace_root);
        defer self.allocator.free(escaped_root);
        const last_error_json = if (self.reconcile_last_error) |value| blk: {
            const escaped = try jsonEscape(self.allocator, value);
            defer self.allocator.free(escaped);
            break :blk try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{escaped});
        } else try self.allocator.dupe(u8, "null");
        defer self.allocator.free(last_error_json);

        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(self.allocator);
        try out.writer(self.allocator).print(
            "{{\"agent_id\":\"{s}\",\"workspace_id\":\"{s}\",\"name\":\"{s}\",\"workspace_name\":\"{s}\",\"template_id\":\"{s}\",\"workspace_root\":\"{s}\"",
            .{ escaped_agent, escaped_project, escaped_name, escaped_name, escaped_template_id, escaped_root },
        );
        const topology = try self.appendWorkspaceTopologyJsonLocked(
            &out,
            project,
            now_ms,
            null,
            include_node_secrets,
            agent_id,
            workspace_token,
            is_admin,
        );
        try out.appendSlice(self.allocator, ",\"availability\":");
        try appendWorkspaceAvailabilityJson(self.allocator, &out, topology);
        try out.writer(self.allocator).print(
            ",\"reconcile_state\":\"{s}\",\"last_reconcile_ms\":{d},\"last_success_ms\":{d},\"last_error\":{s},\"queue_depth\":{d}}}",
            .{
                reconcileStateName(self.reconcile_state),
                self.reconcile_last_reconcile_ms,
                self.reconcile_last_success_ms,
                last_error_json,
                topology.queue_depth,
            },
        );
        return out.toOwnedSlice(self.allocator);
    }

    fn appendWorkspaceTopologyJsonLocked(
        self: *ControlPlane,
        out: *std.ArrayListUnmanaged(u8),
        project: Workspace,
        now_ms: i64,
        failed_ops: ?*std.ArrayListUnmanaged([]u8),
        include_node_secrets: bool,
        actor_id: ?[]const u8,
        actor_project_token: ?[]const u8,
        actor_is_admin: bool,
    ) !ReconcileWorkspaceSummary {
        const visible_mounts = try self.allocator.alloc(bool, project.mounts.items.len);
        defer self.allocator.free(visible_mounts);
        for (project.mounts.items, 0..) |mount, idx| {
            visible_mounts[idx] = self.workspaceMountVisibleForActorLocked(
                project,
                mount,
                actor_id,
                actor_project_token,
                actor_is_admin,
            );
        }

        var first_by_path = std.StringHashMapUnmanaged(usize){};
        defer first_by_path.deinit(self.allocator);
        var selected_by_path = std.StringHashMapUnmanaged(usize){};
        defer selected_by_path.deinit(self.allocator);

        for (project.mounts.items, 0..) |mount, idx| {
            if (!visible_mounts[idx]) continue;
            if (!first_by_path.contains(mount.mount_path)) {
                try first_by_path.put(self.allocator, mount.mount_path, idx);
            }
            if (selected_by_path.getPtr(mount.mount_path)) |selected_idx| {
                if (self.shouldSelectCandidateMountLocked(project, selected_idx.*, idx, now_ms)) {
                    selected_idx.* = idx;
                }
            } else {
                try selected_by_path.put(self.allocator, mount.mount_path, idx);
            }
        }
        var summary = ReconcileWorkspaceSummary{};
        for (project.mounts.items, 0..) |mount, idx| {
            if (!visible_mounts[idx]) continue;
            const selected_idx = selected_by_path.get(mount.mount_path) orelse continue;
            if (selected_idx != idx) continue;
            summary.mounts_total +%= 1;
            const state_rank = mountCandidateAvailabilityRank(self.nodes.get(mount.node_id), now_ms);
            switch (state_rank) {
                2 => summary.online_mounts +%= 1,
                1 => summary.degraded_mounts +%= 1,
                else => summary.missing_mounts +%= 1,
            }
        }

        try out.appendSlice(self.allocator, ",\"mounts\":[");
        var first = true;
        for (project.mounts.items, 0..) |mount, idx| {
            if (!visible_mounts[idx]) continue;
            const selected_idx = selected_by_path.get(mount.mount_path) orelse continue;
            if (selected_idx != idx) continue;
            if (!first) try out.append(self.allocator, ',');
            first = false;
            try appendWorkspaceMountJson(self.allocator, out, mount, self.nodes.get(mount.node_id), include_node_secrets, now_ms);
        }
        try out.appendSlice(self.allocator, "],\"desired_mounts\":[");

        first = true;
        for (project.mounts.items, 0..) |mount, idx| {
            if (!visible_mounts[idx]) continue;
            if (!first) try out.append(self.allocator, ',');
            first = false;
            try appendWorkspaceMountJson(self.allocator, out, mount, self.nodes.get(mount.node_id), include_node_secrets, now_ms);
        }
        try out.appendSlice(self.allocator, "],\"actual_mounts\":[");

        first = true;
        for (project.mounts.items, 0..) |mount, idx| {
            if (!visible_mounts[idx]) continue;
            const selected_idx = selected_by_path.get(mount.mount_path) orelse continue;
            if (selected_idx != idx) continue;
            if (!first) try out.append(self.allocator, ',');
            first = false;
            try appendWorkspaceMountJson(self.allocator, out, mount, self.nodes.get(mount.node_id), include_node_secrets, now_ms);
        }
        try out.appendSlice(self.allocator, "],\"drift\":{\"count\":");

        var drift_items = std.ArrayListUnmanaged(u8){};
        defer drift_items.deinit(self.allocator);
        var first_drift = true;
        for (project.mounts.items, 0..) |mount, idx| {
            if (!visible_mounts[idx]) continue;
            const first_idx = first_by_path.get(mount.mount_path) orelse continue;
            if (first_idx != idx) continue;

            const selected_idx = selected_by_path.get(mount.mount_path) orelse continue;
            const selected_mount = project.mounts.items[selected_idx];
            const selected_node = self.nodes.get(selected_mount.node_id);
            const selected_online = if (selected_node) |resolved| resolved.lease_expires_at_ms > now_ms else false;

            if (selected_node == null) {
                summary.drift_count +%= 1;
                summary.queue_depth +%= 1;
                if (!first_drift) try drift_items.append(self.allocator, ',');
                first_drift = false;
                try appendDriftEntryJson(
                    self.allocator,
                    &drift_items,
                    selected_mount.mount_path,
                    "missing_node",
                    .err,
                    selected_mount.node_id,
                    mount.node_id,
                    "selected node is missing",
                );
                if (failed_ops) |ops| {
                    const message = try std.fmt.allocPrint(
                        self.allocator,
                        "project={s} mount={s} node={s} missing",
                        .{ project.id, selected_mount.mount_path, selected_mount.node_id },
                    );
                    try ops.append(self.allocator, message);
                }
                continue;
            }

            if (!selected_online) {
                summary.drift_count +%= 1;
                summary.queue_depth +%= 1;
                if (!first_drift) try drift_items.append(self.allocator, ',');
                first_drift = false;
                try appendDriftEntryJson(
                    self.allocator,
                    &drift_items,
                    selected_mount.mount_path,
                    "node_offline",
                    .err,
                    selected_mount.node_id,
                    mount.node_id,
                    "selected node lease is expired",
                );
                if (failed_ops) |ops| {
                    const message = try std.fmt.allocPrint(
                        self.allocator,
                        "project={s} mount={s} node={s} offline",
                        .{ project.id, selected_mount.mount_path, selected_mount.node_id },
                    );
                    try ops.append(self.allocator, message);
                }
                continue;
            }

            if (selected_idx != first_idx) {
                summary.drift_count +%= 1;
                if (!first_drift) try drift_items.append(self.allocator, ',');
                first_drift = false;
                try appendDriftEntryJson(
                    self.allocator,
                    &drift_items,
                    selected_mount.mount_path,
                    "failover_active",
                    .warning,
                    selected_mount.node_id,
                    mount.node_id,
                    "using healthy failover node",
                );
            }
        }

        try out.writer(self.allocator).print("{d},\"items\":[{s}]}}", .{ summary.drift_count, drift_items.items });
        return summary;
    }

    fn shouldSelectCandidateMountLocked(
        self: *ControlPlane,
        project: Workspace,
        current_idx: usize,
        candidate_idx: usize,
        now_ms: i64,
    ) bool {
        const current_mount = project.mounts.items[current_idx];
        const candidate_mount = project.mounts.items[candidate_idx];
        const current_node = self.nodes.get(current_mount.node_id);
        const candidate_node = self.nodes.get(candidate_mount.node_id);
        const current_rank = mountCandidateAvailabilityRank(current_node, now_ms);
        const candidate_rank = mountCandidateAvailabilityRank(candidate_node, now_ms);
        if (candidate_rank != current_rank) return candidate_rank > current_rank;

        const current_lease = mountCandidateLeaseOrMin(current_node);
        const candidate_lease = mountCandidateLeaseOrMin(candidate_node);
        if (candidate_lease != current_lease) return candidate_lease > current_lease;

        return false;
    }

    fn mountCandidateAvailabilityRank(node: ?Node, now_ms: i64) u8 {
        if (node) |resolved| {
            if (resolved.lease_expires_at_ms > now_ms) return 2;
            return 1;
        }
        return 0;
    }

    fn mountCandidateLeaseOrMin(node: ?Node) i64 {
        if (node) |resolved| return resolved.lease_expires_at_ms;
        return std.math.minInt(i64);
    }

    fn evaluateProjectDriftLocked(
        self: *ControlPlane,
        project: Workspace,
        now_ms: i64,
        failed_ops: ?*std.ArrayListUnmanaged([]u8),
    ) !ReconcileWorkspaceSummary {
        var scratch = std.ArrayListUnmanaged(u8){};
        defer scratch.deinit(self.allocator);
        return try self.appendWorkspaceTopologyJsonLocked(
            &scratch,
            project,
            now_ms,
            failed_ops,
            false,
            null,
            null,
            true,
        );
    }

    fn workspaceMountVisibleForActorLocked(
        self: *ControlPlane,
        project: Workspace,
        mount: WorkspaceMount,
        actor_id: ?[]const u8,
        actor_project_token: ?[]const u8,
        actor_is_admin: bool,
    ) bool {
        if (actor_id == null) return true;
        if (actor_is_admin) return true;

        const node = self.nodes.get(mount.node_id) orelse return true;
        var matched_invoke_venom = false;
        for (node.venoms.items) |venom| {
            if (!venomHasInvokePath(self.allocator, venom)) continue;
            if (!venomMountIncludesPath(self.allocator, venom, mount.mount_path)) continue;
            matched_invoke_venom = true;
            if (!servicePermissionsAllowActor(
                self.allocator,
                venom.permissions_json,
                actor_project_token != null,
                false,
            )) return false;
        }
        if (!matched_invoke_venom) return true;
        requireWorkspaceActionAccess(&project, .invoke, actor_id, actor_project_token, false) catch return false;
        return true;
    }

    pub fn metricsJson(self: *ControlPlane) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now_ms = std.time.milliTimestamp();
        _ = self.reapExpiredLeasesLocked(now_ms);
        const snapshot = self.collectMetricsLocked(now_ms);

        return std.fmt.allocPrint(
            self.allocator,
            "{{\"invites\":{{\"active\":{d},\"created_total\":{d},\"redeemed_total\":{d}}},\"nodes\":{{\"online\":{d},\"total\":{d},\"joins_total\":{d},\"lease_refresh_total\":{d},\"ensured_total\":{d},\"deletes_total\":{d},\"reaped_total\":{d}}},\"workspaces\":{{\"total\":{d},\"active_bindings\":{d},\"creates_total\":{d},\"updates_total\":{d},\"deletes_total\":{d},\"token_rotates_total\":{d},\"token_revokes_total\":{d},\"activations_total\":{d},\"mounts_total\":{d},\"mount_sets_total\":{d},\"mount_removes_total\":{d}}}}}",
            .{
                snapshot.invites_active,
                self.invites_created_total,
                self.invites_redeemed_total,
                snapshot.nodes_online,
                snapshot.nodes_total,
                self.node_joins_total,
                self.node_lease_refresh_total,
                self.nodes_ensured_total,
                self.node_deletes_total,
                self.lease_reap_nodes_total,
                snapshot.workspaces_total,
                snapshot.active_workspace_bindings,
                self.workspace_creates_total,
                self.workspace_updates_total,
                self.workspace_deletes_total,
                self.workspace_token_rotates_total,
                self.workspace_token_revokes_total,
                self.workspace_activations_total,
                snapshot.mounts_total,
                self.mount_sets_total,
                self.mount_removes_total,
            },
        );
    }

    pub fn metricsPrometheus(self: *ControlPlane) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now_ms = std.time.milliTimestamp();
        _ = self.reapExpiredLeasesLocked(now_ms);
        const snapshot = self.collectMetricsLocked(now_ms);

        return std.fmt.allocPrint(
            self.allocator,
            \\# TYPE spiderweb_invites_active gauge
            \\spiderweb_invites_active {d}
            \\# TYPE spiderweb_invites_created_total counter
            \\spiderweb_invites_created_total {d}
            \\# TYPE spiderweb_invites_redeemed_total counter
            \\spiderweb_invites_redeemed_total {d}
            \\# TYPE spiderweb_nodes_online gauge
            \\spiderweb_nodes_online {d}
            \\# TYPE spiderweb_nodes_total gauge
            \\spiderweb_nodes_total {d}
            \\# TYPE spiderweb_node_joins_total counter
            \\spiderweb_node_joins_total {d}
            \\# TYPE spiderweb_node_lease_refresh_total counter
            \\spiderweb_node_lease_refresh_total {d}
            \\# TYPE spiderweb_nodes_ensured_total counter
            \\spiderweb_nodes_ensured_total {d}
            \\# TYPE spiderweb_node_deletes_total counter
            \\spiderweb_node_deletes_total {d}
            \\# TYPE spiderweb_lease_reap_nodes_total counter
            \\spiderweb_lease_reap_nodes_total {d}
            \\# TYPE spiderweb_workspaces_total gauge
            \\spiderweb_workspaces_total {d}
            \\# TYPE spiderweb_active_workspace_bindings gauge
            \\spiderweb_active_workspace_bindings {d}
            \\# TYPE spiderweb_workspace_creates_total counter
            \\spiderweb_workspace_creates_total {d}
            \\# TYPE spiderweb_workspace_updates_total counter
            \\spiderweb_workspace_updates_total {d}
            \\# TYPE spiderweb_workspace_deletes_total counter
            \\spiderweb_workspace_deletes_total {d}
            \\# TYPE spiderweb_workspace_token_rotates_total counter
            \\spiderweb_workspace_token_rotates_total {d}
            \\# TYPE spiderweb_workspace_token_revokes_total counter
            \\spiderweb_workspace_token_revokes_total {d}
            \\# TYPE spiderweb_workspace_activations_total counter
            \\spiderweb_workspace_activations_total {d}
            \\# TYPE spiderweb_workspace_mounts_total gauge
            \\spiderweb_workspace_mounts_total {d}
            \\# TYPE spiderweb_mount_sets_total counter
            \\spiderweb_mount_sets_total {d}
            \\# TYPE spiderweb_mount_removes_total counter
            \\spiderweb_mount_removes_total {d}
            \\
        ,
            .{
                snapshot.invites_active,
                self.invites_created_total,
                self.invites_redeemed_total,
                snapshot.nodes_online,
                snapshot.nodes_total,
                self.node_joins_total,
                self.node_lease_refresh_total,
                self.nodes_ensured_total,
                self.node_deletes_total,
                self.lease_reap_nodes_total,
                snapshot.workspaces_total,
                snapshot.active_workspace_bindings,
                self.workspace_creates_total,
                self.workspace_updates_total,
                self.workspace_deletes_total,
                self.workspace_token_rotates_total,
                self.workspace_token_revokes_total,
                self.workspace_activations_total,
                snapshot.mounts_total,
                self.mount_sets_total,
                self.mount_removes_total,
            },
        );
    }

    const MetricsSnapshot = struct {
        invites_active: usize,
        nodes_online: usize,
        nodes_total: usize,
        workspaces_total: usize,
        active_workspace_bindings: usize,
        mounts_total: usize,
    };

    pub const AvailabilitySnapshot = struct {
        nodes_online: usize = 0,
        nodes_total: usize = 0,
        mounts_online: usize = 0,
        mounts_degraded: usize = 0,
        mounts_missing: usize = 0,
        mounts_total: usize = 0,
        project_mount_digest: u64 = 0,

        pub fn eql(lhs: AvailabilitySnapshot, rhs: AvailabilitySnapshot) bool {
            return lhs.nodes_online == rhs.nodes_online and
                lhs.nodes_total == rhs.nodes_total and
                lhs.mounts_online == rhs.mounts_online and
                lhs.mounts_degraded == rhs.mounts_degraded and
                lhs.mounts_missing == rhs.mounts_missing and
                lhs.mounts_total == rhs.mounts_total and
                lhs.project_mount_digest == rhs.project_mount_digest;
        }
    };

    const ProjectAvailabilitySnapshot = struct {
        online_mounts: usize = 0,
        degraded_mounts: usize = 0,
        missing_mounts: usize = 0,
        mounts_total: usize = 0,
        digest: u64 = 0,
    };

    pub fn availabilitySnapshot(self: *ControlPlane) AvailabilitySnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now_ms = std.time.milliTimestamp();
        return self.collectAvailabilitySnapshotLocked(now_ms);
    }

    fn collectAvailabilitySnapshotLocked(self: *ControlPlane, now_ms: i64) AvailabilitySnapshot {
        var snapshot = AvailabilitySnapshot{
            .nodes_total = self.nodes.count(),
        };
        var nodes_it = self.nodes.valueIterator();
        while (nodes_it.next()) |node| {
            if (node.lease_expires_at_ms > now_ms) snapshot.nodes_online += 1;
        }

        var digest_acc: u64 = 0;
        var project_it = self.workspaces.valueIterator();
        while (project_it.next()) |project| {
            const project_snapshot = self.collectProjectAvailabilitySnapshotLocked(project.*, now_ms);
            snapshot.mounts_online += project_snapshot.online_mounts;
            snapshot.mounts_degraded += project_snapshot.degraded_mounts;
            snapshot.mounts_missing += project_snapshot.missing_mounts;
            snapshot.mounts_total += project_snapshot.mounts_total;
            digest_acc +%= project_snapshot.digest *% 0x9e3779b185ebca87;
        }
        snapshot.project_mount_digest = digest_acc;
        return snapshot;
    }

    fn collectProjectAvailabilitySnapshotLocked(
        self: *ControlPlane,
        project: Workspace,
        now_ms: i64,
    ) ProjectAvailabilitySnapshot {
        var out = ProjectAvailabilitySnapshot{
            .digest = std.hash.Wyhash.hash(0, project.id),
        };
        const mounts = project.mounts.items;

        var idx: usize = 0;
        while (idx < mounts.len) : (idx += 1) {
            const mount = mounts[idx];
            var seen_before = false;
            var selected_idx = idx;

            var candidate_idx: usize = 0;
            while (candidate_idx < mounts.len) : (candidate_idx += 1) {
                const candidate = mounts[candidate_idx];
                if (!std.mem.eql(u8, candidate.mount_path, mount.mount_path)) continue;
                if (candidate_idx < idx) {
                    seen_before = true;
                    break;
                }
                if (self.shouldSelectCandidateMountLocked(project, selected_idx, candidate_idx, now_ms)) {
                    selected_idx = candidate_idx;
                }
            }
            if (seen_before) continue;

            const selected_mount = mounts[selected_idx];
            const state_rank = mountCandidateAvailabilityRank(self.nodes.get(selected_mount.node_id), now_ms);
            out.mounts_total += 1;
            switch (state_rank) {
                2 => out.online_mounts += 1,
                1 => out.degraded_mounts += 1,
                else => out.missing_mounts += 1,
            }

            const mount_hash = hashMountAvailabilityItem(selected_mount, state_rank);
            out.digest +%= mount_hash *% 0xbf58476d1ce4e5b9;
        }

        return out;
    }

    fn collectMetricsLocked(self: *ControlPlane, now_ms: i64) MetricsSnapshot {
        var online_nodes: usize = 0;
        var mounts_total: usize = 0;

        var node_it = self.nodes.valueIterator();
        while (node_it.next()) |node| {
            if (node.lease_expires_at_ms > now_ms) online_nodes += 1;
        }

        var project_it = self.workspaces.valueIterator();
        while (project_it.next()) |project| {
            mounts_total += project.mounts.items.len;
        }

        return .{
            .invites_active = self.invites.count(),
            .nodes_online = online_nodes,
            .nodes_total = self.nodes.count(),
            .workspaces_total = self.workspaces.count(),
            .active_workspace_bindings = self.active_workspace_by_agent.count(),
            .mounts_total = mounts_total,
        };
    }

    fn reapExpiredLeasesLocked(self: *ControlPlane, now_ms: i64) bool {
        var removed_any = false;
        var removed_count: u64 = 0;

        while (true) {
            var expired_id: ?[]const u8 = null;
            var node_it = self.nodes.valueIterator();
            while (node_it.next()) |node| {
                if (node.lease_expires_at_ms <= now_ms) {
                    expired_id = node.id;
                    break;
                }
            }
            const node_id = expired_id orelse break;

            const removed = self.nodes.fetchRemove(node_id) orelse continue;
            var node = removed.value;
            _ = self.dropNodeMountsFromProjectsLocked(node.id, now_ms);
            node.deinit(self.allocator);
            removed_any = true;
            removed_count += 1;
        }

        if (removed_any) self.persistSnapshotBestEffortLocked();
        if (removed_count > 0) {
            self.lease_reap_nodes_total +%= removed_count;
            std.log.info("control-plane lease reaper removed {d} expired nodes", .{removed_count});
        }
        return removed_any;
    }

    fn dropNodeMountsFromProjectsLocked(self: *ControlPlane, node_id: []const u8, now_ms: i64) bool {
        var changed_any = false;
        var project_it = self.workspaces.valueIterator();
        while (project_it.next()) |project| {
            var changed = false;
            var i: usize = 0;
            while (i < project.mounts.items.len) {
                if (std.mem.eql(u8, project.mounts.items[i].node_id, node_id)) {
                    var removed_mount = project.mounts.orderedRemove(i);
                    removed_mount.deinit(self.allocator);
                    changed = true;
                } else {
                    i += 1;
                }
            }
            if (changed) {
                changed_any = true;
                project.updated_at_ms = now_ms;
            }
        }
        return changed_any;
    }

    fn deleteNodeByIdLocked(self: *ControlPlane, node_id: []const u8, now_ms: i64) !void {
        const removed = self.nodes.fetchRemove(node_id) orelse return ControlPlaneError.NodeNotFound;
        var node = removed.value;
        defer node.deinit(self.allocator);

        _ = self.dropNodeMountsFromProjectsLocked(node_id, now_ms);
        self.node_deletes_total +%= 1;
        self.persistSnapshotBestEffortLocked();
        std.log.info("control-plane node deleted: {s}", .{node_id});
    }

    fn renderNodeJoinPayload(self: *ControlPlane, node_id: []const u8) ![]u8 {
        const node = self.nodes.get(node_id) orelse return ControlPlaneError.NodeNotFound;
        const escaped_id = try jsonEscape(self.allocator, node.id);
        defer self.allocator.free(escaped_id);
        const escaped_name = try jsonEscape(self.allocator, node.name);
        defer self.allocator.free(escaped_name);
        const escaped_url = try jsonEscape(self.allocator, node.fs_url);
        defer self.allocator.free(escaped_url);
        const escaped_secret = try jsonEscape(self.allocator, node.secret);
        defer self.allocator.free(escaped_secret);
        const escaped_lease = try jsonEscape(self.allocator, node.lease_token);
        defer self.allocator.free(escaped_lease);
        const escaped_platform_os = try jsonEscape(self.allocator, node.platform_os);
        defer self.allocator.free(escaped_platform_os);
        const escaped_platform_arch = try jsonEscape(self.allocator, node.platform_arch);
        defer self.allocator.free(escaped_platform_arch);
        const escaped_platform_runtime = try jsonEscape(self.allocator, node.platform_runtime_kind);
        defer self.allocator.free(escaped_platform_runtime);

        return std.fmt.allocPrint(
            self.allocator,
            "{{\"node_id\":\"{s}\",\"node_name\":\"{s}\",\"fs_url\":\"{s}\",\"node_secret\":\"{s}\",\"lease_token\":\"{s}\",\"platform\":{{\"os\":\"{s}\",\"arch\":\"{s}\",\"runtime_kind\":\"{s}\"}},\"lease_expires_at_ms\":{d}}}",
            .{
                escaped_id,
                escaped_name,
                escaped_url,
                escaped_secret,
                escaped_lease,
                escaped_platform_os,
                escaped_platform_arch,
                escaped_platform_runtime,
                node.lease_expires_at_ms,
            },
        );
    }

    fn renderNodeVenomPayload(self: *ControlPlane, node_id: []const u8, delta_json: ?[]const u8) ![]u8 {
        const node = self.nodes.get(node_id) orelse return ControlPlaneError.NodeNotFound;
        const escaped_id = try jsonEscape(self.allocator, node.id);
        defer self.allocator.free(escaped_id);
        const escaped_name = try jsonEscape(self.allocator, node.name);
        defer self.allocator.free(escaped_name);
        const escaped_platform_os = try jsonEscape(self.allocator, node.platform_os);
        defer self.allocator.free(escaped_platform_os);
        const escaped_platform_arch = try jsonEscape(self.allocator, node.platform_arch);
        defer self.allocator.free(escaped_platform_arch);
        const escaped_platform_runtime = try jsonEscape(self.allocator, node.platform_runtime_kind);
        defer self.allocator.free(escaped_platform_runtime);

        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.allocator);
        try out.writer(self.allocator).print(
            "{{\"node_id\":\"{s}\",\"node_name\":\"{s}\",\"platform\":{{\"os\":\"{s}\",\"arch\":\"{s}\",\"runtime_kind\":\"{s}\"}},\"labels\":{{",
            .{
                escaped_id,
                escaped_name,
                escaped_platform_os,
                escaped_platform_arch,
                escaped_platform_runtime,
            },
        );
        for (node.labels.items, 0..) |label, idx| {
            if (idx != 0) try out.append(self.allocator, ',');
            const escaped_key = try jsonEscape(self.allocator, label.key);
            defer self.allocator.free(escaped_key);
            const escaped_value = try jsonEscape(self.allocator, label.value);
            defer self.allocator.free(escaped_value);
            try out.writer(self.allocator).print("\"{s}\":\"{s}\"", .{ escaped_key, escaped_value });
        }
        try out.appendSlice(self.allocator, "},\"venoms\":[");
        for (node.venoms.items, 0..) |venom, idx| {
            if (idx != 0) try out.append(self.allocator, ',');
            const package_id = if (idx < node.venom_package_ids.items.len) node.venom_package_ids.items[idx] else null;
            try appendNodeVenomJson(self.allocator, &out, venom, package_id);
        }
        try out.append(self.allocator, ']');
        if (delta_json) |delta| {
            try out.appendSlice(self.allocator, ",\"venom_delta\":");
            try out.appendSlice(self.allocator, delta);
        }
        try out.append(self.allocator, '}');
        return out.toOwnedSlice(self.allocator);
    }

    fn renderSingleInstalledVenomPackageJsonLocked(self: *ControlPlane, venom_id: []const u8) ![]u8 {
        for (self.installed_venom_packages.items) |package| {
            if (!std.mem.eql(u8, package.venom_id, venom_id)) continue;
            var out = std.ArrayListUnmanaged(u8){};
            defer out.deinit(self.allocator);
            try venom_package_model.appendPackageJson(self.allocator, &out, package);
            return out.toOwnedSlice(self.allocator);
        }
        return ControlPlaneError.VenomPackageNotFound;
    }

    fn renderInstalledVenomReleasesJsonLocked(self: *ControlPlane) ![]u8 {
        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.allocator);
        try out.append(self.allocator, '[');
        for (self.installed_venom_releases.items, 0..) |release, idx| {
            if (idx != 0) try out.append(self.allocator, ',');
            try appendInstalledVenomReleaseJson(self.allocator, &out, release);
        }
        try out.append(self.allocator, ']');
        return out.toOwnedSlice(self.allocator);
    }

    fn renderSingleInstalledVenomReleaseJsonLocked(
        self: *ControlPlane,
        package_id: []const u8,
        release_version: ?[]const u8,
    ) ![]u8 {
        const release_index = if (release_version) |requested| blk: {
            var found_index: ?usize = null;
            for (self.installed_venom_releases.items, 0..) |release, idx| {
                if (!std.mem.eql(u8, release.package_id, package_id)) continue;
                if (!std.mem.eql(u8, release.package.release_version, requested)) continue;
                found_index = idx;
                break;
            }
            break :blk found_index;
        } else findPreferredInstalledReleaseIndex(self.installed_venom_releases.items, package_id);
        const index = release_index orelse return ControlPlaneError.VenomPackageNotFound;

        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.allocator);
        try appendInstalledVenomReleaseJson(self.allocator, &out, self.installed_venom_releases.items[index]);
        return out.toOwnedSlice(self.allocator);
    }

    fn renderSingleVenomPackageJsonLocked(self: *ControlPlane, venom_id: []const u8) ![]u8 {
        if (venom_packages.findBuiltinPackage(venom_id)) |spec| {
            return venom_packages.renderPackageMetadataJson(self.allocator, spec);
        }
        return self.renderSingleInstalledVenomPackageJsonLocked(venom_id);
    }

    const VenomPackageView = struct {
        venom_id: []const u8,
        kind: []const u8,
        version: []const u8,
        enabled: bool,
        host_roles_json: []const u8,
        binding_scopes_json: []const u8,
        requirements_json: []const u8,
        runtime_json: []const u8,
        runtime_kind: venom_model.RuntimeKind,
    };

    fn lookupVenomPackageLocked(self: *ControlPlane, venom_id: []const u8) ?VenomPackageView {
        if (venom_packages.findBuiltinPackage(venom_id)) |spec| {
            return .{
                .venom_id = spec.venom_id,
                .kind = spec.kind,
                .version = spec.version,
                .enabled = spec.enabled,
                .host_roles_json = spec.hostRolesJson(),
                .binding_scopes_json = spec.bindingScopesJson(),
                .requirements_json = spec.requirements_json,
                .runtime_json = spec.runtime_json,
                .runtime_kind = spec.runtime_kind,
            };
        }
        for (self.installed_venom_packages.items) |package| {
            if (!std.mem.eql(u8, package.venom_id, venom_id)) continue;
            if (!package.enabled) return null;
            return .{
                .venom_id = package.venom_id,
                .kind = package.kind,
                .version = package.version,
                .enabled = package.enabled,
                .host_roles_json = package.host_roles_json,
                .binding_scopes_json = package.binding_scopes_json,
                .requirements_json = package.requirements_json,
                .runtime_json = package.runtime_json,
                .runtime_kind = if (std.mem.indexOf(u8, package.runtime_json, "\"type\":\"wasm\"") != null) .wasm else .native,
            };
        }
        return null;
    }

    fn cloneVenomPackageLocked(
        self: *ControlPlane,
        allocator: std.mem.Allocator,
        venom_id: []const u8,
    ) !?venom_package_model.VenomPackage {
        if (try venom_packages.cloneBuiltinPackage(allocator, venom_id)) |package| return package;
        for (self.installed_venom_packages.items) |package| {
            if (!std.mem.eql(u8, package.venom_id, venom_id)) continue;
            if (!package.enabled) return null;
            return .{
                .venom_id = try allocator.dupe(u8, package.venom_id),
                .kind = try allocator.dupe(u8, package.kind),
                .version = try allocator.dupe(u8, package.version),
                .release_version = try allocator.dupe(u8, package.release_version),
                .channel = if (package.channel) |value| try allocator.dupe(u8, value) else null,
                .digest = if (package.digest) |value| try allocator.dupe(u8, value) else null,
                .signature_json = if (package.signature_json) |value| try allocator.dupe(u8, value) else null,
                .trust_json = if (package.trust_json) |value| try allocator.dupe(u8, value) else null,
                .enabled = package.enabled,
                .categories_json = try allocator.dupe(u8, package.categories_json),
                .host_roles_json = try allocator.dupe(u8, package.host_roles_json),
                .binding_scopes_json = try allocator.dupe(u8, package.binding_scopes_json),
                .runtime_kind = package.runtime_kind,
                .requirements_json = try allocator.dupe(u8, package.requirements_json),
                .capabilities_json = try allocator.dupe(u8, package.capabilities_json),
                .ops_json = try allocator.dupe(u8, package.ops_json),
                .runtime_json = try allocator.dupe(u8, package.runtime_json),
                .permissions_json = try allocator.dupe(u8, package.permissions_json),
                .schema_json = try allocator.dupe(u8, package.schema_json),
                .help_md = if (package.help_md) |help| try allocator.dupe(u8, help) else null,
            };
        }
        return null;
    }

    fn validateNodeVenomCatalogLocked(
        self: *ControlPlane,
        fs_url: []const u8,
        platform_runtime_kind: []const u8,
        venoms: []const venom_catalog.VenomDescriptor,
        package_ids: []const ?[]const u8,
    ) !void {
        if (package_ids.len != 0 and package_ids.len != venoms.len) return ControlPlaneError.InvalidPayload;
        var available_venoms = std.ArrayListUnmanaged([]const u8){};
        defer available_venoms.deinit(self.allocator);
        for (venoms) |venom| {
            try available_venoms.append(self.allocator, venom.venom_id);
        }

        var host_capabilities = std.ArrayListUnmanaged([]const u8){};
        defer host_capabilities.deinit(self.allocator);
        try host_capabilities.append(self.allocator, "namespace_driver");
        if (fs_url.len > 0) try host_capabilities.append(self.allocator, "local_fs_export");
        if (std.mem.eql(u8, platform_runtime_kind, "native")) {
            try host_capabilities.append(self.allocator, "native_proc");
            try host_capabilities.append(self.allocator, "native_inproc");
        } else if (std.mem.eql(u8, platform_runtime_kind, "wasm")) {
            try host_capabilities.append(self.allocator, "wasm");
        }

        for (venoms, 0..) |venom, idx| {
            const package_id = if (package_ids.len == 0) venom.venom_id else package_ids[idx] orelse venom.venom_id;
            const package = lookupVenomPackageLocked(self, package_id) orelse return ControlPlaneError.VenomPackageNotFound;
            try validateVenomPackageInstantiationLocked(
                self.allocator,
                package,
                "node",
                "node_export",
                available_venoms.items,
                host_capabilities.items,
                venom.runtime_json,
            );
        }
    }

    fn validateVenomPackageInstantiationLocked(
        allocator: std.mem.Allocator,
        package: VenomPackageView,
        host: []const u8,
        legacy_projection_mode: []const u8,
        available_venoms: []const []const u8,
        host_capabilities: []const []const u8,
        actual_runtime_json: ?[]const u8,
    ) !void {
        if (!jsonArrayContainsString(allocator, package.host_roles_json, host)) {
            return ControlPlaneError.VenomPackageHostUnsupported;
        }
        const required_scope = if (std.mem.eql(u8, legacy_projection_mode, "node_export"))
            "workspace"
        else if (std.mem.eql(u8, legacy_projection_mode, "workspace_service") or std.mem.eql(u8, legacy_projection_mode, "host_local"))
            "workspace"
        else if (std.mem.eql(u8, legacy_projection_mode, "runtime_private"))
            "agent"
        else if (std.mem.eql(u8, legacy_projection_mode, "client_private"))
            "client"
        else
            legacy_projection_mode;
        if (!jsonArrayContainsString(allocator, package.binding_scopes_json, required_scope)) {
            return ControlPlaneError.VenomPackageProjectionUnsupported;
        }
        if (!requirementsSatisfied(allocator, package.requirements_json, available_venoms, host_capabilities)) {
            return ControlPlaneError.VenomPackageRequirementsUnmet;
        }
        if (!runtimeTypeCompatible(allocator, package.runtime_json, actual_runtime_json)) {
            return ControlPlaneError.VenomPackageRuntimeMismatch;
        }
    }

    fn collectNodeVenomPackageIds(
        allocator: std.mem.Allocator,
        venoms_value: std.json.Value,
        out: *std.ArrayListUnmanaged(?[]const u8),
    ) !void {
        if (venoms_value != .array) return ControlPlaneError.InvalidPayload;
        for (venoms_value.array.items) |item| {
            if (item != .object) return ControlPlaneError.InvalidPayload;
            if (item.object.get("package_id")) |package_id_value| {
                if (package_id_value != .string or package_id_value.string.len == 0) return ControlPlaneError.InvalidPayload;
                try validateIdentifier(package_id_value.string, 128);
                try out.append(allocator, package_id_value.string);
            } else {
                try out.append(allocator, null);
            }
        }
    }

    fn cloneNodeVenomPackageIds(
        allocator: std.mem.Allocator,
        package_ids: []const ?[]const u8,
    ) !std.ArrayListUnmanaged(?[]u8) {
        var out = std.ArrayListUnmanaged(?[]u8){};
        errdefer deinitNodeVenomPackageIds(allocator, &out);
        for (package_ids) |package_id| {
            try out.append(allocator, if (package_id) |value| try allocator.dupe(u8, value) else null);
        }
        return out;
    }

    fn deinitNodeVenomPackageIds(
        allocator: std.mem.Allocator,
        package_ids: *std.ArrayListUnmanaged(?[]u8),
    ) void {
        for (package_ids.items) |package_id| {
            if (package_id) |value| allocator.free(value);
        }
        package_ids.deinit(allocator);
        package_ids.* = .{};
    }

    fn requirementsSatisfied(
        allocator: std.mem.Allocator,
        requirements_json: []const u8,
        available_venoms: []const []const u8,
        host_capabilities: []const []const u8,
    ) bool {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, requirements_json, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .object) return false;

        if (parsed.value.object.get("venoms")) |venoms_value| {
            if (venoms_value != .array) return false;
            for (venoms_value.array.items) |item| {
                if (item != .string or !containsString(available_venoms, item.string)) return false;
            }
        }

        if (parsed.value.object.get("host_capabilities")) |caps_value| {
            if (caps_value != .array) return false;
            for (caps_value.array.items) |item| {
                if (item != .string or !containsString(host_capabilities, item.string)) return false;
            }
        }
        return true;
    }

    fn jsonArrayContainsString(allocator: std.mem.Allocator, raw_json: []const u8, needle: []const u8) bool {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .array) return false;
        for (parsed.value.array.items) |item| {
            if (item != .string) continue;
            if (std.mem.eql(u8, item.string, needle)) return true;
        }
        return false;
    }

    fn runtimeTypeCompatible(allocator: std.mem.Allocator, expected_runtime_json: []const u8, actual_runtime_json: ?[]const u8) bool {
        var expected_parsed = std.json.parseFromSlice(std.json.Value, allocator, expected_runtime_json, .{}) catch return true;
        defer expected_parsed.deinit();
        if (expected_parsed.value != .object) return true;
        const expected_type_value = expected_parsed.value.object.get("type") orelse return true;
        if (expected_type_value != .string or expected_type_value.string.len == 0) return true;

        var actual_parsed = std.json.parseFromSlice(std.json.Value, allocator, actual_runtime_json orelse "{}", .{}) catch return false;
        defer actual_parsed.deinit();
        if (actual_parsed.value != .object) return false;
        const actual_type = blk: {
            const actual_type_value = actual_parsed.value.object.get("type") orelse break :blk "builtin";
            if (actual_type_value != .string or actual_type_value.string.len == 0) break :blk "builtin";
            break :blk actual_type_value.string;
        };
        return std.mem.eql(u8, expected_type_value.string, actual_type);
    }

    fn containsString(haystack: []const []const u8, needle: []const u8) bool {
        for (haystack) |item| {
            if (std.mem.eql(u8, item, needle)) return true;
        }
        return false;
    }

    fn extractProspectiveNodeRuntimeKind(
        node: *const Node,
        platform_value: ?std.json.Value,
    ) ![]const u8 {
        const raw = platform_value orelse return node.platform_runtime_kind;
        if (raw != .object) return ControlPlaneError.InvalidPayload;
        if (raw.object.get("runtime_kind")) |value| {
            if (value != .string or value.string.len == 0) return ControlPlaneError.InvalidPayload;
            try validateIdentifier(value.string, 64);
            return value.string;
        }
        return node.platform_runtime_kind;
    }

    fn clonePreferredVenomProviderLocked(
        self: *ControlPlane,
        allocator: std.mem.Allocator,
        venom_id: []const u8,
        preferred_node_name: []const u8,
        require_name_match: bool,
        constraints: PreferredVenomProviderConstraints,
    ) !?PreferredVenomProvider {
        var selected_node: ?*const Node = null;
        var selected_venom: ?*const venom_catalog.VenomDescriptor = null;

        var it = self.nodes.valueIterator();
        while (it.next()) |node| {
            if (require_name_match and !std.mem.eql(u8, node.name, preferred_node_name)) continue;
            const venom = findNodeVenom(node, venom_id) orelse continue;
            if (!preferredVenomMatchesConstraints(venom, constraints)) continue;
            if (selected_node == null or preferredProviderCandidateBeatsSelected(node, selected_node.?)) {
                selected_node = node;
                selected_venom = venom;
            }
        }

        const node = selected_node orelse return null;
        const venom = selected_venom orelse return null;
        const endpoint_path = if (venom.endpoints.items.len > 0)
            venom.endpoints.items[0]
        else
            return null;

        return .{
            .node_id = try allocator.dupe(u8, node.id),
            .node_name = try allocator.dupe(u8, node.name),
            .venom_id = try allocator.dupe(u8, venom.venom_id),
            .host_type = try allocator.dupe(u8, nodeHostType(node).asString()),
            .endpoint_path = try allocator.dupe(u8, endpoint_path),
        };
    }

    fn preferredVenomBindingKeyLocked(
        self: *ControlPlane,
        scope: PreferredVenomBindingScope,
        scope_id: ?[]const u8,
        venom_id: []const u8,
    ) ![]u8 {
        return switch (scope) {
            .global => std.fmt.allocPrint(self.allocator, "global:{s}", .{venom_id}),
            .project => std.fmt.allocPrint(self.allocator, "project:{s}:{s}", .{ scope_id orelse "", venom_id }),
            .agent => std.fmt.allocPrint(self.allocator, "agent:{s}:{s}", .{ scope_id orelse "", venom_id }),
        };
    }

    fn cloneExplicitPreferredVenomProviderLocked(
        self: *ControlPlane,
        allocator: std.mem.Allocator,
        venom_id: []const u8,
        scope: PreferredVenomBindingScope,
        scope_id: ?[]const u8,
        constraints: PreferredVenomProviderConstraints,
    ) !?PreferredVenomProvider {
        const preferred_key = try self.preferredVenomBindingKeyLocked(scope, scope_id, venom_id);
        defer self.allocator.free(preferred_key);
        const preferred_node_id = self.preferred_venom_provider_by_scope_venom.get(preferred_key) orelse return null;
        const node = self.nodes.getPtr(preferred_node_id) orelse return null;
        const venom = findNodeVenom(node, venom_id) orelse return null;
        if (!preferredVenomMatchesConstraints(venom, constraints)) return null;
        const endpoint_path = if (venom.endpoints.items.len > 0)
            venom.endpoints.items[0]
        else
            return null;

        return .{
            .node_id = try allocator.dupe(u8, node.id),
            .node_name = try allocator.dupe(u8, node.name),
            .venom_id = try allocator.dupe(u8, venom.venom_id),
            .host_type = try allocator.dupe(u8, nodeHostType(node).asString()),
            .endpoint_path = try allocator.dupe(u8, endpoint_path),
        };
    }

    fn findNodeVenom(node: *const Node, venom_id: []const u8) ?*const venom_catalog.VenomDescriptor {
        for (node.venoms.items) |*venom| {
            if (std.mem.eql(u8, venom.venom_id, venom_id)) return venom;
        }
        return null;
    }

    fn snapshotNodeVenomDigests(
        allocator: std.mem.Allocator,
        venoms: []const venom_catalog.VenomDescriptor,
        package_ids: []const ?[]u8,
        out: *std.ArrayListUnmanaged(NodeVenomDigest),
    ) !void {
        for (venoms, 0..) |venom, idx| {
            const venom_id = try allocator.dupe(u8, venom.venom_id);
            errdefer allocator.free(venom_id);
            const version = try allocator.dupe(u8, venom.version);
            errdefer allocator.free(version);
            const package_id = if (idx < package_ids.len) package_ids[idx] else null;
            const owned_package_id = if (package_id) |value| try allocator.dupe(u8, value) else null;
            errdefer if (owned_package_id) |value| allocator.free(value);
            try out.append(allocator, .{
                .venom_id = venom_id,
                .version = version,
                .package_id = owned_package_id,
                .digest = nodeVenomDigest64(venom, package_id),
            });
        }
    }

    fn nodeVenomDigest64(venom: venom_catalog.VenomDescriptor, package_id: ?[]const u8) u64 {
        var hasher = std.hash.Wyhash.init(venom_catalog.venomDigest64(venom));
        if (package_id) |value| {
            hasher.update(&.{1});
            hasher.update(value);
        } else {
            hasher.update(&.{0});
        }
        return hasher.final();
    }

    fn deinitNodeVenomDigests(
        allocator: std.mem.Allocator,
        digests: *std.ArrayListUnmanaged(NodeVenomDigest),
    ) void {
        for (digests.items) |*entry| entry.deinit(allocator);
        digests.deinit(allocator);
        digests.* = .{};
    }

    fn renderNodeVenomDeltaJson(
        allocator: std.mem.Allocator,
        previous: *const std.ArrayListUnmanaged(NodeVenomDigest),
        current: *const std.ArrayListUnmanaged(NodeVenomDigest),
    ) ![]u8 {
        var previous_index = std.StringHashMapUnmanaged(usize){};
        defer previous_index.deinit(allocator);

        for (previous.items, 0..) |entry, idx| {
            try previous_index.put(allocator, entry.venom_id, idx);
        }

        const seen_previous = try allocator.alloc(bool, previous.items.len);
        defer allocator.free(seen_previous);
        @memset(seen_previous, false);

        var changed = false;
        for (current.items) |entry| {
            if (previous_index.get(entry.venom_id)) |idx| {
                seen_previous[idx] = true;
                const before = previous.items[idx];
                if (before.digest != entry.digest) changed = true;
            } else {
                changed = true;
            }
        }
        for (seen_previous) |seen| {
            if (!seen) {
                changed = true;
                break;
            }
        }

        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(allocator);
        try out.appendSlice(allocator, "{\"changed\":");
        try out.appendSlice(allocator, if (changed) "true" else "false");
        try out.appendSlice(allocator, ",\"timestamp_ms\":");
        try out.writer(allocator).print("{d}", .{std.time.milliTimestamp()});

        try out.appendSlice(allocator, ",\"added\":[");
        var first_added = true;
        for (current.items) |entry| {
            if (previous_index.contains(entry.venom_id)) continue;
            if (!first_added) try out.append(allocator, ',');
            first_added = false;
            try appendNodeVenomDigestJson(allocator, &out, entry.venom_id, entry.version, entry.digest);
        }
        try out.appendSlice(allocator, "],\"updated\":[");
        var first_updated = true;
        for (current.items) |entry| {
            const prev_idx = previous_index.get(entry.venom_id) orelse continue;
            const before = previous.items[prev_idx];
            if (before.digest == entry.digest) continue;
            if (!first_updated) try out.append(allocator, ',');
            first_updated = false;
            try appendNodeVenomUpdateJson(
                allocator,
                &out,
                entry.venom_id,
                entry.version,
                entry.digest,
                before.version,
                before.digest,
            );
        }
        try out.appendSlice(allocator, "],\"removed\":[");
        var first_removed = true;
        for (previous.items, 0..) |entry, idx| {
            if (seen_previous[idx]) continue;
            if (!first_removed) try out.append(allocator, ',');
            first_removed = false;
            try appendNodeVenomDigestJson(allocator, &out, entry.venom_id, entry.version, entry.digest);
        }
        try out.appendSlice(allocator, "]}");
        return out.toOwnedSlice(allocator);
    }

    fn appendNodeVenomDigestJson(
        allocator: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(u8),
        venom_id: []const u8,
        version: []const u8,
        digest: u64,
    ) !void {
        const escaped_venom = try jsonEscape(allocator, venom_id);
        defer allocator.free(escaped_venom);
        const escaped_version = try jsonEscape(allocator, version);
        defer allocator.free(escaped_version);
        try out.writer(allocator).print(
            "{{\"venom_id\":\"{s}\",\"version\":\"{s}\",\"hash\":\"0x{x:0>16}\"}}",
            .{ escaped_venom, escaped_version, digest },
        );
    }

    fn appendNodeVenomUpdateJson(
        allocator: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(u8),
        venom_id: []const u8,
        version: []const u8,
        digest: u64,
        previous_version: []const u8,
        previous_digest: u64,
    ) !void {
        const escaped_venom = try jsonEscape(allocator, venom_id);
        defer allocator.free(escaped_venom);
        const escaped_version = try jsonEscape(allocator, version);
        defer allocator.free(escaped_version);
        const escaped_previous_version = try jsonEscape(allocator, previous_version);
        defer allocator.free(escaped_previous_version);
        try out.writer(allocator).print(
            "{{\"venom_id\":\"{s}\",\"version\":\"{s}\",\"hash\":\"0x{x:0>16}\",\"previous_version\":\"{s}\",\"previous_hash\":\"0x{x:0>16}\"}}",
            .{ escaped_venom, escaped_version, digest, escaped_previous_version, previous_digest },
        );
    }

    fn persistSnapshotBestEffortLocked(self: *ControlPlane) void {
        self.requestReconcileLocked(std.time.milliTimestamp());
        self.persistSnapshotLocked() catch |err| {
            std.log.warn("control-plane snapshot persist failed: {s}", .{@errorName(err)});
        };
    }

    fn persistSnapshotLocked(self: *ControlPlane) !void {
        const snapshot_directory = self.snapshot_directory orelse return;
        const snapshot_filename = self.snapshot_filename orelse return;

        const snapshot_json = try self.buildSnapshotJsonLocked();
        defer self.allocator.free(snapshot_json);
        const persisted_json = if (self.state_encryption_key) |key|
            try encryptSnapshotJson(self.allocator, snapshot_json, key)
        else
            try self.allocator.dupe(u8, snapshot_json);
        defer self.allocator.free(persisted_json);

        try std.fs.cwd().makePath(snapshot_directory);
        const snapshot_path = try std.fs.path.join(self.allocator, &.{ snapshot_directory, snapshot_filename });
        defer self.allocator.free(snapshot_path);
        try std.fs.cwd().writeFile(.{
            .sub_path = snapshot_path,
            .data = persisted_json,
        });
    }

    fn loadSnapshotLocked(self: *ControlPlane) !void {
        const snapshot_directory = self.snapshot_directory orelse return;
        const snapshot_filename = self.snapshot_filename orelse return;
        const snapshot_path = try std.fs.path.join(self.allocator, &.{ snapshot_directory, snapshot_filename });
        defer self.allocator.free(snapshot_path);

        var file = std.fs.cwd().openFile(snapshot_path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NameTooLong => return,
            error.NotDir => return,
            error.IsDir => return,
            else => return err,
        };
        defer file.close();

        const snapshot_size = try file.getEndPos();
        if (snapshot_size > max_snapshot_file_bytes) return error.FileTooBig;

        const record = try file.readToEndAlloc(self.allocator, @intCast(snapshot_size));
        defer self.allocator.free(record);

        if (isEncryptedSnapshotEnvelope(record)) {
            const key = self.state_encryption_key orelse return error.MissingSnapshotEncryptionKey;
            const snapshot_json = try decryptSnapshotJson(self.allocator, record, key);
            defer self.allocator.free(snapshot_json);
            try self.restoreSnapshotFromJsonLocked(snapshot_json);
            return;
        }
        try self.restoreSnapshotFromJsonLocked(record);
    }

    fn buildSnapshotJsonLocked(self: *ControlPlane) ![]u8 {
        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(self.allocator);

        try out.writer(self.allocator).print(
            "{{\"schema\":1,\"next\":{{\"invite_id\":{d},\"node_id\":{d},\"pending_join_id\":{d},\"workspace_id\":{d}}},\"metrics\":{{\"invites_created_total\":{d},\"invites_redeemed_total\":{d},\"node_joins_total\":{d},\"node_lease_refresh_total\":{d},\"nodes_ensured_total\":{d},\"node_deletes_total\":{d},\"workspace_creates_total\":{d},\"workspace_updates_total\":{d},\"workspace_deletes_total\":{d},\"workspace_token_rotates_total\":{d},\"workspace_token_revokes_total\":{d},\"mount_sets_total\":{d},\"mount_removes_total\":{d},\"workspace_activations_total\":{d},\"lease_reap_nodes_total\":{d}}},\"invites\":[",
            .{
                self.next_invite_id,
                self.next_node_id,
                self.next_pending_join_id,
                self.next_workspace_id,
                self.invites_created_total,
                self.invites_redeemed_total,
                self.node_joins_total,
                self.node_lease_refresh_total,
                self.nodes_ensured_total,
                self.node_deletes_total,
                self.workspace_creates_total,
                self.workspace_updates_total,
                self.workspace_deletes_total,
                self.workspace_token_rotates_total,
                self.workspace_token_revokes_total,
                self.mount_sets_total,
                self.mount_removes_total,
                self.workspace_activations_total,
                self.lease_reap_nodes_total,
            },
        );

        var first = true;
        var invite_it = self.invites.valueIterator();
        while (invite_it.next()) |invite| {
            if (!first) try out.append(self.allocator, ',');
            first = false;

            const escaped_id = try jsonEscape(self.allocator, invite.id);
            defer self.allocator.free(escaped_id);
            const escaped_token = try jsonEscape(self.allocator, invite.token);
            defer self.allocator.free(escaped_token);
            try out.writer(self.allocator).print(
                "{{\"id\":\"{s}\",\"token\":\"{s}\",\"created_at_ms\":{d},\"expires_at_ms\":{d},\"redeemed\":{s}}}",
                .{
                    escaped_id,
                    escaped_token,
                    invite.created_at_ms,
                    invite.expires_at_ms,
                    if (invite.redeemed) "true" else "false",
                },
            );
        }

        try out.appendSlice(self.allocator, "],\"nodes\":[");
        first = true;
        var node_it = self.nodes.valueIterator();
        while (node_it.next()) |node| {
            if (!first) try out.append(self.allocator, ',');
            first = false;

            const escaped_id = try jsonEscape(self.allocator, node.id);
            defer self.allocator.free(escaped_id);
            const escaped_name = try jsonEscape(self.allocator, node.name);
            defer self.allocator.free(escaped_name);
            const escaped_url = try jsonEscape(self.allocator, node.fs_url);
            defer self.allocator.free(escaped_url);
            const escaped_secret = try jsonEscape(self.allocator, node.secret);
            defer self.allocator.free(escaped_secret);
            const escaped_lease = try jsonEscape(self.allocator, node.lease_token);
            defer self.allocator.free(escaped_lease);
            const escaped_platform_os = try jsonEscape(self.allocator, node.platform_os);
            defer self.allocator.free(escaped_platform_os);
            const escaped_platform_arch = try jsonEscape(self.allocator, node.platform_arch);
            defer self.allocator.free(escaped_platform_arch);
            const escaped_platform_runtime = try jsonEscape(self.allocator, node.platform_runtime_kind);
            defer self.allocator.free(escaped_platform_runtime);

            try out.writer(self.allocator).print(
                "{{\"id\":\"{s}\",\"name\":\"{s}\",\"fs_url\":\"{s}\",\"secret\":\"{s}\",\"lease_token\":\"{s}\",\"platform\":{{\"os\":\"{s}\",\"arch\":\"{s}\",\"runtime_kind\":\"{s}\"}},\"labels\":{{",
                .{
                    escaped_id,
                    escaped_name,
                    escaped_url,
                    escaped_secret,
                    escaped_lease,
                    escaped_platform_os,
                    escaped_platform_arch,
                    escaped_platform_runtime,
                },
            );
            for (node.labels.items, 0..) |label, idx| {
                if (idx != 0) try out.append(self.allocator, ',');
                const escaped_key = try jsonEscape(self.allocator, label.key);
                defer self.allocator.free(escaped_key);
                const escaped_value = try jsonEscape(self.allocator, label.value);
                defer self.allocator.free(escaped_value);
                try out.writer(self.allocator).print("\"{s}\":\"{s}\"", .{ escaped_key, escaped_value });
            }
            try out.appendSlice(self.allocator, "},\"venoms\":[");
            for (node.venoms.items, 0..) |venom, idx| {
                if (idx != 0) try out.append(self.allocator, ',');
                const package_id = if (idx < node.venom_package_ids.items.len) node.venom_package_ids.items[idx] else null;
                try appendNodeVenomJson(self.allocator, &out, venom, package_id);
            }
            try out.writer(self.allocator).print(
                "],\"joined_at_ms\":{d},\"last_seen_ms\":{d},\"lease_expires_at_ms\":{d}}}",
                .{ node.joined_at_ms, node.last_seen_ms, node.lease_expires_at_ms },
            );
        }

        try out.appendSlice(self.allocator, "],\"pending_joins\":[");
        first = true;
        var pending_it = self.pending_joins.valueIterator();
        while (pending_it.next()) |pending| {
            if (!first) try out.append(self.allocator, ',');
            first = false;
            const escaped_id = try jsonEscape(self.allocator, pending.id);
            defer self.allocator.free(escaped_id);
            const escaped_name = try jsonEscape(self.allocator, pending.node_name);
            defer self.allocator.free(escaped_name);
            const escaped_url = try jsonEscape(self.allocator, pending.fs_url);
            defer self.allocator.free(escaped_url);
            const escaped_platform_os = try jsonEscape(self.allocator, pending.platform_os);
            defer self.allocator.free(escaped_platform_os);
            const escaped_platform_arch = try jsonEscape(self.allocator, pending.platform_arch);
            defer self.allocator.free(escaped_platform_arch);
            const escaped_platform_runtime = try jsonEscape(self.allocator, pending.platform_runtime_kind);
            defer self.allocator.free(escaped_platform_runtime);
            try out.writer(self.allocator).print(
                "{{\"id\":\"{s}\",\"node_name\":\"{s}\",\"fs_url\":\"{s}\",\"platform\":{{\"os\":\"{s}\",\"arch\":\"{s}\",\"runtime_kind\":\"{s}\"}},\"requested_at_ms\":{d}}}",
                .{
                    escaped_id,
                    escaped_name,
                    escaped_url,
                    escaped_platform_os,
                    escaped_platform_arch,
                    escaped_platform_runtime,
                    pending.requested_at_ms,
                },
            );
        }

        try out.appendSlice(self.allocator, "],\"workspaces\":[");
        first = true;
        var project_it = self.workspaces.valueIterator();
        while (project_it.next()) |project| {
            if (!first) try out.append(self.allocator, ',');
            first = false;

            const escaped_id = try jsonEscape(self.allocator, project.id);
            defer self.allocator.free(escaped_id);
            const escaped_name = try jsonEscape(self.allocator, project.name);
            defer self.allocator.free(escaped_name);
            const escaped_vision = try jsonEscape(self.allocator, project.vision);
            defer self.allocator.free(escaped_vision);
            const escaped_status = try jsonEscape(self.allocator, project.status);
            defer self.allocator.free(escaped_status);
            const escaped_kind = try jsonEscape(self.allocator, workspaceKindName(project.kind));
            defer self.allocator.free(escaped_kind);
            const escaped_template_id = try jsonEscape(self.allocator, project.template_id);
            defer self.allocator.free(escaped_template_id);
            const escaped_token = try jsonEscape(self.allocator, project.mutation_token);
            defer self.allocator.free(escaped_token);

            try out.writer(self.allocator).print(
                "{{\"id\":\"{s}\",\"name\":\"{s}\",\"vision\":\"{s}\",\"status\":\"{s}\",\"template_id\":\"{s}\",\"kind\":\"{s}\",\"is_delete_protected\":{s},\"token_locked\":{s},\"mutation_token\":\"{s}\",\"created_at_ms\":{d},\"updated_at_ms\":{d},\"access_policy\":",
                .{
                    escaped_id,
                    escaped_name,
                    escaped_vision,
                    escaped_status,
                    escaped_template_id,
                    escaped_kind,
                    if (project.is_delete_protected) "true" else "false",
                    if (project.token_locked) "true" else "false",
                    escaped_token,
                    project.created_at_ms,
                    project.updated_at_ms,
                },
            );
            try appendWorkspaceAccessPolicyJson(self.allocator, &out, project.access_policy);
            try out.appendSlice(self.allocator, ",\"mounts\":[");
            for (project.mounts.items, 0..) |mount, idx| {
                if (idx != 0) try out.append(self.allocator, ',');
                const escaped_path = try jsonEscape(self.allocator, mount.mount_path);
                defer self.allocator.free(escaped_path);
                const escaped_node = try jsonEscape(self.allocator, mount.node_id);
                defer self.allocator.free(escaped_node);
                const escaped_export = try jsonEscape(self.allocator, mount.export_name);
                defer self.allocator.free(escaped_export);
                try out.writer(self.allocator).print(
                    "{{\"mount_path\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"{s}\"}}",
                    .{ escaped_path, escaped_node, escaped_export },
                );
            }
            try out.appendSlice(self.allocator, "],\"binds\":[");
            for (project.binds.items, 0..) |bind, idx| {
                if (idx != 0) try out.append(self.allocator, ',');
                const escaped_bind = try jsonEscape(self.allocator, bind.bind_path);
                defer self.allocator.free(escaped_bind);
                const escaped_target = try jsonEscape(self.allocator, bind.target_path);
                defer self.allocator.free(escaped_target);
                try out.writer(self.allocator).print(
                    "{{\"bind_path\":\"{s}\",\"target_path\":\"{s}\"}}",
                    .{ escaped_bind, escaped_target },
                );
            }
            try out.appendSlice(self.allocator, "]}");
        }

        try out.appendSlice(self.allocator, "],\"installed_venom_releases\":[");
        for (self.installed_venom_releases.items, 0..) |release, idx| {
            if (idx != 0) try out.append(self.allocator, ',');
            try appendInstalledVenomReleaseJson(self.allocator, &out, release);
        }

        try out.appendSlice(self.allocator, "],\"installed_venom_packages\":[");
        for (self.installed_venom_packages.items, 0..) |package, idx| {
            if (idx != 0) try out.append(self.allocator, ',');
            try venom_package_model.appendPackageJson(self.allocator, &out, package);
        }

        try out.appendSlice(self.allocator, "],\"active_workspace_by_agent\":[");
        first = true;
        var active_it = self.active_workspace_by_agent.iterator();
        while (active_it.next()) |entry| {
            if (!first) try out.append(self.allocator, ',');
            first = false;
            const escaped_agent = try jsonEscape(self.allocator, entry.key_ptr.*);
            defer self.allocator.free(escaped_agent);
            const escaped_workspace = try jsonEscape(self.allocator, entry.value_ptr.*);
            defer self.allocator.free(escaped_workspace);
            try out.writer(self.allocator).print(
                "{{\"agent_id\":\"{s}\",\"workspace_id\":\"{s}\"}}",
                .{ escaped_agent, escaped_workspace },
            );
        }

        try out.appendSlice(self.allocator, "]}");
        return out.toOwnedSlice(self.allocator);
    }

    fn restoreSnapshotFromJsonLocked(self: *ControlPlane, snapshot_json: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, snapshot_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidSnapshot;
        const root = parsed.value.object;

        self.clearState();
        self.next_invite_id = 1;
        self.next_node_id = 1;
        self.next_pending_join_id = 1;
        self.next_workspace_id = 1;

        if (root.get("next")) |next_val| {
            if (next_val != .object) return error.InvalidSnapshot;
            self.next_invite_id = try getOptionalU64(next_val.object, "invite_id", 1);
            self.next_node_id = try getOptionalU64(next_val.object, "node_id", 1);
            self.next_pending_join_id = try getOptionalU64(next_val.object, "pending_join_id", 1);
            self.next_workspace_id = try getOptionalU64(next_val.object, "workspace_id", 1);
        } else {
            self.next_invite_id = try getOptionalU64(root, "next_invite_id", 1);
            self.next_node_id = try getOptionalU64(root, "next_node_id", 1);
            self.next_pending_join_id = try getOptionalU64(root, "next_pending_join_id", 1);
            self.next_workspace_id = try getOptionalU64(root, "next_workspace_id", 1);
        }

        if (root.get("metrics")) |metrics_val| {
            if (metrics_val != .object) return error.InvalidSnapshot;
            self.invites_created_total = try getOptionalU64(metrics_val.object, "invites_created_total", 0);
            self.invites_redeemed_total = try getOptionalU64(metrics_val.object, "invites_redeemed_total", 0);
            self.node_joins_total = try getOptionalU64(metrics_val.object, "node_joins_total", 0);
            self.node_lease_refresh_total = try getOptionalU64(metrics_val.object, "node_lease_refresh_total", 0);
            self.nodes_ensured_total = try getOptionalU64(metrics_val.object, "nodes_ensured_total", 0);
            self.node_deletes_total = try getOptionalU64(metrics_val.object, "node_deletes_total", 0);
            self.workspace_creates_total = try getOptionalU64(metrics_val.object, "workspace_creates_total", 0);
            self.workspace_updates_total = try getOptionalU64(metrics_val.object, "workspace_updates_total", 0);
            self.workspace_deletes_total = try getOptionalU64(metrics_val.object, "workspace_deletes_total", 0);
            self.workspace_token_rotates_total = try getOptionalU64(metrics_val.object, "workspace_token_rotates_total", 0);
            self.workspace_token_revokes_total = try getOptionalU64(metrics_val.object, "workspace_token_revokes_total", 0);
            self.mount_sets_total = try getOptionalU64(metrics_val.object, "mount_sets_total", 0);
            self.mount_removes_total = try getOptionalU64(metrics_val.object, "mount_removes_total", 0);
            self.workspace_activations_total = try getOptionalU64(metrics_val.object, "workspace_activations_total", 0);
            self.lease_reap_nodes_total = try getOptionalU64(metrics_val.object, "lease_reap_nodes_total", 0);
        }

        if (root.get("invites")) |invites_val| {
            if (invites_val != .array) return error.InvalidSnapshot;
            for (invites_val.array.items) |item| {
                if (item != .object) return error.InvalidSnapshot;
                var invite = Invite{
                    .id = try dupeRequiredString(self.allocator, item.object, "id"),
                    .token = try dupeRequiredString(self.allocator, item.object, "token"),
                    .created_at_ms = try getRequiredI64(item.object, "created_at_ms"),
                    .expires_at_ms = try getRequiredI64(item.object, "expires_at_ms"),
                    .redeemed = try getRequiredBool(item.object, "redeemed"),
                };
                errdefer invite.deinit(self.allocator);
                if (self.invites.contains(invite.id)) return error.InvalidSnapshot;
                try self.invites.put(self.allocator, invite.id, invite);
            }
        }

        if (root.get("nodes")) |nodes_val| {
            if (nodes_val != .array) return error.InvalidSnapshot;
            for (nodes_val.array.items) |item| {
                if (item != .object) return error.InvalidSnapshot;
                const fs_url = if (item.object.get("fs_url")) |url_val| blk: {
                    if (url_val != .string) return error.InvalidSnapshot;
                    break :blk try self.allocator.dupe(u8, url_val.string);
                } else try self.allocator.dupe(u8, "");
                var node = Node{
                    .id = try dupeRequiredString(self.allocator, item.object, "id"),
                    .name = try dupeRequiredString(self.allocator, item.object, "name"),
                    .fs_url = fs_url,
                    .secret = try dupeRequiredString(self.allocator, item.object, "secret"),
                    .lease_token = try dupeRequiredString(self.allocator, item.object, "lease_token"),
                    .platform_os = if (item.object.get("platform")) |platform_val| blk: {
                        if (platform_val != .object) return error.InvalidSnapshot;
                        const os_val = platform_val.object.get("os") orelse return error.InvalidSnapshot;
                        if (os_val != .string or os_val.string.len == 0) return error.InvalidSnapshot;
                        break :blk try self.allocator.dupe(u8, os_val.string);
                    } else try self.allocator.dupe(u8, default_platform_os),
                    .platform_arch = if (item.object.get("platform")) |platform_val| blk: {
                        if (platform_val != .object) return error.InvalidSnapshot;
                        const arch_val = platform_val.object.get("arch") orelse return error.InvalidSnapshot;
                        if (arch_val != .string or arch_val.string.len == 0) return error.InvalidSnapshot;
                        break :blk try self.allocator.dupe(u8, arch_val.string);
                    } else try self.allocator.dupe(u8, default_platform_arch),
                    .platform_runtime_kind = if (item.object.get("platform")) |platform_val| blk: {
                        if (platform_val != .object) return error.InvalidSnapshot;
                        const runtime_val = platform_val.object.get("runtime_kind") orelse return error.InvalidSnapshot;
                        if (runtime_val != .string or runtime_val.string.len == 0) return error.InvalidSnapshot;
                        break :blk try self.allocator.dupe(u8, runtime_val.string);
                    } else try self.allocator.dupe(u8, default_platform_runtime_kind),
                    .joined_at_ms = try getRequiredI64(item.object, "joined_at_ms"),
                    .last_seen_ms = try getRequiredI64(item.object, "last_seen_ms"),
                    .lease_expires_at_ms = try getRequiredI64(item.object, "lease_expires_at_ms"),
                };
                errdefer node.deinit(self.allocator);
                if (item.object.get("labels")) |labels_val| {
                    replaceNodeLabelsFromValue(self.allocator, &node.labels, labels_val) catch return error.InvalidSnapshot;
                }
                if (item.object.get("venoms")) |venoms_val| {
                    var package_ids = std.ArrayListUnmanaged(?[]const u8){};
                    defer package_ids.deinit(self.allocator);
                    try collectNodeVenomPackageIds(self.allocator, venoms_val, &package_ids);
                    venom_catalog.replaceVenomsFromJsonValue(self.allocator, &node.venoms, venoms_val) catch return error.InvalidSnapshot;
                    node.venom_package_ids = try cloneNodeVenomPackageIds(self.allocator, package_ids.items);
                }
                if (self.nodes.contains(node.id)) return error.InvalidSnapshot;
                try self.nodes.put(self.allocator, node.id, node);
            }
        }

        if (root.get("pending_joins")) |pending_val| {
            if (pending_val != .array) return error.InvalidSnapshot;
            for (pending_val.array.items) |item| {
                if (item != .object) return error.InvalidSnapshot;
                const fs_url = if (item.object.get("fs_url")) |url_val| blk: {
                    if (url_val != .string) return error.InvalidSnapshot;
                    break :blk try self.allocator.dupe(u8, url_val.string);
                } else try self.allocator.dupe(u8, "");

                const platform_val = item.object.get("platform");
                var pending = PendingJoin{
                    .id = try dupeRequiredString(self.allocator, item.object, "id"),
                    .node_name = try dupeRequiredString(self.allocator, item.object, "node_name"),
                    .fs_url = fs_url,
                    .platform_os = if (platform_val) |value| blk: {
                        if (value != .object) return error.InvalidSnapshot;
                        const os_val = value.object.get("os") orelse return error.InvalidSnapshot;
                        if (os_val != .string or os_val.string.len == 0) return error.InvalidSnapshot;
                        break :blk try self.allocator.dupe(u8, os_val.string);
                    } else try self.allocator.dupe(u8, default_platform_os),
                    .platform_arch = if (platform_val) |value| blk: {
                        if (value != .object) return error.InvalidSnapshot;
                        const arch_val = value.object.get("arch") orelse return error.InvalidSnapshot;
                        if (arch_val != .string or arch_val.string.len == 0) return error.InvalidSnapshot;
                        break :blk try self.allocator.dupe(u8, arch_val.string);
                    } else try self.allocator.dupe(u8, default_platform_arch),
                    .platform_runtime_kind = if (platform_val) |value| blk: {
                        if (value != .object) return error.InvalidSnapshot;
                        const runtime_val = value.object.get("runtime_kind") orelse return error.InvalidSnapshot;
                        if (runtime_val != .string or runtime_val.string.len == 0) return error.InvalidSnapshot;
                        break :blk try self.allocator.dupe(u8, runtime_val.string);
                    } else try self.allocator.dupe(u8, default_platform_runtime_kind),
                    .requested_at_ms = try getRequiredI64(item.object, "requested_at_ms"),
                };
                errdefer pending.deinit(self.allocator);
                if (self.pending_joins.contains(pending.id)) return error.InvalidSnapshot;
                try self.pending_joins.put(self.allocator, pending.id, pending);
            }
        }

        const workspaces_val = root.get("workspaces");
        if (workspaces_val) |items_val| {
            if (items_val != .array) return error.InvalidSnapshot;
            for (items_val.array.items) |item| {
                if (item != .object) return error.InvalidSnapshot;
                const kind = if (item.object.get("kind")) |kind_val| blk: {
                    if (kind_val != .string) return error.InvalidSnapshot;
                    break :blk parseProjectKind(kind_val.string);
                } else if (item.object.get("id")) |id_val|
                    if (id_val == .string and std.mem.eql(u8, id_val.string, host_workspace_id))
                        WorkspaceKind.host_internal
                    else
                        WorkspaceKind.normal
                else
                    WorkspaceKind.normal;
                const is_delete_protected = if (item.object.get("is_delete_protected")) |protected_val| blk: {
                    if (protected_val != .bool) return error.InvalidSnapshot;
                    break :blk protected_val.bool;
                } else kind == .host_internal;
                const token_locked = if (item.object.get("token_locked")) |locked_val| blk: {
                    if (locked_val != .bool) return error.InvalidSnapshot;
                    break :blk locked_val.bool;
                } else if (kind == .host_internal)
                    true
                else
                    false;
                var parsed_access_policy: ?WorkspaceAccessPolicy = null;
                errdefer if (parsed_access_policy) |*policy| policy.deinit(self.allocator);
                if (item.object.get("access_policy")) |policy_value| {
                    parsed_access_policy = parseWorkspaceAccessPolicyValue(self.allocator, policy_value) catch return error.InvalidSnapshot;
                }
                var project = Workspace{
                    .id = try dupeRequiredString(self.allocator, item.object, "id"),
                    .name = try dupeRequiredString(self.allocator, item.object, "name"),
                    .vision = try dupeRequiredString(self.allocator, item.object, "vision"),
                    .status = try dupeRequiredString(self.allocator, item.object, "status"),
                    .template_id = if (item.object.get("template_id")) |template_val| blk: {
                        if (template_val != .string) return error.InvalidSnapshot;
                        if (kind == .host_internal) break :blk try self.allocator.dupe(u8, "");
                        if (template_val.string.len == 0) return error.InvalidSnapshot;
                        break :blk try self.allocator.dupe(u8, template_val.string);
                    } else try self.allocator.dupe(u8, defaultTemplateIdForProjectKind(kind)),
                    .kind = kind,
                    .is_delete_protected = is_delete_protected,
                    .token_locked = token_locked,
                    .mutation_token = if (item.object.get("mutation_token")) |token_val| blk: {
                        if (token_val != .string or token_val.string.len == 0) return error.InvalidSnapshot;
                        break :blk try self.allocator.dupe(u8, token_val.string);
                    } else try makeToken(self.allocator, "ws"),
                    .access_policy = if (parsed_access_policy) |policy| policy else .{},
                    .created_at_ms = try getRequiredI64(item.object, "created_at_ms"),
                    .updated_at_ms = try getRequiredI64(item.object, "updated_at_ms"),
                };
                parsed_access_policy = null;
                errdefer project.deinit(self.allocator);
                if (self.workspaces.contains(project.id)) return error.InvalidSnapshot;

                const mounts_val = item.object.get("mounts") orelse return error.InvalidSnapshot;
                if (mounts_val != .array) return error.InvalidSnapshot;
                for (mounts_val.array.items) |mount_item| {
                    if (mount_item != .object) return error.InvalidSnapshot;
                    var mount = WorkspaceMount{
                        .mount_path = try dupeRequiredString(self.allocator, mount_item.object, "mount_path"),
                        .node_id = try dupeRequiredString(self.allocator, mount_item.object, "node_id"),
                        .export_name = try dupeRequiredString(self.allocator, mount_item.object, "export_name"),
                    };
                    errdefer mount.deinit(self.allocator);
                    try project.mounts.append(self.allocator, mount);
                }
                if (item.object.get("binds")) |binds_val| {
                    if (binds_val != .array) return error.InvalidSnapshot;
                    for (binds_val.array.items) |bind_item| {
                        if (bind_item != .object) return error.InvalidSnapshot;
                        var bind = WorkspaceBind{
                            .bind_path = try dupeRequiredString(self.allocator, bind_item.object, "bind_path"),
                            .target_path = try dupeRequiredString(self.allocator, bind_item.object, "target_path"),
                        };
                        errdefer bind.deinit(self.allocator);
                        try project.binds.append(self.allocator, bind);
                    }
                }
                try self.workspaces.put(self.allocator, project.id, project);
            }
        }

        if (root.get("installed_venom_releases")) |releases_val| {
            if (releases_val != .array) return error.InvalidSnapshot;
            for (releases_val.array.items) |item| {
                var release = parseInstalledVenomReleaseValue(self.allocator, item) catch return error.InvalidSnapshot;
                errdefer release.deinit(self.allocator);
                try self.installed_venom_releases.append(self.allocator, release);
            }
            try rebuildInstalledVenomPackagesFromReleasesLocked(self);
        } else if (root.get("installed_venom_packages")) |packages_val| {
            var legacy_packages = std.ArrayListUnmanaged(venom_package_model.VenomPackage){};
            errdefer venom_package_model.deinitPackages(self.allocator, &legacy_packages);
            venom_package_model.replacePackagesFromJsonValue(self.allocator, &legacy_packages, packages_val) catch return error.InvalidSnapshot;
            for (legacy_packages.items) |package| {
                const owned_package = package;
                try self.installed_venom_releases.append(self.allocator, .{
                    .package_id = try self.allocator.dupe(u8, owned_package.venom_id),
                    .package = owned_package,
                });
            }
            legacy_packages.items.len = 0;
            venom_package_model.deinitPackages(self.allocator, &legacy_packages);
            try rebuildInstalledVenomPackagesFromReleasesLocked(self);
        }

        const active_workspace_bindings_val = root.get("active_workspace_by_agent");
        if (active_workspace_bindings_val) |active_val| {
            if (active_val != .array) return error.InvalidSnapshot;
            for (active_val.array.items) |item| {
                if (item != .object) return error.InvalidSnapshot;
                const agent_id = try dupeRequiredString(self.allocator, item.object, "agent_id");
                errdefer self.allocator.free(agent_id);
                const workspace_id = try dupeRequiredString(self.allocator, item.object, "workspace_id");
                errdefer self.allocator.free(workspace_id);
                if (self.active_workspace_by_agent.contains(agent_id)) return error.InvalidSnapshot;
                try self.active_workspace_by_agent.put(self.allocator, agent_id, workspace_id);
            }
        }

        // Normalize stale pointers from historic snapshots.
        var normalize_it = self.active_workspace_by_agent.iterator();
        while (normalize_it.next()) |entry| {
            if (entry.value_ptr.*.len == 0) continue;
            if (self.workspaces.get(entry.value_ptr.*)) |project| {
                if (project.kind == .host_internal) {
                    self.allocator.free(entry.value_ptr.*);
                    entry.value_ptr.* = try self.allocator.dupe(u8, "");
                }
                continue;
            }
            if (!self.workspaces.contains(entry.value_ptr.*)) {
                self.allocator.free(entry.value_ptr.*);
                entry.value_ptr.* = try self.allocator.dupe(u8, "");
            }
        }
    }
};

const ParsedPayload = std.json.Parsed(std.json.Value);

fn parsePayload(allocator: std.mem.Allocator, payload_json: ?[]const u8) !ParsedPayload {
    const raw = payload_json orelse "{}";
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    errdefer parsed.deinit();
    if (parsed.value != .object) return ControlPlaneError.InvalidPayload;
    return parsed;
}

fn parseVenomPackageValue(allocator: std.mem.Allocator, value: std.json.Value) !venom_package_model.VenomPackage {
    if (value != .object) return ControlPlaneError.InvalidPayload;
    const wrapped = try std.fmt.allocPrint(allocator, "[{f}]", .{std.json.fmt(value, .{})});
    defer allocator.free(wrapped);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, wrapped, .{});
    defer parsed.deinit();

    var packages = std.ArrayListUnmanaged(venom_package_model.VenomPackage){};
    errdefer venom_package_model.deinitPackages(allocator, &packages);
    venom_package_model.replacePackagesFromJsonValue(allocator, &packages, parsed.value) catch return ControlPlaneError.InvalidPayload;
    if (packages.items.len != 1) return ControlPlaneError.InvalidPayload;
    const package = packages.items[0];
    packages.items.len = 0;
    venom_package_model.deinitPackages(allocator, &packages);
    return package;
}

fn parseInstalledVenomReleaseValue(allocator: std.mem.Allocator, value: std.json.Value) !InstalledVenomRelease {
    if (value != .object) return ControlPlaneError.InvalidPayload;

    const release_value = if (value.object.get("release")) |wrapped| wrapped else value;
    if (release_value != .object) return ControlPlaneError.InvalidPayload;

    var package = try parseVenomPackageValue(allocator, release_value.object.get("package") orelse release_value);
    errdefer package.deinit(allocator);

    const package_id = getOptionalString(release_value.object, "package_id") orelse package.venom_id;
    try validateIdentifier(package_id, 128);

    if (!std.mem.eql(u8, package.venom_id, package_id)) {
        allocator.free(package.venom_id);
        package.venom_id = try allocator.dupe(u8, package_id);
    }

    if (getOptionalString(release_value.object, "release_version")) |release_version| {
        allocator.free(package.release_version);
        package.release_version = try allocator.dupe(u8, release_version);
    }
    if (getOptionalString(release_value.object, "channel")) |channel| {
        if (package.channel) |channel_value| allocator.free(channel_value);
        package.channel = try allocator.dupe(u8, channel);
    }
    if (getOptionalString(release_value.object, "digest")) |digest| {
        if (package.digest) |digest_value| allocator.free(digest_value);
        package.digest = try allocator.dupe(u8, digest);
    }
    if (release_value.object.get("signature")) |signature| {
        if (package.signature_json) |signature_value| allocator.free(signature_value);
        package.signature_json = try optionalObjectJsonOrNull(allocator, signature);
    }
    if (release_value.object.get("trust")) |trust| {
        if (package.trust_json) |trust_value| allocator.free(trust_value);
        package.trust_json = try optionalObjectJsonOrNull(allocator, trust);
    }
    if (release_value.object.get("enabled")) |enabled_value| {
        if (enabled_value != .bool) return ControlPlaneError.InvalidPayload;
        package.enabled = enabled_value.bool;
    }

    return .{
        .package_id = try allocator.dupe(u8, package_id),
        .package = package,
    };
}

fn optionalObjectJsonOrNull(allocator: std.mem.Allocator, value: std.json.Value) !?[]u8 {
    return switch (value) {
        .object => blk: {
            break :blk try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
        },
        .null => null,
        else => ControlPlaneError.InvalidPayload,
    };
}

fn appendInstalledVenomReleaseJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    release: InstalledVenomRelease,
) !void {
    const escaped_package_id = try jsonEscape(allocator, release.package_id);
    defer allocator.free(escaped_package_id);
    const escaped_release_version = try jsonEscape(allocator, release.package.release_version);
    defer allocator.free(escaped_release_version);
    const release_id = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ release.package_id, release.package.release_version });
    defer allocator.free(release_id);
    const escaped_release_id = try jsonEscape(allocator, release_id);
    defer allocator.free(escaped_release_id);
    const channel_json = try optionalJsonStringField(allocator, release.package.channel);
    defer allocator.free(channel_json);
    const digest_json = try optionalJsonStringField(allocator, release.package.digest);
    defer allocator.free(digest_json);
    const signature_json = if (release.package.signature_json) |value|
        try allocator.dupe(u8, value)
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(signature_json);
    const trust_json = if (release.package.trust_json) |value|
        try allocator.dupe(u8, value)
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(trust_json);

    try out.writer(allocator).print(
        "{{\"release_id\":\"{s}\",\"package_id\":\"{s}\",\"release_version\":\"{s}\",\"version\":\"{s}\",\"channel\":{s},\"digest\":{s},\"signature\":{s},\"trust\":{s},\"enabled\":{},\"package\":",
        .{
            escaped_release_id,
            escaped_package_id,
            escaped_release_version,
            escaped_release_version,
            channel_json,
            digest_json,
            signature_json,
            trust_json,
            release.package.enabled,
        },
    );
    try venom_package_model.appendPackageJson(allocator, out, release.package);
    try out.append(allocator, '}');
}

fn optionalJsonStringField(allocator: std.mem.Allocator, value: ?[]const u8) ![]u8 {
    if (value) |raw| {
        const escaped = try jsonEscape(allocator, raw);
        defer allocator.free(escaped);
        return std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    }
    return allocator.dupe(u8, "null");
}

fn deinitInstalledVenomReleases(
    allocator: std.mem.Allocator,
    releases: *std.ArrayListUnmanaged(InstalledVenomRelease),
) void {
    for (releases.items) |*release| release.deinit(allocator);
    releases.deinit(allocator);
    releases.* = .{};
}

fn rebuildInstalledVenomPackagesFromReleasesLocked(self: *ControlPlane) !void {
    venom_package_model.deinitPackages(self.allocator, &self.installed_venom_packages);

    var selected_by_package_id = std.StringHashMapUnmanaged(usize){};
    defer selected_by_package_id.deinit(self.allocator);

    for (self.installed_venom_releases.items, 0..) |release, idx| {
        if (selected_by_package_id.get(release.package_id)) |existing_idx| {
            const existing = self.installed_venom_releases.items[existing_idx];
            if (installedReleaseBeatsForProjection(release, existing)) {
                try selected_by_package_id.put(self.allocator, release.package_id, idx);
            }
            continue;
        }
        try selected_by_package_id.put(self.allocator, release.package_id, idx);
    }

    var release_it = selected_by_package_id.iterator();
    while (release_it.next()) |entry| {
        const release = self.installed_venom_releases.items[entry.value_ptr.*];
        try self.installed_venom_packages.append(self.allocator, try clonePackage(self.allocator, release.package));
    }
}

fn installedReleaseBeatsForProjection(candidate: InstalledVenomRelease, existing: InstalledVenomRelease) bool {
    if (candidate.package.enabled != existing.package.enabled) return candidate.package.enabled;
    return compareReleaseVersions(candidate.package.release_version, existing.package.release_version) == .gt;
}

fn findPreferredInstalledReleaseIndex(
    releases: []const InstalledVenomRelease,
    package_id: []const u8,
) ?usize {
    var selected_index: ?usize = null;
    for (releases, 0..) |release, idx| {
        if (!std.mem.eql(u8, release.package_id, package_id)) continue;
        if (selected_index == null or installedReleaseBeatsForProjection(release, releases[selected_index.?])) {
            selected_index = idx;
        }
    }
    return selected_index;
}

fn findInstalledReleaseIndex(
    releases: []const InstalledVenomRelease,
    package_id: []const u8,
    release_version: []const u8,
) ?usize {
    for (releases, 0..) |release, idx| {
        if (!std.mem.eql(u8, release.package_id, package_id)) continue;
        if (!std.mem.eql(u8, release.package.release_version, release_version)) continue;
        return idx;
    }
    return null;
}

fn findEnabledInstalledReleaseIndex(
    releases: []const InstalledVenomRelease,
    package_id: []const u8,
) ?usize {
    for (releases, 0..) |release, idx| {
        if (!std.mem.eql(u8, release.package_id, package_id)) continue;
        if (!release.package.enabled) continue;
        return idx;
    }
    return null;
}

fn findRollbackInstalledReleaseIndex(
    releases: []const InstalledVenomRelease,
    package_id: []const u8,
) ?usize {
    const current_index = findEnabledInstalledReleaseIndex(releases, package_id) orelse
        findPreferredInstalledReleaseIndex(releases, package_id) orelse
        return null;
    const current = releases[current_index];

    var fallback_index: ?usize = null;
    var previous_index: ?usize = null;
    for (releases, 0..) |release, idx| {
        if (!std.mem.eql(u8, release.package_id, package_id)) continue;
        if (idx == current_index) continue;

        if (fallback_index == null or installedReleaseBeatsForProjection(release, releases[fallback_index.?])) {
            fallback_index = idx;
        }

        if (compareReleaseVersions(release.package.release_version, current.package.release_version) != .lt) continue;
        if (previous_index == null or compareReleaseVersions(release.package.release_version, releases[previous_index.?].package.release_version) == .gt) {
            previous_index = idx;
        }
    }

    return previous_index orelse fallback_index;
}

fn clonePackage(allocator: std.mem.Allocator, package: venom_package_model.VenomPackage) !venom_package_model.VenomPackage {
    return .{
        .venom_id = try allocator.dupe(u8, package.venom_id),
        .kind = try allocator.dupe(u8, package.kind),
        .version = try allocator.dupe(u8, package.version),
        .release_version = try allocator.dupe(u8, package.release_version),
        .channel = if (package.channel) |value| try allocator.dupe(u8, value) else null,
        .digest = if (package.digest) |value| try allocator.dupe(u8, value) else null,
        .signature_json = if (package.signature_json) |value| try allocator.dupe(u8, value) else null,
        .trust_json = if (package.trust_json) |value| try allocator.dupe(u8, value) else null,
        .enabled = package.enabled,
        .categories_json = try allocator.dupe(u8, package.categories_json),
        .host_roles_json = try allocator.dupe(u8, package.host_roles_json),
        .binding_scopes_json = try allocator.dupe(u8, package.binding_scopes_json),
        .runtime_kind = package.runtime_kind,
        .requirements_json = try allocator.dupe(u8, package.requirements_json),
        .capabilities_json = try allocator.dupe(u8, package.capabilities_json),
        .ops_json = try allocator.dupe(u8, package.ops_json),
        .runtime_json = try allocator.dupe(u8, package.runtime_json),
        .permissions_json = try allocator.dupe(u8, package.permissions_json),
        .schema_json = try allocator.dupe(u8, package.schema_json),
        .help_md = if (package.help_md) |value| try allocator.dupe(u8, value) else null,
    };
}

fn compareReleaseVersions(a: []const u8, b: []const u8) std.math.Order {
    const parsed_a = std.SemanticVersion.parse(a) catch return std.mem.order(u8, a, b);
    const parsed_b = std.SemanticVersion.parse(b) catch return std.mem.order(u8, a, b);
    return parsed_a.order(parsed_b);
}

fn getRequiredString(obj: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = obj.get(name) orelse return ControlPlaneError.MissingField;
    if (value != .string or value.string.len == 0) return ControlPlaneError.InvalidPayload;
    return value.string;
}

fn getOptionalString(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = obj.get(name) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getOptionalUnsigned(obj: std.json.ObjectMap, name: []const u8, default_value: u64) !u64 {
    const value = obj.get(name) orelse return default_value;
    if (value != .integer or value.integer < 0) return ControlPlaneError.InvalidPayload;
    return @intCast(value.integer);
}

fn getOptionalBool(obj: std.json.ObjectMap, name: []const u8, default_value: bool) !bool {
    const value = obj.get(name) orelse return default_value;
    if (value != .bool) return ControlPlaneError.InvalidPayload;
    return value.bool;
}

const PlatformPayload = struct {
    os: []u8,
    arch: []u8,
    runtime_kind: []u8,

    fn deinit(self: *PlatformPayload, allocator: std.mem.Allocator) void {
        allocator.free(self.os);
        allocator.free(self.arch);
        allocator.free(self.runtime_kind);
        self.* = undefined;
    }
};

fn parsePlatformFromPayloadValue(
    allocator: std.mem.Allocator,
    raw_value: ?std.json.Value,
) !PlatformPayload {
    var out = PlatformPayload{
        .os = try allocator.dupe(u8, default_platform_os),
        .arch = try allocator.dupe(u8, default_platform_arch),
        .runtime_kind = try allocator.dupe(u8, default_platform_runtime_kind),
    };
    errdefer out.deinit(allocator);

    const raw = raw_value orelse return out;
    if (raw != .object) return ControlPlaneError.InvalidPayload;

    if (raw.object.get("os")) |value| {
        if (value != .string or value.string.len == 0) return ControlPlaneError.InvalidPayload;
        try validateIdentifier(value.string, 64);
        allocator.free(out.os);
        out.os = try allocator.dupe(u8, value.string);
    }
    if (raw.object.get("arch")) |value| {
        if (value != .string or value.string.len == 0) return ControlPlaneError.InvalidPayload;
        try validateIdentifier(value.string, 64);
        allocator.free(out.arch);
        out.arch = try allocator.dupe(u8, value.string);
    }
    if (raw.object.get("runtime_kind")) |value| {
        if (value != .string or value.string.len == 0) return ControlPlaneError.InvalidPayload;
        try validateIdentifier(value.string, 64);
        allocator.free(out.runtime_kind);
        out.runtime_kind = try allocator.dupe(u8, value.string);
    }

    return out;
}

fn applyPlatformUpdateFromValue(
    allocator: std.mem.Allocator,
    node: *Node,
    raw: std.json.Value,
) !void {
    if (raw != .object) return ControlPlaneError.InvalidPayload;

    if (raw.object.get("os")) |value| {
        if (value != .string or value.string.len == 0) return ControlPlaneError.InvalidPayload;
        try validateIdentifier(value.string, 64);
        allocator.free(node.platform_os);
        node.platform_os = try allocator.dupe(u8, value.string);
    }
    if (raw.object.get("arch")) |value| {
        if (value != .string or value.string.len == 0) return ControlPlaneError.InvalidPayload;
        try validateIdentifier(value.string, 64);
        allocator.free(node.platform_arch);
        node.platform_arch = try allocator.dupe(u8, value.string);
    }
    if (raw.object.get("runtime_kind")) |value| {
        if (value != .string or value.string.len == 0) return ControlPlaneError.InvalidPayload;
        try validateIdentifier(value.string, 64);
        allocator.free(node.platform_runtime_kind);
        node.platform_runtime_kind = try allocator.dupe(u8, value.string);
    }
}

fn replaceNodeLabelsFromValue(
    allocator: std.mem.Allocator,
    labels: *std.ArrayListUnmanaged(NodeLabel),
    raw: std.json.Value,
) !void {
    if (raw != .object) return ControlPlaneError.InvalidPayload;

    var next = std.ArrayListUnmanaged(NodeLabel){};
    errdefer {
        for (next.items) |*label| label.deinit(allocator);
        next.deinit(allocator);
    }

    var it = raw.object.iterator();
    while (it.next()) |entry| {
        try validateIdentifier(entry.key_ptr.*, 128);
        if (entry.value_ptr.* != .string) return ControlPlaneError.InvalidPayload;
        try validateDisplayStringAllowEmpty(entry.value_ptr.*.string, 512);
        var label = NodeLabel{
            .key = try allocator.dupe(u8, entry.key_ptr.*),
            .value = try allocator.dupe(u8, entry.value_ptr.*.string),
        };
        errdefer label.deinit(allocator);
        try next.append(allocator, label);
    }

    for (labels.items) |*label| label.deinit(allocator);
    labels.deinit(allocator);
    labels.* = next;
}

fn appendPendingJoinJsonAlloc(allocator: std.mem.Allocator, pending: PendingJoin) ![]u8 {
    const escaped_id = try jsonEscape(allocator, pending.id);
    defer allocator.free(escaped_id);
    const escaped_name = try jsonEscape(allocator, pending.node_name);
    defer allocator.free(escaped_name);
    const escaped_url = try jsonEscape(allocator, pending.fs_url);
    defer allocator.free(escaped_url);
    const escaped_platform_os = try jsonEscape(allocator, pending.platform_os);
    defer allocator.free(escaped_platform_os);
    const escaped_platform_arch = try jsonEscape(allocator, pending.platform_arch);
    defer allocator.free(escaped_platform_arch);
    const escaped_platform_runtime = try jsonEscape(allocator, pending.platform_runtime_kind);
    defer allocator.free(escaped_platform_runtime);
    return std.fmt.allocPrint(
        allocator,
        "{{\"request_id\":\"{s}\",\"node_name\":\"{s}\",\"fs_url\":\"{s}\",\"platform\":{{\"os\":\"{s}\",\"arch\":\"{s}\",\"runtime_kind\":\"{s}\"}},\"requested_at_ms\":{d}}}",
        .{
            escaped_id,
            escaped_name,
            escaped_url,
            escaped_platform_os,
            escaped_platform_arch,
            escaped_platform_runtime,
            pending.requested_at_ms,
        },
    );
}

fn getOptionalU64(obj: std.json.ObjectMap, name: []const u8, default_value: u64) !u64 {
    const value = obj.get(name) orelse return default_value;
    if (value != .integer or value.integer < 0) return error.InvalidSnapshot;
    return @intCast(value.integer);
}

fn getOptionalU64ByNames(obj: std.json.ObjectMap, names: []const []const u8, default_value: u64) !u64 {
    for (names) |name| {
        if (obj.get(name) != null) {
            return getOptionalU64(obj, name, default_value);
        }
    }
    return default_value;
}

fn dupeRequiredString(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    name: []const u8,
) ![]u8 {
    const value = obj.get(name) orelse return error.InvalidSnapshot;
    if (value != .string) return error.InvalidSnapshot;
    return allocator.dupe(u8, value.string);
}

fn getRequiredI64(obj: std.json.ObjectMap, name: []const u8) !i64 {
    const value = obj.get(name) orelse return error.InvalidSnapshot;
    if (value != .integer) return error.InvalidSnapshot;
    return value.integer;
}

fn getRequiredBool(obj: std.json.ObjectMap, name: []const u8) !bool {
    const value = obj.get(name) orelse return error.InvalidSnapshot;
    if (value != .bool) return error.InvalidSnapshot;
    return value.bool;
}

fn makeSequentialId(allocator: std.mem.Allocator, prefix: []const u8, counter: *u64) ![]u8 {
    const id = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ prefix, counter.* });
    counter.* += 1;
    return id;
}

fn makeToken(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    try out.writer(allocator).print("{s}-", .{prefix});
    for (bytes) |byte| {
        try out.writer(allocator).print("{x:0>2}", .{byte});
    }
    return out.toOwnedSlice(allocator);
}

fn appendNodeVenomJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    venom: venom_catalog.VenomDescriptor,
    package_id: ?[]const u8,
) !void {
    if (package_id == null) {
        try venom_catalog.appendVenomJson(allocator, out, venom);
        return;
    }
    if (venom.package_id) |existing_package_id| {
        if (std.mem.eql(u8, existing_package_id, package_id.?)) {
            try venom_catalog.appendVenomJson(allocator, out, venom);
            return;
        }
    } else if (std.mem.eql(u8, package_id.?, venom.venom_id)) {
        try venom_catalog.appendVenomJson(allocator, out, venom);
        return;
    }

    var rendered = venom;
    rendered.package_id = @constCast(package_id.?);
    try venom_catalog.appendVenomJson(allocator, out, rendered);
}

fn appendNodeJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), node: Node) !void {
    const escaped_id = try jsonEscape(allocator, node.id);
    defer allocator.free(escaped_id);
    const escaped_name = try jsonEscape(allocator, node.name);
    defer allocator.free(escaped_name);
    const escaped_url = try jsonEscape(allocator, node.fs_url);
    defer allocator.free(escaped_url);
    const escaped_platform_os = try jsonEscape(allocator, node.platform_os);
    defer allocator.free(escaped_platform_os);
    const escaped_platform_arch = try jsonEscape(allocator, node.platform_arch);
    defer allocator.free(escaped_platform_arch);
    const escaped_platform_runtime = try jsonEscape(allocator, node.platform_runtime_kind);
    defer allocator.free(escaped_platform_runtime);
    try out.writer(allocator).print(
        "{{\"node_id\":\"{s}\",\"node_name\":\"{s}\",\"fs_url\":\"{s}\",\"platform\":{{\"os\":\"{s}\",\"arch\":\"{s}\",\"runtime_kind\":\"{s}\"}},\"venom_count\":{d},\"joined_at_ms\":{d},\"last_seen_ms\":{d},\"lease_expires_at_ms\":{d}}}",
        .{
            escaped_id,
            escaped_name,
            escaped_url,
            escaped_platform_os,
            escaped_platform_arch,
            escaped_platform_runtime,
            node.venoms.items.len,
            node.joined_at_ms,
            node.last_seen_ms,
            node.lease_expires_at_ms,
        },
    );
}

fn appendProjectSummaryJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), project: Workspace) !void {
    const escaped_id = try jsonEscape(allocator, project.id);
    defer allocator.free(escaped_id);
    const escaped_name = try jsonEscape(allocator, project.name);
    defer allocator.free(escaped_name);
    const escaped_status = try jsonEscape(allocator, project.status);
    defer allocator.free(escaped_status);
    const escaped_kind = try jsonEscape(allocator, workspaceKindName(project.kind));
    defer allocator.free(escaped_kind);
    try out.writer(allocator).print(
        "{{\"workspace_id\":\"{s}\",\"name\":\"{s}\",\"status\":\"{s}\",\"kind\":\"{s}\",\"is_delete_protected\":{s},\"mount_count\":{d}}}",
        .{
            escaped_id,
            escaped_name,
            escaped_status,
            escaped_kind,
            if (project.is_delete_protected) "true" else "false",
            project.mounts.items.len,
        },
    );
}

fn appendMountJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), mount: WorkspaceMount) !void {
    const escaped_path = try jsonEscape(allocator, mount.mount_path);
    defer allocator.free(escaped_path);
    const escaped_node = try jsonEscape(allocator, mount.node_id);
    defer allocator.free(escaped_node);
    const escaped_export = try jsonEscape(allocator, mount.export_name);
    defer allocator.free(escaped_export);
    try out.writer(allocator).print(
        "{{\"mount_path\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"{s}\"}}",
        .{ escaped_path, escaped_node, escaped_export },
    );
}

fn appendBindJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), bind: WorkspaceBind) !void {
    const escaped_bind = try jsonEscape(allocator, bind.bind_path);
    defer allocator.free(escaped_bind);
    const escaped_target = try jsonEscape(allocator, bind.target_path);
    defer allocator.free(escaped_target);
    try out.writer(allocator).print(
        "{{\"bind_path\":\"{s}\",\"target_path\":\"{s}\"}}",
        .{ escaped_bind, escaped_target },
    );
}

fn appendWorkspaceTemplateBindJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    bind_spec: WorkspaceTemplateBindSpec,
) !void {
    const escaped_bind = try jsonEscape(allocator, bind_spec.bind_path);
    defer allocator.free(escaped_bind);
    const escaped_venom = try jsonEscape(allocator, bind_spec.venom_id);
    defer allocator.free(escaped_venom);
    const escaped_host_role = try jsonEscape(allocator, bind_spec.host_role.asString());
    defer allocator.free(escaped_host_role);
    const target_path_json = try allocator.dupe(u8, "null");
    defer allocator.free(target_path_json);

    try out.writer(allocator).print(
        "{{\"bind_path\":\"{s}\",\"venom_id\":\"{s}\",\"host_role\":\"{s}\",\"binding_scope\":\"workspace\",\"target_path\":{s}}}",
        .{ escaped_bind, escaped_venom, escaped_host_role, target_path_json },
    );
}

fn appendWorkspaceTemplateJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    template: WorkspaceTemplateSpec,
) !void {
    const escaped_id = try jsonEscape(allocator, template.id);
    defer allocator.free(escaped_id);
    const escaped_description = try jsonEscape(allocator, template.description);
    defer allocator.free(escaped_description);

    try out.writer(allocator).print(
        "{{\"template_id\":\"{s}\",\"description\":\"{s}\",\"binds\":[",
        .{ escaped_id, escaped_description },
    );
    for (template.bind_specs, 0..) |bind_spec, idx| {
        if (idx != 0) try out.append(allocator, ',');
        try appendWorkspaceTemplateBindJson(allocator, out, bind_spec);
    }
    try out.appendSlice(allocator, "]}");
}

fn appendWorkspaceAvailabilityJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    summary: ReconcileWorkspaceSummary,
) !void {
    try out.writer(allocator).print(
        "{{\"mounts_total\":{d},\"online\":{d},\"degraded\":{d},\"missing\":{d}}}",
        .{
            summary.mounts_total,
            summary.online_mounts,
            summary.degraded_mounts,
            summary.missing_mounts,
        },
    );
}

fn hashMountAvailabilityItem(mount: WorkspaceMount, state_rank: u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(mount.mount_path);
    hasher.update("\x1f");
    hasher.update(mount.node_id);
    hasher.update("\x1f");
    hasher.update(mount.export_name);
    hasher.update("\x1f");
    const state = [1]u8{state_rank};
    hasher.update(&state);
    return hasher.final();
}

fn venomHasInvokePath(allocator: std.mem.Allocator, venom: venom_catalog.VenomDescriptor) bool {
    var caps_parsed = std.json.parseFromSlice(std.json.Value, allocator, venom.capabilities_json, .{}) catch null;
    if (caps_parsed) |*parsed| {
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("invoke")) |invoke_value| {
                if (invoke_value == .bool and invoke_value.bool) return true;
            }
        }
    }

    var ops_parsed = std.json.parseFromSlice(std.json.Value, allocator, venom.ops_json, .{}) catch null;
    if (ops_parsed) |*parsed| {
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("invoke")) |invoke_value| {
                if (invoke_value == .string and std.mem.trim(u8, invoke_value.string, " \t\r\n").len > 0) return true;
            }
            if (parsed.value.object.get("paths")) |paths_value| {
                if (paths_value == .object) {
                    if (paths_value.object.get("invoke")) |invoke_value| {
                        if (invoke_value == .string and std.mem.trim(u8, invoke_value.string, " \t\r\n").len > 0) return true;
                    }
                }
            }
        }
    }
    return false;
}

fn preferredProviderCandidateBeatsSelected(candidate: *const Node, selected: *const Node) bool {
    const candidate_priority = nodeHostType(candidate).selectionPriority();
    const selected_priority = nodeHostType(selected).selectionPriority();
    if (candidate_priority != selected_priority) return candidate_priority > selected_priority;
    return std.mem.order(u8, candidate.id, selected.id) == .lt;
}

fn nodeHostType(node: *const Node) venom_model.HostType {
    if (nodeLabelValue(node, venom_model.host_type_label_key)) |value| {
        const parsed = venom_model.HostType.fromString(std.mem.trim(u8, value, " \t\r\n"));
        if (parsed != .unknown) return parsed;
    }
    return venom_model.defaultHostTypeForNodeName(node.name);
}

fn nodeLabelValue(node: *const Node, key: []const u8) ?[]const u8 {
    for (node.labels.items) |label| {
        if (std.mem.eql(u8, label.key, key)) return label.value;
    }
    return null;
}

fn preferredVenomMatchesConstraints(
    venom: *const venom_catalog.VenomDescriptor,
    constraints: PreferredVenomProviderConstraints,
) bool {
    if (constraints.host_role) |host_role| {
        if (!jsonArrayContainsStringFast(venom.host_roles_json, host_role.asString())) return false;
    }
    if (constraints.binding_scope) |binding_scope| {
        if (!jsonArrayContainsStringFast(venom.binding_scopes_json, binding_scope.asString())) return false;
    }
    return true;
}

fn jsonArrayContainsStringFast(json: []const u8, needle: []const u8) bool {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, json, cursor, "\"")) |start_quote| {
        const value_start = start_quote + 1;
        const end_quote = std.mem.indexOfPos(u8, json, value_start, "\"") orelse return false;
        if (std.mem.eql(u8, json[value_start..end_quote], needle)) return true;
        cursor = end_quote + 1;
    }
    return false;
}

fn venomMountIncludesPath(
    allocator: std.mem.Allocator,
    venom: venom_catalog.VenomDescriptor,
    mount_path: []const u8,
) bool {
    var mounts_parsed = std.json.parseFromSlice(std.json.Value, allocator, venom.mounts_json, .{}) catch null;
    if (mounts_parsed) |*parsed| {
        defer parsed.deinit();
        if (parsed.value == .array) {
            for (parsed.value.array.items) |mount_value| {
                if (mount_value != .object) continue;
                const mount_path_value = mount_value.object.get("mount_path") orelse continue;
                if (mount_path_value != .string) continue;
                if (std.mem.eql(u8, mount_path_value.string, mount_path)) return true;
            }
        }
    }

    for (venom.endpoints.items) |endpoint| {
        if (std.mem.eql(u8, endpoint, mount_path)) return true;
    }
    return false;
}

fn servicePermissionsAllowActor(
    allocator: std.mem.Allocator,
    permissions_json: []const u8,
    has_project_token: bool,
    is_admin: bool,
) bool {
    if (is_admin) return true;
    if (permissions_json.len == 0) return true;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, permissions_json, .{}) catch return true;
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
    if (require_project_token and !has_project_token) return false;

    if (obj.get("allow_roles")) |roles| {
        if (roles == .array) {
            for (roles.array.items) |role| {
                if (role != .string) continue;
                if (std.mem.eql(u8, role.string, "user")) return true;
                if (std.mem.eql(u8, role.string, "all")) return true;
                if (std.mem.eql(u8, role.string, "*")) return true;
            }
            return false;
        }
    }

    if (obj.get("default")) |value| {
        if (value == .string) {
            if (std.mem.eql(u8, value.string, "deny")) return false;
            if (std.mem.eql(u8, value.string, "deny-by-default")) return false;
        }
    }

    return true;
}

fn appendWorkspaceMountJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    mount: WorkspaceMount,
    node: ?Node,
    include_node_secrets: bool,
    now_ms: i64,
) !void {
    const escaped_path = try jsonEscape(allocator, mount.mount_path);
    defer allocator.free(escaped_path);
    const escaped_node = try jsonEscape(allocator, mount.node_id);
    defer allocator.free(escaped_node);
    const escaped_export = try jsonEscape(allocator, mount.export_name);
    defer allocator.free(escaped_export);

    if (node) |resolved| {
        const escaped_name = try jsonEscape(allocator, resolved.name);
        defer allocator.free(escaped_name);
        const escaped_url = try jsonEscape(allocator, resolved.fs_url);
        defer allocator.free(escaped_url);
        const auth_json = if (include_node_secrets) blk: {
            const escaped_auth = try jsonEscape(allocator, resolved.secret);
            defer allocator.free(escaped_auth);
            break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped_auth});
        } else try allocator.dupe(u8, "null");
        defer allocator.free(auth_json);
        const online = resolved.lease_expires_at_ms > now_ms;
        const state = if (online) "online" else "degraded";
        try out.writer(allocator).print(
            "{{\"mount_path\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"{s}\",\"node_name\":\"{s}\",\"fs_url\":\"{s}\",\"fs_auth_token\":{s},\"online\":{s},\"state\":\"{s}\"}}",
            .{
                escaped_path,
                escaped_node,
                escaped_export,
                escaped_name,
                escaped_url,
                auth_json,
                if (online) "true" else "false",
                state,
            },
        );
        return;
    }

    try out.writer(allocator).print(
        "{{\"mount_path\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"{s}\",\"node_name\":null,\"fs_url\":null,\"fs_auth_token\":null,\"online\":false,\"state\":\"missing\"}}",
        .{ escaped_path, escaped_node, escaped_export },
    );
}

fn appendDriftEntryJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    mount_path: []const u8,
    kind: []const u8,
    severity: DriftSeverity,
    selected_node_id: []const u8,
    desired_node_id: []const u8,
    message: []const u8,
) !void {
    const escaped_path = try jsonEscape(allocator, mount_path);
    defer allocator.free(escaped_path);
    const escaped_kind = try jsonEscape(allocator, kind);
    defer allocator.free(escaped_kind);
    const escaped_selected = try jsonEscape(allocator, selected_node_id);
    defer allocator.free(escaped_selected);
    const escaped_desired = try jsonEscape(allocator, desired_node_id);
    defer allocator.free(escaped_desired);
    const escaped_message = try jsonEscape(allocator, message);
    defer allocator.free(escaped_message);

    try out.writer(allocator).print(
        "{{\"mount_path\":\"{s}\",\"kind\":\"{s}\",\"severity\":\"{s}\",\"selected_node_id\":\"{s}\",\"desired_node_id\":\"{s}\",\"message\":\"{s}\"}}",
        .{
            escaped_path,
            escaped_kind,
            driftSeverityName(severity),
            escaped_selected,
            escaped_desired,
            escaped_message,
        },
    );
}

fn reconcileStateName(state: ReconcileState) []const u8 {
    return switch (state) {
        .idle => "idle",
        .pending => "pending",
        .running => "running",
        .degraded => "degraded",
    };
}

fn driftSeverityName(severity: DriftSeverity) []const u8 {
    return switch (severity) {
        .info => "info",
        .warning => "warning",
        .err => "error",
    };
}

fn workspaceKindName(kind: WorkspaceKind) []const u8 {
    return switch (kind) {
        .normal => normal_project_kind_name,
        .host_internal => host_internal_project_kind_name,
    };
}

fn parseProjectKind(value: []const u8) WorkspaceKind {
    if (std.mem.eql(u8, value, host_internal_project_kind_name)) return .host_internal;
    return .normal;
}

fn defaultTemplateIdForProjectKind(kind: WorkspaceKind) []const u8 {
    return switch (kind) {
        .normal => default_project_template_id,
        .host_internal => "",
    };
}

fn resolveProjectTemplateSpec(template_id: []const u8) ?WorkspaceTemplateSpec {
    for (builtin_workspace_templates) |template| {
        if (std.mem.eql(u8, template.id, template_id)) return template;
    }
    return null;
}

fn workspaceTokenEnabled(project: *const Workspace) bool {
    return project.token_locked and project.mutation_token.len > 0;
}

fn accessModeName(mode: AccessMode) []const u8 {
    return switch (mode) {
        .open => "open",
        .token => "token",
        .admin => "admin",
        .deny => "deny",
    };
}

fn parseAccessMode(value: []const u8) !AccessMode {
    if (std.mem.eql(u8, value, "open") or std.mem.eql(u8, value, "allow")) return .open;
    if (std.mem.eql(u8, value, "token") or std.mem.eql(u8, value, "token-required") or std.mem.eql(u8, value, "token_or_admin")) return .token;
    if (std.mem.eql(u8, value, "admin") or std.mem.eql(u8, value, "admin-only")) return .admin;
    if (std.mem.eql(u8, value, "deny") or std.mem.eql(u8, value, "disabled")) return .deny;
    return ControlPlaneError.InvalidPayload;
}

fn workspaceActionPolicyIsEmpty(policy: *const WorkspaceActionPolicy) bool {
    return policy.read == null and
        policy.observe == null and
        policy.invoke == null and
        policy.mount == null and
        policy.bind == null and
        policy.admin == null;
}

fn parseWorkspaceActionPolicyFromObject(obj: std.json.ObjectMap, policy: *WorkspaceActionPolicy) !void {
    if (obj.get("read")) |value| {
        if (value != .string) return ControlPlaneError.InvalidPayload;
        policy.read = try parseAccessMode(value.string);
    }
    if (obj.get("observe")) |value| {
        if (value != .string) return ControlPlaneError.InvalidPayload;
        policy.observe = try parseAccessMode(value.string);
    }
    if (obj.get("invoke")) |value| {
        if (value != .string) return ControlPlaneError.InvalidPayload;
        policy.invoke = try parseAccessMode(value.string);
    }
    if (obj.get("mount")) |value| {
        if (value != .string) return ControlPlaneError.InvalidPayload;
        policy.mount = try parseAccessMode(value.string);
    }
    if (obj.get("bind")) |value| {
        if (value != .string) return ControlPlaneError.InvalidPayload;
        policy.bind = try parseAccessMode(value.string);
    }
    if (obj.get("admin")) |value| {
        if (value != .string) return ControlPlaneError.InvalidPayload;
        policy.admin = try parseAccessMode(value.string);
    }
}

fn upsertAgentAccessOverride(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(WorkspaceAgentAccessOverride),
    entry: WorkspaceAgentAccessOverride,
) !void {
    for (list.items) |*existing| {
        if (!std.mem.eql(u8, existing.agent_id, entry.agent_id)) continue;
        existing.actions = entry.actions;
        allocator.free(entry.agent_id);
        return;
    }
    try list.append(allocator, entry);
}

fn parseWorkspaceAccessPolicyValue(allocator: std.mem.Allocator, value: std.json.Value) !WorkspaceAccessPolicy {
    if (value != .object) return ControlPlaneError.InvalidPayload;
    const obj = value.object;

    var policy = WorkspaceAccessPolicy{};
    errdefer policy.deinit(allocator);

    try parseWorkspaceActionPolicyFromObject(obj, &policy.actions);
    if (obj.get("actions")) |actions_value| {
        if (actions_value != .object) return ControlPlaneError.InvalidPayload;
        try parseWorkspaceActionPolicyFromObject(actions_value.object, &policy.actions);
    }

    if (obj.get("agents")) |agents_value| {
        switch (agents_value) {
            .object => {
                var it = agents_value.object.iterator();
                while (it.next()) |entry| {
                    try validateIdentifier(entry.key_ptr.*, 128);
                    if (entry.value_ptr.* != .object) return ControlPlaneError.InvalidPayload;
                    var agent_override = WorkspaceAgentAccessOverride{
                        .agent_id = try allocator.dupe(u8, entry.key_ptr.*),
                    };
                    errdefer allocator.free(agent_override.agent_id);
                    try parseWorkspaceActionPolicyFromObject(entry.value_ptr.*.object, &agent_override.actions);
                    if (entry.value_ptr.*.object.get("actions")) |actions_value| {
                        if (actions_value != .object) return ControlPlaneError.InvalidPayload;
                        try parseWorkspaceActionPolicyFromObject(actions_value.object, &agent_override.actions);
                    }
                    if (workspaceActionPolicyIsEmpty(&agent_override.actions)) {
                        allocator.free(agent_override.agent_id);
                        continue;
                    }
                    try upsertAgentAccessOverride(allocator, &policy.agents, agent_override);
                }
            },
            .array => {
                for (agents_value.array.items) |item| {
                    if (item != .object) return ControlPlaneError.InvalidPayload;
                    const agent_id = getRequiredString(item.object, "agent_id") catch return ControlPlaneError.MissingField;
                    try validateIdentifier(agent_id, 128);
                    var agent_override = WorkspaceAgentAccessOverride{
                        .agent_id = try allocator.dupe(u8, agent_id),
                    };
                    errdefer allocator.free(agent_override.agent_id);
                    try parseWorkspaceActionPolicyFromObject(item.object, &agent_override.actions);
                    if (item.object.get("actions")) |actions_value| {
                        if (actions_value != .object) return ControlPlaneError.InvalidPayload;
                        try parseWorkspaceActionPolicyFromObject(actions_value.object, &agent_override.actions);
                    }
                    if (workspaceActionPolicyIsEmpty(&agent_override.actions)) {
                        allocator.free(agent_override.agent_id);
                        continue;
                    }
                    try upsertAgentAccessOverride(allocator, &policy.agents, agent_override);
                }
            },
            else => return ControlPlaneError.InvalidPayload,
        }
    }

    return policy;
}

fn appendWorkspaceActionPolicyJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    policy: WorkspaceActionPolicy,
) !void {
    try out.appendSlice(allocator, "{");
    var first = true;
    if (policy.read) |mode| {
        if (!first) try out.append(allocator, ',');
        first = false;
        try out.writer(allocator).print("\"read\":\"{s}\"", .{accessModeName(mode)});
    }
    if (policy.observe) |mode| {
        if (!first) try out.append(allocator, ',');
        first = false;
        try out.writer(allocator).print("\"observe\":\"{s}\"", .{accessModeName(mode)});
    }
    if (policy.invoke) |mode| {
        if (!first) try out.append(allocator, ',');
        first = false;
        try out.writer(allocator).print("\"invoke\":\"{s}\"", .{accessModeName(mode)});
    }
    if (policy.mount) |mode| {
        if (!first) try out.append(allocator, ',');
        first = false;
        try out.writer(allocator).print("\"mount\":\"{s}\"", .{accessModeName(mode)});
    }
    if (policy.bind) |mode| {
        if (!first) try out.append(allocator, ',');
        first = false;
        try out.writer(allocator).print("\"bind\":\"{s}\"", .{accessModeName(mode)});
    }
    if (policy.admin) |mode| {
        if (!first) try out.append(allocator, ',');
        try out.writer(allocator).print("\"admin\":\"{s}\"", .{accessModeName(mode)});
    }
    try out.appendSlice(allocator, "}");
}

fn appendWorkspaceAccessPolicyJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    policy: WorkspaceAccessPolicy,
) !void {
    try out.appendSlice(allocator, "{\"actions\":");
    try appendWorkspaceActionPolicyJson(allocator, out, policy.actions);
    try out.appendSlice(allocator, ",\"agents\":{");
    for (policy.agents.items, 0..) |agent, idx| {
        if (idx != 0) try out.append(allocator, ',');
        const escaped_agent = try jsonEscape(allocator, agent.agent_id);
        defer allocator.free(escaped_agent);
        try out.writer(allocator).print("\"{s}\":", .{escaped_agent});
        try appendWorkspaceActionPolicyJson(allocator, out, agent.actions);
    }
    try out.appendSlice(allocator, "}}");
}

fn defaultWorkspaceActionMode(project: *const Workspace, action: WorkspaceAction) AccessMode {
    _ = action;
    return if (workspaceTokenEnabled(project)) .token else .open;
}

fn resolveWorkspaceActionMode(project: *const Workspace, action: WorkspaceAction, actor_id: ?[]const u8) AccessMode {
    if (action == .bind) {
        if (project.access_policy.modeFor(actor_id, .bind)) |mode| return mode;
        if (project.access_policy.modeFor(actor_id, .mount)) |mode| return mode;
        return defaultWorkspaceActionMode(project, .bind);
    }

    var mode = defaultWorkspaceActionMode(project, action);
    if (project.access_policy.modeFor(actor_id, action)) |override_mode| {
        mode = override_mode;
    }
    return mode;
}

fn requireWorkspaceActionAccess(
    project: *const Workspace,
    action: WorkspaceAction,
    actor_id: ?[]const u8,
    provided_token: ?[]const u8,
    is_admin: bool,
) !void {
    if (is_admin) return;
    switch (resolveWorkspaceActionMode(project, action, actor_id)) {
        .open => return,
        .token => {
            const token = provided_token orelse return ControlPlaneError.MissingField;
            try validateSecretToken(token, 256);
            if (!workspaceTokenEnabled(project)) return ControlPlaneError.WorkspaceAuthFailed;
            if (!secureTokenEql(project.mutation_token, token)) return ControlPlaneError.WorkspaceAuthFailed;
        },
        .admin, .deny => return ControlPlaneError.WorkspacePolicyForbidden,
    }
}

fn requireWorkspaceAccessToken(project: *const Workspace, provided_token: ?[]const u8, is_admin: bool) !void {
    try requireWorkspaceActionAccess(project, .admin, null, provided_token, is_admin);
}

fn renderWorkspacePayload(allocator: std.mem.Allocator, project: Workspace, include_project_token: bool) ![]u8 {
    const escaped_id = try jsonEscape(allocator, project.id);
    defer allocator.free(escaped_id);
    const escaped_name = try jsonEscape(allocator, project.name);
    defer allocator.free(escaped_name);
    const escaped_vision = try jsonEscape(allocator, project.vision);
    defer allocator.free(escaped_vision);
    const escaped_status = try jsonEscape(allocator, project.status);
    defer allocator.free(escaped_status);
    const escaped_template_id = try jsonEscape(allocator, project.template_id);
    defer allocator.free(escaped_template_id);
    const escaped_kind = try jsonEscape(allocator, workspaceKindName(project.kind));
    defer allocator.free(escaped_kind);
    const escaped_token = if (include_project_token and workspaceTokenEnabled(&project)) blk: {
        break :blk try jsonEscape(allocator, project.mutation_token);
    } else null;
    defer if (escaped_token) |token| allocator.free(token);

    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try out.writer(allocator).print(
        "{{\"workspace_id\":\"{s}\",\"name\":\"{s}\",\"vision\":\"{s}\",\"status\":\"{s}\",\"template_id\":\"{s}\",\"kind\":\"{s}\",\"is_delete_protected\":{s},\"token_locked\":{s},\"created_at_ms\":{d},\"updated_at_ms\":{d}",
        .{
            escaped_id,
            escaped_name,
            escaped_vision,
            escaped_status,
            escaped_template_id,
            escaped_kind,
            if (project.is_delete_protected) "true" else "false",
            if (project.token_locked) "true" else "false",
            project.created_at_ms,
            project.updated_at_ms,
        },
    );
    if (escaped_token) |token| {
        try out.writer(allocator).print(",\"workspace_token\":\"{s}\"", .{token});
    }
    try out.appendSlice(allocator, ",\"access_policy\":");
    try appendWorkspaceAccessPolicyJson(allocator, &out, project.access_policy);
    try out.appendSlice(allocator, ",\"mounts\":[");
    for (project.mounts.items, 0..) |mount, idx| {
        if (idx != 0) try out.append(allocator, ',');
        try appendMountJson(allocator, &out, mount);
    }
    try out.appendSlice(allocator, "],\"binds\":[");
    for (project.binds.items, 0..) |bind, idx| {
        if (idx != 0) try out.append(allocator, ',');
        try appendBindJson(allocator, &out, bind);
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn normalizeMountPath(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return ControlPlaneError.InvalidPayload;

    trimmed = std.mem.trim(u8, trimmed, "/");
    if (trimmed.len == 0) return allocator.dupe(u8, "/");

    return std.fmt.allocPrint(allocator, "/{s}", .{trimmed});
}

fn getPublicWorkspaceLocked(self: *ControlPlane, workspace_id: []const u8) !Workspace {
    const project = self.workspaces.get(workspace_id) orelse return ControlPlaneError.WorkspaceNotFound;
    if (project.kind == .host_internal) return ControlPlaneError.WorkspaceNotFound;
    return project;
}

fn getPublicWorkspacePtrLocked(self: *ControlPlane, workspace_id: []const u8) !*Workspace {
    const project = self.workspaces.getPtr(workspace_id) orelse return ControlPlaneError.WorkspaceNotFound;
    if (project.kind == .host_internal) return ControlPlaneError.WorkspaceNotFound;
    return project;
}

fn getHostWorkspaceLocked(self: *ControlPlane) !Workspace {
    return self.workspaces.get(host_workspace_id) orelse ControlPlaneError.WorkspaceNotFound;
}

fn getHostWorkspacePtrLocked(self: *ControlPlane) !*Workspace {
    return self.workspaces.getPtr(host_workspace_id) orelse ControlPlaneError.WorkspaceNotFound;
}

fn upsertActiveWorkspaceBindingLocked(self: *ControlPlane, agent_id: []const u8, workspace_id: []const u8) !void {
    if (self.active_workspace_by_agent.getPtr(agent_id)) |existing| {
        if (std.mem.eql(u8, existing.*, workspace_id)) return;
        self.allocator.free(existing.*);
        existing.* = try self.allocator.dupe(u8, workspace_id);
        return;
    }

    try self.active_workspace_by_agent.put(
        self.allocator,
        try self.allocator.dupe(u8, agent_id),
        try self.allocator.dupe(u8, workspace_id),
    );
}

fn clearActiveWorkspaceBindingLocked(self: *ControlPlane, agent_id: []const u8) bool {
    const removed = self.active_workspace_by_agent.fetchRemove(agent_id) orelse return false;
    self.allocator.free(removed.key);
    self.allocator.free(removed.value);
    return true;
}

fn hostWorkspaceHasMountsLocked(self: *ControlPlane) bool {
    const project = getHostWorkspaceLocked(self) catch return false;
    return project.mounts.items.len > 0;
}

fn removeWorkspaceMountEntriesLocked(
    allocator: std.mem.Allocator,
    project: *Workspace,
    mount_path: []const u8,
    node_id_filter: ?[]const u8,
    export_name_filter: ?[]const u8,
) u32 {
    var removed_count: u32 = 0;
    var i: usize = 0;
    while (i < project.mounts.items.len) {
        const mount = project.mounts.items[i];
        if (!std.mem.eql(u8, mount.mount_path, mount_path)) {
            i += 1;
            continue;
        }
        if (node_id_filter) |node_id| {
            if (!std.mem.eql(u8, mount.node_id, node_id)) {
                i += 1;
                continue;
            }
        }
        if (export_name_filter) |export_name| {
            if (!std.mem.eql(u8, mount.export_name, export_name)) {
                i += 1;
                continue;
            }
        }

        var removed = project.mounts.orderedRemove(i);
        removed.deinit(allocator);
        removed_count +%= 1;
        if (node_id_filter != null) break;
    }
    return removed_count;
}

fn ensureDefaultWorkspaceMountsLocked(self: *ControlPlane, project: *Workspace) !bool {
    if (project.kind == .host_internal) return false;

    var changed = false;
    var mounted_from_host = false;
    if (getHostWorkspaceLocked(self)) |host_project| {
        for (host_project.mounts.items) |host_mount| {
            if (!self.nodes.contains(host_mount.node_id)) continue;

            const remapped_path = try remapSystemMountPathForWorkspace(
                self.allocator,
                project.id,
                host_mount.mount_path,
            );
            errdefer self.allocator.free(remapped_path);

            var conflict = false;
            for (project.mounts.items) |existing| {
                if (std.mem.eql(u8, existing.mount_path, remapped_path)) {
                    conflict = true;
                    break;
                }
                if (mountPathsOverlap(existing.mount_path, remapped_path)) {
                    conflict = true;
                    break;
                }
            }
            if (!conflict) {
                for (project.binds.items) |existing_bind| {
                    if (pathsConflict(existing_bind.bind_path, remapped_path)) {
                        conflict = true;
                        break;
                    }
                }
            }
            if (conflict) {
                self.allocator.free(remapped_path);
                continue;
            }

            try project.mounts.append(self.allocator, .{
                .mount_path = remapped_path,
                .node_id = try self.allocator.dupe(u8, host_mount.node_id),
                .export_name = try self.allocator.dupe(u8, host_mount.export_name),
            });
            mounted_from_host = true;
            changed = true;
        }
    } else |_| {}

    if (!mounted_from_host and !workspaceHasCanonicalMount(project)) {
        var default_node_id: ?[]const u8 = null;
        var node_it = self.nodes.iterator();
        if (node_it.next()) |entry| default_node_id = entry.key_ptr.*;
        if (default_node_id) |node_id| {
            var conflicts = false;
            for (project.binds.items) |existing_bind| {
                if (pathsConflict(existing_bind.bind_path, host_workspace_mount_path)) {
                    conflicts = true;
                    break;
                }
            }
            if (!conflicts) {
                try project.mounts.append(self.allocator, .{
                    .mount_path = try self.allocator.dupe(u8, host_workspace_mount_path),
                    .node_id = try self.allocator.dupe(u8, node_id),
                    .export_name = try self.allocator.dupe(u8, default_host_project_export_name),
                });
                changed = true;
            }
        }
    }

    if (pruneLegacyWorkspaceAliasMountsLocked(self, project)) changed = true;
    return changed;
}

fn ensureWorkspaceTemplateBindsLocked(self: *ControlPlane, project: *Workspace) !bool {
    const template = resolveProjectTemplateSpec(project.template_id) orelse return false;
    return ensureBindSpecsLocked(self, project, template.bind_specs);
}

fn ensureHostWorkspaceBindsLocked(self: *ControlPlane, project: *Workspace) !bool {
    return ensureBindSpecsLocked(self, project, core_workspace_bind_specs[0..]);
}

fn ensureBindSpecsLocked(
    self: *ControlPlane,
    project: *Workspace,
    bind_specs: []const WorkspaceTemplateBindSpec,
) !bool {
    var changed = false;
    for (bind_specs) |spec| {
        const target_path = try resolveTemplateBindTargetPathLocked(self, project, spec) orelse continue;
        defer self.allocator.free(target_path);
        const normalized_bind = try normalizeMountPath(self.allocator, spec.bind_path);
        defer self.allocator.free(normalized_bind);
        const normalized_target = try normalizeMountPath(self.allocator, target_path);
        defer self.allocator.free(normalized_target);

        if (!workspacePathWithinBindAuthority(project, normalized_target)) continue;

        var skip = false;
        for (project.mounts.items) |mount| {
            if (pathsConflict(mount.mount_path, normalized_bind)) {
                skip = true;
                break;
            }
        }
        if (skip) continue;

        for (project.binds.items) |existing| {
            if (std.mem.eql(u8, existing.bind_path, normalized_bind)) {
                skip = true;
                break;
            }
            if (pathsConflict(existing.bind_path, normalized_bind)) {
                skip = true;
                break;
            }
        }
        if (skip) continue;

        try project.binds.append(self.allocator, .{
            .bind_path = try self.allocator.dupe(u8, normalized_bind),
            .target_path = try self.allocator.dupe(u8, normalized_target),
        });
        changed = true;
    }
    return changed;
}

fn resolveTemplateBindTargetPathLocked(
    self: *ControlPlane,
    project: *const Workspace,
    spec: WorkspaceTemplateBindSpec,
) !?[]u8 {
    var provider = (try self.resolvePreferredVenomProviderForContextLocked(
        self.allocator,
        spec.venom_id,
        &.{},
        if (project.kind == .host_internal) null else project.id,
        null,
        .{
            .host_role = spec.host_role,
            .binding_scope = .workspace,
        },
    )) orelse return null;
    defer provider.deinit(self.allocator);
    return try self.allocator.dupe(u8, provider.endpoint_path);
}

fn workspaceHasCanonicalMount(project: *const Workspace) bool {
    for (project.mounts.items) |mount| {
        if (std.mem.eql(u8, mount.mount_path, host_workspace_mount_path)) return true;
    }
    return false;
}

fn pruneLegacyWorkspaceAliasMountsIfReplacementLocked(self: *ControlPlane, project: *Workspace) bool {
    if (!workspaceHasCanonicalMount(project)) return false;
    return pruneLegacyWorkspaceAliasMountsLocked(self, project);
}

fn pruneLegacyWorkspaceAliasMountsLocked(self: *ControlPlane, project: *Workspace) bool {
    if (!workspaceHasCanonicalMount(project)) return false;

    var removed = false;
    var idx: usize = 0;
    while (idx < project.mounts.items.len) {
        const mount = &project.mounts.items[idx];
        if (!std.mem.eql(u8, mount.mount_path, "/workspace")) {
            idx += 1;
            continue;
        }

        var removed_mount = project.mounts.orderedRemove(idx);
        removed_mount.deinit(self.allocator);
        removed = true;
    }
    return removed;
}

fn remapSystemMountPathForWorkspace(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    mount_path: []const u8,
) ![]u8 {
    if (std.mem.startsWith(u8, mount_path, host_workspace_mount_prefix)) {
        const suffix = mount_path[host_workspace_mount_prefix.len..];
        return std.fmt.allocPrint(allocator, "/nodes/local/projects/{s}/{s}", .{ workspace_id, suffix });
    }
    return allocator.dupe(u8, mount_path);
}

fn mountPathsOverlap(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, "/") or std.mem.eql(u8, b, "/")) return true;

    if (std.mem.startsWith(u8, a, b)) {
        return a.len > b.len and a[b.len] == '/';
    }
    if (std.mem.startsWith(u8, b, a)) {
        return b.len > a.len and b[a.len] == '/';
    }
    return false;
}

fn pathsConflict(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b) or mountPathsOverlap(a, b);
}

fn pathIsAncestorOrEqual(ancestor: []const u8, path: []const u8) bool {
    if (ancestor.len == 0 or path.len == 0) return false;
    if (!std.mem.startsWith(u8, path, ancestor)) return false;
    if (ancestor.len == path.len) return true;
    if (std.mem.eql(u8, ancestor, "/")) return true;
    return path[ancestor.len] == '/';
}

fn workspacePathWithinMountAuthority(project: *const Workspace, path: []const u8) bool {
    for (project.mounts.items) |mount| {
        if (pathIsAncestorOrEqual(mount.mount_path, path)) return true;
    }
    return false;
}

fn workspacePathWithinBindAuthority(project: *const Workspace, path: []const u8) bool {
    if (workspacePathWithinMountAuthority(project, path)) return true;
    if (isNodeVenomCatalogPath(path)) return true;
    if (std.mem.eql(u8, path, "/global")) return true;
    if (pathMatchesPrefix(path, "/global")) return true;
    return false;
}

fn isNodeVenomCatalogPath(path: []const u8) bool {
    if (!pathMatchesPrefix(path, "/nodes")) return false;
    var iter = std.mem.splitScalar(u8, path, '/');
    _ = iter.next();
    const first = iter.next() orelse return false;
    if (!std.mem.eql(u8, first, "nodes")) return false;
    _ = iter.next() orelse return false;
    const third = iter.next() orelse return false;
    return std.mem.eql(u8, third, "venoms");
}

fn pathMatchesPrefix(path: []const u8, prefix: []const u8) bool {
    if (std.mem.eql(u8, path, prefix)) return true;
    if (prefix.len == 0 or !std.mem.startsWith(u8, path, prefix)) return false;
    return path.len > prefix.len and path[prefix.len] == '/';
}

fn joinBoundPath(allocator: std.mem.Allocator, target: []const u8, suffix: []const u8) ![]u8 {
    if (suffix.len == 0) return allocator.dupe(u8, target);
    if (std.mem.eql(u8, target, "/")) return std.fmt.allocPrint(allocator, "{s}", .{suffix});
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ target, suffix });
}

fn resolveBoundPath(allocator: std.mem.Allocator, project: *const Workspace, path: []const u8) !?[]u8 {
    var selected: ?*const WorkspaceBind = null;
    for (project.binds.items) |*bind| {
        if (!pathMatchesPrefix(path, bind.bind_path)) continue;
        if (selected == null or bind.bind_path.len > selected.?.bind_path.len) {
            selected = bind;
        }
    }
    if (selected) |bind| {
        const suffix = path[bind.bind_path.len..];
        return try joinBoundPath(allocator, bind.target_path, suffix);
    }
    return null;
}

fn validateIdentifier(value: []const u8, max_len: usize) !void {
    if (value.len == 0 or value.len > max_len) return ControlPlaneError.InvalidPayload;
    for (value) |char| {
        if (std.ascii.isAlphanumeric(char)) continue;
        if (char == '-' or char == '_' or char == '.') continue;
        return ControlPlaneError.InvalidPayload;
    }
}

fn validateSecretToken(value: []const u8, max_len: usize) !void {
    if (value.len == 0 or value.len > max_len) return ControlPlaneError.InvalidPayload;
}

fn validateDisplayString(value: []const u8, max_len: usize) !void {
    if (value.len == 0 or value.len > max_len) return ControlPlaneError.InvalidPayload;
    for (value) |char| {
        if (char < 0x20) return ControlPlaneError.InvalidPayload;
    }
}

fn validateDisplayStringAllowEmpty(value: []const u8, max_len: usize) !void {
    if (value.len > max_len) return ControlPlaneError.InvalidPayload;
    for (value) |char| {
        if (char < 0x20) return ControlPlaneError.InvalidPayload;
    }
}

fn secureTokenEql(expected: []const u8, candidate: []const u8) bool {
    if (expected.len != candidate.len) return false;
    var diff: u8 = 0;
    for (expected, candidate) |lhs, rhs| {
        diff |= lhs ^ rhs;
    }
    return diff == 0;
}

fn validateExportName(value: []const u8) !void {
    try validateIdentifier(value, 128);
    if (std.mem.indexOfScalar(u8, value, '/')) |_| return ControlPlaneError.InvalidPayload;
}

fn validateFsUrl(value: []const u8) !void {
    if (!std.mem.startsWith(u8, value, "ws://")) return ControlPlaneError.InvalidPayload;
    if (std.mem.indexOf(u8, value, "/fs") == null) return ControlPlaneError.InvalidPayload;
    if (value.len > 512) return ControlPlaneError.InvalidPayload;
}

fn jsonEscape(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    for (value) |char| {
        switch (char) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => if (char < 0x20) {
                try out.writer(allocator).print("\\u00{x:0>2}", .{char});
            } else {
                try out.append(allocator, char);
            },
        }
    }

    return out.toOwnedSlice(allocator);
}

fn loadStateEncryptionKey(allocator: std.mem.Allocator) ?[persistence_cipher.key_length]u8 {
    const raw = std.process.getEnvVarOwned(allocator, persistence_key_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => {
            std.log.warn("control-plane state encryption disabled: failed reading {s}: {s}", .{ persistence_key_env, @errorName(err) });
            return null;
        },
    };
    defer allocator.free(raw);

    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed.len != persistence_cipher.key_length * 2) {
        std.log.warn(
            "control-plane state encryption disabled: {s} must be {d} hex chars",
            .{ persistence_key_env, persistence_cipher.key_length * 2 },
        );
        return null;
    }

    var key: [persistence_cipher.key_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&key, trimmed) catch |err| {
        std.log.warn("control-plane state encryption disabled: invalid key in {s}: {s}", .{ persistence_key_env, @errorName(err) });
        return null;
    };
    std.log.info("control-plane state encryption enabled via {s}", .{persistence_key_env});
    return key;
}

fn isEncryptedSnapshotEnvelope(content_json: []const u8) bool {
    return std.mem.indexOf(u8, content_json, "\"enc\":\"aes-256-gcm\"") != null and
        std.mem.indexOf(u8, content_json, "\"ciphertext\"") != null and
        std.mem.indexOf(u8, content_json, "\"nonce\"") != null and
        std.mem.indexOf(u8, content_json, "\"tag\"") != null;
}

fn encryptSnapshotJson(
    allocator: std.mem.Allocator,
    snapshot_json: []const u8,
    key: [persistence_cipher.key_length]u8,
) ![]u8 {
    var nonce: [persistence_cipher.nonce_length]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    const ciphertext = try allocator.alloc(u8, snapshot_json.len);
    defer allocator.free(ciphertext);
    var tag: [persistence_cipher.tag_length]u8 = undefined;
    persistence_cipher.encrypt(ciphertext, &tag, snapshot_json, persistence_aad, nonce, key);

    const encoded_nonce = try encodeBase64(allocator, &nonce);
    defer allocator.free(encoded_nonce);
    const encoded_tag = try encodeBase64(allocator, &tag);
    defer allocator.free(encoded_tag);
    const encoded_ciphertext = try encodeBase64(allocator, ciphertext);
    defer allocator.free(encoded_ciphertext);

    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":1,\"enc\":\"aes-256-gcm\",\"nonce\":\"{s}\",\"tag\":\"{s}\",\"ciphertext\":\"{s}\"}}",
        .{ encoded_nonce, encoded_tag, encoded_ciphertext },
    );
}

fn decryptSnapshotJson(
    allocator: std.mem.Allocator,
    envelope_json: []const u8,
    key: [persistence_cipher.key_length]u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, envelope_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSnapshot;
    const obj = parsed.value.object;

    const enc = obj.get("enc") orelse return error.InvalidSnapshot;
    if (enc != .string or !std.mem.eql(u8, enc.string, "aes-256-gcm")) return error.InvalidSnapshot;
    const nonce_b64 = try getRequiredSnapshotString(obj, "nonce");
    const tag_b64 = try getRequiredSnapshotString(obj, "tag");
    const ciphertext_b64 = try getRequiredSnapshotString(obj, "ciphertext");

    const nonce_bytes = try decodeBase64(allocator, nonce_b64);
    defer allocator.free(nonce_bytes);
    if (nonce_bytes.len != persistence_cipher.nonce_length) return error.InvalidSnapshot;

    const tag_bytes = try decodeBase64(allocator, tag_b64);
    defer allocator.free(tag_bytes);
    if (tag_bytes.len != persistence_cipher.tag_length) return error.InvalidSnapshot;

    const ciphertext = try decodeBase64(allocator, ciphertext_b64);
    defer allocator.free(ciphertext);

    var nonce: [persistence_cipher.nonce_length]u8 = undefined;
    @memcpy(nonce[0..], nonce_bytes);
    var tag: [persistence_cipher.tag_length]u8 = undefined;
    @memcpy(tag[0..], tag_bytes);

    const plaintext = try allocator.alloc(u8, ciphertext.len);
    errdefer allocator.free(plaintext);
    persistence_cipher.decrypt(plaintext, ciphertext, tag, persistence_aad, nonce, key) catch return error.AuthenticationFailed;
    return plaintext;
}

fn getRequiredSnapshotString(obj: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const value = obj.get(field) orelse return error.InvalidSnapshot;
    if (value != .string or value.string.len == 0) return error.InvalidSnapshot;
    return value.string;
}

fn encodeBase64(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const out_len = std.base64.standard.Encoder.calcSize(data.len);
    const out = try allocator.alloc(u8, out_len);
    _ = std.base64.standard.Encoder.encode(out, data);
    return out;
}

fn decodeBase64(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const out_len = try std.base64.standard.Decoder.calcSizeForSlice(data);
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    try std.base64.standard.Decoder.decode(out, data);
    return out;
}

test "acheron_control_plane: builtin host project is protected and hidden from listings" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const projects_json = try plane.listWorkspaces();
    defer allocator.free(projects_json);
    try std.testing.expect(std.mem.indexOf(u8, projects_json, "\"workspace_id\":\"system\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, projects_json, "\"kind\":\"host_internal\"") == null);

    try std.testing.expectError(
        ControlPlaneError.WorkspaceNotFound,
        plane.deleteWorkspace("{\"workspace_id\":\"system\",\"workspace_token\":\"token\"}"),
    );
    try std.testing.expectError(
        ControlPlaneError.WorkspaceNotFound,
        plane.getWorkspace("{\"workspace_id\":\"system\"}"),
    );
    const state_json = try plane.dumpState();
    defer allocator.free(state_json);
    var parsed_state = try std.json.parseFromSlice(std.json.Value, allocator, state_json, .{});
    defer parsed_state.deinit();
    const workspaces_val = parsed_state.value.object.get("workspaces").?;
    try std.testing.expect(workspaces_val == .array);
    var spider_token: ?[]const u8 = null;
    for (workspaces_val.array.items) |item| {
        if (item != .object) continue;
        const id_val = item.object.get("id") orelse continue;
        if (id_val != .string) continue;
        if (!std.mem.eql(u8, id_val.string, host_workspace_id)) continue;
        const token_val = item.object.get("mutation_token") orelse continue;
        if (token_val == .string) {
            spider_token = token_val.string;
            break;
        }
    }
    try std.testing.expect(spider_token != null);
    const update_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"name\":\"Renamed\",\"vision\":\"Changed\"}}",
        .{ host_workspace_id, spider_token.? },
    );
    defer allocator.free(update_req);
    try std.testing.expectError(
        ControlPlaneError.WorkspaceNotFound,
        plane.updateWorkspace(update_req),
    );
    try std.testing.expectError(
        ControlPlaneError.WorkspaceNotFound,
        plane.activateWorkspace("agent-worker", "{\"workspace_id\":\"system\",\"workspace_token\":\"token\"}"),
    );
    try std.testing.expectError(
        ControlPlaneError.WorkspaceNotFound,
        plane.workspaceStatus("agent-worker", "{\"workspace_id\":\"system\"}"),
    );

    const activate_missing_token = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\"}}",
        .{host_workspace_id},
    );
    defer allocator.free(activate_missing_token);
    try std.testing.expectError(
        ControlPlaneError.WorkspaceNotFound,
        plane.activateWorkspace(default_host_actor_id, activate_missing_token),
    );

    const activated = try plane.activateHostWorkspace();
    defer allocator.free(activated);
    try std.testing.expect(std.mem.indexOf(u8, activated, "\"workspace_id\":\"system\"") != null);
    try std.testing.expect(plane.active_workspace_by_agent.get(default_host_actor_id) == null);

    const status = try plane.hostWorkspaceStatus();
    defer allocator.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"workspace_id\":\"system\"") != null);

    const generic_status = try plane.workspaceStatusWithRole(default_host_actor_id, null, true);
    defer allocator.free(generic_status);
    try std.testing.expect(std.mem.indexOf(u8, generic_status, "\"workspace_id\":null") != null);

    const non_system = try plane.createWorkspace("{\"name\":\"Product\",\"vision\":\"Ship product milestones\"}");
    defer allocator.free(non_system);
    var parsed_non_system = try std.json.parseFromSlice(std.json.Value, allocator, non_system, .{});
    defer parsed_non_system.deinit();
    const non_system_project_id = parsed_non_system.value.object.get("workspace_id").?.string;
    const activate_non_system = try std.fmt.allocPrint(allocator, "{{\"workspace_id\":\"{s}\"}}", .{non_system_project_id});
    defer allocator.free(activate_non_system);
    try std.testing.expectError(
        ControlPlaneError.WorkspaceAssignmentForbidden,
        plane.activateWorkspace(default_host_actor_id, activate_non_system),
    );

    try std.testing.expectError(
        ControlPlaneError.WorkspaceAssignmentForbidden,
        plane.activateWorkspaceWithRole(default_host_actor_id, activate_non_system, true),
    );
    const admin_status = try plane.workspaceStatusWithRole(default_host_actor_id, activate_non_system, true);
    defer allocator.free(admin_status);
    const expected_project_id = try std.fmt.allocPrint(allocator, "\"workspace_id\":\"{s}\"", .{non_system_project_id});
    defer allocator.free(expected_project_id);
    try std.testing.expect(std.mem.indexOf(u8, admin_status, expected_project_id) != null);
}

test "acheron_control_plane: builtin host mount can be bound from local node" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const joined = try plane.ensureNode("spiderweb-local", "ws://127.0.0.1:18891/fs", 60_000);
    defer allocator.free(joined);
    var parsed_join = try std.json.parseFromSlice(std.json.Value, allocator, joined, .{});
    defer parsed_join.deinit();
    const node_id = parsed_join.value.object.get("node_id").?.string;

    try plane.ensureSpiderWebMount(node_id, "system-root");

    const status = try plane.hostWorkspaceStatus();
    defer allocator.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"workspace_id\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"mount_path\":\"/nodes/local/fs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"export_name\":\"system-root\"") != null);
}

test "acheron_control_plane: builtin host mounts support namespace topology" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const joined = try plane.ensureNode("spiderweb-local", "ws://127.0.0.1:18891/fs", 60_000);
    defer allocator.free(joined);
    var parsed_join = try std.json.parseFromSlice(std.json.Value, allocator, joined, .{});
    defer parsed_join.deinit();
    const node_id = parsed_join.value.object.get("node_id").?.string;

    const mounts = [_]SpiderWebMountSpec{
        .{ .mount_path = "/agents", .export_name = "agents" },
        .{ .mount_path = "/meta", .export_name = "meta" },
        .{ .mount_path = "/global/capabilities", .export_name = "capabilities" },
        .{ .mount_path = "/nodes/local/fs", .export_name = "workspace" },
        .{ .mount_path = "/nodes/local/projects/system/agents", .export_name = "agents" },
        .{ .mount_path = "/nodes/local/projects/system/meta", .export_name = "meta" },
        .{ .mount_path = "/nodes/local/projects/system/global/capabilities", .export_name = "capabilities" },
        .{ .mount_path = "/nodes/local/projects/system/nodes/local/fs", .export_name = "workspace" },
        .{ .mount_path = "/nodes/local/projects/system/fs/local::fs", .export_name = "workspace" },
    };
    try plane.ensureSpiderWebMounts(node_id, &mounts);

    const status = try plane.hostWorkspaceStatus();
    defer allocator.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"mount_path\":\"/agents\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"mount_path\":\"/meta\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"mount_path\":\"/global/capabilities\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"mount_path\":\"/nodes/local/fs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"mount_path\":\"/nodes/local/projects/system/agents\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"mount_path\":\"/nodes/local/projects/system/meta\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"mount_path\":\"/nodes/local/projects/system/global/capabilities\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"mount_path\":\"/nodes/local/projects/system/nodes/local/fs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"mount_path\":\"/nodes/local/projects/system/fs/local::fs\"") != null);
}

test "acheron_control_plane: admin can set and remove builtin host mounts" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const local_joined = try plane.ensureNode("spiderweb-local", "ws://127.0.0.1:18891/fs", 60_000);
    defer allocator.free(local_joined);
    var local_parsed = try std.json.parseFromSlice(std.json.Value, allocator, local_joined, .{});
    defer local_parsed.deinit();
    const local_node_id = local_parsed.value.object.get("node_id").?.string;
    try plane.ensureSpiderWebMount(local_node_id, "system-root");

    const remote_joined = try plane.ensureNode("clawz", "ws://100.101.192.123:18790/fs/node/node-3", 60_000);
    defer allocator.free(remote_joined);
    var remote_parsed = try std.json.parseFromSlice(std.json.Value, allocator, remote_joined, .{});
    defer remote_parsed.deinit();
    const remote_node_id = remote_parsed.value.object.get("node_id").?.string;

    const host_mounts = [_]SpiderWebMountSpec{
        .{ .mount_path = "/nodes/clawz/fs", .export_name = "work" },
    };
    try plane.ensureSpiderWebMounts(remote_node_id, &host_mounts);

    {
        const status = try plane.hostWorkspaceStatus();
        defer allocator.free(status);
        try std.testing.expect(std.mem.indexOf(u8, status, "\"mount_path\":\"/nodes/clawz/fs\"") != null);
    }

    try std.testing.expect(try plane.removeHostMount("/nodes/clawz/fs", remote_node_id, "work"));
    {
        const status = try plane.hostWorkspaceStatus();
        defer allocator.free(status);
        try std.testing.expect(std.mem.indexOf(u8, status, "\"mount_path\":\"/nodes/clawz/fs\"") == null);
    }
}

test "acheron_control_plane: ensureSpiderWebMounts preserves extra builtin mounts" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const local_joined = try plane.ensureNode("spiderweb-local", "ws://127.0.0.1:18891/fs", 60_000);
    defer allocator.free(local_joined);
    var local_parsed = try std.json.parseFromSlice(std.json.Value, allocator, local_joined, .{});
    defer local_parsed.deinit();
    const local_node_id = local_parsed.value.object.get("node_id").?.string;
    try plane.ensureSpiderWebMount(local_node_id, "system-root");

    const remote_joined = try plane.ensureNode("clawz", "ws://100.101.192.123:18790/fs/node/node-3", 60_000);
    defer allocator.free(remote_joined);
    var remote_parsed = try std.json.parseFromSlice(std.json.Value, allocator, remote_joined, .{});
    defer remote_parsed.deinit();
    const remote_node_id = remote_parsed.value.object.get("node_id").?.string;

    const host_mounts = [_]SpiderWebMountSpec{
        .{ .mount_path = "/nodes/clawz/fs", .export_name = "work" },
    };
    try plane.ensureSpiderWebMounts(remote_node_id, &host_mounts);

    // Re-ensuring local mount specs should not wipe additional admin-managed mounts.
    try plane.ensureSpiderWebMount(local_node_id, "system-root");

    const status = try plane.hostWorkspaceStatus();
    defer allocator.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"mount_path\":\"/nodes/local/fs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"mount_path\":\"/nodes/clawz/fs\"") != null);
}

test "acheron_control_plane: invite join lease flow works" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const invite_json = try plane.createNodeInvite(null);
    defer allocator.free(invite_json);
    try std.testing.expect(std.mem.indexOf(u8, invite_json, "\"invite_token\"") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, invite_json, .{});
    defer parsed.deinit();
    const token = parsed.value.object.get("invite_token").?.string;

    const join_req = try std.fmt.allocPrint(
        allocator,
        "{{\"invite_token\":\"{s}\",\"node_name\":\"alpha\",\"fs_url\":\"ws://127.0.0.1:18891/fs\"}}",
        .{token},
    );
    defer allocator.free(join_req);
    const join_json = try plane.nodeJoin(join_req);
    defer allocator.free(join_json);
    try std.testing.expect(std.mem.indexOf(u8, join_json, "\"node_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, join_json, "\"fs_url\":\"ws://127.0.0.1:18891/fs\"") != null);

    var join_parsed = try std.json.parseFromSlice(std.json.Value, allocator, join_json, .{});
    defer join_parsed.deinit();
    const node_id = join_parsed.value.object.get("node_id").?.string;
    const secret = join_parsed.value.object.get("node_secret").?.string;

    const refresh_req = try std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"fs_url\":\"ws://127.0.0.1:28891/fs\"}}",
        .{ node_id, secret },
    );
    defer allocator.free(refresh_req);
    const refresh_json = try plane.refreshNodeLease(refresh_req);
    defer allocator.free(refresh_json);
    try std.testing.expect(std.mem.indexOf(u8, refresh_json, "\"lease_token\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, refresh_json, "\"fs_url\":\"ws://127.0.0.1:28891/fs\"") != null);
}

test "acheron_control_plane: project mount conflict is rejected" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const invite_json = try plane.createNodeInvite(null);
    defer allocator.free(invite_json);
    var parsed_invite = try std.json.parseFromSlice(std.json.Value, allocator, invite_json, .{});
    defer parsed_invite.deinit();
    const token = parsed_invite.value.object.get("invite_token").?.string;

    const join_req = try std.fmt.allocPrint(allocator, "{{\"invite_token\":\"{s}\"}}", .{token});
    defer allocator.free(join_req);
    const join_json = try plane.nodeJoin(join_req);
    defer allocator.free(join_json);
    var parsed_join = try std.json.parseFromSlice(std.json.Value, allocator, join_json, .{});
    defer parsed_join.deinit();
    const node_id = parsed_join.value.object.get("node_id").?.string;

    const create_json = try plane.createWorkspace("{\"name\":\"Demo\",\"vision\":\"Demo\"}");
    defer allocator.free(create_json);
    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, create_json, .{});
    defer parsed_project.deinit();
    const workspace_id = parsed_project.value.object.get("workspace_id").?.string;
    const workspace_token = parsed_project.value.object.get("workspace_token").?.string;

    const mount_a = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"work\",\"mount_path\":\"/src\"}}",
        .{ workspace_id, workspace_token, node_id },
    );
    defer allocator.free(mount_a);
    const first = try plane.setWorkspaceMount(mount_a);
    defer allocator.free(first);

    const mount_b = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"work\",\"mount_path\":\"/src/lib\"}}",
        .{ workspace_id, workspace_token, node_id },
    );
    defer allocator.free(mount_b);
    try std.testing.expectError(ControlPlaneError.MountConflict, plane.setWorkspaceMount(mount_b));
}

test "acheron_control_plane: project bind lifecycle resolves bound paths" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const joined = try plane.ensureNode("bind-lifecycle-node", "ws://127.0.0.1:18891/fs", 60_000);
    defer allocator.free(joined);
    var joined_parsed = try std.json.parseFromSlice(std.json.Value, allocator, joined, .{});
    defer joined_parsed.deinit();
    const node_id = joined_parsed.value.object.get("node_id").?.string;

    const project_json = try plane.createWorkspace("{\"name\":\"Bindings\",\"vision\":\"Bindings\"}");
    defer allocator.free(project_json);
    var project = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer project.deinit();
    const workspace_id = project.value.object.get("workspace_id").?.string;
    const workspace_token = project.value.object.get("workspace_token").?.string;

    const mount_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"work\",\"mount_path\":\"/nodes/local/fs\"}}",
        .{ workspace_id, workspace_token, node_id },
    );
    defer allocator.free(mount_req);
    const mounted = try plane.setWorkspaceMount(mount_req);
    defer allocator.free(mounted);

    const bind_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"bind_path\":\"/repo\",\"target_path\":\"/nodes/local/fs\"}}",
        .{ workspace_id, workspace_token },
    );
    defer allocator.free(bind_req);
    const bound = try plane.setWorkspaceBind(bind_req);
    defer allocator.free(bound);
    try std.testing.expect(std.mem.indexOf(u8, bound, "\"bind_path\":\"/repo\"") != null);

    const list_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\"}}",
        .{ workspace_id, workspace_token },
    );
    defer allocator.free(list_req);
    const listed = try plane.listWorkspaceBinds(list_req);
    defer allocator.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"target_path\":\"/nodes/local/fs\"") != null);

    const resolve_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"path\":\"/repo/src\"}}",
        .{ workspace_id, workspace_token },
    );
    defer allocator.free(resolve_req);
    const resolved = try plane.resolveWorkspacePath(resolve_req);
    defer allocator.free(resolved);
    try std.testing.expect(std.mem.indexOf(u8, resolved, "\"matched\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resolved, "\"resolved_path\":\"/nodes/local/fs/src\"") != null);

    const unbind_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"bind_path\":\"/repo\"}}",
        .{ workspace_id, workspace_token },
    );
    defer allocator.free(unbind_req);
    const unbound = try plane.removeWorkspaceBind(unbind_req);
    defer allocator.free(unbound);
    try std.testing.expect(std.mem.indexOf(u8, unbound, "\"bind_path\":\"/repo\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, unbound, "\"bind_path\":\"/.spiderweb/control/workspace/mounts\"") != null);
}

test "acheron_control_plane: bind conflicts with existing mount path" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const joined = try plane.ensureNode("bind-conflict-node", "ws://127.0.0.1:18891/fs", 60_000);
    defer allocator.free(joined);
    var joined_parsed = try std.json.parseFromSlice(std.json.Value, allocator, joined, .{});
    defer joined_parsed.deinit();
    const node_id = joined_parsed.value.object.get("node_id").?.string;

    const project_json = try plane.createWorkspace("{\"name\":\"BindConflict\",\"vision\":\"BindConflict\"}");
    defer allocator.free(project_json);
    var project = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer project.deinit();
    const workspace_id = project.value.object.get("workspace_id").?.string;
    const workspace_token = project.value.object.get("workspace_token").?.string;

    const mount_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"work\",\"mount_path\":\"/src\"}}",
        .{ workspace_id, workspace_token, node_id },
    );
    defer allocator.free(mount_req);
    const mounted = try plane.setWorkspaceMount(mount_req);
    defer allocator.free(mounted);

    const bind_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"bind_path\":\"/src\",\"target_path\":\"/nodes/{s}/fs\"}}",
        .{ workspace_id, workspace_token, node_id },
    );
    defer allocator.free(bind_req);
    try std.testing.expectError(ControlPlaneError.BindConflict, plane.setWorkspaceBind(bind_req));
}

test "acheron_control_plane: bind target must remain within mounted authority" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const joined = try plane.ensureNode("bind-authority-node", "ws://127.0.0.1:18891/fs", 60_000);
    defer allocator.free(joined);
    var joined_parsed = try std.json.parseFromSlice(std.json.Value, allocator, joined, .{});
    defer joined_parsed.deinit();
    const node_id = joined_parsed.value.object.get("node_id").?.string;

    const project_json = try plane.createWorkspace("{\"name\":\"BindAuthority\",\"vision\":\"BindAuthority\"}");
    defer allocator.free(project_json);
    var project = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer project.deinit();
    const workspace_id = project.value.object.get("workspace_id").?.string;
    const workspace_token = project.value.object.get("workspace_token").?.string;

    const mount_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"work\",\"mount_path\":\"/src\"}}",
        .{ workspace_id, workspace_token, node_id },
    );
    defer allocator.free(mount_req);
    const mounted = try plane.setWorkspaceMount(mount_req);
    defer allocator.free(mounted);

    const bind_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"bind_path\":\"/repo\",\"target_path\":\"/nodes/local/fs\"}}",
        .{ workspace_id, workspace_token },
    );
    defer allocator.free(bind_req);
    try std.testing.expectError(ControlPlaneError.BindConflict, plane.setWorkspaceBind(bind_req));
}

test "acheron_control_plane: project mutation requires valid workspace_token" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const invite_json = try plane.createNodeInvite(null);
    defer allocator.free(invite_json);
    var parsed_invite = try std.json.parseFromSlice(std.json.Value, allocator, invite_json, .{});
    defer parsed_invite.deinit();
    const token = parsed_invite.value.object.get("invite_token").?.string;

    const join_req = try std.fmt.allocPrint(
        allocator,
        "{{\"invite_token\":\"{s}\",\"node_name\":\"alpha\",\"fs_url\":\"ws://127.0.0.1:18891/fs\"}}",
        .{token},
    );
    defer allocator.free(join_req);
    const join_json = try plane.nodeJoin(join_req);
    defer allocator.free(join_json);
    var parsed_join = try std.json.parseFromSlice(std.json.Value, allocator, join_json, .{});
    defer parsed_join.deinit();
    const node_id = parsed_join.value.object.get("node_id").?.string;

    const project_json = try plane.createWorkspace("{\"name\":\"Secure\",\"vision\":\"Secure\"}");
    defer allocator.free(project_json);
    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer parsed_project.deinit();
    const workspace_id = parsed_project.value.object.get("workspace_id").?.string;

    const bad_mount_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"not-the-token\",\"node_id\":\"{s}\",\"export_name\":\"work\",\"mount_path\":\"/src\"}}",
        .{ workspace_id, node_id },
    );
    defer allocator.free(bad_mount_req);
    const mounted = try plane.setWorkspaceMount(bad_mount_req);
    defer allocator.free(mounted);
    try std.testing.expect(std.mem.indexOf(u8, mounted, "\"mount_path\":\"/src\"") != null);
}

test "acheron_control_plane: access policy enforces action modes and per-agent overrides" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const ensured = try plane.ensureNode("policy-node", "ws://127.0.0.1:18891/fs", 60_000);
    defer allocator.free(ensured);
    var ensured_parsed = try std.json.parseFromSlice(std.json.Value, allocator, ensured, .{});
    defer ensured_parsed.deinit();
    const node_id = ensured_parsed.value.object.get("node_id").?.string;

    const create_project = try plane.createWorkspace(
        "{\"name\":\"PolicyOps\",\"vision\":\"PolicyOps\",\"access_policy\":{\"actions\":{\"mount\":\"deny\"}}}",
    );
    defer allocator.free(create_project);
    try std.testing.expect(std.mem.indexOf(u8, create_project, "\"access_policy\"") != null);
    var project = try std.json.parseFromSlice(std.json.Value, allocator, create_project, .{});
    defer project.deinit();
    const workspace_id = project.value.object.get("workspace_id").?.string;

    const denied_mount_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"work\",\"mount_path\":\"/src\"}}",
        .{ workspace_id, node_id },
    );
    defer allocator.free(denied_mount_req);
    try std.testing.expectError(ControlPlaneError.WorkspacePolicyForbidden, plane.setWorkspaceMount(denied_mount_req));
    try std.testing.expect(!plane.workspaceAllowsAction(workspace_id, "bob", .bind, null, false));

    const denied_bind_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"bind_path\":\"/repo\",\"target_path\":\"/nodes/local/fs\"}}",
        .{workspace_id},
    );
    defer allocator.free(denied_bind_req);
    try std.testing.expectError(ControlPlaneError.WorkspacePolicyForbidden, plane.setWorkspaceBind(denied_bind_req));

    const update_policy_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"access_policy\":{{\"actions\":{{\"mount\":\"open\",\"observe\":\"open\"}},\"agents\":{{\"alice\":{{\"mount\":\"deny\",\"observe\":\"deny\"}}}}}}}}",
        .{workspace_id},
    );
    defer allocator.free(update_policy_req);
    const updated = try plane.updateWorkspace(update_policy_req);
    defer allocator.free(updated);
    try std.testing.expect(std.mem.indexOf(u8, updated, "\"access_policy\"") != null);

    try std.testing.expect(plane.workspaceAllowsAction(workspace_id, "bob", .mount, null, false));
    try std.testing.expect(plane.workspaceAllowsAction(workspace_id, "bob", .bind, null, false));
    try std.testing.expect(!plane.workspaceAllowsAction(workspace_id, "alice", .mount, null, false));
    try std.testing.expect(!plane.workspaceAllowsAction(workspace_id, "alice", .bind, null, false));
    try std.testing.expect(plane.workspaceAllowsAction(workspace_id, "bob", .observe, null, false));
    try std.testing.expect(!plane.workspaceAllowsAction(workspace_id, "alice", .observe, null, false));

    const mounted_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"work\",\"mount_path\":\"/src\"}}",
        .{ workspace_id, node_id },
    );
    defer allocator.free(mounted_req);
    const mounted_json = try plane.setWorkspaceMount(mounted_req);
    defer allocator.free(mounted_json);
    try std.testing.expect(plane.workspaceAllowsNodeVenomEvent(workspace_id, "bob", null, node_id, false));
    try std.testing.expect(!plane.workspaceAllowsNodeVenomEvent(workspace_id, "alice", null, node_id, false));

    const rotate_req = try std.fmt.allocPrint(allocator, "{{\"workspace_id\":\"{s}\"}}", .{workspace_id});
    defer allocator.free(rotate_req);
    const rotated = try plane.rotateWorkspaceToken(rotate_req);
    defer allocator.free(rotated);
    var rotated_parsed = try std.json.parseFromSlice(std.json.Value, allocator, rotated, .{});
    defer rotated_parsed.deinit();
    const workspace_token = rotated_parsed.value.object.get("workspace_token").?.string;

    try std.testing.expect(!plane.workspaceAllowsAction(workspace_id, "bob", .read, null, false));
    try std.testing.expect(plane.workspaceAllowsAction(workspace_id, "bob", .read, workspace_token, false));
    try std.testing.expect(!plane.workspaceAllowsAction(workspace_id, "bob", .observe, null, false));
    try std.testing.expect(plane.workspaceAllowsAction(workspace_id, "bob", .observe, workspace_token, false));
    try std.testing.expect(!plane.workspaceAllowsAction(workspace_id, "alice", .mount, workspace_token, false));
    try std.testing.expect(plane.workspaceAllowsNodeVenomEvent(workspace_id, "bob", workspace_token, node_id, false));
    try std.testing.expect(!plane.workspaceAllowsNodeVenomEvent(workspace_id, "bob", null, node_id, false));
}

test "acheron_control_plane: access policy action matrix honors token admin and per-agent override" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const project_json = try plane.createWorkspace(
        "{\"name\":\"PolicyMatrix\",\"vision\":\"PolicyMatrix\",\"access_policy\":{\"actions\":{\"read\":\"open\",\"observe\":\"token\",\"invoke\":\"admin\",\"mount\":\"deny\",\"bind\":\"deny\",\"admin\":\"token\"},\"agents\":{\"worker\":{\"invoke\":\"open\",\"mount\":\"token\",\"bind\":\"token\"}}}}",
    );
    defer allocator.free(project_json);
    var project = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer project.deinit();
    const workspace_id = project.value.object.get("workspace_id").?.string;
    const workspace_token = project.value.object.get("workspace_token").?.string;

    try std.testing.expect(plane.workspaceAllowsAction(workspace_id, "bob", .read, null, false));
    try std.testing.expect(!plane.workspaceAllowsAction(workspace_id, "bob", .observe, null, false));
    try std.testing.expect(plane.workspaceAllowsAction(workspace_id, "bob", .observe, workspace_token, false));
    try std.testing.expect(!plane.workspaceAllowsAction(workspace_id, "bob", .invoke, null, false));
    try std.testing.expect(!plane.workspaceAllowsAction(workspace_id, "bob", .invoke, workspace_token, false));
    try std.testing.expect(!plane.workspaceAllowsAction(workspace_id, "bob", .mount, null, false));
    try std.testing.expect(!plane.workspaceAllowsAction(workspace_id, "bob", .mount, workspace_token, false));
    try std.testing.expect(!plane.workspaceAllowsAction(workspace_id, "bob", .bind, null, false));
    try std.testing.expect(!plane.workspaceAllowsAction(workspace_id, "bob", .bind, workspace_token, false));
    try std.testing.expect(!plane.workspaceAllowsAction(workspace_id, "bob", .admin, null, false));
    try std.testing.expect(plane.workspaceAllowsAction(workspace_id, "bob", .admin, workspace_token, false));

    try std.testing.expect(plane.workspaceAllowsAction(workspace_id, "worker", .invoke, null, false));
    try std.testing.expect(!plane.workspaceAllowsAction(workspace_id, "worker", .mount, null, false));
    try std.testing.expect(plane.workspaceAllowsAction(workspace_id, "worker", .mount, workspace_token, false));
    try std.testing.expect(!plane.workspaceAllowsAction(workspace_id, "worker", .bind, null, false));
    try std.testing.expect(plane.workspaceAllowsAction(workspace_id, "worker", .bind, workspace_token, false));

    try std.testing.expect(plane.workspaceAllowsAction(workspace_id, "bob", .read, null, true));
    try std.testing.expect(plane.workspaceAllowsAction(workspace_id, "bob", .observe, null, true));
    try std.testing.expect(plane.workspaceAllowsAction(workspace_id, "bob", .invoke, null, true));
    try std.testing.expect(plane.workspaceAllowsAction(workspace_id, "bob", .mount, null, true));
    try std.testing.expect(plane.workspaceAllowsAction(workspace_id, "bob", .bind, null, true));
    try std.testing.expect(plane.workspaceAllowsAction(workspace_id, "bob", .admin, null, true));
}

test "acheron_control_plane: workspace status filters invoke service mounts when invoke is denied" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const ensured = try plane.ensureNode("workspace-invoke-node", "ws://127.0.0.1:18891/fs", 60_000);
    defer allocator.free(ensured);
    var ensured_parsed = try std.json.parseFromSlice(std.json.Value, allocator, ensured, .{});
    defer ensured_parsed.deinit();
    if (ensured_parsed.value != .object) return error.TestExpectedResponse;
    const node_id = ensured_parsed.value.object.get("node_id").?.string;
    const node_secret = ensured_parsed.value.object.get("node_secret").?.string;

    const escaped_node_id = try jsonEscape(allocator, node_id);
    defer allocator.free(escaped_node_id);
    const escaped_node_secret = try jsonEscape(allocator, node_secret);
    defer allocator.free(escaped_node_secret);
    const upsert_req = try std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"venoms\":[" ++
            "{{\"venom_id\":\"fs-main\",\"kind\":\"fs\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"/nodes/{s}/fs\"],\"capabilities\":{{\"rw\":true}},\"mounts\":[{{\"mount_id\":\"fs-main\",\"mount_path\":\"/nodes/{s}/fs\",\"state\":\"online\"}}],\"ops\":{{\"model\":\"namespace\"}},\"runtime\":{{\"type\":\"native_proc\"}},\"permissions\":{{\"default\":\"allow-by-default\",\"allow_roles\":[\"user\"]}},\"schema\":{{\"model\":\"namespace-service-v1\"}}}}," ++
            "{{\"venom_id\":\"tool-main\",\"kind\":\"tool\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"/nodes/{s}/tool/main\"],\"capabilities\":{{\"invoke\":true}},\"mounts\":[{{\"mount_id\":\"tool-main\",\"mount_path\":\"/nodes/{s}/tool/main\",\"state\":\"online\"}}],\"ops\":{{\"model\":\"namespace\",\"invoke\":\"control/invoke.json\"}},\"runtime\":{{\"type\":\"native_proc\"}},\"permissions\":{{\"default\":\"allow-by-default\",\"allow_roles\":[\"user\"]}},\"schema\":{{\"model\":\"namespace-service-v1\"}}}}" ++
            "]}}",
        .{
            escaped_node_id,
            escaped_node_secret,
            escaped_node_id,
            escaped_node_id,
            escaped_node_id,
            escaped_node_id,
        },
    );
    defer allocator.free(upsert_req);
    const upserted = try plane.nodeVenomUpsert(upsert_req);
    defer allocator.free(upserted);

    const project_json = try plane.createWorkspace(
        "{\"name\":\"InvokeFilteredWorkspace\",\"vision\":\"InvokeFilteredWorkspace\",\"access_policy\":{\"actions\":{\"invoke\":\"open\"},\"agents\":{\"default\":{\"invoke\":\"deny\"}}}}",
    );
    defer allocator.free(project_json);
    var project_parsed = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer project_parsed.deinit();
    if (project_parsed.value != .object) return error.TestExpectedResponse;
    const workspace_id = project_parsed.value.object.get("workspace_id").?.string;

    const mount_fs_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"fs-main\",\"mount_path\":\"/nodes/{s}/fs\"}}",
        .{ workspace_id, node_id, node_id },
    );
    defer allocator.free(mount_fs_req);
    const mount_fs = try plane.setWorkspaceMount(mount_fs_req);
    defer allocator.free(mount_fs);

    const mount_tool_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"tool-main\",\"mount_path\":\"/nodes/{s}/tool/main\"}}",
        .{ workspace_id, node_id, node_id },
    );
    defer allocator.free(mount_tool_req);
    const mount_tool = try plane.setWorkspaceMount(mount_tool_req);
    defer allocator.free(mount_tool);

    const selected_req = try std.fmt.allocPrint(allocator, "{{\"workspace_id\":\"{s}\"}}", .{workspace_id});
    defer allocator.free(selected_req);

    const user_status = try plane.workspaceStatus(default_host_actor_id, selected_req);
    defer allocator.free(user_status);
    try std.testing.expect(std.mem.indexOf(u8, user_status, "\"mount_path\":\"/nodes/") != null);
    try std.testing.expect(std.mem.indexOf(u8, user_status, "/fs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, user_status, "/tool/main\"") == null);

    const admin_status = try plane.workspaceStatusWithRole(default_host_actor_id, selected_req, true);
    defer allocator.free(admin_status);
    try std.testing.expect(std.mem.indexOf(u8, admin_status, "/tool/main\"") != null);
}

test "acheron_control_plane: invalid access policy payload is rejected" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    try std.testing.expectError(
        ControlPlaneError.InvalidPayload,
        plane.createWorkspace("{\"name\":\"BadPolicy\",\"vision\":\"BadPolicy\",\"access_policy\":{\"actions\":{\"read\":true}}}"),
    );
}

test "acheron_control_plane: identical mount path can be used for failover nodes" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const invite_a_json = try plane.createNodeInvite(null);
    defer allocator.free(invite_a_json);
    var invite_a = try std.json.parseFromSlice(std.json.Value, allocator, invite_a_json, .{});
    defer invite_a.deinit();
    const token_a = invite_a.value.object.get("invite_token").?.string;

    const join_a_req = try std.fmt.allocPrint(
        allocator,
        "{{\"invite_token\":\"{s}\",\"node_name\":\"alpha\",\"fs_url\":\"ws://127.0.0.1:18891/fs\"}}",
        .{token_a},
    );
    defer allocator.free(join_a_req);
    const join_a_json = try plane.nodeJoin(join_a_req);
    defer allocator.free(join_a_json);
    var join_a = try std.json.parseFromSlice(std.json.Value, allocator, join_a_json, .{});
    defer join_a.deinit();
    const node_a = join_a.value.object.get("node_id").?.string;

    const invite_b_json = try plane.createNodeInvite(null);
    defer allocator.free(invite_b_json);
    var invite_b = try std.json.parseFromSlice(std.json.Value, allocator, invite_b_json, .{});
    defer invite_b.deinit();
    const token_b = invite_b.value.object.get("invite_token").?.string;

    const join_b_req = try std.fmt.allocPrint(
        allocator,
        "{{\"invite_token\":\"{s}\",\"node_name\":\"beta\",\"fs_url\":\"ws://127.0.0.1:18892/fs\"}}",
        .{token_b},
    );
    defer allocator.free(join_b_req);
    const join_b_json = try plane.nodeJoin(join_b_req);
    defer allocator.free(join_b_json);
    var join_b = try std.json.parseFromSlice(std.json.Value, allocator, join_b_json, .{});
    defer join_b.deinit();
    const node_b = join_b.value.object.get("node_id").?.string;

    const project_json = try plane.createWorkspace("{\"name\":\"Failover\",\"vision\":\"Failover\"}");
    defer allocator.free(project_json);
    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer parsed_project.deinit();
    const workspace_id = parsed_project.value.object.get("workspace_id").?.string;
    const workspace_token = parsed_project.value.object.get("workspace_token").?.string;

    const mount_a = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"work\",\"mount_path\":\"/src\"}}",
        .{ workspace_id, workspace_token, node_a },
    );
    defer allocator.free(mount_a);
    const first = try plane.setWorkspaceMount(mount_a);
    defer allocator.free(first);

    const mount_b = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"work\",\"mount_path\":\"/src\"}}",
        .{ workspace_id, workspace_token, node_b },
    );
    defer allocator.free(mount_b);
    const second = try plane.setWorkspaceMount(mount_b);
    defer allocator.free(second);

    try std.testing.expect(std.mem.indexOf(u8, second, "\"node_id\":\"node-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"node_id\":\"node-2\"") != null);
}

test "acheron_control_plane: removeWorkspaceMount supports path-wide and targeted failover removal" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const invite_a_json = try plane.createNodeInvite(null);
    defer allocator.free(invite_a_json);
    var invite_a = try std.json.parseFromSlice(std.json.Value, allocator, invite_a_json, .{});
    defer invite_a.deinit();
    const token_a = invite_a.value.object.get("invite_token").?.string;

    const join_a_req = try std.fmt.allocPrint(
        allocator,
        "{{\"invite_token\":\"{s}\",\"node_name\":\"alpha\",\"fs_url\":\"ws://127.0.0.1:18891/fs\"}}",
        .{token_a},
    );
    defer allocator.free(join_a_req);
    const join_a_json = try plane.nodeJoin(join_a_req);
    defer allocator.free(join_a_json);
    var join_a = try std.json.parseFromSlice(std.json.Value, allocator, join_a_json, .{});
    defer join_a.deinit();
    const node_a = join_a.value.object.get("node_id").?.string;

    const invite_b_json = try plane.createNodeInvite(null);
    defer allocator.free(invite_b_json);
    var invite_b = try std.json.parseFromSlice(std.json.Value, allocator, invite_b_json, .{});
    defer invite_b.deinit();
    const token_b = invite_b.value.object.get("invite_token").?.string;

    const join_b_req = try std.fmt.allocPrint(
        allocator,
        "{{\"invite_token\":\"{s}\",\"node_name\":\"beta\",\"fs_url\":\"ws://127.0.0.1:18892/fs\"}}",
        .{token_b},
    );
    defer allocator.free(join_b_req);
    const join_b_json = try plane.nodeJoin(join_b_req);
    defer allocator.free(join_b_json);
    var join_b = try std.json.parseFromSlice(std.json.Value, allocator, join_b_json, .{});
    defer join_b.deinit();
    const node_b = join_b.value.object.get("node_id").?.string;

    const project_json = try plane.createWorkspace("{\"name\":\"FailoverRemove\",\"vision\":\"FailoverRemove\"}");
    defer allocator.free(project_json);
    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer parsed_project.deinit();
    const workspace_id = parsed_project.value.object.get("workspace_id").?.string;
    const workspace_token = parsed_project.value.object.get("workspace_token").?.string;

    const mount_a = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"work\",\"mount_path\":\"/src\"}}",
        .{ workspace_id, workspace_token, node_a },
    );
    defer allocator.free(mount_a);
    const first = try plane.setWorkspaceMount(mount_a);
    defer allocator.free(first);

    const mount_b = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"work\",\"mount_path\":\"/src\"}}",
        .{ workspace_id, workspace_token, node_b },
    );
    defer allocator.free(mount_b);
    const second = try plane.setWorkspaceMount(mount_b);
    defer allocator.free(second);

    const remove_targeted = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"mount_path\":\"/src\",\"node_id\":\"{s}\",\"export_name\":\"work\"}}",
        .{ workspace_id, workspace_token, node_a },
    );
    defer allocator.free(remove_targeted);
    const targeted_removed = try plane.removeWorkspaceMount(remove_targeted);
    defer allocator.free(targeted_removed);
    const node_a_entry = try std.fmt.allocPrint(allocator, "\"node_id\":\"{s}\"", .{node_a});
    defer allocator.free(node_a_entry);
    const node_b_entry = try std.fmt.allocPrint(allocator, "\"node_id\":\"{s}\"", .{node_b});
    defer allocator.free(node_b_entry);
    try std.testing.expect(std.mem.indexOf(u8, targeted_removed, node_a_entry) == null);
    try std.testing.expect(std.mem.indexOf(u8, targeted_removed, node_b_entry) != null);

    const remove_all = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"mount_path\":\"/src\"}}",
        .{ workspace_id, workspace_token },
    );
    defer allocator.free(remove_all);
    const all_removed = try plane.removeWorkspaceMount(remove_all);
    defer allocator.free(all_removed);
    try std.testing.expect(std.mem.indexOf(u8, all_removed, "\"mounts\":[]") != null);
}

test "acheron_control_plane: lease reaper removes expired nodes and project mounts" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const invite_json = try plane.createNodeInvite(null);
    defer allocator.free(invite_json);
    var invite = try std.json.parseFromSlice(std.json.Value, allocator, invite_json, .{});
    defer invite.deinit();
    const token = invite.value.object.get("invite_token").?.string;

    const join_req = try std.fmt.allocPrint(
        allocator,
        "{{\"invite_token\":\"{s}\",\"node_name\":\"ephemeral\",\"fs_url\":\"ws://127.0.0.1:18891/fs\"}}",
        .{token},
    );
    defer allocator.free(join_req);
    const join_json = try plane.nodeJoin(join_req);
    defer allocator.free(join_json);
    var join = try std.json.parseFromSlice(std.json.Value, allocator, join_json, .{});
    defer join.deinit();
    const node_id = join.value.object.get("node_id").?.string;

    const project_json = try plane.createWorkspace("{\"name\":\"Lease GC\",\"vision\":\"Lease GC\"}");
    defer allocator.free(project_json);
    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer parsed_project.deinit();
    const workspace_id = parsed_project.value.object.get("workspace_id").?.string;
    const workspace_token = parsed_project.value.object.get("workspace_token").?.string;

    const mount_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"work\",\"mount_path\":\"/src\"}}",
        .{ workspace_id, workspace_token, node_id },
    );
    defer allocator.free(mount_req);
    const mounted = try plane.setWorkspaceMount(mount_req);
    defer allocator.free(mounted);

    plane.mutex.lock();
    if (plane.nodes.getPtr(node_id)) |node| {
        node.lease_expires_at_ms = 0;
    }
    _ = plane.reapExpiredLeasesLocked(std.time.milliTimestamp());
    plane.mutex.unlock();

    const nodes_json = try plane.listNodes();
    defer allocator.free(nodes_json);
    try std.testing.expect(std.mem.indexOf(u8, nodes_json, node_id) == null);

    const get_project_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\"}}",
        .{workspace_id},
    );
    defer allocator.free(get_project_req);
    const project_after = try plane.getWorkspace(get_project_req);
    defer allocator.free(project_after);
    try std.testing.expect(std.mem.indexOf(u8, project_after, "\"mounts\":[]") != null);
}

test "acheron_control_plane: ensureNode upserts by node name" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const created = try plane.ensureNode("local", "ws://127.0.0.1:18891/fs", 60_000);
    defer allocator.free(created);
    try std.testing.expect(std.mem.indexOf(u8, created, "\"node_id\":\"node-1\"") != null);

    const updated = try plane.ensureNode("local", "ws://127.0.0.1:28891/fs", 60_000);
    defer allocator.free(updated);
    try std.testing.expect(std.mem.indexOf(u8, updated, "\"node_id\":\"node-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "\"fs_url\":\"ws://127.0.0.1:28891/fs\"") != null);

    const nodes_json = try plane.listNodes();
    defer allocator.free(nodes_json);
    try std.testing.expect(std.mem.indexOf(u8, nodes_json, "\"node_id\":\"node-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, nodes_json, "\"node_id\":\"node-2\"") == null);
}

test "acheron_control_plane: metricsJson reports mutation counters" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const invite_json = try plane.createNodeInvite(null);
    defer allocator.free(invite_json);
    var invite = try std.json.parseFromSlice(std.json.Value, allocator, invite_json, .{});
    defer invite.deinit();
    const token = invite.value.object.get("invite_token").?.string;

    const join_req = try std.fmt.allocPrint(
        allocator,
        "{{\"invite_token\":\"{s}\",\"node_name\":\"alpha\",\"fs_url\":\"ws://127.0.0.1:18891/fs\"}}",
        .{token},
    );
    defer allocator.free(join_req);
    const join_json = try plane.nodeJoin(join_req);
    defer allocator.free(join_json);
    var join = try std.json.parseFromSlice(std.json.Value, allocator, join_json, .{});
    defer join.deinit();
    const node_id = join.value.object.get("node_id").?.string;

    const project_json = try plane.createWorkspace("{\"name\":\"Metrics\",\"vision\":\"Metrics\"}");
    defer allocator.free(project_json);
    var project = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer project.deinit();
    const workspace_id = project.value.object.get("workspace_id").?.string;
    const workspace_token = project.value.object.get("workspace_token").?.string;

    const mount_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"work\",\"mount_path\":\"/src\"}}",
        .{ workspace_id, workspace_token, node_id },
    );
    defer allocator.free(mount_req);
    const mounted = try plane.setWorkspaceMount(mount_req);
    defer allocator.free(mounted);

    const activate_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\"}}",
        .{ workspace_id, workspace_token },
    );
    defer allocator.free(activate_req);
    const activated = try plane.activateWorkspace("agent-metrics", activate_req);
    defer allocator.free(activated);

    const metrics_json = try plane.metricsJson();
    defer allocator.free(metrics_json);
    try std.testing.expect(std.mem.indexOf(u8, metrics_json, "\"created_total\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, metrics_json, "\"joins_total\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, metrics_json, "\"mount_sets_total\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, metrics_json, "\"activations_total\":1") != null);
}

test "acheron_control_plane: rotate and revoke project tokens invalidate previous token" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const invite_json = try plane.createNodeInvite(null);
    defer allocator.free(invite_json);
    var invite = try std.json.parseFromSlice(std.json.Value, allocator, invite_json, .{});
    defer invite.deinit();
    const invite_token = invite.value.object.get("invite_token").?.string;

    const join_req = try std.fmt.allocPrint(
        allocator,
        "{{\"invite_token\":\"{s}\",\"node_name\":\"alpha\",\"fs_url\":\"ws://127.0.0.1:18891/fs\"}}",
        .{invite_token},
    );
    defer allocator.free(join_req);
    const join_json = try plane.nodeJoin(join_req);
    defer allocator.free(join_json);
    var join = try std.json.parseFromSlice(std.json.Value, allocator, join_json, .{});
    defer join.deinit();
    const node_id = join.value.object.get("node_id").?.string;

    const project_json = try plane.createWorkspace("{\"name\":\"TokenOps\",\"vision\":\"TokenOps\"}");
    defer allocator.free(project_json);
    var project = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer project.deinit();
    const workspace_id = project.value.object.get("workspace_id").?.string;
    const token_1 = project.value.object.get("workspace_token").?.string;

    const rotate_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\"}}",
        .{ workspace_id, token_1 },
    );
    defer allocator.free(rotate_req);
    const rotate_json = try plane.rotateWorkspaceToken(rotate_req);
    defer allocator.free(rotate_json);
    var rotate = try std.json.parseFromSlice(std.json.Value, allocator, rotate_json, .{});
    defer rotate.deinit();
    const token_2 = rotate.value.object.get("workspace_token").?.string;
    try std.testing.expect(!std.mem.eql(u8, token_1, token_2));

    const mount_old_token = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"work\",\"mount_path\":\"/src\"}}",
        .{ workspace_id, token_1, node_id },
    );
    defer allocator.free(mount_old_token);
    try std.testing.expectError(ControlPlaneError.WorkspaceAuthFailed, plane.setWorkspaceMount(mount_old_token));

    const mount_new_token = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"work\",\"mount_path\":\"/src\"}}",
        .{ workspace_id, token_2, node_id },
    );
    defer allocator.free(mount_new_token);
    const mounted = try plane.setWorkspaceMount(mount_new_token);
    defer allocator.free(mounted);

    const revoke_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\"}}",
        .{ workspace_id, token_2 },
    );
    defer allocator.free(revoke_req);
    const revoke_json = try plane.revokeWorkspaceToken(revoke_req);
    defer allocator.free(revoke_json);
    var revoke = try std.json.parseFromSlice(std.json.Value, allocator, revoke_json, .{});
    defer revoke.deinit();
    const token_3 = revoke.value.object.get("workspace_token").?.string;
    try std.testing.expect(!std.mem.eql(u8, token_2, token_3));

    const remove_old_token = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"mount_path\":\"/src\"}}",
        .{ workspace_id, token_2 },
    );
    defer allocator.free(remove_old_token);
    try std.testing.expectError(ControlPlaneError.WorkspaceAuthFailed, plane.removeWorkspaceMount(remove_old_token));

    const remove_new_token = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"mount_path\":\"/src\"}}",
        .{ workspace_id, token_3 },
    );
    defer allocator.free(remove_new_token);
    const removed = try plane.removeWorkspaceMount(remove_new_token);
    defer allocator.free(removed);
}

test "acheron_control_plane: workspaceStatus supports explicit project selection" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const invite_json = try plane.createNodeInvite(null);
    defer allocator.free(invite_json);
    var invite = try std.json.parseFromSlice(std.json.Value, allocator, invite_json, .{});
    defer invite.deinit();
    const invite_token = invite.value.object.get("invite_token").?.string;

    const join_req = try std.fmt.allocPrint(
        allocator,
        "{{\"invite_token\":\"{s}\",\"node_name\":\"alpha\",\"fs_url\":\"ws://127.0.0.1:18891/fs\"}}",
        .{invite_token},
    );
    defer allocator.free(join_req);
    const join_json = try plane.nodeJoin(join_req);
    defer allocator.free(join_json);
    var join = try std.json.parseFromSlice(std.json.Value, allocator, join_json, .{});
    defer join.deinit();
    const node_id = join.value.object.get("node_id").?.string;

    const project_json = try plane.createWorkspace("{\"name\":\"Selector\",\"vision\":\"Selector\"}");
    defer allocator.free(project_json);
    var project = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer project.deinit();
    const workspace_id = project.value.object.get("workspace_id").?.string;
    const workspace_token = project.value.object.get("workspace_token").?.string;

    const mount_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"work\",\"mount_path\":\"/src\"}}",
        .{ workspace_id, workspace_token, node_id },
    );
    defer allocator.free(mount_req);
    const mounted = try plane.setWorkspaceMount(mount_req);
    defer allocator.free(mounted);

    const no_selection = try plane.workspaceStatus("agent-selector", null);
    defer allocator.free(no_selection);
    try std.testing.expect(std.mem.indexOf(u8, no_selection, "\"workspace_id\":null") != null);

    const selected_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\"}}",
        .{ workspace_id, workspace_token },
    );
    defer allocator.free(selected_req);
    const selected = try plane.workspaceStatus("agent-selector", selected_req);
    defer allocator.free(selected);
    try std.testing.expect(std.mem.indexOf(u8, selected, workspace_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, selected, "\"mount_path\":\"/src\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, selected, "\"fs_auth_token\":\"") != null);

    const selected_primary = try plane.workspaceStatus(default_host_actor_id, selected_req);
    defer allocator.free(selected_primary);
    try std.testing.expect(std.mem.indexOf(u8, selected_primary, "\"fs_auth_token\":\"") != null);

    const selected_admin = try plane.workspaceStatusWithRole("agent-selector", selected_req, true);
    defer allocator.free(selected_admin);
    try std.testing.expect(std.mem.indexOf(u8, selected_admin, "\"fs_auth_token\":\"") != null);

    const selected_without_token = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\"}}",
        .{workspace_id},
    );
    defer allocator.free(selected_without_token);
    try std.testing.expectError(
        ControlPlaneError.WorkspaceAuthFailed,
        plane.workspaceStatus("agent-selector", selected_without_token),
    );

    try std.testing.expectError(
        ControlPlaneError.WorkspaceNotFound,
        plane.workspaceStatus("agent-selector", "{\"workspace_id\":\"proj-missing\"}"),
    );
}

test "acheron_control_plane: workspace topology prefers best available candidate and marks degraded mounts" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const node_a_json = try plane.ensureNode("alpha", "ws://127.0.0.1:18891/fs", 60_000);
    defer allocator.free(node_a_json);
    var node_a_payload = try std.json.parseFromSlice(std.json.Value, allocator, node_a_json, .{});
    defer node_a_payload.deinit();
    const node_a_id = node_a_payload.value.object.get("node_id").?.string;

    const node_b_json = try plane.ensureNode("bravo", "ws://127.0.0.1:18892/fs", 60_000);
    defer allocator.free(node_b_json);
    var node_b_payload = try std.json.parseFromSlice(std.json.Value, allocator, node_b_json, .{});
    defer node_b_payload.deinit();
    const node_b_id = node_b_payload.value.object.get("node_id").?.string;

    const project_json = try plane.createWorkspace("{\"name\":\"Failover Select\",\"vision\":\"Failover Select\"}");
    defer allocator.free(project_json);
    var project = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer project.deinit();
    const workspace_id = project.value.object.get("workspace_id").?.string;
    const workspace_token = project.value.object.get("workspace_token").?.string;

    const mount_primary = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"work\",\"mount_path\":\"/src\"}}",
        .{ workspace_id, workspace_token, node_a_id },
    );
    defer allocator.free(mount_primary);
    const mounted_primary = try plane.setWorkspaceMount(mount_primary);
    defer allocator.free(mounted_primary);

    const mount_failover = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"work\",\"mount_path\":\"/src\"}}",
        .{ workspace_id, workspace_token, node_b_id },
    );
    defer allocator.free(mount_failover);
    const mounted_failover = try plane.setWorkspaceMount(mount_failover);
    defer allocator.free(mounted_failover);

    const stale_now = std.time.milliTimestamp();
    plane.mutex.lock();
    if (plane.nodes.getPtr(node_a_id)) |node| node.lease_expires_at_ms = stale_now - 5_000;
    if (plane.nodes.getPtr(node_b_id)) |node| node.lease_expires_at_ms = stale_now - 1_000;
    plane.mutex.unlock();

    const selected_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\"}}",
        .{ workspace_id, workspace_token },
    );
    defer allocator.free(selected_req);

    const status_offline_json = try plane.workspaceStatus("agent-selector", selected_req);
    defer allocator.free(status_offline_json);
    var status_offline = try std.json.parseFromSlice(std.json.Value, allocator, status_offline_json, .{});
    defer status_offline.deinit();
    const mounts_offline = status_offline.value.object.get("mounts").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), mounts_offline.len);
    const selected_offline = mounts_offline[0].object;
    try std.testing.expect(std.mem.eql(u8, selected_offline.get("node_id").?.string, node_b_id));
    try std.testing.expect(std.mem.eql(u8, selected_offline.get("state").?.string, "degraded"));
    try std.testing.expect(selected_offline.get("online").?.bool == false);
    const availability_offline = status_offline.value.object.get("availability").?.object;
    try std.testing.expectEqual(@as(i64, 1), availability_offline.get("mounts_total").?.integer);
    try std.testing.expectEqual(@as(i64, 0), availability_offline.get("online").?.integer);
    try std.testing.expectEqual(@as(i64, 1), availability_offline.get("degraded").?.integer);
    try std.testing.expectEqual(@as(i64, 0), availability_offline.get("missing").?.integer);

    const drift_items_offline = status_offline.value.object.get("drift").?.object.get("items").?.array.items;
    try std.testing.expect(drift_items_offline.len > 0);
    const drift_item_offline = drift_items_offline[0].object;
    try std.testing.expect(std.mem.eql(u8, drift_item_offline.get("kind").?.string, "node_offline"));
    try std.testing.expect(std.mem.eql(u8, drift_item_offline.get("selected_node_id").?.string, node_b_id));
    try std.testing.expect(std.mem.eql(u8, drift_item_offline.get("desired_node_id").?.string, node_a_id));

    plane.mutex.lock();
    if (plane.nodes.fetchRemove(node_a_id)) |removed| {
        var node = removed.value;
        node.deinit(allocator);
    }
    plane.mutex.unlock();

    const status_missing_json = try plane.workspaceStatus("agent-selector", selected_req);
    defer allocator.free(status_missing_json);
    var status_missing = try std.json.parseFromSlice(std.json.Value, allocator, status_missing_json, .{});
    defer status_missing.deinit();
    const mounts_missing = status_missing.value.object.get("mounts").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), mounts_missing.len);
    const selected_missing = mounts_missing[0].object;
    try std.testing.expect(std.mem.eql(u8, selected_missing.get("node_id").?.string, node_b_id));
    try std.testing.expect(std.mem.eql(u8, selected_missing.get("state").?.string, "degraded"));
    try std.testing.expect(selected_missing.get("online").?.bool == false);
    const availability_missing = status_missing.value.object.get("availability").?.object;
    try std.testing.expectEqual(@as(i64, 1), availability_missing.get("mounts_total").?.integer);
    try std.testing.expectEqual(@as(i64, 0), availability_missing.get("online").?.integer);
    try std.testing.expectEqual(@as(i64, 1), availability_missing.get("degraded").?.integer);
    try std.testing.expectEqual(@as(i64, 0), availability_missing.get("missing").?.integer);
}

test "acheron_control_plane: pending join request list approve and deny flow works" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const request_json = try plane.nodeJoinRequest(
        "{\"node_name\":\"delta\",\"fs_url\":\"ws://127.0.0.1:19891/fs\",\"platform\":{\"os\":\"linux\",\"arch\":\"amd64\",\"runtime_kind\":\"native\"}}",
    );
    defer allocator.free(request_json);
    var request = try std.json.parseFromSlice(std.json.Value, allocator, request_json, .{});
    defer request.deinit();
    const request_id = request.value.object.get("request_id").?.string;

    const listed = try plane.listPendingNodeJoins("{}");
    defer allocator.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, request_id) != null);

    const approve_req = try std.fmt.allocPrint(
        allocator,
        "{{\"request_id\":\"{s}\"}}",
        .{request_id},
    );
    defer allocator.free(approve_req);
    const approved = try plane.approvePendingNodeJoin(approve_req);
    defer allocator.free(approved);
    try std.testing.expect(std.mem.indexOf(u8, approved, "\"node_name\":\"delta\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, approved, "\"runtime_kind\":\"native\"") != null);

    const listed_after = try plane.listPendingNodeJoins("{}");
    defer allocator.free(listed_after);
    try std.testing.expect(std.mem.indexOf(u8, listed_after, "\"pending\":[]") != null);

    const request2_json = try plane.nodeJoinRequest(
        "{\"node_name\":\"epsilon\",\"fs_url\":\"ws://127.0.0.1:19892/fs\"}",
    );
    defer allocator.free(request2_json);
    var request2 = try std.json.parseFromSlice(std.json.Value, allocator, request2_json, .{});
    defer request2.deinit();
    const request2_id = request2.value.object.get("request_id").?.string;

    const deny_req = try std.fmt.allocPrint(
        allocator,
        "{{\"request_id\":\"{s}\"}}",
        .{request2_id},
    );
    defer allocator.free(deny_req);
    const denied = try plane.denyPendingNodeJoin(deny_req);
    defer allocator.free(denied);
    try std.testing.expect(std.mem.indexOf(u8, denied, "\"denied\":true") != null);

    try std.testing.expectError(
        ControlPlaneError.PendingJoinNotFound,
        plane.denyPendingNodeJoin(deny_req),
    );
}

test "acheron_control_plane: node venom upsert and get stores catalog metadata" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const invite_json = try plane.createNodeInvite(null);
    defer allocator.free(invite_json);
    var invite = try std.json.parseFromSlice(std.json.Value, allocator, invite_json, .{});
    defer invite.deinit();
    const invite_token = invite.value.object.get("invite_token").?.string;

    const join_req = try std.fmt.allocPrint(
        allocator,
        "{{\"invite_token\":\"{s}\",\"node_name\":\"svc-node\",\"fs_url\":\"ws://127.0.0.1:18891/fs\"}}",
        .{invite_token},
    );
    defer allocator.free(join_req);
    const join_json = try plane.nodeJoin(join_req);
    defer allocator.free(join_json);
    var join = try std.json.parseFromSlice(std.json.Value, allocator, join_json, .{});
    defer join.deinit();
    const node_id = join.value.object.get("node_id").?.string;
    const node_secret = join.value.object.get("node_secret").?.string;

    const upsert_req = try std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"platform\":{{\"os\":\"linux\",\"arch\":\"amd64\",\"runtime_kind\":\"native\"}},\"labels\":{{\"site\":\"home-lab\",\"tier\":\"edge\"}},\"venoms\":[{{\"venom_id\":\"camera\",\"kind\":\"camera\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"/nodes/svc-node/camera\"],\"capabilities\":{{\"still\":true}}}},{{\"venom_id\":\"terminal\",\"kind\":\"terminal\",\"version\":\"1\",\"state\":\"degraded\",\"endpoints\":[\"/nodes/svc-node/terminal/1\"],\"capabilities\":{{\"pty\":true}}}}]}}",
        .{ node_id, node_secret },
    );
    defer allocator.free(upsert_req);
    const upserted = try plane.nodeVenomUpsert(upsert_req);
    defer allocator.free(upserted);
    try std.testing.expect(std.mem.indexOf(u8, upserted, "\"venom_id\":\"camera\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, upserted, "\"site\":\"home-lab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, upserted, "\"venom_delta\":{\"changed\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, upserted, "\"added\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, upserted, "\"updated\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, upserted, "\"removed\":[") != null);

    const get_req = try std.fmt.allocPrint(allocator, "{{\"node_id\":\"{s}\"}}", .{node_id});
    defer allocator.free(get_req);
    const fetched = try plane.nodeVenomGet(get_req);
    defer allocator.free(fetched);
    try std.testing.expect(std.mem.indexOf(u8, fetched, "\"runtime_kind\":\"native\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetched, "\"venom_id\":\"terminal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetched, "\"state\":\"degraded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetched, "\"venom_delta\"") == null);
}

test "acheron_control_plane: node venom upsert reports unchanged catalog delta" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const invite_json = try plane.createNodeInvite(null);
    defer allocator.free(invite_json);
    var invite = try std.json.parseFromSlice(std.json.Value, allocator, invite_json, .{});
    defer invite.deinit();
    const invite_token = invite.value.object.get("invite_token").?.string;

    const join_req = try std.fmt.allocPrint(
        allocator,
        "{{\"invite_token\":\"{s}\",\"node_name\":\"svc-node\",\"fs_url\":\"ws://127.0.0.1:18891/fs\"}}",
        .{invite_token},
    );
    defer allocator.free(join_req);
    const join_json = try plane.nodeJoin(join_req);
    defer allocator.free(join_json);
    var join = try std.json.parseFromSlice(std.json.Value, allocator, join_json, .{});
    defer join.deinit();
    const node_id = join.value.object.get("node_id").?.string;
    const node_secret = join.value.object.get("node_secret").?.string;

    const upsert_req = try std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"venoms\":[{{\"venom_id\":\"camera\",\"kind\":\"camera\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"/nodes/svc-node/camera\"],\"capabilities\":{{\"still\":true}}}}]}}",
        .{ node_id, node_secret },
    );
    defer allocator.free(upsert_req);

    const first = try plane.nodeVenomUpsert(upsert_req);
    defer allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"venom_delta\":{\"changed\":true") != null);

    const second = try plane.nodeVenomUpsert(upsert_req);
    defer allocator.free(second);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"venom_delta\":{\"changed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"added\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"updated\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"removed\":[]") != null);
}

test "acheron_control_plane: node venom delta changes when only package_id changes" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const installed_a = try plane.installVenomPackage(
        \\{"package":{"venom_id":"camera_pkg_a","kind":"camera","version":"1","categories":["camera"],"host_roles":["node"],"binding_scopes":["node"],"runtime_kind":"native","requirements":{},"capabilities":{"still":true},"ops":{"model":"namespace"},"runtime":{"type":"native_proc"},"permissions":{},"schema":{}}}
    );
    defer allocator.free(installed_a);
    const installed_b = try plane.installVenomPackage(
        \\{"package":{"venom_id":"camera_pkg_b","kind":"camera","version":"1","categories":["camera"],"host_roles":["node"],"binding_scopes":["node"],"runtime_kind":"native","requirements":{},"capabilities":{"still":true},"ops":{"model":"namespace"},"runtime":{"type":"native_proc"},"permissions":{},"schema":{}}}
    );
    defer allocator.free(installed_b);

    const ensured = try plane.ensureNode("delta-node", "ws://127.0.0.1:18891/fs", 60_000);
    defer allocator.free(ensured);
    var ensured_parsed = try std.json.parseFromSlice(std.json.Value, allocator, ensured, .{});
    defer ensured_parsed.deinit();
    const node_id = ensured_parsed.value.object.get("node_id").?.string;
    const node_secret = ensured_parsed.value.object.get("node_secret").?.string;

    const first_upsert = try std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"platform\":{{\"os\":\"linux\",\"arch\":\"amd64\",\"runtime_kind\":\"native\"}},\"venoms\":[{{\"venom_id\":\"camera-instance\",\"package_id\":\"camera_pkg_a\",\"kind\":\"camera\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"/nodes/{s}/camera\"],\"runtime\":{{\"type\":\"native_proc\"}}}}]}}",
        .{ node_id, node_secret, node_id },
    );
    defer allocator.free(first_upsert);
    const first = try plane.nodeVenomUpsert(first_upsert);
    defer allocator.free(first);

    const second_upsert = try std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"platform\":{{\"os\":\"linux\",\"arch\":\"amd64\",\"runtime_kind\":\"native\"}},\"venoms\":[{{\"venom_id\":\"camera-instance\",\"package_id\":\"camera_pkg_b\",\"kind\":\"camera\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"/nodes/{s}/camera\"],\"runtime\":{{\"type\":\"native_proc\"}}}}]}}",
        .{ node_id, node_secret, node_id },
    );
    defer allocator.free(second_upsert);
    const second = try plane.nodeVenomUpsert(second_upsert);
    defer allocator.free(second);

    try std.testing.expect(std.mem.indexOf(u8, second, "\"venom_delta\":{\"changed\":true") != null);
}

test "acheron_control_plane: node venom event retention honors configured history max" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.initWithOptions(allocator, .{
        .node_venom_event_history_max = 2,
    });
    defer plane.deinit();

    const ensured = try plane.ensureNode("retained-node", "ws://127.0.0.1:18891/fs", 60_000);
    defer allocator.free(ensured);
    var ensured_parsed = try std.json.parseFromSlice(std.json.Value, allocator, ensured, .{});
    defer ensured_parsed.deinit();
    const node_id = ensured_parsed.value.object.get("node_id").?.string;
    const node_secret = ensured_parsed.value.object.get("node_secret").?.string;

    inline for (0..3) |idx| {
        const upsert_req = try std.fmt.allocPrint(
            allocator,
            "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"venoms\":[{{\"venom_id\":\"terminal-main\",\"kind\":\"terminal\",\"version\":\"{d}\",\"state\":\"online\",\"endpoints\":[\"/nodes/{s}/terminal/main\"],\"capabilities\":{{\"pty\":true}}}}]}}",
            .{ node_id, node_secret, idx, node_id },
        );
        defer allocator.free(upsert_req);
        const upserted = try plane.nodeVenomUpsert(upsert_req);
        defer allocator.free(upserted);
    }

    const snapshot = try plane.snapshotNodeVenomEvents(allocator, null, null, null, true, 0);
    defer allocator.free(snapshot);

    const line_count: usize = if (snapshot.len == 0) 0 else std.mem.count(u8, snapshot, "\n") + 1;
    try std.testing.expectEqual(@as(usize, 2), line_count);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"version\":\"2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"version\":\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"version\":\"0\"") == null);
}

test "acheron_control_plane: preferred venom provider favors spiderweb-local by node name" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const local_joined = try plane.ensureNode("spiderweb-local", "ws://127.0.0.1:18891/fs", 60_000);
    defer allocator.free(local_joined);
    var local_parsed = try std.json.parseFromSlice(std.json.Value, allocator, local_joined, .{});
    defer local_parsed.deinit();
    const local_node_id = local_parsed.value.object.get("node_id").?.string;
    const local_node_secret = local_parsed.value.object.get("node_secret").?.string;

    const remote_joined = try plane.ensureNode("edge-remote", "ws://127.0.0.1:28891/fs", 60_000);
    defer allocator.free(remote_joined);
    var remote_parsed = try std.json.parseFromSlice(std.json.Value, allocator, remote_joined, .{});
    defer remote_parsed.deinit();
    const remote_node_id = remote_parsed.value.object.get("node_id").?.string;
    const remote_node_secret = remote_parsed.value.object.get("node_secret").?.string;

    const local_upsert_req = try std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"venoms\":[{{\"venom_id\":\"fs\",\"kind\":\"fs\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"/nodes/{s}/fs\"],\"capabilities\":{{\"rw\":true}},\"mounts\":[{{\"mount_id\":\"fs\",\"mount_path\":\"/nodes/{s}/fs\",\"state\":\"online\"}}],\"ops\":{{\"model\":\"namespace\"}},\"runtime\":{{\"type\":\"builtin\",\"abi\":\"venom-driver-v1\"}},\"permissions\":{{\"default\":\"deny-by-default\",\"allow_roles\":[\"admin\",\"user\"]}},\"schema\":{{\"model\":\"namespace-mount\"}}}}]}}",
        .{ local_node_id, local_node_secret, local_node_id, local_node_id },
    );
    defer allocator.free(local_upsert_req);
    const local_upserted = try plane.nodeVenomUpsert(local_upsert_req);
    defer allocator.free(local_upserted);

    const remote_upsert_req = try std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"venoms\":[{{\"venom_id\":\"fs\",\"kind\":\"fs\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"/nodes/{s}/fs\"],\"capabilities\":{{\"rw\":true}},\"mounts\":[{{\"mount_id\":\"fs\",\"mount_path\":\"/nodes/{s}/fs\",\"state\":\"online\"}}],\"ops\":{{\"model\":\"namespace\"}},\"runtime\":{{\"type\":\"builtin\",\"abi\":\"venom-driver-v1\"}},\"permissions\":{{\"default\":\"deny-by-default\",\"allow_roles\":[\"admin\",\"user\"]}},\"schema\":{{\"model\":\"namespace-mount\"}}}}]}}",
        .{ remote_node_id, remote_node_secret, remote_node_id, remote_node_id },
    );
    defer allocator.free(remote_upsert_req);
    const remote_upserted = try plane.nodeVenomUpsert(remote_upsert_req);
    defer allocator.free(remote_upserted);

    var provider = (try plane.resolvePreferredVenomProvider(allocator, "fs", &.{ "spiderweb-local", "local" })) orelse return error.TestExpectedResponse;
    defer provider.deinit(allocator);
    const expected_endpoint = try std.fmt.allocPrint(allocator, "/nodes/{s}/fs", .{local_node_id});
    defer allocator.free(expected_endpoint);

    try std.testing.expectEqualStrings(local_node_id, provider.node_id);
    try std.testing.expectEqualStrings("spiderweb-local", provider.node_name);
    try std.testing.expectEqualStrings("fs", provider.venom_id);
    try std.testing.expectEqualStrings(expected_endpoint, provider.endpoint_path);
}

test "acheron_control_plane: explicit venom bind overrides heuristic provider selection" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const local_joined = try plane.ensureNode("spiderweb-local", "ws://127.0.0.1:18891/fs", 60_000);
    defer allocator.free(local_joined);
    var local_parsed = try std.json.parseFromSlice(std.json.Value, allocator, local_joined, .{});
    defer local_parsed.deinit();
    const local_node_id = local_parsed.value.object.get("node_id").?.string;
    const local_node_secret = local_parsed.value.object.get("node_secret").?.string;

    const app_joined = try plane.ensureNode("spiderapp-default", "", 60_000);
    defer allocator.free(app_joined);
    var app_parsed = try std.json.parseFromSlice(std.json.Value, allocator, app_joined, .{});
    defer app_parsed.deinit();
    const app_node_id = app_parsed.value.object.get("node_id").?.string;
    const app_node_secret = app_parsed.value.object.get("node_secret").?.string;

    const local_upsert_req = try std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"venoms\":[{{\"venom_id\":\"terminal\",\"kind\":\"terminal\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"/nodes/{s}/terminal\"],\"capabilities\":{{\"invoke\":true}},\"mounts\":[{{\"mount_id\":\"terminal\",\"mount_path\":\"/nodes/{s}/terminal\",\"state\":\"online\"}}],\"ops\":{{\"model\":\"namespace\",\"invoke\":\"control/invoke.json\"}},\"runtime\":{{\"type\":\"builtin\",\"abi\":\"venom-driver-v1\"}},\"permissions\":{{\"default\":\"deny-by-default\",\"allow_roles\":[\"admin\",\"user\"]}},\"schema\":{{\"model\":\"namespace-terminal\"}}}}]}}",
        .{ local_node_id, local_node_secret, local_node_id, local_node_id },
    );
    defer allocator.free(local_upsert_req);
    _ = try plane.nodeVenomUpsert(local_upsert_req);

    const app_upsert_req = try std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"venoms\":[{{\"venom_id\":\"terminal\",\"kind\":\"terminal\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"/nodes/{s}/terminal\"],\"capabilities\":{{\"invoke\":true}},\"mounts\":[{{\"mount_id\":\"terminal\",\"mount_path\":\"/nodes/{s}/terminal\",\"state\":\"online\"}}],\"ops\":{{\"model\":\"namespace\",\"invoke\":\"control/invoke.json\"}},\"runtime\":{{\"type\":\"builtin\",\"abi\":\"venom-driver-v1\"}},\"permissions\":{{\"default\":\"deny-by-default\",\"allow_roles\":[\"admin\",\"user\"]}},\"schema\":{{\"model\":\"namespace-terminal\"}}}}]}}",
        .{ app_node_id, app_node_secret, app_node_id, app_node_id },
    );
    defer allocator.free(app_upsert_req);
    _ = try plane.nodeVenomUpsert(app_upsert_req);

    const bind_req = try std.fmt.allocPrint(allocator, "{{\"venom_id\":\"terminal\",\"node_id\":\"{s}\"}}", .{app_node_id});
    defer allocator.free(bind_req);
    const bind_json = try plane.bindPreferredVenomProvider(bind_req);
    defer allocator.free(bind_json);
    try std.testing.expect(std.mem.indexOf(u8, bind_json, app_node_id) != null);

    var provider = (try plane.resolvePreferredVenomProvider(allocator, "terminal", &.{ "spiderweb-local", "local" })) orelse return error.TestExpectedResponse;
    defer provider.deinit(allocator);
    try std.testing.expectEqualStrings(app_node_id, provider.node_id);
    try std.testing.expectEqualStrings("spiderapp-default", provider.node_name);
}

test "acheron_control_plane: scoped venom binds resolve agent before project before global" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const local_joined = try plane.ensureNode("spiderweb-local", "ws://127.0.0.1:18891/fs", 60_000);
    defer allocator.free(local_joined);
    var local_parsed = try std.json.parseFromSlice(std.json.Value, allocator, local_joined, .{});
    defer local_parsed.deinit();
    const local_node_id = local_parsed.value.object.get("node_id").?.string;
    const local_node_secret = local_parsed.value.object.get("node_secret").?.string;

    const app_joined = try plane.ensureNode("spiderapp-default", "", 60_000);
    defer allocator.free(app_joined);
    var app_parsed = try std.json.parseFromSlice(std.json.Value, allocator, app_joined, .{});
    defer app_parsed.deinit();
    const app_node_id = app_parsed.value.object.get("node_id").?.string;
    const app_node_secret = app_parsed.value.object.get("node_secret").?.string;

    const local_upsert_req = try std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"venoms\":[{{\"venom_id\":\"terminal\",\"kind\":\"terminal\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"/nodes/{s}/terminal\"],\"capabilities\":{{\"invoke\":true}},\"mounts\":[{{\"mount_id\":\"terminal\",\"mount_path\":\"/nodes/{s}/terminal\",\"state\":\"online\"}}],\"ops\":{{\"model\":\"namespace\",\"invoke\":\"control/invoke.json\"}},\"runtime\":{{\"type\":\"builtin\",\"abi\":\"venom-driver-v1\"}},\"permissions\":{{\"default\":\"deny-by-default\",\"allow_roles\":[\"admin\",\"user\"]}},\"schema\":{{\"model\":\"namespace-terminal\"}}}}]}}",
        .{ local_node_id, local_node_secret, local_node_id, local_node_id },
    );
    defer allocator.free(local_upsert_req);
    _ = try plane.nodeVenomUpsert(local_upsert_req);

    const app_upsert_req = try std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"venoms\":[{{\"venom_id\":\"terminal\",\"kind\":\"terminal\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"/nodes/{s}/terminal\"],\"capabilities\":{{\"invoke\":true}},\"mounts\":[{{\"mount_id\":\"terminal\",\"mount_path\":\"/nodes/{s}/terminal\",\"state\":\"online\"}}],\"ops\":{{\"model\":\"namespace\",\"invoke\":\"control/invoke.json\"}},\"runtime\":{{\"type\":\"builtin\",\"abi\":\"venom-driver-v1\"}},\"permissions\":{{\"default\":\"deny-by-default\",\"allow_roles\":[\"admin\",\"user\"]}},\"schema\":{{\"model\":\"namespace-terminal\"}}}}]}}",
        .{ app_node_id, app_node_secret, app_node_id, app_node_id },
    );
    defer allocator.free(app_upsert_req);
    _ = try plane.nodeVenomUpsert(app_upsert_req);

    const bind_global = try std.fmt.allocPrint(allocator, "{{\"venom_id\":\"terminal\",\"scope\":\"global\",\"node_id\":\"{s}\"}}", .{local_node_id});
    defer allocator.free(bind_global);
    _ = try plane.bindPreferredVenomProvider(bind_global);

    const bind_project = try std.fmt.allocPrint(allocator, "{{\"venom_id\":\"terminal\",\"scope\":\"project\",\"workspace_id\":\"{s}\",\"node_id\":\"{s}\"}}", .{ host_workspace_id, app_node_id });
    defer allocator.free(bind_project);
    _ = try plane.bindPreferredVenomProvider(bind_project);

    const bind_agent = try std.fmt.allocPrint(allocator, "{{\"venom_id\":\"terminal\",\"scope\":\"agent\",\"agent_id\":\"alice\",\"node_id\":\"{s}\"}}", .{local_node_id});
    defer allocator.free(bind_agent);
    _ = try plane.bindPreferredVenomProvider(bind_agent);

    var project_provider = (try plane.resolvePreferredVenomProviderForContext(
        allocator,
        "terminal",
        &.{ "spiderweb-local", "local" },
        host_workspace_id,
        null,
    )) orelse return error.TestExpectedResponse;
    defer project_provider.deinit(allocator);
    try std.testing.expectEqualStrings(app_node_id, project_provider.node_id);

    var agent_provider = (try plane.resolvePreferredVenomProviderForContext(
        allocator,
        "terminal",
        &.{ "spiderweb-local", "local" },
        host_workspace_id,
        "alice",
    )) orelse return error.TestExpectedResponse;
    defer agent_provider.deinit(allocator);
    try std.testing.expectEqualStrings(local_node_id, agent_provider.node_id);
}

test "acheron_control_plane: node ensure allows empty fs_url for app-local nodes" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const ensured = try plane.nodeEnsure("{\"node_name\":\"spiderapp-default\"}");
    defer allocator.free(ensured);

    try std.testing.expect(std.mem.indexOf(u8, ensured, "\"node_id\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ensured, "\"node_secret\":\"") != null);
}

test "acheron_control_plane: workspaceUp requires workspace_token for existing non-builtin project" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const project_json = try plane.createWorkspace("{\"name\":\"UpAuth\",\"vision\":\"UpAuth\"}");
    defer allocator.free(project_json);
    var project = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer project.deinit();
    const workspace_id = project.value.object.get("workspace_id").?.string;
    const workspace_token = project.value.object.get("workspace_token").?.string;

    const missing_token_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"status\":\"paused\"}}",
        .{workspace_id},
    );
    defer allocator.free(missing_token_req);
    try std.testing.expectError(ControlPlaneError.MissingField, plane.workspaceUp("agent-up", missing_token_req));

    const bad_token_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"bad-token\",\"status\":\"paused\"}}",
        .{workspace_id},
    );
    defer allocator.free(bad_token_req);
    try std.testing.expectError(ControlPlaneError.WorkspaceAuthFailed, plane.workspaceUp("agent-up", bad_token_req));

    const missing_token_primary_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"status\":\"paused\"}}",
        .{workspace_id},
    );
    defer allocator.free(missing_token_primary_req);
    try std.testing.expectError(ControlPlaneError.MissingField, plane.workspaceUp("default", missing_token_primary_req));

    const bad_token_primary_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"bad-token\",\"status\":\"paused\"}}",
        .{workspace_id},
    );
    defer allocator.free(bad_token_primary_req);
    try std.testing.expectError(ControlPlaneError.WorkspaceAuthFailed, plane.workspaceUp("default", bad_token_primary_req));

    const ok_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"status\":\"paused\",\"activate\":false}}",
        .{ workspace_id, workspace_token },
    );
    defer allocator.free(ok_req);
    const ok_json = try plane.workspaceUp("agent-up", ok_req);
    defer allocator.free(ok_json);
    try std.testing.expect(std.mem.indexOf(u8, ok_json, "\"created\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, ok_json, "\"activated\":false") != null);

    const get_req = try std.fmt.allocPrint(allocator, "{{\"workspace_id\":\"{s}\"}}", .{workspace_id});
    defer allocator.free(get_req);
    const get_json = try plane.getWorkspace(get_req);
    defer allocator.free(get_json);
    try std.testing.expect(std.mem.indexOf(u8, get_json, "\"status\":\"paused\"") != null);
}

test "acheron_control_plane: workspaceUp requires workspace_token for builtin host project activation" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const state_json = try plane.dumpState();
    defer allocator.free(state_json);
    var parsed_state = try std.json.parseFromSlice(std.json.Value, allocator, state_json, .{});
    defer parsed_state.deinit();
    const workspaces_val = parsed_state.value.object.get("workspaces").?;
    try std.testing.expect(workspaces_val == .array);

    var spider_token: ?[]const u8 = null;
    for (workspaces_val.array.items) |item| {
        if (item != .object) continue;
        const id_val = item.object.get("id") orelse continue;
        if (id_val != .string) continue;
        if (!std.mem.eql(u8, id_val.string, host_workspace_id)) continue;
        const token_val = item.object.get("mutation_token") orelse continue;
        if (token_val == .string) {
            spider_token = token_val.string;
            break;
        }
    }
    try std.testing.expect(spider_token != null);

    const missing_token_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\"}}",
        .{host_workspace_id},
    );
    defer allocator.free(missing_token_req);
    try std.testing.expectError(ControlPlaneError.MissingField, plane.workspaceUp(default_host_actor_id, missing_token_req));

    const bad_token_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"bad-token\"}}",
        .{host_workspace_id},
    );
    defer allocator.free(bad_token_req);
    try std.testing.expectError(ControlPlaneError.WorkspaceAuthFailed, plane.workspaceUp(default_host_actor_id, bad_token_req));

    const ok_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\"}}",
        .{ host_workspace_id, spider_token.? },
    );
    defer allocator.free(ok_req);
    const ok_json = try plane.workspaceUp(default_host_actor_id, ok_req);
    defer allocator.free(ok_json);
    try std.testing.expect(std.mem.indexOf(u8, ok_json, "\"created\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, ok_json, "\"activated\":true") != null);
}

test "acheron_control_plane: host actor can upsert existing non-host project by name without token" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const project_json = try plane.createWorkspace("{\"name\":\"ZiggyPR\",\"vision\":\"Initial\"}");
    defer allocator.free(project_json);

    const upsert_json = try plane.workspaceUp(
        default_host_actor_id,
        "{\"name\":\"ZiggyPR\",\"vision\":\"Help review PRs\",\"activate\":false}",
    );
    defer allocator.free(upsert_json);
    try std.testing.expect(std.mem.indexOf(u8, upsert_json, "\"created\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, upsert_json, "\"activated\":false") != null);

    var parsed_project = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer parsed_project.deinit();
    const workspace_id = parsed_project.value.object.get("workspace_id").?.string;
    const get_req = try std.fmt.allocPrint(allocator, "{{\"workspace_id\":\"{s}\"}}", .{workspace_id});
    defer allocator.free(get_req);
    const get_json = try plane.getWorkspace(get_req);
    defer allocator.free(get_json);
    try std.testing.expect(std.mem.indexOf(u8, get_json, "\"vision\":\"Help review PRs\"") != null);
}

test "acheron_control_plane: primary agent bypasses project invoke token gates" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    try std.testing.expect(!plane.workspaceAllowsAction(host_workspace_id, "worker", .invoke, null, false));
    try std.testing.expect(plane.workspaceAllowsAction(host_workspace_id, default_host_actor_id, .invoke, null, false));

    const created = try plane.createWorkspace("{\"name\":\"InvokeGate\",\"vision\":\"InvokeGate\"}");
    defer allocator.free(created);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, created, .{});
    defer parsed.deinit();
    const workspace_id = parsed.value.object.get("workspace_id").?.string;
    const workspace_token = parsed.value.object.get("workspace_token").?.string;

    try std.testing.expect(!plane.workspaceAllowsAction(workspace_id, "worker", .invoke, null, false));
    try std.testing.expect(plane.workspaceAllowsAction(workspace_id, "worker", .invoke, workspace_token, false));
    try std.testing.expect(plane.workspaceAllowsAction(workspace_id, default_host_actor_id, .invoke, null, false));
}

test "acheron_control_plane: project create/up require non-empty vision" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const created = try plane.createWorkspace("{\"name\":\"Visionless\",\"vision\":\"Visionless\"}");
    defer allocator.free(created);
    try std.testing.expect(std.mem.indexOf(u8, created, "\"vision\":\"Visionless\"") != null);

    var parsed_created = try std.json.parseFromSlice(std.json.Value, allocator, created, .{});
    defer parsed_created.deinit();
    const workspace_id = parsed_created.value.object.get("workspace_id").?.string;
    const workspace_token = parsed_created.value.object.get("workspace_token").?.string;

    try std.testing.expectError(
        ControlPlaneError.MissingField,
        plane.createWorkspace("{\"name\":\"MissingVision\"}"),
    );

    const clear_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"vision\":\"\"}}",
        .{ workspace_id, workspace_token },
    );
    defer allocator.free(clear_req);
    try std.testing.expectError(ControlPlaneError.InvalidPayload, plane.workspaceUp("agent-vision", clear_req));

    const get_req = try std.fmt.allocPrint(allocator, "{{\"workspace_id\":\"{s}\"}}", .{workspace_id});
    defer allocator.free(get_req);
    const fetched = try plane.getWorkspace(get_req);
    defer allocator.free(fetched);
    try std.testing.expect(std.mem.indexOf(u8, fetched, "\"vision\":\"Visionless\"") != null);

    const up_created = try plane.workspaceUp("agent-vision", "{\"name\":\"UpNoVision\",\"vision\":\"UpNoVision\"}");
    defer allocator.free(up_created);
    try std.testing.expect(std.mem.indexOf(u8, up_created, "\"created\":true") != null);

    try std.testing.expectError(
        ControlPlaneError.MissingField,
        plane.workspaceUp("agent-vision", "{\"name\":\"StillNoVision\"}"),
    );
}

test "acheron_control_plane: workspaceUp auto-provisions default /nodes/local/fs mount for new projects" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const node_json = try plane.ensureNode("bootstrap-node", "ws://127.0.0.1:18891/fs", 60_000);
    defer allocator.free(node_json);
    var parsed_node = try std.json.parseFromSlice(std.json.Value, allocator, node_json, .{});
    defer parsed_node.deinit();
    const node_id = parsed_node.value.object.get("node_id").?.string;

    try plane.ensureSpiderWebMount(node_id, "bootstrap-workspace");

    const up_json = try plane.workspaceUp(
        default_host_actor_id,
        "{\"name\":\"BootstrapProject\",\"vision\":\"BootstrapProject\",\"activate\":false}",
    );
    defer allocator.free(up_json);
    var parsed_up = try std.json.parseFromSlice(std.json.Value, allocator, up_json, .{});
    defer parsed_up.deinit();
    const workspace_id = parsed_up.value.object.get("workspace_id").?.string;

    const get_req = try std.fmt.allocPrint(allocator, "{{\"workspace_id\":\"{s}\"}}", .{workspace_id});
    defer allocator.free(get_req);
    const get_json = try plane.getWorkspace(get_req);
    defer allocator.free(get_json);

    try std.testing.expect(std.mem.indexOf(u8, get_json, "\"mount_path\":\"/nodes/local/fs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_json, "\"node_id\":\"node-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_json, "\"export_name\":\"bootstrap-workspace\"") != null);
}

test "acheron_control_plane: default mount migration replaces legacy /workspace-only mounts" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const node_json = try plane.ensureNode("bootstrap-node", "ws://127.0.0.1:18891/fs", 60_000);
    defer allocator.free(node_json);
    var parsed_node = try std.json.parseFromSlice(std.json.Value, allocator, node_json, .{});
    defer parsed_node.deinit();
    const node_id = parsed_node.value.object.get("node_id").?.string;

    const up_json = try plane.workspaceUp(
        default_host_actor_id,
        "{\"name\":\"LegacyMountProject\",\"vision\":\"LegacyMountProject\",\"activate\":false}",
    );
    defer allocator.free(up_json);
    var parsed_up = try std.json.parseFromSlice(std.json.Value, allocator, up_json, .{});
    defer parsed_up.deinit();
    const workspace_id = parsed_up.value.object.get("workspace_id").?.string;

    const project = plane.workspaces.getPtr(workspace_id).?;
    for (project.mounts.items) |*mount| mount.deinit(allocator);
    project.mounts.clearRetainingCapacity();
    try project.mounts.append(allocator, .{
        .mount_path = try allocator.dupe(u8, "/workspace"),
        .node_id = try allocator.dupe(u8, node_id),
        .export_name = try allocator.dupe(u8, "legacy-workspace"),
    });

    try std.testing.expect(try ensureDefaultWorkspaceMountsLocked(&plane, project));
    try std.testing.expectEqual(@as(usize, 1), project.mounts.items.len);
    try std.testing.expectEqualStrings("/nodes/local/fs", project.mounts.items[0].mount_path);
    try std.testing.expectEqualStrings(node_id, project.mounts.items[0].node_id);
    try std.testing.expectEqualStrings(default_host_project_export_name, project.mounts.items[0].export_name);
}

test "acheron_control_plane: builtin ensure prunes legacy workspace alias when canonical mount exists" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const now_ms = std.time.milliTimestamp();
    try plane.ensureBuiltinHostProjectLocked(now_ms);
    const project = plane.workspaces.getPtr(host_workspace_id).?;

    try project.mounts.append(allocator, .{
        .mount_path = try allocator.dupe(u8, "/workspace"),
        .node_id = try allocator.dupe(u8, "node-legacy"),
        .export_name = try allocator.dupe(u8, "legacy"),
    });
    try project.mounts.append(allocator, .{
        .mount_path = try allocator.dupe(u8, "/nodes/local/fs"),
        .node_id = try allocator.dupe(u8, "node-canonical"),
        .export_name = try allocator.dupe(u8, "work"),
    });

    try plane.ensureBuiltinHostProjectLocked(now_ms + 1);
    try std.testing.expectEqual(@as(usize, 1), project.mounts.items.len);
    try std.testing.expectEqualStrings("/nodes/local/fs", project.mounts.items[0].mount_path);
    try std.testing.expectEqualStrings("node-canonical", project.mounts.items[0].node_id);
}

fn seedManagedWorkspaceTemplateProviders(
    allocator: std.mem.Allocator,
    plane: *ControlPlane,
) ![]u8 {
    const joined = try plane.ensureNode("spiderweb-fs-node", "", 60_000);
    defer allocator.free(joined);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, joined, .{});
    defer parsed.deinit();
    const node_id = parsed.value.object.get("node_id").?.string;
    const node_secret = parsed.value.object.get("node_secret").?.string;

    const upsert_req = try std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"platform\":{{\"os\":\"linux\",\"arch\":\"amd64\",\"runtime_kind\":\"spiderweb\"}},\"labels\":{{\"{s}\":\"spiderweb_managed\"}},\"venoms\":[" ++
            "{{\"venom_id\":\"mounts\",\"package_id\":\"mounts\",\"kind\":\"mounts\",\"version\":\"1\",\"state\":\"online\",\"host_roles\":[\"spiderweb\"],\"binding_scopes\":[\"workspace\"],\"runtime_kind\":\"native\",\"requirements\":{{}},\"endpoints\":[\"/nodes/{s}/venoms/mounts\"],\"mounts\":[{{\"mount_id\":\"mounts\",\"mount_path\":\"/nodes/{s}/venoms/mounts\",\"state\":\"online\"}}],\"capabilities\":{{\"invoke\":true}},\"ops\":{{\"model\":\"namespace\",\"invoke\":\"control/invoke.json\"}},\"runtime\":{{\"type\":\"native_proc\",\"abi\":\"namespace-driver-v1\"}},\"permissions\":{{\"default\":\"deny-by-default\"}},\"schema\":{{\"model\":\"namespace-mount\"}}}}," ++
            "{{\"venom_id\":\"home\",\"package_id\":\"home\",\"kind\":\"home\",\"version\":\"1\",\"state\":\"online\",\"host_roles\":[\"spiderweb\"],\"binding_scopes\":[\"workspace\"],\"runtime_kind\":\"native\",\"requirements\":{{}},\"endpoints\":[\"/nodes/{s}/venoms/home\"],\"mounts\":[{{\"mount_id\":\"home\",\"mount_path\":\"/nodes/{s}/venoms/home\",\"state\":\"online\"}}],\"capabilities\":{{\"invoke\":true}},\"ops\":{{\"model\":\"namespace\",\"invoke\":\"control/invoke.json\"}},\"runtime\":{{\"type\":\"native_proc\",\"abi\":\"namespace-driver-v1\"}},\"permissions\":{{\"default\":\"deny-by-default\"}},\"schema\":{{\"model\":\"namespace-mount\"}}}}," ++
            "{{\"venom_id\":\"packages\",\"package_id\":\"packages\",\"kind\":\"registry\",\"version\":\"1\",\"state\":\"online\",\"host_roles\":[\"spiderweb\"],\"binding_scopes\":[\"workspace\"],\"runtime_kind\":\"native\",\"requirements\":{{}},\"endpoints\":[\"/nodes/{s}/venoms/packages\"],\"mounts\":[{{\"mount_id\":\"packages\",\"mount_path\":\"/nodes/{s}/venoms/packages\",\"state\":\"online\"}}],\"capabilities\":{{\"invoke\":true}},\"ops\":{{\"model\":\"namespace\",\"invoke\":\"control/invoke.json\"}},\"runtime\":{{\"type\":\"native_proc\",\"abi\":\"namespace-driver-v1\"}},\"permissions\":{{\"default\":\"deny-by-default\"}},\"schema\":{{\"model\":\"namespace-mount\"}}}}," ++
            "{{\"venom_id\":\"runtimes\",\"package_id\":\"runtimes\",\"kind\":\"runtimes\",\"version\":\"1\",\"state\":\"online\",\"host_roles\":[\"spiderweb\"],\"binding_scopes\":[\"workspace\"],\"runtime_kind\":\"native\",\"requirements\":{{}},\"endpoints\":[\"/nodes/{s}/venoms/runtimes\"],\"mounts\":[{{\"mount_id\":\"runtimes\",\"mount_path\":\"/nodes/{s}/venoms/runtimes\",\"state\":\"online\"}}],\"capabilities\":{{\"invoke\":true}},\"ops\":{{\"model\":\"namespace\",\"invoke\":\"control/invoke.json\"}},\"runtime\":{{\"type\":\"native_proc\",\"abi\":\"namespace-driver-v1\"}},\"permissions\":{{\"default\":\"deny-by-default\"}},\"schema\":{{\"model\":\"namespace-mount\"}}}}," ++
            "{{\"venom_id\":\"terminal\",\"package_id\":\"terminal\",\"kind\":\"terminal\",\"version\":\"1\",\"state\":\"online\",\"host_roles\":[\"node\"],\"binding_scopes\":[\"workspace\"],\"runtime_kind\":\"native\",\"requirements\":{{}},\"endpoints\":[\"/nodes/{s}/venoms/terminal\"],\"mounts\":[{{\"mount_id\":\"terminal\",\"mount_path\":\"/nodes/{s}/venoms/terminal\",\"state\":\"online\"}}],\"capabilities\":{{\"invoke\":true}},\"ops\":{{\"model\":\"namespace\",\"invoke\":\"control/invoke.json\"}},\"runtime\":{{\"type\":\"native_proc\",\"abi\":\"namespace-driver-v1\"}},\"permissions\":{{\"default\":\"deny-by-default\"}},\"schema\":{{\"model\":\"namespace-mount\"}}}}," ++
            "{{\"venom_id\":\"git\",\"package_id\":\"git\",\"kind\":\"git\",\"version\":\"1\",\"state\":\"online\",\"host_roles\":[\"node\"],\"binding_scopes\":[\"workspace\"],\"runtime_kind\":\"native\",\"requirements\":{{}},\"endpoints\":[\"/nodes/{s}/venoms/git\"],\"mounts\":[{{\"mount_id\":\"git\",\"mount_path\":\"/nodes/{s}/venoms/git\",\"state\":\"online\"}}],\"capabilities\":{{\"invoke\":true}},\"ops\":{{\"model\":\"namespace\",\"invoke\":\"control/invoke.json\"}},\"runtime\":{{\"type\":\"native_proc\",\"abi\":\"namespace-driver-v1\"}},\"permissions\":{{\"default\":\"deny-by-default\"}},\"schema\":{{\"model\":\"namespace-mount\"}}}}," ++
            "{{\"venom_id\":\"search_code\",\"package_id\":\"search_code\",\"kind\":\"search_code\",\"version\":\"1\",\"state\":\"online\",\"host_roles\":[\"node\"],\"binding_scopes\":[\"workspace\"],\"runtime_kind\":\"native\",\"requirements\":{{}},\"endpoints\":[\"/nodes/{s}/venoms/search_code\"],\"mounts\":[{{\"mount_id\":\"search_code\",\"mount_path\":\"/nodes/{s}/venoms/search_code\",\"state\":\"online\"}}],\"capabilities\":{{\"invoke\":true}},\"ops\":{{\"model\":\"namespace\",\"invoke\":\"control/invoke.json\"}},\"runtime\":{{\"type\":\"native_proc\",\"abi\":\"namespace-driver-v1\"}},\"permissions\":{{\"default\":\"deny-by-default\"}},\"schema\":{{\"model\":\"namespace-mount\"}}}}" ++
            "]}}",
        .{
            node_id,
            node_secret,
            venom_model.host_type_label_key,
            node_id,
            node_id,
            node_id,
            node_id,
            node_id,
            node_id,
            node_id,
            node_id,
            node_id,
            node_id,
            node_id,
            node_id,
        },
    );
    defer allocator.free(upsert_req);
    const upserted = try plane.nodeVenomUpsert(upsert_req);
    defer allocator.free(upserted);
    return try allocator.dupe(u8, node_id);
}

test "acheron_control_plane: createWorkspace defaults to minimum template and seeds canonical control and venom binds" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const provider_node_id = try seedManagedWorkspaceTemplateProviders(allocator, &plane);
    defer allocator.free(provider_node_id);
    const project_json = try plane.createWorkspace("{\"name\":\"TemplateMinimum\",\"vision\":\"TemplateMinimum\"}");
    defer allocator.free(project_json);
    try std.testing.expect(std.mem.indexOf(u8, project_json, "\"template_id\":\"minimum\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_json, "\"bind_path\":\"/.spiderweb/control/workspace/mounts\"") != null);
    const mounts_target = try std.fmt.allocPrint(allocator, "\"target_path\":\"/nodes/{s}/venoms/mounts\"", .{provider_node_id});
    defer allocator.free(mounts_target);
    try std.testing.expect(std.mem.indexOf(u8, project_json, mounts_target) != null);
    try std.testing.expect(std.mem.indexOf(u8, project_json, "\"bind_path\":\"/.spiderweb/control/packages\"") != null);
    const packages_target = try std.fmt.allocPrint(allocator, "\"target_path\":\"/nodes/{s}/venoms/packages\"", .{provider_node_id});
    defer allocator.free(packages_target);
    try std.testing.expect(std.mem.indexOf(u8, project_json, packages_target) != null);
    try std.testing.expect(std.mem.indexOf(u8, project_json, "\"bind_path\":\"/services/chat\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, project_json, "\"bind_path\":\"/.spiderweb/venoms/chat\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, project_json, "\"bind_path\":\"/services/jobs\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, project_json, "\"bind_path\":\"/.spiderweb/venoms/web_search\"") == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
    defer parsed.deinit();
    const workspace_id = parsed.value.object.get("workspace_id").?.string;
    const workspace_token = parsed.value.object.get("workspace_token").?.string;

    const resolve_req = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"path\":\"/.spiderweb/control/workspace/mounts/control/invoke.json\"}}",
        .{ workspace_id, workspace_token },
    );
    defer allocator.free(resolve_req);
    const resolved = try plane.resolveWorkspacePath(resolve_req);
    defer allocator.free(resolved);
    try std.testing.expect(std.mem.indexOf(u8, resolved, "\"matched\":true") != null);
    const resolved_target = try std.fmt.allocPrint(allocator, "\"resolved_path\":\"/nodes/{s}/venoms/mounts/control/invoke.json\"", .{provider_node_id});
    defer allocator.free(resolved_target);
    try std.testing.expect(std.mem.indexOf(u8, resolved, resolved_target) != null);
}

test "acheron_control_plane: workspace template catalog lists dev template and returns bind metadata" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const listed = try plane.listWorkspaceTemplates();
    defer allocator.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"template_id\":\"minimum\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"template_id\":\"dev\"") != null);

    const fetched = try plane.getWorkspaceTemplate("{\"template_id\":\"dev\"}");
    defer allocator.free(fetched);
    try std.testing.expect(std.mem.indexOf(u8, fetched, "\"template_id\":\"dev\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetched, "\"bind_path\":\"/.spiderweb/control/packages\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetched, "\"bind_path\":\"/.spiderweb/venoms/git\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetched, "\"bind_path\":\"/.spiderweb/venoms/terminal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetched, "\"bind_path\":\"/.spiderweb/venoms/search_code\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetched, "\"target_path\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetched, "\"provider_scope\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, fetched, "\"bind_path\":\"/services/chat\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, fetched, "\"bind_path\":\"/services/jobs\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, fetched, "\"bind_path\":\"/services/web_search\"") == null);

    try std.testing.expectError(ControlPlaneError.TemplateNotFound, plane.getWorkspaceTemplate("{\"template_id\":\"unknown\"}"));
}

test "acheron_control_plane: builtin host project seeds mounts control bind" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const provider_node_id = try seedManagedWorkspaceTemplateProviders(allocator, &plane);
    defer allocator.free(provider_node_id);
    try plane.ensureBuiltinHostProjectLocked(std.time.milliTimestamp());
    const project = plane.workspaces.get(host_workspace_id) orelse return error.TestExpectedResponse;
    try std.testing.expectEqual(@as(usize, 0), project.template_id.len);

    const payload = try renderWorkspacePayload(allocator, project, false);
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"bind_path\":\"/.spiderweb/control/workspace/mounts\"") != null);
    const mounts_target = try std.fmt.allocPrint(allocator, "\"target_path\":\"/nodes/{s}/venoms/mounts\"", .{provider_node_id});
    defer allocator.free(mounts_target);
    try std.testing.expect(std.mem.indexOf(u8, payload, mounts_target) != null);
}

test "acheron_control_plane: dev template seeds canonical development binds" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const provider_node_id = try seedManagedWorkspaceTemplateProviders(allocator, &plane);
    defer allocator.free(provider_node_id);
    const project_json = try plane.createWorkspace("{\"name\":\"TemplateDev\",\"vision\":\"TemplateDev\",\"template_id\":\"dev\"}");
    defer allocator.free(project_json);
    try std.testing.expect(std.mem.indexOf(u8, project_json, "\"template_id\":\"dev\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_json, "\"bind_path\":\"/.spiderweb/control/workspace/mounts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_json, "\"bind_path\":\"/.spiderweb/control/workspace/home\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_json, "\"bind_path\":\"/.spiderweb/control/packages\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_json, "\"bind_path\":\"/.spiderweb/control/runtimes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_json, "\"bind_path\":\"/.spiderweb/venoms/git\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_json, "\"bind_path\":\"/.spiderweb/venoms/terminal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_json, "\"bind_path\":\"/.spiderweb/venoms/search_code\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_json, "\"bind_path\":\"/.spiderweb/venoms/computer\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, project_json, "\"bind_path\":\"/.spiderweb/venoms/browser\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, project_json, "\"bind_path\":\"/.spiderweb/venoms/events\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, project_json, "\"bind_path\":\"/.spiderweb/venoms/library\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, project_json, "\"bind_path\":\"/services/chat\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, project_json, "\"bind_path\":\"/services/jobs\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, project_json, "\"bind_path\":\"/services/web_search\"") == null);
}

test "acheron_control_plane: snapshot encryption envelope roundtrip" {
    const allocator = std.testing.allocator;
    const sample = "{\"schema\":1,\"hello\":\"world\"}";
    const key = [_]u8{0x5A} ** persistence_cipher.key_length;
    const encrypted = try encryptSnapshotJson(allocator, sample, key);
    defer allocator.free(encrypted);
    try std.testing.expect(isEncryptedSnapshotEnvelope(encrypted));

    const decrypted = try decryptSnapshotJson(allocator, encrypted, key);
    defer allocator.free(decrypted);
    try std.testing.expectEqualStrings(sample, decrypted);
}

test "acheron_control_plane: persistence restores nodes projects mounts and active workspace" {
    const allocator = std.testing.allocator;
    const dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/fs-control-plane-{d}", .{std.time.nanoTimestamp()});
    defer allocator.free(dir);
    defer std.fs.cwd().deleteTree(dir) catch {};

    try std.fs.cwd().makePath(dir);

    var expected_node_id: ?[]u8 = null;
    defer if (expected_node_id) |id| allocator.free(id);
    var expected_project_id: ?[]u8 = null;
    defer if (expected_project_id) |id| allocator.free(id);
    var expected_project_token: ?[]u8 = null;
    defer if (expected_project_token) |token| allocator.free(token);

    {
        var plane = ControlPlane.initWithPersistence(allocator, dir, "control-plane.db");
        defer plane.deinit();

        const invite_json = try plane.createNodeInvite(null);
        defer allocator.free(invite_json);
        var invite_parsed = try std.json.parseFromSlice(std.json.Value, allocator, invite_json, .{});
        defer invite_parsed.deinit();
        const token = invite_parsed.value.object.get("invite_token").?.string;

        const join_req = try std.fmt.allocPrint(
            allocator,
            "{{\"invite_token\":\"{s}\",\"node_name\":\"alpha\",\"fs_url\":\"ws://127.0.0.1:38891/fs\"}}",
            .{token},
        );
        defer allocator.free(join_req);
        const join_json = try plane.nodeJoin(join_req);
        defer allocator.free(join_json);
        var join_parsed = try std.json.parseFromSlice(std.json.Value, allocator, join_json, .{});
        defer join_parsed.deinit();
        expected_node_id = try allocator.dupe(u8, join_parsed.value.object.get("node_id").?.string);

        const project_json = try plane.createWorkspace("{\"name\":\"Demo\",\"vision\":\"dist fs\"}");
        defer allocator.free(project_json);
        var project_parsed = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
        defer project_parsed.deinit();
        expected_project_id = try allocator.dupe(u8, project_parsed.value.object.get("workspace_id").?.string);
        const workspace_token = project_parsed.value.object.get("workspace_token").?.string;
        expected_project_token = try allocator.dupe(u8, workspace_token);

        const mount_req = try std.fmt.allocPrint(
            allocator,
            "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"work\",\"mount_path\":\"/src\"}}",
            .{ expected_project_id.?, workspace_token, expected_node_id.? },
        );
        defer allocator.free(mount_req);
        const mounted = try plane.setWorkspaceMount(mount_req);
        defer allocator.free(mounted);

        const activate_req = try std.fmt.allocPrint(
            allocator,
            "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\"}}",
            .{ expected_project_id.?, workspace_token },
        );
        defer allocator.free(activate_req);
        const activated = try plane.activateWorkspace("agent-alpha", activate_req);
        defer allocator.free(activated);
    }

    {
        var plane = ControlPlane.initWithPersistence(allocator, dir, "control-plane.db");
        defer plane.deinit();

        const nodes_json = try plane.listNodes();
        defer allocator.free(nodes_json);
        try std.testing.expect(std.mem.indexOf(u8, nodes_json, expected_node_id.?) != null);

        const project_req = try std.fmt.allocPrint(
            allocator,
            "{{\"workspace_id\":\"{s}\"}}",
            .{expected_project_id.?},
        );
        defer allocator.free(project_req);
        const project_json = try plane.getWorkspace(project_req);
        defer allocator.free(project_json);
        try std.testing.expect(std.mem.indexOf(u8, project_json, "\"mount_path\":\"/src\"") != null);

        const remount_req = try std.fmt.allocPrint(
            allocator,
            "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\",\"node_id\":\"{s}\",\"export_name\":\"work\",\"mount_path\":\"/restored\"}}",
            .{ expected_project_id.?, expected_project_token.?, expected_node_id.? },
        );
        defer allocator.free(remount_req);
        const remounted = try plane.setWorkspaceMount(remount_req);
        defer allocator.free(remounted);
        try std.testing.expect(std.mem.indexOf(u8, remounted, "\"mount_path\":\"/restored\"") != null);

        const status = try plane.workspaceStatus("agent-alpha", null);
        defer allocator.free(status);
        try std.testing.expect(std.mem.indexOf(u8, status, expected_project_id.?) != null);
        try std.testing.expect(std.mem.indexOf(u8, status, "\"fs_url\":\"ws://127.0.0.1:38891/fs\"") != null);

        const invite2 = try plane.createNodeInvite(null);
        defer allocator.free(invite2);
        try std.testing.expect(std.mem.indexOf(u8, invite2, "\"invite_id\":\"invite-2\"") != null);
    }
}

test "acheron_control_plane: persistence restores node venom catalogs" {
    const allocator = std.testing.allocator;
    const dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/fs-control-plane-venoms-{d}", .{std.time.nanoTimestamp()});
    defer allocator.free(dir);
    defer std.fs.cwd().deleteTree(dir) catch {};

    try std.fs.cwd().makePath(dir);

    var expected_node_id: ?[]u8 = null;
    defer if (expected_node_id) |id| allocator.free(id);

    {
        var plane = ControlPlane.initWithPersistence(allocator, dir, "control-plane.db");
        defer plane.deinit();

        const invite_json = try plane.createNodeInvite(null);
        defer allocator.free(invite_json);
        var invite_parsed = try std.json.parseFromSlice(std.json.Value, allocator, invite_json, .{});
        defer invite_parsed.deinit();
        const token = invite_parsed.value.object.get("invite_token").?.string;

        const join_req = try std.fmt.allocPrint(
            allocator,
            "{{\"invite_token\":\"{s}\",\"node_name\":\"alpha\",\"fs_url\":\"ws://127.0.0.1:38891/fs\"}}",
            .{token},
        );
        defer allocator.free(join_req);
        const join_json = try plane.nodeJoin(join_req);
        defer allocator.free(join_json);
        var join_parsed = try std.json.parseFromSlice(std.json.Value, allocator, join_json, .{});
        defer join_parsed.deinit();
        const node_id = join_parsed.value.object.get("node_id").?.string;
        const node_secret = join_parsed.value.object.get("node_secret").?.string;
        expected_node_id = try allocator.dupe(u8, node_id);

        const installed = try plane.installVenomPackage(
            \\{"package":{"venom_id":"camera","kind":"camera","version":"1","categories":["camera","edge"],"host_roles":["node"],"binding_scopes":["node"],"runtime_kind":"native","requirements":{},"capabilities":{"still":true},"ops":{"model":"namespace"},"runtime":{},"permissions":{},"schema":{}}}
        );
        defer allocator.free(installed);

        const upsert_req = try std.fmt.allocPrint(
            allocator,
            "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"venoms\":[{{\"venom_id\":\"camera\",\"kind\":\"camera\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"/nodes/{s}/venoms/camera\"],\"capabilities\":{{\"still\":true}}}}]}}",
            .{ node_id, node_secret, node_id },
        );
        defer allocator.free(upsert_req);
        const upserted = try plane.nodeVenomUpsert(upsert_req);
        defer allocator.free(upserted);
        try std.testing.expect(std.mem.indexOf(u8, upserted, "\"venom_id\":\"camera\"") != null);
    }

    {
        var plane = ControlPlane.initWithPersistence(allocator, dir, "control-plane.db");
        defer plane.deinit();

        const get_req = try std.fmt.allocPrint(allocator, "{{\"node_id\":\"{s}\"}}", .{expected_node_id.?});
        defer allocator.free(get_req);
        const fetched = try plane.nodeVenomGet(get_req);
        defer allocator.free(fetched);
        try std.testing.expect(std.mem.indexOf(u8, fetched, "\"venom_id\":\"camera\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, fetched, "\"/nodes/") != null);
    }
}

test "acheron_control_plane: node venom upsert requires installed package for custom node venom" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const joined = try plane.ensureNode("camera-node", "", 60_000);
    defer allocator.free(joined);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, joined, .{});
    defer parsed.deinit();
    const node_id = parsed.value.object.get("node_id").?.string;
    const node_secret = parsed.value.object.get("node_secret").?.string;

    const upsert_req = try std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"venoms\":[{{\"venom_id\":\"camera\",\"kind\":\"camera\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"/nodes/{s}/camera\"],\"runtime\":{{\"type\":\"native_proc\"}}}}]}}",
        .{ node_id, node_secret, node_id },
    );
    defer allocator.free(upsert_req);
    try std.testing.expectError(ControlPlaneError.VenomPackageNotFound, plane.nodeVenomUpsert(upsert_req));
}

test "acheron_control_plane: node venom upsert rejects runtime mismatch with installed package" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const installed = try plane.installVenomPackage(
        \\{"package":{"venom_id":"camera","kind":"camera","version":"1","categories":["camera"],"host_roles":["node"],"binding_scopes":["node"],"runtime_kind":"wasm","requirements":{},"capabilities":{"still":true},"ops":{"model":"namespace"},"runtime":{"type":"wasm"},"permissions":{},"schema":{}}}
    );
    defer allocator.free(installed);

    const joined = try plane.ensureNode("camera-node", "", 60_000);
    defer allocator.free(joined);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, joined, .{});
    defer parsed.deinit();
    const node_id = parsed.value.object.get("node_id").?.string;
    const node_secret = parsed.value.object.get("node_secret").?.string;

    const upsert_req = try std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"venoms\":[{{\"venom_id\":\"camera\",\"kind\":\"camera\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"/nodes/{s}/camera\"],\"runtime\":{{\"type\":\"native_proc\"}}}}]}}",
        .{ node_id, node_secret, node_id },
    );
    defer allocator.free(upsert_req);
    try std.testing.expectError(ControlPlaneError.VenomPackageRuntimeMismatch, plane.nodeVenomUpsert(upsert_req));
}

test "acheron_control_plane: builtin terminal package accepts local node export upsert" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const joined = try plane.ensureNode("spiderweb-local", "", 60_000);
    defer allocator.free(joined);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, joined, .{});
    defer parsed.deinit();
    const node_id = parsed.value.object.get("node_id").?.string;
    const node_secret = parsed.value.object.get("node_secret").?.string;

    const upsert_req = try std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"platform\":{{\"os\":\"linux\",\"arch\":\"amd64\",\"runtime_kind\":\"spiderweb\"}},\"venoms\":[{{\"venom_id\":\"terminal\",\"kind\":\"terminal\",\"version\":\"1\",\"state\":\"online\",\"package_id\":\"terminal\",\"host_roles\":[\"node\"],\"binding_scopes\":[\"workspace\"],\"requirements\":{{}},\"endpoints\":[\"/nodes/{s}/venoms/terminal\"],\"mounts\":[{{\"mount_id\":\"terminal\",\"mount_path\":\"/nodes/{s}/venoms/terminal\",\"state\":\"online\"}}],\"capabilities\":{{\"invoke\":true,\"discoverable\":true}},\"ops\":{{\"model\":\"namespace\",\"invoke\":\"control/invoke.json\"}},\"runtime\":{{\"type\":\"native_proc\",\"abi\":\"namespace-driver-v1\"}},\"permissions\":{{\"default\":\"allow-by-default\"}},\"schema\":{{\"model\":\"namespace-mount\"}}}}]}}",
        .{ node_id, node_secret, node_id, node_id },
    );
    defer allocator.free(upsert_req);

    const upserted = try plane.nodeVenomUpsert(upsert_req);
    defer allocator.free(upserted);
    try std.testing.expect(std.mem.indexOf(u8, upserted, "\"venom_id\":\"terminal\"") != null);
}

test "acheron_control_plane: builtin computer and browser packages accept node export upsert" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const joined = try plane.ensureNode("mac-capabilities", "", 60_000);
    defer allocator.free(joined);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, joined, .{});
    defer parsed.deinit();
    const node_id = parsed.value.object.get("node_id").?.string;
    const node_secret = parsed.value.object.get("node_secret").?.string;

    const upsert_req = try std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"platform\":{{\"os\":\"macos\",\"arch\":\"arm64\",\"runtime_kind\":\"native\"}},\"venoms\":[" ++
            "{{\"venom_id\":\"computer-main\",\"package_id\":\"computer\",\"kind\":\"computer\",\"version\":\"1\",\"state\":\"online\",\"host_roles\":[\"node\"],\"binding_scopes\":[\"workspace\"],\"runtime_kind\":\"native\",\"requirements\":{{\"host_capabilities\":[\"macos_accessibility\",\"screen_capture\"]}},\"endpoints\":[\"/nodes/{s}/venoms/computer-main\"],\"mounts\":[{{\"mount_id\":\"computer-main\",\"mount_path\":\"/nodes/{s}/venoms/computer-main\",\"state\":\"online\"}}],\"capabilities\":{{\"invoke\":true,\"observe\":true,\"act\":true}},\"ops\":{{\"model\":\"namespace\",\"invoke\":\"control/invoke.json\"}},\"runtime\":{{\"type\":\"native_proc\",\"abi\":\"namespace-driver-v1\"}},\"permissions\":{{\"default\":\"deny-by-default\"}},\"schema\":{{\"model\":\"computer-observe-act-v1\"}}}}," ++
            "{{\"venom_id\":\"browser-main\",\"package_id\":\"browser\",\"kind\":\"browser\",\"version\":\"1\",\"state\":\"online\",\"host_roles\":[\"node\"],\"binding_scopes\":[\"workspace\"],\"runtime_kind\":\"native\",\"requirements\":{{\"host_capabilities\":[\"managed_browser\"]}},\"endpoints\":[\"/nodes/{s}/venoms/browser-main\"],\"mounts\":[{{\"mount_id\":\"browser-main\",\"mount_path\":\"/nodes/{s}/venoms/browser-main\",\"state\":\"online\"}}],\"capabilities\":{{\"invoke\":true,\"observe\":true,\"act\":true}},\"ops\":{{\"model\":\"namespace\",\"invoke\":\"control/invoke.json\"}},\"runtime\":{{\"type\":\"native_proc\",\"abi\":\"namespace-driver-v1\"}},\"permissions\":{{\"default\":\"deny-by-default\"}},\"schema\":{{\"model\":\"browser-observe-act-v1\"}}}}" ++
            "]}}",
        .{ node_id, node_secret, node_id, node_id, node_id, node_id },
    );
    defer allocator.free(upsert_req);

    const upserted = try plane.nodeVenomUpsert(upsert_req);
    defer allocator.free(upserted);
    try std.testing.expect(std.mem.indexOf(u8, upserted, "\"venom_id\":\"computer-main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, upserted, "\"venom_id\":\"browser-main\"") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, upserted, "\"package_id\":\"computer\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, upserted, "\"package_id\":\"browser\""));
}

test "acheron_control_plane: node venom upsert honors package_id alias" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const installed = try plane.installVenomPackage(
        \\{"package":{"venom_id":"camera_pkg","kind":"camera","version":"1","categories":["camera"],"host_roles":["node"],"binding_scopes":["node"],"runtime_kind":"native","requirements":{},"capabilities":{"still":true},"ops":{"model":"namespace"},"runtime":{"type":"native_proc"},"permissions":{},"schema":{}}}
    );
    defer allocator.free(installed);

    const joined = try plane.ensureNode("camera-node", "", 60_000);
    defer allocator.free(joined);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, joined, .{});
    defer parsed.deinit();
    const node_id = parsed.value.object.get("node_id").?.string;
    const node_secret = parsed.value.object.get("node_secret").?.string;

    const upsert_req = try std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"platform\":{{\"os\":\"linux\",\"arch\":\"amd64\",\"runtime_kind\":\"native\"}},\"venoms\":[{{\"venom_id\":\"camera-instance\",\"package_id\":\"camera_pkg\",\"kind\":\"camera\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"/nodes/{s}/camera\"],\"runtime\":{{\"type\":\"native_proc\"}}}}]}}",
        .{ node_id, node_secret, node_id },
    );
    defer allocator.free(upsert_req);

    const upserted = try plane.nodeVenomUpsert(upsert_req);
    defer allocator.free(upserted);
    try std.testing.expect(std.mem.indexOf(u8, upserted, "\"venom_id\":\"camera-instance\"") != null);
}

test "acheron_control_plane: platform-only upsert preserves stored package_id alias" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const installed = try plane.installVenomPackage(
        \\{"package":{"venom_id":"camera_pkg","kind":"camera","version":"1","categories":["camera"],"host_roles":["node"],"binding_scopes":["node"],"runtime_kind":"native","requirements":{},"capabilities":{"still":true},"ops":{"model":"namespace"},"runtime":{"type":"native_proc"},"permissions":{},"schema":{}}}
    );
    defer allocator.free(installed);

    const joined = try plane.ensureNode("camera-node", "", 60_000);
    defer allocator.free(joined);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, joined, .{});
    defer parsed.deinit();
    const node_id = parsed.value.object.get("node_id").?.string;
    const node_secret = parsed.value.object.get("node_secret").?.string;

    const initial_upsert = try std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"platform\":{{\"os\":\"linux\",\"arch\":\"amd64\",\"runtime_kind\":\"native\"}},\"venoms\":[{{\"venom_id\":\"camera-instance\",\"package_id\":\"camera_pkg\",\"kind\":\"camera\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"/nodes/{s}/camera\"],\"runtime\":{{\"type\":\"native_proc\"}}}}]}}",
        .{ node_id, node_secret, node_id },
    );
    defer allocator.free(initial_upsert);
    const upserted = try plane.nodeVenomUpsert(initial_upsert);
    defer allocator.free(upserted);

    const platform_only = try std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"platform\":{{\"os\":\"linux\",\"arch\":\"amd64\",\"runtime_kind\":\"native\"}}}}",
        .{ node_id, node_secret },
    );
    defer allocator.free(platform_only);

    const revalidated = try plane.nodeVenomUpsert(platform_only);
    defer allocator.free(revalidated);
    try std.testing.expect(std.mem.indexOf(u8, revalidated, "\"package_id\":\"camera_pkg\"") != null);
}

test "acheron_control_plane: platform-only node upsert revalidates existing venoms" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const installed = try plane.installVenomPackage(
        \\{"package":{"venom_id":"camera","kind":"camera","version":"1","categories":["camera"],"host_roles":["node"],"binding_scopes":["node"],"runtime_kind":"native","requirements":{"host_capabilities":["native_proc"]},"capabilities":{"still":true},"ops":{"model":"namespace"},"runtime":{"type":"native_proc"},"permissions":{},"schema":{}}}
    );
    defer allocator.free(installed);

    const joined = try plane.ensureNode("camera-node", "", 60_000);
    defer allocator.free(joined);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, joined, .{});
    defer parsed.deinit();
    const node_id = parsed.value.object.get("node_id").?.string;
    const node_secret = parsed.value.object.get("node_secret").?.string;

    const upsert_req = try std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"platform\":{{\"runtime_kind\":\"native\"}},\"venoms\":[{{\"venom_id\":\"camera\",\"kind\":\"camera\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"/nodes/{s}/camera\"],\"runtime\":{{\"type\":\"native_proc\"}}}}]}}",
        .{ node_id, node_secret, node_id },
    );
    defer allocator.free(upsert_req);
    const upserted = try plane.nodeVenomUpsert(upsert_req);
    defer allocator.free(upserted);

    const platform_only_req = try std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"platform\":{{\"runtime_kind\":\"wasm\"}}}}",
        .{ node_id, node_secret },
    );
    defer allocator.free(platform_only_req);
    try std.testing.expectError(ControlPlaneError.VenomPackageRequirementsUnmet, plane.nodeVenomUpsert(platform_only_req));
}

test "acheron_control_plane: runtime venom instantiation requires package dependencies" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const installed = try plane.installVenomPackage(
        \\{"package":{"venom_id":"scratchpad","kind":"memory_ext","version":"1","categories":["memory"],"host_roles":["client"],"binding_scopes":["agent"],"runtime_kind":"native","requirements":{"venoms":["memory"]},"capabilities":{"invoke":true},"ops":{"model":"filesystem_loopback"},"runtime":{"type":"external_runtime"},"permissions":{},"schema":{}}}
    );
    defer allocator.free(installed);

    try std.testing.expectError(
        ControlPlaneError.VenomPackageRequirementsUnmet,
        plane.validateRuntimeVenomInstantiation(&.{"scratchpad"}),
    );

    try plane.validateRuntimeVenomInstantiation(&.{ "memory", "scratchpad" });
}

test "acheron_control_plane: venom package install list get remove" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const install_req =
        \\{"package":{"venom_id":"camera_pkg","kind":"camera","version":"1","categories":["camera","edge"],"host_roles":["node"],"binding_scopes":["node"],"runtime_kind":"native","requirements":{},"capabilities":{"still":true},"ops":{"model":"namespace"},"runtime":{"type":"native_proc"},"permissions":{"default":"deny-by-default"},"schema":{"model":"namespace-mount"},"help_md":"Camera package"}}
    ;
    const installed = try plane.installVenomPackage(install_req);
    defer allocator.free(installed);
    try std.testing.expect(std.mem.indexOf(u8, installed, "\"venom_id\":\"camera_pkg\"") != null);

    const listed = try plane.listVenomPackages();
    defer allocator.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"venom_id\":\"packages\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"venom_id\":\"camera_pkg\"") != null);

    const fetched = try plane.getVenomPackage("{\"venom_id\":\"camera_pkg\"}");
    defer allocator.free(fetched);
    try std.testing.expect(std.mem.indexOf(u8, fetched, "\"kind\":\"camera\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetched, "\"enabled\":true") != null);

    const disabled = try plane.disableVenomPackage("{\"venom_id\":\"camera_pkg\"}");
    defer allocator.free(disabled);
    try std.testing.expect(std.mem.indexOf(u8, disabled, "\"enabled\":false") != null);
    try std.testing.expectError(
        ControlPlaneError.VenomPackageNotFound,
        plane.validateRuntimeVenomInstantiation(&.{"camera_pkg"}),
    );

    const listed_disabled = try plane.listVenomPackages();
    defer allocator.free(listed_disabled);
    try std.testing.expect(std.mem.indexOf(u8, listed_disabled, "\"venom_id\":\"camera_pkg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed_disabled, "\"enabled\":false") != null);

    const enabled = try plane.enableVenomPackage("{\"venom_id\":\"camera_pkg\"}");
    defer allocator.free(enabled);
    try std.testing.expect(std.mem.indexOf(u8, enabled, "\"enabled\":true") != null);

    const removed = try plane.removeVenomPackage("{\"venom_id\":\"camera_pkg\"}");
    defer allocator.free(removed);
    try std.testing.expect(std.mem.indexOf(u8, removed, "\"removed\":true") != null);

    const listed_after = try plane.listVenomPackages();
    defer allocator.free(listed_after);
    try std.testing.expect(std.mem.indexOf(u8, listed_after, "\"venom_id\":\"camera_pkg\"") == null);
}

test "acheron_control_plane: venom package persistence restores installed registry" {
    const allocator = std.testing.allocator;
    const dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/fs-control-plane-packages-{d}", .{std.time.nanoTimestamp()});
    defer allocator.free(dir);
    defer std.fs.cwd().deleteTree(dir) catch {};

    try std.fs.cwd().makePath(dir);

    {
        var plane = ControlPlane.initWithPersistence(allocator, dir, "control-plane.db");
        defer plane.deinit();
        const installed = try plane.installVenomPackage(
            \\{"package":{"venom_id":"package_persist","kind":"registry_test","version":"3","categories":["test"],"host_roles":["spiderweb"],"binding_scopes":["workspace"],"runtime_kind":"native","requirements":{},"capabilities":{},"ops":{},"runtime":{},"permissions":{},"schema":{}}}
        );
        defer allocator.free(installed);
        try std.testing.expect(std.mem.indexOf(u8, installed, "\"venom_id\":\"package_persist\"") != null);
    }

    {
        var plane = ControlPlane.initWithPersistence(allocator, dir, "control-plane.db");
        defer plane.deinit();
        const listed = try plane.listVenomPackages();
        defer allocator.free(listed);
        try std.testing.expect(std.mem.indexOf(u8, listed, "\"venom_id\":\"package_persist\"") != null);

        const fetched = try plane.getVenomPackage("{\"venom_id\":\"package_persist\"}");
        defer allocator.free(fetched);
        try std.testing.expect(std.mem.indexOf(u8, fetched, "\"version\":\"3\"") != null);
    }
}

test "acheron_control_plane: venom release rollback and targeted removal" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const install_v1 =
        \\{"release":{"package_id":"camera_pkg","release_version":"1.0.0","channel":"stable","digest":"sha256:v1","signature":{"alg":"test","sig":"v1"},"trust":{"source":"test"},"package":{"venom_id":"camera_pkg","kind":"camera","version":"1","release_version":"1.0.0","categories":["camera"],"host_roles":["node"],"binding_scopes":["node"],"runtime_kind":"native","requirements":{},"capabilities":{"still":true},"ops":{"model":"namespace"},"runtime":{"type":"native_proc"},"permissions":{"default":"deny-by-default"},"schema":{"model":"namespace-mount"}}}}
    ;
    const installed_v1 = try plane.installVenomPackage(install_v1);
    defer allocator.free(installed_v1);
    try std.testing.expect(std.mem.indexOf(u8, installed_v1, "\"release_version\":\"1.0.0\"") != null);

    const install_v2 =
        \\{"release":{"package_id":"camera_pkg","release_version":"1.1.0","channel":"stable","digest":"sha256:v2","signature":{"alg":"test","sig":"v2"},"trust":{"source":"test"},"package":{"venom_id":"camera_pkg","kind":"camera","version":"2","release_version":"1.1.0","categories":["camera"],"host_roles":["node"],"binding_scopes":["node"],"runtime_kind":"native","requirements":{},"capabilities":{"still":true,"stream":true},"ops":{"model":"namespace"},"runtime":{"type":"native_proc"},"permissions":{"default":"deny-by-default"},"schema":{"model":"namespace-mount"}}}}
    ;
    const installed_v2 = try plane.installVenomPackage(install_v2);
    defer allocator.free(installed_v2);
    try std.testing.expect(std.mem.indexOf(u8, installed_v2, "\"release_version\":\"1.1.0\"") != null);

    const releases = try plane.listVenomReleases();
    defer allocator.free(releases);
    try std.testing.expect(std.mem.indexOf(u8, releases, "\"release_id\":\"camera_pkg@1.0.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, releases, "\"release_id\":\"camera_pkg@1.1.0\"") != null);

    const release_v1 = try plane.getVenomRelease("{\"venom_id\":\"camera_pkg\",\"release_version\":\"1.0.0\"}");
    defer allocator.free(release_v1);
    try std.testing.expect(std.mem.indexOf(u8, release_v1, "\"digest\":\"sha256:v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, release_v1, "\"enabled\":false") != null);

    const projected_latest = try plane.getVenomPackage("{\"venom_id\":\"camera_pkg\"}");
    defer allocator.free(projected_latest);
    try std.testing.expect(std.mem.indexOf(u8, projected_latest, "\"release_version\":\"1.1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, projected_latest, "\"enabled\":true") != null);

    const rolled_back = try plane.rollbackVenomPackage("{\"venom_id\":\"camera_pkg\",\"release_version\":\"1.0.0\"}");
    defer allocator.free(rolled_back);
    try std.testing.expect(std.mem.indexOf(u8, rolled_back, "\"release_version\":\"1.0.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rolled_back, "\"enabled\":true") != null);

    const release_v2_after_rollback = try plane.getVenomRelease("{\"venom_id\":\"camera_pkg\",\"release_version\":\"1.1.0\"}");
    defer allocator.free(release_v2_after_rollback);
    try std.testing.expect(std.mem.indexOf(u8, release_v2_after_rollback, "\"enabled\":false") != null);

    const removed = try plane.removeVenomPackage("{\"venom_id\":\"camera_pkg\",\"release_version\":\"1.0.0\"}");
    defer allocator.free(removed);
    try std.testing.expect(std.mem.indexOf(u8, removed, "\"removed\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, removed, "\"release_version\":\"1.0.0\"") != null);

    const projected_after_remove = try plane.getVenomPackage("{\"venom_id\":\"camera_pkg\"}");
    defer allocator.free(projected_after_remove);
    try std.testing.expect(std.mem.indexOf(u8, projected_after_remove, "\"release_version\":\"1.1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, projected_after_remove, "\"enabled\":false") != null);

    const releases_after_remove = try plane.listVenomReleases();
    defer allocator.free(releases_after_remove);
    try std.testing.expect(std.mem.indexOf(u8, releases_after_remove, "\"release_id\":\"camera_pkg@1.0.0\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, releases_after_remove, "\"release_id\":\"camera_pkg@1.1.0\"") != null);
}

test "acheron_control_plane: venom release rollback defaults to previous installed release" {
    const allocator = std.testing.allocator;
    var plane = ControlPlane.init(allocator);
    defer plane.deinit();

    const install_v1 =
        \\{"release":{"package_id":"camera_pkg","release_version":"1.0.0","channel":"stable","digest":"sha256:v1","signature":{"alg":"test","sig":"v1"},"trust":{"source":"test"},"package":{"venom_id":"camera_pkg","kind":"camera","version":"1","release_version":"1.0.0","categories":["camera"],"host_roles":["node"],"binding_scopes":["node"],"runtime_kind":"native","requirements":{},"capabilities":{"still":true},"ops":{"model":"namespace"},"runtime":{"type":"native_proc"},"permissions":{"default":"deny-by-default"},"schema":{"model":"namespace-mount"}}}}
    ;
    const install_v2 =
        \\{"release":{"package_id":"camera_pkg","release_version":"1.1.0","channel":"stable","digest":"sha256:v2","signature":{"alg":"test","sig":"v2"},"trust":{"source":"test"},"package":{"venom_id":"camera_pkg","kind":"camera","version":"2","release_version":"1.1.0","categories":["camera"],"host_roles":["node"],"binding_scopes":["node"],"runtime_kind":"native","requirements":{},"capabilities":{"still":true,"stream":true},"ops":{"model":"namespace"},"runtime":{"type":"native_proc"},"permissions":{"default":"deny-by-default"},"schema":{"model":"namespace-mount"}}}}
    ;
    const install_v3 =
        \\{"release":{"package_id":"camera_pkg","release_version":"1.2.0","channel":"stable","digest":"sha256:v3","signature":{"alg":"test","sig":"v3"},"trust":{"source":"test"},"package":{"venom_id":"camera_pkg","kind":"camera","version":"3","release_version":"1.2.0","categories":["camera"],"host_roles":["node"],"binding_scopes":["node"],"runtime_kind":"native","requirements":{},"capabilities":{"still":true,"stream":true,"hdr":true},"ops":{"model":"namespace"},"runtime":{"type":"native_proc"},"permissions":{"default":"deny-by-default"},"schema":{"model":"namespace-mount"}}}}
    ;

    const installed_v1 = try plane.installVenomPackage(install_v1);
    defer allocator.free(installed_v1);
    const installed_v2 = try plane.installVenomPackage(install_v2);
    defer allocator.free(installed_v2);
    const installed_v3 = try plane.installVenomPackage(install_v3);
    defer allocator.free(installed_v3);

    const rolled_back = try plane.rollbackVenomPackage("{\"venom_id\":\"camera_pkg\"}");
    defer allocator.free(rolled_back);
    try std.testing.expect(std.mem.indexOf(u8, rolled_back, "\"release_version\":\"1.1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rolled_back, "\"enabled\":true") != null);

    const current = try plane.getVenomPackage("{\"venom_id\":\"camera_pkg\"}");
    defer allocator.free(current);
    try std.testing.expect(std.mem.indexOf(u8, current, "\"release_version\":\"1.1.0\"") != null);

    const newest_release = try plane.getVenomRelease("{\"venom_id\":\"camera_pkg\",\"release_version\":\"1.2.0\"}");
    defer allocator.free(newest_release);
    try std.testing.expect(std.mem.indexOf(u8, newest_release, "\"enabled\":false") != null);
}

test "acheron_control_plane: venom release persistence restores selected release" {
    const allocator = std.testing.allocator;
    const dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/fs-control-plane-releases-{d}", .{std.time.nanoTimestamp()});
    defer allocator.free(dir);
    defer std.fs.cwd().deleteTree(dir) catch {};

    try std.fs.cwd().makePath(dir);

    {
        var plane = ControlPlane.initWithPersistence(allocator, dir, "control-plane.db");
        defer plane.deinit();

        const install_v1 =
            \\{"release":{"package_id":"camera_pkg","release_version":"1.0.0","channel":"stable","digest":"sha256:v1","signature":{"alg":"test","sig":"v1"},"trust":{"source":"test"},"package":{"venom_id":"camera_pkg","kind":"camera","version":"1","release_version":"1.0.0","categories":["camera"],"host_roles":["node"],"binding_scopes":["node"],"runtime_kind":"native","requirements":{},"capabilities":{"still":true},"ops":{"model":"namespace"},"runtime":{"type":"native_proc"},"permissions":{"default":"deny-by-default"},"schema":{"model":"namespace-mount"}}}}
        ;
        const install_v2 =
            \\{"release":{"package_id":"camera_pkg","release_version":"1.1.0","channel":"stable","digest":"sha256:v2","signature":{"alg":"test","sig":"v2"},"trust":{"source":"test"},"package":{"venom_id":"camera_pkg","kind":"camera","version":"2","release_version":"1.1.0","categories":["camera"],"host_roles":["node"],"binding_scopes":["node"],"runtime_kind":"native","requirements":{},"capabilities":{"still":true,"stream":true},"ops":{"model":"namespace"},"runtime":{"type":"native_proc"},"permissions":{"default":"deny-by-default"},"schema":{"model":"namespace-mount"}}}}
        ;

        const installed_v1 = try plane.installVenomPackage(install_v1);
        defer allocator.free(installed_v1);
        const installed_v2 = try plane.installVenomPackage(install_v2);
        defer allocator.free(installed_v2);

        const rolled_back = try plane.enableVenomPackage("{\"venom_id\":\"camera_pkg\",\"release_version\":\"1.0.0\"}");
        defer allocator.free(rolled_back);
        try std.testing.expect(std.mem.indexOf(u8, rolled_back, "\"release_version\":\"1.0.0\"") != null);
    }

    {
        var plane = ControlPlane.initWithPersistence(allocator, dir, "control-plane.db");
        defer plane.deinit();

        const projected = try plane.getVenomPackage("{\"venom_id\":\"camera_pkg\"}");
        defer allocator.free(projected);
        try std.testing.expect(std.mem.indexOf(u8, projected, "\"release_version\":\"1.0.0\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, projected, "\"enabled\":true") != null);

        const release_v2 = try plane.getVenomRelease("{\"venom_id\":\"camera_pkg\",\"release_version\":\"1.1.0\"}");
        defer allocator.free(release_v2);
        try std.testing.expect(std.mem.indexOf(u8, release_v2, "\"enabled\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, release_v2, "\"digest\":\"sha256:v2\"") != null);

        const releases = try plane.listVenomReleases();
        defer allocator.free(releases);
        try std.testing.expect(std.mem.indexOf(u8, releases, "\"release_id\":\"camera_pkg@1.0.0\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, releases, "\"release_id\":\"camera_pkg@1.1.0\"") != null);
    }
}

test "acheron_control_plane: persistence keeps primary active project override" {
    const allocator = std.testing.allocator;
    const dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/fs-control-plane-primary-{d}", .{std.time.nanoTimestamp()});
    defer allocator.free(dir);
    defer std.fs.cwd().deleteTree(dir) catch {};

    try std.fs.cwd().makePath(dir);

    var expected_project_id: ?[]u8 = null;
    defer if (expected_project_id) |id| allocator.free(id);

    {
        var plane = ControlPlane.initWithPersistence(allocator, dir, "control-plane.db");
        defer plane.deinit();

        const project_json = try plane.createWorkspace("{\"name\":\"PrimaryPersist\",\"vision\":\"PrimaryPersist\"}");
        defer allocator.free(project_json);
        var project_parsed = try std.json.parseFromSlice(std.json.Value, allocator, project_json, .{});
        defer project_parsed.deinit();
        const workspace_id = project_parsed.value.object.get("workspace_id").?.string;
        const workspace_token = project_parsed.value.object.get("workspace_token").?.string;
        expected_project_id = try allocator.dupe(u8, workspace_id);

        const activate_req = try std.fmt.allocPrint(
            allocator,
            "{{\"workspace_id\":\"{s}\",\"workspace_token\":\"{s}\"}}",
            .{ workspace_id, workspace_token },
        );
        defer allocator.free(activate_req);
        const activated = try plane.activateWorkspaceWithRole(default_host_actor_id, activate_req, true);
        defer allocator.free(activated);
        try std.testing.expect(std.mem.indexOf(u8, activated, expected_project_id.?) != null);
    }

    {
        var plane = ControlPlane.initWithPersistence(allocator, dir, "control-plane.db");
        defer plane.deinit();

        const status = try plane.workspaceStatusWithRole(default_host_actor_id, null, true);
        defer allocator.free(status);
        try std.testing.expect(std.mem.indexOf(u8, status, expected_project_id.?) != null);
    }
}
