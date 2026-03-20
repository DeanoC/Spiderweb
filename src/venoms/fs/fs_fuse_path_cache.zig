const std = @import("std");

pub const FusePathCache = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    attr_map: std.StringHashMapUnmanaged(AttrEntry) = .{},
    dir_map: std.StringHashMapUnmanaged(DirEntry) = .{},
    negative_map: std.StringHashMapUnmanaged(i64) = .{},

    attr_ttl_ms: i64,
    dir_ttl_ms: i64,
    negative_ttl_ms: i64,

    max_attr_entries: usize = 4096,
    max_dir_entries: usize = 512,
    max_negative_entries: usize = 1024,

    const AttrEntry = struct {
        json: []u8,
        expires_at_ms: i64,
    };

    const DirEntry = struct {
        json: []u8,
        expires_at_ms: i64,
    };

    pub fn init(allocator: std.mem.Allocator, attr_ttl_ms: i64, dir_ttl_ms: i64, negative_ttl_ms: i64) FusePathCache {
        return .{
            .allocator = allocator,
            .attr_ttl_ms = attr_ttl_ms,
            .dir_ttl_ms = dir_ttl_ms,
            .negative_ttl_ms = negative_ttl_ms,
        };
    }

    pub fn deinit(self: *FusePathCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var attr_it = self.attr_map.iterator();
        while (attr_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.json);
        }
        self.attr_map.deinit(self.allocator);

        var dir_it = self.dir_map.iterator();
        while (dir_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.json);
        }
        self.dir_map.deinit(self.allocator);

        var neg_it = self.negative_map.iterator();
        while (neg_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.negative_map.deinit(self.allocator);
    }

    /// Returns an owned dupe of the cached attr JSON if fresh, or null. Caller must free.
    pub fn getAttr(self: *FusePathCache, path: []const u8, now_ms: i64) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = self.attr_map.get(path) orelse return null;
        if (entry.expires_at_ms < now_ms) return null;
        return self.allocator.dupe(u8, entry.json) catch null;
    }

    /// Stores an owned copy of json in the attr cache.
    pub fn putAttr(self: *FusePathCache, path: []const u8, json: []const u8, now_ms: i64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.evictExpiredIfOver(&self.attr_map, self.max_attr_entries, now_ms, true);

        const owned_json = try self.allocator.dupe(u8, json);
        errdefer self.allocator.free(owned_json);

        if (self.attr_map.getPtr(path)) |existing| {
            self.allocator.free(existing.json);
            existing.* = .{ .json = owned_json, .expires_at_ms = now_ms + self.attr_ttl_ms };
            return;
        }

        const owned_key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_key);
        try self.attr_map.put(self.allocator, owned_key, .{
            .json = owned_json,
            .expires_at_ms = now_ms + self.attr_ttl_ms,
        });
    }

    /// Returns an owned dupe of the cached dir listing JSON if fresh, or null. Caller must free.
    pub fn getDir(self: *FusePathCache, path: []const u8, cookie: u64, now_ms: i64) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = self.makeDirKey(path, cookie) catch return null;
        defer self.allocator.free(key);

        const entry = self.dir_map.get(key) orelse return null;
        if (entry.expires_at_ms < now_ms) return null;
        return self.allocator.dupe(u8, entry.json) catch null;
    }

    /// Stores an owned copy of json in the dir cache.
    pub fn putDir(self: *FusePathCache, path: []const u8, cookie: u64, json: []const u8, now_ms: i64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.evictExpiredIfOver(&self.dir_map, self.max_dir_entries, now_ms, true);

        const key = try self.makeDirKey(path, cookie);
        errdefer self.allocator.free(key);

        const owned_json = try self.allocator.dupe(u8, json);
        errdefer self.allocator.free(owned_json);

        if (self.dir_map.getPtr(key)) |existing| {
            self.allocator.free(existing.json);
            existing.* = .{ .json = owned_json, .expires_at_ms = now_ms + self.dir_ttl_ms };
            self.allocator.free(key);
            return;
        }

        try self.dir_map.put(self.allocator, key, .{
            .json = owned_json,
            .expires_at_ms = now_ms + self.dir_ttl_ms,
        });
    }

    /// Returns true if path has a fresh negative (ENOENT) entry.
    pub fn isNegative(self: *FusePathCache, path: []const u8, now_ms: i64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const expires = self.negative_map.get(path) orelse return false;
        return expires >= now_ms;
    }

    /// Records a negative (ENOENT) cache entry for path.
    pub fn putNegative(self: *FusePathCache, path: []const u8, now_ms: i64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.evictExpiredNegativeIfOver(now_ms);

        if (self.negative_map.getPtr(path)) |existing| {
            existing.* = now_ms + self.negative_ttl_ms;
            return;
        }

        const owned_key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_key);
        try self.negative_map.put(self.allocator, owned_key, now_ms + self.negative_ttl_ms);
    }

    /// Removes attr and negative entries for the given path.
    pub fn invalidatePath(self: *FusePathCache, path: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.invalidatePathLocked(path);
    }

    /// Removes dir listing entries where path is the directory being listed.
    pub fn invalidateChildren(self: *FusePathCache, path: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.invalidateChildrenLocked(path);
    }

    /// Invalidates path + parent directory's listings.
    pub fn invalidatePathAndParent(self: *FusePathCache, path: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.invalidatePathLocked(path);
        if (parentOf(path)) |parent| {
            self.invalidateChildrenLocked(parent);
        }
    }

    /// Removes all entries whose path starts with prefix.
    pub fn invalidateTree(self: *FusePathCache, prefix: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.removeMatchingKeys(&self.attr_map, prefix, true);
        self.removeMatchingKeys(&self.dir_map, prefix, true);
        self.removeMatchingNegativeKeys(prefix);
    }

    // --- internal helpers ---

    fn invalidatePathLocked(self: *FusePathCache, path: []const u8) void {
        if (self.attr_map.fetchRemove(path)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value.json);
        }
        if (self.negative_map.fetchRemove(path)) |removed| {
            self.allocator.free(removed.key);
        }
    }

    fn invalidateChildrenLocked(self: *FusePathCache, path: []const u8) void {
        // Dir cache keys are "path\x00cookie". Remove all entries whose path portion matches.
        var to_remove = std.ArrayListUnmanaged([]const u8){};
        defer to_remove.deinit(self.allocator);

        var it = self.dir_map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const path_part = dirKeyPath(key);
            if (std.mem.eql(u8, path_part, path)) {
                to_remove.append(self.allocator, key) catch continue;
            }
        }
        for (to_remove.items) |key| {
            if (self.dir_map.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
                self.allocator.free(removed.value.json);
            }
        }
    }

    fn removeMatchingKeys(self: *FusePathCache, map: anytype, prefix: []const u8, has_json: bool) void {
        var to_remove = std.ArrayListUnmanaged([]const u8){};
        defer to_remove.deinit(self.allocator);

        var it = map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const effective_path = if (has_json and @TypeOf(map.*) == std.StringHashMapUnmanaged(DirEntry))
                dirKeyPath(key)
            else
                key;
            if (std.mem.eql(u8, effective_path, prefix) or
                (effective_path.len > prefix.len and
                std.mem.startsWith(u8, effective_path, prefix) and
                (prefix.len == 1 or effective_path[prefix.len] == '/')))
            {
                to_remove.append(self.allocator, key) catch continue;
            }
        }
        for (to_remove.items) |key| {
            if (map.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
                if (has_json) self.allocator.free(removed.value.json);
            }
        }
    }

    fn removeMatchingNegativeKeys(self: *FusePathCache, prefix: []const u8) void {
        var to_remove = std.ArrayListUnmanaged([]const u8){};
        defer to_remove.deinit(self.allocator);

        var it = self.negative_map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key, prefix) or
                (key.len > prefix.len and
                std.mem.startsWith(u8, key, prefix) and
                (prefix.len == 1 or key[prefix.len] == '/')))
            {
                to_remove.append(self.allocator, key) catch continue;
            }
        }
        for (to_remove.items) |key| {
            if (self.negative_map.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
            }
        }
    }

    fn evictExpiredIfOver(self: *FusePathCache, map: anytype, max: usize, now_ms: i64, has_json: bool) void {
        if (map.count() < max) return;

        var to_remove = std.ArrayListUnmanaged([]const u8){};
        defer to_remove.deinit(self.allocator);

        var it = map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.expires_at_ms < now_ms) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (to_remove.items) |key| {
            if (map.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
                if (has_json) self.allocator.free(removed.value.json);
            }
        }

        // If still over cap after evicting expired, clear everything
        if (map.count() >= max) {
            var clear_it = map.iterator();
            while (clear_it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                if (has_json) self.allocator.free(entry.value_ptr.json);
            }
            map.clearRetainingCapacity();
        }
    }

    fn evictExpiredNegativeIfOver(self: *FusePathCache, now_ms: i64) void {
        if (self.negative_map.count() < self.max_negative_entries) return;

        var to_remove = std.ArrayListUnmanaged([]const u8){};
        defer to_remove.deinit(self.allocator);

        var it = self.negative_map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* < now_ms) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (to_remove.items) |key| {
            if (self.negative_map.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
            }
        }

        if (self.negative_map.count() >= self.max_negative_entries) {
            var clear_it = self.negative_map.iterator();
            while (clear_it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            self.negative_map.clearRetainingCapacity();
        }
    }

    fn makeDirKey(self: *FusePathCache, path: []const u8, cookie: u64) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}\x00{d}", .{ path, cookie });
    }

    fn dirKeyPath(key: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, key, 0)) |sep| {
            return key[0..sep];
        }
        return key;
    }

    fn parentOf(path: []const u8) ?[]const u8 {
        if (path.len <= 1) return null;
        const trimmed = if (path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
        if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |idx| {
            if (idx == 0) return "/";
            return trimmed[0..idx];
        }
        return null;
    }
};

// --- Tests ---

test "FusePathCache: attr cache respects TTL" {
    const allocator = std.testing.allocator;
    var cache = FusePathCache.init(allocator, 100, 100, 50);
    defer cache.deinit();

    try cache.putAttr("/file.txt", "{\"size\":42}", 1000);

    // Fresh
    const hit = cache.getAttr("/file.txt", 1050);
    try std.testing.expect(hit != null);
    allocator.free(hit.?);

    // Expired
    const miss = cache.getAttr("/file.txt", 1200);
    try std.testing.expect(miss == null);
}

test "FusePathCache: dir cache respects TTL" {
    const allocator = std.testing.allocator;
    var cache = FusePathCache.init(allocator, 100, 100, 50);
    defer cache.deinit();

    try cache.putDir("/dir", 0, "{\"ents\":[]}", 1000);

    const hit = cache.getDir("/dir", 0, 1050);
    try std.testing.expect(hit != null);
    allocator.free(hit.?);

    const miss = cache.getDir("/dir", 0, 1200);
    try std.testing.expect(miss == null);
}

test "FusePathCache: negative cache respects TTL" {
    const allocator = std.testing.allocator;
    var cache = FusePathCache.init(allocator, 100, 100, 50);
    defer cache.deinit();

    try cache.putNegative("/missing.txt", 1000);
    try std.testing.expect(cache.isNegative("/missing.txt", 1025));
    try std.testing.expect(!cache.isNegative("/missing.txt", 1100));
}

test "FusePathCache: invalidatePath removes attr and negative" {
    const allocator = std.testing.allocator;
    var cache = FusePathCache.init(allocator, 100, 100, 50);
    defer cache.deinit();

    try cache.putAttr("/file.txt", "{}", 1000);
    try cache.putNegative("/file.txt", 1000);

    cache.invalidatePath("/file.txt");

    try std.testing.expect(cache.getAttr("/file.txt", 1000) == null);
    try std.testing.expect(!cache.isNegative("/file.txt", 1000));
}

test "FusePathCache: invalidatePathAndParent clears parent dir listings" {
    const allocator = std.testing.allocator;
    var cache = FusePathCache.init(allocator, 100, 100, 50);
    defer cache.deinit();

    try cache.putDir("/parent", 0, "{\"ents\":[\"child\"]}", 1000);
    try cache.putAttr("/parent/child", "{}", 1000);

    cache.invalidatePathAndParent("/parent/child");

    // Child attr should be gone
    try std.testing.expect(cache.getAttr("/parent/child", 1000) == null);
    // Parent dir listing should be gone
    try std.testing.expect(cache.getDir("/parent", 0, 1000) == null);
}

test "FusePathCache: invalidateTree removes descendants" {
    const allocator = std.testing.allocator;
    var cache = FusePathCache.init(allocator, 100, 100, 50);
    defer cache.deinit();

    try cache.putAttr("/a", "{}", 1000);
    try cache.putAttr("/a/b", "{}", 1000);
    try cache.putAttr("/a/b/c", "{}", 1000);
    try cache.putAttr("/other", "{}", 1000);

    cache.invalidateTree("/a");

    try std.testing.expect(cache.getAttr("/a", 1000) == null);
    try std.testing.expect(cache.getAttr("/a/b", 1000) == null);
    try std.testing.expect(cache.getAttr("/a/b/c", 1000) == null);

    // /other should survive
    const other = cache.getAttr("/other", 1000);
    try std.testing.expect(other != null);
    allocator.free(other.?);
}

test "FusePathCache: parentOf" {
    try std.testing.expectEqualStrings("/", FusePathCache.parentOf("/file.txt").?);
    try std.testing.expectEqualStrings("/parent", FusePathCache.parentOf("/parent/child").?);
    try std.testing.expectEqualStrings("/a/b", FusePathCache.parentOf("/a/b/c").?);
    try std.testing.expect(FusePathCache.parentOf("/") == null);
}

test "FusePathCache: different cookies are different cache entries" {
    const allocator = std.testing.allocator;
    var cache = FusePathCache.init(allocator, 100, 100, 50);
    defer cache.deinit();

    try cache.putDir("/dir", 0, "{\"page\":0}", 1000);
    try cache.putDir("/dir", 100, "{\"page\":1}", 1000);

    const page0 = cache.getDir("/dir", 0, 1050).?;
    defer allocator.free(page0);
    try std.testing.expectEqualStrings("{\"page\":0}", page0);

    const page1 = cache.getDir("/dir", 100, 1050).?;
    defer allocator.free(page1);
    try std.testing.expectEqualStrings("{\"page\":1}", page1);
}
