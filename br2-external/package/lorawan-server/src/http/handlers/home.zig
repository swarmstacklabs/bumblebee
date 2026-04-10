const context_mod = @import("../context.zig");

pub fn handle(ctx: *context_mod.Context) !void {
    ctx.res.setText(.ok, "lorawan-server\n");
}
