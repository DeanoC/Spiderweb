const std = @import("std");
const mcp_client = @import("venoms/mcp_client.zig");

const max_payload_bytes: usize = 4 * 1024 * 1024;

/// One-shot MCP bridge process.
///
/// Usage: spiderweb-mcp-bridge -- <mcp-command> [mcp-args...]
///
/// Reads a JSON invocation payload from stdin, spawns an MCP server subprocess,
/// performs the requested operation, and writes the JSON result to stdout.
///
/// Payload format:
///   {"op": "tools/call", "tool": "read_file", "arguments": {"path": "/tmp/x"}}
///   {"op": "tools/list"}
///   {"op": "resources/list"}
///   {"op": "resources/read", "uri": "file:///tmp/x"}
///
/// If "op" is omitted, defaults to "tools/call".
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    // Find the "--" separator; everything after it is the MCP server command.
    const separator_idx = findSeparator(argv) orelse {
        try writeError("usage: spiderweb-mcp-bridge -- <mcp-command> [mcp-args...]");
        return;
    };
    if (separator_idx + 1 >= argv.len) {
        try writeError("missing MCP server command after --");
        return;
    }

    const mcp_command = argv[separator_idx + 1];
    const mcp_args = if (separator_idx + 2 < argv.len) argv[separator_idx + 2 ..] else &[_][:0]const u8{};

    // Read the invocation payload from stdin.
    const payload = std.fs.File.stdin().readToEndAlloc(allocator, max_payload_bytes) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "failed to read stdin: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        try writeError(msg);
        return;
    };
    defer allocator.free(payload);

    // Dispatch.
    const result_json = dispatch(allocator, mcp_command, mcp_args, payload) catch |err| {
        try writeErrorJson(allocator, @errorName(err));
        return;
    };
    defer allocator.free(result_json);

    try std.fs.File.stdout().writeAll(result_json);
}

fn dispatch(
    allocator: std.mem.Allocator,
    mcp_command: []const u8,
    mcp_args: []const []const u8,
    payload: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");

    // Parse payload to determine operation.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, if (trimmed.len > 0) trimmed else "{}", .{}) catch
        return buildResultError(allocator, "invalid_payload", "payload is not valid JSON");
    defer parsed.deinit();
    if (parsed.value != .object)
        return buildResultError(allocator, "invalid_payload", "payload must be a JSON object");

    const obj = parsed.value.object;
    const op = getOptionalString(obj, "op") orelse getOptionalString(obj, "operation") orelse "tools/call";

    // Connect to MCP server.
    var client = mcp_client.McpClient.init(allocator, mcp_command, mcp_args);
    defer client.deinit();
    client.connect() catch |err|
        return buildResultError(allocator, "mcp_connect_failed", @errorName(err));

    // Dispatch based on operation.
    if (std.mem.eql(u8, op, "tools/call")) {
        return handleToolsCall(allocator, &client, obj);
    } else if (std.mem.eql(u8, op, "tools/list")) {
        return handleToolsList(allocator, &client);
    } else if (std.mem.eql(u8, op, "resources/list")) {
        return handleResourcesList(allocator, &client);
    } else if (std.mem.eql(u8, op, "resources/read")) {
        return handleResourcesRead(allocator, &client, obj);
    } else {
        return buildResultError(allocator, "unknown_operation", op);
    }
}

/// Return the JSON-RPC error detail from the client if available, else fall back
/// to the Zig error name.  The returned slice is valid until the next client call.
fn mcpErrorMessage(client: *mcp_client.McpClient, err: anyerror) []const u8 {
    if (err == error.McpRpcError) {
        if (client.last_rpc_error) |msg| return msg;
    }
    return @errorName(err);
}

fn handleToolsCall(
    allocator: std.mem.Allocator,
    client: *mcp_client.McpClient,
    obj: std.json.ObjectMap,
) ![]u8 {
    const tool_name = getOptionalString(obj, "tool") orelse getOptionalString(obj, "tool_name") orelse getOptionalString(obj, "name") orelse
        return buildResultError(allocator, "invalid_payload", "missing 'tool' field");

    const arguments_json = if (obj.get("arguments")) |args_value|
        try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(args_value, .{})})
    else
        try allocator.dupe(u8, "{}");
    defer allocator.free(arguments_json);

    const mcp_result = client.callTool(tool_name, arguments_json) catch |err|
        return buildResultError(allocator, "mcp_call_failed", mcpErrorMessage(client, err));
    defer allocator.free(mcp_result);

    return buildResultOk(allocator, "tools/call", tool_name, mcp_result);
}

fn handleToolsList(
    allocator: std.mem.Allocator,
    client: *mcp_client.McpClient,
) ![]u8 {
    const mcp_result = client.listTools() catch |err|
        return buildResultError(allocator, "mcp_list_failed", mcpErrorMessage(client, err));
    defer allocator.free(mcp_result);

    return buildResultOk(allocator, "tools/list", null, mcp_result);
}

fn handleResourcesList(
    allocator: std.mem.Allocator,
    client: *mcp_client.McpClient,
) ![]u8 {
    const mcp_result = client.listResources() catch |err|
        return buildResultError(allocator, "mcp_list_failed", mcpErrorMessage(client, err));
    defer allocator.free(mcp_result);

    return buildResultOk(allocator, "resources/list", null, mcp_result);
}

fn handleResourcesRead(
    allocator: std.mem.Allocator,
    client: *mcp_client.McpClient,
    obj: std.json.ObjectMap,
) ![]u8 {
    const uri = getOptionalString(obj, "uri") orelse
        return buildResultError(allocator, "invalid_payload", "missing 'uri' field");

    const mcp_result = client.readResource(uri) catch |err|
        return buildResultError(allocator, "mcp_read_failed", mcpErrorMessage(client, err));
    defer allocator.free(mcp_result);

    return buildResultOk(allocator, "resources/read", null, mcp_result);
}

// --- Result Builders ---

fn buildResultOk(
    allocator: std.mem.Allocator,
    op: []const u8,
    tool_name: ?[]const u8,
    result_json: []const u8,
) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"ok\":true,\"operation\":\"");
    try out.appendSlice(allocator, op);
    try out.append(allocator, '"');
    if (tool_name) |name| {
        try out.appendSlice(allocator, ",\"tool\":\"");
        try appendJsonEscaped(allocator, &out, name);
        try out.append(allocator, '"');
    }
    try out.appendSlice(allocator, ",\"result\":");
    try out.appendSlice(allocator, result_json);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn buildResultError(
    allocator: std.mem.Allocator,
    code: []const u8,
    message: []const u8,
) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"ok\":false,\"error\":{\"code\":\"");
    try appendJsonEscaped(allocator, &out, code);
    try out.appendSlice(allocator, "\",\"message\":\"");
    try appendJsonEscaped(allocator, &out, message);
    try out.appendSlice(allocator, "\"}}");
    return out.toOwnedSlice(allocator);
}

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

fn writeError(message: []const u8) !void {
    try std.fs.File.stderr().writeAll(message);
    try std.fs.File.stderr().writeAll("\n");
}

fn writeErrorJson(allocator: std.mem.Allocator, code: []const u8) !void {
    const json = try buildResultError(allocator, code, "internal error");
    defer allocator.free(json);
    try std.fs.File.stdout().writeAll(json);
}

fn getOptionalString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |value| {
        if (value == .string and value.string.len > 0) return value.string;
    }
    return null;
}

fn findSeparator(argv: []const [:0]const u8) ?usize {
    for (argv, 0..) |arg, idx| {
        if (std.mem.eql(u8, arg, "--")) return idx;
    }
    return null;
}

// --- Tests ---

test "mcp_bridge: buildResultOk formats correctly" {
    const allocator = std.testing.allocator;
    const result = try buildResultOk(allocator, "tools/call", "read_file", "{\"content\":\"hello\"}");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"tool\":\"read_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"result\":{\"content\":\"hello\"}") != null);
}

test "mcp_bridge: buildResultError formats correctly" {
    const allocator = std.testing.allocator;
    const result = try buildResultError(allocator, "test_code", "test message");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"code\":\"test_code\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"message\":\"test message\"") != null);
}

test "mcp_bridge: buildResultOk without tool_name" {
    const allocator = std.testing.allocator;
    const result = try buildResultOk(allocator, "tools/list", null, "{\"tools\":[]}");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"tool\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"operation\":\"tools/list\"") != null);
}
