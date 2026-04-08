const context_mod = @import("../http/context.zig");
const runtime = @import("../http/runtime.zig");
const request_mod = @import("../http/request.zig");

pub fn middleware(ctx: *context_mod.Context, exec: *runtime.Executor) runtime.AppError!void {
    try ctx.res.setHeader("Access-Control-Allow-Origin", "*");
    try ctx.res.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type");
    try ctx.res.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, PATCH, OPTIONS");

    if (ctx.req.method == request_mod.Method.OPTIONS) {
        ctx.res.setText(204, "");
        return;
    }

    try exec.next(ctx);
}
