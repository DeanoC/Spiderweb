const builtin = @import("builtin");
const std = @import("std");

pub const CredentialError = error{
    SecureStoreUnavailable,
    InvalidProvider,
    InvalidKey,
    StoreFailed,
    ClearFailed,
};

pub const Backend = enum {
    linux_secret_tool,
    macos_security,
    none,
};

const service_name = "spiderweb";

pub const SecretKind = enum {
    provider_api_key,
    mount_auth_token,
    remote_node_secret,
};

pub const CredentialStore = struct {
    allocator: std.mem.Allocator,
    backend: Backend,

    pub fn init(allocator: std.mem.Allocator) CredentialStore {
        return .{
            .allocator = allocator,
            .backend = detectBackend(allocator),
        };
    }

    pub fn backendName(self: CredentialStore) []const u8 {
        return switch (self.backend) {
            .linux_secret_tool => "linux-secret-tool",
            .macos_security => "macos-security",
            .none => "none",
        };
    }

    pub fn supportsSecureStorage(self: CredentialStore) bool {
        return self.backend != .none;
    }

    pub fn getProviderApiKey(self: CredentialStore, provider_name: []const u8) ?[]u8 {
        if (!isValidProvider(provider_name)) return null;
        return self.getSecret(.provider_api_key, provider_name);
    }

    pub fn setProviderApiKey(self: CredentialStore, provider_name: []const u8, api_key: []const u8) CredentialError!void {
        if (!isValidProvider(provider_name)) return CredentialError.InvalidProvider;
        return self.setSecret(.provider_api_key, provider_name, api_key);
    }

    pub fn clearProviderApiKey(self: CredentialStore, provider_name: []const u8) CredentialError!void {
        if (!isValidProvider(provider_name)) return CredentialError.InvalidProvider;
        return self.clearSecret(.provider_api_key, provider_name);
    }

    pub fn getMountAuthToken(self: CredentialStore, mount_id: []const u8) ?[]u8 {
        return self.getSecret(.mount_auth_token, mount_id);
    }

    pub fn setMountAuthToken(self: CredentialStore, mount_id: []const u8, auth_token: []const u8) CredentialError!void {
        return self.setSecret(.mount_auth_token, mount_id, auth_token);
    }

    pub fn clearMountAuthToken(self: CredentialStore, mount_id: []const u8) CredentialError!void {
        return self.clearSecret(.mount_auth_token, mount_id);
    }

    pub fn getRemoteNodeSecret(self: CredentialStore, node_id: []const u8) ?[]u8 {
        return self.getSecret(.remote_node_secret, node_id);
    }

    pub fn setRemoteNodeSecret(self: CredentialStore, node_id: []const u8, node_secret: []const u8) CredentialError!void {
        return self.setSecret(.remote_node_secret, node_id, node_secret);
    }

    pub fn clearRemoteNodeSecret(self: CredentialStore, node_id: []const u8) CredentialError!void {
        return self.clearSecret(.remote_node_secret, node_id);
    }

    pub fn getSecret(self: CredentialStore, kind: SecretKind, key: []const u8) ?[]u8 {
        if (!isValidKey(key)) return null;
        return switch (self.backend) {
            .linux_secret_tool => lookupLinuxSecretTool(self.allocator, kind, key),
            .macos_security => lookupMacosSecurity(self.allocator, kind, key),
            .none => null,
        };
    }

    pub fn setSecret(self: CredentialStore, kind: SecretKind, key: []const u8, value: []const u8) CredentialError!void {
        if (!isValidKey(key)) return CredentialError.InvalidKey;
        return switch (self.backend) {
            .linux_secret_tool => storeLinuxSecretTool(self.allocator, kind, key, value) catch CredentialError.StoreFailed,
            .macos_security => storeMacosSecurity(self.allocator, kind, key, value) catch CredentialError.StoreFailed,
            .none => CredentialError.SecureStoreUnavailable,
        };
    }

    pub fn clearSecret(self: CredentialStore, kind: SecretKind, key: []const u8) CredentialError!void {
        if (!isValidKey(key)) return CredentialError.InvalidKey;
        return switch (self.backend) {
            .linux_secret_tool => clearLinuxSecretTool(self.allocator, kind, key) catch CredentialError.ClearFailed,
            .macos_security => clearMacosSecurity(self.allocator, kind, key) catch CredentialError.ClearFailed,
            .none => CredentialError.SecureStoreUnavailable,
        };
    }
};

fn detectBackend(allocator: std.mem.Allocator) Backend {
    if (builtin.os.tag == .linux and commandExists(allocator, "secret-tool")) {
        return .linux_secret_tool;
    }
    if (builtin.os.tag == .macos and commandExists(allocator, "security")) {
        return .macos_security;
    }
    return .none;
}

fn commandExists(allocator: std.mem.Allocator, command: []const u8) bool {
    var child = std.process.Child.init(&[_][]const u8{ command, "--help" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return false;
    _ = child.wait() catch return false;
    return true;
}

fn isValidProvider(provider_name: []const u8) bool {
    return isValidKey(provider_name);
}

fn isValidKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |ch| {
        if (std.ascii.isAlphanumeric(ch)) continue;
        if (ch == '-' or ch == '_' or ch == '.') continue;
        return false;
    }
    return true;
}

fn secretKindLabel(kind: SecretKind) []const u8 {
    return switch (kind) {
        .provider_api_key => "provider_api_key",
        .mount_auth_token => "mount_auth_token",
        .remote_node_secret => "remote_node_secret",
    };
}

fn labelForSecret(allocator: std.mem.Allocator, kind: SecretKind, key: []const u8) ![]u8 {
    const kind_label = switch (kind) {
        .provider_api_key => "API key",
        .mount_auth_token => "mount auth token",
        .remote_node_secret => "remote node secret",
    };
    return std.fmt.allocPrint(allocator, "Spiderweb {s}: {s}", .{ kind_label, key });
}

fn secretAccountKey(allocator: std.mem.Allocator, kind: SecretKind, key: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ secretKindLabel(kind), key });
}

fn lookupLinuxSecretTool(allocator: std.mem.Allocator, kind: SecretKind, key: []const u8) ?[]u8 {
    const account_key = secretAccountKey(allocator, kind, key) catch return null;
    defer allocator.free(account_key);

    const kind_label = secretKindLabel(kind);
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "secret-tool",
            "lookup",
            "service",
            service_name,
            "kind",
            kind_label,
            "account",
            account_key,
        },
        .max_output_bytes = 32 * 1024,
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    const trimmed = std.mem.trimRight(u8, result.stdout, "\r\n");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}

fn storeLinuxSecretTool(allocator: std.mem.Allocator, kind: SecretKind, key: []const u8, value: []const u8) !void {
    const account_key = try secretAccountKey(allocator, kind, key);
    defer allocator.free(account_key);
    const label = try labelForSecret(allocator, kind, key);
    defer allocator.free(label);

    var child = std.process.Child.init(&[_][]const u8{
        "secret-tool",
        "store",
        "--label",
        label,
        "service",
        service_name,
        "kind",
        secretKindLabel(kind),
        "account",
        account_key,
    }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    errdefer _ = child.kill() catch {};

    if (child.stdin) |*stdin_pipe| {
        try stdin_pipe.writeAll(value);
        stdin_pipe.close();
        child.stdin = null;
    }

    var stderr_bytes: ?[]u8 = null;
    defer if (stderr_bytes) |bytes| allocator.free(bytes);
    if (child.stderr) |*stderr_pipe| {
        stderr_bytes = stderr_pipe.readToEndAlloc(allocator, 16 * 1024) catch null;
    }

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                if (stderr_bytes) |bytes| {
                    const err_text = std.mem.trim(u8, bytes, " \t\r\n");
                    if (err_text.len > 0) {
                        std.log.warn("secret-tool store failed: {s}", .{err_text});
                    }
                }
                return error.CommandFailed;
            }
        },
        else => return error.CommandFailed,
    }
}

fn clearLinuxSecretTool(allocator: std.mem.Allocator, kind: SecretKind, key: []const u8) !void {
    const account_key = try secretAccountKey(allocator, kind, key);
    defer allocator.free(account_key);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "secret-tool",
            "clear",
            "service",
            service_name,
            "kind",
            secretKindLabel(kind),
            "account",
            account_key,
        },
        .max_output_bytes = 16 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code == 0 or code == 1) return,
        else => {},
    }
    return error.CommandFailed;
}

fn lookupMacosSecurity(allocator: std.mem.Allocator, kind: SecretKind, key: []const u8) ?[]u8 {
    const account_key = secretAccountKey(allocator, kind, key) catch return null;
    defer allocator.free(account_key);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "security",
            "find-generic-password",
            "-s",
            service_name,
            "-a",
            account_key,
            "-w",
        },
        .max_output_bytes = 32 * 1024,
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    const trimmed = std.mem.trimRight(u8, result.stdout, "\r\n");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}

fn storeMacosSecurity(allocator: std.mem.Allocator, kind: SecretKind, key: []const u8, value: []const u8) !void {
    const account_key = try secretAccountKey(allocator, kind, key);
    defer allocator.free(account_key);
    const label = try labelForSecret(allocator, kind, key);
    defer allocator.free(label);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "security",
            "add-generic-password",
            "-U",
            "-s",
            service_name,
            "-a",
            account_key,
            "-l",
            label,
            "-w",
            value,
        },
        .max_output_bytes = 32 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code == 0) return,
        else => {},
    }

    const stderr_text = std.mem.trim(u8, result.stderr, " \t\r\n");
    if (stderr_text.len > 0) {
        std.log.warn("security add-generic-password failed: {s}", .{stderr_text});
    }
    return error.CommandFailed;
}

fn clearMacosSecurity(allocator: std.mem.Allocator, kind: SecretKind, key: []const u8) !void {
    const account_key = try secretAccountKey(allocator, kind, key);
    defer allocator.free(account_key);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "security",
            "delete-generic-password",
            "-s",
            service_name,
            "-a",
            account_key,
        },
        .max_output_bytes = 16 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code == 0 or code == 44) return,
        else => {},
    }
    return error.CommandFailed;
}

test "credential_store: key validation rejects unsafe names" {
    try std.testing.expect(!isValidProvider(""));
    try std.testing.expect(!isValidProvider("../openai"));
    try std.testing.expect(!isValidProvider("openai codex"));
    try std.testing.expect(isValidProvider("openai-codex"));
    try std.testing.expect(isValidProvider("kimi_code"));
    try std.testing.expect(!isValidKey("mount/auth"));
    try std.testing.expect(isValidKey("remote-node.1"));
}

test "credential_store: init selects a backend enum" {
    const store = CredentialStore.init(std.testing.allocator);
    switch (store.backend) {
        .linux_secret_tool, .macos_security, .none => {},
    }
}
