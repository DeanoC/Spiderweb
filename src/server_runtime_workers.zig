const std = @import("std");

pub fn reconcileWorkerMain(runtime_registry: anytype) void {
    runtime_registry.runReconcileWorkerLoop();
}

pub fn servicePresenceWorkerMain(runtime_registry: anytype) void {
    runtime_registry.runServicePresenceWorkerLoop();
}

pub fn spawnRuntimeWarmupThread(
    runtime_registry: anytype,
    binding_key: []const u8,
    agent_id: []const u8,
    workspace_id: ?[]const u8,
    workspace_token: ?[]const u8,
) !void {
    try runtime_registry.beginRuntimeWarmupThread();
    errdefer runtime_registry.finishRuntimeWarmupThread();

    const Context = struct {
        allocator: std.mem.Allocator,
        runtime_registry: @TypeOf(runtime_registry),
        binding_key: ?[]u8 = null,
        agent_id: ?[]u8 = null,
        workspace_id: ?[]u8 = null,
        workspace_token: ?[]u8 = null,

        fn deinit(self: *@This()) void {
            if (self.binding_key) |value| self.allocator.free(value);
            if (self.agent_id) |value| self.allocator.free(value);
            if (self.workspace_id) |value| self.allocator.free(value);
            if (self.workspace_token) |value| self.allocator.free(value);
            self.allocator.destroy(self);
        }
    };

    const ctx = try runtime_registry.allocator.create(Context);
    ctx.* = .{
        .allocator = runtime_registry.allocator,
        .runtime_registry = runtime_registry,
        .binding_key = null,
        .agent_id = null,
        .workspace_id = null,
        .workspace_token = null,
    };
    errdefer ctx.deinit();

    ctx.binding_key = try runtime_registry.allocator.dupe(u8, binding_key);
    ctx.agent_id = try runtime_registry.allocator.dupe(u8, agent_id);
    if (workspace_id) |value| {
        ctx.workspace_id = try runtime_registry.allocator.dupe(u8, value);
    }
    if (workspace_token) |value| {
        ctx.workspace_token = try runtime_registry.allocator.dupe(u8, value);
    }

    const ThreadMain = struct {
        fn run(thread_ctx: *Context) void {
            defer thread_ctx.deinit();
            const resolved_binding_key = thread_ctx.binding_key orelse return;
            const resolved_agent_id = thread_ctx.agent_id orelse return;
            thread_ctx.runtime_registry.runRuntimeWarmupThread(
                resolved_binding_key,
                resolved_agent_id,
                thread_ctx.workspace_id,
                thread_ctx.workspace_token,
            );
        }
    };

    const thread = try std.Thread.spawn(.{}, ThreadMain.run, .{ctx});
    thread.detach();
}
