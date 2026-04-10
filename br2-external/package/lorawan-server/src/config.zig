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
pub const env_frontend_root = "LORAWAN_SERVER_FRONTEND_ROOT";

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
    frontend_root: []u8,
    admin: AdminConfig,

    pub fn init(allocator: std.mem.Allocator, bind_address: []const u8, udp_port: u16, http_port: u16, db_path: []u8, frontend_root: []u8, admin: AdminConfig) Config {
        return .{
            .allocator = allocator,
            .bind_address = bind_address,
            .udp_port = udp_port,
            .http_port = http_port,
            .db_path = db_path,
            .frontend_root = frontend_root,
            .admin = admin,
        };
    }

    pub fn initWithDefaultFrontendRoot(
        allocator: std.mem.Allocator,
        bind_address: []const u8,
        udp_port: u16,
        http_port: u16,
        db_path: []const u8,
        admin: AdminConfig,
    ) !Config {
        return Config.init(
            allocator,
            bind_address,
            udp_port,
            http_port,
            try allocator.dupe(u8, db_path),
            try allocator.dupe(u8, defaultFrontendRoot()),
            admin,
        );
    }

    pub fn load(allocator: std.mem.Allocator) !Config {
        var cfg = Config.init(
            allocator,
            default_bind_address,
            try loadPort(allocator, env_udp_port, default_udp_port),
            try loadPort(allocator, env_http_port, default_http_port),
            try loadOwnedString(allocator, env_db_path, defaultDbPath()),
            try loadOwnedString(allocator, env_frontend_root, defaultFrontendRoot()),
            AdminConfig.init(
                try loadOptionalString(allocator, env_admin_user),
                try loadOptionalString(allocator, env_admin_pass),
            ),
        );
        errdefer cfg.deinit();

        try cfg.validate();
        return cfg;
    }

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.db_path);
        self.allocator.free(self.frontend_root);
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
            .frontend_root = self.frontend_root,
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

fn defaultFrontendRoot() []const u8 {
    return switch (builtin.cpu.arch) {
        .arm, .aarch64 => "/usr/share/lorawan-server/ui",
        else => "./ui",
    };
}

fn loadPort(allocator: std.mem.Allocator, name: []const u8, fallback: u16) !u16 {
    const raw = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return fallback,
        else => return err,
    };
    defer allocator.free(raw);

    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return fallback;

    return std.fmt.parseInt(u16, value, 10);
}

fn loadOwnedString(allocator: std.mem.Allocator, name: []const u8, fallback: []const u8) ![]u8 {
    const raw = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return allocator.dupe(u8, fallback),
        else => return err,
    };
    errdefer allocator.free(raw);

    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) {
        allocator.free(raw);
        return allocator.dupe(u8, fallback);
    }
    if (value.ptr == raw.ptr and value.len == raw.len) return raw;

    const normalized = try allocator.dupe(u8, value);
    allocator.free(raw);
    return normalized;
}

fn loadOptionalString(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const raw = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    errdefer allocator.free(raw);

    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) {
        allocator.free(raw);
        return null;
    }
    if (value.ptr == raw.ptr and value.len == raw.len) return raw;

    const normalized = try allocator.dupe(u8, value);
    allocator.free(raw);
    return normalized;
}
