const std = @import("std");

const context_mod = @import("../context.zig");
const mac_command_state = @import("../mac_command_state.zig");
const runtime = @import("../runtime.zig");

pub fn middleware(ctx: *context_mod.Context, exec: *runtime.Executor) runtime.AppError!void {
    const state = ctx.data(mac_command_state.State);
    if (state.mode != .node_update) return exec.next(ctx);

    state.correlated_pending = null;
    const expected = expectedPendingTagForAnswer(try ctx.currentTag()) orelse return exec.next(ctx);

    while (state.pending_index < state.pending_commands.len) : (state.pending_index += 1) {
        const pending = state.pending_commands[state.pending_index];
        if (std.meta.activeTag(pending) == expected) {
            state.correlated_pending = pending;
            state.pending_index += 1;
            return exec.next(ctx);
        }

        try state.remaining_pending.append(state.allocator, pending);
    }

    return error.UnmatchedMacCommandAnswer;
}

fn expectedPendingTagForAnswer(answer_tag: context_mod.CommandTag) ?context_mod.CommandTag {
    return switch (answer_tag) {
        .link_adr_ans => .link_adr_req,
        .duty_cycle_ans => .duty_cycle_req,
        .rx_param_setup_ans => .rx_param_setup_req,
        .dev_status_ans => .dev_status_req,
        .new_channel_ans => .new_channel_req,
        .rx_timing_setup_ans => .rx_timing_setup_req,
        .tx_param_setup_ans => .tx_param_setup_req,
        .dl_channel_ans => .dl_channel_req,
        else => null,
    };
}
