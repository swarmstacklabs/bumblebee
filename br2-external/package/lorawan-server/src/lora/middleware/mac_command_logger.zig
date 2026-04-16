const context_mod = @import("../context.zig");
const runtime = @import("../runtime.zig");
const logger = @import("../../logger.zig");

pub fn middleware(ctx: *context_mod.Context, exec: *runtime.Executor) runtime.AppError!void {
    const command_tag = try ctx.currentTag();

    logger.debug("lora_mac", "command_started", "mac command handling started", .{
        .command = @tagName(command_tag),
        .command_index = ctx.command_index,
    });

    exec.next(ctx) catch |err| {
        logger.debug("lora_mac", "command_failed", "mac command handling failed", .{
            .command = @tagName(command_tag),
            .command_index = ctx.command_index,
            .error_name = @errorName(err),
        });
        return err;
    };

    logger.debug("lora_mac", "command_finished", "mac command handling finished", .{
        .command = @tagName(command_tag),
        .command_index = ctx.command_index,
    });
}
