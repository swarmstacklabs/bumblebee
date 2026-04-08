const context_mod = @import("../http/context.zig");
const runtime = @import("../http/runtime.zig");
const app_mod = @import("../app.zig");
const logger = @import("../logger.zig");

pub fn middleware(ctx: *context_mod.Context, exec: *runtime.Executor) runtime.AppError!void {
    exec.next(ctx) catch |err| switch (err) {
        error.Unauthorized => {
            try ctx.res.setHeader("WWW-Authenticate", "Basic realm=\"lorawan-server\"");
            ctx.res.setText(401, "unauthorized\n");
        },
        error.BadRequest => {
            try ctx.res.setJsonStatus(400, app_mod.ErrorResponse{ .@"error" = "bad request" });
        },
        else => {
            logger.err("http", "request_failed", "http request failed", .{
                .path = ctx.req.path,
                .error_name = @errorName(err),
                .request_id = ctx.request_id,
            });
            ctx.res.setText(500, "internal server error\n");
        },
    };
}
