const std = @import("std");
const types = @import("types.zig");
const wire = @import("wire.zig");

const ConfigEntry = types.ConfigEntry;

pub fn publish(allocator: std.mem.Allocator, stream: *std.net.Stream, config: ConfigEntry, payload: []const u8) !void {
    const request = try buildProduceRequest(allocator, config.client_id orelse config.name, config.topic.?, config.partition, payload);
    defer allocator.free(request);
    try stream.writeAll(request);
}

fn buildProduceRequest(allocator: std.mem.Allocator, client_id: []const u8, topic: []const u8, partition: i32, payload: []const u8) ![]u8 {
    const message = try buildMessage(allocator, payload);
    defer allocator.free(message);

    var request = std.ArrayList(u8){};
    defer request.deinit(allocator);

    try wire.appendI16(&request, allocator, 0);
    try wire.appendI16(&request, allocator, 0);
    try wire.appendI32(&request, allocator, 1);
    try wire.appendKafkaString(&request, allocator, client_id);
    try wire.appendI16(&request, allocator, 0);
    try wire.appendI32(&request, allocator, 1000);
    try wire.appendI32(&request, allocator, 1);
    try wire.appendKafkaString(&request, allocator, topic);
    try wire.appendI32(&request, allocator, 1);
    try wire.appendI32(&request, allocator, partition);

    var message_set = std.ArrayList(u8){};
    defer message_set.deinit(allocator);
    try wire.appendI64(&message_set, allocator, 0);
    try wire.appendI32(&message_set, allocator, @intCast(message.len));
    try message_set.appendSlice(allocator, message);

    try wire.appendI32(&request, allocator, @intCast(message_set.items.len));
    try request.appendSlice(allocator, message_set.items);

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    try wire.appendI32(&out, allocator, @intCast(request.items.len));
    try out.appendSlice(allocator, request.items);
    return out.toOwnedSlice(allocator);
}

fn buildMessage(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var body = std.ArrayList(u8){};
    defer body.deinit(allocator);

    try body.append(allocator, 0);
    try body.append(allocator, 0);
    try wire.appendI32(&body, allocator, -1);
    try wire.appendI32(&body, allocator, @intCast(payload.len));
    try body.appendSlice(allocator, payload);

    var crc = std.hash.Crc32.init();
    crc.update(body.items);
    const checksum = crc.final();

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    try wire.appendU32(&out, allocator, checksum);
    try out.appendSlice(allocator, body.items);
    return out.toOwnedSlice(allocator);
}

test "kafka produce request contains topic and payload" {
    const req = try buildProduceRequest(std.testing.allocator, "lorawan-server", "uplinks", 0, "{\"x\":1}");
    defer std.testing.allocator.free(req);

    try std.testing.expect(std.mem.indexOf(u8, req, "uplinks") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "{\"x\":1}") != null);
}
