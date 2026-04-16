const std = @import("std");
const app_mod = @import("app.zig");
const logger = @import("logger.zig");
const connectors_repository = @import("repository/connectors_repository.zig");

const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const Database = app_mod.Database;

pub const Kind = enum {
    mqtt,
    ws,
    rabbitmq,
    kafka,

    pub fn parse(raw: []const u8) !Kind {
        if (std.mem.eql(u8, raw, "mqtt")) return .mqtt;
        if (std.mem.eql(u8, raw, "ws")) return .ws;
        if (std.mem.eql(u8, raw, "rabbitmq")) return .rabbitmq;
        if (std.mem.eql(u8, raw, "kafka")) return .kafka;
        return error.UnsupportedConnectorKind;
    }
};

pub const ConfigEntry = struct {
    name: []u8,
    kind: Kind,
    uri: []u8,
    enabled: bool,
    topic: ?[]u8,
    exchange: ?[]u8,
    routing_key: ?[]u8,
    partition: i32,
    client_id: ?[]u8,
    username: ?[]u8,
    password: ?[]u8,

    pub fn clone(self: ConfigEntry, allocator: std.mem.Allocator) !ConfigEntry {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .kind = self.kind,
            .uri = try allocator.dupe(u8, self.uri),
            .enabled = self.enabled,
            .topic = if (self.topic) |value| try allocator.dupe(u8, value) else null,
            .exchange = if (self.exchange) |value| try allocator.dupe(u8, value) else null,
            .routing_key = if (self.routing_key) |value| try allocator.dupe(u8, value) else null,
            .partition = self.partition,
            .client_id = if (self.client_id) |value| try allocator.dupe(u8, value) else null,
            .username = if (self.username) |value| try allocator.dupe(u8, value) else null,
            .password = if (self.password) |value| try allocator.dupe(u8, value) else null,
        };
    }

    pub fn deinit(self: *ConfigEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.uri);
        if (self.topic) |value| allocator.free(value);
        if (self.exchange) |value| allocator.free(value);
        if (self.routing_key) |value| allocator.free(value);
        if (self.client_id) |value| allocator.free(value);
        if (self.username) |value| allocator.free(value);
        if (self.password) |value| allocator.free(value);
    }
};

fn validateConfig(entry: ConfigEntry) !void {
    switch (entry.kind) {
        .mqtt => if (entry.topic == null) return error.MissingConnectorTopic,
        .rabbitmq => {
            if (entry.exchange == null) return error.MissingConnectorExchange;
            if (entry.routing_key == null) return error.MissingConnectorRoutingKey;
        },
        .kafka => if (entry.topic == null) return error.MissingConnectorTopic,
        .ws => {},
    }
}

pub const PublishedEvent = struct {
    event_type: []const u8,
    gateway_mac: [8]u8,
    payload_json: []const u8,
    received_at_ms: i64,
};

pub fn publishFromDatabase(allocator: std.mem.Allocator, db: Database, event: PublishedEvent) void {
    const envelope = encodeEnvelope(allocator, event) catch |err| {
        logger.warn("connectors", "encode_failed", "failed to encode connector payload", .{
            .error_name = @errorName(err),
            .event_type = event.event_type,
        });
        return;
    };
    defer allocator.free(envelope);

    const repo = connectors_repository.Repository.init(db);
    const records = repo.listEnabled(allocator) catch |err| {
        logger.warn("connectors", "load_failed", "failed to load connector configuration from database", .{
            .error_name = @errorName(err),
        });
        return;
    };
    defer {
        for (records) |*record| record.deinit(allocator);
        allocator.free(records);
    }

    for (records) |record| {
        var config = configFromRecord(allocator, record) catch |err| {
            logger.warn("connectors", "config_invalid", "connector configuration is invalid", .{
                .name = record.name,
                .error_name = @errorName(err),
            });
            continue;
        };
        defer config.deinit(allocator);

        publishOne(allocator, config, envelope) catch |err| {
            logger.warn("connectors", "publish_failed", "connector publish failed", .{
                .name = config.name,
                .kind = @tagName(config.kind),
                .error_name = @errorName(err),
            });
        };
    }
}

fn configFromRecord(allocator: std.mem.Allocator, record: connectors_repository.Record) !ConfigEntry {
    var config = ConfigEntry{
        .name = try allocator.dupe(u8, record.name),
        .kind = try Kind.parse(record.connector_type),
        .uri = try allocator.dupe(u8, record.uri),
        .enabled = record.enabled,
        .topic = if (record.topic) |value| try allocator.dupe(u8, value) else null,
        .exchange = if (record.exchange_name) |value| try allocator.dupe(u8, value) else null,
        .routing_key = if (record.routing_key) |value| try allocator.dupe(u8, value) else null,
        .partition = record.partition,
        .client_id = if (record.client_id) |value| try allocator.dupe(u8, value) else null,
        .username = if (record.username) |value| try allocator.dupe(u8, value) else null,
        .password = if (record.password) |value| try allocator.dupe(u8, value) else null,
    };
    errdefer config.deinit(allocator);

    try validateConfig(config);
    return config;
}

fn encodeEnvelope(allocator: std.mem.Allocator, event: PublishedEvent) ![]u8 {
    var list = std.ArrayList(u8){};
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "{\"event_type\":");
    try list.writer(allocator).print("{f}", .{std.json.fmt(event.event_type, .{})});
    try list.appendSlice(allocator, ",\"gateway_mac\":\"");
    const mac = gatewayMacHex(event.gateway_mac);
    try list.appendSlice(allocator, mac[0..]);
    try list.appendSlice(allocator, "\",\"received_at_ms\":");
    try list.writer(allocator).print("{d}", .{event.received_at_ms});
    try list.appendSlice(allocator, ",\"payload\":");
    try list.appendSlice(allocator, event.payload_json);
    try list.append(allocator, '}');

    return list.toOwnedSlice(allocator);
}

fn publishOne(allocator: std.mem.Allocator, config: ConfigEntry, payload: []const u8) !void {
    const endpoint = try Endpoint.parse(allocator, config);
    defer endpoint.deinit(allocator);

    var stream = try std.net.tcpConnectToHost(allocator, endpoint.host, endpoint.port);
    defer stream.close();

    switch (config.kind) {
        .mqtt => try mqttPublish(allocator, &stream, endpoint, config, payload),
        .ws => try websocketSend(allocator, &stream, endpoint, config, payload),
        .rabbitmq => try rabbitmqPublish(allocator, &stream, endpoint, config, payload),
        .kafka => try kafkaPublish(allocator, &stream, config, payload),
    }
}

const Endpoint = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
    username: ?[]const u8,
    password: ?[]const u8,

    fn parse(allocator: std.mem.Allocator, config: ConfigEntry) !Endpoint {
        const uri = try std.Uri.parse(config.uri);
        const host = try uri.getHostAlloc(allocator);
        errdefer allocator.free(host);

        const path = try uri.path.toRawMaybeAlloc(allocator);
        errdefer if (path.ptr != uri.path.percent_encoded.ptr and path.ptr != uri.path.raw.ptr) allocator.free(path);

        const user = if (config.username) |value|
            try allocator.dupe(u8, value)
        else if (uri.user) |value|
            try value.toRawMaybeAlloc(allocator)
        else
            null;
        errdefer if (user) |value| allocator.free(value);

        const pass = if (config.password) |value|
            try allocator.dupe(u8, value)
        else if (uri.password) |value|
            try value.toRawMaybeAlloc(allocator)
        else
            null;
        errdefer if (pass) |value| allocator.free(value);

        return .{
            .host = host,
            .port = uri.port orelse defaultPort(config.kind),
            .path = if (path.len == 0) "/" else path,
            .username = user,
            .password = pass,
        };
    }

    fn deinit(self: Endpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        if (self.path.len > 0 and self.path.ptr != "/".ptr) allocator.free(self.path);
        if (self.username) |value| allocator.free(value);
        if (self.password) |value| allocator.free(value);
    }
};

fn defaultPort(kind: Kind) u16 {
    return switch (kind) {
        .mqtt => 1883,
        .ws => 80,
        .rabbitmq => 5672,
        .kafka => 9092,
    };
}

fn mqttPublish(allocator: std.mem.Allocator, stream: *std.net.Stream, endpoint: Endpoint, config: ConfigEntry, payload: []const u8) !void {
    const topic = try expandPattern(allocator, config.topic.?, payload);
    defer allocator.free(topic);

    const client_id = if (config.client_id) |value| value else config.name;

    const connect_packet = try buildMqttConnectPacket(allocator, client_id, endpoint.username, endpoint.password);
    defer allocator.free(connect_packet);
    try stream.writeAll(connect_packet);

    var connack: [4]u8 = undefined;
    try readNoEof(stream, connack[0..]);
    if (connack[0] != 0x20 or connack[1] != 0x02 or connack[3] != 0x00) {
        return error.MqttConnectRejected;
    }

    const publish_packet = try buildMqttPublishPacket(allocator, topic, payload);
    defer allocator.free(publish_packet);
    try stream.writeAll(publish_packet);

    try stream.writeAll(&.{ 0xE0, 0x00 });
}

fn buildMqttConnectPacket(allocator: std.mem.Allocator, client_id: []const u8, username: ?[]const u8, password: ?[]const u8) ![]u8 {
    var variable = std.ArrayList(u8){};
    defer variable.deinit(allocator);

    try appendPrefixedBytes(&variable, allocator, "MQTT");
    try variable.append(allocator, 0x04);
    var flags: u8 = 0x02;
    if (username != null) flags |= 0x80;
    if (password != null) flags |= 0x40;
    try variable.append(allocator, flags);
    try appendU16(&variable, allocator, 30);
    try appendPrefixedBytes(&variable, allocator, client_id);
    if (username) |value| try appendPrefixedBytes(&variable, allocator, value);
    if (password) |value| try appendPrefixedBytes(&variable, allocator, value);

    return buildFixedHeaderPacket(allocator, 0x10, variable.items);
}

fn buildMqttPublishPacket(allocator: std.mem.Allocator, topic: []const u8, payload: []const u8) ![]u8 {
    var variable = std.ArrayList(u8){};
    defer variable.deinit(allocator);

    try appendPrefixedBytes(&variable, allocator, topic);
    try variable.appendSlice(allocator, payload);

    return buildFixedHeaderPacket(allocator, 0x30, variable.items);
}

fn buildFixedHeaderPacket(allocator: std.mem.Allocator, packet_type: u8, body: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try out.append(allocator, packet_type);
    try encodeMqttRemainingLength(&out, allocator, body.len);
    try out.appendSlice(allocator, body);
    return out.toOwnedSlice(allocator);
}

fn encodeMqttRemainingLength(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: usize) !void {
    var remaining = value;
    while (true) {
        var encoded: u8 = @intCast(remaining % 128);
        remaining /= 128;
        if (remaining > 0) encoded |= 0x80;
        try out.append(allocator, encoded);
        if (remaining == 0) return;
    }
}

fn websocketSend(allocator: std.mem.Allocator, stream: *std.net.Stream, endpoint: Endpoint, _: ConfigEntry, payload: []const u8) !void {
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
        const auth_value = try basicAuthHeader(allocator, endpoint.username orelse "", endpoint.password orelse "");
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

    const frame = try buildWebSocketTextFrame(allocator, payload);
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

fn buildWebSocketTextFrame(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try out.append(allocator, 0x81);

    var mask: [4]u8 = undefined;
    std.crypto.random.bytes(&mask);

    if (payload.len < 126) {
        try out.append(allocator, 0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 0xFFFF) {
        try out.append(allocator, 0x80 | 126);
        try appendU16(&out, allocator, @intCast(payload.len));
    } else {
        try out.append(allocator, 0x80 | 127);
        try appendU64(&out, allocator, payload.len);
    }

    try out.appendSlice(allocator, &mask);
    for (payload, 0..) |byte, i| {
        try out.append(allocator, byte ^ mask[i % mask.len]);
    }

    return out.toOwnedSlice(allocator);
}

fn rabbitmqPublish(allocator: std.mem.Allocator, stream: *std.net.Stream, endpoint: Endpoint, config: ConfigEntry, payload: []const u8) !void {
    try stream.writeAll("AMQP\x00\x00\x09\x01");

    const start = try readAmqpFrame(allocator, stream);
    defer allocator.free(start.payload);
    if (start.frame_type != 1 or methodClass(start.payload) != 10 or methodMethod(start.payload) != 10) {
        return error.AmqpUnexpectedFrame;
    }

    const start_ok = try buildAmqpStartOk(allocator, endpoint.username orelse "guest", endpoint.password orelse "guest");
    defer allocator.free(start_ok);
    try stream.writeAll(start_ok);

    const tune = try readAmqpFrame(allocator, stream);
    defer allocator.free(tune.payload);
    if (tune.frame_type != 1 or methodClass(tune.payload) != 10 or methodMethod(tune.payload) != 30) {
        return error.AmqpUnexpectedFrame;
    }

    const frame_max = if (tune.payload.len >= 12) std.mem.readInt(u32, tune.payload[8..12], .big) else 131072;

    const tune_ok = try buildAmqpTuneOk(allocator, frame_max);
    defer allocator.free(tune_ok);
    try stream.writeAll(tune_ok);

    const open = try buildAmqpConnectionOpen(allocator, endpoint.path);
    defer allocator.free(open);
    try stream.writeAll(open);

    const open_ok = try readAmqpFrame(allocator, stream);
    defer allocator.free(open_ok.payload);
    if (open_ok.frame_type != 1 or methodClass(open_ok.payload) != 10 or methodMethod(open_ok.payload) != 41) {
        return error.AmqpUnexpectedFrame;
    }

    const channel_open = try buildAmqpChannelOpen(allocator);
    defer allocator.free(channel_open);
    try stream.writeAll(channel_open);

    const channel_ok = try readAmqpFrame(allocator, stream);
    defer allocator.free(channel_ok.payload);
    if (channel_ok.frame_type != 1 or methodClass(channel_ok.payload) != 20 or methodMethod(channel_ok.payload) != 11) {
        return error.AmqpUnexpectedFrame;
    }

    const publish = try buildAmqpBasicPublish(allocator, config.exchange.?, config.routing_key.?, payload);
    defer allocator.free(publish);
    try stream.writeAll(publish);
}

const AmqpFrame = struct {
    frame_type: u8,
    channel: u16,
    payload: []u8,
};

fn readAmqpFrame(allocator: std.mem.Allocator, stream: *std.net.Stream) !AmqpFrame {
    var header: [7]u8 = undefined;
    try readNoEof(stream, header[0..]);

    const size = std.mem.readInt(u32, header[3..7], .big);
    const payload = try allocator.alloc(u8, size);
    errdefer allocator.free(payload);
    try readNoEof(stream, payload);

    var frame_end: [1]u8 = undefined;
    try readNoEof(stream, frame_end[0..]);
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

fn buildAmqpStartOk(allocator: std.mem.Allocator, username: []const u8, password: []const u8) ![]u8 {
    var method = std.ArrayList(u8){};
    defer method.deinit(allocator);
    try appendU16(&method, allocator, 10);
    try appendU16(&method, allocator, 11);
    try appendU32(&method, allocator, 0);
    try appendLongString(&method, allocator, "PLAIN");
    const response = try std.fmt.allocPrint(allocator, "\x00{s}\x00{s}", .{ username, password });
    defer allocator.free(response);
    try appendLongString(&method, allocator, response);
    try appendLongString(&method, allocator, "en_US");
    return buildAmqpMethodFrame(allocator, 0, method.items);
}

fn buildAmqpTuneOk(allocator: std.mem.Allocator, frame_max: u32) ![]u8 {
    var method = std.ArrayList(u8){};
    defer method.deinit(allocator);
    try appendU16(&method, allocator, 10);
    try appendU16(&method, allocator, 31);
    try appendU16(&method, allocator, 0);
    try appendU32(&method, allocator, frame_max);
    try appendU16(&method, allocator, 0);
    return buildAmqpMethodFrame(allocator, 0, method.items);
}

fn buildAmqpConnectionOpen(allocator: std.mem.Allocator, raw_path: []const u8) ![]u8 {
    const vhost = if (raw_path.len <= 1) "/" else raw_path[1..];
    var method = std.ArrayList(u8){};
    defer method.deinit(allocator);
    try appendU16(&method, allocator, 10);
    try appendU16(&method, allocator, 40);
    try appendShortString(&method, allocator, vhost);
    try appendShortString(&method, allocator, "");
    try method.append(allocator, 0);
    return buildAmqpMethodFrame(allocator, 0, method.items);
}

fn buildAmqpChannelOpen(allocator: std.mem.Allocator) ![]u8 {
    var method = std.ArrayList(u8){};
    defer method.deinit(allocator);
    try appendU16(&method, allocator, 20);
    try appendU16(&method, allocator, 10);
    try appendShortString(&method, allocator, "");
    return buildAmqpMethodFrame(allocator, 1, method.items);
}

fn buildAmqpBasicPublish(allocator: std.mem.Allocator, exchange: []const u8, routing_key: []const u8, payload: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    var method = std.ArrayList(u8){};
    defer method.deinit(allocator);
    try appendU16(&method, allocator, 60);
    try appendU16(&method, allocator, 40);
    try appendU16(&method, allocator, 0);
    try appendShortString(&method, allocator, exchange);
    try appendShortString(&method, allocator, routing_key);
    try method.append(allocator, 0);
    try appendSliceAmqpFrame(&out, allocator, 1, 1, method.items);

    var header = std.ArrayList(u8){};
    defer header.deinit(allocator);
    try appendU16(&header, allocator, 60);
    try appendU16(&header, allocator, 0);
    try appendU64(&header, allocator, payload.len);
    try appendU16(&header, allocator, 0x1000);
    try appendShortString(&header, allocator, "application/json");
    try appendSliceAmqpFrame(&out, allocator, 2, 1, header.items);

    try appendSliceAmqpFrame(&out, allocator, 3, 1, payload);
    return out.toOwnedSlice(allocator);
}

fn buildAmqpMethodFrame(allocator: std.mem.Allocator, channel: u16, payload: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    try appendSliceAmqpFrame(&out, allocator, 1, channel, payload);
    return out.toOwnedSlice(allocator);
}

fn appendSliceAmqpFrame(out: *std.ArrayList(u8), allocator: std.mem.Allocator, frame_type: u8, channel: u16, payload: []const u8) !void {
    try out.append(allocator, frame_type);
    try appendU16(out, allocator, channel);
    try appendU32(out, allocator, @intCast(payload.len));
    try out.appendSlice(allocator, payload);
    try out.append(allocator, 0xCE);
}

fn kafkaPublish(allocator: std.mem.Allocator, stream: *std.net.Stream, config: ConfigEntry, payload: []const u8) !void {
    const request = try buildKafkaProduceRequest(allocator, config.client_id orelse config.name, config.topic.?, config.partition, payload);
    defer allocator.free(request);
    try stream.writeAll(request);
}

fn buildKafkaProduceRequest(allocator: std.mem.Allocator, client_id: []const u8, topic: []const u8, partition: i32, payload: []const u8) ![]u8 {
    const message = try buildKafkaMessage(allocator, payload);
    defer allocator.free(message);

    var request = std.ArrayList(u8){};
    defer request.deinit(allocator);

    try appendI16(&request, allocator, 0);
    try appendI16(&request, allocator, 0);
    try appendI32(&request, allocator, 1);
    try appendKafkaString(&request, allocator, client_id);
    try appendI16(&request, allocator, 0);
    try appendI32(&request, allocator, 1000);
    try appendI32(&request, allocator, 1);
    try appendKafkaString(&request, allocator, topic);
    try appendI32(&request, allocator, 1);
    try appendI32(&request, allocator, partition);

    var message_set = std.ArrayList(u8){};
    defer message_set.deinit(allocator);
    try appendI64(&message_set, allocator, 0);
    try appendI32(&message_set, allocator, @intCast(message.len));
    try message_set.appendSlice(allocator, message);

    try appendI32(&request, allocator, @intCast(message_set.items.len));
    try request.appendSlice(allocator, message_set.items);

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    try appendI32(&out, allocator, @intCast(request.items.len));
    try out.appendSlice(allocator, request.items);
    return out.toOwnedSlice(allocator);
}

fn buildKafkaMessage(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var body = std.ArrayList(u8){};
    defer body.deinit(allocator);

    try body.append(allocator, 0);
    try body.append(allocator, 0);
    try appendI32(&body, allocator, -1);
    try appendI32(&body, allocator, @intCast(payload.len));
    try body.appendSlice(allocator, payload);

    var crc = std.hash.Crc32.init();
    crc.update(body.items);
    const checksum = crc.final();

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    try appendU32(&out, allocator, checksum);
    try out.appendSlice(allocator, body.items);
    return out.toOwnedSlice(allocator);
}

fn basicAuthHeader(allocator: std.mem.Allocator, username: []const u8, password: []const u8) ![]u8 {
    const raw = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ username, password });
    defer allocator.free(raw);
    const out = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(raw.len));
    _ = std.base64.standard.Encoder.encode(out, raw);
    return out;
}

fn expandPattern(allocator: std.mem.Allocator, pattern: []const u8, payload: []const u8) ![]u8 {
    _ = payload;
    return allocator.dupe(u8, pattern);
}

fn appendPrefixedBytes(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try appendU16(out, allocator, @intCast(value.len));
    try out.appendSlice(allocator, value);
}

fn appendShortString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try out.append(allocator, @intCast(value.len));
    try out.appendSlice(allocator, value);
}

fn appendLongString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try appendU32(out, allocator, @intCast(value.len));
    try out.appendSlice(allocator, value);
}

fn appendKafkaString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try appendI16(out, allocator, @intCast(value.len));
    try out.appendSlice(allocator, value);
}

fn appendU16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, value, .big);
    try out.appendSlice(allocator, &buf);
}

fn appendI16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(i16, &buf, value, .big);
    try out.appendSlice(allocator, &buf);
}

fn appendU32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .big);
    try out.appendSlice(allocator, &buf);
}

fn appendI32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &buf, value, .big);
    try out.appendSlice(allocator, &buf);
}

fn appendU64(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .big);
    try out.appendSlice(allocator, &buf);
}

fn appendI64(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf, value, .big);
    try out.appendSlice(allocator, &buf);
}

fn gatewayMacHex(mac: [8]u8) [16]u8 {
    const digits = "0123456789abcdef";
    var out: [16]u8 = undefined;
    for (mac, 0..) |byte, i| {
        out[i * 2] = digits[byte >> 4];
        out[i * 2 + 1] = digits[byte & 0x0F];
    }
    return out;
}

fn readNoEof(stream: *std.net.Stream, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const n = try stream.read(buffer[offset..]);
        if (n == 0) return error.EndOfStream;
        offset += n;
    }
}

test "configFromRecord parses and validates connector records" {
    const record = connectors_repository.Record{
        .id = 1,
        .name = try std.testing.allocator.dupe(u8, "kafka-main"),
        .connector_type = try std.testing.allocator.dupe(u8, "kafka"),
        .uri = try std.testing.allocator.dupe(u8, "kafka://broker:9092"),
        .enabled = true,
        .topic = try std.testing.allocator.dupe(u8, "lorawan"),
        .exchange_name = null,
        .routing_key = null,
        .partition = 2,
        .client_id = null,
        .username = null,
        .password = null,
    };
    var owned_record = record;
    defer owned_record.deinit(std.testing.allocator);

    var config = try configFromRecord(std.testing.allocator, owned_record);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(Kind.kafka, config.kind);
    try std.testing.expectEqualStrings("lorawan", config.topic.?);
    try std.testing.expectEqual(@as(i32, 2), config.partition);
}

test "encode envelope embeds payload as nested json" {
    const body = try encodeEnvelope(std.testing.allocator, .{
        .event_type = "lorawan_uplink",
        .gateway_mac = [_]u8{ 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11 },
        .payload_json = "{\"dev_addr\":\"01020304\"}",
        .received_at_ms = 123,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"event_type\":\"lorawan_uplink\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"gateway_mac\":\"aabbccddeeff0011\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"payload\":{\"dev_addr\":\"01020304\"}") != null);
}

test "mqtt publish packet uses qos0 topic and body" {
    const packet = try buildMqttPublishPacket(std.testing.allocator, "uplinks/node-a", "{\"x\":1}");
    defer std.testing.allocator.free(packet);

    try std.testing.expectEqual(@as(u8, 0x30), packet[0]);
    try std.testing.expect(std.mem.indexOf(u8, packet, "uplinks/node-a") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet, "{\"x\":1}") != null);
}

test "kafka produce request contains topic and payload" {
    const req = try buildKafkaProduceRequest(std.testing.allocator, "lorawan-server", "uplinks", 0, "{\"x\":1}");
    defer std.testing.allocator.free(req);

    try std.testing.expect(std.mem.indexOf(u8, req, "uplinks") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "{\"x\":1}") != null);
}
