const std = @import("std");
const types = @import("types.zig");
const wire = @import("wire.zig");

const ConfigEntry = types.ConfigEntry;
const Endpoint = types.Endpoint;

const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub fn publish(allocator: std.mem.Allocator, stream: *std.net.Stream, endpoint: Endpoint, _: ConfigEntry, payload: []const u8) !void {
    var nonce: [16]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    var key_buf: [32]u8 = undefined;
    const key = std.base64.standard.Encoder.encode(&key_buf, &nonce);

    var request = std.ArrayList(u8){};
    defer request.deinit(allocator);
    try request.writer(allocator).print(
        "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {s}\r\n",
        .{ endpoint.path, endpoint.host, endpoint.port, key },
    );
    if (endpoint.username != null or endpoint.password != null) {
        const auth_value = try wire.basicAuthHeader(allocator, endpoint.username orelse "", endpoint.password orelse "");
        defer allocator.free(auth_value);
        try request.writer(allocator).print("Authorization: Basic {s}\r\n", .{auth_value});
    }
    try request.appendSlice(allocator, "\r\n");
    try stream.writeAll(request.items);

    const response = try readHttpHeaders(allocator, stream);
    defer allocator.free(response);

    if (!std.mem.startsWith(u8, response, "HTTP/1.1 101")) return error.WebSocketUpgradeRejected;
    const accept = try websocketAccept(allocator, key);
    defer allocator.free(accept);
    if (std.mem.indexOf(u8, response, accept) == null) return error.WebSocketAcceptMismatch;

    const frame = try buildTextFrame(allocator, payload);
    defer allocator.free(frame);
    try stream.writeAll(frame);
}

fn readHttpHeaders(allocator: std.mem.Allocator, stream: *std.net.Stream) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    var buf: [256]u8 = undefined;
    while (true) {
        const n = try stream.read(&buf);
        if (n == 0) return error.ConnectionClosed;
        try out.appendSlice(allocator, buf[0..n]);
        if (std.mem.indexOf(u8, out.items, "\r\n\r\n") != null) break;
    }
    return out.toOwnedSlice(allocator);
}

fn websocketAccept(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const raw = try std.fmt.allocPrint(allocator, "{s}{s}", .{ key, websocket_guid });
    defer allocator.free(raw);

    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(raw, &digest, .{});

    const out_len = std.base64.standard.Encoder.calcSize(digest.len);
    const out = try allocator.alloc(u8, out_len);
    _ = std.base64.standard.Encoder.encode(out, &digest);
    return out;
}

fn buildTextFrame(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try out.append(allocator, 0x81);

    var mask: [4]u8 = undefined;
    std.crypto.random.bytes(&mask);

    if (payload.len < 126) {
        try out.append(allocator, 0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 0xFFFF) {
        try out.append(allocator, 0x80 | 126);
        try wire.appendU16(&out, allocator, @intCast(payload.len));
    } else {
        try out.append(allocator, 0x80 | 127);
        try wire.appendU64(&out, allocator, payload.len);
    }

    try out.appendSlice(allocator, &mask);
    for (payload, 0..) |byte, i| {
        try out.append(allocator, byte ^ mask[i % mask.len]);
    }

    return out.toOwnedSlice(allocator);
}
