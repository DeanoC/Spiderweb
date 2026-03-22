const std = @import("std");
const Config = @import("config.zig");
const acheron_session_mod = @import("acheron/session.zig");

pub fn resetNamespaceSession(namespace_session: *?acheron_session_mod.Session) void {
    if (namespace_session.*) |*session| {
        session.deinit();
        namespace_session.* = null;
    }
}

pub fn getOrInitNamespaceSessionForBinding(
    allocator: std.mem.Allocator,
    namespace_session: *?acheron_session_mod.Session,
    runtime_registry: anytype,
    binding: anytype,
    session_key: []const u8,
    trusted_namespace_mount_url: ?[]const u8,
    is_admin: bool,
) !*acheron_session_mod.Session {
    if (namespace_session.* == null) {
        namespace_session.* = try initNamespaceSessionForBinding(
            allocator,
            runtime_registry,
            binding,
            session_key,
            trusted_namespace_mount_url,
            is_admin,
        );
    }
    return &(namespace_session.*.?);
}

pub fn localFsExportRootForNamespace(runtime_config: Config.RuntimeConfig) ?[]const u8 {
    const trimmed = runtime_config.effectiveLocalNodeExportPath();
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "/")) return null;
    return trimmed;
}

pub fn initNamespaceSessionForBinding(
    allocator: std.mem.Allocator,
    runtime_registry: anytype,
    binding: anytype,
    session_key: []const u8,
    trusted_namespace_mount_url: ?[]const u8,
    is_admin: bool,
) !acheron_session_mod.Session {
    const project_id = binding.project_id orelse return error.InvalidState;
    const runtime = runtime_registry.getRuntimeForBindingIfReady(binding.agent_id, binding.project_id) orelse
        try runtime_registry.getOrCreate(binding.agent_id, binding.project_id, binding.project_token);
    defer runtime.release();

    const namespace_auth_token = if (is_admin)
        try runtime_registry.auth_tokens.copyAccessToken()
    else
        try runtime_registry.auth_tokens.copyAccessToken();
    defer allocator.free(namespace_auth_token);

    return acheron_session_mod.Session.initWithOptions(
        allocator,
        runtime,
        binding.agent_id,
        .{
            .project_id = project_id,
            .project_token = binding.project_token,
            .namespace_mount_url = trusted_namespace_mount_url orelse runtime_registry.workspace_url,
            .namespace_session_key = session_key,
            .agents_dir = runtime_registry.runtime_config.agents_dir,
            .assets_dir = runtime_registry.runtime_config.assets_dir,
            .projects_dir = "projects",
            .local_fs_export_root = localFsExportRootForNamespace(runtime_registry.runtime_config),
            .sandbox_mounts_root = runtime_registry.runtime_config.sandbox_mounts_root,
            .sandbox_launcher = runtime_registry.runtime_config.sandbox_launcher,
            .sandbox_fs_mount_bin = runtime_registry.runtime_config.sandbox_fs_mount_bin,
            .control_plane = &runtime_registry.control_plane,
            .namespace_auth_token = namespace_auth_token,
            .control_operator_token = runtime_registry.control_operator_token,
            .actor_type = binding.actor_type,
            .actor_id = binding.actor_id,
            .is_admin = is_admin,
        },
    );
}
