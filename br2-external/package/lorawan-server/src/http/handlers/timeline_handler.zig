const std = @import("std");

const context_mod = @import("../context.zig");
const crud_repository = @import("../../repository/crud_repository.zig");

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
    const params = crud_repository.ListParams{
        .page = 1,
        .page_size = 100,
        .sort_by = "datetime",
        .sort_order = .desc,
    };
    const page = try ctx.services.events_repo.list(ctx.allocator, params);
    defer {
        for (page.entries) |*record| record.deinit(ctx.allocator);
        ctx.allocator.free(page.entries);
    }

    var items = try ctx.allocator.alloc(TimelineItem, page.entries.len);
    defer ctx.allocator.free(items);

    for (page.entries, 0..) |event, index| {
        items[index] = .{
            .id = event.evid,
            .content = event.text,
            .start = event.datetime,
            .title = event.args,
        };
    }

    try ctx.res.setJson(TimelineResponse{ .items = items });
}
