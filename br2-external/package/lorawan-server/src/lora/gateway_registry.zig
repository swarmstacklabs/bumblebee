const std = @import("std");
const posix = std.posix;

const app_mod = @import("../app.zig");
const event_repository = @import("../repository/event_repository.zig");
const gateway_repository = @import("../repository/gateway_repository.zig");
const App = app_mod.App;
const StorageContext = app_mod.StorageContext;

pub const GatewayTarget = gateway_repository.GatewayTarget;
pub const RuntimeRecord = gateway_repository.RuntimeRecord;

pub const Registry = struct {
    gateway_repo: gateway_repository.Repository,
    event_repo: event_repository.Repository,

    pub fn init(db: StorageContext) Registry {
        return .{
            .gateway_repo = gateway_repository.Repository.init(db),
            .event_repo = event_repository.Repository.init(db),
        };
    }

    pub fn touch(self: Registry, gateway_mac: [8]u8, version: u8, client_addr: *const posix.sockaddr.in) !void {
        try self.gateway_repo.upsertRuntime(gateway_mac, version, client_addr, null, null);
    }

    pub fn rememberPullTarget(self: Registry, gateway_mac: [8]u8, version: u8, client_addr: *const posix.sockaddr.in) !void {
        try self.gateway_repo.upsertRuntime(gateway_mac, version, client_addr, null, null);
    }

    pub fn rememberPending(self: Registry, gateway_mac: [8]u8, token: u16, txpk_json: []const u8) !void {
        try self.gateway_repo.rememberPending(gateway_mac, token, txpk_json);
    }

    pub fn clearPending(self: Registry, gateway_mac: [8]u8, token: u16) !void {
        try self.gateway_repo.clearPending(gateway_mac, token);
    }

    pub fn insertEvent(self: Registry, event_type: []const u8, gateway_mac: [8]u8, payload_json: []u8) !void {
        try self.event_repo.insertGatewayEvent(event_type, gateway_mac, payload_json);
    }

    pub fn readTarget(self: Registry, gateway_mac: [8]u8) !GatewayTarget {
        return self.gateway_repo.readTarget(gateway_mac);
    }

    pub fn get(self: Registry, gateway_mac: [8]u8) !?RuntimeRecord {
        return self.gateway_repo.get(gateway_mac);
    }

    pub fn list(self: Registry, allocator: std.mem.Allocator) ![]RuntimeRecord {
        return self.gateway_repo.list(allocator);
    }

    pub fn countPending(self: Registry, gateway_mac: [8]u8) !i64 {
        return self.gateway_repo.countPending(gateway_mac);
    }
};

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

    const registry = Registry.init(app.app.storage());
    try registry.rememberPullTarget(gateway_mac, 1, &client_addr);

    const target = try registry.readTarget(gateway_mac);
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

    const registry = Registry.init(app.app.storage());
    try registry.touch(gateway_mac, 1, &client_addr);
    try registry.rememberPending(gateway_mac, 0xCAFE, "{\"txpk\":{}}");

    const before = (try registry.get(gateway_mac)).?;
    defer before.deinit(allocator);
    try std.testing.expectEqual(@as(?u16, 0xCAFE), before.pending_downlink_token);
    try std.testing.expectEqualStrings("10.0.0.5", before.peer_address.?);

    try registry.clearPending(gateway_mac, 0xCAFE);

    const snapshots = try registry.list(allocator);
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
