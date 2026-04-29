const std = @import("std");

const app_mod = @import("../app.zig");
const db_mod = @import("../db.zig");
const StorageContext = db_mod.StorageContext;

pub const Repository = struct {
    storage: StorageContext,

    pub fn init(storage: StorageContext) Repository {
        return .{ .storage = storage };
    }

    pub fn deinit(_: Repository) void {}

    pub fn insertObservation(self: Repository, command_tag: []const u8, outcome: []const u8, level: []const u8, latency_ns: u64) !void {
        self.storage.lock();
        defer self.storage.unlock();

        const sql =
            "INSERT INTO mac_command_metrics(command_tag, outcome, level, latency_ns) VALUES(?, ?, ?, ?);";
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();

        stmt.bindText(1, command_tag);
        stmt.bindText(2, outcome);
        stmt.bindText(3, level);
        stmt.bindInt64(4, latency_ns);
        try stmt.expectDone();
    }

    pub fn count(self: Repository) !i64 {
        self.storage.lock();
        defer self.storage.unlock();

        const sql = "SELECT COUNT(*) FROM mac_command_metrics;";
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();

        try stmt.expectRow();
        return stmt.readInt64(0);
    }
};

const TestApp = struct {
    app: app_mod.App,
    db_path: []u8,
    allocator: std.mem.Allocator,
};

fn testApp(allocator: std.mem.Allocator) !TestApp {
    const db_path = try std.fmt.allocPrint(allocator, "/tmp/lorawan-server-metrics-repo-{d}.db", .{std.time.nanoTimestamp()});
    errdefer allocator.free(db_path);

    const app = try app_mod.App.init(allocator, db_path);
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

test "mac command metrics repository inserts observations" {
    const allocator = std.testing.allocator;
    var app = try testApp(allocator);
    defer testAppDeinit(&app);

    const repo = Repository.init(app.app.storage());
    try repo.insertObservation("device_time_req", "success", "debug", 42);
    try repo.insertObservation("dev_status_ans", "failure", "err", 99);

    try std.testing.expectEqual(@as(i64, 2), try repo.count());
}
