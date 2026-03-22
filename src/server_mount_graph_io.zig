const std = @import("std");

pub fn materializeWriteData(
    allocator: std.mem.Allocator,
    existing: ?[]const u8,
    offset: u64,
    data: []const u8,
    truncate_to_size: ?u64,
    materialized_limit: usize,
) ![]u8 {
    const base = if (truncate_to_size) |requested_size| blk: {
        const target_size = std.math.cast(usize, requested_size) orelse return error.InvalidOffset;
        if (target_size > materialized_limit) return error.WriteTooLarge;

        const current = existing orelse return error.FileNotFound;
        var truncated = try allocator.alloc(u8, target_size);
        errdefer allocator.free(truncated);
        if (target_size > 0) {
            @memset(truncated, 0);
            const copy_len = @min(current.len, target_size);
            if (copy_len > 0) @memcpy(truncated[0..copy_len], current[0..copy_len]);
        }
        break :blk truncated;
    } else try allocator.dupe(u8, existing orelse "");
    errdefer allocator.free(base);

    if (base.len > materialized_limit) return error.WriteTooLarge;
    if (data.len == 0) return base;

    const range = try validateWriteRange(offset, data.len, materialized_limit);
    if (range.write_end <= base.len) {
        @memcpy(base[range.base_offset..range.write_end], data);
        return base;
    }

    const merged_len = range.write_end;
    var merged = try allocator.alloc(u8, merged_len);
    errdefer allocator.free(merged);
    @memset(merged, 0);
    if (base.len > 0) {
        @memcpy(merged[0..base.len], base);
    }
    @memcpy(merged[range.base_offset..range.write_end], data);
    allocator.free(base);
    return merged;
}

pub fn validateWriteRange(offset: u64, data_len: usize, materialized_limit: usize) !struct {
    base_offset: usize,
    write_end: usize,
} {
    const base_offset = std.math.cast(usize, offset) orelse return error.InvalidOffset;
    const write_end = std.math.add(usize, base_offset, data_len) catch return error.InvalidOffset;
    if (write_end > materialized_limit) return error.WriteTooLarge;
    return .{
        .base_offset = base_offset,
        .write_end = write_end,
    };
}

pub fn writeResponseCount(request_bytes: usize) !u32 {
    return std.math.cast(u32, request_bytes) orelse error.InvalidPayload;
}

pub fn encodeStandardBase64Owned(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(data.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, data);
    return encoded;
}

pub fn clampReadLength(offset: u64, requested_length: ?u32, materialized_limit: usize) !u32 {
    const materialized_limit_u64: u64 = materialized_limit;
    if (offset > materialized_limit_u64) return error.InvalidOffset;

    const base_offset = std.math.cast(usize, offset) orelse return error.InvalidOffset;
    const remaining = materialized_limit - base_offset;
    const max_length = std.math.cast(u32, remaining) orelse return error.InvalidOffset;
    return if (requested_length) |value| @min(value, max_length) else max_length;
}

pub fn readIsEof(
    offset: u64,
    requested_length_field: ?u32,
    requested_length: u32,
    chunk_len: usize,
    materialized_limit: usize,
) bool {
    if (chunk_len < requested_length) return true;
    if (requested_length != 0) return false;

    const materialized_limit_u64: u64 = materialized_limit;
    const requested_some_bytes = requested_length_field == null or requested_length_field.? > 0;
    return offset == materialized_limit_u64 and requested_some_bytes;
}
