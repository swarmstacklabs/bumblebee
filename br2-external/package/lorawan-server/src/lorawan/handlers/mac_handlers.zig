const std = @import("std");

const commands = @import("../commands.zig");
const context_mod = @import("../context.zig");
const dispatcher_mod = @import("../dispatcher.zig");
const router_mod = @import("../router.zig");
const types = @import("../types.zig");

const State = struct {
    mode: Mode,
    rx_time_ms: i64 = 0,
    gateway_count: usize = 0,
    node: ?*types.Node = null,
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
    // These answers only confirm prior downlink MAC requests. This server does not
    // persist pending request state yet, so there is nothing concrete to apply.
    const state = ctx.data(State);
    if (state.mode != .node_update) return;
}

pub fn applyToNode(allocator: std.mem.Allocator, node: *types.Node, incoming: []const commands.Command) !void {
    var ctx = context_mod.Context.init(allocator);
    defer ctx.deinit();

    var state = State{
        .mode = .node_update,
        .node = node,
    };
    ctx.setUserData(&state);

    try dispatchIgnoringMissing(&ctx, incoming);
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
    try applyToNode(std.testing.allocator, &node, &[_]commands.Command{
        .{ .link_adr_ans = .{ .power_ack = true, .data_rate_ack = true, .channel_mask_ack = true } },
        .{ .dev_status_ans = .{ .battery = 99, .margin = -2 } },
        .device_time_req,
    });

    try std.testing.expectEqual(@as(?u8, 99), node.last_battery);
    try std.testing.expectEqual(@as(?i8, -2), node.last_dev_status_margin);
}
