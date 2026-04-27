const std = @import("std");

pub const Level = enum {
    debug,
    info,
    warn,
    err,
};

var mutex: std.Thread.Mutex = .{};
var min_level: Level = .info;
var file_allocator: ?std.mem.Allocator = null;
var file_log_dir: ?[]u8 = null;

const ms_per_day: i64 = 24 * 60 * 60 * 1000;

pub fn setLevel(level: Level) void {
    mutex.lock();
    defer mutex.unlock();
    min_level = level;
}

pub fn currentLevel() Level {
    mutex.lock();
    defer mutex.unlock();
    return min_level;
}

pub fn configureFileLogging(allocator: std.mem.Allocator, log_dir: []const u8) !void {
    try std.fs.cwd().makePath(log_dir);

    mutex.lock();
    defer mutex.unlock();

    if (file_log_dir) |existing| {
        file_allocator.?.free(existing);
    }
    file_log_dir = try allocator.dupe(u8, log_dir);
    file_allocator = allocator;
}

pub fn deinit() void {
    mutex.lock();
    defer mutex.unlock();

    if (file_log_dir) |existing| {
        file_allocator.?.free(existing);
        file_log_dir = null;
        file_allocator = null;
    }
}

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
    if (@intFromEnum(level) < @intFromEnum(min_level)) return;

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
    writeFileRecord(encoded);
}

fn writeFileRecord(encoded: []const u8) void {
    const dir = file_log_dir orelse return;
    const day = @divFloor(std.time.milliTimestamp(), ms_per_day);

    const filename = std.fmt.allocPrint(std.heap.page_allocator, "lorawan-server-{d}.log", .{day}) catch return;
    defer std.heap.page_allocator.free(filename);

    const path = std.fs.path.join(std.heap.page_allocator, &.{ dir, filename }) catch return;
    defer std.heap.page_allocator.free(path);

    var file = std.fs.createFileAbsolute(path, .{ .truncate = false }) catch return;
    defer file.close();

    file.seekFromEnd(0) catch return;
    file.writeAll(encoded) catch return;
    file.writeAll("\n") catch return;
}
