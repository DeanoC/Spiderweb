const std = @import("std");

/// MCP JSON-RPC 2.0 client over stdio.
///
/// Manages a child MCP server process, sends JSON-RPC requests on its stdin
/// and reads newline-delimited JSON-RPC responses from its stdout.
pub const McpClient = struct {
    allocator: std.mem.Allocator,
    command: []const u8,
    args: []const []const u8,
    next_id: u64 = 1,
    child: ?std.process.Child = null,
    /// Buffer for reading child stdout lines.
    stdout_buf: std.ArrayListUnmanaged(u8) = .{},
    server_capabilities: ?[]u8 = null,
    /// Populated when sendRequest returns error.McpRpcError; freed on next call or deinit.
    last_rpc_error: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        command: []const u8,
        args: []const []const u8,
    ) McpClient {
        return .{
            .allocator = allocator,
            .command = command,
            .args = args,
        };
    }

    pub fn deinit(self: *McpClient) void {
        self.shutdown();
        self.stdout_buf.deinit(self.allocator);
        if (self.server_capabilities) |cap| self.allocator.free(cap);
        if (self.last_rpc_error) |msg| self.allocator.free(msg);
    }

    /// Spawn the MCP server subprocess and perform the initialize handshake.
    pub fn connect(self: *McpClient) !void {
        if (self.child != null) return error.AlreadyConnected;

        var argv = std.ArrayListUnmanaged([]const u8){};
        defer argv.deinit(self.allocator);
        try argv.append(self.allocator, self.command);
        for (self.args) |arg| try argv.append(self.allocator, arg);

        var child = std.process.Child.init(argv.items, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        // Inherit stderr so MCP server log output goes to the bridge's stderr
        // rather than filling a pipe buffer and causing the child to deadlock.
        child.stderr_behavior = .Inherit;
        try child.spawn();
        self.child = child;

        // Send initialize request.
        const init_result = try self.sendRequest(
            "initialize",
            "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"spider-mcp-venom\",\"version\":\"1\"}}",
        );
        defer self.allocator.free(init_result);

        // Store server capabilities.
        if (self.server_capabilities) |old| self.allocator.free(old);
        self.server_capabilities = try self.allocator.dupe(u8, init_result);

        // Send initialized notification (no id, no response expected).
        try self.sendNotification("notifications/initialized", "{}");
    }

    /// List tools exposed by the MCP server.
    /// Returns owned JSON string of the result object.
    pub fn listTools(self: *McpClient) ![]u8 {
        return self.sendRequest("tools/list", "{}");
    }

    /// Call a tool on the MCP server.
    /// `tool_name` is the MCP tool name, `arguments_json` is the JSON object of args.
    /// Returns owned JSON string of the result object.
    pub fn callTool(self: *McpClient, tool_name: []const u8, arguments_json: []const u8) ![]u8 {
        var params = std.ArrayListUnmanaged(u8){};
        defer params.deinit(self.allocator);
        try params.appendSlice(self.allocator, "{\"name\":\"");
        try appendJsonEscaped(self.allocator, &params, tool_name);
        try params.appendSlice(self.allocator, "\",\"arguments\":");
        if (arguments_json.len == 0 or std.mem.eql(u8, arguments_json, "null")) {
            try params.appendSlice(self.allocator, "{}");
        } else {
            try params.appendSlice(self.allocator, arguments_json);
        }
        try params.append(self.allocator, '}');
        return self.sendRequest("tools/call", params.items);
    }

    /// List resources exposed by the MCP server.
    pub fn listResources(self: *McpClient) ![]u8 {
        return self.sendRequest("resources/list", "{}");
    }

    /// Read a resource by URI.
    pub fn readResource(self: *McpClient, uri: []const u8) ![]u8 {
        var params = std.ArrayListUnmanaged(u8){};
        defer params.deinit(self.allocator);
        try params.appendSlice(self.allocator, "{\"uri\":\"");
        try appendJsonEscaped(self.allocator, &params, uri);
        try params.appendSlice(self.allocator, "\"}");
        return self.sendRequest("resources/read", params.items);
    }

    /// Shut down the MCP server subprocess.
    pub fn shutdown(self: *McpClient) void {
        if (self.child) |*child| {
            // Close stdin to signal EOF to the server.
            if (child.stdin) |stdin| {
                stdin.close();
                child.stdin = null;
            }
            // Kill the child to ensure it exits promptly, then reap it.
            // Many MCP servers do not exit on stdin EOF, so we must not
            // rely on them doing so — an indefinite wait would hang the
            // one-shot bridge process.
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            if (child.stdout) |stdout| {
                stdout.close();
                child.stdout = null;
            }
            self.child = null;
        }
    }

    /// Check if the child process is still alive.
    pub fn isAlive(self: *McpClient) bool {
        if (self.child == null) return false;
        // If we can get the stdin pipe, the process is likely still running.
        return self.child.?.stdin != null;
    }

    // --- Internal ---

    fn sendRequest(self: *McpClient, method: []const u8, params_json: []const u8) ![]u8 {
        const id = self.next_id;
        self.next_id +%= 1;

        var req = std.ArrayListUnmanaged(u8){};
        defer req.deinit(self.allocator);
        try req.writer(self.allocator).print(
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}\n",
            .{ id, method, params_json },
        );

        const child = &(self.child orelse return error.NotConnected);
        const stdin = child.stdin orelse return error.NotConnected;
        try stdin.writeAll(req.items);

        // Read response lines until we find one matching our id.
        return self.readResponseForId(id);
    }

    fn sendNotification(self: *McpClient, method: []const u8, params_json: []const u8) !void {
        var req = std.ArrayListUnmanaged(u8){};
        defer req.deinit(self.allocator);
        try req.writer(self.allocator).print(
            "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}\n",
            .{ method, params_json },
        );

        const child = &(self.child orelse return error.NotConnected);
        const stdin = child.stdin orelse return error.NotConnected;
        try stdin.writeAll(req.items);
    }

    fn readResponseForId(self: *McpClient, expected_id: u64) ![]u8 {
        const child = &(self.child orelse return error.NotConnected);
        const stdout = child.stdout orelse return error.NotConnected;

        // Use a stack buffer for the reader; streamDelimiter handles lines
        // longer than the buffer by streaming in chunks into the writer.
        var read_buf: [4096]u8 = undefined;
        var file_reader = stdout.readerStreaming(&read_buf);
        const reader = &file_reader.interface;

        // Read lines until we find a response with matching id.
        // Skip notifications (messages without id).
        var attempts: u32 = 0;
        while (attempts < 1000) : (attempts += 1) {
            // Accumulate line bytes via an allocating writer so that lines
            // longer than the read buffer are handled correctly.
            var line_aw: std.Io.Writer.Allocating = .init(self.allocator);
            _ = reader.streamDelimiter(&line_aw.writer, '\n') catch |err| {
                line_aw.deinit();
                return switch (err) {
                    error.EndOfStream => error.McpServerClosed,
                    else => err,
                };
            };
            // Consume the '\n' delimiter left in the reader buffer.
            reader.toss(1);
            const line_owned = line_aw.toOwnedSlice() catch |err| {
                line_aw.deinit();
                return err;
            };
            defer self.allocator.free(line_owned);
            const line = std.mem.trim(u8, line_owned, " \t\r\n");
            if (line.len == 0) continue;

            // Parse to check if this is our response.
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const obj = parsed.value.object;

            // Skip notifications (no "id" field).
            const id_value = obj.get("id") orelse continue;
            const msg_id: u64 = switch (id_value) {
                .integer => |i| if (i >= 0) @intCast(i) else continue,
                .float => |f| if (f >= 0) @intFromFloat(f) else continue,
                else => continue,
            };
            if (msg_id != expected_id) continue;

            // JSON-RPC error response: surface as an error so callers report ok=false.
            if (obj.get("error")) |err_value| {
                if (self.last_rpc_error) |old| self.allocator.free(old);
                self.last_rpc_error = std.fmt.allocPrint(
                    self.allocator,
                    "{f}",
                    .{std.json.fmt(err_value, .{})},
                ) catch null;
                return error.McpRpcError;
            }

            // Extract "result" field.
            if (obj.get("result")) |result_value| {
                return std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(result_value, .{})});
            }

            // Response without result or error — return the full line.
            return self.allocator.dupe(u8, line);
        }

        return error.McpResponseTimeout;
    }
};

fn appendJsonEscaped(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    try list.writer(allocator).print("\\u{x:0>4}", .{c});
                } else {
                    try list.append(allocator, c);
                }
            },
        }
    }
}

// --- Tests ---

test "mcp_client: json escape handles special characters" {
    const allocator = std.testing.allocator;
    var list = std.ArrayListUnmanaged(u8){};
    defer list.deinit(allocator);
    try appendJsonEscaped(allocator, &list, "hello \"world\"\nnewline\\back");
    try std.testing.expectEqualStrings("hello \\\"world\\\"\\nnewline\\\\back", list.items);
}

test "mcp_client: json escape handles control characters" {
    const allocator = std.testing.allocator;
    var list = std.ArrayListUnmanaged(u8){};
    defer list.deinit(allocator);
    try appendJsonEscaped(allocator, &list, "\x00\x1f");
    try std.testing.expectEqualStrings("\\u0000\\u001f", list.items);
}

test "mcp_client: init stores config" {
    var client = McpClient.init(std.testing.allocator, "echo", &.{"hello"});
    defer client.deinit();
    try std.testing.expectEqualStrings("echo", client.command);
    try std.testing.expectEqual(@as(usize, 1), client.args.len);
    try std.testing.expect(!client.isAlive());
}
