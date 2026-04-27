const std = @import("std");

const app_mod = @import("../app.zig");
const storage = @import("../storage.zig");
const Database = app_mod.Database;

pub const Repository = struct {
    db: Database,

    pub fn init(db: Database) Repository {
        return .{ .db = db };
    }

    pub fn deinit(_: Repository) void {}

    pub fn insertObservation(
        self: Repository,
        method: []const u8,
        path: []const u8,
        status_code: u16,
        level: []const u8,
        latency_ns: u64,
    ) !void {
        self.db.mutex.lock();
        defer self.db.mutex.unlock();

        const sql =
            "INSERT INTO http_request_metrics(method, path, status_code, level, latency_ns) VALUES(?, ?, ?, ?, ?);";
        const stmt = try storage.Statement.prepare(self.db.conn, sql);
        defer stmt.deinit();

        stmt.bindText(1, method);
        stmt.bindText(2, path);
        stmt.bindInt(3, status_code);
        stmt.bindText(4, level);
        stmt.bindInt64(5, latency_ns);
        try stmt.expectDone();
    }

    pub fn count(self: Repository) !i64 {
        self.db.mutex.lock();
        defer self.db.mutex.unlock();

        const sql = "SELECT COUNT(*) FROM http_request_metrics;";
        const stmt = try storage.Statement.prepare(self.db.conn, sql);
        defer stmt.deinit();

        try stmt.expectRow();
        return stmt.readInt64(0);
    }

    pub fn countByStatus(self: Repository, status_code: u16) !i64 {
        self.db.mutex.lock();
        defer self.db.mutex.unlock();

        const sql = "SELECT COUNT(*) FROM http_request_metrics WHERE status_code = ?;";
        const stmt = try storage.Statement.prepare(self.db.conn, sql);
        defer stmt.deinit();

        stmt.bindInt(1, status_code);
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
    const db_path = try std.fmt.allocPrint(allocator, "/tmp/lorawan-server-http-metrics-repo-{d}.db", .{std.time.nanoTimestamp()});
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

test "http request metrics repository inserts observations" {
    const allocator = std.testing.allocator;
    var app = try testApp(allocator);
    defer testAppDeinit(&app);

    const repo = Repository.init(app.app.database());
    try repo.insertObservation("GET", "/missing", 404, "info", 42);
    try repo.insertObservation("POST", "/api/devices", 500, "err", 99);

    try std.testing.expectEqual(@as(i64, 2), try repo.count());
}
