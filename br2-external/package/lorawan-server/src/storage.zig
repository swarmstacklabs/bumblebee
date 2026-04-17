const std = @import("std");
const logger = @import("logger.zig");
const pending_downlinks = @import("lora/pending_downlinks.zig");

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Statement = struct {
    raw: *c.sqlite3_stmt,

    pub fn init(raw: *c.sqlite3_stmt) Statement {
        return .{ .raw = raw };
    }

    pub fn prepare(db: *c.sqlite3, sql: []const u8) !Statement {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql.ptr, @as(c_int, @intCast(sql.len)), &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        return Statement.init(stmt.?);
    }

    pub fn deinit(self: Statement) void {
        _ = c.sqlite3_finalize(self.raw);
    }

    pub fn bindText(self: Statement, index: c_int, value: []const u8) void {
        _ = c.sqlite3_bind_text(self.raw, index, value.ptr, @as(c_int, @intCast(value.len)), null);
    }

    pub fn bindInt(self: Statement, index: c_int, value: anytype) void {
        _ = c.sqlite3_bind_int(self.raw, index, @as(c_int, @intCast(value)));
    }

    pub fn bindInt64(self: Statement, index: c_int, value: anytype) void {
        _ = c.sqlite3_bind_int64(self.raw, index, @as(c.sqlite3_int64, @intCast(value)));
    }

    pub fn bindNull(self: Statement, index: c_int) void {
        _ = c.sqlite3_bind_null(self.raw, index);
    }

    pub fn step(self: Statement) c_int {
        return c.sqlite3_step(self.raw);
    }

    pub fn expectDone(self: Statement) !void {
        if (self.step() != c.SQLITE_DONE) return error.SqliteStepFailed;
    }

    pub fn expectRow(self: Statement) !void {
        if (self.step() != c.SQLITE_ROW) return error.SqliteStepFailed;
    }

    pub fn readInt(self: Statement, column: c_int) c_int {
        return c.sqlite3_column_int(self.raw, column);
    }

    pub fn readInt64(self: Statement, column: c_int) i64 {
        return c.sqlite3_column_int64(self.raw, column);
    }

    pub fn readText(self: Statement, column: c_int) ?[]const u8 {
        const value = c.sqlite3_column_text(self.raw, column) orelse return null;
        return std.mem.span(value);
    }

    pub fn columnType(self: Statement, column: c_int) c_int {
        return c.sqlite3_column_type(self.raw, column);
    }
};

pub fn changes(db: *c.sqlite3) c_int {
    return c.sqlite3_changes(db);
}

pub const StatusResponse = struct {
    status: []const u8,

    pub fn init(status: []const u8) StatusResponse {
        return .{ .status = status };
    }

    pub fn deinit(_: StatusResponse) void {}
};

pub const ErrorResponse = struct {
    @"error": []const u8,

    pub fn init(message: []const u8) ErrorResponse {
        return .{ .@"error" = message };
    }

    pub fn deinit(_: ErrorResponse) void {}
};

pub const SystemMemoryUsage = struct {
    total_bytes: u64,
    available_bytes: u64,
    used_bytes: u64,
    process_resident_bytes: u64,
    process_virtual_bytes: u64,

    pub fn init(
        total_bytes: u64,
        available_bytes: u64,
        used_bytes: u64,
        process_resident_bytes: u64,
        process_virtual_bytes: u64,
    ) SystemMemoryUsage {
        return .{
            .total_bytes = total_bytes,
            .available_bytes = available_bytes,
            .used_bytes = used_bytes,
            .process_resident_bytes = process_resident_bytes,
            .process_virtual_bytes = process_virtual_bytes,
        };
    }

    pub fn deinit(_: SystemMemoryUsage) void {}
};

pub const CpuUsage = struct {
    usage_percent: f64,
    user_time_ms: u64,
    system_time_ms: u64,
    logical_cores: usize,

    pub fn init(usage_percent: f64, user_time_ms: u64, system_time_ms: u64, logical_cores: usize) CpuUsage {
        return .{
            .usage_percent = usage_percent,
            .user_time_ms = user_time_ms,
            .system_time_ms = system_time_ms,
            .logical_cores = logical_cores,
        };
    }

    pub fn deinit(_: CpuUsage) void {}
};

pub const SystemResourcesRecord = struct {
    uptime_ms: u64,
    memory: SystemMemoryUsage,
    cpu: CpuUsage,

    pub fn init(uptime_ms: u64, memory: SystemMemoryUsage, cpu: CpuUsage) SystemResourcesRecord {
        return .{
            .uptime_ms = uptime_ms,
            .memory = memory,
            .cpu = cpu,
        };
    }

    pub fn deinit(_: SystemResourcesRecord) void {}
};

pub const DeviceRecord = struct {
    id: i64,
    name: []const u8,
    dev_eui: []const u8,
    app_eui: []const u8,
    app_key: []const u8,
    created_at: []const u8,
    updated_at: []const u8,

    pub fn init(id: i64, name: []const u8, dev_eui: []const u8, app_eui: []const u8, app_key: []const u8, created_at: []const u8, updated_at: []const u8) DeviceRecord {
        return .{
            .id = id,
            .name = name,
            .dev_eui = dev_eui,
            .app_eui = app_eui,
            .app_key = app_key,
            .created_at = created_at,
            .updated_at = updated_at,
        };
    }

    pub fn deinit(self: DeviceRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.dev_eui);
        allocator.free(self.app_eui);
        allocator.free(self.app_key);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
    }
};

pub const DeviceWriteInput = struct {
    name: []const u8,
    dev_eui: []const u8,
    app_eui: []const u8,
    app_key: []const u8,

    pub fn init(name: []const u8, dev_eui: []const u8, app_eui: []const u8, app_key: []const u8) DeviceWriteInput {
        return .{
            .name = name,
            .dev_eui = dev_eui,
            .app_eui = app_eui,
            .app_key = app_key,
        };
    }

    pub fn deinit(self: DeviceWriteInput, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.dev_eui);
        allocator.free(self.app_eui);
        allocator.free(self.app_key);
    }
};

pub const Database = struct {
    allocator: std.mem.Allocator,
    conn: *c.sqlite3,
    mutex: *std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, conn: *c.sqlite3, mutex: *std.Thread.Mutex) Database {
        return .{
            .allocator = allocator,
            .conn = conn,
            .mutex = mutex,
        };
    }

    pub fn deinit(_: Database) void {}
};

pub const App = struct {
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    pending_downlinks: pending_downlinks.Tracker,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !App {
        try ensureDbDir(path);

        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        var db_ptr: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path_z.ptr, &db_ptr) != c.SQLITE_OK or db_ptr == null) {
            return error.SqliteOpenFailed;
        }

        var self = App{
            .allocator = allocator,
            .db = db_ptr.?,
            .pending_downlinks = pending_downlinks.Tracker.init(allocator),
        };
        errdefer {
            self.pending_downlinks.deinit();
            _ = c.sqlite3_close(self.db);
        }

        try self.exec("PRAGMA foreign_keys = ON;");
        try self.runMigrations();
        return self;
    }

    pub fn deinit(self: *App) void {
        self.pending_downlinks.deinit();
        _ = c.sqlite3_close(self.db);
    }

    pub fn database(self: *App) Database {
        return Database.init(self.allocator, self.db, &self.mutex);
    }

    pub fn exec(self: *App, sql: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try execUnlocked(self, sql);
    }

    pub fn runMigrations(self: *App) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try execUnlocked(self, schema_migrations_sql);
        const current_version = try getSchemaVersion(self.db);

        for (migrations) |migration| {
            if (migration.version <= current_version) continue;
            try applyMigration(self.db, migration);
            logger.info("storage", "migration_applied", "sqlite migration applied", .{
                .version = migration.version,
                .name = migration.name,
            });
        }
    }

    fn execUnlocked(self: *App, sql: []const u8) !void {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);

        var err_msg: [*c]u8 = null;
        if (c.sqlite3_exec(self.db, sql_z.ptr, null, null, &err_msg) != c.SQLITE_OK) {
            if (err_msg != null) {
                logger.err("storage", "sqlite_exec_failed", "sqlite exec failed", .{
                    .error_message = std.mem.span(@as([*:0]const u8, err_msg)),
                });
                c.sqlite3_free(err_msg);
            }
            return error.SqliteExecFailed;
        }
    }
};

const Migration = struct {
    version: i64,
    name: []const u8,
    sql: []const u8,

    fn init(version: i64, name: []const u8, sql: []const u8) Migration {
        return .{
            .version = version,
            .name = name,
            .sql = sql,
        };
    }

    fn deinit(_: Migration) void {}
};

const schema_migrations_sql =
    "CREATE TABLE IF NOT EXISTS schema_migrations (" ++
    "version INTEGER PRIMARY KEY, " ++
    "name TEXT NOT NULL, " ++
    "applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP" ++
    ");";

const migration_v1_sql =
    "CREATE TABLE IF NOT EXISTS config (" ++
    "id INTEGER PRIMARY KEY AUTOINCREMENT, " ++
    "name TEXT NOT NULL UNIQUE, " ++
    "value_json TEXT NOT NULL DEFAULT '{}', " ++
    "created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, " ++
    "updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP" ++
    ");" ++
    "INSERT INTO config(name, value_json) VALUES('main', '{}') " ++
    "ON CONFLICT(name) DO NOTHING;" ++
    "CREATE TABLE IF NOT EXISTS users (" ++
    "id INTEGER PRIMARY KEY AUTOINCREMENT, " ++
    "name TEXT NOT NULL UNIQUE, " ++
    "password_hash TEXT NOT NULL DEFAULT '', " ++
    "scope_json TEXT NOT NULL DEFAULT '[]', " ++
    "created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, " ++
    "updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP" ++
    ");" ++
    "CREATE TABLE IF NOT EXISTS gateways (" ++
    "id INTEGER PRIMARY KEY AUTOINCREMENT, " ++
    "mac TEXT NOT NULL UNIQUE, " ++
    "name TEXT NOT NULL, " ++
    "network_name TEXT, " ++
    "gateway_json TEXT NOT NULL DEFAULT '{}', " ++
    "created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, " ++
    "updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP" ++
    ");" ++
    "CREATE TABLE IF NOT EXISTS networks (" ++
    "id INTEGER PRIMARY KEY AUTOINCREMENT, " ++
    "name TEXT NOT NULL UNIQUE, " ++
    "network_json TEXT NOT NULL DEFAULT '{}', " ++
    "created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, " ++
    "updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP" ++
    ");" ++
    "CREATE TABLE IF NOT EXISTS devices (" ++
    "id INTEGER PRIMARY KEY AUTOINCREMENT, " ++
    "name TEXT NOT NULL, " ++
    "dev_eui TEXT NOT NULL UNIQUE, " ++
    "app_eui TEXT NOT NULL, " ++
    "app_key TEXT NOT NULL, " ++
    "device_json TEXT NOT NULL DEFAULT '{}', " ++
    "created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, " ++
    "updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP" ++
    ");" ++
    "CREATE TABLE IF NOT EXISTS nodes (" ++
    "id INTEGER PRIMARY KEY AUTOINCREMENT, " ++
    "dev_addr TEXT NOT NULL UNIQUE, " ++
    "device_id INTEGER, " ++
    "node_json TEXT NOT NULL DEFAULT '{}', " ++
    "created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, " ++
    "updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, " ++
    "FOREIGN KEY(device_id) REFERENCES devices(id) ON DELETE SET NULL" ++
    ");" ++
    "CREATE TABLE IF NOT EXISTS events (" ++
    "id INTEGER PRIMARY KEY AUTOINCREMENT, " ++
    "event_type TEXT NOT NULL, " ++
    "entity_type TEXT, " ++
    "entity_id TEXT, " ++
    "payload_json TEXT NOT NULL DEFAULT '{}', " ++
    "created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP" ++
    ");" ++
    "CREATE TABLE IF NOT EXISTS gateway_runtime (" ++
    "gateway_mac TEXT NOT NULL PRIMARY KEY, " ++
    "last_seen_at TEXT, " ++
    "last_seen_unix_ms INTEGER, " ++
    "peer_address TEXT, " ++
    "peer_port INTEGER, " ++
    "pending_downlink_token INTEGER, " ++
    "pending_downlink_json TEXT, " ++
    "updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP" ++
    ");" ++
    "CREATE INDEX IF NOT EXISTS idx_gateways_network_name ON gateways(network_name);" ++
    "CREATE INDEX IF NOT EXISTS idx_nodes_device_id ON nodes(device_id);" ++
    "CREATE INDEX IF NOT EXISTS idx_events_entity ON events(entity_type, entity_id);" ++
    "CREATE INDEX IF NOT EXISTS idx_events_created_at ON events(created_at);";

const migration_v2_sql =
    "ALTER TABLE gateway_runtime ADD COLUMN semtech_version INTEGER;";

const migration_v3_sql =
    "CREATE TABLE IF NOT EXISTS connectors (" ++
    "id INTEGER PRIMARY KEY AUTOINCREMENT, " ++
    "name TEXT NOT NULL UNIQUE, " ++
    "connector_type TEXT NOT NULL, " ++
    "uri TEXT NOT NULL, " ++
    "enabled INTEGER NOT NULL DEFAULT 1, " ++
    "topic TEXT, " ++
    "exchange_name TEXT, " ++
    "routing_key TEXT, " ++
    "partition INTEGER NOT NULL DEFAULT 0, " ++
    "client_id TEXT, " ++
    "username TEXT, " ++
    "password TEXT, " ++
    "created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, " ++
    "updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP" ++
    ");" ++
    "CREATE INDEX IF NOT EXISTS idx_connectors_enabled ON connectors(enabled);";

const migration_v4_sql =
    "CREATE TABLE IF NOT EXISTS mac_command_metrics (" ++
    "id INTEGER PRIMARY KEY AUTOINCREMENT, " ++
    "command_tag TEXT NOT NULL, " ++
    "outcome TEXT NOT NULL, " ++
    "latency_ns INTEGER NOT NULL, " ++
    "created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP" ++
    ");" ++
    "CREATE INDEX IF NOT EXISTS idx_mac_command_metrics_tag_created_at ON mac_command_metrics(command_tag, created_at);" ++
    "CREATE INDEX IF NOT EXISTS idx_mac_command_metrics_created_at ON mac_command_metrics(created_at);";

const migrations = [_]Migration{
    .{
        .version = 1,
        .name = "initial_schema",
        .sql = migration_v1_sql,
    },
    .{
        .version = 2,
        .name = "gateway_runtime_semtech_version",
        .sql = migration_v2_sql,
    },
    .{
        .version = 3,
        .name = "connectors_runtime_table",
        .sql = migration_v3_sql,
    },
    .{
        .version = 4,
        .name = "mac_command_metrics_table",
        .sql = migration_v4_sql,
    },
};

fn getSchemaVersion(db: *c.sqlite3) !i64 {
    const sql = "SELECT COALESCE(MAX(version), 0) FROM schema_migrations;";
    const stmt = try Statement.prepare(db, sql);
    defer stmt.deinit();

    try stmt.expectRow();
    return stmt.readInt64(0);
}

fn applyMigration(db: *c.sqlite3, migration: Migration) !void {
    try execDb(db, "BEGIN IMMEDIATE;");
    errdefer execDb(db, "ROLLBACK;") catch {};

    try execDb(db, migration.sql);

    const insert_sql = "INSERT INTO schema_migrations(version, name) VALUES(?, ?);";
    const stmt = try Statement.prepare(db, insert_sql);
    defer stmt.deinit();

    stmt.bindInt64(1, migration.version);
    stmt.bindText(2, migration.name);
    try stmt.expectDone();

    try execDb(db, "COMMIT;");
}

fn execDb(db: *c.sqlite3, sql: []const u8) !void {
    const sql_z = try std.heap.page_allocator.dupeZ(u8, sql);
    defer std.heap.page_allocator.free(sql_z);

    var err_msg: [*c]u8 = null;
    if (c.sqlite3_exec(db, sql_z.ptr, null, null, &err_msg) != c.SQLITE_OK) {
        if (err_msg != null) {
            logger.err("storage", "sqlite_exec_failed", "sqlite exec failed", .{
                .error_message = std.mem.span(@as([*:0]const u8, err_msg)),
            });
            c.sqlite3_free(err_msg);
        }
        return error.SqliteExecFailed;
    }
}

fn ensureDbDir(path: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse return;
    try std.fs.cwd().makePath(dir_path);
}
