const std = @import("std");

const commands = @import("../commands.zig");
const context_mod = @import("../context.zig");
const runtime = @import("../runtime.zig");

pub fn middleware(ctx: *context_mod.Context, exec: *runtime.Executor) runtime.AppError!void {
    const command = try ctx.currentCommand();
    try validateCommand(command);
    return exec.next(ctx);
}

fn validateCommand(command: commands.Command) !void {
    switch (command) {
        .link_check_req,
        .duty_cycle_ans,
        .rx_timing_setup_ans,
        .tx_param_setup_ans,
        .device_time_req,
        .dev_status_req,
        => {},

        .link_adr_ans,
        .rx_param_setup_ans,
        .new_channel_ans,
        .dl_channel_ans,
        .link_check_ans,
        .device_time_ans,
        => {},

        .dev_status_ans => |value| {
            if (value.margin < -32 or value.margin > 31) return error.MalformedMacCommandPayload;
        },

        .link_adr_req => |value| {
            if (value.data_rate > 15) return error.MalformedMacCommandPayload;
            if (value.tx_power > 15) return error.MalformedMacCommandPayload;
            if (value.ch_mask_cntl > 7) return error.MalformedMacCommandPayload;
            if (value.ch_mask_cntl >= 6) return error.UnsupportedMacCommandPayload;
            if (value.nb_rep > 15) return error.MalformedMacCommandPayload;
        },

        .duty_cycle_req => |value| {
            if (value.max_dcycle > 15) return error.MalformedMacCommandPayload;
        },

        .rx_param_setup_req => |value| {
            if (value.rx1_dr_offset > 7) return error.MalformedMacCommandPayload;
            if (value.rx1_dr_offset > 5) return error.UnsupportedMacCommandPayload;
            if (value.rx2_data_rate > 15) return error.MalformedMacCommandPayload;
            if (value.frequency_100hz == 0 or value.frequency_100hz > 0x00FF_FFFF) return error.MalformedMacCommandPayload;
        },

        .new_channel_req => |value| {
            if (value.channel_index > 15) return error.UnsupportedMacCommandPayload;
            if (value.frequency_100hz > 0x00FF_FFFF) return error.MalformedMacCommandPayload;
            if (value.max_dr > 15 or value.min_dr > 15) return error.MalformedMacCommandPayload;
            if (value.max_dr < value.min_dr) return error.MalformedMacCommandPayload;
        },

        .rx_timing_setup_req => |value| {
            if (value.delay > 15) return error.MalformedMacCommandPayload;
        },

        .tx_param_setup_req => |value| {
            if (value.max_eirp > 15) return error.MalformedMacCommandPayload;
        },

        .dl_channel_req => |value| {
            if (value.channel_index > 15) return error.UnsupportedMacCommandPayload;
            if (value.frequency_100hz > 0x00FF_FFFF) return error.MalformedMacCommandPayload;
        },
    }
}

test "validator rejects out-of-range dev status margin" {
    try std.testing.expectError(
        error.MalformedMacCommandPayload,
        validateCommand(.{ .dev_status_ans = .{ .battery = 255, .margin = 32 } }),
    );
}

test "validator rejects unsupported link adr channel mask control" {
    try std.testing.expectError(
        error.UnsupportedMacCommandPayload,
        validateCommand(.{ .link_adr_req = .{
            .data_rate = 5,
            .tx_power = 3,
            .channel_mask = 0x00FF,
            .ch_mask_cntl = 6,
            .nb_rep = 1,
        } }),
    );
}

test "validator accepts well-formed command payloads" {
    try validateCommand(.{ .dev_status_ans = .{ .battery = 99, .margin = -5 } });
    try validateCommand(.{ .new_channel_req = .{
        .channel_index = 3,
        .frequency_100hz = 8671000,
        .max_dr = 5,
        .min_dr = 0,
    } });
}
