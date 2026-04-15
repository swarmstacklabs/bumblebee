const std = @import("std");
const posix = std.posix;

const app_mod = @import("../app.zig");
const event_repository = @import("../repository/event_repository.zig");
const logger = @import("../logger.zig");
const lorawan = @import("../lorawan.zig");
const storage = @import("../storage.zig");
const udp_transport = @import("transport.zig");
const App = app_mod.App;
const Config = app_mod.Config;
const state_repository = lorawan.state_repository;
const gateway_registry = lorawan.gateway_registry;
const pending_downlinks = lorawan.pending_downlinks;
const packets = lorawan.packets;

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

    pub fn init(app: *App, socket: udp_transport.Socket) Server {
        return .{
            .app = app,
            .socket = socket,
        };
    }
};

pub fn serverMain(app: *App, runtime_config: *const Config) !void {
    const sock = try initServerSocket(runtime_config);
    defer sock.close();

    var server = Server.init(app, sock);
    while (true) try drainReady(&server);
}

pub fn sendDownlink(app: *App, socket: udp_transport.Socket, gateway_mac: [8]u8, req: DownlinkRequest) !u16 {
    var server = Server.init(app, socket);
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

    context.server.app.pending_downlinks.pruneExpired();

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

    const registry = gateway_registry.Registry.init(context.server.app.database());
    const lorawan_service = lorawan.service.Service.init(context.server.app.database());
    try registry.touch(push.gateway_mac, version, &context.client_addr);

    for (push.rxpk.items) |rxpk| {
        try registry.insertEvent("gateway_rxpk", push.gateway_mac, try packets.encodeNormalizedRxpk(context.server.app.allocator, push.gateway_mac, rxpk));

        const maybe_ingested = lorawan_service.ingestRxpk(context.server.app.allocator, push.gateway_mac, rxpk) catch |err| blk: {
            logger.warn("udp", "lorawan_ingest_failed", "failed to ingest LoRaWAN uplink", .{
                .gateway_mac = packets.gatewayMacHex(push.gateway_mac),
                .error_name = @errorName(err),
            });
            break :blk null;
        };

        if (maybe_ingested) |ingested| {
            defer ingested.deinit(context.server.app.allocator);

            try registry.insertEvent(ingested.event_type, push.gateway_mac, try context.server.app.allocator.dupe(u8, ingested.event_json));

            if (ingested.downlink) |downlink| {
                _ = sendDownlinkWithServer(context.server, push.gateway_mac, downlink) catch |err| {
                    logger.warn("udp", "lorawan_downlink_failed", "failed to send LoRaWAN downlink", .{
                        .gateway_mac = packets.gatewayMacHex(push.gateway_mac),
                        .error_name = @errorName(err),
                    });
                    continue;
                };
            }
        }
    }

    if (push.stat) |stat| {
        try registry.insertEvent("gateway_stat", push.gateway_mac, try context.server.app.allocator.dupe(u8, stat.json));
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
    const registry = gateway_registry.Registry.init(context.server.app.database());
    try registry.rememberPullTarget(gateway_mac, version, &context.client_addr);
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

    const registry = gateway_registry.Registry.init(context.server.app.database());
    const runtime = try registry.get(ack.gateway_mac);
    defer if (runtime) |value| value.deinit(context.server.app.allocator);

    const runtime_matches = runtime != null and runtime.?.pending_downlink_token != null and runtime.?.pending_downlink_token.? == ack.token;
    const maybe_pending = context.server.app.pending_downlinks.take(ack.gateway_mac, ack.token);
    defer if (maybe_pending) |pending| pending_downlinks.freeEntry(context.server.app.allocator, pending);
    if (maybe_pending == null and !runtime_matches) {
        logger.warn("udp", "unknown_tx_ack_token", "received tx ack for unknown token", .{
            .token = ack.token,
            .gateway_mac = packets.gatewayMacHex(ack.gateway_mac),
        });
        return;
    }

    const delay_ms = if (maybe_pending) |pending| std.time.milliTimestamp() - pending.sent_at_ms else 0;
    const status = if (ack.error_name) |value| value else "NONE";

    if (runtime_matches and std.ascii.eqlIgnoreCase(status, "NONE") and runtime.?.pending_downlink_json != null) {
        const lorawan_service = lorawan.service.Service.init(context.server.app.database());
        try lorawan_service.syncAcknowledgedDownlink(context.server.app.allocator, runtime.?.pending_downlink_json.?);
    }

    try registry.clearPending(ack.gateway_mac, ack.token);

    try registry.insertEvent("gateway_tx_ack", ack.gateway_mac, try packets.encodeTxAckEvent(
        context.server.app.allocator,
        ack.gateway_mac,
        ack.token,
        delay_ms,
        if (maybe_pending) |pending| pending.dev_addr else null,
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
    server.app.pending_downlinks.pruneExpired();

    const registry = gateway_registry.Registry.init(server.app.database());
    const target = try registry.readTarget(gateway_mac);
    defer target.deinit(server.app.allocator);

    const token = pending_downlinks.randomToken();
    const txpk_json = try packets.buildPullRespJson(server.app.allocator, req);
    defer server.app.allocator.free(txpk_json);

    const payload = try packets.encodePullResp(server.app.allocator, packets.semtech_version, token, txpk_json);
    defer server.app.allocator.free(payload);

    try server.socket.sendTo(&target.addr, @sizeOf(posix.sockaddr.in), payload);

    try server.app.pending_downlinks.remember(gateway_mac, token, req.dev_addr);
    try registry.rememberPending(gateway_mac, token, txpk_json);
    return token;
}

fn sendAck(socket: *const udp_transport.Socket, client_addr: *const posix.sockaddr.in, client_len: posix.socklen_t, version: u8, token: u16, ident: u8) !void {
    var ack_buf: [4]u8 = undefined;
    ack_buf[0] = version;
    std.mem.writeInt(u16, ack_buf[1..3], token, .big);
    ack_buf[3] = ident;
    try socket.sendTo(client_addr, client_len, &ack_buf);
}

test "pull data sends pull ack and stores gateway target" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();
    var server = harness.server();

    const fixture = ForwarderFixture{};
    const pull_data = fixture.pullData(0x1234);

    try harness.sendFromClient(&pull_data);
    try drainReady(&server);

    const ack = try harness.recvOnClient();
    defer allocator.free(ack);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        packets.semtech_version,
        0x12,
        0x34,
        packets.pull_ack_ident,
    }, ack);

    const registry = gateway_registry.Registry.init(harness.app.database());
    const target = try registry.readTarget(fixture.gateway_mac);
    defer target.deinit(allocator);

    try std.testing.expectEqual(harness.client_port, std.mem.bigToNative(u16, target.addr.port));
    try std.testing.expectEqual(@as(?u8, packets.semtech_version), target.semtech_version);
    try std.testing.expectEqual(@as(?u16, null), target.pending_token);
}

test "forwarder fixture push data sends ack and records rxpk event" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();
    var server = harness.server();

    const fixture = ForwarderFixture{};
    const rxpk_json = try fixture.rxpkPayloadJson(allocator, "AQID", 42);
    defer allocator.free(rxpk_json);
    const push_data = try fixture.pushDataWithJson(allocator, 0xABCD, rxpk_json);
    defer allocator.free(push_data);

    try harness.sendFromClient(push_data);
    try drainReady(&server);

    const ack = try harness.recvOnClient();
    defer allocator.free(ack);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        packets.semtech_version,
        0xAB,
        0xCD,
        packets.push_ack_ident,
    }, ack);

    try std.testing.expectEqual(@as(i64, 1), try countEvents(&harness.app, "gateway_rxpk"));
}

test "forwarder fixture push data with stat sends ack and records both events" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();
    var server = harness.server();

    const fixture = ForwarderFixture{};
    const payload_json = try fixture.rxpkWithStatPayloadJson(allocator, "AQID", 42);
    defer allocator.free(payload_json);
    const push_data = try fixture.pushDataWithJson(allocator, 0xABCD, payload_json);
    defer allocator.free(push_data);

    try harness.sendFromClient(push_data);
    try drainReady(&server);

    const ack = try harness.recvOnClient();
    defer allocator.free(ack);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        packets.semtech_version,
        0xAB,
        0xCD,
        packets.push_ack_ident,
    }, ack);

    try std.testing.expectEqual(@as(i64, 1), try countEvents(&harness.app, "gateway_rxpk"));
    try std.testing.expectEqual(@as(i64, 1), try countEvents(&harness.app, "gateway_stat"));
}

test "forwarder fixture malformed push data still gets push ack" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();
    var server = harness.server();

    const fixture = ForwarderFixture{};
    const push_data = try fixture.pushDataWithJson(allocator, 0x1011, "bad_json");
    defer allocator.free(push_data);

    try harness.sendFromClient(push_data);
    try drainReady(&server);

    const ack = try harness.recvOnClient();
    defer allocator.free(ack);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        packets.semtech_version,
        0x10,
        0x11,
        packets.push_ack_ident,
    }, ack);

    try std.testing.expectEqual(@as(i64, 0), try countEvents(&harness.app, "gateway_rxpk"));
    try std.testing.expectEqual(@as(i64, 0), try countEvents(&harness.app, "gateway_stat"));
}

test "forwarder fixture push and pull flow yields pull resp and tx ack clears pending state" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();
    var server = harness.server();

    const fixture = ForwarderFixture{};

    try harness.sendFromClient(&fixture.pullData(0x0001));
    try drainReady(&server);
    const pull_ack = try harness.recvOnClient();
    defer allocator.free(pull_ack);

    const rxpk_json = try fixture.rxpkPayloadJson(allocator, "AQID", 7);
    defer allocator.free(rxpk_json);
    const push_data = try fixture.pushDataWithJson(allocator, 0x2222, rxpk_json);
    defer allocator.free(push_data);

    try harness.sendFromClient(push_data);
    try drainReady(&server);
    const push_ack = try harness.recvOnClient();
    defer allocator.free(push_ack);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        packets.semtech_version,
        0x22,
        0x22,
        packets.push_ack_ident,
    }, push_ack);

    const token = try sendDownlink(&harness.app, harness.socket, fixture.gateway_mac, .{
        .gateway_mac = fixture.gateway_mac,
        .dev_addr = "01020304",
        .gateway_tmst = 7,
        .rfch = 0,
        .freq = 868.1,
        .powe = 14,
        .datr = .{ .lora = "SF9BW125" },
        .codr = "4/5",
        .timing = .{ .class_a_delay_s = 1 },
        .phy_payload = &[_]u8{ 0x01, 0x02, 0x03 },
    });

    const pull_resp = try harness.recvOnClient();
    defer allocator.free(pull_resp);
    try std.testing.expectEqual(@as(u8, packets.pull_resp_ident), pull_resp[3]);
    try std.testing.expectEqual(token, std.mem.readInt(u16, pull_resp[1..3], .big));
    try expectPullRespTmst(allocator, pull_resp[4..], 1_000_007);

    const tx_ack = try fixture.txAck(allocator, token, "NONE");
    defer allocator.free(tx_ack);

    try harness.sendFromClient(tx_ack);
    try drainReady(&server);

    try std.testing.expect(harness.app.pending_downlinks.take(fixture.gateway_mac, token) == null);
    try std.testing.expectEqual(@as(i64, 1), try countEvents(&harness.app, "gateway_tx_ack"));
    try std.testing.expectEqual(@as(i64, 0), try countPendingTokens(&harness.app, fixture.gateway_mac));
}

test "pending downlinks are isolated by gateway mac for matching tokens" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    const gateway_a = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const gateway_b = [_]u8{ 8, 7, 6, 5, 4, 3, 2, 1 };
    const token: u16 = 0xCAFE;

    try harness.app.pending_downlinks.remember(gateway_a, token, "01020304");
    try harness.app.pending_downlinks.remember(gateway_b, token, "AABBCCDD");

    const pending_a = harness.app.pending_downlinks.take(gateway_a, token).?;
    defer pending_downlinks.freeEntry(allocator, pending_a);
    try std.testing.expectEqual(gateway_a, pending_a.gateway_mac);
    try std.testing.expectEqualStrings("01020304", pending_a.dev_addr.?);

    const pending_b = harness.app.pending_downlinks.take(gateway_b, token).?;
    defer pending_downlinks.freeEntry(allocator, pending_b);
    try std.testing.expectEqual(gateway_b, pending_b.gateway_mac);
    try std.testing.expectEqualStrings("AABBCCDD", pending_b.dev_addr.?);
}

test "join requests load registered devices from storage and create a node" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();
    var server = harness.server();

    const fixture = ForwarderFixture{};
    try seedGatewayNetwork(harness.app.database(), fixture.gateway_mac);
    try seedDevice(harness.app.database(), "node-a", "1112131415161718", "0102030405060708", "2b7e151628aed2a6abf7158809cf4f3c", "public", "26011bda");

    try harness.sendFromClient(&fixture.pullData(0x0001));
    try drainReady(&server);
    const pull_ack = try harness.recvOnClient();
    defer allocator.free(pull_ack);

    const join_payload = try encodeJoinRequest(
        allocator,
        [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 },
        [_]u8{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18 },
        [_]u8{ 0xAA, 0xBB },
        [_]u8{ 0x2B, 0x7E, 0x15, 0x16, 0x28, 0xAE, 0xD2, 0xA6, 0xAB, 0xF7, 0x15, 0x88, 0x09, 0xCF, 0x4F, 0x3C },
    );
    defer allocator.free(join_payload);
    const join_b64 = try encodeBase64Alloc(allocator, join_payload);
    defer allocator.free(join_b64);
    const rxpk_json = try fixture.rxpkPayloadJson(allocator, join_b64, 42);
    defer allocator.free(rxpk_json);
    const push_data = try fixture.pushDataWithJson(allocator, 0x1200, rxpk_json);
    defer allocator.free(push_data);

    try harness.sendFromClient(push_data);
    try drainReady(&server);

    const push_ack = try harness.recvOnClient();
    defer allocator.free(push_ack);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        packets.semtech_version,
        0x12,
        0x00,
        packets.push_ack_ident,
    }, push_ack);

    const pull_resp = try harness.recvOnClient();
    defer allocator.free(pull_resp);
    try std.testing.expectEqual(@as(u8, packets.pull_resp_ident), pull_resp[3]);
    try std.testing.expectEqual(@as(i64, 1), try countEvents(&harness.app, "lorawan_join_request"));

    const repo = state_repository.Repository.init(harness.app.database());
    const node = (try repo.findNodeByDevAddr(allocator, [_]u8{ 0x26, 0x01, 0x1B, 0xDA })).?;
    defer node.deinit(allocator);
    try std.testing.expectEqual(@as(?i64, 1), node.device_id);
    try std.testing.expectEqual(@as(?u32, null), node.f_cnt_up);
}

test "tx ack persists pending mac commands and later uplink syncs node state" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();
    var server = harness.server();

    const fixture = ForwarderFixture{};
    try seedGatewayNetwork(harness.app.database(), fixture.gateway_mac);
    try seedNode(
        harness.app.database(),
        [_]u8{ 0x01, 0x02, 0x03, 0x04 },
        [_]u8{ 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F },
        [_]u8{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F },
    );

    try harness.sendFromClient(&fixture.pullData(0x0001));
    try drainReady(&server);
    const pull_ack = try harness.recvOnClient();
    defer allocator.free(pull_ack);

    const request_fopts = try lorawan.commands.encodeFOpts(allocator, &[_]lorawan.commands.Command{
        .{ .link_adr_req = .{ .data_rate = 5, .tx_power = 7, .channel_mask = 0x00FF, .ch_mask_cntl = 0, .nb_rep = 1 } },
    });
    defer allocator.free(request_fopts);

    const nwk_s_key = [_]u8{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F };
    const app_s_key = [_]u8{ 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F };
    const downlink_phy = try lorawan.codec.encodeDataDownlink(
        allocator,
        [_]u8{ 0x01, 0x02, 0x03, 0x04 },
        nwk_s_key,
        app_s_key,
        1,
        .{ .confirmed = false, .port = null, .data = "", .pending = false },
        request_fopts,
        false,
        false,
    );
    defer allocator.free(downlink_phy);

    const token = try sendDownlink(&harness.app, harness.socket, fixture.gateway_mac, .{
        .gateway_mac = fixture.gateway_mac,
        .dev_addr = "01020304",
        .gateway_tmst = 7,
        .rfch = 0,
        .freq = 868.1,
        .powe = 14,
        .datr = .{ .lora = "SF9BW125" },
        .codr = "4/5",
        .timing = .{ .class_a_delay_s = 1 },
        .phy_payload = downlink_phy,
    });

    const pull_resp = try harness.recvOnClient();
    defer allocator.free(pull_resp);
    try std.testing.expectEqual(@as(u8, packets.pull_resp_ident), pull_resp[3]);

    const tx_ack = try fixture.txAck(allocator, token, "NONE");
    defer allocator.free(tx_ack);
    try harness.sendFromClient(tx_ack);
    try drainReady(&server);

    {
        const repo = state_repository.Repository.init(harness.app.database());
        const node = (try repo.findNodeByDevAddr(allocator, [_]u8{ 0x01, 0x02, 0x03, 0x04 })).?;
        defer node.deinit(allocator);
        try std.testing.expect(node.pending_mac_commands != null);
        try std.testing.expectEqualSlices(u8, request_fopts, node.pending_mac_commands.?);
    }

    const uplink_fopts = try allocator.dupe(u8, &[_]u8{ 0x03, 0x07 });
    defer allocator.free(uplink_fopts);
    const uplink_phy = try encodeDataUplink(allocator, [_]u8{ 0x01, 0x02, 0x03, 0x04 }, nwk_s_key, 1, uplink_fopts);
    defer allocator.free(uplink_phy);
    const uplink_b64 = try encodeBase64Alloc(allocator, uplink_phy);
    defer allocator.free(uplink_b64);
    const rxpk_json = try fixture.rxpkPayloadJson(allocator, uplink_b64, 77);
    defer allocator.free(rxpk_json);
    const push_data = try fixture.pushDataWithJson(allocator, 0x3333, rxpk_json);
    defer allocator.free(push_data);

    try harness.sendFromClient(push_data);
    try drainReady(&server);

    const push_ack = try harness.recvOnClient();
    defer allocator.free(push_ack);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        packets.semtech_version,
        0x33,
        0x33,
        packets.push_ack_ident,
    }, push_ack);

    {
        const repo = state_repository.Repository.init(harness.app.database());
        const node = (try repo.findNodeByDevAddr(allocator, [_]u8{ 0x01, 0x02, 0x03, 0x04 })).?;
        defer node.deinit(allocator);
        try std.testing.expectEqual(@as(i32, 7), node.adr_use.tx_power);
        try std.testing.expectEqual(@as(u8, 5), node.adr_use.data_rate);
        try std.testing.expectEqual(@as(?u32, 1), node.f_cnt_up);
        try std.testing.expect(node.pending_mac_commands == null);
    }
}

test "reused OTAA dev nonce is rejected after first successful join" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();
    var server = harness.server();

    const fixture = ForwarderFixture{};
    try seedGatewayNetwork(harness.app.database(), fixture.gateway_mac);
    try seedDevice(harness.app.database(), "node-a", "1112131415161718", "0102030405060708", "2b7e151628aed2a6abf7158809cf4f3c", "public", "26011bda");

    try harness.sendFromClient(&fixture.pullData(0x0001));
    try drainReady(&server);
    const pull_ack = try harness.recvOnClient();
    defer allocator.free(pull_ack);

    const join_payload = try encodeJoinRequest(
        allocator,
        [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 },
        [_]u8{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18 },
        [_]u8{ 0xAA, 0xBB },
        [_]u8{ 0x2B, 0x7E, 0x15, 0x16, 0x28, 0xAE, 0xD2, 0xA6, 0xAB, 0xF7, 0x15, 0x88, 0x09, 0xCF, 0x4F, 0x3C },
    );
    defer allocator.free(join_payload);
    const join_b64 = try encodeBase64Alloc(allocator, join_payload);
    defer allocator.free(join_b64);

    const first_rxpk_json = try fixture.rxpkPayloadJson(allocator, join_b64, 42);
    defer allocator.free(first_rxpk_json);
    const first_push_data = try fixture.pushDataWithJson(allocator, 0x2200, first_rxpk_json);
    defer allocator.free(first_push_data);

    try harness.sendFromClient(first_push_data);
    try drainReady(&server);

    const first_push_ack = try harness.recvOnClient();
    defer allocator.free(first_push_ack);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        packets.semtech_version,
        0x22,
        0x00,
        packets.push_ack_ident,
    }, first_push_ack);

    const first_pull_resp = try harness.recvOnClient();
    defer allocator.free(first_pull_resp);
    try std.testing.expectEqual(@as(u8, packets.pull_resp_ident), first_pull_resp[3]);
    try std.testing.expectEqual(@as(i64, 1), try countEvents(&harness.app, "lorawan_join_request"));

    {
        const repo = state_repository.Repository.init(harness.app.database());
        const device = (try repo.findDeviceByDevEui(allocator, [_]u8{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18 })).?;
        defer device.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), device.used_dev_nonces.len);
        try std.testing.expectEqual(@as(u16, 0xBBAA), device.used_dev_nonces[0]);
    }

    const duplicate_rxpk_json = try fixture.rxpkPayloadJson(allocator, join_b64, 43);
    defer allocator.free(duplicate_rxpk_json);
    const duplicate_push_data = try fixture.pushDataWithJson(allocator, 0x2300, duplicate_rxpk_json);
    defer allocator.free(duplicate_push_data);

    try harness.sendFromClient(duplicate_push_data);
    try drainReady(&server);

    const duplicate_push_ack = try harness.recvOnClient();
    defer allocator.free(duplicate_push_ack);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        packets.semtech_version,
        0x23,
        0x00,
        packets.push_ack_ident,
    }, duplicate_push_ack);
    try std.testing.expectError(error.Timeout, harness.recvOnClient());
    try std.testing.expectEqual(@as(i64, 1), try countEvents(&harness.app, "lorawan_join_request"));

    {
        const repo = state_repository.Repository.init(harness.app.database());
        const device = (try repo.findDeviceByDevEui(allocator, [_]u8{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18 })).?;
        defer device.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), device.used_dev_nonces.len);
        try std.testing.expectEqual(@as(u16, 0xBBAA), device.used_dev_nonces[0]);
    }
}

test "successful OTAA rejoins persist and increment app nonce state" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();
    var server = harness.server();

    const fixture = ForwarderFixture{};
    try seedGatewayNetwork(harness.app.database(), fixture.gateway_mac);
    try seedDevice(harness.app.database(), "node-a", "1112131415161718", "0102030405060708", "2b7e151628aed2a6abf7158809cf4f3c", "public", "26011bda");

    try harness.sendFromClient(&fixture.pullData(0x0001));
    try drainReady(&server);
    const pull_ack = try harness.recvOnClient();
    defer allocator.free(pull_ack);

    const first_join_payload = try encodeJoinRequest(
        allocator,
        [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 },
        [_]u8{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18 },
        [_]u8{ 0xAA, 0xBB },
        [_]u8{ 0x2B, 0x7E, 0x15, 0x16, 0x28, 0xAE, 0xD2, 0xA6, 0xAB, 0xF7, 0x15, 0x88, 0x09, 0xCF, 0x4F, 0x3C },
    );
    defer allocator.free(first_join_payload);
    const first_join_b64 = try encodeBase64Alloc(allocator, first_join_payload);
    defer allocator.free(first_join_b64);
    const first_rxpk_json = try fixture.rxpkPayloadJson(allocator, first_join_b64, 42);
    defer allocator.free(first_rxpk_json);
    const first_push_data = try fixture.pushDataWithJson(allocator, 0x2400, first_rxpk_json);
    defer allocator.free(first_push_data);

    try harness.sendFromClient(first_push_data);
    try drainReady(&server);

    const first_push_ack = try harness.recvOnClient();
    defer allocator.free(first_push_ack);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        packets.semtech_version,
        0x24,
        0x00,
        packets.push_ack_ident,
    }, first_push_ack);

    const first_pull_resp = try harness.recvOnClient();
    defer allocator.free(first_pull_resp);
    try std.testing.expectEqual(@as(u8, packets.pull_resp_ident), first_pull_resp[3]);

    {
        const repo = state_repository.Repository.init(harness.app.database());
        const device = (try repo.findDeviceByDevEui(allocator, [_]u8{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18 })).?;
        defer device.deinit(allocator);
        try std.testing.expectEqual(@as(u32, 1), device.next_app_nonce);
        try std.testing.expectEqual(@as(usize, 1), device.used_dev_nonces.len);
        try std.testing.expectEqual(@as(u16, 0xBBAA), device.used_dev_nonces[0]);
    }

    const second_join_payload = try encodeJoinRequest(
        allocator,
        [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 },
        [_]u8{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18 },
        [_]u8{ 0xCC, 0xDD },
        [_]u8{ 0x2B, 0x7E, 0x15, 0x16, 0x28, 0xAE, 0xD2, 0xA6, 0xAB, 0xF7, 0x15, 0x88, 0x09, 0xCF, 0x4F, 0x3C },
    );
    defer allocator.free(second_join_payload);
    const second_join_b64 = try encodeBase64Alloc(allocator, second_join_payload);
    defer allocator.free(second_join_b64);
    const second_rxpk_json = try fixture.rxpkPayloadJson(allocator, second_join_b64, 43);
    defer allocator.free(second_rxpk_json);
    const second_push_data = try fixture.pushDataWithJson(allocator, 0x2500, second_rxpk_json);
    defer allocator.free(second_push_data);

    try harness.sendFromClient(second_push_data);
    try drainReady(&server);

    const second_push_ack = try harness.recvOnClient();
    defer allocator.free(second_push_ack);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        packets.semtech_version,
        0x25,
        0x00,
        packets.push_ack_ident,
    }, second_push_ack);

    const second_pull_resp = try harness.recvOnClient();
    defer allocator.free(second_pull_resp);
    try std.testing.expectEqual(@as(u8, packets.pull_resp_ident), second_pull_resp[3]);

    {
        const repo = state_repository.Repository.init(harness.app.database());
        const device = (try repo.findDeviceByDevEui(allocator, [_]u8{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18 })).?;
        defer device.deinit(allocator);
        try std.testing.expectEqual(@as(u32, 2), device.next_app_nonce);
        try std.testing.expectEqual(@as(usize, 2), device.used_dev_nonces.len);
        try std.testing.expectEqual(@as(u16, 0xBBAA), device.used_dev_nonces[0]);
        try std.testing.expectEqual(@as(u16, 0xDDCC), device.used_dev_nonces[1]);
    }
}

test "duplicate uplink frame counter is rejected without mutating node state" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();
    var server = harness.server();

    const fixture = ForwarderFixture{};
    try seedGatewayNetwork(harness.app.database(), fixture.gateway_mac);
    try seedNode(
        harness.app.database(),
        [_]u8{ 0x01, 0x02, 0x03, 0x04 },
        [_]u8{ 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F },
        [_]u8{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F },
    );

    const nwk_s_key = [_]u8{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F };
    const uplink_phy = try encodeDataUplink(allocator, [_]u8{ 0x01, 0x02, 0x03, 0x04 }, nwk_s_key, 1, &[_]u8{});
    defer allocator.free(uplink_phy);
    const uplink_b64 = try encodeBase64Alloc(allocator, uplink_phy);
    defer allocator.free(uplink_b64);

    const first_rxpk_json = try fixture.rxpkPayloadJson(allocator, uplink_b64, 100);
    defer allocator.free(first_rxpk_json);
    const first_push_data = try fixture.pushDataWithJson(allocator, 0x4444, first_rxpk_json);
    defer allocator.free(first_push_data);

    try harness.sendFromClient(first_push_data);
    try drainReady(&server);

    const first_push_ack = try harness.recvOnClient();
    defer allocator.free(first_push_ack);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        packets.semtech_version,
        0x44,
        0x44,
        packets.push_ack_ident,
    }, first_push_ack);

    {
        const repo = state_repository.Repository.init(harness.app.database());
        const node = (try repo.findNodeByDevAddr(allocator, [_]u8{ 0x01, 0x02, 0x03, 0x04 })).?;
        defer node.deinit(allocator);
        try std.testing.expectEqual(@as(?u32, 1), node.f_cnt_up);
    }
    try std.testing.expectEqual(@as(i64, 1), try countEvents(&harness.app, "lorawan_uplink"));

    const duplicate_rxpk_json = try fixture.rxpkPayloadJson(allocator, uplink_b64, 101);
    defer allocator.free(duplicate_rxpk_json);
    const duplicate_push_data = try fixture.pushDataWithJson(allocator, 0x5555, duplicate_rxpk_json);
    defer allocator.free(duplicate_push_data);

    try harness.sendFromClient(duplicate_push_data);
    try drainReady(&server);

    const duplicate_push_ack = try harness.recvOnClient();
    defer allocator.free(duplicate_push_ack);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        packets.semtech_version,
        0x55,
        0x55,
        packets.push_ack_ident,
    }, duplicate_push_ack);
    try std.testing.expectError(error.Timeout, harness.recvOnClient());

    {
        const repo = state_repository.Repository.init(harness.app.database());
        const node = (try repo.findNodeByDevAddr(allocator, [_]u8{ 0x01, 0x02, 0x03, 0x04 })).?;
        defer node.deinit(allocator);
        try std.testing.expectEqual(@as(?u32, 1), node.f_cnt_up);
        try std.testing.expect(node.pending_mac_commands == null);
    }
    try std.testing.expectEqual(@as(i64, 1), try countEvents(&harness.app, "lorawan_uplink"));
}

test "confirmed uplink triggers empty ack downlink" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();
    var server = harness.server();

    const fixture = ForwarderFixture{};
    try seedGatewayNetwork(harness.app.database(), fixture.gateway_mac);
    try seedNode(
        harness.app.database(),
        [_]u8{ 0x01, 0x02, 0x03, 0x04 },
        [_]u8{ 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F },
        [_]u8{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F },
    );

    try harness.sendFromClient(&fixture.pullData(0x0001));
    try drainReady(&server);
    const pull_ack = try harness.recvOnClient();
    defer allocator.free(pull_ack);

    const nwk_s_key = [_]u8{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F };
    const uplink_phy = try encodeConfirmedDataUplink(allocator, [_]u8{ 0x01, 0x02, 0x03, 0x04 }, nwk_s_key, 1, &[_]u8{});
    defer allocator.free(uplink_phy);
    const uplink_b64 = try encodeBase64Alloc(allocator, uplink_phy);
    defer allocator.free(uplink_b64);

    const rxpk_json = try fixture.rxpkPayloadJson(allocator, uplink_b64, 200);
    defer allocator.free(rxpk_json);
    const push_data = try fixture.pushDataWithJson(allocator, 0x6666, rxpk_json);
    defer allocator.free(push_data);

    try harness.sendFromClient(push_data);
    try drainReady(&server);

    const push_ack = try harness.recvOnClient();
    defer allocator.free(push_ack);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        packets.semtech_version,
        0x66,
        0x66,
        packets.push_ack_ident,
    }, push_ack);

    const pull_resp = try harness.recvOnClient();
    defer allocator.free(pull_resp);
    try std.testing.expectEqual(@as(u8, packets.pull_resp_ident), pull_resp[3]);

    const downlink_phy = try extractPullRespPhyPayload(allocator, pull_resp[4..]);
    defer allocator.free(downlink_phy);
    const decoded = try lorawan.codec.decodeFrame(downlink_phy);
    const frame = switch (decoded) {
        .data => |value| value,
        else => return error.UnexpectedFrameType,
    };

    try std.testing.expect(!frame.is_uplink);
    try std.testing.expect(!frame.confirmed);
    try std.testing.expect(frame.ack);
    try std.testing.expectEqual(@as(u16, 1), frame.f_cnt16);
    try std.testing.expectEqual(@as(usize, 0), frame.f_opts.len);
    try std.testing.expectEqual(@as(?u8, null), frame.f_port);

    {
        const repo = state_repository.Repository.init(harness.app.database());
        const node = (try repo.findNodeByDevAddr(allocator, [_]u8{ 0x01, 0x02, 0x03, 0x04 })).?;
        defer node.deinit(allocator);
        try std.testing.expectEqual(@as(?u32, 1), node.f_cnt_up);
        try std.testing.expectEqual(@as(u32, 1), node.f_cnt_down);
    }
}

test "confirmed downlink is tracked, retried, and cleared by uplink ack" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();
    var server = harness.server();

    const fixture = ForwarderFixture{};
    try seedGatewayNetwork(harness.app.database(), fixture.gateway_mac);
    try seedNode(
        harness.app.database(),
        [_]u8{ 0x01, 0x02, 0x03, 0x04 },
        [_]u8{ 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F },
        [_]u8{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F },
    );

    try harness.sendFromClient(&fixture.pullData(0x0001));
    try drainReady(&server);
    const pull_ack = try harness.recvOnClient();
    defer allocator.free(pull_ack);

    const nwk_s_key = [_]u8{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F };
    const app_s_key = [_]u8{ 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F };
    const confirmed_downlink_phy = try lorawan.codec.encodeDataDownlink(
        allocator,
        [_]u8{ 0x01, 0x02, 0x03, 0x04 },
        nwk_s_key,
        app_s_key,
        1,
        .{ .confirmed = true, .port = 3, .data = "abc", .pending = false },
        &[_]u8{},
        false,
        false,
    );
    defer allocator.free(confirmed_downlink_phy);

    const token = try sendDownlink(&harness.app, harness.socket, fixture.gateway_mac, .{
        .gateway_mac = fixture.gateway_mac,
        .dev_addr = "01020304",
        .gateway_tmst = 7,
        .rfch = 0,
        .freq = 868.1,
        .powe = 14,
        .datr = .{ .lora = "SF9BW125" },
        .codr = "4/5",
        .timing = .{ .class_a_delay_s = 1 },
        .phy_payload = confirmed_downlink_phy,
    });

    const initial_pull_resp = try harness.recvOnClient();
    defer allocator.free(initial_pull_resp);
    try std.testing.expectEqual(@as(u8, packets.pull_resp_ident), initial_pull_resp[3]);

    const tx_ack = try fixture.txAck(allocator, token, "NONE");
    defer allocator.free(tx_ack);
    try harness.sendFromClient(tx_ack);
    try drainReady(&server);

    {
        const repo = state_repository.Repository.init(harness.app.database());
        const node = (try repo.findNodeByDevAddr(allocator, [_]u8{ 0x01, 0x02, 0x03, 0x04 })).?;
        defer node.deinit(allocator);
        try std.testing.expect(node.pending_confirmed_downlink != null);
        try std.testing.expectEqualSlices(u8, confirmed_downlink_phy, node.pending_confirmed_downlink.?);
        try std.testing.expectEqual(@as(u8, 2), node.confirmed_downlink_retries);
    }

    const retry_uplink_phy = try encodeDataUplink(allocator, [_]u8{ 0x01, 0x02, 0x03, 0x04 }, nwk_s_key, 1, &[_]u8{});
    defer allocator.free(retry_uplink_phy);
    const retry_uplink_b64 = try encodeBase64Alloc(allocator, retry_uplink_phy);
    defer allocator.free(retry_uplink_b64);
    const retry_rxpk_json = try fixture.rxpkPayloadJson(allocator, retry_uplink_b64, 201);
    defer allocator.free(retry_rxpk_json);
    const retry_push_data = try fixture.pushDataWithJson(allocator, 0x7777, retry_rxpk_json);
    defer allocator.free(retry_push_data);

    try harness.sendFromClient(retry_push_data);
    try drainReady(&server);

    const retry_push_ack = try harness.recvOnClient();
    defer allocator.free(retry_push_ack);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        packets.semtech_version,
        0x77,
        0x77,
        packets.push_ack_ident,
    }, retry_push_ack);

    const retry_pull_resp = try harness.recvOnClient();
    defer allocator.free(retry_pull_resp);
    const retried_phy = try extractPullRespPhyPayload(allocator, retry_pull_resp[4..]);
    defer allocator.free(retried_phy);
    try std.testing.expectEqualSlices(u8, confirmed_downlink_phy, retried_phy);

    {
        const repo = state_repository.Repository.init(harness.app.database());
        const node = (try repo.findNodeByDevAddr(allocator, [_]u8{ 0x01, 0x02, 0x03, 0x04 })).?;
        defer node.deinit(allocator);
        try std.testing.expect(node.pending_confirmed_downlink != null);
        try std.testing.expectEqual(@as(u8, 1), node.confirmed_downlink_retries);
    }

    const ack_uplink_phy = try encodeAckingDataUplink(allocator, [_]u8{ 0x01, 0x02, 0x03, 0x04 }, nwk_s_key, 2, &[_]u8{});
    defer allocator.free(ack_uplink_phy);
    const ack_uplink_b64 = try encodeBase64Alloc(allocator, ack_uplink_phy);
    defer allocator.free(ack_uplink_b64);
    const ack_rxpk_json = try fixture.rxpkPayloadJson(allocator, ack_uplink_b64, 202);
    defer allocator.free(ack_rxpk_json);
    const ack_push_data = try fixture.pushDataWithJson(allocator, 0x7878, ack_rxpk_json);
    defer allocator.free(ack_push_data);

    try harness.sendFromClient(ack_push_data);
    try drainReady(&server);

    const ack_push_ack = try harness.recvOnClient();
    defer allocator.free(ack_push_ack);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        packets.semtech_version,
        0x78,
        0x78,
        packets.push_ack_ident,
    }, ack_push_ack);
    try std.testing.expectError(error.Timeout, harness.recvOnClient());

    {
        const repo = state_repository.Repository.init(harness.app.database());
        const node = (try repo.findNodeByDevAddr(allocator, [_]u8{ 0x01, 0x02, 0x03, 0x04 })).?;
        defer node.deinit(allocator);
        try std.testing.expect(node.pending_confirmed_downlink == null);
        try std.testing.expectEqual(@as(u8, 0), node.confirmed_downlink_retries);
        try std.testing.expectEqual(@as(?u32, 2), node.f_cnt_up);
    }
}

test "node downlinks prefer RX1 scheduling when uplink state supports it" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();
    var server = harness.server();

    const fixture = ForwarderFixture{};
    try seedGatewayNetwork(harness.app.database(), fixture.gateway_mac);
    try seedNode(
        harness.app.database(),
        [_]u8{ 0x01, 0x02, 0x03, 0x04 },
        [_]u8{ 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F },
        [_]u8{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F },
    );

    {
        const repo = state_repository.Repository.init(harness.app.database());
        var node = (try repo.findNodeByDevAddr(allocator, [_]u8{ 0x01, 0x02, 0x03, 0x04 })).?;
        defer node.deinit(allocator);
        node.rxwin_use.frequency = 869.525;
        node.rxwin_use.rx2_data_rate = 4;
        node.rxwin_use.rx1_dr_offset = 0;
        try repo.upsertNode(allocator, node);
    }

    try harness.sendFromClient(&fixture.pullData(0x0001));
    try drainReady(&server);
    const pull_ack = try harness.recvOnClient();
    defer allocator.free(pull_ack);

    const nwk_s_key = [_]u8{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F };
    const uplink_phy = try encodeConfirmedDataUplink(allocator, [_]u8{ 0x01, 0x02, 0x03, 0x04 }, nwk_s_key, 1, &[_]u8{});
    defer allocator.free(uplink_phy);
    const uplink_b64 = try encodeBase64Alloc(allocator, uplink_phy);
    defer allocator.free(uplink_b64);

    const rxpk_json = try fixture.rxpkPayloadJson(allocator, uplink_b64, 321);
    defer allocator.free(rxpk_json);
    const push_data = try fixture.pushDataWithJson(allocator, 0x7979, rxpk_json);
    defer allocator.free(push_data);

    try harness.sendFromClient(push_data);
    try drainReady(&server);

    const push_ack = try harness.recvOnClient();
    defer allocator.free(push_ack);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        packets.semtech_version,
        0x79,
        0x79,
        packets.push_ack_ident,
    }, push_ack);

    const pull_resp = try harness.recvOnClient();
    defer allocator.free(pull_resp);
    try expectPullRespSettings(allocator, pull_resp[4..], 1_000_321, 868.1, "SF12BW125");
}

test "node downlinks fall back to RX2 scheduling when RX1 cannot be derived" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();
    var server = harness.server();

    const fixture = ForwarderFixture{ .datr = "UNSUPPORTED" };
    try seedGatewayNetwork(harness.app.database(), fixture.gateway_mac);
    try seedNode(
        harness.app.database(),
        [_]u8{ 0x01, 0x02, 0x03, 0x04 },
        [_]u8{ 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F },
        [_]u8{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F },
    );

    {
        const repo = state_repository.Repository.init(harness.app.database());
        var node = (try repo.findNodeByDevAddr(allocator, [_]u8{ 0x01, 0x02, 0x03, 0x04 })).?;
        defer node.deinit(allocator);
        node.rxwin_use.frequency = 869.525;
        node.rxwin_use.rx2_data_rate = 4;
        node.rxwin_use.rx1_dr_offset = 0;
        try repo.upsertNode(allocator, node);
    }

    try harness.sendFromClient(&fixture.pullData(0x0001));
    try drainReady(&server);
    const pull_ack = try harness.recvOnClient();
    defer allocator.free(pull_ack);

    const nwk_s_key = [_]u8{ 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F };
    const uplink_phy = try encodeConfirmedDataUplink(allocator, [_]u8{ 0x01, 0x02, 0x03, 0x04 }, nwk_s_key, 1, &[_]u8{});
    defer allocator.free(uplink_phy);
    const uplink_b64 = try encodeBase64Alloc(allocator, uplink_phy);
    defer allocator.free(uplink_b64);

    const rxpk_json = try fixture.rxpkPayloadJson(allocator, uplink_b64, 321);
    defer allocator.free(rxpk_json);
    const push_data = try fixture.pushDataWithJson(allocator, 0x7979, rxpk_json);
    defer allocator.free(push_data);

    try harness.sendFromClient(push_data);
    try drainReady(&server);

    const push_ack = try harness.recvOnClient();
    defer allocator.free(push_ack);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        packets.semtech_version,
        0x79,
        0x79,
        packets.push_ack_ident,
    }, push_ack);

    const pull_resp = try harness.recvOnClient();
    defer allocator.free(pull_resp);
    try expectPullRespSettings(allocator, pull_resp[4..], 2_000_321, 869.525, "SF8BW125");
}

const ForwarderFixture = struct {
    gateway_mac: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 },
    freq: f64 = 868.10,
    datr: []const u8 = "SF12BW125",
    codr: []const u8 = "4/5",

    fn rxpkPayloadJson(self: ForwarderFixture, allocator: std.mem.Allocator, base64_data: []const u8, tmst: u64) ![]u8 {
        _ = self;
        return std.json.Stringify.valueAlloc(allocator, .{
            .rxpk = &[_]struct {
                modu: []const u8,
                freq: f64,
                datr: []const u8,
                codr: []const u8,
                data: []const u8,
                tmst: u64,
            }{.{
                .modu = "LORA",
                .freq = 868.10,
                .datr = "SF12BW125",
                .codr = "4/5",
                .data = base64_data,
                .tmst = tmst,
            }},
        }, .{});
    }

    fn rxpkWithStatPayloadJson(self: ForwarderFixture, allocator: std.mem.Allocator, base64_data: []const u8, tmst: u64) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, .{
            .rxpk = &[_]struct {
                modu: []const u8,
                freq: f64,
                datr: []const u8,
                codr: []const u8,
                data: []const u8,
                tmst: u64,
            }{.{
                .modu = "LORA",
                .freq = self.freq,
                .datr = self.datr,
                .codr = self.codr,
                .data = base64_data,
                .tmst = tmst,
            }},
            .stat = .{ .rxnb = 1 },
        }, .{});
    }

    fn pushDataWithJson(self: ForwarderFixture, allocator: std.mem.Allocator, token: u16, json_payload: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{c}{c}{c}{c}{s}{s}", .{
            packets.semtech_version,
            @as(u8, @truncate(token >> 8)),
            @as(u8, @truncate(token)),
            packets.push_data_ident,
            self.gateway_mac[0..],
            json_payload,
        });
    }

    fn pullData(self: ForwarderFixture, token: u16) [12]u8 {
        return .{
            packets.semtech_version,
            @as(u8, @truncate(token >> 8)),
            @as(u8, @truncate(token)),
            packets.pull_data_ident,
            self.gateway_mac[0],
            self.gateway_mac[1],
            self.gateway_mac[2],
            self.gateway_mac[3],
            self.gateway_mac[4],
            self.gateway_mac[5],
            self.gateway_mac[6],
            self.gateway_mac[7],
        };
    }

    fn txAck(self: ForwarderFixture, allocator: std.mem.Allocator, token: u16, error_name: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{c}{c}{c}{c}{s}{{\"txpk_ack\":{{\"error\":\"{s}\"}}}}", .{
            packets.semtech_version,
            @as(u8, @truncate(token >> 8)),
            @as(u8, @truncate(token)),
            packets.tx_ack_ident,
            self.gateway_mac[0..],
            error_name,
        });
    }
};

const TestHarness = struct {
    allocator: std.mem.Allocator,
    app: App,
    db_path: []u8,
    socket: udp_transport.Socket,
    client_fd: posix.socket_t,
    client_port: u16,

    fn init(allocator: std.mem.Allocator) !TestHarness {
        const db_path = try std.fmt.allocPrint(allocator, "/tmp/lorawan-server-udp-test-{d}.db", .{std.time.nanoTimestamp()});
        errdefer allocator.free(db_path);

        var app = try App.init(allocator, db_path);
        errdefer app.deinit();

        var cfg = try Config.initWithDefaultFrontendPath(
            allocator,
            "0.0.0.0",
            0,
            0,
            db_path,
            app_mod.AdminConfig.init(null, null),
        );
        defer cfg.deinit();

        const socket = initServerSocket(&cfg) catch |err| switch (err) {
            error.SocketOpenFailed, error.SocketConfigureFailed, error.SocketBindFailed => return error.SkipZigTest,
            else => return err,
        };
        errdefer socket.close();

        const client_fd = posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0) catch |err| switch (err) {
            error.Unexpected, error.AccessDenied => return error.SkipZigTest,
            else => return err,
        };
        errdefer posix.close(client_fd);

        var client_addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = 0,
            .addr = ipv4(127, 0, 0, 1),
            .zero = [_]u8{0} ** 8,
        };
        posix.bind(client_fd, @ptrCast(&client_addr), @sizeOf(posix.sockaddr.in)) catch |err| switch (err) {
            error.Unexpected, error.AccessDenied => return error.SkipZigTest,
            else => return err,
        };

        const harness = TestHarness{
            .allocator = allocator,
            .app = app,
            .db_path = db_path,
            .socket = socket,
            .client_fd = client_fd,
            .client_port = try localPort(client_fd),
        };
        return harness;
    }

    fn deinit(self: *TestHarness) void {
        posix.close(self.client_fd);
        self.socket.close();
        self.app.deinit();
        std.fs.deleteFileAbsolute(self.db_path) catch {};
        self.allocator.free(self.db_path);
    }

    fn server(self: *TestHarness) Server {
        return Server.init(&self.app, self.socket);
    }

    fn sendFromClient(self: *TestHarness, payload: []const u8) !void {
        var server_addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, try localPort(self.socket.fd)),
            .addr = ipv4(127, 0, 0, 1),
            .zero = [_]u8{0} ** 8,
        };
        _ = try posix.sendto(self.client_fd, payload, 0, @ptrCast(&server_addr), @sizeOf(posix.sockaddr.in));
    }

    fn recvOnClient(self: *TestHarness) ![]u8 {
        var pollfd = [_]posix.pollfd{.{ .fd = self.client_fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = try posix.poll(&pollfd, 1_000);
        if (ready == 0 or (pollfd[0].revents & posix.POLL.IN) == 0) return error.Timeout;

        var buf: [2048]u8 = undefined;
        var from_addr: posix.sockaddr.in = undefined;
        var from_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        const len = try posix.recvfrom(self.client_fd, &buf, 0, @ptrCast(&from_addr), &from_len);
        return self.allocator.dupe(u8, buf[0..len]);
    }
};

fn localPort(fd: posix.socket_t) !u16 {
    var addr: posix.sockaddr.in = undefined;
    var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try posix.getsockname(fd, @ptrCast(&addr), &len);
    return std.mem.bigToNative(u16, addr.port);
}

fn ipv4(a: u8, b: u8, c: u8, d: u8) u32 {
    return @bitCast([4]u8{ a, b, c, d });
}

fn countEvents(app: *App, event_type: []const u8) !i64 {
    return event_repository.Repository.init(app.database()).countByType(event_type);
}

fn countPendingTokens(app: *App, gateway_mac: [8]u8) !i64 {
    return gateway_registry.Registry.init(app.database()).countPending(gateway_mac);
}

fn expectPullRespTmst(allocator: std.mem.Allocator, json_payload: []const u8, expected_tmst: i64) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{});
    defer parsed.deinit();

    const txpk = parsed.value.object.get("txpk").?.object;
    try std.testing.expectEqual(expected_tmst, txpk.get("tmst").?.integer);
}

fn expectPullRespSettings(allocator: std.mem.Allocator, json_payload: []const u8, expected_tmst: i64, expected_freq: f64, expected_datr: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{});
    defer parsed.deinit();

    const txpk = parsed.value.object.get("txpk").?.object;
    try std.testing.expectEqual(expected_tmst, txpk.get("tmst").?.integer);
    try std.testing.expectEqual(expected_freq, txpk.get("freq").?.float);
    try std.testing.expectEqualStrings(expected_datr, txpk.get("datr").?.string);
}

fn seedGatewayNetwork(db: app_mod.Database, gateway_mac: [8]u8) !void {
    const gateway_hex = packets.gatewayMacHex(gateway_mac);
    const network_stmt = try storage.Statement.prepare(db.conn, "INSERT INTO networks(name, network_json) VALUES(?, ?);");
    defer network_stmt.deinit();
    network_stmt.bindText(1, "public");
    network_stmt.bindText(2, "{\"netid\":\"000013\",\"tx_codr\":\"4/5\",\"join1_delay\":5,\"rx1_delay\":1,\"gw_power\":14,\"rxwin_init\":{\"rx1_dr_offset\":0,\"rx2_data_rate\":0,\"frequency\":869.525}}");
    try network_stmt.expectDone();

    const gateway_stmt = try storage.Statement.prepare(db.conn, "INSERT INTO gateways(mac, name, network_name, gateway_json) VALUES(?, ?, ?, ?);");
    defer gateway_stmt.deinit();
    gateway_stmt.bindText(1, gateway_hex[0..]);
    gateway_stmt.bindText(2, "gateway-a");
    gateway_stmt.bindText(3, "public");
    gateway_stmt.bindText(4, "{\"tx_rfch\":0}");
    try gateway_stmt.expectDone();
}

fn seedDevice(db: app_mod.Database, name: []const u8, dev_eui: []const u8, app_eui: []const u8, app_key: []const u8, network_name: []const u8, dev_addr: []const u8) !void {
    const stmt = try storage.Statement.prepare(db.conn, "INSERT INTO devices(name, dev_eui, app_eui, app_key, device_json) VALUES(?, ?, ?, ?, ?);");
    defer stmt.deinit();
    const device_json = try std.fmt.allocPrint(db.allocator, "{{\"network_name\":\"{s}\",\"dev_addr\":\"{s}\"}}", .{ network_name, dev_addr });
    defer db.allocator.free(device_json);
    stmt.bindText(1, name);
    stmt.bindText(2, dev_eui);
    stmt.bindText(3, app_eui);
    stmt.bindText(4, app_key);
    stmt.bindText(5, device_json);
    try stmt.expectDone();
}

fn seedNode(db: app_mod.Database, dev_addr: [4]u8, app_s_key: [16]u8, nwk_s_key: [16]u8) !void {
    const repo = state_repository.Repository.init(db);
    const node = lorawan.types.Node.init(dev_addr, app_s_key, nwk_s_key, .{}, .{ .tx_power = 0, .data_rate = 0 });
    try repo.upsertNode(db.allocator, node);
}

fn encodeBase64Alloc(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, encoder.calcSize(data.len));
    _ = encoder.encode(out, data);
    return out;
}

fn extractPullRespPhyPayload(allocator: std.mem.Allocator, json_payload: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{});
    defer parsed.deinit();

    const txpk = parsed.value.object.get("txpk").?.object;
    const data = txpk.get("data").?.string;
    const decoder = std.base64.standard.Decoder;
    const out = try allocator.alloc(u8, try decoder.calcSizeForSlice(data));
    errdefer allocator.free(out);
    try decoder.decode(out, data);
    return out;
}

fn encodeConfirmedDataUplink(allocator: std.mem.Allocator, dev_addr: [4]u8, nwk_s_key: [16]u8, f_cnt_up: u32, f_opts: []const u8) ![]u8 {
    return encodeDataUplinkWithFlags(allocator, 0b10000000, dev_addr, nwk_s_key, f_cnt_up, f_opts, false);
}

fn encodeAckingDataUplink(allocator: std.mem.Allocator, dev_addr: [4]u8, nwk_s_key: [16]u8, f_cnt_up: u32, f_opts: []const u8) ![]u8 {
    return encodeDataUplinkWithFlags(allocator, 0b01000000, dev_addr, nwk_s_key, f_cnt_up, f_opts, true);
}

fn encodeDataUplink(allocator: std.mem.Allocator, dev_addr: [4]u8, nwk_s_key: [16]u8, f_cnt_up: u32, f_opts: []const u8) ![]u8 {
    return encodeDataUplinkWithFlags(allocator, 0b01000000, dev_addr, nwk_s_key, f_cnt_up, f_opts, false);
}

fn encodeDataUplinkWithFlags(allocator: std.mem.Allocator, mhdr: u8, dev_addr: [4]u8, nwk_s_key: [16]u8, f_cnt_up: u32, f_opts: []const u8, ack: bool) ![]u8 {
    var buffer = std.ArrayList(u8){};
    defer buffer.deinit(allocator);

    try buffer.append(allocator, mhdr);

    const dev_addr_le = [_]u8{ dev_addr[3], dev_addr[2], dev_addr[1], dev_addr[0] };
    try buffer.appendSlice(allocator, &dev_addr_le);
    try buffer.append(allocator, (@as(u8, if (ack) 1 else 0) << 5) | @as(u8, @intCast(f_opts.len)));

    var fcnt_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &fcnt_buf, @intCast(f_cnt_up & 0xFFFF), .little);
    try buffer.appendSlice(allocator, &fcnt_buf);
    try buffer.appendSlice(allocator, f_opts);

    const message = try buffer.toOwnedSlice(allocator);
    errdefer allocator.free(message);

    var b0: [16]u8 = [_]u8{0} ** 16;
    b0[0] = 0x49;
    @memcpy(b0[6..10], &dev_addr_le);
    std.mem.writeInt(u32, b0[10..14], f_cnt_up, .little);
    b0[15] = @intCast(message.len);

    const cmac_input = try allocator.alloc(u8, b0.len + message.len);
    defer allocator.free(cmac_input);
    @memcpy(cmac_input[0..b0.len], &b0);
    @memcpy(cmac_input[b0.len..], message);

    var mac: [16]u8 = undefined;
    std.crypto.auth.cmac.CmacAes128.create(&mac, cmac_input, &nwk_s_key);

    const out = try allocator.alloc(u8, message.len + 4);
    @memcpy(out[0..message.len], message);
    @memcpy(out[message.len..], mac[0..4]);
    allocator.free(message);
    return out;
}

fn encodeJoinRequest(allocator: std.mem.Allocator, app_eui: [8]u8, dev_eui: [8]u8, dev_nonce: [2]u8, app_key: [16]u8) ![]u8 {
    var payload = try allocator.alloc(u8, 23);
    errdefer allocator.free(payload);

    payload[0] = 0x00;

    const app_eui_le = [_]u8{ app_eui[7], app_eui[6], app_eui[5], app_eui[4], app_eui[3], app_eui[2], app_eui[1], app_eui[0] };
    const dev_eui_le = [_]u8{ dev_eui[7], dev_eui[6], dev_eui[5], dev_eui[4], dev_eui[3], dev_eui[2], dev_eui[1], dev_eui[0] };
    @memcpy(payload[1..9], &app_eui_le);
    @memcpy(payload[9..17], &dev_eui_le);
    @memcpy(payload[17..19], &dev_nonce);

    var mac: [16]u8 = undefined;
    std.crypto.auth.cmac.CmacAes128.create(&mac, payload[0..19], &app_key);
    @memcpy(payload[19..23], mac[0..4]);
    return payload;
}
