const builtin = @import("builtin");
const std = @import("std");
const mount_provider = @import("spiderweb_mount_provider");
const namespace_client_mod = @import("namespace_client.zig");

// Spiderweb workspace mounts must reflect the server-owned namespace exactly.
// This provider mirrors the FSKit client model: cache the mount graph, walk it
// incrementally, and resolve project-local binds through Spiderweb control.
// Do not add client-side routing shortcuts or bypasses here.
const synthetic_statfs_json =
    "{\"bsize\":65536,\"frsize\":65536,\"blocks\":1,\"bfree\":1,\"bavail\":1,\"files\":1048576,\"ffree\":1048575,\"favail\":1048575,\"namemax\":4096}";
const mount_graph_cache_ttl_ms: i64 = 5_000;
const mount_graph_initial_snapshot_depth: u32 = 1;

const MountGraphNodeKind = enum {
    synthetic_directory,
    synthetic_file,
    alias,
    export_root,
};

const SyntheticContentMode = enum {
    inline_snapshot,
    delta_snapshot,
    remote_read,
    remote_rw,
    write_only_command,
};

const MountGraphSource = struct {
    id: []const u8,
    mount_path: []const u8,
    fs_url: []const u8,
    export_name: ?[]const u8 = null,
};

const MountGraphNode = struct {
    id: u64,
    parent_id: ?u64 = null,
    name: []const u8,
    path: []const u8,
    kind: MountGraphNodeKind,
    mode: u32,
    writable: bool,
    size: u64,
    canonical_node_id: ?u64 = null,
    content_mode: ?SyntheticContentMode = null,
    inline_content_b64: ?[]const u8 = null,
    source_id: ?[]const u8 = null,
};

const MountGraphSnapshot = struct {
    mount_session_id: []const u8,
    graph_generation: u64,
    root_node_id: u64,
    nodes: []MountGraphNode,
    sources: []MountGraphSource,
};

const MountFileReadPayload = struct {
    path: []const u8,
    offset: u64,
    n: u32,
    eof: bool,
    data_b64: []const u8,
};

const OwnedMountGraphNode = struct {
    id: u64,
    parent_id: ?u64 = null,
    name: []u8,
    path: []u8,
    kind: MountGraphNodeKind,
    mode: u32,
    writable: bool,
    size: u64,
    canonical_node_id: ?u64 = null,
    content_mode: ?SyntheticContentMode = null,
    inline_content_b64: ?[]u8 = null,
    source_id: ?[]u8 = null,

    fn deinit(self: *OwnedMountGraphNode, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        if (self.inline_content_b64) |value| allocator.free(value);
        if (self.source_id) |value| allocator.free(value);
        self.* = undefined;
    }
};

const MountGraphCache = struct {
    graph_generation: u64 = 0,
    fetched_at_ms: i64 = 0,
    nodes: std.ArrayListUnmanaged(OwnedMountGraphNode) = .{},
    path_index: std.StringHashMapUnmanaged(usize) = .{},
    id_index: std.AutoHashMapUnmanaged(u64, usize) = .{},
    loaded_directory_depths: std.StringHashMapUnmanaged(u32) = .{},

    fn deinit(self: *MountGraphCache, allocator: std.mem.Allocator) void {
        self.clearAllNodes(allocator);
        self.path_index.deinit(allocator);
        self.id_index.deinit(allocator);
        self.clearLoadedDirectoryDepths(allocator);
        self.loaded_directory_depths.deinit(allocator);
        self.* = .{};
    }

    fn isFresh(self: *const MountGraphCache) bool {
        if (self.nodes.items.len == 0 or self.fetched_at_ms == 0) return false;
        return (std.time.milliTimestamp() - self.fetched_at_ms) < mount_graph_cache_ttl_ms;
    }

    fn markStale(self: *MountGraphCache) void {
        self.fetched_at_ms = 0;
    }

    fn hasFreshDirectoryDepth(self: *const MountGraphCache, path: []const u8, minimum_depth: u32) bool {
        if (!self.isFresh()) return false;
        const normalized_path = normalizeAbsolutePath(path);
        const existing_depth = self.loaded_directory_depths.get(normalized_path) orelse 0;
        return existing_depth >= minimum_depth;
    }

    fn replaceWithSnapshot(
        self: *MountGraphCache,
        allocator: std.mem.Allocator,
        snapshot: MountGraphSnapshot,
        scope_path: []const u8,
        depth: u32,
        replace_all: bool,
    ) !void {
        const normalized_scope_path = normalizeAbsolutePath(scope_path);
        if (replace_all) {
            self.clearAllNodes(allocator);
            self.clearLoadedDirectoryDepths(allocator);
            for (snapshot.nodes) |node| {
                const normalized_node_path = normalizeAbsolutePath(node.path);
                try self.nodes.append(allocator, .{
                    .id = node.id,
                    .parent_id = node.parent_id,
                    .name = try allocator.dupe(u8, node.name),
                    .path = try allocator.dupe(u8, normalized_node_path),
                    .kind = node.kind,
                    .mode = node.mode,
                    .writable = node.writable,
                    .size = node.size,
                    .canonical_node_id = node.canonical_node_id,
                    .content_mode = node.content_mode,
                    .inline_content_b64 = if (node.inline_content_b64) |value| try allocator.dupe(u8, value) else null,
                    .source_id = if (node.source_id) |value| try allocator.dupe(u8, value) else null,
                });
            }
            try self.rebuildIndexes(allocator);
            try self.markLoadedDirectoryDepths(allocator, normalized_scope_path, depth);
            self.graph_generation = snapshot.graph_generation;
            self.fetched_at_ms = std.time.milliTimestamp();
            return;
        }

        try self.removeSubtree(allocator, normalized_scope_path);
        self.removeLoadedDepthEntries(allocator, normalized_scope_path);
        try self.rebuildIndexes(allocator);

        var merged_id_remap = std.AutoHashMapUnmanaged(u64, u64){};
        defer merged_id_remap.deinit(allocator);
        var next_merge_id = self.nextMergedNodeId();

        for (snapshot.nodes) |node| {
            const normalized_node_path = normalizeAbsolutePath(node.path);
            const in_scope = pathMatchesPrefixBoundary(normalized_node_path, normalized_scope_path);
            if (!in_scope) {
                if (self.lookupPath(normalized_node_path)) |existing| {
                    try merged_id_remap.put(allocator, node.id, existing.id);
                    continue;
                }
            }

            const merged_parent_id = if (node.parent_id) |parent_id|
                merged_id_remap.get(parent_id) orelse node.parent_id
            else
                null;

            const merged_id = next_merge_id;
            next_merge_id += 1;
            try self.nodes.append(allocator, .{
                .id = merged_id,
                .parent_id = merged_parent_id,
                .name = try allocator.dupe(u8, node.name),
                .path = try allocator.dupe(u8, normalized_node_path),
                .kind = node.kind,
                .mode = node.mode,
                .writable = node.writable,
                .size = node.size,
                .canonical_node_id = node.canonical_node_id,
                .content_mode = node.content_mode,
                .inline_content_b64 = if (node.inline_content_b64) |value| try allocator.dupe(u8, value) else null,
                .source_id = if (node.source_id) |value| try allocator.dupe(u8, value) else null,
            });
            try merged_id_remap.put(allocator, node.id, merged_id);
        }

        try self.rebuildIndexes(allocator);
        try self.markLoadedDirectoryDepths(allocator, normalized_scope_path, depth);
        self.graph_generation = snapshot.graph_generation;
        self.fetched_at_ms = std.time.milliTimestamp();
    }

    fn nextMergedNodeId(self: *const MountGraphCache) u64 {
        var next_id: u64 = 1;
        for (self.nodes.items) |node| {
            if (node.id >= next_id) next_id = node.id + 1;
        }
        return next_id;
    }

    fn lookupPath(self: *const MountGraphCache, path: []const u8) ?*const OwnedMountGraphNode {
        const index = self.path_index.get(normalizeAbsolutePath(path)) orelse return null;
        return &self.nodes.items[index];
    }

    fn clearAllNodes(self: *MountGraphCache, allocator: std.mem.Allocator) void {
        for (self.nodes.items) |*node| node.deinit(allocator);
        self.nodes.clearRetainingCapacity();
        self.path_index.clearRetainingCapacity();
        self.id_index.clearRetainingCapacity();
    }

    fn clearLoadedDirectoryDepths(self: *MountGraphCache, allocator: std.mem.Allocator) void {
        var it = self.loaded_directory_depths.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        self.loaded_directory_depths.clearRetainingCapacity();
    }

    fn removeSubtree(self: *MountGraphCache, allocator: std.mem.Allocator, scope_path: []const u8) !void {
        var retained = std.ArrayListUnmanaged(OwnedMountGraphNode){};
        errdefer {
            for (retained.items) |*node| node.deinit(allocator);
            retained.deinit(allocator);
        }

        for (self.nodes.items) |*node| {
            if (pathMatchesPrefixBoundary(normalizeAbsolutePath(node.path), normalizeAbsolutePath(scope_path))) {
                node.deinit(allocator);
                continue;
            }
            try retained.append(allocator, node.*);
            node.* = undefined;
        }

        self.nodes.deinit(allocator);
        self.nodes = retained;
        self.path_index.clearRetainingCapacity();
        self.id_index.clearRetainingCapacity();
    }

    fn removeLoadedDepthEntries(self: *MountGraphCache, allocator: std.mem.Allocator, scope_path: []const u8) void {
        var removals = std.ArrayListUnmanaged([]const u8){};
        defer removals.deinit(allocator);

        var it = self.loaded_directory_depths.iterator();
        while (it.next()) |entry| {
            if (!pathMatchesPrefixBoundary(entry.key_ptr.*, normalizeAbsolutePath(scope_path))) continue;
            removals.append(allocator, entry.key_ptr.*) catch continue;
        }

        for (removals.items) |key| {
            if (self.loaded_directory_depths.fetchRemove(key)) |removed| {
                allocator.free(removed.key);
            }
        }
    }

    fn rebuildIndexes(self: *MountGraphCache, allocator: std.mem.Allocator) !void {
        self.path_index.clearRetainingCapacity();
        self.id_index.clearRetainingCapacity();
        for (self.nodes.items, 0..) |*node, idx| {
            try self.path_index.put(allocator, node.path, idx);
            try self.id_index.put(allocator, node.id, idx);
        }
    }

    fn markLoadedDirectoryDepths(self: *MountGraphCache, allocator: std.mem.Allocator, scope_path: []const u8, depth: u32) !void {
        if (depth == 0) return;

        for (self.nodes.items) |node| {
            if (!nodeIsDirectory(node)) continue;
            const normalized_path = normalizeAbsolutePath(node.path);
            const relative_depth = relativeMountGraphDepth(scope_path, normalized_path) orelse continue;
            if (relative_depth > depth) continue;
            if (relative_depth == depth and !std.mem.eql(u8, normalized_path, scope_path)) continue;

            const loaded_depth = depth - relative_depth;
            const existing_depth = self.loaded_directory_depths.get(normalized_path) orelse 0;
            if (existing_depth >= loaded_depth) continue;

            const owned_key = if (self.loaded_directory_depths.getKey(normalized_path)) |existing_key|
                existing_key
            else blk: {
                const duped = try allocator.dupe(u8, normalized_path);
                errdefer allocator.free(duped);
                try self.loaded_directory_depths.put(allocator, duped, loaded_depth);
                break :blk duped;
            };

            try self.loaded_directory_depths.put(allocator, owned_key, loaded_depth);
        }
    }
};

const BufferedHandleState = struct {
    bytes: std.ArrayListUnmanaged(u8) = .{},
    dirty: bool = false,
    created: bool = false,

    fn deinit(self: *BufferedHandleState, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.* = .{};
    }
};

const HandleBacking = union(enum) {
    @"inline": []u8,
    remote,
    buffered: BufferedHandleState,

    fn deinit(self: *HandleBacking, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .@"inline" => |bytes| allocator.free(bytes),
            .remote => {},
            .buffered => |*buffered| buffered.deinit(allocator),
        }
        self.* = undefined;
    }
};

const HandleState = struct {
    path: []u8,
    node_id: u64,
    flags: u32,
    writable: bool,
    backing: HandleBacking,
    lock_held: bool = false,

    fn deinit(self: *HandleState, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.backing.deinit(allocator);
        self.* = undefined;
    }
};

const NamespaceProviderContext = struct {
    client: *namespace_client_mod.NamespaceClient,
    mount_graph: MountGraphCache = .{},
    next_handle_id: u64 = 1,
    open_handles: std.AutoHashMapUnmanaged(u64, HandleState) = .{},
    mutex: std.Thread.Mutex = .{},

    fn deinit(self: *NamespaceProviderContext, allocator: std.mem.Allocator) void {
        var it = self.open_handles.valueIterator();
        while (it.next()) |state| state.deinit(allocator);
        self.open_handles.deinit(allocator);
        self.mount_graph.deinit(allocator);
        allocator.destroy(self);
    }

    fn lookupNode(self: *NamespaceProviderContext, allocator: std.mem.Allocator, path: []const u8) !*const OwnedMountGraphNode {
        return self.resolveMountGraphNode(allocator, path);
    }

    fn ensureDirectoryNode(self: *NamespaceProviderContext, allocator: std.mem.Allocator, path: []const u8) !*const OwnedMountGraphNode {
        const node = try self.lookupNode(allocator, path);
        if (!nodeIsDirectory(node.*)) return error.NotDirectory;
        return node;
    }

    fn requestSnapshot(
        self: *NamespaceProviderContext,
        allocator: std.mem.Allocator,
        path: []const u8,
        depth: u32,
    ) !std.json.Parsed(MountGraphSnapshot) {
        const payload_json = try self.client.controlMountAttach(path, depth);
        defer allocator.free(payload_json);
        return std.json.parseFromSlice(
            MountGraphSnapshot,
            allocator,
            payload_json,
            .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            },
        );
    }

    fn ensureMountGraphLoaded(self: *NamespaceProviderContext, allocator: std.mem.Allocator) !void {
        if (self.mount_graph.isFresh()) return;
        try self.refreshMountGraph(allocator, "/", mount_graph_initial_snapshot_depth);
    }

    fn refreshMountGraph(self: *NamespaceProviderContext, allocator: std.mem.Allocator, path: []const u8, depth: u32) !void {
        var parsed = try self.requestSnapshot(allocator, path, depth);
        defer parsed.deinit();
        const normalized_path = normalizeAbsolutePath(path);
        try self.mount_graph.replaceWithSnapshot(
            allocator,
            parsed.value,
            normalized_path,
            depth,
            std.mem.eql(u8, normalized_path, "/"),
        );
    }

    fn ensureDirectoryChildrenLoaded(
        self: *NamespaceProviderContext,
        allocator: std.mem.Allocator,
        path: []const u8,
        minimum_depth: u32,
    ) !void {
        if (minimum_depth == 0) return;
        try self.ensureMountGraphLoaded(allocator);

        const normalized_path = normalizeAbsolutePath(path);
        const existing_depth = self.mount_graph.loaded_directory_depths.get(normalized_path) orelse 0;
        if (self.mount_graph.isFresh() and existing_depth >= minimum_depth) return;
        try self.refreshMountGraph(allocator, normalized_path, minimum_depth);
    }

    fn resolveMountGraphNode(self: *NamespaceProviderContext, allocator: std.mem.Allocator, path: []const u8) !*const OwnedMountGraphNode {
        try self.ensureMountGraphLoaded(allocator);

        const normalized_path = normalizeAbsolutePath(path);
        if (std.mem.eql(u8, normalized_path, "/")) {
            return self.mount_graph.lookupPath("/") orelse error.FileNotFound;
        }

        var current_path = std.ArrayListUnmanaged(u8){};
        defer current_path.deinit(allocator);

        var current_node = self.mount_graph.lookupPath("/") orelse return error.FileNotFound;
        var segment_it = std.mem.tokenizeScalar(u8, normalized_path[1..], '/');
        while (segment_it.next()) |segment| {
            const current_path_slice = if (current_path.items.len == 0) "/" else current_path.items;
            if (nodeIsDirectory(current_node.*)) {
                try self.ensureDirectoryChildrenLoaded(allocator, current_path_slice, 1);
                current_node = self.mount_graph.lookupPath(current_path_slice) orelse return error.FileNotFound;
            }

            if (current_path.items.len == 0) {
                try current_path.append(allocator, '/');
            } else {
                try current_path.append(allocator, '/');
            }
            try current_path.appendSlice(allocator, segment);

            current_node = self.mount_graph.lookupPath(current_path.items) orelse blk: {
                if (self.mount_graph.hasFreshDirectoryDepth(current_path_slice, 1)) {
                    return error.FileNotFound;
                }
                try self.refreshMountGraph(allocator, current_path_slice, 1);
                break :blk self.mount_graph.lookupPath(current_path.items) orelse return error.FileNotFound;
            };
        }

        return current_node;
    }

    fn reserveHandleId(self: *NamespaceProviderContext) u64 {
        const handle_id = self.next_handle_id;
        self.next_handle_id +%= 1;
        if (self.next_handle_id == 0) self.next_handle_id = 1;
        return handle_id;
    }

    fn storeHandle(self: *NamespaceProviderContext, allocator: std.mem.Allocator, state: HandleState) !mount_provider.OpenFile {
        const handle_id = self.reserveHandleId();
        try self.open_handles.put(allocator, handle_id, state);
        return .{
            .namespace = .{
                .handle_id = handle_id,
                .writable = state.writable,
            },
        };
    }

    fn getHandle(self: *NamespaceProviderContext, file: mount_provider.OpenFile) !*HandleState {
        const handle = switch (file) {
            .namespace => |value| value,
            else => return error.InvalidState,
        };
        return self.open_handles.getPtr(handle.handle_id) orelse error.InvalidState;
    }

    fn takeHandle(self: *NamespaceProviderContext, file: mount_provider.OpenFile) !HandleState {
        const handle = switch (file) {
            .namespace => |value| value,
            else => return error.InvalidState,
        };
        const removed = self.open_handles.fetchRemove(handle.handle_id) orelse return error.InvalidState;
        return removed.value;
    }

    fn flushBufferedHandle(self: *NamespaceProviderContext, state: *HandleState) !void {
        if (state.backing != .buffered) return;
        var buffered = &state.backing.buffered;
        if (!buffered.dirty and !buffered.created) return;
        _ = try self.client.controlMountFileWriteWithOptions(
            state.path,
            0,
            buffered.bytes.items,
            buffered.bytes.items.len,
        );
        self.mount_graph.markStale();
        buffered.dirty = false;
        buffered.created = false;
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    client: *namespace_client_mod.NamespaceClient,
) !mount_provider.Provider {
    const ctx = try allocator.create(NamespaceProviderContext);
    ctx.* = .{
        .client = client,
    };
    return .{
        .allocator = allocator,
        .ctx = ctx,
        .vtable = &namespace_provider_vtable,
    };
}

const namespace_provider_vtable: mount_provider.Provider.VTable = .{
    .deinit = namespaceProviderDeinit,
    .getattr = namespaceProviderGetattr,
    .readdir = namespaceProviderReaddir,
    .statfs = namespaceProviderStatfs,
    .open = namespaceProviderOpen,
    .read = namespaceProviderRead,
    .release = namespaceProviderRelease,
    .create = namespaceProviderCreate,
    .write = namespaceProviderWrite,
    .truncate = namespaceProviderTruncate,
    .unlink = namespaceProviderUnlink,
    .mkdir = namespaceProviderMkdir,
    .rmdir = namespaceProviderRmdir,
    .rename = namespaceProviderRename,
    .symlink = namespaceProviderSymlink,
    .setxattr = namespaceProviderSetxattr,
    .getxattr = namespaceProviderGetxattr,
    .listxattr = namespaceProviderListxattr,
    .removexattr = namespaceProviderRemovexattr,
    .lock = namespaceProviderLock,
    .try_keepalive_if_idle = namespaceProviderTryKeepAliveIfIdle,
};

fn asCtx(ctx: *anyopaque) *NamespaceProviderContext {
    return @ptrCast(@alignCast(ctx));
}

fn namespaceProviderDeinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    asCtx(ctx).deinit(allocator);
}

fn namespaceProviderGetattr(ctx: *anyopaque, path: []const u8) ![]u8 {
    const namespace_ctx = asCtx(ctx);
    namespace_ctx.mutex.lock();
    defer namespace_ctx.mutex.unlock();
    const allocator = namespace_ctx.client.allocator;
    const node = try namespace_ctx.lookupNode(allocator, path);
    return nodeAttrJson(allocator, node);
}

fn namespaceProviderReaddir(ctx: *anyopaque, path: []const u8, cookie: u64, max_entries: u32) ![]u8 {
    const namespace_ctx = asCtx(ctx);
    namespace_ctx.mutex.lock();
    defer namespace_ctx.mutex.unlock();
    const allocator = namespace_ctx.client.allocator;
    const normalized_path = normalizeAbsolutePath(path);
    _ = try namespace_ctx.ensureDirectoryNode(allocator, normalized_path);
    try namespace_ctx.ensureDirectoryChildrenLoaded(allocator, normalized_path, 1);
    const directory = try namespace_ctx.ensureDirectoryNode(allocator, normalized_path);

    var children = std.ArrayListUnmanaged(*const OwnedMountGraphNode){};
    defer children.deinit(allocator);
    for (namespace_ctx.mount_graph.nodes.items) |*node| {
        if (node.parent_id != null and node.parent_id.? == directory.id) {
            try children.append(allocator, node);
        }
    }
    std.mem.sort(*const OwnedMountGraphNode, children.items, {}, struct {
        fn lessThan(_: void, lhs: *const OwnedMountGraphNode, rhs: *const OwnedMountGraphNode) bool {
            return std.ascii.orderIgnoreCase(lhs.name, rhs.name) == .lt;
        }
    }.lessThan);

    const start_index = std.math.cast(usize, cookie) orelse return error.InvalidOffset;
    if (start_index >= children.items.len) {
        return allocator.dupe(u8, "{\"ents\":[],\"next\":0,\"eof\":true,\"dir_gen\":0}");
    }

    const max_count: usize = if (max_entries == 0) 0 else max_entries;
    const end_index = @min(children.items.len, start_index + max_count);
    const eof = end_index >= children.items.len;

    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"ents\":[");
    for (children.items[start_index..end_index], 0..) |child, idx| {
        if (idx != 0) try out.append(allocator, ',');
        const escaped_name = try jsonEscape(allocator, child.name);
        defer allocator.free(escaped_name);
        const attr_json = try nodeAttrJson(allocator, child.*);
        defer allocator.free(attr_json);
        try out.writer(allocator).print(
            "{{\"name\":\"{s}\",\"attr\":{s}}}",
            .{ escaped_name, attr_json },
        );
    }
    try out.writer(allocator).print(
        "],\"next\":{d},\"eof\":{s},\"dir_gen\":{d}}}",
        .{
            if (eof) @as(usize, 0) else end_index,
            if (eof) "true" else "false",
            namespace_ctx.mount_graph.graph_generation,
        },
    );
    return out.toOwnedSlice(allocator);
}

fn namespaceProviderStatfs(ctx: *anyopaque, path: []const u8) ![]u8 {
    _ = path;
    const namespace_ctx = asCtx(ctx);
    namespace_ctx.mutex.lock();
    defer namespace_ctx.mutex.unlock();
    return namespace_ctx.client.allocator.dupe(u8, synthetic_statfs_json);
}

fn namespaceProviderOpen(ctx: *anyopaque, path: []const u8, flags: u32) !mount_provider.OpenFile {
    const namespace_ctx = asCtx(ctx);
    namespace_ctx.mutex.lock();
    defer namespace_ctx.mutex.unlock();
    const allocator = namespace_ctx.client.allocator;
    const node = try namespace_ctx.lookupNode(allocator, path);
    const normalized_path = normalizeAbsolutePath(path);

    if (flagsRequireWrite(flags) and !node.writable) return error.ReadOnlyFilesystem;

    var backing: HandleBacking = if (nodeIsDirectory(node))
        .{ .@"inline" = try allocator.dupe(u8, "") }
    else if (node.content_mode != null and
        (node.content_mode.? == .inline_snapshot or node.content_mode.? == .delta_snapshot))
        .{ .@"inline" = try decodeInlineContent(allocator, node.inline_content_b64) }
    else
        .remote;

    if (flagsRequireWrite(flags) and hasTruncateOnOpen(flags) and !nodeIsDirectory(node.*)) {
        _ = try namespace_ctx.client.controlMountFileWriteWithOptions(
            normalized_path,
            0,
            "",
            0,
        );
        namespace_ctx.mount_graph.markStale();
        backing.deinit(allocator);
        backing = .{ .@"inline" = try allocator.dupe(u8, "") };
    }

    return namespace_ctx.storeHandle(allocator, .{
        .path = try allocator.dupe(u8, normalized_path),
        .node_id = node.id,
        .flags = flags,
        .writable = node.writable,
        .backing = backing,
    });
}

fn namespaceProviderRead(ctx: *anyopaque, file: mount_provider.OpenFile, off: u64, len: u32) ![]u8 {
    const namespace_ctx = asCtx(ctx);
    namespace_ctx.mutex.lock();
    defer namespace_ctx.mutex.unlock();
    const allocator = namespace_ctx.client.allocator;
    const state = try namespace_ctx.getHandle(file);

    return switch (state.backing) {
        .@"inline" => |bytes| readOwnedSlice(allocator, bytes, off, len),
        .buffered => |*buffered| readOwnedSlice(allocator, buffered.bytes.items, off, len),
        .remote => blk: {
            const payload_json = try namespace_ctx.client.controlMountFileRead(state.path, off, len);
            defer allocator.free(payload_json);
            break :blk try parseMountFileReadData(allocator, payload_json);
        },
    };
}

fn namespaceProviderRelease(ctx: *anyopaque, file: mount_provider.OpenFile) !void {
    const namespace_ctx = asCtx(ctx);
    namespace_ctx.mutex.lock();
    defer namespace_ctx.mutex.unlock();
    const allocator = namespace_ctx.client.allocator;
    var state = try namespace_ctx.takeHandle(file);
    defer state.deinit(allocator);
    try namespace_ctx.flushBufferedHandle(&state);
    if (state.lock_held) {
        namespace_ctx.client.controlMountPathLock(state.path, "unlock", true) catch {};
        state.lock_held = false;
    }
}

fn namespaceProviderCreate(ctx: *anyopaque, path: []const u8, mode: u32, flags: u32) !mount_provider.OpenFile {
    const namespace_ctx = asCtx(ctx);
    namespace_ctx.mutex.lock();
    defer namespace_ctx.mutex.unlock();
    const allocator = namespace_ctx.client.allocator;
    const normalized_path = normalizeAbsolutePath(path);
    const parent_path = parentPath(normalized_path);
    if (hasExclusiveCreate(flags)) {
        _ = namespace_ctx.lookupNode(allocator, normalized_path) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (namespace_ctx.mount_graph.lookupPath(normalized_path) != null) return error.AlreadyExists;
    }
    _ = try namespace_ctx.ensureDirectoryNode(allocator, parent_path);

    // Materialize an empty file immediately so follow-up path-based operations
    // on the just-created entry behave the same way as the other mount backends.
    _ = try namespace_ctx.client.controlMountFileWrite(normalized_path, 0, "");
    try namespace_ctx.client.controlMountPathSetattr(normalized_path, .{
        .mode = mode & 0o7777,
    });
    namespace_ctx.mount_graph.markStale();

    return namespace_ctx.storeHandle(allocator, .{
        .path = try allocator.dupe(u8, normalized_path),
        .node_id = 0,
        .flags = flags,
        .writable = true,
        .backing = .{
            .buffered = .{
                .dirty = false,
                .created = false,
            },
        },
    });
}

fn namespaceProviderWrite(ctx: *anyopaque, file: mount_provider.OpenFile, off: u64, data: []const u8) !u32 {
    const namespace_ctx = asCtx(ctx);
    namespace_ctx.mutex.lock();
    defer namespace_ctx.mutex.unlock();
    const state = try namespace_ctx.getHandle(file);
    if (!state.writable) return error.ReadOnlyFilesystem;
    return writeHandleStateLocked(namespace_ctx, state, off, data);
}

fn namespaceProviderTruncate(ctx: *anyopaque, path: []const u8, size: u64) !void {
    const namespace_ctx = asCtx(ctx);
    namespace_ctx.mutex.lock();
    defer namespace_ctx.mutex.unlock();
    const normalized_path = normalizeAbsolutePath(path);
    _ = try namespace_ctx.client.controlMountFileWriteWithOptions(
        normalized_path,
        0,
        "",
        size,
    );
    namespace_ctx.mount_graph.markStale();
}

fn namespaceProviderUnlink(ctx: *anyopaque, path: []const u8) !void {
    const namespace_ctx = asCtx(ctx);
    namespace_ctx.mutex.lock();
    defer namespace_ctx.mutex.unlock();
    try namespace_ctx.client.controlMountPathUnlink(path);
    namespace_ctx.mount_graph.markStale();
}

fn namespaceProviderMkdir(ctx: *anyopaque, path: []const u8) !void {
    const namespace_ctx = asCtx(ctx);
    namespace_ctx.mutex.lock();
    defer namespace_ctx.mutex.unlock();
    try namespace_ctx.client.controlMountPathMkdir(path);
    namespace_ctx.mount_graph.markStale();
}

fn namespaceProviderRmdir(ctx: *anyopaque, path: []const u8) !void {
    const namespace_ctx = asCtx(ctx);
    namespace_ctx.mutex.lock();
    defer namespace_ctx.mutex.unlock();
    try namespace_ctx.client.controlMountPathRmdir(path);
    namespace_ctx.mount_graph.markStale();
}

fn namespaceProviderRename(ctx: *anyopaque, old_path: []const u8, new_path: []const u8) !void {
    const namespace_ctx = asCtx(ctx);
    namespace_ctx.mutex.lock();
    defer namespace_ctx.mutex.unlock();
    try namespace_ctx.client.controlMountPathRename(old_path, new_path);
    namespace_ctx.mount_graph.markStale();
}

fn namespaceProviderSymlink(ctx: *anyopaque, target: []const u8, link_path: []const u8) !void {
    const namespace_ctx = asCtx(ctx);
    namespace_ctx.mutex.lock();
    defer namespace_ctx.mutex.unlock();
    try namespace_ctx.client.controlMountPathSymlink(target, link_path);
    namespace_ctx.mount_graph.markStale();
}

fn namespaceProviderSetxattr(ctx: *anyopaque, path: []const u8, name: []const u8, value: []const u8, flags: u32) !void {
    const namespace_ctx = asCtx(ctx);
    namespace_ctx.mutex.lock();
    defer namespace_ctx.mutex.unlock();
    try namespace_ctx.client.controlMountPathSetxattr(path, name, value, flags);
    namespace_ctx.mount_graph.markStale();
}

fn namespaceProviderGetxattr(ctx: *anyopaque, path: []const u8, name: []const u8) ![]u8 {
    const namespace_ctx = asCtx(ctx);
    namespace_ctx.mutex.lock();
    defer namespace_ctx.mutex.unlock();
    return namespace_ctx.client.controlMountPathGetxattr(path, name);
}

fn namespaceProviderListxattr(ctx: *anyopaque, path: []const u8) ![]u8 {
    const namespace_ctx = asCtx(ctx);
    namespace_ctx.mutex.lock();
    defer namespace_ctx.mutex.unlock();
    return namespace_ctx.client.controlMountPathListxattr(path);
}

fn namespaceProviderRemovexattr(ctx: *anyopaque, path: []const u8, name: []const u8) !void {
    const namespace_ctx = asCtx(ctx);
    namespace_ctx.mutex.lock();
    defer namespace_ctx.mutex.unlock();
    try namespace_ctx.client.controlMountPathRemovexattr(path, name);
    namespace_ctx.mount_graph.markStale();
}

fn namespaceProviderLock(ctx: *anyopaque, file: mount_provider.OpenFile, mode: mount_provider.LockMode, wait: bool) !void {
    const namespace_ctx = asCtx(ctx);
    namespace_ctx.mutex.lock();
    defer namespace_ctx.mutex.unlock();
    const state = try namespace_ctx.getHandle(file);
    const mode_name = switch (mode) {
        .shared => "shared",
        .exclusive => "exclusive",
        .unlock => "unlock",
    };
    try namespace_ctx.client.controlMountPathLock(state.path, mode_name, wait);
    state.lock_held = mode != .unlock;
}

fn namespaceProviderTryKeepAliveIfIdle(ctx: *anyopaque) !bool {
    const namespace_ctx = asCtx(ctx);
    namespace_ctx.mutex.lock();
    defer namespace_ctx.mutex.unlock();
    try namespace_ctx.client.keepActiveSessionAlive();
    return true;
}

fn parseMountFileReadData(allocator: std.mem.Allocator, payload_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(
        MountFileReadPayload,
        allocator,
        payload_json,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    return decodeBase64Owned(allocator, parsed.value.data_b64);
}

fn nodeAttrJson(allocator: std.mem.Allocator, node: anytype) ![]u8 {
    const now_ns = std.time.nanoTimestamp();
    const owner = currentProcessAttrOwner();
    const kind_code: u8 = if (nodeIsDirectory(node)) 2 else 1;
    const nlink: u32 = if (kind_code == 2) 2 else 1;
    return std.fmt.allocPrint(
        allocator,
        "{{\"id\":{d},\"k\":{d},\"m\":{d},\"n\":{d},\"u\":{d},\"g\":{d},\"sz\":{d},\"at\":{d},\"mt\":{d},\"ct\":{d},\"gen\":0}}",
        .{
            node.canonical_node_id orelse node.id,
            kind_code,
            effectiveMode(node),
            nlink,
            owner.uid,
            owner.gid,
            node.size,
            now_ns,
            now_ns,
            now_ns,
        },
    );
}

fn nodeIsDirectory(node: anytype) bool {
    if (node.kind == .synthetic_directory or node.kind == .export_root) return true;
    return (effectiveMode(node) & 0o170000) == 0o040000;
}

fn effectiveMode(node: anytype) u32 {
    if (node.mode != 0) return node.mode;
    return switch (node.kind) {
        .synthetic_directory, .export_root => 0o040755,
        else => 0o100644,
    };
}

fn normalizeAbsolutePath(path: []const u8) []const u8 {
    if (path.len == 0) return "/";
    if (path.len > 1 and path[path.len - 1] == '/') return std.mem.trimRight(u8, path, "/");
    return path;
}

fn parentPath(path: []const u8) []const u8 {
    const normalized = normalizeAbsolutePath(path);
    if (std.mem.eql(u8, normalized, "/")) return "/";
    const slash_index = std.mem.lastIndexOfScalar(u8, normalized, '/') orelse return "/";
    if (slash_index == 0) return "/";
    return normalized[0..slash_index];
}

fn pathMatchesPrefixBoundary(path: []const u8, prefix: []const u8) bool {
    const normalized_path = normalizeAbsolutePath(path);
    const normalized_prefix = normalizeAbsolutePath(prefix);
    if (std.mem.eql(u8, normalized_path, normalized_prefix)) return true;
    if (!std.mem.startsWith(u8, normalized_path, normalized_prefix)) return false;
    if (std.mem.eql(u8, normalized_prefix, "/")) return normalized_path.len > 1;
    return normalized_path.len > normalized_prefix.len and normalized_path[normalized_prefix.len] == '/';
}

fn relativeMountGraphDepth(scope_path: []const u8, path: []const u8) ?u32 {
    const normalized_scope = normalizeAbsolutePath(scope_path);
    const normalized_path = normalizeAbsolutePath(path);
    if (std.mem.eql(u8, normalized_scope, normalized_path)) return 0;
    if (!pathMatchesPrefixBoundary(normalized_path, normalized_scope)) return null;

    const suffix = if (std.mem.eql(u8, normalized_scope, "/"))
        normalized_path[1..]
    else
        normalized_path[normalized_scope.len + 1 ..];
    if (suffix.len == 0) return 0;

    var depth: u32 = 1;
    for (suffix) |ch| {
        if (ch == '/') depth += 1;
    }
    return depth;
}

fn readOwnedSlice(allocator: std.mem.Allocator, bytes: []const u8, off: u64, len: u32) ![]u8 {
    const start = std.math.cast(usize, off) orelse return error.InvalidOffset;
    if (start >= bytes.len) return allocator.dupe(u8, "");
    const end = @min(bytes.len, start + len);
    return allocator.dupe(u8, bytes[start..end]);
}

fn decodeInlineContent(allocator: std.mem.Allocator, inline_content_b64: ?[]const u8) ![]u8 {
    const value = inline_content_b64 orelse return allocator.dupe(u8, "");
    return decodeBase64Owned(allocator, value);
}

fn decodeBase64Owned(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, encoded);
    return decoded;
}

fn writeHandleStateLocked(
    namespace_ctx: *NamespaceProviderContext,
    state: *HandleState,
    off: u64,
    data: []const u8,
) !u32 {
    return switch (state.backing) {
        .remote => blk: {
            const written = try namespace_ctx.client.controlMountFileWrite(state.path, off, data);
            namespace_ctx.mount_graph.markStale();
            break :blk written;
        },
        .@"inline" => {
            var buffered = BufferedHandleState{
                .dirty = false,
                .created = false,
            };
            try buffered.bytes.appendSlice(namespace_ctx.client.allocator, state.backing.@"inline");
            state.backing.deinit(namespace_ctx.client.allocator);
            state.backing = .{ .buffered = buffered };
            return writeHandleStateLocked(namespace_ctx, state, off, data);
        },
        .buffered => |*buffered| {
            try writeIntoBuffer(namespace_ctx.client.allocator, buffered, off, data);
            return std.math.cast(u32, data.len) orelse error.InvalidPayload;
        },
    };
}

fn writeIntoBuffer(
    allocator: std.mem.Allocator,
    buffered: *BufferedHandleState,
    off: u64,
    data: []const u8,
) !void {
    const base_offset = std.math.cast(usize, off) orelse return error.InvalidOffset;
    const write_end = std.math.add(usize, base_offset, data.len) catch return error.InvalidOffset;
    if (write_end > buffered.bytes.items.len) {
        const old_len = buffered.bytes.items.len;
        try buffered.bytes.resize(allocator, write_end);
        @memset(buffered.bytes.items[old_len..], 0);
    }
    if (data.len > 0) {
        @memcpy(buffered.bytes.items[base_offset..write_end], data);
    }
    buffered.dirty = true;
}

fn flagsRequireWrite(flags: u32) bool {
    return (flags & 0x3) != 0;
}

fn hasTruncateOnOpen(flags: u32) bool {
    return (flags & 0x200) != 0 or (flags & 0x400) != 0;
}

fn hasExclusiveCreate(flags: u32) bool {
    return (flags & 0x80) != 0 or (flags & 0x800) != 0;
}

fn currentProcessAttrOwner() struct { uid: u32, gid: u32 } {
    return switch (builtin.os.tag) {
        .linux => .{ .uid = @intCast(std.os.linux.getuid()), .gid = @intCast(std.os.linux.getgid()) },
        else => .{ .uid = 0, .gid = 0 },
    };
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

test "namespace_mount_provider: scoped snapshot merges do not duplicate ancestor roots" {
    const allocator = std.testing.allocator;
    var cache = MountGraphCache{};
    defer cache.deinit(allocator);

    const initial_nodes = [_]MountGraphNode{
        .{
            .id = 100,
            .parent_id = 50,
            .name = "fs",
            .path = "/nodes/local/fs",
            .kind = .export_root,
            .mode = 0o040755,
            .writable = false,
            .size = 0,
        },
        .{
            .id = 101,
            .parent_id = 100,
            .name = "AGENTS.md",
            .path = "/nodes/local/fs/AGENTS.md",
            .kind = .synthetic_file,
            .mode = 0o100644,
            .writable = false,
            .size = 12,
        },
        .{
            .id = 102,
            .parent_id = 100,
            .name = "validate_game.py",
            .path = "/nodes/local/fs/validate_game.py",
            .kind = .synthetic_file,
            .mode = 0o100644,
            .writable = false,
            .size = 16,
        },
    };
    const initial_snapshot = MountGraphSnapshot{
        .mount_session_id = "mount-test",
        .graph_generation = 1,
        .root_node_id = 1,
        .nodes = initial_nodes[0..],
        .sources = &.{},
    };
    try cache.replaceWithSnapshot(allocator, initial_snapshot, "/nodes/local/fs", 1, true);

    const managed_root_nodes = [_]MountGraphNode{
        .{
            .id = 200,
            .parent_id = 60,
            .name = "fs",
            .path = "/nodes/local/fs",
            .kind = .export_root,
            .mode = 0o040755,
            .writable = false,
            .size = 0,
        },
        .{
            .id = 201,
            .parent_id = 200,
            .name = ".spiderweb",
            .path = "/nodes/local/fs/.spiderweb",
            .kind = .synthetic_directory,
            .mode = 0o040755,
            .writable = false,
            .size = 0,
        },
        .{
            .id = 202,
            .parent_id = 201,
            .name = "protocol.json",
            .path = "/nodes/local/fs/.spiderweb/protocol.json",
            .kind = .synthetic_file,
            .mode = 0o100644,
            .writable = false,
            .size = 32,
        },
    };
    const managed_root_snapshot = MountGraphSnapshot{
        .mount_session_id = "mount-test",
        .graph_generation = 2,
        .root_node_id = 1,
        .nodes = managed_root_nodes[0..],
        .sources = &.{},
    };
    try cache.replaceWithSnapshot(allocator, managed_root_snapshot, "/nodes/local/fs/.spiderweb", 1, false);

    const shared_data_nodes = [_]MountGraphNode{
        .{
            .id = 300,
            .parent_id = 70,
            .name = "fs",
            .path = "/nodes/local/fs",
            .kind = .export_root,
            .mode = 0o040755,
            .writable = false,
            .size = 0,
        },
        .{
            .id = 301,
            .parent_id = 300,
            .name = ".spiderweb",
            .path = "/nodes/local/fs/.spiderweb",
            .kind = .synthetic_directory,
            .mode = 0o040755,
            .writable = false,
            .size = 0,
        },
        .{
            .id = 302,
            .parent_id = 301,
            .name = "shared_data",
            .path = "/nodes/local/fs/.spiderweb/shared_data",
            .kind = .synthetic_directory,
            .mode = 0o040755,
            .writable = false,
            .size = 0,
        },
        .{
            .id = 303,
            .parent_id = 302,
            .name = "world_seed.json",
            .path = "/nodes/local/fs/.spiderweb/shared_data/world_seed.json",
            .kind = .synthetic_file,
            .mode = 0o100644,
            .writable = false,
            .size = 64,
        },
    };
    const shared_data_snapshot = MountGraphSnapshot{
        .mount_session_id = "mount-test",
        .graph_generation = 3,
        .root_node_id = 1,
        .nodes = shared_data_nodes[0..],
        .sources = &.{},
    };
    try cache.replaceWithSnapshot(allocator, shared_data_snapshot, "/nodes/local/fs/.spiderweb/shared_data", 1, false);

    var fs_root_count: usize = 0;
    for (cache.nodes.items) |node| {
        if (std.mem.eql(u8, node.path, "/nodes/local/fs")) fs_root_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), fs_root_count);

    const fs_root = cache.lookupPath("/nodes/local/fs") orelse return error.TestExpectedResponse;
    const managed_root = cache.lookupPath("/nodes/local/fs/.spiderweb") orelse return error.TestExpectedResponse;
    try std.testing.expectEqual(fs_root.id, managed_root.parent_id.?);

    var child_names = std.StringHashMapUnmanaged(void){};
    defer child_names.deinit(allocator);
    for (cache.nodes.items) |node| {
        if (node.parent_id == null or node.parent_id.? != fs_root.id) continue;
        try child_names.put(allocator, node.name, {});
    }

    try std.testing.expect(child_names.contains("AGENTS.md"));
    try std.testing.expect(child_names.contains("validate_game.py"));
    try std.testing.expect(child_names.contains(".spiderweb"));
}

test "namespace_mount_provider: recognizes truncate and exclusive flag variants" {
    try std.testing.expect(hasTruncateOnOpen(0x200));
    try std.testing.expect(hasTruncateOnOpen(0x400));
    try std.testing.expect(!hasTruncateOnOpen(0));

    try std.testing.expect(hasExclusiveCreate(0x80));
    try std.testing.expect(hasExclusiveCreate(0x800));
    try std.testing.expect(!hasExclusiveCreate(0));
}
