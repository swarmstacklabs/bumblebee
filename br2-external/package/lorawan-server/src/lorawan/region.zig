const std = @import("std");
const packets = @import("packets.zig");
const types = @import("types.zig");

pub const Region = enum {
    eu868,
    us902,
    us902_pr,
    cn779,
    eu433,
    au915,
    cn470,
    as923,
    kr920,
    in865,
    ru868,

    pub fn parse(text: []const u8) !Region {
        if (std.ascii.eqlIgnoreCase(text, "EU868")) return .eu868;
        if (std.ascii.eqlIgnoreCase(text, "US902")) return .us902;
        if (std.ascii.eqlIgnoreCase(text, "US902-PR")) return .us902_pr;
        if (std.ascii.eqlIgnoreCase(text, "CN779")) return .cn779;
        if (std.ascii.eqlIgnoreCase(text, "EU433")) return .eu433;
        if (std.ascii.eqlIgnoreCase(text, "AU915")) return .au915;
        if (std.ascii.eqlIgnoreCase(text, "CN470")) return .cn470;
        if (std.ascii.eqlIgnoreCase(text, "AS923")) return .as923;
        if (std.ascii.eqlIgnoreCase(text, "KR920")) return .kr920;
        if (std.ascii.eqlIgnoreCase(text, "IN865")) return .in865;
        if (std.ascii.eqlIgnoreCase(text, "RU868")) return .ru868;
        return error.UnsupportedRegion;
    }

    pub fn canonicalName(self: Region) []const u8 {
        return switch (self) {
            .eu868 => "EU868",
            .us902 => "US902",
            .us902_pr => "US902-PR",
            .cn779 => "CN779",
            .eu433 => "EU433",
            .au915 => "AU915",
            .cn470 => "CN470",
            .as923 => "AS923",
            .kr920 => "KR920",
            .in865 => "IN865",
            .ru868 => "RU868",
        };
    }

    pub fn defaultRxWindow(self: Region) types.RxWindowConfig {
        return switch (self) {
            .eu868 => .{ .rx1_dr_offset = 0, .rx2_data_rate = 0, .frequency = 869.525 },
            .us902, .us902_pr => .{ .rx1_dr_offset = 0, .rx2_data_rate = 8, .frequency = 923.3 },
            .cn779 => .{ .rx1_dr_offset = 0, .rx2_data_rate = 0, .frequency = 786.0 },
            .eu433 => .{ .rx1_dr_offset = 0, .rx2_data_rate = 0, .frequency = 434.665 },
            .au915 => .{ .rx1_dr_offset = 0, .rx2_data_rate = 8, .frequency = 923.3 },
            .cn470 => .{ .rx1_dr_offset = 0, .rx2_data_rate = 0, .frequency = 505.3 },
            .as923 => .{ .rx1_dr_offset = 0, .rx2_data_rate = 2, .frequency = 923.2 },
            .kr920 => .{ .rx1_dr_offset = 0, .rx2_data_rate = 0, .frequency = 921.9 },
            .in865 => .{ .rx1_dr_offset = 0, .rx2_data_rate = 2, .frequency = 866.55 },
            .ru868 => .{ .rx1_dr_offset = 0, .rx2_data_rate = 0, .frequency = 869.1 },
        };
    }

    pub fn supportsFrequencyCfList(self: Region) bool {
        return switch (self) {
            .eu868, .cn779, .eu433, .as923, .kr920, .in865, .ru868 => true,
            else => false,
        };
    }

    pub fn supportsSimpleChannelMask(self: Region) bool {
        return switch (self) {
            .eu868, .cn779, .eu433, .as923, .kr920, .in865, .ru868 => true,
            else => false,
        };
    }

    pub fn supportsNewChannelReq(self: Region) bool {
        return self.supportsFrequencyCfList();
    }

    pub fn supportsDlChannelReq(self: Region) bool {
        return switch (self) {
            .eu868, .cn779, .eu433, .as923, .ru868 => true,
            else => false,
        };
    }

    pub fn supportsTxParamSetup(self: Region) bool {
        return switch (self) {
            .as923 => true,
            else => false,
        };
    }

    pub fn defaultEnabledChannels(self: Region, allocator: std.mem.Allocator) ![]u8 {
        const len: usize = switch (self) {
            .eu868, .cn779, .eu433, .kr920, .in865 => 3,
            .ru868 => 2,
            .us902, .us902_pr, .au915 => 72,
            .cn470 => 96,
            .as923 => 2,
        };
        const out = try allocator.alloc(u8, len);
        for (out, 0..) |*value, index| value.* = @intCast(index);
        return out;
    }

    pub fn maxUplinkDataRate(self: Region) u8 {
        return switch (self) {
            .us902, .us902_pr => 4,
            .au915 => 6,
            else => 5,
        };
    }

    pub fn maxRx1DrOffset(self: Region) u8 {
        return switch (self) {
            .us902, .us902_pr => 3,
            else => 5,
        };
    }
};

pub fn uplinkDataRateIndex(region: Region, datr: packets.DataRate) !?u8 {
    return switch (datr) {
        .lora => |value| uplinkLoraDataRateIndex(region, value),
        .fsk => |value| switch (region) {
            .eu868, .cn779, .eu433, .as923, .ru868 => if (value == 50_000) 7 else null,
            else => null,
        },
    };
}

pub fn dataRateName(region: Region, data_rate: u8) ![]const u8 {
    return switch (region) {
        .us902, .us902_pr, .au915 => switch (data_rate) {
            0 => "SF10BW125",
            1 => "SF9BW125",
            2 => "SF8BW125",
            3 => "SF7BW125",
            4 => "SF8BW500",
            8 => "SF12BW500",
            9 => "SF11BW500",
            10 => "SF10BW500",
            11 => "SF9BW500",
            12 => "SF8BW500",
            13 => "SF7BW500",
            else => return error.UnsupportedDataRate,
        },
        .cn470, .kr920, .in865 => switch (data_rate) {
            0 => "SF12BW125",
            1 => "SF11BW125",
            2 => "SF10BW125",
            3 => "SF9BW125",
            4 => "SF8BW125",
            5 => "SF7BW125",
            else => return error.UnsupportedDataRate,
        },
        else => switch (data_rate) {
            0 => "SF12BW125",
            1 => "SF11BW125",
            2 => "SF10BW125",
            3 => "SF9BW125",
            4 => "SF8BW125",
            5 => "SF7BW125",
            6 => "SF7BW250",
            7 => "50000",
            else => return error.UnsupportedDataRate,
        },
    };
}

pub fn downlinkRx1DataRate(region: Region, allocator: std.mem.Allocator, uplink_datr: packets.DataRate, rx1_dr_offset: u8) !?packets.DataRate {
    const uplink_index = (try uplinkDataRateIndex(region, uplink_datr)) orelse return null;
    const downlink_index = try rx1DownlinkIndex(region, uplink_index, rx1_dr_offset);
    const name = try dataRateName(region, downlink_index);
    return if (std.mem.eql(u8, name, "50000"))
        .{ .fsk = 50_000 }
    else
        .{ .lora = try allocator.dupe(u8, name) };
}

pub fn rx2DataRate(region: Region, allocator: std.mem.Allocator, data_rate: u8) !packets.DataRate {
    const name = try dataRateName(region, data_rate);
    return if (std.mem.eql(u8, name, "50000"))
        .{ .fsk = 50_000 }
    else
        .{ .lora = try allocator.dupe(u8, name) };
}

pub fn rx1DownlinkFrequency(region: Region, uplink_freq_mhz: f64) ?f64 {
    return switch (region) {
        .us902 => rx1UsDownlinkFrequency(uplink_freq_mhz, false),
        .us902_pr => rx1UsDownlinkFrequency(uplink_freq_mhz, true),
        .au915 => rx1AuDownlinkFrequency(uplink_freq_mhz),
        .cn470 => rx1Cn470DownlinkFrequency(uplink_freq_mhz),
        else => uplink_freq_mhz,
    };
}

fn uplinkLoraDataRateIndex(region: Region, datr: []const u8) ?u8 {
    return switch (region) {
        .us902, .us902_pr => if (std.mem.eql(u8, datr, "SF10BW125")) 0 else if (std.mem.eql(u8, datr, "SF9BW125")) 1 else if (std.mem.eql(u8, datr, "SF8BW125")) 2 else if (std.mem.eql(u8, datr, "SF7BW125")) 3 else if (std.mem.eql(u8, datr, "SF8BW500")) 4 else null,
        .au915 => if (std.mem.eql(u8, datr, "SF12BW125")) 0 else if (std.mem.eql(u8, datr, "SF11BW125")) 1 else if (std.mem.eql(u8, datr, "SF10BW125")) 2 else if (std.mem.eql(u8, datr, "SF9BW125")) 3 else if (std.mem.eql(u8, datr, "SF8BW125")) 4 else if (std.mem.eql(u8, datr, "SF7BW125")) 5 else if (std.mem.eql(u8, datr, "SF8BW500")) 6 else null,
        .cn470, .kr920, .in865 => if (std.mem.eql(u8, datr, "SF12BW125")) 0 else if (std.mem.eql(u8, datr, "SF11BW125")) 1 else if (std.mem.eql(u8, datr, "SF10BW125")) 2 else if (std.mem.eql(u8, datr, "SF9BW125")) 3 else if (std.mem.eql(u8, datr, "SF8BW125")) 4 else if (std.mem.eql(u8, datr, "SF7BW125")) 5 else null,
        else => if (std.mem.eql(u8, datr, "SF12BW125")) 0 else if (std.mem.eql(u8, datr, "SF11BW125")) 1 else if (std.mem.eql(u8, datr, "SF10BW125")) 2 else if (std.mem.eql(u8, datr, "SF9BW125")) 3 else if (std.mem.eql(u8, datr, "SF8BW125")) 4 else if (std.mem.eql(u8, datr, "SF7BW125")) 5 else if (std.mem.eql(u8, datr, "SF7BW250")) 6 else null,
    };
}

fn rx1DownlinkIndex(region: Region, uplink_index: u8, rx1_dr_offset: u8) !u8 {
    return switch (region) {
        .as923 => blk: {
            const effective_offset = if (rx1_dr_offset > 5) 0 else rx1_dr_offset;
            const signed = @as(i16, uplink_index) - @as(i16, effective_offset);
            break :blk @intCast(std.math.clamp(signed, 0, 5));
        },
        .us902, .us902_pr => try selectMappedIndex(uplink_index, rx1_dr_offset, &[_][]const u8{
            &[_]u8{ 10, 9, 8, 8 },
            &[_]u8{ 11, 10, 9, 8 },
            &[_]u8{ 12, 11, 10, 9 },
            &[_]u8{ 13, 12, 11, 10 },
            &[_]u8{ 13, 13, 12, 11 },
        }),
        .au915 => try selectMappedIndex(uplink_index, rx1_dr_offset, &[_][]const u8{
            &[_]u8{ 8, 8, 8, 8, 8, 8 },
            &[_]u8{ 9, 8, 8, 8, 8, 8 },
            &[_]u8{ 10, 9, 8, 8, 8, 8 },
            &[_]u8{ 11, 10, 9, 8, 8, 8 },
            &[_]u8{ 12, 11, 10, 9, 8, 8 },
            &[_]u8{ 13, 12, 11, 10, 9, 8 },
            &[_]u8{ 13, 13, 12, 11, 10, 9 },
        }),
        else => blk: {
            const effective_offset = @min(rx1_dr_offset, 5);
            break :blk uplink_index -| effective_offset;
        },
    };
}

fn selectMappedIndex(uplink_index: u8, rx1_dr_offset: u8, mapping: []const []const u8) !u8 {
    if (uplink_index >= mapping.len) return error.UnsupportedDataRate;
    if (rx1_dr_offset >= mapping[uplink_index].len) return error.UnsupportedRx1Offset;
    return mapping[uplink_index][rx1_dr_offset];
}

fn rx1UsDownlinkFrequency(freq_mhz: f64, hybrid: bool) ?f64 {
    const channel = uplinkChannel(freq_mhz, 902.3, 0.2, 903.0, 1.6) orelse return null;
    const downlink_index: u32 = if (hybrid) channel / 8 else channel % 8;
    return 923.3 + 0.6 * @as(f64, @floatFromInt(downlink_index));
}

fn rx1AuDownlinkFrequency(freq_mhz: f64) ?f64 {
    const channel = uplinkChannel(freq_mhz, 915.2, 0.2, 915.9, 1.6) orelse return null;
    const downlink_index: u32 = channel % 8;
    return 923.3 + 0.6 * @as(f64, @floatFromInt(downlink_index));
}

fn rx1Cn470DownlinkFrequency(freq_mhz: f64) ?f64 {
    const rounded = @round((freq_mhz - 470.3) * 10.0);
    const scaled: i32 = @intFromFloat(rounded);
    if (scaled < 0 or @mod(scaled, 2) != 0) return null;
    const channel: u32 = @intCast(@divTrunc(scaled, 2));
    return 500.3 + 0.2 * @as(f64, @floatFromInt(channel % 48));
}

fn uplinkChannel(freq_mhz: f64, start_a: f64, step_a: f64, start_b: f64, step_b: f64) ?u32 {
    if (channelFromPlan(freq_mhz, start_a, step_a)) |value| return value;
    if (channelFromPlan(freq_mhz, start_b, step_b)) |value| return 64 + value;
    return null;
}

fn channelFromPlan(freq_mhz: f64, start: f64, step: f64) ?u32 {
    const rounded = @round((freq_mhz - start) / step);
    const channel: i32 = @intFromFloat(rounded);
    if (channel < 0) return null;
    const expected = start + step * @as(f64, @floatFromInt(channel));
    if (@abs(expected - freq_mhz) > 0.001) return null;
    return @intCast(channel);
}

test "region defaults use non-EU RX2 values where required" {
    try std.testing.expectEqual(@as(u8, 8), Region.us902.defaultRxWindow().rx2_data_rate);
    try std.testing.expectEqual(@as(f64, 923.3), Region.au915.defaultRxWindow().frequency);
    try std.testing.expectEqual(@as(u8, 2), Region.as923.defaultRxWindow().rx2_data_rate);
}

test "region rx1 downlink mapping follows US902 table" {
    const datr = try downlinkRx1DataRate(.us902, std.testing.allocator, .{ .lora = "SF8BW125" }, 1);
    defer switch (datr.?) {
        .lora => |value| std.testing.allocator.free(value),
        .fsk => {},
    };
    try std.testing.expectEqualStrings("SF9BW500", datr.?.lora);
}

test "region rx1 downlink frequency remaps AU915 uplinks" {
    try std.testing.expectEqual(@as(?f64, 923.9), rx1DownlinkFrequency(.au915, 915.4));
}
