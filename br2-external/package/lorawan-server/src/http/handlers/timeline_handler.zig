const std = @import("std");

const context_mod = @import("../context.zig");
const events_repository = @import("../../repository/events_repository.zig");

const TimelineItem = struct {
    id: i64,
    content: []const u8,
    start: []const u8,
    title: []const u8,
};

const TimelineResponse = struct {
    items: []TimelineItem,
};

pub fn list(ctx: *context_mod.Context) !void {
    const params = events_repository.TimelineParams{
        .start_ms = try optionalQueryInt(ctx.req.queryParam("start_ms")),
        .end_ms = try optionalQueryInt(ctx.req.queryParam("end_ms")),
        .timezone_offset_minutes = try timezoneOffsetMinutes(ctx.req.queryParam("timezone_offset_minutes")),
        .limit = 100,
    };
    const entries = try ctx.services.events_repo.timeline(ctx.allocator, params);
    defer {
        for (entries) |*record| record.deinit(ctx.allocator);
        ctx.allocator.free(entries);
    }

    var items = try ctx.allocator.alloc(TimelineItem, entries.len);
    defer ctx.allocator.free(items);

    for (entries, 0..) |event, index| {
        items[index] = .{
            .id = event.evid,
            .content = event.text,
            .start = event.datetime,
            .title = event.args,
        };
    }

    try ctx.res.setJson(TimelineResponse{ .items = items });
}

fn optionalQueryInt(value: ?[]const u8) !?i64 {
    const text = value orelse return null;
    if (text.len == 0) return null;
    return std.fmt.parseInt(i64, text, 10) catch return error.BadRequest;
}

fn timezoneOffsetMinutes(value: ?[]const u8) !i32 {
    const parsed = try optionalQueryInt(value) orelse return 0;
    if (parsed < -1440 or parsed > 1440) return error.BadRequest;
    return @intCast(parsed);
}
