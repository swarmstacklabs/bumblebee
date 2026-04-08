const std = @import("std");

const context_mod = @import("../http/context.zig");
const runtime = @import("../http/runtime.zig");
const logger = @import("../logger.zig");

pub fn middleware(ctx: *context_mod.Context, exec: *runtime.Executor) runtime.AppError!void {
    logger.info("http", "request_started", "http request started", .{
        .method = @tagName(ctx.req.method),
        .path = ctx.req.path,
        .request_id = ctx.request_id,
    });

    try exec.next(ctx);

    logger.info("http", "request_finished", "http request finished", .{
        .method = @tagName(ctx.req.method),
        .path = ctx.req.path,
        .status = ctx.res.status,
        .request_id = ctx.request_id,
    });
}
