const std = @import("std");

pub fn runMetricsHttpServer(
    allocator: std.mem.Allocator,
    runtime_registry: anytype,
    listener: *std.net.Server,
) void {
    while (true) {
        var connection = listener.accept() catch |err| {
            std.log.err("metrics accept failed: {s}", .{@errorName(err)});
            std.Thread.sleep(250 * std.time.ns_per_ms);
            continue;
        };
        defer connection.stream.close();

        handleMetricsHttpConnection(allocator, runtime_registry, &connection.stream) catch |err| {
            std.log.warn("metrics request failed: {s}", .{@errorName(err)});
        };
    }
}

fn handleMetricsHttpConnection(
    allocator: std.mem.Allocator,
    runtime_registry: anytype,
    stream: *std.net.Stream,
) !void {
    var request_buf: [16 * 1024]u8 = undefined;
    const request = try readHttpRequestIntoBuffer(stream, &request_buf);
    const request_target = parseHttpRequestPath(request) orelse {
        try writeHttpStatus(stream, "400 Bad Request", "text/plain; charset=utf-8", "bad request\n");
        return;
    };
    const request_path = stripHttpRequestTargetQuery(request_target);

    if (std.mem.eql(u8, request_path, "/livez")) {
        try writeHttpStatus(stream, "200 OK", "text/plain; charset=utf-8", "ok\n");
        return;
    }

    if (std.mem.eql(u8, request_path, "/readyz")) {
        if (runtime_registry.getFirstAgentId() == null) {
            try writeHttpStatus(stream, "503 Service Unavailable", "text/plain; charset=utf-8", "not ready\n");
            return;
        }
        try writeHttpStatus(stream, "200 OK", "text/plain; charset=utf-8", "ready\n");
        return;
    }

    if (std.mem.eql(u8, request_path, "/metrics")) {
        const body = runtime_registry.metricsPrometheus() catch |err| {
            const err_msg = try std.fmt.allocPrint(allocator, "metrics formatter error: {s}\n", .{@errorName(err)});
            defer allocator.free(err_msg);
            try writeHttpStatus(stream, "500 Internal Server Error", "text/plain; charset=utf-8", err_msg);
            return;
        };
        defer allocator.free(body);
        try writeHttpStatus(stream, "200 OK", "text/plain; version=0.0.4; charset=utf-8", body);
        return;
    }

    if (!std.mem.eql(u8, request_path, "/metrics.json")) {
        try writeHttpStatus(stream, "404 Not Found", "text/plain; charset=utf-8", "not found\n");
        return;
    }

    const json_body = runtime_registry.metricsJson() catch |err| {
        const err_msg = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}\n", .{@errorName(err)});
        defer allocator.free(err_msg);
        try writeHttpStatus(stream, "500 Internal Server Error", "application/json", err_msg);
        return;
    };
    defer allocator.free(json_body);

    try writeHttpStatus(stream, "200 OK", "application/json", json_body);
}

fn readHttpRequestIntoBuffer(stream: *std.net.Stream, buffer: []u8) ![]const u8 {
    var used: usize = 0;
    while (used < buffer.len) {
        const read_n = try stream.read(buffer[used..]);
        if (read_n == 0) return error.ConnectionClosed;
        used += read_n;
        if (std.mem.indexOf(u8, buffer[0..used], "\r\n\r\n") != null) {
            return buffer[0..used];
        }
    }
    return error.RequestTooLarge;
}

pub fn parseHttpRequestPath(request: []const u8) ?[]const u8 {
    const line_end = std.mem.indexOf(u8, request, "\r\n") orelse return null;
    const line = request[0..line_end];
    if (!std.mem.startsWith(u8, line, "GET ")) return null;
    const path_start = 4;
    const path_end = std.mem.indexOfPos(u8, line, path_start, " ") orelse return null;
    if (path_end <= path_start) return null;
    return line[path_start..path_end];
}

pub fn stripHttpRequestTargetQuery(target: []const u8) []const u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return target;
    return target[0..query_start];
}

fn writeHttpStatus(
    stream: *std.net.Stream,
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
) !void {
    var header_buf: [256]u8 = undefined;
    const response_headers = try std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, content_type, body.len },
    );
    try stream.writeAll(response_headers);
    if (body.len > 0) try stream.writeAll(body);
}
