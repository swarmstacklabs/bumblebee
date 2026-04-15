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
                    try applyChannelMaskState(state.allocator, node, request.ch_mask_cntl, request.channel_mask);
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
        .new_channel_ans => |answer| {
            switch (pending) {
                .new_channel_req => |request| if (answer.data_rate_range_ok and answer.channel_freq_ok) {
                    try applyExtraChannel(
                        state.allocator,
                        node,
                        request.channel_index,
                        @as(f64, @floatFromInt(request.frequency_100hz)) / 10_000.0,
                        request.min_dr,
                        request.max_dr,
                    );
                },
                else => {},
            }
        },
        .dl_channel_ans => |answer| {
            switch (pending) {
                .dl_channel_req => |request| if (answer.uplink_freq_exists and answer.channel_freq_ok) {
                    try applyDlChannelMapping(
                        state.allocator,
                        node,
                        request.channel_index,
                        @as(f64, @floatFromInt(request.frequency_100hz)) / 10_000.0,
                    );
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

fn applyChannelMaskState(allocator: std.mem.Allocator, node: *types.Node, control: u8, mask: u16) !void {
    var masks = if (node.channel_masks) |existing|
        try allocator.dupe(types.ChannelMaskState, existing)
    else
        try allocator.alloc(types.ChannelMaskState, 0);
    errdefer allocator.free(masks);

    var updated = false;
    for (masks) |*entry| {
        if (entry.control == control) {
            entry.mask = mask;
            updated = true;
            break;
        }
    }

    if (!updated) {
        masks = try allocator.realloc(masks, masks.len + 1);
        masks[masks.len - 1] = types.ChannelMaskState.init(control, mask);
    }

    const enabled = try rebuildEnabledChannels(allocator, masks);
    errdefer allocator.free(enabled);

    if (node.channel_masks) |existing| allocator.free(existing);
    if (node.enabled_channels) |existing| allocator.free(existing);
    node.channel_masks = masks;
    node.enabled_channels = enabled;
}

fn rebuildEnabledChannels(allocator: std.mem.Allocator, masks: []const types.ChannelMaskState) ![]u8 {
    var enabled = std.ArrayListUnmanaged(u8){};
    defer enabled.deinit(allocator);

    for (masks) |entry| {
        const base: u16 = @as(u16, entry.control) * 16;
        for (0..16) |bit_index| {
            if ((entry.mask & (@as(u16, 1) << @intCast(bit_index))) == 0) continue;
            const channel_index: u16 = base + @as(u16, @intCast(bit_index));
            if (channel_index > std.math.maxInt(u8)) continue;
            if (!containsU8(enabled.items, @intCast(channel_index))) {
                try enabled.append(allocator, @intCast(channel_index));
            }
        }
    }

    std.mem.sort(u8, enabled.items, {}, comptime std.sort.asc(u8));
    return enabled.toOwnedSlice(allocator);
}

fn applyExtraChannel(allocator: std.mem.Allocator, node: *types.Node, index: u8, frequency: f64, min_data_rate: u8, max_data_rate: u8) !void {
    var channels = if (node.extra_channels) |existing|
        try allocator.dupe(types.ExtraChannel, existing)
    else
        try allocator.alloc(types.ExtraChannel, 0);
    errdefer allocator.free(channels);

    const existing_index = findExtraChannelIndex(channels, index);
    if (frequency == 0) {
        if (existing_index) |value| {
            _ = orderedRemove(types.ExtraChannel, channels, value);
            const resized = try allocator.realloc(channels, channels.len - 1);
            channels = resized;
        }
        try setEnabledChannelPresent(allocator, node, index, false);
    } else {
        const channel = types.ExtraChannel.init(index, frequency, min_data_rate, max_data_rate);
        if (existing_index) |value| {
            channels[value] = channel;
        } else {
            channels = try allocator.realloc(channels, channels.len + 1);
            channels[channels.len - 1] = channel;
        }
        try setEnabledChannelPresent(allocator, node, index, true);
    }

    if (node.extra_channels) |existing| allocator.free(existing);
    node.extra_channels = channels;
}

fn applyDlChannelMapping(allocator: std.mem.Allocator, node: *types.Node, index: u8, frequency: f64) !void {
    var mappings = if (node.dl_channel_map) |existing|
        try allocator.dupe(types.DlChannelMapping, existing)
    else
        try allocator.alloc(types.DlChannelMapping, 0);
    errdefer allocator.free(mappings);

    const existing_index = findDlChannelIndex(mappings, index);
    if (frequency == 0) {
        if (existing_index) |value| {
            _ = orderedRemove(types.DlChannelMapping, mappings, value);
            mappings = try allocator.realloc(mappings, mappings.len - 1);
        }
    } else {
        const mapping = types.DlChannelMapping.init(index, frequency);
        if (existing_index) |value| {
            mappings[value] = mapping;
        } else {
            mappings = try allocator.realloc(mappings, mappings.len + 1);
            mappings[mappings.len - 1] = mapping;
        }
    }

    if (node.dl_channel_map) |existing| allocator.free(existing);
    node.dl_channel_map = mappings;
}

fn setEnabledChannelPresent(allocator: std.mem.Allocator, node: *types.Node, index: u8, present: bool) !void {
    var enabled = if (node.enabled_channels) |existing|
        try allocator.dupe(u8, existing)
    else
        try allocator.alloc(u8, 0);
    errdefer allocator.free(enabled);

    const existing_index = std.mem.indexOfScalar(u8, enabled, index);
    if (present) {
        if (existing_index == null) {
            enabled = try allocator.realloc(enabled, enabled.len + 1);
            enabled[enabled.len - 1] = index;
            std.mem.sort(u8, enabled, {}, comptime std.sort.asc(u8));
        }
    } else if (existing_index) |value| {
        _ = orderedRemove(u8, enabled, value);
        enabled = try allocator.realloc(enabled, enabled.len - 1);
    }

    if (node.enabled_channels) |existing| allocator.free(existing);
    node.enabled_channels = enabled;
}

fn containsU8(values: []const u8, needle: u8) bool {
    return std.mem.indexOfScalar(u8, values, needle) != null;
}

fn findExtraChannelIndex(values: []const types.ExtraChannel, index: u8) ?usize {
    for (values, 0..) |value, value_index| {
        if (value.index == index) return value_index;
    }
    return null;
}

fn findDlChannelIndex(values: []const types.DlChannelMapping, index: u8) ?usize {
    for (values, 0..) |value, value_index| {
        if (value.index == index) return value_index;
    }
    return null;
}

fn orderedRemove(comptime T: type, values: []T, index: usize) []T {
    std.mem.copyForwards(T, values[index .. values.len - 1], values[index + 1 ..]);
    return values[0 .. values.len - 1];
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
    defer node.deinit(std.testing.allocator);

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
    try std.testing.expectEqual(@as(usize, 1), node.channel_masks.?.len);
    try std.testing.expectEqual(@as(u8, 0), node.channel_masks.?[0].control);
    try std.testing.expectEqual(@as(u16, 0x00FF), node.channel_masks.?[0].mask);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 }, node.enabled_channels.?);
    try std.testing.expectEqual(@as(u8, 3), node.rxwin_use.rx1_dr_offset);
    try std.testing.expectEqual(@as(u8, 4), node.rxwin_use.rx2_data_rate);
    try std.testing.expectEqual(@as(f64, 869.525), node.rxwin_use.frequency);
    try std.testing.expectEqual(@as(usize, 0), remaining.len);
}

test "mac command handlers persist channel plan state" {
    var node = types.Node.init([_]u8{ 1, 2, 3, 4 }, [_]u8{0} ** 16, [_]u8{0} ** 16, .{}, .{ .tx_power = 0, .data_rate = 0 });
    defer node.deinit(std.testing.allocator);

    const remaining = try applyToNode(std.testing.allocator, &node, &[_]commands.Command{
        .{ .new_channel_req = .{ .channel_index = 3, .frequency_100hz = 8671000, .max_dr = 5, .min_dr = 0 } },
        .{ .dl_channel_req = .{ .channel_index = 3, .frequency_100hz = 8691000 } },
    }, &[_]commands.Command{
        .{ .new_channel_ans = .{ .data_rate_range_ok = true, .channel_freq_ok = true } },
        .{ .dl_channel_ans = .{ .uplink_freq_exists = true, .channel_freq_ok = true } },
    });
    defer std.testing.allocator.free(remaining);

    try std.testing.expectEqual(@as(usize, 0), remaining.len);
    try std.testing.expectEqual(@as(usize, 1), node.extra_channels.?.len);
    try std.testing.expectEqual(@as(u8, 3), node.extra_channels.?[0].index);
    try std.testing.expectEqual(@as(f64, 867.1), node.extra_channels.?[0].frequency);
    try std.testing.expectEqual(@as(usize, 1), node.dl_channel_map.?.len);
    try std.testing.expectEqual(@as(u8, 3), node.dl_channel_map.?[0].index);
    try std.testing.expectEqual(@as(f64, 869.1), node.dl_channel_map.?[0].frequency);
    try std.testing.expect(containsU8(node.enabled_channels.?, 3));
}
