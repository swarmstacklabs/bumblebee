const context_mod = @import("../http/context.zig");

pub fn handle(ctx: *context_mod.Context) !void {
    ctx.res.setText(200, "ok\n");
}
