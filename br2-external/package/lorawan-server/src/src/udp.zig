const std = @import("std");
const posix = std.posix;

const app_mod = @import("app.zig");
const gateway_state = @import("gateway_state.zig");
const logger = @import("logger.zig");
const pending_downlinks = @import("pending_downlinks.zig");
const packets = @import("udp_packets.zig");
const udp_transport = @import("udp_transport.zig");
const App = app_mod.App;
const Config = app_mod.Config;

const UdpPacketContext = struct {
    server: *Server,
    client_addr: posix.sockaddr.in,
    client_len: posix.socklen_t,
    msg: []u8,
};

pub const DataRate = packets.DataRate;
pub const Rxpk = packets.Rxpk;
pub const GatewayStat = packets.GatewayStat;
pub const PushDataFrame = packets.PushDataFrame;
pub const PullDataFrame = packets.PullDataFrame;
pub const TxAckFrame = packets.TxAckFrame;
pub const DecodedFrame = packets.DecodedFrame;
pub const DownlinkTiming = packets.DownlinkTiming;
pub const DownlinkRequest = packets.DownlinkRequest;

pub const Server = struct {
    app: *App,
    socket: udp_transport.Socket,
    pending: pending_downlinks.Tracker,

    pub fn init(app: *App, socket: udp_transport.Socket) Server {
        return .{
            .app = app,
            .socket = socket,
            .pending = pending_downlinks.Tracker.init(app.allocator),
        };
    }

    pub fn deinit(self: *Server) void {
        self.pending.deinit();
    }
};

pub fn serverMain(app: *App, runtime_config: *const Config) !void {
    const sock = try initServerSocket(runtime_config);
    defer sock.close();

    var server = Server.init(app, sock);
    defer server.deinit();
    while (true) try drainReady(&server);
}

pub fn sendDownlink(app: *App, socket: udp_transport.Socket, gateway_mac: [8]u8, req: DownlinkRequest) !u16 {
    var server = Server.init(app, socket);
    defer server.deinit();
    return sendDownlinkWithServer(&server, gateway_mac, req);
}

pub fn initServerSocket(runtime_config: *const Config) !udp_transport.Socket {
    const sock = try udp_transport.Socket.initServer(runtime_config);
    logger.info("udp", "listener_started", "udp listener started", .{
        .bind_address = runtime_config.bind_address,
        .port = runtime_config.udp_port,
    });

    return sock;
}

pub fn drainReady(server: *Server) !void {
    var buf: [4096]u8 = undefined;

    while (true) {
        const datagram = (try server.socket.recvFrom(buf[0..])) orelse return;
        try handleDatagram(server, datagram.client_addr, datagram.client_len, buf[0..datagram.len]);
    }
}

pub fn handleDatagram(
    server: *Server,
    client_addr: posix.sockaddr.in,
    client_len: posix.socklen_t,
    msg: []const u8,
) !void {
    const owned_msg = try server.app.allocator.dupe(u8, msg);
    defer server.app.allocator.free(owned_msg);

    var context = UdpPacketContext{
        .server = server,
        .client_addr = client_addr,
        .client_len = client_len,
        .msg = owned_msg,
    };

    try handleUdpPacket(&context);
}

fn handleUdpPacket(context: *UdpPacketContext) !void {
    const port = std.mem.bigToNative(u16, context.client_addr.port);
    const ip = @as([4]u8, @bitCast(context.client_addr.addr));

    logger.debug("udp", "packet_received", "udp packet received", .{
        .bytes = context.msg.len,
        .peer_ip = ip,
        .peer_port = port,
    });

    if (context.msg.len < 4) {
        logger.warn("udp", "packet_too_short", "udp packet too short for semtech header", .{
            .bytes = context.msg.len,
            .peer_port = port,
        });
        return;
    }

    const version = context.msg[0];
    const token = std.mem.readInt(u16, context.msg[1..3], .big);
    const ident = context.msg[3];

    context.server.pending.pruneExpired();

    switch (ident) {
        packets.push_data_ident => try handlePushData(context, version, token),
        packets.pull_data_ident => try handlePullData(context, version, token),
        packets.tx_ack_ident => try handleTxAck(context, version, token),
        else => logger.warn("udp", "unsupported_ident", "unsupported semtech packet type", .{
            .version = version,
            .token = token,
            .ident = ident,
        }),
    }
}

fn handlePushData(context: *UdpPacketContext, version: u8, token: u16) !void {
    if (context.msg.len < 12) {
        logger.warn("udp", "push_data_short", "push data packet too short", .{
            .bytes = context.msg.len,
            .token = token,
        });
        return;
    }

    try sendAck(&context.server.socket, &context.client_addr, context.client_len, version, token, packets.push_ack_ident);

    var frame = packets.decodeFrame(context.server.app.allocator, context.msg) catch |err| {
        logger.err("udp", "push_data_decode_failed", "failed to decode push data frame", .{
            .error_name = @errorName(err),
            .token = token,
        });
        return;
    };
    defer frame.deinit(context.server.app.allocator);

    const push = switch (frame) {
        .push_data => |value| value,
        else => return,
    };

    try gateway_state.updateLastSeen(context.server.app, push.gateway_mac, &context.client_addr);

    for (push.rxpk.items) |rxpk| {
        try gateway_state.insertEvent(context.server.app, "gateway_rxpk", push.gateway_mac, try packets.encodeNormalizedRxpk(context.server.app.allocator, push.gateway_mac, rxpk));
    }

    if (push.stat) |stat| {
        try gateway_state.insertEvent(context.server.app, "gateway_stat", push.gateway_mac, stat.json);
    }
}

fn handlePullData(context: *UdpPacketContext, version: u8, token: u16) !void {
    if (context.msg.len < 12) {
        logger.warn("udp", "pull_data_short", "pull data packet too short", .{
            .bytes = context.msg.len,
            .token = token,
        });
        return;
    }

    const gateway_mac = packets.parseGatewayMac(context.msg[4..12].*);
    try sendAck(&context.server.socket, &context.client_addr, context.client_len, version, token, packets.pull_ack_ident);
    try gateway_state.updatePullTarget(context.server.app, gateway_mac, version, &context.client_addr);
}

fn handleTxAck(context: *UdpPacketContext, version: u8, token: u16) !void {
    _ = version;

    var frame = packets.decodeFrame(context.server.app.allocator, context.msg) catch |err| {
        logger.err("udp", "tx_ack_decode_failed", "failed to decode tx ack frame", .{
            .error_name = @errorName(err),
            .token = token,
        });
        return;
    };
    defer frame.deinit(context.server.app.allocator);

    const ack = switch (frame) {
        .tx_ack => |value| value,
        else => return,
    };

    const maybe_pending = context.server.pending.take(ack.token);
    if (maybe_pending == null) {
        logger.warn("udp", "unknown_tx_ack_token", "received tx ack for unknown token", .{
            .token = ack.token,
            .gateway_mac = packets.gatewayMacHex(ack.gateway_mac),
        });
        return;
    }

    const pending = maybe_pending.?;
    defer pending_downlinks.freeEntry(context.server.app.allocator, pending);

    const delay_ms = std.time.milliTimestamp() - pending.sent_at_ms;
    const status = if (ack.error_name) |value| value else "NONE";

    try gateway_state.insertEvent(context.server.app, "gateway_tx_ack", ack.gateway_mac, try packets.encodeTxAckEvent(
        context.server.app.allocator,
        ack.gateway_mac,
        ack.token,
        delay_ms,
        pending.dev_addr,
        status,
    ));

    if (ack.error_name) |value| {
        if (!std.ascii.eqlIgnoreCase(value, "NONE")) {
            logger.warn("udp", "tx_ack_error", "gateway reported downlink error", .{
                .gateway_mac = packets.gatewayMacHex(ack.gateway_mac),
                .token = ack.token,
                .error_name = value,
            });
        }
    }
}

fn sendDownlinkWithServer(server: *Server, gateway_mac: [8]u8, req: DownlinkRequest) !u16 {
    server.pending.pruneExpired();

    const target = try gateway_state.readTarget(server.app, gateway_mac);
    defer target.deinit(server.app.allocator);

    const token = pending_downlinks.randomToken();
    const txpk_json = try packets.buildPullRespJson(server.app.allocator, req);
    errdefer server.app.allocator.free(txpk_json);

    const payload = try packets.encodePullResp(server.app.allocator, packets.semtech_version, token, txpk_json);
    defer server.app.allocator.free(payload);

    try server.socket.sendTo(&target.addr, @sizeOf(posix.sockaddr.in), payload);

    try server.pending.remember(token, gateway_mac, req.dev_addr);
    try gateway_state.updatePending(server.app, gateway_mac, token, txpk_json);
    return token;
}

fn sendAck(socket: *const udp_transport.Socket, client_addr: *const posix.sockaddr.in, client_len: posix.socklen_t, version: u8, token: u16, ident: u8) !void {
    var ack_buf: [4]u8 = undefined;
    ack_buf[0] = version;
    std.mem.writeInt(u16, ack_buf[1..3], token, .big);
    ack_buf[3] = ident;
    try socket.sendTo(client_addr, client_len, &ack_buf);
}
