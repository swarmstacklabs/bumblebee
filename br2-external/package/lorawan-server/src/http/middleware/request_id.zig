const std = @import("std");

const context_mod = @import("../context.zig");
const runtime = @import("../runtime.zig");

pub fn middleware(ctx: *context_mod.Context, exec: *runtime.Executor) runtime.AppError!void {
    const request_id = try std.fmt.allocPrint(ctx.allocator, "req-{d}", .{std.time.microTimestamp()});
    ctx.request_id = request_id;
    try ctx.res.setHeader("X-Request-Id", request_id);
    try exec.next(ctx);
}
