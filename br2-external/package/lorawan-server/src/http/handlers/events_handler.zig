const context_mod = @import("../context.zig");
const crud_repository = @import("../../repository/crud_repository.zig");

pub fn list(ctx: *context_mod.Context) !void {
    const params = try listParams(ctx, "datetime", .desc);
    const page = try ctx.services.events_repo.list(ctx.allocator, params);
    defer {
        for (page.entries) |*record| record.deinit(ctx.allocator);
        ctx.allocator.free(page.entries);
    }

    try ctx.res.setJson(page);
}

fn listParams(ctx: *context_mod.Context, default_sort_by: []const u8, default_sort_order: crud_repository.SortOrder) !crud_repository.ListParams {
    const page = try positiveQueryInt(ctx.req.queryParam("page"), 1);
    const page_size = try positiveQueryInt(ctx.req.queryParam("page_size"), 50);
    if (page_size > 100) return error.BadRequest;

    return .{
        .page = page,
        .page_size = page_size,
        .sort_by = ctx.req.queryParam("sort_by") orelse default_sort_by,
        .sort_order = try sortOrder(ctx.req.queryParam("sort_order"), default_sort_order),
    };
}

fn positiveQueryInt(value: ?[]const u8, default_value: usize) !usize {
    const text = value orelse return default_value;
    const parsed = @import("std").fmt.parseInt(usize, text, 10) catch return error.BadRequest;
    if (parsed == 0) return error.BadRequest;
    return parsed;
}

fn sortOrder(value: ?[]const u8, default_value: crud_repository.SortOrder) !crud_repository.SortOrder {
    const text = value orelse return default_value;
    if (@import("std").ascii.eqlIgnoreCase(text, "asc")) return .asc;
    if (@import("std").ascii.eqlIgnoreCase(text, "desc")) return .desc;
    return error.BadRequest;
}
