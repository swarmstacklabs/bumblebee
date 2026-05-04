const std = @import("std");

pub const Kind = enum {
    mqtt,
    ws,
    wss,
    rabbitmq,
    kafka,

    pub fn parse(raw: []const u8) !Kind {
        if (std.mem.eql(u8, raw, "mqtt")) return .mqtt;
        if (std.mem.eql(u8, raw, "ws")) return .ws;
        if (std.mem.eql(u8, raw, "wss")) return .wss;
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
        .ws, .wss => {},
    }
}

pub const Endpoint = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
    username: ?[]const u8,
    password: ?[]const u8,
    is_tls: bool,

    pub fn parse(allocator: std.mem.Allocator, config: ConfigEntry) !Endpoint {
        const uri = try std.Uri.parse(config.uri);
        const host_component = uri.host orelse return error.UriMissingHost;
        const host = try dupeUriComponent(allocator, host_component);
        errdefer allocator.free(host);
        if (host.len > std.Uri.host_name_max) return error.UriHostTooLong;

        const raw_path = try uri.path.toRawMaybeAlloc(allocator);
        defer if (raw_path.ptr != uri.path.percent_encoded.ptr and raw_path.ptr != uri.path.raw.ptr) allocator.free(raw_path);

        const path = try allocator.dupe(u8, if (raw_path.len == 0) "/" else raw_path);
        errdefer allocator.free(path);

        const user = if (config.username) |value|
            try allocator.dupe(u8, value)
        else if (uri.user) |value|
            try dupeUriComponent(allocator, value)
        else
            null;
        errdefer if (user) |value| allocator.free(value);

        const pass = if (config.password) |value|
            try allocator.dupe(u8, value)
        else if (uri.password) |value|
            try dupeUriComponent(allocator, value)
        else
            null;
        errdefer if (pass) |value| allocator.free(value);

        return .{
            .host = host,
            .port = uri.port orelse defaultPortForScheme(config.kind, uri.scheme),
            .path = path,
            .username = user,
            .password = pass,
            .is_tls = std.ascii.eqlIgnoreCase(uri.scheme, "wss"),
        };
    }

    pub fn deinit(self: Endpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.path);
        if (self.username) |value| allocator.free(value);
        if (self.password) |value| allocator.free(value);
    }
};

fn dupeUriComponent(allocator: std.mem.Allocator, component: std.Uri.Component) ![]u8 {
    const raw = try component.toRawMaybeAlloc(allocator);
    defer switch (component) {
        .raw => |value| if (raw.ptr != value.ptr) allocator.free(raw),
        .percent_encoded => |value| if (raw.ptr != value.ptr) allocator.free(raw),
    };
    return allocator.dupe(u8, raw);
}

pub fn defaultPort(kind: Kind) u16 {
    return switch (kind) {
        .mqtt => 1883,
        .ws => 80,
        .wss => 443,
        .rabbitmq => 5672,
        .kafka => 9092,
    };
}

fn defaultPortForScheme(kind: Kind, scheme: []const u8) u16 {
    if ((kind == .ws or kind == .wss) and std.ascii.eqlIgnoreCase(scheme, "wss")) {
        return 443;
    }
    if ((kind == .ws or kind == .wss) and std.ascii.eqlIgnoreCase(scheme, "ws")) {
        return 80;
    }
    return defaultPort(kind);
}
