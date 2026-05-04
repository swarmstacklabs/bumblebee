const std = @import("std");
const builtin = @import("builtin");

const connectors = @import("../connectors.zig");
const http_transport = @import("transport.zig");
const logger = @import("../logger.zig");
const request_mod = @import("request.zig");

const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const max_pending_events = 128;

const PendingEvent = struct {
    allocator: std.mem.Allocator,
    payload: []u8,

    fn deinit(self: PendingEvent) void {
        self.allocator.free(self.payload);
    }
};

var pending_events: [max_pending_events]PendingEvent = undefined;
var pending_event_count: usize = 0;

pub fn enqueue(allocator: std.mem.Allocator, event: connectors.PublishedEvent) void {
    if (builtin.is_test) return;

    const envelope = connectors.encodeEnvelope(allocator, event) catch |err| {
        logger.warn("timeline_ws", "encode_failed", "failed to encode websocket timeline payload", .{
            .error_name = @errorName(err),
            .event_type = event.event_type,
        });
        return;
    };
    errdefer allocator.free(envelope);

    if (pending_event_count == max_pending_events) {
        pending_events[0].deinit();
        std.mem.copyForwards(PendingEvent, pending_events[0 .. max_pending_events - 1], pending_events[1..max_pending_events]);
        pending_event_count -= 1;
    }

    pending_events[pending_event_count] = .{
        .allocator = allocator,
        .payload = envelope,
    };
    pending_event_count += 1;
}

pub fn handleUpgrade(allocator: std.mem.Allocator, conn: *http_transport.Connection, req: request_mod.Request) !bool {
    if (!std.mem.eql(u8, req.path, "/admin/timeline/ws")) return false;
    if (!isWebSocketUpgrade(req)) {
        try conn.writeAll("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return true;
    }

    const key = req.header("Sec-WebSocket-Key") orelse {
        try conn.writeAll("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return true;
    };
    const accept = try websocketAccept(allocator, key);
    defer allocator.free(accept);

    var response = std.ArrayList(u8){};
    defer response.deinit(allocator);
    try response.writer(allocator).print(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n",
        .{accept},
    );
    try conn.writeAll(response.items);
    conn.mode = .timeline_ws;
    conn.resetRequestBuffer();
    return false;
}

pub fn drainClient(conn: *http_transport.Connection) !bool {
    const n = conn.recv() catch |err| switch (err) {
        error.WouldBlock => return false,
        else => return err,
    };
    if (n == 0) return true;

    conn.resetRequestBuffer();
    return false;
}

pub fn broadcastPending(allocator: std.mem.Allocator, conns: *std.ArrayList(http_transport.Connection)) void {
    _ = allocator;
    if (pending_event_count == 0) return;
    defer clearPending();

    var i: usize = 0;
    while (i < conns.items.len) {
        if (conns.items[i].mode != .timeline_ws) {
            i += 1;
            continue;
        }

        var failed = false;
        for (pending_events[0..pending_event_count]) |event| {
            const frame = buildTextFrame(event.allocator, event.payload) catch |err| {
                logger.warn("timeline_ws", "frame_failed", "failed to build websocket frame", .{
                    .error_name = @errorName(err),
                });
                failed = true;
                break;
            };
            defer event.allocator.free(frame);

            conns.items[i].writeAll(frame) catch |err| {
                logger.warn("timeline_ws", "write_failed", "failed to send websocket timeline payload", .{
                    .error_name = @errorName(err),
                });
                failed = true;
                break;
            };
        }

        if (failed) {
            conns.items[i].close();
            _ = conns.orderedRemove(i);
            continue;
        }
        i += 1;
    }
}

fn clearPending() void {
    for (pending_events[0..pending_event_count]) |event| {
        event.deinit();
    }
    pending_event_count = 0;
}

fn isWebSocketUpgrade(req: request_mod.Request) bool {
    const upgrade = req.header("Upgrade") orelse return false;
    const connection = req.header("Connection") orelse return false;
    const version = req.header("Sec-WebSocket-Version") orelse return false;
    return std.ascii.eqlIgnoreCase(upgrade, "websocket") and
        headerContainsToken(connection, "Upgrade") and
        std.mem.eql(u8, version, "13");
}

fn headerContainsToken(value: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, value, ',');
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), token)) return true;
    }
    return false;
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
    if (payload.len < 126) {
        try out.append(allocator, @intCast(payload.len));
    } else if (payload.len <= 0xFFFF) {
        try out.append(allocator, 126);
        try out.append(allocator, @intCast((payload.len >> 8) & 0xff));
        try out.append(allocator, @intCast(payload.len & 0xff));
    } else {
        try out.append(allocator, 127);
        var shift: usize = 56;
        while (true) {
            try out.append(allocator, @intCast((payload.len >> @intCast(shift)) & 0xff));
            if (shift == 0) break;
            shift -= 8;
        }
    }
    try out.appendSlice(allocator, payload);
    return out.toOwnedSlice(allocator);
}

test "websocket upgrade detection accepts standard browser headers" {
    const headers = [_]request_mod.Header{
        request_mod.Header.init("Upgrade", "websocket"),
        request_mod.Header.init("Connection", "keep-alive, Upgrade"),
        request_mod.Header.init("Sec-WebSocket-Version", "13"),
        request_mod.Header.init("Sec-WebSocket-Key", "abc"),
    };
    const req = request_mod.Request.init(.GET, "/admin/timeline/ws", "/admin/timeline/ws", "", &headers);
    try std.testing.expect(isWebSocketUpgrade(req));
}
