const std = @import("std");

const config = @import("config.zig");
const http_server = @import("http_server.zig");
const storage = @import("storage.zig");
const udp_server = @import("udp_server.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var app: storage.App = undefined;
var runtime_config: config.Config = undefined;

pub fn main() !void {
    defer _ = gpa.detectLeaks();
    const allocator = gpa.allocator();

    runtime_config = try config.Config.load(allocator);
    defer runtime_config.deinit();
    runtime_config.logSummary();

    app = try storage.App.init(allocator, runtime_config.db_path);
    defer app.deinit();

    const http_thread = try std.Thread.spawn(.{}, http_server.serverMain, .{ &app, &runtime_config });
    defer http_thread.join();

    try udp_server.serverMain(&app, &runtime_config);
}
