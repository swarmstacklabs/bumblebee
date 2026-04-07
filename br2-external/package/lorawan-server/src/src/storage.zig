const std = @import("std");
const logger = @import("logger.zig");

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const StatusResponse = struct {
    status: []const u8,
};

pub const ErrorResponse = struct {
    @"error": []const u8,
};

pub const DeviceJson = struct {
    id: i64,
    name: []const u8,
    dev_eui: []const u8,
    app_eui: []const u8,
    app_key: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const DevicePayload = struct {
    name: []const u8,
    dev_eui: []const u8,
    app_eui: []const u8,
    app_key: []const u8,

    pub fn deinit(self: DevicePayload, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.dev_eui);
        allocator.free(self.app_eui);
        allocator.free(self.app_key);
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !App {
        try ensureDbDir(path);

        var db_ptr: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path.ptr, &db_ptr) != c.SQLITE_OK or db_ptr == null) {
            return error.SqliteOpenFailed;
        }

        var self = App{
            .allocator = allocator,
            .db = db_ptr.?,
        };
        errdefer _ = c.sqlite3_close(self.db);

        try self.exec("PRAGMA foreign_keys = ON;");
        try self.runMigrations();
        return self;
    }

    pub fn deinit(self: *App) void {
        _ = c.sqlite3_close(self.db);
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
        var err_msg: [*c]u8 = null;
        if (c.sqlite3_exec(self.db, sql.ptr, null, null, &err_msg) != c.SQLITE_OK) {
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

const migrations = [_]Migration{
    .{
        .version = 1,
        .name = "initial_schema",
        .sql = migration_v1_sql,
    },
};

fn getSchemaVersion(db: *c.sqlite3) !i64 {
    const sql = "SELECT COALESCE(MAX(version), 0) FROM schema_migrations;";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.ptr, @as(c_int, @intCast(sql.len)), &stmt, null) != c.SQLITE_OK) {
        return error.SqlitePrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const step_result = c.sqlite3_step(stmt);
    if (step_result != c.SQLITE_ROW) return error.SqliteStepFailed;

    return c.sqlite3_column_int64(stmt, 0);
}

fn applyMigration(db: *c.sqlite3, migration: Migration) !void {
    try execDb(db, "BEGIN IMMEDIATE;");
    errdefer execDb(db, "ROLLBACK;") catch {};

    try execDb(db, migration.sql);

    const insert_sql = "INSERT INTO schema_migrations(version, name) VALUES(?, ?);";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, insert_sql.ptr, @as(c_int, @intCast(insert_sql.len)), &stmt, null) != c.SQLITE_OK) {
        return error.SqlitePrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt.?, 1, migration.version);
    _ = c.sqlite3_bind_text(stmt.?, 2, migration.name.ptr, @as(c_int, @intCast(migration.name.len)), null);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        return error.SqliteStepFailed;
    }

    try execDb(db, "COMMIT;");
}

fn execDb(db: *c.sqlite3, sql: []const u8) !void {
    var err_msg: [*c]u8 = null;
    if (c.sqlite3_exec(db, sql.ptr, null, null, &err_msg) != c.SQLITE_OK) {
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
