const std = @import("std");
const posix = std.posix;

const app_mod = @import("../app.zig");
const event_repository = @import("../repository/event_repository.zig");
const logger = @import("../logger.zig");
const lorawan = @import("../lorawan.zig");
const udp_transport = @import("transport.zig");
const App = app_mod.App;
const Config = app_mod.Config;
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

    try gateway_registry.touch(context.server.app, push.gateway_mac, version, &context.client_addr);

    for (push.rxpk.items) |rxpk| {
        try gateway_registry.insertEvent(context.server.app, "gateway_rxpk", push.gateway_mac, try packets.encodeNormalizedRxpk(context.server.app.allocator, push.gateway_mac, rxpk));

        const maybe_ingested = lorawan.service.ingestRxpk(context.server.app, context.server.app.allocator, push.gateway_mac, rxpk) catch |err| blk: {
            logger.warn("udp", "lorawan_ingest_failed", "failed to ingest LoRaWAN uplink", .{
                .gateway_mac = packets.gatewayMacHex(push.gateway_mac),
                .error_name = @errorName(err),
            });
            break :blk null;
        };

        if (maybe_ingested) |ingested| {
            defer ingested.deinit(context.server.app.allocator);

            try gateway_registry.insertEvent(context.server.app, ingested.event_type, push.gateway_mac, try context.server.app.allocator.dupe(u8, ingested.event_json));

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
        try gateway_registry.insertEvent(context.server.app, "gateway_stat", push.gateway_mac, stat.json);
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
    try gateway_registry.rememberPullTarget(context.server.app, gateway_mac, version, &context.client_addr);
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

    const maybe_pending = context.server.app.pending_downlinks.take(ack.gateway_mac, ack.token);
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

    try gateway_registry.clearPending(context.server.app, ack.gateway_mac, ack.token);

    try gateway_registry.insertEvent(context.server.app, "gateway_tx_ack", ack.gateway_mac, try packets.encodeTxAckEvent(
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
    server.app.pending_downlinks.pruneExpired();

    const target = try gateway_registry.readTarget(server.app, gateway_mac);
    defer target.deinit(server.app.allocator);

    const token = pending_downlinks.randomToken();
    const txpk_json = try packets.buildPullRespJson(server.app.allocator, req);
    errdefer server.app.allocator.free(txpk_json);

    const payload = try packets.encodePullResp(server.app.allocator, packets.semtech_version, token, txpk_json);
    defer server.app.allocator.free(payload);

    try server.socket.sendTo(&target.addr, @sizeOf(posix.sockaddr.in), payload);

    try server.app.pending_downlinks.remember(gateway_mac, token, req.dev_addr);
    try gateway_registry.rememberPending(server.app, gateway_mac, token, txpk_json);
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

    const target = try gateway_registry.readTarget(&harness.app, fixture.gateway_mac);
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
    const push_data = try fixture.pushDataWithJson(allocator, 0xABCD, try fixture.rxpkPayloadJson(allocator, "AQID", 42));
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

    const push_data = try fixture.pushDataWithJson(allocator, 0x2222, try fixture.rxpkPayloadJson(allocator, "AQID", 7));
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

        var cfg = Config{
            .allocator = allocator,
            .bind_address = "0.0.0.0",
            .udp_port = 0,
            .http_port = 0,
            .db_path = db_path,
            .admin = .{ .user = null, .pass = null },
        };

        const socket = initServerSocket(&cfg) catch |err| switch (err) {
            error.Unexpected, error.AccessDenied => return error.SkipZigTest,
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
    return event_repository.Repository.init(app).countByType(event_type);
}

fn countPendingTokens(app: *App, gateway_mac: [8]u8) !i64 {
    return gateway_registry.countPending(app, gateway_mac);
}

fn expectPullRespTmst(allocator: std.mem.Allocator, json_payload: []const u8, expected_tmst: i64) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{});
    defer parsed.deinit();

    const txpk = parsed.value.object.get("txpk").?.object;
    try std.testing.expectEqual(expected_tmst, txpk.get("tmst").?.integer);
}
