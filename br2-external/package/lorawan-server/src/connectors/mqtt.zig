const std = @import("std");
const types = @import("types.zig");
const wire = @import("wire.zig");

const ConfigEntry = types.ConfigEntry;
const Endpoint = types.Endpoint;

pub fn publish(allocator: std.mem.Allocator, stream: *std.net.Stream, endpoint: Endpoint, config: ConfigEntry, payload: []const u8) !void {
    const topic = try wire.expandPattern(allocator, config.topic.?, payload);
    defer allocator.free(topic);

    const client_id = if (config.client_id) |value| value else config.name;

    const connect_packet = try buildConnectPacket(allocator, client_id, endpoint.username, endpoint.password);
    defer allocator.free(connect_packet);
    try stream.writeAll(connect_packet);

    var connack: [4]u8 = undefined;
    try wire.readNoEof(stream, connack[0..]);
    if (connack[0] != 0x20 or connack[1] != 0x02 or connack[3] != 0x00) {
        return error.MqttConnectRejected;
    }

    const publish_packet = try buildPublishPacket(allocator, topic, payload);
    defer allocator.free(publish_packet);
    try stream.writeAll(publish_packet);

    try stream.writeAll(&.{ 0xE0, 0x00 });
}

fn buildConnectPacket(allocator: std.mem.Allocator, client_id: []const u8, username: ?[]const u8, password: ?[]const u8) ![]u8 {
    var variable = std.ArrayList(u8){};
    defer variable.deinit(allocator);

    try wire.appendPrefixedBytes(&variable, allocator, "MQTT");
    try variable.append(allocator, 0x04);
    var flags: u8 = 0x02;
    if (username != null) flags |= 0x80;
    if (password != null) flags |= 0x40;
    try variable.append(allocator, flags);
    try wire.appendU16(&variable, allocator, 30);
    try wire.appendPrefixedBytes(&variable, allocator, client_id);
    if (username) |value| try wire.appendPrefixedBytes(&variable, allocator, value);
    if (password) |value| try wire.appendPrefixedBytes(&variable, allocator, value);

    return buildFixedHeaderPacket(allocator, 0x10, variable.items);
}

fn buildPublishPacket(allocator: std.mem.Allocator, topic: []const u8, payload: []const u8) ![]u8 {
    var variable = std.ArrayList(u8){};
    defer variable.deinit(allocator);

    try wire.appendPrefixedBytes(&variable, allocator, topic);
    try variable.appendSlice(allocator, payload);

    return buildFixedHeaderPacket(allocator, 0x30, variable.items);
}

fn buildFixedHeaderPacket(allocator: std.mem.Allocator, packet_type: u8, body: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try out.append(allocator, packet_type);
    try encodeRemainingLength(&out, allocator, body.len);
    try out.appendSlice(allocator, body);
    return out.toOwnedSlice(allocator);
}

fn encodeRemainingLength(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: usize) !void {
    var remaining = value;
    while (true) {
        var encoded: u8 = @intCast(remaining % 128);
        remaining /= 128;
        if (remaining > 0) encoded |= 0x80;
        try out.append(allocator, encoded);
        if (remaining == 0) return;
    }
}

test "mqtt publish packet uses qos0 topic and body" {
    const packet = try buildPublishPacket(std.testing.allocator, "uplinks/node-a", "{\"x\":1}");
    defer std.testing.allocator.free(packet);

    try std.testing.expectEqual(@as(u8, 0x30), packet[0]);
    try std.testing.expect(std.mem.indexOf(u8, packet, "uplinks/node-a") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet, "{\"x\":1}") != null);
}
