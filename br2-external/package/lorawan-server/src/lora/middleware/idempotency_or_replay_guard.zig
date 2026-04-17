const std = @import("std");

const context_mod = @import("../context.zig");
const mac_command_state = @import("../mac_command_state.zig");
const runtime = @import("../runtime.zig");
const logger = @import("../../logger.zig");

pub fn middleware(ctx: *context_mod.Context, exec: *runtime.Executor) runtime.AppError!void {
    const state = ctx.data(mac_command_state.State);
    if (state.mode != .node_update) return exec.next(ctx);

    const command = try ctx.currentCommand();
    if (isDuplicateCommand(state.processed_uplink_commands.items, command)) {
        logger.debug("lora_mac", "command_replay_skipped", "skipped duplicate uplink mac command", .{
            .command = @tagName(std.meta.activeTag(command)),
            .command_index = ctx.command_index,
        });
        return;
    }

    try state.processed_uplink_commands.append(state.allocator, command);
    return exec.next(ctx);
}

fn isDuplicateCommand(seen: []const mac_command_state.Command, command: mac_command_state.Command) bool {
    for (seen) |value| {
        if (std.meta.eql(value, command)) return true;
    }
    return false;
}
