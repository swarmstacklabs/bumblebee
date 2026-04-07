const std = @import("std");

const app_mod = @import("app.zig");
const http_server = @import("http_server.zig");
const udp_server = @import("udp_server.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var app: app_mod.App = undefined;
var runtime_config: app_mod.Config = undefined;

pub fn main() !void {
    defer _ = gpa.detectLeaks();
    const allocator = gpa.allocator();

    runtime_config = try app_mod.Config.load(allocator);
    defer runtime_config.deinit();
    runtime_config.logSummary();

    app = try app_mod.App.init(allocator, runtime_config.db_path);
    defer app.deinit();

    const http_thread = try std.Thread.spawn(.{}, http_server.serverMain, .{ &app, &runtime_config });
    defer http_thread.join();

    try udp_server.serverMain(&app, &runtime_config);
}
