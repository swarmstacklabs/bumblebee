const std = @import("std");
const posix = std.posix;

const app_mod = @import("../app.zig");
const packets = @import("../lorawan/packets.zig");
const sqlite = @import("../sqlite_helpers.zig");
const App = app_mod.App;

pub const GatewayTarget = struct {
    addr: posix.sockaddr.in,
    semtech_version: ?u8,
    pending_token: ?u16,
    pending_json: ?[]u8,

    pub fn deinit(self: GatewayTarget, allocator: std.mem.Allocator) void {
        if (self.pending_json) |value| allocator.free(value);
    }
};

pub const RuntimeRecord = struct {
    gateway_mac: [8]u8,
    semtech_version: ?u8,
    last_seen_at: ?[]u8,
    last_seen_unix_ms: ?i64,
    peer_address: ?[]u8,
    peer_port: ?u16,
    pending_downlink_token: ?u16,
    pending_downlink_json: ?[]u8,
    updated_at: ?[]u8,

    pub fn deinit(self: RuntimeRecord, allocator: std.mem.Allocator) void {
        if (self.last_seen_at) |value| allocator.free(value);
        if (self.peer_address) |value| allocator.free(value);
        if (self.pending_downlink_json) |value| allocator.free(value);
        if (self.updated_at) |value| allocator.free(value);
    }
};

pub const Repository = struct {
    app: *App,

    pub fn init(app: *App) Repository {
        return .{ .app = app };
    }

    pub fn upsertRuntime(self: Repository, gateway_mac: [8]u8, version: u8, client_addr: *const posix.sockaddr.in, token: ?u16, pending_json: ?[]const u8) !void {
        const peer_ip = formatPeerIp(client_addr);
        const peer_port = std.mem.bigToNative(u16, client_addr.port);
        const gateway_hex = packets.gatewayMacHex(gateway_mac);
        const now_ms = std.time.milliTimestamp();

        self.app.mutex.lock();
        defer self.app.mutex.unlock();

        const sql =
            "INSERT INTO gateway_runtime(gateway_mac, semtech_version, last_seen_at, last_seen_unix_ms, peer_address, peer_port, pending_downlink_token, pending_downlink_json, updated_at) " ++
            "VALUES(?, ?, CURRENT_TIMESTAMP, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP) " ++
            "ON CONFLICT(gateway_mac) DO UPDATE SET " ++
            "semtech_version = COALESCE(excluded.semtech_version, gateway_runtime.semtech_version), " ++
            "last_seen_at = CURRENT_TIMESTAMP, " ++
            "last_seen_unix_ms = excluded.last_seen_unix_ms, " ++
            "peer_address = excluded.peer_address, " ++
            "peer_port = excluded.peer_port, " ++
            "pending_downlink_token = COALESCE(excluded.pending_downlink_token, gateway_runtime.pending_downlink_token), " ++
            "pending_downlink_json = COALESCE(excluded.pending_downlink_json, gateway_runtime.pending_downlink_json), " ++
            "updated_at = CURRENT_TIMESTAMP;";

        const stmt = try sqlite.Statement.prepare(self.app.db, sql);
        defer stmt.deinit();

        stmt.bindText(1, gateway_hex[0..]);
        stmt.bindInt(2, version);
        stmt.bindInt64(3, now_ms);
        stmt.bindText(4, peer_ip[0..]);
        stmt.bindInt(5, peer_port);
        if (token) |value| stmt.bindInt(6, value) else stmt.bindNull(6);
        if (pending_json) |value| stmt.bindText(7, value) else stmt.bindNull(7);
        try stmt.expectDone();
    }

    pub fn rememberPending(self: Repository, gateway_mac: [8]u8, token: u16, txpk_json: []const u8) !void {
        self.app.mutex.lock();
        defer self.app.mutex.unlock();

        const sql =
            "UPDATE gateway_runtime " ++
            "SET pending_downlink_token = ?, pending_downlink_json = ?, updated_at = CURRENT_TIMESTAMP " ++
            "WHERE gateway_mac = ?;";
        const stmt = try sqlite.Statement.prepare(self.app.db, sql);
        defer stmt.deinit();

        stmt.bindInt(1, token);
        stmt.bindText(2, txpk_json);
        const gateway_hex = packets.gatewayMacHex(gateway_mac);
        stmt.bindText(3, gateway_hex[0..]);
        try stmt.expectDone();
    }

    pub fn clearPending(self: Repository, gateway_mac: [8]u8, token: u16) !void {
        self.app.mutex.lock();
        defer self.app.mutex.unlock();

        const sql =
            "UPDATE gateway_runtime " ++
            "SET pending_downlink_token = NULL, pending_downlink_json = NULL, updated_at = CURRENT_TIMESTAMP " ++
            "WHERE gateway_mac = ? AND pending_downlink_token = ?;";
        const stmt = try sqlite.Statement.prepare(self.app.db, sql);
        defer stmt.deinit();

        const gateway_hex = packets.gatewayMacHex(gateway_mac);
        stmt.bindText(1, gateway_hex[0..]);
        stmt.bindInt(2, token);
        try stmt.expectDone();
    }

    pub fn readTarget(self: Repository, gateway_mac: [8]u8) !GatewayTarget {
        const gateway_hex = packets.gatewayMacHex(gateway_mac);

        self.app.mutex.lock();
        defer self.app.mutex.unlock();

        const sql =
            "SELECT peer_address, peer_port, semtech_version, pending_downlink_token, pending_downlink_json " ++
            "FROM gateway_runtime WHERE gateway_mac = ?;";
        const stmt = try sqlite.Statement.prepare(self.app.db, sql);
        defer stmt.deinit();

        stmt.bindText(1, gateway_hex[0..]);
        if (stmt.step() != sqlite.c.SQLITE_ROW) return error.GatewayNotConnected;

        const ip_text = stmt.readText(0) orelse return error.GatewayNotConnected;
        const port = stmt.readInt(1);
        if (port <= 0 or port > std.math.maxInt(u16)) return error.GatewayNotConnected;

        const parsed_ip = try parseIpv4(ip_text);
        const pending_text = stmt.readText(4);

        return .{
            .addr = .{
                .family = posix.AF.INET,
                .port = std.mem.nativeToBig(u16, @intCast(port)),
                .addr = parsed_ip,
                .zero = [_]u8{0} ** 8,
            },
            .semtech_version = optionalU8Column(stmt, 2),
            .pending_token = optionalU16Column(stmt, 3),
            .pending_json = if (pending_text) |value| try self.app.allocator.dupe(u8, value) else null,
        };
    }

    pub fn get(self: Repository, gateway_mac: [8]u8) !?RuntimeRecord {
        const gateway_hex = packets.gatewayMacHex(gateway_mac);

        self.app.mutex.lock();
        defer self.app.mutex.unlock();

        const sql =
            "SELECT semtech_version, last_seen_at, last_seen_unix_ms, peer_address, peer_port, " ++
            "pending_downlink_token, pending_downlink_json, updated_at " ++
            "FROM gateway_runtime WHERE gateway_mac = ?;";
        const stmt = try sqlite.Statement.prepare(self.app.db, sql);
        defer stmt.deinit();

        stmt.bindText(1, gateway_hex[0..]);
        if (stmt.step() != sqlite.c.SQLITE_ROW) return null;

        return .{
            .gateway_mac = gateway_mac,
            .semtech_version = optionalU8Column(stmt, 0),
            .last_seen_at = try dupOptionalText(self.app.allocator, stmt, 1),
            .last_seen_unix_ms = optionalI64Column(stmt, 2),
            .peer_address = try dupOptionalText(self.app.allocator, stmt, 3),
            .peer_port = optionalU16Column(stmt, 4),
            .pending_downlink_token = optionalU16Column(stmt, 5),
            .pending_downlink_json = try dupOptionalText(self.app.allocator, stmt, 6),
            .updated_at = try dupOptionalText(self.app.allocator, stmt, 7),
        };
    }

    pub fn list(self: Repository, allocator: std.mem.Allocator) ![]RuntimeRecord {
        self.app.mutex.lock();
        defer self.app.mutex.unlock();

        const sql =
            "SELECT gateway_mac, semtech_version, last_seen_at, last_seen_unix_ms, peer_address, peer_port, " ++
            "pending_downlink_token, pending_downlink_json, updated_at " ++
            "FROM gateway_runtime ORDER BY gateway_mac ASC;";
        const stmt = try sqlite.Statement.prepare(self.app.db, sql);
        defer stmt.deinit();

        var out = std.ArrayList(RuntimeRecord){};
        errdefer {
            for (out.items) |item| item.deinit(allocator);
            out.deinit(allocator);
        }

        while (stmt.step() == sqlite.c.SQLITE_ROW) {
            const gateway_hex = stmt.readText(0) orelse return error.InvalidGatewayMac;
            try out.append(allocator, .{
                .gateway_mac = try parseGatewayMacHex(gateway_hex),
                .semtech_version = optionalU8Column(stmt, 1),
                .last_seen_at = try dupOptionalText(allocator, stmt, 2),
                .last_seen_unix_ms = optionalI64Column(stmt, 3),
                .peer_address = try dupOptionalText(allocator, stmt, 4),
                .peer_port = optionalU16Column(stmt, 5),
                .pending_downlink_token = optionalU16Column(stmt, 6),
                .pending_downlink_json = try dupOptionalText(allocator, stmt, 7),
                .updated_at = try dupOptionalText(allocator, stmt, 8),
            });
        }

        return out.toOwnedSlice(allocator);
    }

    pub fn countPending(self: Repository, gateway_mac: [8]u8) !i64 {
        self.app.mutex.lock();
        defer self.app.mutex.unlock();

        const gateway_hex = packets.gatewayMacHex(gateway_mac);
        const sql = "SELECT COUNT(*) FROM gateway_runtime WHERE gateway_mac = ? AND pending_downlink_token IS NOT NULL;";
        const stmt = try sqlite.Statement.prepare(self.app.db, sql);
        defer stmt.deinit();

        stmt.bindText(1, gateway_hex[0..]);
        try stmt.expectRow();
        return stmt.readInt64(0);
    }
};

fn formatPeerIp(addr: *const posix.sockaddr.in) [15]u8 {
    const ip = @as([4]u8, @bitCast(addr.addr));
    var buf: [15]u8 = [_]u8{0} ** 15;
    const text = std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch unreachable;
    var out: [15]u8 = [_]u8{0} ** 15;
    @memcpy(out[0..text.len], text);
    return out;
}

fn parseIpv4(text: []const u8) !u32 {
    var it = std.mem.splitScalar(u8, text, '.');
    var octets: [4]u8 = undefined;
    var index: usize = 0;
    while (it.next()) |part| {
        if (index >= octets.len) return error.InvalidIpv4;
        octets[index] = try std.fmt.parseInt(u8, part, 10);
        index += 1;
    }
    if (index != 4) return error.InvalidIpv4;
    return @bitCast(octets);
}

fn parseGatewayMacHex(text: []const u8) ![8]u8 {
    if (text.len != 16) return error.InvalidGatewayMac;

    var out: [8]u8 = undefined;
    var index: usize = 0;
    while (index < out.len) : (index += 1) {
        out[index] = try std.fmt.parseInt(u8, text[index * 2 .. index * 2 + 2], 16);
    }
    return out;
}

fn dupOptionalText(allocator: std.mem.Allocator, stmt: sqlite.Statement, column: c_int) !?[]u8 {
    const value = stmt.readText(column) orelse return null;
    return try allocator.dupe(u8, value);
}

fn optionalI64Column(stmt: sqlite.Statement, column: c_int) ?i64 {
    if (stmt.columnType(column) == sqlite.c.SQLITE_NULL) return null;
    return stmt.readInt64(column);
}

fn optionalU16Column(stmt: sqlite.Statement, column: c_int) ?u16 {
    if (stmt.columnType(column) == sqlite.c.SQLITE_NULL) return null;
    const value = stmt.readInt(column);
    if (value < 0 or value > std.math.maxInt(u16)) return null;
    return @intCast(value);
}

fn optionalU8Column(stmt: sqlite.Statement, column: c_int) ?u8 {
    if (stmt.columnType(column) == sqlite.c.SQLITE_NULL) return null;
    const value = stmt.readInt(column);
    if (value < 0 or value > std.math.maxInt(u8)) return null;
    return @intCast(value);
}
