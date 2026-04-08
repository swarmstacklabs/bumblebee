const std = @import("std");

pub const Command = union(enum) {
    link_check_req,
    link_adr_ans: struct { power_ack: bool, data_rate_ack: bool, channel_mask_ack: bool },
    duty_cycle_ans,
    rx_param_setup_ans: struct { rx1_dr_offset_ack: bool, rx2_data_rate_ack: bool, channel_ack: bool },
    dev_status_ans: struct { battery: u8, margin: i8 },
    new_channel_ans: struct { data_rate_range_ok: bool, channel_freq_ok: bool },
    rx_timing_setup_ans,
    tx_param_setup_ans,
    dl_channel_ans: struct { uplink_freq_exists: bool, channel_freq_ok: bool },
    device_time_req,

    link_check_ans: struct { margin: u8, gateway_count: u8 },
    link_adr_req: struct { data_rate: u8, tx_power: u8, channel_mask: u16, ch_mask_cntl: u8, nb_rep: u8 },
    duty_cycle_req: struct { max_dcycle: u8 },
    rx_param_setup_req: struct { rx1_dr_offset: u8, rx2_data_rate: u8, frequency_100hz: u32 },
    dev_status_req,
    new_channel_req: struct { channel_index: u8, frequency_100hz: u32, max_dr: u8, min_dr: u8 },
    rx_timing_setup_req: struct { delay: u8 },
    tx_param_setup_req: struct { downlink_dwell: bool, uplink_dwell: bool, max_eirp: u8 },
    dl_channel_req: struct { channel_index: u8, frequency_100hz: u32 },
    device_time_ans: struct { milliseconds_since_epoch: i64 },
};

pub fn parseFOpts(allocator: std.mem.Allocator, payload: []const u8) ![]Command {
    var out = std.ArrayList(Command){};
    errdefer out.deinit(allocator);

    var rest = payload;
    while (rest.len > 0) {
        switch (rest[0]) {
            0x02 => {
                try out.append(allocator, .link_check_req);
                rest = rest[1..];
            },
            0x03 => {
                if (rest.len < 2) return error.InvalidMacCommand;
                try out.append(allocator, .{ .link_adr_ans = .{
                    .power_ack = (rest[1] & 0b100) != 0,
                    .data_rate_ack = (rest[1] & 0b010) != 0,
                    .channel_mask_ack = (rest[1] & 0b001) != 0,
                } });
                rest = rest[2..];
            },
            0x04 => {
                try out.append(allocator, .duty_cycle_ans);
                rest = rest[1..];
            },
            0x05 => {
                if (rest.len < 2) return error.InvalidMacCommand;
                try out.append(allocator, .{ .rx_param_setup_ans = .{
                    .rx1_dr_offset_ack = (rest[1] & 0b100) != 0,
                    .rx2_data_rate_ack = (rest[1] & 0b010) != 0,
                    .channel_ack = (rest[1] & 0b001) != 0,
                } });
                rest = rest[2..];
            },
            0x06 => {
                if (rest.len < 3) return error.InvalidMacCommand;
                const margin_bits = rest[2] & 0x3F;
                try out.append(allocator, .{ .dev_status_ans = .{
                    .battery = rest[1],
                    .margin = if ((margin_bits & 0x20) != 0) @as(i8, @intCast(margin_bits)) - 64 else @as(i8, @intCast(margin_bits)),
                } });
                rest = rest[3..];
            },
            0x07 => {
                if (rest.len < 2) return error.InvalidMacCommand;
                try out.append(allocator, .{ .new_channel_ans = .{
                    .data_rate_range_ok = (rest[1] & 0b010) != 0,
                    .channel_freq_ok = (rest[1] & 0b001) != 0,
                } });
                rest = rest[2..];
            },
            0x08 => {
                try out.append(allocator, .rx_timing_setup_ans);
                rest = rest[1..];
            },
            0x09 => {
                try out.append(allocator, .tx_param_setup_ans);
                rest = rest[1..];
            },
            0x0A => {
                if (rest.len < 2) return error.InvalidMacCommand;
                try out.append(allocator, .{ .dl_channel_ans = .{
                    .uplink_freq_exists = (rest[1] & 0b010) != 0,
                    .channel_freq_ok = (rest[1] & 0b001) != 0,
                } });
                rest = rest[2..];
            },
            0x0D => {
                try out.append(allocator, .device_time_req);
                rest = rest[1..];
            },
            else => return error.UnknownMacCommand,
        }
    }

    return out.toOwnedSlice(allocator);
}

pub fn encodeFOpts(allocator: std.mem.Allocator, commands: []const Command) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    for (commands) |command| {
        switch (command) {
            .link_check_ans => |value| {
                try out.appendSlice(allocator, &[_]u8{ 0x02, value.margin, value.gateway_count });
            },
            .link_adr_req => |value| {
                try out.append(allocator, 0x03);
                try out.append(allocator, (value.data_rate << 4) | (value.tx_power & 0x0F));
                var mask_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, &mask_buf, value.channel_mask, .little);
                try out.appendSlice(allocator, &mask_buf);
                try out.append(allocator, ((value.ch_mask_cntl & 0x07) << 4) | (value.nb_rep & 0x0F));
            },
            .duty_cycle_req => |value| try out.appendSlice(allocator, &[_]u8{ 0x04, value.max_dcycle & 0x0F }),
            .rx_param_setup_req => |value| {
                try out.append(allocator, 0x05);
                try out.append(allocator, ((value.rx1_dr_offset & 0x07) << 4) | (value.rx2_data_rate & 0x0F));
                try appendU24Le(&out, allocator, value.frequency_100hz);
            },
            .dev_status_req => try out.append(allocator, 0x06),
            .new_channel_req => |value| {
                try out.appendSlice(allocator, &[_]u8{ 0x07, value.channel_index });
                try appendU24Le(&out, allocator, value.frequency_100hz);
                try out.append(allocator, (value.max_dr << 4) | (value.min_dr & 0x0F));
            },
            .rx_timing_setup_req => |value| try out.appendSlice(allocator, &[_]u8{ 0x08, value.delay & 0x0F }),
            .tx_param_setup_req => |value| try out.appendSlice(allocator, &[_]u8{
                0x09,
                (@as(u8, if (value.downlink_dwell) 1 else 0) << 5) |
                    (@as(u8, if (value.uplink_dwell) 1 else 0) << 4) |
                    (value.max_eirp & 0x0F),
            }),
            .dl_channel_req => |value| {
                try out.appendSlice(allocator, &[_]u8{ 0x0A, value.channel_index });
                try appendU24Le(&out, allocator, value.frequency_100hz);
            },
            .device_time_ans => |value| {
                try out.append(allocator, 0x0D);
                var seconds_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &seconds_buf, @intCast(@divTrunc(value.milliseconds_since_epoch, 1000)), .little);
                try out.appendSlice(allocator, &seconds_buf);
                const ms_rem: i64 = @mod(value.milliseconds_since_epoch, 1000);
                const fraction: u8 = @intCast(@divTrunc(ms_rem * 256, 1000));
                try out.append(allocator, fraction);
            },
            else => return error.UnsupportedOutgoingMacCommand,
        }
    }

    return out.toOwnedSlice(allocator);
}

fn appendU24Le(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    try out.appendSlice(allocator, &[_]u8{
        @intCast(value & 0xFF),
        @intCast((value >> 8) & 0xFF),
        @intCast((value >> 16) & 0xFF),
    });
}

test "mac commands parse and encode core set" {
    const allocator = std.testing.allocator;
    const parsed = try parseFOpts(allocator, &[_]u8{ 0x02, 0x06, 0xFF, 0b00111110, 0x0D });
    defer allocator.free(parsed);

    try std.testing.expect(parsed.len == 3);
    try std.testing.expect(parsed[0] == .link_check_req);
    try std.testing.expectEqual(@as(u8, 0xFF), parsed[1].dev_status_ans.battery);
    try std.testing.expect(parsed[2] == .device_time_req);

    const encoded = try encodeFOpts(allocator, &[_]Command{
        .{ .link_check_ans = .{ .margin = 10, .gateway_count = 2 } },
        .dev_status_req,
        .{ .rx_timing_setup_req = .{ .delay = 3 } },
    });
    defer allocator.free(encoded);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x02, 10, 2, 0x06, 0x08, 0x03 }, encoded);
}
