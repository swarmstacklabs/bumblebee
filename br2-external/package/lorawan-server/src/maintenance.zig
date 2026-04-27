const std = @import("std");

const app_mod = @import("app.zig");
const logger = @import("logger.zig");
const storage = @import("storage.zig");

const cleanup_interval_ms: i64 = 60 * 60 * 1000;
const ns_per_ms: i128 = 1_000_000;

pub const CleanupResult = struct {
    log_files_deleted: usize = 0,
    mac_metrics_deleted: i64 = 0,
    http_metrics_deleted: i64 = 0,
};

pub const Scheduler = struct {
    next_run_ms: i64,

    pub fn init(now_ms: i64) Scheduler {
        return .{ .next_run_ms = now_ms + cleanup_interval_ms };
    }

    pub fn pollTimeoutMs(self: Scheduler, now_ms: i64) i32 {
        const delta = self.next_run_ms - now_ms;
        if (delta <= 0) return 0;
        return @intCast(@min(delta, std.math.maxInt(i32)));
    }

    pub fn runIfDue(self: *Scheduler, app: *app_mod.App, config: *const app_mod.Config) void {
        const now_ms = std.time.milliTimestamp();
        if (now_ms < self.next_run_ms) return;

        _ = run(app, config, now_ms) catch |err| {
            logger.warn("maintenance", "cleanup_failed", "retention cleanup failed", .{
                .error_name = @errorName(err),
            });
        };
        self.next_run_ms = now_ms + cleanup_interval_ms;
    }
};

pub fn run(app: *app_mod.App, config: *const app_mod.Config, now_ms: i64) !CleanupResult {
    const result = CleanupResult{
        .log_files_deleted = try cleanupLogs(config.log_dir, now_ms, config.log_cleanup_period_ms),
        .mac_metrics_deleted = try cleanupMetricTable(app.database(), "mac_command_metrics", now_ms, config.metrics_cleanup_period_ms),
        .http_metrics_deleted = try cleanupMetricTable(app.database(), "http_request_metrics", now_ms, config.metrics_cleanup_period_ms),
    };

    if (result.log_files_deleted != 0 or result.mac_metrics_deleted != 0 or result.http_metrics_deleted != 0) {
        logger.info("maintenance", "cleanup_completed", "retention cleanup completed", .{
            .log_files_deleted = result.log_files_deleted,
            .mac_metrics_deleted = result.mac_metrics_deleted,
            .http_metrics_deleted = result.http_metrics_deleted,
        });
    }

    return result;
}

fn cleanupLogs(log_dir: []const u8, now_ms: i64, retention_ms: i64) !usize {
    var dir = std.fs.openDirAbsolute(log_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close();

    const cutoff_ns = @as(i128, @intCast(now_ms - retention_ms)) * ns_per_ms;
    var deleted: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!isManagedLogFile(entry.name)) continue;

        const stat = try dir.statFile(entry.name);
        if (stat.mtime >= cutoff_ns) continue;

        try dir.deleteFile(entry.name);
        deleted += 1;
    }
    return deleted;
}

fn isManagedLogFile(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "lorawan-server-") and std.mem.endsWith(u8, name, ".log");
}

fn cleanupMetricTable(db: app_mod.Database, table_name: []const u8, now_ms: i64, retention_ms: i64) !i64 {
    db.mutex.lock();
    defer db.mutex.unlock();

    const cutoff_seconds = @divTrunc(now_ms - retention_ms, 1000);
    const sql = try std.fmt.allocPrint(db.allocator, "DELETE FROM {s} WHERE unixepoch(created_at) < ?;", .{table_name});
    defer db.allocator.free(sql);

    const stmt = try storage.Statement.prepare(db.conn, sql);
    defer stmt.deinit();

    stmt.bindInt64(1, cutoff_seconds);
    try stmt.expectDone();
    return storage.changes(db.conn);
}

const TestApp = struct {
    app: app_mod.App,
    db_path: []u8,
    allocator: std.mem.Allocator,
};

fn testApp(allocator: std.mem.Allocator) !TestApp {
    const db_path = try std.fmt.allocPrint(allocator, "/tmp/lorawan-server-maintenance-{d}.db", .{std.time.nanoTimestamp()});
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

test "cleanup removes metrics older than retention window" {
    const allocator = std.testing.allocator;
    var test_app = try testApp(allocator);
    defer testAppDeinit(&test_app);

    try test_app.app.exec(
        "INSERT INTO mac_command_metrics(command_tag, outcome, level, latency_ns, created_at) VALUES('device_time_req', 'success', 'debug', 1, datetime('now', '-40 days'));" ++
            "INSERT INTO mac_command_metrics(command_tag, outcome, level, latency_ns, created_at) VALUES('dev_status_ans', 'failure', 'err', 2, datetime('now'));" ++
            "INSERT INTO http_request_metrics(method, path, status_code, level, latency_ns, created_at) VALUES('GET', '/old', 404, 'info', 3, datetime('now', '-40 days'));" ++
            "INSERT INTO http_request_metrics(method, path, status_code, level, latency_ns, created_at) VALUES('GET', '/new', 200, 'debug', 4, datetime('now'));",
    );

    const result = CleanupResult{
        .mac_metrics_deleted = try cleanupMetricTable(test_app.app.database(), "mac_command_metrics", std.time.milliTimestamp(), 30 * 24 * 60 * 60 * 1000),
        .http_metrics_deleted = try cleanupMetricTable(test_app.app.database(), "http_request_metrics", std.time.milliTimestamp(), 30 * 24 * 60 * 60 * 1000),
    };

    try std.testing.expectEqual(@as(i64, 1), result.mac_metrics_deleted);
    try std.testing.expectEqual(@as(i64, 1), result.http_metrics_deleted);
}
