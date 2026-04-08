const std = @import("std");

const context_mod = @import("../http/context.zig");
const runtime = @import("../http/runtime.zig");

pub fn middleware(ctx: *context_mod.Context, exec: *runtime.Executor) runtime.AppError!void {
    if (!ctx.config.admin.isConfigured()) {
        ctx.user_id = "anonymous";
        try exec.next(ctx);
        return;
    }

    const header = ctx.req.header("Authorization") orelse return error.Unauthorized;
    if (!std.ascii.startsWithIgnoreCase(header, "Basic ")) return error.Unauthorized;

    const encoded = std.mem.trim(u8, header["Basic ".len..], " \t");
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.Unauthorized;
    const decoded = try ctx.allocator.alloc(u8, decoded_len);
    defer ctx.allocator.free(decoded);

    _ = std.base64.standard.Decoder.decode(decoded, encoded) catch return error.Unauthorized;
    const sep = std.mem.indexOfScalar(u8, decoded, ':') orelse return error.Unauthorized;

    const user = decoded[0..sep];
    const pass = decoded[sep + 1 ..];
    if (!std.mem.eql(u8, user, ctx.config.admin.user.?) or !std.mem.eql(u8, pass, ctx.config.admin.pass.?)) {
        return error.Unauthorized;
    }

    ctx.user_id = ctx.config.admin.user.?;
    try exec.next(ctx);
}
