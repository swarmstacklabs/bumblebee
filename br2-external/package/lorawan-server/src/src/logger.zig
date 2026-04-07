const std = @import("std");

pub const Level = enum {
    debug,
    info,
    warn,
    err,
};

var mutex: std.Thread.Mutex = .{};

pub fn debug(scope: []const u8, event: []const u8, message: []const u8, fields: anytype) void {
    log(.debug, scope, event, message, fields);
}

pub fn info(scope: []const u8, event: []const u8, message: []const u8, fields: anytype) void {
    log(.info, scope, event, message, fields);
}

pub fn warn(scope: []const u8, event: []const u8, message: []const u8, fields: anytype) void {
    log(.warn, scope, event, message, fields);
}

pub fn err(scope: []const u8, event: []const u8, message: []const u8, fields: anytype) void {
    log(.err, scope, event, message, fields);
}

fn log(level: Level, scope: []const u8, event: []const u8, message: []const u8, fields: anytype) void {
    mutex.lock();
    defer mutex.unlock();

    const record = .{
        .ts_ms = std.time.milliTimestamp(),
        .level = @tagName(level),
        .scope = scope,
        .event = event,
        .message = message,
        .fields = fields,
    };
    const encoded = std.json.Stringify.valueAlloc(std.heap.page_allocator, record, .{}) catch return;
    defer std.heap.page_allocator.free(encoded);

    std.fs.File.stderr().writeAll(encoded) catch {};
    std.fs.File.stderr().writeAll("\n") catch {};
}
