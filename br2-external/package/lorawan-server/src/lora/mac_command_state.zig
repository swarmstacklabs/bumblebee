const std = @import("std");

const commands = @import("commands.zig");
const context_mod = @import("context.zig");
const types = @import("types.zig");

pub const Mode = enum {
    response,
    node_update,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    mode: Mode,
    rx_time_ms: ?i64 = null,
    link_margin: u8 = 0,
    gateway_count: usize = 0,
    node: ?*types.Node = null,
    region: ?types.Region = null,
    pending_commands: []const commands.Command = &.{},
    pending_state_ready: bool = false,
    pending_index: usize = 0,
    remaining_pending: std.ArrayListUnmanaged(commands.Command) = .{},
    correlated_pending: ?commands.Command = null,
};

pub fn requiresNode(tag: context_mod.CommandTag) bool {
    return switch (tag) {
        .link_adr_ans,
        .duty_cycle_ans,
        .rx_param_setup_ans,
        .dev_status_ans,
        .new_channel_ans,
        .rx_timing_setup_ans,
        .tx_param_setup_ans,
        .dl_channel_ans,
        => true,
        else => false,
    };
}

pub fn requiresRegion(tag: context_mod.CommandTag) bool {
    return switch (tag) {
        .link_adr_ans,
        .tx_param_setup_ans,
        .new_channel_ans,
        .dl_channel_ans,
        => true,
        else => false,
    };
}

pub fn requiresPendingState(tag: context_mod.CommandTag) bool {
    return switch (tag) {
        .link_adr_ans,
        .duty_cycle_ans,
        .rx_param_setup_ans,
        .dev_status_ans,
        .new_channel_ans,
        .rx_timing_setup_ans,
        .tx_param_setup_ans,
        .dl_channel_ans,
        => true,
        else => false,
    };
}
