const std = @import("std");
const posix = std.posix;

const app_mod = @import("app.zig");
const packets = @import("udp_packets.zig");
const App = app_mod.App;
const c = app_mod.c;

pub const GatewayTarget = struct {
    addr: posix.sockaddr.in,
    pending_json: ?[]u8,

    pub fn deinit(self: GatewayTarget, allocator: std.mem.Allocator) void {
        if (self.pending_json) |value| allocator.free(value);
    }
};

pub fn updateLastSeen(app: *App, gateway_mac: [8]u8, client_addr: *const posix.sockaddr.in) !void {
    try upsertGatewayRuntime(app, gateway_mac, client_addr, null, null);
}

pub fn updatePullTarget(app: *App, gateway_mac: [8]u8, version: u8, client_addr: *const posix.sockaddr.in) !void {
    const json = try std.json.Stringify.valueAlloc(app.allocator, .{
        .version = version,
    }, .{});
    defer app.allocator.free(json);
    try upsertGatewayRuntime(app, gateway_mac, client_addr, null, json);
}

pub fn updatePending(app: *App, gateway_mac: [8]u8, token: u16, txpk_json: []const u8) !void {
    app.mutex.lock();
    defer app.mutex.unlock();

    const sql =
        "UPDATE gateway_runtime " ++
        "SET pending_downlink_token = ?, pending_downlink_json = ?, updated_at = CURRENT_TIMESTAMP " ++
        "WHERE gateway_mac = ?;";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(app.db, sql.ptr, @as(c_int, @intCast(sql.len)), &stmt, null) != c.SQLITE_OK) {
        return error.SqlitePrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int(stmt, 1, token);
    bindSqliteText(stmt.?, 2, txpk_json);
    const gateway_hex = packets.gatewayMacHex(gateway_mac);
    bindSqliteText(stmt.?, 3, gateway_hex[0..]);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
}

pub fn insertEvent(app: *App, event_type: []const u8, gateway_mac: [8]u8, payload_json: []u8) !void {
    defer app.allocator.free(payload_json);

    const gateway_hex = packets.gatewayMacHex(gateway_mac);
    app.mutex.lock();
    defer app.mutex.unlock();

    const sql =
        "INSERT INTO events(event_type, entity_type, entity_id, payload_json) VALUES(?, 'gateway', ?, ?);";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(app.db, sql.ptr, @as(c_int, @intCast(sql.len)), &stmt, null) != c.SQLITE_OK) {
        return error.SqlitePrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    bindSqliteText(stmt.?, 1, event_type);
    bindSqliteText(stmt.?, 2, gateway_hex[0..]);
    bindSqliteText(stmt.?, 3, payload_json);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
}

pub fn readTarget(app: *App, gateway_mac: [8]u8) !GatewayTarget {
    const gateway_hex = packets.gatewayMacHex(gateway_mac);

    app.mutex.lock();
    defer app.mutex.unlock();

    const sql =
        "SELECT peer_address, peer_port, pending_downlink_json FROM gateway_runtime WHERE gateway_mac = ?;";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(app.db, sql.ptr, @as(c_int, @intCast(sql.len)), &stmt, null) != c.SQLITE_OK) {
        return error.SqlitePrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    bindSqliteText(stmt.?, 1, gateway_hex[0..]);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.GatewayNotConnected;

    const ip_ptr = c.sqlite3_column_text(stmt, 0) orelse return error.GatewayNotConnected;
    const port = c.sqlite3_column_int(stmt, 1);
    if (port <= 0 or port > std.math.maxInt(u16)) return error.GatewayNotConnected;

    const ip_text = std.mem.span(ip_ptr);
    const parsed_ip = try parseIpv4(ip_text);

    const pending_ptr = c.sqlite3_column_text(stmt, 2);
    return .{
        .addr = .{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, @intCast(port)),
            .addr = parsed_ip,
            .zero = [_]u8{0} ** 8,
        },
        .pending_json = if (pending_ptr != null) try app.allocator.dupe(u8, std.mem.span(pending_ptr)) else null,
    };
}

fn upsertGatewayRuntime(app: *App, gateway_mac: [8]u8, client_addr: *const posix.sockaddr.in, token: ?u16, pending_json: ?[]const u8) !void {
    const peer_ip = formatPeerIp(client_addr);
    const peer_port = std.mem.bigToNative(u16, client_addr.port);
    const gateway_hex = packets.gatewayMacHex(gateway_mac);
    const now_ms = std.time.milliTimestamp();

    app.mutex.lock();
    defer app.mutex.unlock();

    const sql =
        "INSERT INTO gateway_runtime(gateway_mac, last_seen_at, last_seen_unix_ms, peer_address, peer_port, pending_downlink_token, pending_downlink_json, updated_at) " ++
        "VALUES(?, CURRENT_TIMESTAMP, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP) " ++
        "ON CONFLICT(gateway_mac) DO UPDATE SET " ++
        "last_seen_at = CURRENT_TIMESTAMP, " ++
        "last_seen_unix_ms = excluded.last_seen_unix_ms, " ++
        "peer_address = excluded.peer_address, " ++
        "peer_port = excluded.peer_port, " ++
        "pending_downlink_token = COALESCE(excluded.pending_downlink_token, gateway_runtime.pending_downlink_token), " ++
        "pending_downlink_json = COALESCE(excluded.pending_downlink_json, gateway_runtime.pending_downlink_json), " ++
        "updated_at = CURRENT_TIMESTAMP;";

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(app.db, sql.ptr, @as(c_int, @intCast(sql.len)), &stmt, null) != c.SQLITE_OK) {
        return error.SqlitePrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    bindSqliteText(stmt.?, 1, gateway_hex[0..]);
    _ = c.sqlite3_bind_int64(stmt, 2, now_ms);
    bindSqliteText(stmt.?, 3, peer_ip[0..]);
    _ = c.sqlite3_bind_int(stmt, 4, peer_port);
    if (token) |value| {
        _ = c.sqlite3_bind_int(stmt, 5, value);
    } else {
        _ = c.sqlite3_bind_null(stmt, 5);
    }
    if (pending_json) |value| {
        bindSqliteText(stmt.?, 6, value);
    } else {
        _ = c.sqlite3_bind_null(stmt, 6);
    }

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
}

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

fn bindSqliteText(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) void {
    _ = c.sqlite3_bind_text(stmt, index, value.ptr, @as(c_int, @intCast(value.len)), null);
}
