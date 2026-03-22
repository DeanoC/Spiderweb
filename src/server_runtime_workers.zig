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
    project_id: ?[]const u8,
    project_token: ?[]const u8,
) !void {
    try runtime_registry.beginRuntimeWarmupThread();
    errdefer runtime_registry.finishRuntimeWarmupThread();

    const Context = struct {
        allocator: std.mem.Allocator,
        runtime_registry: @TypeOf(runtime_registry),
        binding_key: ?[]u8 = null,
        agent_id: ?[]u8 = null,
        project_id: ?[]u8 = null,
        project_token: ?[]u8 = null,

        fn deinit(self: *@This()) void {
            if (self.binding_key) |value| self.allocator.free(value);
            if (self.agent_id) |value| self.allocator.free(value);
            if (self.project_id) |value| self.allocator.free(value);
            if (self.project_token) |value| self.allocator.free(value);
            self.allocator.destroy(self);
        }
    };

    const ctx = try runtime_registry.allocator.create(Context);
    ctx.* = .{
        .allocator = runtime_registry.allocator,
        .runtime_registry = runtime_registry,
        .binding_key = null,
        .agent_id = null,
        .project_id = null,
        .project_token = null,
    };
    errdefer ctx.deinit();

    ctx.binding_key = try runtime_registry.allocator.dupe(u8, binding_key);
    ctx.agent_id = try runtime_registry.allocator.dupe(u8, agent_id);
    if (project_id) |value| {
        ctx.project_id = try runtime_registry.allocator.dupe(u8, value);
    }
    if (project_token) |value| {
        ctx.project_token = try runtime_registry.allocator.dupe(u8, value);
    }

    const ThreadMain = struct {
        fn run(thread_ctx: *Context) void {
            defer thread_ctx.deinit();
            const resolved_binding_key = thread_ctx.binding_key orelse return;
            const resolved_agent_id = thread_ctx.agent_id orelse return;
            thread_ctx.runtime_registry.runRuntimeWarmupThread(
                resolved_binding_key,
                resolved_agent_id,
                thread_ctx.project_id,
                thread_ctx.project_token,
            );
        }
    };

    const thread = try std.Thread.spawn(.{}, ThreadMain.run, .{ctx});
    thread.detach();
}
