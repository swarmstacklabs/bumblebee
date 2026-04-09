const context_mod = @import("../context.zig");
const runtime = @import("../runtime.zig");

pub fn middleware(ctx: *context_mod.Context, exec: *runtime.Executor) runtime.AppError!void {
    ctx.user_id = try ctx.services.authenticator.authenticateBasic(
        ctx.allocator,
        ctx.req.header("Authorization"),
    );
    try exec.next(ctx);
}
