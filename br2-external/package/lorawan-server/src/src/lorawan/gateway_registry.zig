const std = @import("std");
const posix = std.posix;

const app_mod = @import("../app.zig");
const event_repository = @import("../repository/event_repository.zig");
const gateway_repository = @import("../repository/gateway_repository.zig");
const App = app_mod.App;

pub const GatewayTarget = gateway_repository.GatewayTarget;
pub const RuntimeRecord = gateway_repository.RuntimeRecord;

pub fn touch(app: *App, gateway_mac: [8]u8, version: u8, client_addr: *const posix.sockaddr.in) !void {
    try gateway_repository.Repository.init(app).upsertRuntime(gateway_mac, version, client_addr, null, null);
}

pub fn rememberPullTarget(app: *App, gateway_mac: [8]u8, version: u8, client_addr: *const posix.sockaddr.in) !void {
    try gateway_repository.Repository.init(app).upsertRuntime(gateway_mac, version, client_addr, null, null);
}

pub fn rememberPending(app: *App, gateway_mac: [8]u8, token: u16, txpk_json: []const u8) !void {
    try gateway_repository.Repository.init(app).rememberPending(gateway_mac, token, txpk_json);
}

pub fn clearPending(app: *App, gateway_mac: [8]u8, token: u16) !void {
    try gateway_repository.Repository.init(app).clearPending(gateway_mac, token);
}

pub fn insertEvent(app: *App, event_type: []const u8, gateway_mac: [8]u8, payload_json: []u8) !void {
    try event_repository.Repository.init(app).insertGatewayEvent(event_type, gateway_mac, payload_json);
}

pub fn readTarget(app: *App, gateway_mac: [8]u8) !GatewayTarget {
    return gateway_repository.Repository.init(app).readTarget(gateway_mac);
}

pub fn get(app: *App, gateway_mac: [8]u8) !?RuntimeRecord {
    return gateway_repository.Repository.init(app).get(gateway_mac);
}

pub fn list(app: *App, allocator: std.mem.Allocator) ![]RuntimeRecord {
    return gateway_repository.Repository.init(app).list(allocator);
}

pub fn countPending(app: *App, gateway_mac: [8]u8) !i64 {
    return gateway_repository.Repository.init(app).countPending(gateway_mac);
}

test "registry stores pull target with semtech version" {
    const allocator = std.testing.allocator;
    var app = try testApp(allocator);
    defer testAppDeinit(&app);

    const gateway_mac = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const client_addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, 1680),
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        .zero = [_]u8{0} ** 8,
    };

    try rememberPullTarget(&app.app, gateway_mac, 1, &client_addr);

    const target = try readTarget(&app.app, gateway_mac);
    defer target.deinit(allocator);

    try std.testing.expectEqual(@as(?u8, 1), target.semtech_version);
    try std.testing.expectEqual(@as(?u16, null), target.pending_token);
    try std.testing.expectEqual(@as(u16, 1680), std.mem.bigToNative(u16, target.addr.port));
}

test "registry lists runtime snapshots and clears pending state" {
    const allocator = std.testing.allocator;
    var app = try testApp(allocator);
    defer testAppDeinit(&app);

    const gateway_mac = [_]u8{ 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17 };
    const client_addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, 1700),
        .addr = @bitCast([4]u8{ 10, 0, 0, 5 }),
        .zero = [_]u8{0} ** 8,
    };

    try touch(&app.app, gateway_mac, 1, &client_addr);
    try rememberPending(&app.app, gateway_mac, 0xCAFE, "{\"txpk\":{}}");

    const before = (try get(&app.app, gateway_mac)).?;
    defer before.deinit(allocator);
    try std.testing.expectEqual(@as(?u16, 0xCAFE), before.pending_downlink_token);
    try std.testing.expectEqualStrings("10.0.0.5", before.peer_address.?);

    try clearPending(&app.app, gateway_mac, 0xCAFE);

    const snapshots = try list(&app.app, allocator);
    defer {
        for (snapshots) |item| item.deinit(allocator);
        allocator.free(snapshots);
    }

    try std.testing.expectEqual(@as(usize, 1), snapshots.len);
    try std.testing.expectEqual(gateway_mac, snapshots[0].gateway_mac);
    try std.testing.expectEqual(@as(?u8, 1), snapshots[0].semtech_version);
    try std.testing.expectEqual(@as(?u16, null), snapshots[0].pending_downlink_token);
    try std.testing.expectEqualStrings("10.0.0.5", snapshots[0].peer_address.?);
}

const TestApp = struct {
    app: App,
    db_path: []u8,
    allocator: std.mem.Allocator,
};

fn testApp(allocator: std.mem.Allocator) !TestApp {
    const db_path = try std.fmt.allocPrint(allocator, "/tmp/lorawan-server-gateway-registry-{d}.db", .{std.time.nanoTimestamp()});
    errdefer allocator.free(db_path);

    const app = try App.init(allocator, db_path);
    return .{
        .app = app,
        .db_path = db_path,
        .allocator = allocator,
    };
}

fn testAppDeinit(test_app: *TestApp) void {
    test_app.app.deinit();
    std.fs.deleteFileAbsolute(test_app.db_path) catch {};
    test_app.allocator.free(test_app.db_path);
}
