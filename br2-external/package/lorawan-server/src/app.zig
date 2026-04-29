const std = @import("std");

const config = @import("config.zig");
const Db = @import("db.zig").Db;
const Database = @import("db.zig").Database;
const pending_downlinks = @import("lora/pending_downlinks.zig");
const storage = @import("storage.zig");

pub const default_udp_port = config.default_udp_port;
pub const default_http_port = config.default_http_port;
pub const default_bind_address = config.default_bind_address;
pub const env_udp_port = config.env_udp_port;
pub const env_http_port = config.env_http_port;
pub const env_db_path = config.env_db_path;
pub const env_admin_user = config.env_admin_user;
pub const env_admin_pass = config.env_admin_pass;
pub const env_frontend_path = config.env_frontend_path;
pub const env_log_level = config.env_log_level;
pub const env_log_dir = config.env_log_dir;
pub const env_log_cleanup_period = config.env_log_cleanup_period;
pub const env_metrics_cleanup_period = config.env_metrics_cleanup_period;
pub const AdminConfig = config.AdminConfig;
pub const Config = config.Config;

pub const StatusResponse = storage.StatusResponse;
pub const ErrorResponse = storage.ErrorResponse;
pub const SystemMemoryUsage = storage.SystemMemoryUsage;
pub const CpuUsage = storage.CpuUsage;
pub const SystemResourcesRecord = storage.SystemResourcesRecord;
pub const DeviceRecord = storage.DeviceRecord;
pub const DeviceWriteInput = storage.DeviceWriteInput;

pub const App = struct {
    allocator: std.mem.Allocator,
    db: *Db,
    pending_downlinks: pending_downlinks.Tracker,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !App {
        var self = App{
            .allocator = allocator,
            .db = try storage.SQLiteDb.create(allocator, path),
            .pending_downlinks = pending_downlinks.Tracker.init(allocator),
        };
        errdefer {
            self.pending_downlinks.deinit();
            self.db.destroy();
        }

        try self.exec("PRAGMA foreign_keys = ON;");
        try self.runMigrations();
        return self;
    }

    pub fn deinit(self: *App) void {
        self.pending_downlinks.deinit();
        self.db.destroy();
    }

    pub fn database(self: *App) Database {
        return Database.init(self.allocator, self.db);
    }

    pub fn exec(self: *App, sql: []const u8) !void {
        try self.db.exec(sql);
    }

    pub fn runMigrations(self: *App) !void {
        try self.db.runMigrations();
    }
};
