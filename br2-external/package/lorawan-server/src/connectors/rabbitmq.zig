const std = @import("std");
const types = @import("types.zig");
const wire = @import("wire.zig");

const ConfigEntry = types.ConfigEntry;
const Endpoint = types.Endpoint;

pub fn publish(allocator: std.mem.Allocator, stream: *std.net.Stream, endpoint: Endpoint, config: ConfigEntry, payload: []const u8) !void {
    try stream.writeAll("AMQP\x00\x00\x09\x01");

    const start = try readFrame(allocator, stream);
    defer allocator.free(start.payload);
    if (start.frame_type != 1 or methodClass(start.payload) != 10 or methodMethod(start.payload) != 10) {
        return error.AmqpUnexpectedFrame;
    }

    const start_ok = try buildStartOk(allocator, endpoint.username orelse "guest", endpoint.password orelse "guest");
    defer allocator.free(start_ok);
    try stream.writeAll(start_ok);

    const tune = try readFrame(allocator, stream);
    defer allocator.free(tune.payload);
    if (tune.frame_type != 1 or methodClass(tune.payload) != 10 or methodMethod(tune.payload) != 30) {
        return error.AmqpUnexpectedFrame;
    }

    const frame_max = if (tune.payload.len >= 12) std.mem.readInt(u32, tune.payload[8..12], .big) else 131072;

    const tune_ok = try buildTuneOk(allocator, frame_max);
    defer allocator.free(tune_ok);
    try stream.writeAll(tune_ok);

    const open = try buildConnectionOpen(allocator, endpoint.path);
    defer allocator.free(open);
    try stream.writeAll(open);

    const open_ok = try readFrame(allocator, stream);
    defer allocator.free(open_ok.payload);
    if (open_ok.frame_type != 1 or methodClass(open_ok.payload) != 10 or methodMethod(open_ok.payload) != 41) {
        return error.AmqpUnexpectedFrame;
    }

    const channel_open = try buildChannelOpen(allocator);
    defer allocator.free(channel_open);
    try stream.writeAll(channel_open);

    const channel_ok = try readFrame(allocator, stream);
    defer allocator.free(channel_ok.payload);
    if (channel_ok.frame_type != 1 or methodClass(channel_ok.payload) != 20 or methodMethod(channel_ok.payload) != 11) {
        return error.AmqpUnexpectedFrame;
    }

    const publish_frame = try buildBasicPublish(allocator, config.exchange.?, config.routing_key.?, payload);
    defer allocator.free(publish_frame);
    try stream.writeAll(publish_frame);
}

const Frame = struct {
    frame_type: u8,
    channel: u16,
    payload: []u8,
};

fn readFrame(allocator: std.mem.Allocator, stream: *std.net.Stream) !Frame {
    var header: [7]u8 = undefined;
    try wire.readNoEof(stream, header[0..]);

    const size = std.mem.readInt(u32, header[3..7], .big);
    const payload = try allocator.alloc(u8, size);
    errdefer allocator.free(payload);
    try wire.readNoEof(stream, payload);

    var frame_end: [1]u8 = undefined;
    try wire.readNoEof(stream, frame_end[0..]);
    if (frame_end[0] != 0xCE) return error.AmqpFrameCorrupt;

    return .{
        .frame_type = header[0],
        .channel = std.mem.readInt(u16, header[1..3], .big),
        .payload = payload,
    };
}

fn methodClass(payload: []const u8) u16 {
    if (payload.len < 2) return 0;
    return std.mem.readInt(u16, payload[0..2], .big);
}

fn methodMethod(payload: []const u8) u16 {
    if (payload.len < 4) return 0;
    return std.mem.readInt(u16, payload[2..4], .big);
}

fn buildStartOk(allocator: std.mem.Allocator, username: []const u8, password: []const u8) ![]u8 {
    var method = std.ArrayList(u8){};
    defer method.deinit(allocator);
    try wire.appendU16(&method, allocator, 10);
    try wire.appendU16(&method, allocator, 11);
    try wire.appendU32(&method, allocator, 0);
    try wire.appendLongString(&method, allocator, "PLAIN");
    const response = try std.fmt.allocPrint(allocator, "\x00{s}\x00{s}", .{ username, password });
    defer allocator.free(response);
    try wire.appendLongString(&method, allocator, response);
    try wire.appendLongString(&method, allocator, "en_US");
    return buildMethodFrame(allocator, 0, method.items);
}

fn buildTuneOk(allocator: std.mem.Allocator, frame_max: u32) ![]u8 {
    var method = std.ArrayList(u8){};
    defer method.deinit(allocator);
    try wire.appendU16(&method, allocator, 10);
    try wire.appendU16(&method, allocator, 31);
    try wire.appendU16(&method, allocator, 0);
    try wire.appendU32(&method, allocator, frame_max);
    try wire.appendU16(&method, allocator, 0);
    return buildMethodFrame(allocator, 0, method.items);
}

fn buildConnectionOpen(allocator: std.mem.Allocator, raw_path: []const u8) ![]u8 {
    const vhost = if (raw_path.len <= 1) "/" else raw_path[1..];
    var method = std.ArrayList(u8){};
    defer method.deinit(allocator);
    try wire.appendU16(&method, allocator, 10);
    try wire.appendU16(&method, allocator, 40);
    try wire.appendShortString(&method, allocator, vhost);
    try wire.appendShortString(&method, allocator, "");
    try method.append(allocator, 0);
    return buildMethodFrame(allocator, 0, method.items);
}

fn buildChannelOpen(allocator: std.mem.Allocator) ![]u8 {
    var method = std.ArrayList(u8){};
    defer method.deinit(allocator);
    try wire.appendU16(&method, allocator, 20);
    try wire.appendU16(&method, allocator, 10);
    try wire.appendShortString(&method, allocator, "");
    return buildMethodFrame(allocator, 1, method.items);
}

fn buildBasicPublish(allocator: std.mem.Allocator, exchange: []const u8, routing_key: []const u8, payload: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    var method = std.ArrayList(u8){};
    defer method.deinit(allocator);
    try wire.appendU16(&method, allocator, 60);
    try wire.appendU16(&method, allocator, 40);
    try wire.appendU16(&method, allocator, 0);
    try wire.appendShortString(&method, allocator, exchange);
    try wire.appendShortString(&method, allocator, routing_key);
    try method.append(allocator, 0);
    try appendSliceFrame(&out, allocator, 1, 1, method.items);

    var header = std.ArrayList(u8){};
    defer header.deinit(allocator);
    try wire.appendU16(&header, allocator, 60);
    try wire.appendU16(&header, allocator, 0);
    try wire.appendU64(&header, allocator, payload.len);
    try wire.appendU16(&header, allocator, 0x1000);
    try wire.appendShortString(&header, allocator, "application/json");
    try appendSliceFrame(&out, allocator, 2, 1, header.items);

    try appendSliceFrame(&out, allocator, 3, 1, payload);
    return out.toOwnedSlice(allocator);
}

fn buildMethodFrame(allocator: std.mem.Allocator, channel: u16, payload: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    try appendSliceFrame(&out, allocator, 1, channel, payload);
    return out.toOwnedSlice(allocator);
}

fn appendSliceFrame(out: *std.ArrayList(u8), allocator: std.mem.Allocator, frame_type: u8, channel: u16, payload: []const u8) !void {
    try out.append(allocator, frame_type);
    try wire.appendU16(out, allocator, channel);
    try wire.appendU32(out, allocator, @intCast(payload.len));
    try out.appendSlice(allocator, payload);
    try out.append(allocator, 0xCE);
}
