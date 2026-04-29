const std = @import("std");

pub fn readBE16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .big);
}

pub fn readLE16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

pub fn writeBE16(out: []u8, value: u16) void {
    std.mem.writeInt(u16, out[0..2], value, .big);
}

pub fn writeLE16(out: []u8, value: u16) void {
    std.mem.writeInt(u16, out[0..2], value, .little);
}

pub fn writeLE32(out: []u8, value: u32) void {
    std.mem.writeInt(u32, out[0..4], value, .little);
}

pub fn reverseArray(comptime len: usize, value: [len]u8) [len]u8 {
    var out: [len]u8 = undefined;
    for (value, 0..) |byte, index| out[len - 1 - index] = byte;
    return out;
}

pub fn readEuiLe(bytes: []const u8) [8]u8 {
    return reverseArray(8, bytes[0..8].*);
}

pub fn readDevAddrLe(bytes: []const u8) [4]u8 {
    return reverseArray(4, bytes[0..4].*);
}

pub fn writeDevAddrLe(value: [4]u8) [4]u8 {
    return reverseArray(4, value);
}

pub fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |text| return try allocator.dupe(u8, text);
    return null;
}

test "big-endian 16-bit read and write" {
    try std.testing.expectEqual(@as(u16, 0xBEEF), readBE16(&[_]u8{ 0xBE, 0xEF }));

    var out: [2]u8 = undefined;
    writeBE16(&out, 0xCAFE);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xCA, 0xFE }, &out);
}

test "little-endian 16-bit read and write" {
    try std.testing.expectEqual(@as(u16, 0x1234), readLE16(&[_]u8{ 0x34, 0x12 }));

    var out: [2]u8 = undefined;
    writeLE16(&out, 0xABCD);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xCD, 0xAB }, &out);
}

test "LoRaWAN little-endian identifiers reverse wire order" {
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 8, 7, 6, 5, 4, 3, 2, 1 },
        &readEuiLe(&[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }),
    );
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 4, 3, 2, 1 },
        &readDevAddrLe(&[_]u8{ 1, 2, 3, 4 }),
    );
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 1, 2, 3, 4 },
        &writeDevAddrLe([_]u8{ 4, 3, 2, 1 }),
    );
}
