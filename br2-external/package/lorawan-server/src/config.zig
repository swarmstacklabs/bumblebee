const std = @import("std");
const builtin = @import("builtin");
const logger = @import("logger.zig");

pub const default_udp_port: u16 = 1680;
pub const default_http_port: u16 = 8080;
pub const default_bind_address = "0.0.0.0";

pub const env_udp_port = "LORAWAN_SERVER_UDP_PORT";
pub const env_http_port = "LORAWAN_SERVER_HTTP_PORT";
pub const env_db_path = "LORAWAN_SERVER_DB_PATH";
pub const env_admin_user = "LORAWAN_SERVER_ADMIN_USER";
pub const env_admin_pass = "LORAWAN_SERVER_ADMIN_PASS";
pub const env_frontend_path = "LORAWAN_SERVER_FRONTEND_PATH";
pub const env_log_level = "LORAWAN_SERVER_LOG_LEVEL";
pub const env_log_dir = "LORAWAN_SERVER_LOG_DIR";
pub const env_log_cleanup_period = "LORAWAN_SERVER_LOG_CLEANUP_PERIOD";
pub const env_metrics_cleanup_period = "LORAWAN_SERVER_METRICS_CLEANUP_PERIOD";

pub const default_cleanup_period_ms: i64 = 30 * 24 * 60 * 60 * 1000;

pub const AdminConfig = struct {
    user: ?[]u8,
    pass: ?[]u8,

    pub fn init(user: ?[]u8, pass: ?[]u8) AdminConfig {
        return .{ .user = user, .pass = pass };
    }

    pub fn deinit(self: *AdminConfig, allocator: std.mem.Allocator) void {
        if (self.user) |value| allocator.free(value);
        if (self.pass) |value| allocator.free(value);
    }

    pub fn isConfigured(self: AdminConfig) bool {
        return self.user != null and self.pass != null;
    }
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    bind_address: []const u8,
    udp_port: u16,
    http_port: u16,
    db_path: []u8,
    frontend_path: []u8,
    log_dir: []u8,
    log_level: logger.Level,
    log_cleanup_period_ms: i64,
    metrics_cleanup_period_ms: i64,
    admin: AdminConfig,

    pub fn init(
        allocator: std.mem.Allocator,
        bind_address: []const u8,
        udp_port: u16,
        http_port: u16,
        db_path: []u8,
        frontend_path: []u8,
        log_dir: []u8,
        log_level: logger.Level,
        log_cleanup_period_ms: i64,
        metrics_cleanup_period_ms: i64,
        admin: AdminConfig,
    ) Config {
        return .{
            .allocator = allocator,
            .bind_address = bind_address,
            .udp_port = udp_port,
            .http_port = http_port,
            .db_path = db_path,
            .frontend_path = frontend_path,
            .log_dir = log_dir,
            .log_level = log_level,
            .log_cleanup_period_ms = log_cleanup_period_ms,
            .metrics_cleanup_period_ms = metrics_cleanup_period_ms,
            .admin = admin,
        };
    }

    pub fn initWithDefaultFrontendPath(
        allocator: std.mem.Allocator,
        bind_address: []const u8,
        udp_port: u16,
        http_port: u16,
        db_path: []const u8,
        admin: AdminConfig,
    ) !Config {
        const resolved_db_path = try resolveAbsolutePathValue(allocator, db_path);
        errdefer allocator.free(resolved_db_path);

        const resolved_frontend_path = try resolveAbsolutePathValue(allocator, defaultFrontendPath());
        errdefer allocator.free(resolved_frontend_path);

        const resolved_log_dir = try resolveAbsolutePathValue(allocator, defaultLogDir());
        errdefer allocator.free(resolved_log_dir);

        return Config.init(
            allocator,
            bind_address,
            udp_port,
            http_port,
            resolved_db_path,
            resolved_frontend_path,
            resolved_log_dir,
            .info,
            default_cleanup_period_ms,
            default_cleanup_period_ms,
            admin,
        );
    }

    pub fn load(allocator: std.mem.Allocator) !Config {
        var env_map = try std.process.getEnvMap(allocator);
        defer env_map.deinit();

        return loadFromEnvMap(allocator, &env_map);
    }

    fn loadFromEnvMap(allocator: std.mem.Allocator, env_map: *const std.process.EnvMap) !Config {
        const db_path = try resolveAbsolutePathFromEnvMap(allocator, env_map, env_db_path, defaultDbPath());
        errdefer allocator.free(db_path);

        const frontend_path = try resolveAbsolutePathFromEnvMap(allocator, env_map, env_frontend_path, defaultFrontendPath());
        errdefer allocator.free(frontend_path);

        const log_dir = try resolveAbsolutePathFromEnvMap(allocator, env_map, env_log_dir, defaultLogDir());
        errdefer allocator.free(log_dir);

        var cfg = Config.init(
            allocator,
            default_bind_address,
            try loadPortFromEnvMap(env_map, env_udp_port, default_udp_port),
            try loadPortFromEnvMap(env_map, env_http_port, default_http_port),
            db_path,
            frontend_path,
            log_dir,
            try loadLogLevelFromEnvMap(env_map, env_log_level, .info),
            try loadDurationMsFromEnvMap(env_map, env_log_cleanup_period, default_cleanup_period_ms),
            try loadDurationMsFromEnvMap(env_map, env_metrics_cleanup_period, default_cleanup_period_ms),
            AdminConfig.init(
                try loadOptionalStringFromEnvMap(allocator, env_map, env_admin_user),
                try loadOptionalStringFromEnvMap(allocator, env_map, env_admin_pass),
            ),
        );
        errdefer cfg.deinit();

        try cfg.validate();
        return cfg;
    }

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.db_path);
        self.allocator.free(self.frontend_path);
        self.allocator.free(self.log_dir);
        self.admin.deinit(self.allocator);
    }

    pub fn validate(self: *Config) !void {
        if ((self.admin.user == null) != (self.admin.pass == null)) {
            logger.err("config", "invalid_admin_configuration", "admin auth config is incomplete", .{
                .required_env = .{ env_admin_user, env_admin_pass },
            });
            return error.InvalidAdminConfiguration;
        }
    }

    pub fn logSummary(self: Config) void {
        logger.info("config", "loaded", "runtime configuration loaded", .{
            .udp_port = self.udp_port,
            .http_port = self.http_port,
            .db_path = self.db_path,
            .frontend_path = self.frontend_path,
            .log_dir = self.log_dir,
            .bind_address = self.bind_address,
            .log_level = @tagName(self.log_level),
            .log_cleanup_period_ms = self.log_cleanup_period_ms,
            .metrics_cleanup_period_ms = self.metrics_cleanup_period_ms,
            .admin_auth = if (self.admin.isConfigured()) "enabled" else "disabled",
        });
    }
};

fn defaultDbPath() []const u8 {
    return switch (builtin.cpu.arch) {
        .arm, .aarch64 => "/var/lib/lorawan-server/lorawan-server.db",
        else => "data/lorawan-server.db",
    };
}

fn defaultFrontendPath() []const u8 {
    return switch (builtin.cpu.arch) {
        .arm, .aarch64 => "/usr/share/lorawan-server/frontend",
        else => "frontend",
    };
}

fn defaultLogDir() []const u8 {
    return switch (builtin.cpu.arch) {
        .arm, .aarch64 => "/var/log/lorawan-server",
        else => "data/logs/lorawan-server",
    };
}

fn loadPortFromEnvMap(env_map: *const std.process.EnvMap, name: []const u8, fallback: u16) !u16 {
    const raw = env_map.get(name) orelse return fallback;
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return fallback;

    return std.fmt.parseInt(u16, value, 10);
}

fn loadLogLevelFromEnvMap(env_map: *const std.process.EnvMap, name: []const u8, fallback: logger.Level) !logger.Level {
    const raw = env_map.get(name) orelse return fallback;
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return fallback;

    if (std.ascii.eqlIgnoreCase(value, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(value, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(value, "warn")) return .warn;
    if (std.ascii.eqlIgnoreCase(value, "error") or std.ascii.eqlIgnoreCase(value, "err")) return .err;
    return error.InvalidLogLevel;
}

fn loadDurationMsFromEnvMap(env_map: *const std.process.EnvMap, name: []const u8, fallback: i64) !i64 {
    const raw = env_map.get(name) orelse return fallback;
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return fallback;

    return parseDurationMs(value);
}

fn parseDurationMs(value: []const u8) !i64 {
    var number_len: usize = 0;
    while (number_len < value.len and std.ascii.isDigit(value[number_len])) {
        number_len += 1;
    }
    if (number_len == 0) return error.InvalidDuration;

    const amount = try std.fmt.parseInt(i64, value[0..number_len], 10);
    if (amount <= 0) return error.InvalidDuration;

    const suffix = std.mem.trim(u8, value[number_len..], " \t\r\n");
    const multiplier: i64 = if (suffix.len == 0 or std.ascii.eqlIgnoreCase(suffix, "d") or std.ascii.eqlIgnoreCase(suffix, "day") or std.ascii.eqlIgnoreCase(suffix, "days"))
        24 * 60 * 60 * 1000
    else if (std.ascii.eqlIgnoreCase(suffix, "mo") or std.ascii.eqlIgnoreCase(suffix, "month") or std.ascii.eqlIgnoreCase(suffix, "months"))
        default_cleanup_period_ms
    else if (std.ascii.eqlIgnoreCase(suffix, "h") or std.ascii.eqlIgnoreCase(suffix, "hour") or std.ascii.eqlIgnoreCase(suffix, "hours"))
        60 * 60 * 1000
    else if (std.ascii.eqlIgnoreCase(suffix, "m") or std.ascii.eqlIgnoreCase(suffix, "min") or std.ascii.eqlIgnoreCase(suffix, "minute") or std.ascii.eqlIgnoreCase(suffix, "minutes"))
        60 * 1000
    else if (std.ascii.eqlIgnoreCase(suffix, "s") or std.ascii.eqlIgnoreCase(suffix, "sec") or std.ascii.eqlIgnoreCase(suffix, "second") or std.ascii.eqlIgnoreCase(suffix, "seconds"))
        1000
    else
        return error.InvalidDuration;

    return std.math.mul(i64, amount, multiplier) catch error.InvalidDuration;
}

fn loadOwnedStringFromEnvMap(allocator: std.mem.Allocator, env_map: *const std.process.EnvMap, name: []const u8, fallback: []const u8) ![]u8 {
    const raw = env_map.get(name) orelse return allocator.dupe(u8, fallback);
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) {
        return allocator.dupe(u8, fallback);
    }
    return allocator.dupe(u8, value);
}

fn resolveAbsolutePathFromEnvMap(allocator: std.mem.Allocator, env_map: *const std.process.EnvMap, name: []const u8, fallback: []const u8) ![]u8 {
    const path = try loadOwnedStringFromEnvMap(allocator, env_map, name, fallback);
    defer allocator.free(path);

    return resolveAbsolutePathValue(allocator, path);
}

fn resolveAbsolutePathValue(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

fn loadOptionalStringFromEnvMap(allocator: std.mem.Allocator, env_map: *const std.process.EnvMap, name: []const u8) !?[]u8 {
    const raw = env_map.get(name) orelse return null;
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) {
        return null;
    }
    return try allocator.dupe(u8, value);
}

test "validate accepts config even when frontend root is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_root);

    const frontend_path = try std.fs.path.resolve(std.testing.allocator, &.{ tmp_root, "missing-frontend" });
    defer std.testing.allocator.free(frontend_path);

    var cfg = Config.init(
        std.testing.allocator,
        default_bind_address,
        default_udp_port,
        default_http_port,
        try std.testing.allocator.dupe(u8, "data/test.db"),
        try std.testing.allocator.dupe(u8, frontend_path),
        try std.testing.allocator.dupe(u8, "data/logs/lorawan-server"),
        .info,
        default_cleanup_period_ms,
        default_cleanup_period_ms,
        AdminConfig.init(null, null),
    );
    defer cfg.deinit();

    try cfg.validate();
    try std.testing.expect(std.fs.path.isAbsolute(cfg.frontend_path));
}

test "initWithDefaultFrontendRoot stores an absolute frontend path" {
    var cfg = try Config.initWithDefaultFrontendPath(
        std.testing.allocator,
        default_bind_address,
        default_udp_port,
        default_http_port,
        "data/test.db",
        AdminConfig.init(null, null),
    );
    defer cfg.deinit();

    try std.testing.expect(std.fs.path.isAbsolute(cfg.db_path));
    try std.testing.expect(std.fs.path.isAbsolute(cfg.frontend_path));
    try std.testing.expect(std.fs.path.isAbsolute(cfg.log_dir));
}

test "load resolves db and frontend paths from env map consistently" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();

    try env_map.put(env_db_path, "data/runtime.db");
    try env_map.put(env_frontend_path, "dist/frontend");
    try env_map.put(env_log_dir, "runtime/logs");

    var cfg = try Config.loadFromEnvMap(std.testing.allocator, &env_map);
    defer cfg.deinit();

    const cwd = try std.process.getCwdAlloc(std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    const expected_db_path = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, "data/runtime.db" });
    defer std.testing.allocator.free(expected_db_path);

    const expected_frontend_path = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, "dist/frontend" });
    defer std.testing.allocator.free(expected_frontend_path);

    const expected_log_dir = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, "runtime/logs" });
    defer std.testing.allocator.free(expected_log_dir);

    try std.testing.expectEqualStrings(expected_db_path, cfg.db_path);
    try std.testing.expectEqualStrings(expected_frontend_path, cfg.frontend_path);
    try std.testing.expectEqualStrings(expected_log_dir, cfg.log_dir);
}

test "load parses cleanup retention periods from env map" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();

    try env_map.put(env_log_cleanup_period, "7d");
    try env_map.put(env_metrics_cleanup_period, "12h");

    var cfg = try Config.loadFromEnvMap(std.testing.allocator, &env_map);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(i64, 7 * 24 * 60 * 60 * 1000), cfg.log_cleanup_period_ms);
    try std.testing.expectEqual(@as(i64, 12 * 60 * 60 * 1000), cfg.metrics_cleanup_period_ms);
}
