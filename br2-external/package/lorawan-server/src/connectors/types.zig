const std = @import("std");

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

pub fn validateConfig(entry: ConfigEntry) !void {
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

pub const Endpoint = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
    username: ?[]const u8,
    password: ?[]const u8,

    pub fn parse(allocator: std.mem.Allocator, config: ConfigEntry) !Endpoint {
        const uri = try std.Uri.parse(config.uri);
        const host = try uri.getHostAlloc(allocator);
        errdefer allocator.free(host);

        const raw_path = try uri.path.toRawMaybeAlloc(allocator);
        defer if (raw_path.ptr != uri.path.percent_encoded.ptr and raw_path.ptr != uri.path.raw.ptr) allocator.free(raw_path);

        const path = try allocator.dupe(u8, if (raw_path.len == 0) "/" else raw_path);
        errdefer allocator.free(path);

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
            .path = path,
            .username = user,
            .password = pass,
        };
    }

    pub fn deinit(self: Endpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.path);
        if (self.username) |value| allocator.free(value);
        if (self.password) |value| allocator.free(value);
    }
};

pub fn defaultPort(kind: Kind) u16 {
    return switch (kind) {
        .mqtt => 1883,
        .ws => 80,
        .rabbitmq => 5672,
        .kafka => 9092,
    };
}
