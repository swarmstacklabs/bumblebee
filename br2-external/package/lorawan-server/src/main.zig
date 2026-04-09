const std = @import("std");

const app_mod = @import("app.zig");
const server = @import("server.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub fn main() !void {
    defer _ = gpa.detectLeaks();
    const allocator = gpa.allocator();

    var runtime_config = try app_mod.Config.load(allocator);
    defer runtime_config.deinit();
    runtime_config.logSummary();

    var app = try app_mod.App.init(allocator, runtime_config.db_path);
    defer app.deinit();

    try server.serverMain(&app, &runtime_config);
}
