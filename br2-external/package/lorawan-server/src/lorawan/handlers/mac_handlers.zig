const std = @import("std");

const commands = @import("../commands.zig");
const context_mod = @import("../context.zig");
const dispatcher_mod = @import("../dispatcher.zig");
const router_mod = @import("../router.zig");
const types = @import("../types.zig");

const State = struct {
    allocator: std.mem.Allocator,
    mode: Mode,
    rx_time_ms: i64 = 0,
    gateway_count: usize = 0,
    node: ?*types.Node = null,
    pending_commands: []const commands.Command = &.{},
    pending_index: usize = 0,
    remaining_pending: std.ArrayListUnmanaged(commands.Command) = .{},
};

const Mode = enum {
    response,
    node_update,
};

const routes = [_]router_mod.Route{
    router_mod.Route.init(.link_check_req, handleLinkCheckReq, &.{}),
    router_mod.Route.init(.link_adr_ans, handleAckOnly, &.{}),
    router_mod.Route.init(.duty_cycle_ans, handleAckOnly, &.{}),
    router_mod.Route.init(.rx_param_setup_ans, handleAckOnly, &.{}),
    router_mod.Route.init(.device_time_req, handleDeviceTimeReq, &.{}),
    router_mod.Route.init(.dev_status_ans, handleDevStatusAns, &.{}),
    router_mod.Route.init(.new_channel_ans, handleAckOnly, &.{}),
    router_mod.Route.init(.rx_timing_setup_ans, handleAckOnly, &.{}),
    router_mod.Route.init(.tx_param_setup_ans, handleAckOnly, &.{}),
    router_mod.Route.init(.dl_channel_ans, handleAckOnly, &.{}),
};

const dispatcher = dispatcher_mod.Dispatcher.init(&.{}, router_mod.Router.init(&routes));

pub fn buildResponses(allocator: std.mem.Allocator, incoming: []const commands.Command, rx_time_ms: i64, gateway_count: usize) ![]commands.Command {
    var ctx = context_mod.Context.init(allocator);
    defer ctx.deinit();

    var state = State{
        .allocator = allocator,
        .mode = .response,
        .rx_time_ms = rx_time_ms,
        .gateway_count = gateway_count,
    };
    ctx.setUserData(&state);

    try dispatchIgnoringMissing(&ctx, incoming);
    return ctx.response_commands.toOwnedSlice(allocator);
}

fn dispatchIgnoringMissing(ctx: *context_mod.Context, incoming: []const commands.Command) !void {
    for (incoming, 0..) |command, command_index| {
        dispatcher.handle(ctx, command_index, command) catch |err| switch (err) {
            error.CommandHandlerNotFound => {},
            else => return err,
        };
    }
}

fn handleLinkCheckReq(ctx: *context_mod.Context) !void {
    const state = ctx.data(State);
    if (state.mode != .response) return;

    try ctx.appendResponse(.{ .link_check_ans = .{
        .margin = 0,
        .gateway_count = @intCast(@min(state.gateway_count, std.math.maxInt(u8))),
    } });
}

fn handleDeviceTimeReq(ctx: *context_mod.Context) !void {
    const state = ctx.data(State);
    if (state.mode != .response) return;

    try ctx.appendResponse(.{ .device_time_ans = .{
        .milliseconds_since_epoch = state.rx_time_ms,
    } });
}

fn handleDevStatusAns(ctx: *context_mod.Context) !void {
    const state = ctx.data(State);
    if (state.mode != .node_update) return;

    const node = state.node orelse return;
    const command = try ctx.currentCommand();
    node.last_battery = command.dev_status_ans.battery;
    node.last_dev_status_margin = command.dev_status_ans.margin;
}

fn handleAckOnly(ctx: *context_mod.Context) !void {
    const state = ctx.data(State);
    if (state.mode != .node_update) return;

    const node = state.node orelse return;
    const command = try ctx.currentCommand();
    const pending = takePendingForAnswer(state, command) orelse return;

    switch (command) {
        .link_adr_ans => |answer| {
            switch (pending) {
                .link_adr_req => |request| if (answer.power_ack and answer.data_rate_ack and answer.channel_mask_ack) {
                    node.adr_use.tx_power = @intCast(request.tx_power);
                    node.adr_use.data_rate = request.data_rate;
                },
                else => {},
            }
        },
        .rx_param_setup_ans => |answer| {
            switch (pending) {
                .rx_param_setup_req => |request| if (answer.rx1_dr_offset_ack and answer.rx2_data_rate_ack and answer.channel_ack) {
                    node.rxwin_use.rx1_dr_offset = request.rx1_dr_offset;
                    node.rxwin_use.rx2_data_rate = request.rx2_data_rate;
                    node.rxwin_use.frequency = @as(f64, @floatFromInt(request.frequency_100hz)) / 10_000.0;
                },
                else => {},
            }
        },
        else => {},
    }
}

pub fn applyToNode(allocator: std.mem.Allocator, node: *types.Node, pending_commands: []const commands.Command, incoming: []const commands.Command) ![]commands.Command {
    var ctx = context_mod.Context.init(allocator);
    defer ctx.deinit();

    var state = State{
        .allocator = allocator,
        .mode = .node_update,
        .node = node,
        .pending_commands = pending_commands,
    };
    defer state.remaining_pending.deinit(allocator);
    ctx.setUserData(&state);

    try dispatchIgnoringMissing(&ctx, incoming);

    while (state.pending_index < state.pending_commands.len) : (state.pending_index += 1) {
        try state.remaining_pending.append(allocator, state.pending_commands[state.pending_index]);
    }

    return state.remaining_pending.toOwnedSlice(allocator);
}

fn takePendingForAnswer(state: *State, answer: commands.Command) ?commands.Command {
    const expected = expectedPendingTag(answer) orelse return null;

    while (state.pending_index < state.pending_commands.len) : (state.pending_index += 1) {
        const pending = state.pending_commands[state.pending_index];
        if (std.meta.activeTag(pending) == expected) {
            state.pending_index += 1;
            return pending;
        }

        state.remaining_pending.append(state.allocator, pending) catch unreachable;
    }

    return null;
}

fn expectedPendingTag(answer: commands.Command) ?context_mod.CommandTag {
    return switch (answer) {
        .link_adr_ans => .link_adr_req,
        .duty_cycle_ans => .duty_cycle_req,
        .rx_param_setup_ans => .rx_param_setup_req,
        .new_channel_ans => .new_channel_req,
        .rx_timing_setup_ans => .rx_timing_setup_req,
        .tx_param_setup_ans => .tx_param_setup_req,
        .dl_channel_ans => .dl_channel_req,
        else => null,
    };
}

test "mac command handlers build responses via dispatcher" {
    const incoming = [_]commands.Command{
        .link_check_req,
        .device_time_req,
        .duty_cycle_ans,
    };

    const response = try buildResponses(std.testing.allocator, &incoming, 1234, 3);
    defer std.testing.allocator.free(response);

    try std.testing.expectEqual(@as(usize, 2), response.len);
    try std.testing.expect(response[0] == .link_check_ans);
    try std.testing.expectEqual(@as(u8, 3), response[0].link_check_ans.gateway_count);
    try std.testing.expect(response[1] == .device_time_ans);
    try std.testing.expectEqual(@as(i64, 1234), response[1].device_time_ans.milliseconds_since_epoch);
}

test "mac command handlers update node state" {
    var node = types.Node.init([_]u8{ 1, 2, 3, 4 }, [_]u8{0} ** 16, [_]u8{0} ** 16, .{}, .{ .tx_power = 0, .data_rate = 0 });
    const remaining = try applyToNode(std.testing.allocator, &node, &[_]commands.Command{
        .{ .link_adr_req = .{ .data_rate = 5, .tx_power = 7, .channel_mask = 0x00FF, .ch_mask_cntl = 0, .nb_rep = 1 } },
        .{ .rx_param_setup_req = .{ .rx1_dr_offset = 3, .rx2_data_rate = 4, .frequency_100hz = 8695250 } },
    }, &[_]commands.Command{
        .{ .link_adr_ans = .{ .power_ack = true, .data_rate_ack = true, .channel_mask_ack = true } },
        .{ .rx_param_setup_ans = .{ .rx1_dr_offset_ack = true, .rx2_data_rate_ack = true, .channel_ack = true } },
        .{ .dev_status_ans = .{ .battery = 99, .margin = -2 } },
        .device_time_req,
    });
    defer std.testing.allocator.free(remaining);

    try std.testing.expectEqual(@as(?u8, 99), node.last_battery);
    try std.testing.expectEqual(@as(?i8, -2), node.last_dev_status_margin);
    try std.testing.expectEqual(@as(i32, 7), node.adr_use.tx_power);
    try std.testing.expectEqual(@as(u8, 5), node.adr_use.data_rate);
    try std.testing.expectEqual(@as(u8, 3), node.rxwin_use.rx1_dr_offset);
    try std.testing.expectEqual(@as(u8, 4), node.rxwin_use.rx2_data_rate);
    try std.testing.expectEqual(@as(f64, 869.525), node.rxwin_use.frequency);
    try std.testing.expectEqual(@as(usize, 0), remaining.len);
}
