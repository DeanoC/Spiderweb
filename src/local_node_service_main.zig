const std = @import("std");
const unified = @import("spider-protocol").unified;
const tool_executor = @import("ziggy-tool-runtime").tool_executor;
const tool_registry = @import("ziggy-tool-runtime").tool_registry;
const git_venom = @import("venoms/git.zig");
const terminal_venom = @import("venoms/terminal.zig");

const workspace_world_prefix = "/nodes/local/fs";
const max_payload_bytes: usize = 1024 * 1024;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);
    if (argv.len < 3) return error.InvalidArguments;

    const mode = argv[1];
    const export_root = argv[2];
    if (!std.fs.path.isAbsolute(export_root)) return error.InvalidArguments;

    // The supervised local-node child uses a simple one-shot stdio contract:
    // stdin is exactly one raw JSON request blob up to max_payload_bytes, and
    // stdout is exactly one raw JSON response blob. There is no extra framing,
    // length prefix, or record delimiter beyond EOF on stdin.
    const payload = try std.fs.File.stdin().readToEndAlloc(allocator, max_payload_bytes);
    defer allocator.free(payload);

    const result_json = dispatchInvocation(allocator, mode, export_root, payload) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => try renderTopLevelFailure(allocator, mode, @errorName(err)),
    };
    defer allocator.free(result_json);

    try std.fs.File.stdout().writeAll(result_json);
}

fn dispatchInvocation(
    allocator: std.mem.Allocator,
    mode: []const u8,
    export_root: []const u8,
    payload: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, mode, "terminal")) return handleTerminalInvocation(allocator, export_root, payload);
    if (std.mem.eql(u8, mode, "git")) return handleGitInvocation(allocator, export_root, payload);
    if (std.mem.eql(u8, mode, "search_code")) return handleSearchCodeInvocation(allocator, export_root, payload);
    return error.InvalidArguments;
}

fn renderTopLevelFailure(
    allocator: std.mem.Allocator,
    mode: []const u8,
    code: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, mode, "git")) {
        var ctx = GitDriverContext{
            .allocator = allocator,
            .export_root = "",
        };
        return ctx.buildGitFailureResultJson(.status, "execution_failed", code);
    }
    if (std.mem.eql(u8, mode, "search_code")) {
        return buildWrappedFailureJson(allocator, "execution_failed", code);
    }
    return buildTerminalFailureJson(allocator, "exec", "launch_failed", code);
}

fn handleTerminalInvocation(
    allocator: std.mem.Allocator,
    export_root: []const u8,
    payload: []const u8,
) ![]u8 {
    var parsed = try parsePayloadObject(allocator, payload);
    defer parsed.deinit();

    const root = parsed.value.object;
    const args_obj = if (root.get("arguments")) |value|
        if (value == .object) value.object else return error.InvalidPayload
    else
        root;

    const operation = jsonObjectOptionalString(args_obj, "op") orelse
        jsonObjectOptionalString(args_obj, "operation") orelse
        jsonObjectOptionalString(root, "op") orelse
        jsonObjectOptionalString(root, "operation") orelse
        "exec";
    if (!std.mem.eql(u8, operation, "exec")) return buildTerminalFailureJson(allocator, operation, "invalid_operation", "only exec is supported");

    const command = if (jsonObjectOptionalString(args_obj, "command")) |value|
        try allocator.dupe(u8, value)
    else if (args_obj.get("argv")) |argv_value|
        try buildCommandFromArgv(allocator, argv_value)
    else
        return buildTerminalFailureJson(allocator, operation, "invalid_payload", "missing command or argv");
    defer allocator.free(command);

    const cwd_relative = if (jsonObjectOptionalString(args_obj, "cwd")) |value|
        try workspacePathToRelative(allocator, value)
    else
        null;
    defer if (cwd_relative) |value| allocator.free(value);

    const timeout_ms = jsonObjectOptionalU64(args_obj, "timeout_ms") orelse 30_000;
    var result = try withExportRootToolResult(
        allocator,
        export_root,
        shellExecTool,
        .{
            .command = command,
            .cwd_relative = cwd_relative,
            .timeout_ms = timeout_ms,
        },
    );
    defer result.deinit(allocator);

    return switch (result) {
        .success => |success| renderTerminalResultJson(allocator, operation, success.payload_json),
        .failure => |failure| buildTerminalFailureJson(
            allocator,
            operation,
            toolErrorCodeName(failure.code),
            failure.message,
        ),
    };
}

fn handleSearchCodeInvocation(
    allocator: std.mem.Allocator,
    export_root: []const u8,
    payload: []const u8,
) ![]u8 {
    var parsed = try parsePayloadObject(allocator, payload);
    defer parsed.deinit();

    const root = parsed.value.object;
    const args_obj = if (root.get("arguments")) |value|
        if (value == .object) value.object else return error.InvalidPayload
    else
        root;

    const query = jsonObjectOptionalString(args_obj, "query") orelse
        jsonObjectOptionalString(args_obj, "pattern") orelse
        return buildWrappedFailureJson(allocator, "invalid_payload", "missing query");
    const path_relative = if (jsonObjectOptionalString(args_obj, "path")) |value|
        workspacePathToRelative(allocator, value) catch
            return buildWrappedFailureJson(allocator, "invalid_payload", "path must stay within /nodes/local/fs")
    else
        try allocator.dupe(u8, ".");
    defer allocator.free(path_relative);
    const case_sensitive = jsonObjectStrictOptionalBool(args_obj, "case_sensitive") catch
        return buildWrappedFailureJson(allocator, "invalid_payload", "case_sensitive must be boolean");
    const max_results = jsonObjectStrictOptionalU64(args_obj, "max_results") catch
        return buildWrappedFailureJson(allocator, "invalid_payload", "max_results must be non-negative integer");

    var result = try withExportRootToolResult(
        allocator,
        export_root,
        searchCodeTool,
        .{
            .query = query,
            .path_relative = path_relative,
            .case_sensitive = case_sensitive orelse false,
            .max_results = max_results orelse 200,
        },
    );
    defer result.deinit(allocator);

    return switch (result) {
        .success => |success| buildWrappedSuccessJson(allocator, success.payload_json),
        .failure => |failure| buildWrappedFailureJson(
            allocator,
            toolErrorCodeName(failure.code),
            failure.message,
        ),
    };
}

fn handleGitInvocation(
    allocator: std.mem.Allocator,
    export_root: []const u8,
    payload: []const u8,
) ![]u8 {
    var parsed = try parsePayloadObject(allocator, payload);
    defer parsed.deinit();
    const root = parsed.value.object;
    const args_obj = if (root.get("arguments")) |value|
        if (value == .object) value.object else return error.InvalidPayload
    else
        root;

    const op = inferGitOp(root, args_obj);
    var ctx = GitDriverContext{
        .allocator = allocator,
        .export_root = export_root,
    };
    return git_venom.executeOpPayload(&ctx, op, args_obj);
}

fn inferGitOp(root: std.json.ObjectMap, args_obj: std.json.ObjectMap) git_venom.Op {
    if (jsonObjectOptionalString(root, "op")) |value| {
        if (git_venom.parseOp(value)) |op| return op;
    }
    if (jsonObjectOptionalString(root, "operation")) |value| {
        if (git_venom.parseOp(value)) |op| return op;
    }
    if (jsonObjectOptionalString(root, "tool_name")) |value| {
        if (git_venom.parseOp(value)) |op| return op;
    }
    if (jsonObjectOptionalString(args_obj, "op")) |value| {
        if (git_venom.parseOp(value)) |op| return op;
    }
    if (jsonObjectOptionalString(args_obj, "operation")) |value| {
        if (git_venom.parseOp(value)) |op| return op;
    }
    if (jsonObjectOptionalString(args_obj, "repo_key") != null or
        jsonObjectOptionalString(args_obj, "repo_url") != null or
        jsonObjectOptionalString(args_obj, "head_branch") != null or
        jsonObjectOptionalString(args_obj, "head_sha") != null or
        jsonObjectOptionalU64(args_obj, "pr_number") != null)
    {
        return .sync_checkout;
    }
    if (jsonObjectOptionalString(args_obj, "head_ref") != null or
        jsonObjectOptionalBool(args_obj, "symmetric") != null)
    {
        return .diff_range;
    }
    return .status;
}

const GitFailureInfo = struct {
    code: []u8,
    message: []u8,

    fn deinit(self: *GitFailureInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.message);
        self.* = undefined;
    }
};

const GitDriverContext = struct {
    allocator: std.mem.Allocator,
    export_root: []const u8,

    const ShellExecOutcome = union(enum) {
        success: git_venom.ParsedShellExecResult,
        failure: GitFailureInfo,

        pub fn deinit(self: *ShellExecOutcome, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .success => |*value| value.deinit(allocator),
                .failure => |*value| value.deinit(allocator),
            }
            self.* = undefined;
        }
    };

    pub fn appendShellSingleQuoted(self: *GitDriverContext, out: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
        return terminal_venom.appendShellSingleQuoted(self, out, value);
    }

    pub fn buildCliCommand(self: *GitDriverContext, program: []const u8, argv: []const []const u8) ![]u8 {
        return git_venom.buildCliCommand(self, program, argv);
    }

    pub fn normalizeLocalWorkspaceAbsolutePath(self: *GitDriverContext, raw_path: []const u8) ![]u8 {
        const trimmed = std.mem.trim(u8, raw_path, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidPayload;
        if (std.mem.startsWith(u8, trimmed, "/")) {
            if (!pathMatchesPrefixBoundary(trimmed, workspace_world_prefix)) return error.InvalidPayload;
            const relative = try normalizeToolRelativePath(self.allocator, trimmed[workspace_world_prefix.len..]);
            defer self.allocator.free(relative);
            if (std.mem.eql(u8, relative, ".")) return self.allocator.dupe(u8, workspace_world_prefix);
            return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ workspace_world_prefix, relative });
        }

        const normalized_relative = try normalizeToolRelativePath(self.allocator, trimmed);
        defer self.allocator.free(normalized_relative);
        if (std.mem.eql(u8, normalized_relative, ".")) return self.allocator.dupe(u8, workspace_world_prefix);
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ workspace_world_prefix, normalized_relative });
    }

    pub fn resolveWorkspaceHostPath(self: *GitDriverContext, absolute_path: []const u8) ![]u8 {
        if (!pathMatchesPrefixBoundary(absolute_path, workspace_world_prefix)) return error.InvalidPayload;
        if (std.mem.eql(u8, absolute_path, workspace_world_prefix)) {
            return self.allocator.dupe(u8, self.export_root);
        }
        const relative = std.mem.trimLeft(u8, absolute_path[workspace_world_prefix.len..], "/");
        if (relative.len == 0) return self.allocator.dupe(u8, self.export_root);
        return std.fs.path.join(self.allocator, &.{ self.export_root, relative });
    }

    pub fn runShellExecCommand(
        self: *GitDriverContext,
        command: []const u8,
        cwd: ?[]const u8,
        timeout_ms: u64,
    ) !ShellExecOutcome {
        const cwd_relative = if (cwd) |value|
            try hostOrWorldPathToRelative(self.allocator, self.export_root, value)
        else
            null;
        defer if (cwd_relative) |value| self.allocator.free(value);

        var result = try withExportRootToolResult(
            self.allocator,
            self.export_root,
            shellExecTool,
            .{
                .command = command,
                .cwd_relative = cwd_relative,
                .timeout_ms = timeout_ms,
            },
        );
        defer result.deinit(self.allocator);

        return switch (result) {
            .success => |success| .{ .success = try git_venom.parseShellExecPayload(self, success.payload_json) },
            .failure => |failure| .{ .failure = .{
                .code = try self.allocator.dupe(u8, toolErrorCodeName(failure.code)),
                .message = try self.allocator.dupe(u8, failure.message),
            } },
        };
    }

    pub fn buildGitSuccessResultJson(self: *GitDriverContext, op: git_venom.Op, result_json: []const u8) ![]u8 {
        return git_venom.buildGitSuccessResultJson(self, op, result_json);
    }

    pub fn buildGitFailureResultJson(
        self: *GitDriverContext,
        op: git_venom.Op,
        code: []const u8,
        message: []const u8,
    ) ![]u8 {
        return git_venom.buildGitFailureResultJson(self, op, code, message);
    }
};

const ShellExecToolArgs = struct {
    command: []const u8,
    cwd_relative: ?[]const u8,
    timeout_ms: u64,
};

const SearchCodeToolArgs = struct {
    query: []const u8,
    path_relative: []const u8,
    case_sensitive: bool,
    max_results: u64,
};

fn shellExecTool(allocator: std.mem.Allocator, input: anytype) !tool_registry.ToolExecutionResult {
    const escaped_command = try unified.jsonEscape(allocator, input.command);
    defer allocator.free(escaped_command);
    const cwd_json = if (input.cwd_relative) |value| blk: {
        const escaped_cwd = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped_cwd);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped_cwd});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(cwd_json);

    const args_json = try std.fmt.allocPrint(
        allocator,
        "{{\"command\":\"{s}\",\"cwd\":{s},\"timeout_ms\":{d}}}",
        .{ escaped_command, cwd_json, input.timeout_ms },
    );
    defer allocator.free(args_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    return tool_executor.BuiltinTools.shellExec(allocator, parsed.value.object);
}

fn searchCodeTool(allocator: std.mem.Allocator, input: anytype) !tool_registry.ToolExecutionResult {
    const escaped_query = try unified.jsonEscape(allocator, input.query);
    defer allocator.free(escaped_query);
    const escaped_path = try unified.jsonEscape(allocator, input.path_relative);
    defer allocator.free(escaped_path);
    const args_json = try std.fmt.allocPrint(
        allocator,
        "{{\"query\":\"{s}\",\"path\":\"{s}\",\"case_sensitive\":{s},\"max_results\":{d}}}",
        .{
            escaped_query,
            escaped_path,
            if (input.case_sensitive) "true" else "false",
            input.max_results,
        },
    );
    defer allocator.free(args_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    return tool_executor.BuiltinTools.searchCode(allocator, parsed.value.object);
}

fn withExportRootToolResult(
    allocator: std.mem.Allocator,
    export_root: []const u8,
    comptime ToolFn: anytype,
    input: anytype,
) !tool_registry.ToolExecutionResult {
    const original_cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(original_cwd);
    try std.process.changeCurDir(export_root);
    defer std.process.changeCurDir(original_cwd) catch {};
    return ToolFn(allocator, input);
}

fn renderTerminalResultJson(
    allocator: std.mem.Allocator,
    operation: []const u8,
    payload_json: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;

    const exit_code = if (parsed.value.object.get("exit_code")) |value|
        switch (value) {
            .integer => value.integer,
            else => -1,
        }
    else
        -1;
    const stdout = if (parsed.value.object.get("stdout")) |value|
        if (value == .string) value.string else ""
    else
        "";
    const stderr = if (parsed.value.object.get("stderr")) |value|
        if (value == .string) value.string else ""
    else
        "";

    const escaped_operation = try unified.jsonEscape(allocator, operation);
    defer allocator.free(escaped_operation);
    const escaped_stdout = try unified.jsonEscape(allocator, stdout);
    defer allocator.free(escaped_stdout);
    const escaped_stderr = try unified.jsonEscape(allocator, stderr);
    defer allocator.free(escaped_stderr);

    return std.fmt.allocPrint(
        allocator,
        "{{\"service\":\"terminal\",\"operation\":\"{s}\",\"ok\":{s},\"state\":\"{s}\",\"exit_code\":{d},\"stdout\":\"{s}\",\"stderr\":\"{s}\"}}",
        .{
            escaped_operation,
            if (exit_code == 0) "true" else "false",
            if (exit_code == 0) "exited" else "error",
            exit_code,
            escaped_stdout,
            escaped_stderr,
        },
    );
}

fn buildTerminalFailureJson(
    allocator: std.mem.Allocator,
    operation: []const u8,
    state: []const u8,
    message: []const u8,
) ![]u8 {
    const escaped_operation = try unified.jsonEscape(allocator, operation);
    defer allocator.free(escaped_operation);
    const escaped_state = try unified.jsonEscape(allocator, state);
    defer allocator.free(escaped_state);
    const escaped_message = try unified.jsonEscape(allocator, message);
    defer allocator.free(escaped_message);
    return std.fmt.allocPrint(
        allocator,
        "{{\"service\":\"terminal\",\"operation\":\"{s}\",\"ok\":false,\"state\":\"{s}\",\"exit_code\":-1,\"stdout\":\"\",\"stderr\":\"{s}\"}}",
        .{ escaped_operation, escaped_state, escaped_message },
    );
}

fn buildWrappedSuccessJson(allocator: std.mem.Allocator, result_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"ok\":true,\"result\":{s},\"error\":null}}", .{result_json});
}

fn buildWrappedFailureJson(
    allocator: std.mem.Allocator,
    code: []const u8,
    message: []const u8,
) ![]u8 {
    const escaped_code = try unified.jsonEscape(allocator, code);
    defer allocator.free(escaped_code);
    const escaped_message = try unified.jsonEscape(allocator, message);
    defer allocator.free(escaped_message);
    return std.fmt.allocPrint(
        allocator,
        "{{\"ok\":false,\"result\":null,\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}",
        .{ escaped_code, escaped_message },
    );
}

fn parsePayloadObject(allocator: std.mem.Allocator, payload: []const u8) !std.json.Parsed(std.json.Value) {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidPayload;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    if (parsed.value != .object) {
        parsed.deinit();
        return error.InvalidPayload;
    }
    return parsed;
}

fn buildCommandFromArgv(allocator: std.mem.Allocator, argv_value: std.json.Value) ![]u8 {
    if (argv_value != .array or argv_value.array.items.len == 0) return error.InvalidPayload;
    var builder = CommandBuilder{ .allocator = allocator };
    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(allocator);
    for (argv_value.array.items) |item| {
        if (item != .string or item.string.len == 0) return error.InvalidPayload;
        try argv.append(allocator, item.string);
    }
    return git_venom.buildCliCommand(&builder, argv.items[0], argv.items[1..]);
}

const CommandBuilder = struct {
    allocator: std.mem.Allocator,

    pub fn appendShellSingleQuoted(self: *CommandBuilder, out: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
        return terminal_venom.appendShellSingleQuoted(self, out, value);
    }
};

fn workspacePathToRelative(allocator: std.mem.Allocator, raw_path: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw_path, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, ".");
    if (!std.mem.startsWith(u8, trimmed, "/")) return normalizeToolRelativePath(allocator, trimmed);
    if (!pathMatchesPrefixBoundary(trimmed, workspace_world_prefix)) return error.InvalidPayload;
    return normalizeToolRelativePath(allocator, trimmed[workspace_world_prefix.len..]);
}

fn hostOrWorldPathToRelative(
    allocator: std.mem.Allocator,
    export_root: []const u8,
    raw_path: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, raw_path, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, ".");
    if (!std.mem.startsWith(u8, trimmed, "/")) return normalizeToolRelativePath(allocator, trimmed);
    if (pathMatchesPrefixBoundary(trimmed, workspace_world_prefix)) return workspacePathToRelative(allocator, trimmed);
    if (!pathMatchesPrefixBoundary(trimmed, export_root)) return error.InvalidPayload;
    return normalizeToolRelativePath(allocator, trimmed[export_root.len..]);
}

fn normalizeToolRelativePath(allocator: std.mem.Allocator, raw_path: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw_path, " \t\r\n/");
    if (trimmed.len == 0) return allocator.dupe(u8, ".");

    var normalized = std.ArrayListUnmanaged(u8){};
    errdefer normalized.deinit(allocator);

    var segments = std.mem.tokenizeScalar(u8, trimmed, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) return error.InvalidPayload;
        if (normalized.items.len != 0) try normalized.append(allocator, '/');
        try normalized.appendSlice(allocator, segment);
    }

    if (normalized.items.len == 0) return allocator.dupe(u8, ".");
    return normalized.toOwnedSlice(allocator);
}

fn pathMatchesPrefixBoundary(path: []const u8, prefix: []const u8) bool {
    const normalized_prefix = if (prefix.len > 1)
        std.mem.trimRight(u8, prefix, "/")
    else
        prefix;
    if (std.mem.eql(u8, path, normalized_prefix)) return true;
    if (normalized_prefix.len == 0) return false;
    if (!std.mem.startsWith(u8, path, normalized_prefix)) return false;
    return path.len > normalized_prefix.len and path[normalized_prefix.len] == '/';
}

fn jsonObjectOptionalString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn jsonObjectOptionalBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    if (value != .bool) return null;
    return value.bool;
}

fn jsonObjectOptionalU64(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = obj.get(key) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

fn jsonObjectStrictOptionalBool(obj: std.json.ObjectMap, key: []const u8) !?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => value.bool,
        .null => null,
        else => error.InvalidPayload,
    };
}

fn jsonObjectStrictOptionalU64(obj: std.json.ObjectMap, key: []const u8) !?u64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => if (value.integer < 0) error.InvalidPayload else @intCast(value.integer),
        .null => null,
        else => error.InvalidPayload,
    };
}

fn toolErrorCodeName(code: tool_registry.ToolErrorCode) []const u8 {
    return @tagName(code);
}

test "local_node_service_main: workspace-relative paths reject parent traversal" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidPayload, workspacePathToRelative(allocator, "../.."));
    try std.testing.expectError(error.InvalidPayload, workspacePathToRelative(allocator, "/nodes/local/fs/../.."));
    try std.testing.expectError(error.InvalidPayload, hostOrWorldPathToRelative(allocator, "/workspace", "/workspace/../.."));
}

test "local_node_service_main: slash-terminated export roots still match child paths" {
    try std.testing.expect(pathMatchesPrefixBoundary("/workspace/repo", "/workspace/"));
    try std.testing.expect(pathMatchesPrefixBoundary("/nodes/local/fs/repo", "/nodes/local/fs/"));
}

test "local_node_service_main: search_code invocation returns wrapped matches" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("export/src");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "export/src/example.txt",
        .data = "alpha\nTODO: search me\nomega\n",
    });

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const export_root = try std.fs.path.join(allocator, &.{ root, "export" });
    defer allocator.free(export_root);

    const result_json = try handleSearchCodeInvocation(
        allocator,
        export_root,
        "{\"query\":\"TODO\",\"path\":\"/nodes/local/fs/src\",\"case_sensitive\":true,\"max_results\":10}",
    );
    defer allocator.free(result_json);

    try std.testing.expect(std.mem.indexOf(u8, result_json, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result_json, "\"path\":\"src\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result_json, "\"query\":\"TODO\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result_json, "\"count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result_json, "example.txt:2:TODO: search me") != null);
}

test "local_node_service_main: search_code invocation rejects invalid payload fields" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("export");

    const root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const export_root = try std.fs.path.join(allocator, &.{ root, "export" });
    defer allocator.free(export_root);

    const bad_path_result = try handleSearchCodeInvocation(
        allocator,
        export_root,
        "{\"query\":\"TODO\",\"path\":\"/nodes/local/fs/../outside\"}",
    );
    defer allocator.free(bad_path_result);
    try std.testing.expect(std.mem.indexOf(u8, bad_path_result, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_path_result, "\"code\":\"invalid_payload\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_path_result, "path must stay within /nodes/local/fs") != null);

    const bad_max_result = try handleSearchCodeInvocation(
        allocator,
        export_root,
        "{\"query\":\"TODO\",\"max_results\":\"many\"}",
    );
    defer allocator.free(bad_max_result);
    try std.testing.expect(std.mem.indexOf(u8, bad_max_result, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_max_result, "\"code\":\"invalid_payload\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_max_result, "max_results must be non-negative integer") != null);
}
