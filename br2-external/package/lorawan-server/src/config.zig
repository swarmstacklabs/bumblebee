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
    admin: AdminConfig,

    pub fn init(allocator: std.mem.Allocator, bind_address: []const u8, udp_port: u16, http_port: u16, db_path: []u8, frontend_path: []u8, admin: AdminConfig) Config {
        return .{
            .allocator = allocator,
            .bind_address = bind_address,
            .udp_port = udp_port,
            .http_port = http_port,
            .db_path = db_path,
            .frontend_path = frontend_path,
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

        return Config.init(
            allocator,
            bind_address,
            udp_port,
            http_port,
            resolved_db_path,
            resolved_frontend_path,
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

        var cfg = Config.init(
            allocator,
            default_bind_address,
            try loadPortFromEnvMap(env_map, env_udp_port, default_udp_port),
            try loadPortFromEnvMap(env_map, env_http_port, default_http_port),
            db_path,
            frontend_path,
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
            .bind_address = self.bind_address,
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

fn loadPortFromEnvMap(env_map: *const std.process.EnvMap, name: []const u8, fallback: u16) !u16 {
    const raw = env_map.get(name) orelse return fallback;
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return fallback;

    return std.fmt.parseInt(u16, value, 10);
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
}

test "load resolves db and frontend paths from env map consistently" {
    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();

    try env_map.put(env_db_path, "data/runtime.db");
    try env_map.put(env_frontend_path, "dist/frontend");

    var cfg = try Config.loadFromEnvMap(std.testing.allocator, &env_map);
    defer cfg.deinit();

    const cwd = try std.process.getCwdAlloc(std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    const expected_db_path = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, "data/runtime.db" });
    defer std.testing.allocator.free(expected_db_path);

    const expected_frontend_path = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, "dist/frontend" });
    defer std.testing.allocator.free(expected_frontend_path);

    try std.testing.expectEqualStrings(expected_db_path, cfg.db_path);
    try std.testing.expectEqualStrings(expected_frontend_path, cfg.frontend_path);
}
