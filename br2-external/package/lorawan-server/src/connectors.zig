const std = @import("std");
const StorageContext = @import("app.zig").StorageContext;
const logger = @import("logger.zig");
const connectors_repository = @import("repository/connectors_repository.zig");
const kafka = @import("connectors/kafka.zig");
const mqtt = @import("connectors/mqtt.zig");
const rabbitmq = @import("connectors/rabbitmq.zig");
const types = @import("connectors/types.zig");
const wire = @import("connectors/wire.zig");
const ws = @import("connectors/ws.zig");

pub const Kind = types.Kind;
pub const ConfigEntry = types.ConfigEntry;

pub const PublishedEvent = struct {
    event_type: []const u8,
    gateway_mac: [8]u8,
    payload_json: []const u8,
    received_at_ms: i64,
};

pub fn publishFromStorage(allocator: std.mem.Allocator, storage: StorageContext, event: PublishedEvent) void {
    const envelope = encodeEnvelope(allocator, event) catch |err| {
        logger.warn("connectors", "encode_failed", "failed to encode connector payload", .{
            .error_name = @errorName(err),
            .event_type = event.event_type,
        });
        return;
    };
    defer allocator.free(envelope);

    const repo = connectors_repository.Repository.init(storage);
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

    try types.validateConfig(config);
    return config;
}

pub fn encodeEnvelope(allocator: std.mem.Allocator, event: PublishedEvent) ![]u8 {
    var list = std.ArrayList(u8){};
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "{\"event_type\":");
    try list.writer(allocator).print("{f}", .{std.json.fmt(event.event_type, .{})});
    try list.appendSlice(allocator, ",\"gateway_mac\":\"");
    const mac = wire.gatewayMacHex(event.gateway_mac);
    try list.appendSlice(allocator, mac[0..]);
    try list.appendSlice(allocator, "\",\"received_at_ms\":");
    try list.writer(allocator).print("{d}", .{event.received_at_ms});
    try list.appendSlice(allocator, ",\"payload\":");
    try list.appendSlice(allocator, event.payload_json);
    try list.append(allocator, '}');

    return list.toOwnedSlice(allocator);
}

fn publishOne(allocator: std.mem.Allocator, config: ConfigEntry, payload: []const u8) !void {
    const endpoint = try types.Endpoint.parse(allocator, config);
    defer endpoint.deinit(allocator);

    if (config.kind == .wss or (config.kind == .ws and endpoint.is_tls)) {
        return ws.publishSecure(allocator, endpoint, config, payload);
    }

    var stream = try std.net.tcpConnectToHost(allocator, endpoint.host, endpoint.port);
    defer stream.close();

    switch (config.kind) {
        .mqtt => try mqtt.publish(allocator, &stream, endpoint, config, payload),
        .ws => try ws.publish(allocator, &stream, endpoint, config, payload),
        .rabbitmq => try rabbitmq.publish(allocator, &stream, endpoint, config, payload),
        .kafka => try kafka.publish(allocator, &stream, config, payload),
        .wss => unreachable,
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

test "configFromRecord accepts secure websocket connector records" {
    const record = connectors_repository.Record{
        .id = 1,
        .name = try std.testing.allocator.dupe(u8, "timeline"),
        .connector_type = try std.testing.allocator.dupe(u8, "ws"),
        .uri = try std.testing.allocator.dupe(u8, "wss://ui.example.test/timeline"),
        .enabled = true,
        .topic = null,
        .exchange_name = null,
        .routing_key = null,
        .partition = 0,
        .client_id = null,
        .username = null,
        .password = null,
    };
    var owned_record = record;
    defer owned_record.deinit(std.testing.allocator);

    var config = try configFromRecord(std.testing.allocator, owned_record);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(Kind.ws, config.kind);

    const endpoint = try types.Endpoint.parse(std.testing.allocator, config);
    defer endpoint.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 443), endpoint.port);
    try std.testing.expect(endpoint.is_tls);
}

test "configFromRecord accepts unsecure websocket connector records" {
    const record = connectors_repository.Record{
        .id = 1,
        .name = try std.testing.allocator.dupe(u8, "timeline-local"),
        .connector_type = try std.testing.allocator.dupe(u8, "ws"),
        .uri = try std.testing.allocator.dupe(u8, "ws://localhost/events"),
        .enabled = true,
        .topic = null,
        .exchange_name = null,
        .routing_key = null,
        .partition = 0,
        .client_id = null,
        .username = null,
        .password = null,
    };
    var owned_record = record;
    defer owned_record.deinit(std.testing.allocator);

    var config = try configFromRecord(std.testing.allocator, owned_record);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(Kind.ws, config.kind);

    const endpoint = try types.Endpoint.parse(std.testing.allocator, config);
    defer endpoint.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 80), endpoint.port);
    try std.testing.expect(!endpoint.is_tls);
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
