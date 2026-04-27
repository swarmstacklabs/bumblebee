const std = @import("std");

const app_mod = @import("app.zig");
const logger = @import("logger.zig");
const maintenance = @import("maintenance.zig");
const server = @import("server.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub fn main() !void {
    defer _ = gpa.detectLeaks();
    const allocator = gpa.allocator();

    var runtime_config = try app_mod.Config.load(allocator);
    defer runtime_config.deinit();
    logger.setLevel(runtime_config.log_level);
    try logger.configureFileLogging(allocator, runtime_config.log_dir);
    defer logger.deinit();
    runtime_config.logSummary();

    var app = try app_mod.App.init(allocator, runtime_config.db_path);
    defer app.deinit();
    _ = maintenance.run(&app, &runtime_config, std.time.milliTimestamp()) catch |err| {
        logger.warn("maintenance", "startup_cleanup_failed", "startup retention cleanup failed", .{
            .error_name = @errorName(err),
        });
    };

    server.serverMain(&app, &runtime_config) catch |err| switch (err) {
        error.ServerStartupFailed => return,
        else => {
            logger.err("server", "server_failed", "server terminated with an unrecoverable error", .{
                .error_name = @errorName(err),
            });
            return err;
        },
    };
}
