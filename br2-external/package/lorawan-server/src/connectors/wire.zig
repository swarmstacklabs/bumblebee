const std = @import("std");

pub fn basicAuthHeader(allocator: std.mem.Allocator, username: []const u8, password: []const u8) ![]u8 {
    const raw = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ username, password });
    defer allocator.free(raw);
    const out = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(raw.len));
    _ = std.base64.standard.Encoder.encode(out, raw);
    return out;
}

pub fn expandPattern(allocator: std.mem.Allocator, pattern: []const u8, payload: []const u8) ![]u8 {
    _ = payload;
    return allocator.dupe(u8, pattern);
}

pub fn appendPrefixedBytes(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try appendU16(out, allocator, @intCast(value.len));
    try out.appendSlice(allocator, value);
}

pub fn appendShortString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try out.append(allocator, @intCast(value.len));
    try out.appendSlice(allocator, value);
}

pub fn appendLongString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try appendU32(out, allocator, @intCast(value.len));
    try out.appendSlice(allocator, value);
}

pub fn appendKafkaString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try appendI16(out, allocator, @intCast(value.len));
    try out.appendSlice(allocator, value);
}

pub fn appendU16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, value, .big);
    try out.appendSlice(allocator, &buf);
}

pub fn appendI16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(i16, &buf, value, .big);
    try out.appendSlice(allocator, &buf);
}

pub fn appendU32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .big);
    try out.appendSlice(allocator, &buf);
}

pub fn appendI32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &buf, value, .big);
    try out.appendSlice(allocator, &buf);
}

pub fn appendU64(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .big);
    try out.appendSlice(allocator, &buf);
}

pub fn appendI64(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf, value, .big);
    try out.appendSlice(allocator, &buf);
}

pub fn gatewayMacHex(mac: [8]u8) [16]u8 {
    const digits = "0123456789abcdef";
    var out: [16]u8 = undefined;
    for (mac, 0..) |byte, i| {
        out[i * 2] = digits[byte >> 4];
        out[i * 2 + 1] = digits[byte & 0x0F];
    }
    return out;
}

pub fn readNoEof(stream: *std.net.Stream, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const n = try stream.read(buffer[offset..]);
        if (n == 0) return error.EndOfStream;
        offset += n;
    }
}
