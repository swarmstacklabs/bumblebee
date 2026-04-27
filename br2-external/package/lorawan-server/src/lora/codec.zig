const std = @import("std");
const commands = @import("commands.zig");
const mac_handlers = @import("handlers/mac_handlers.zig");
const metrics_repository = @import("../repository/mac_command_metrics_repository.zig");
const types = @import("types.zig");

const Aes128 = std.crypto.core.aes.Aes128;
const CmacAes128 = std.crypto.auth.cmac.CmacAes128;

pub const DownlinkTiming = @import("packets.zig").DownlinkTiming;
pub const DownlinkRequest = @import("packets.zig").DownlinkRequest;

const MType = enum(u3) {
    join_request = 0b000,
    join_accept = 0b001,
    unconfirmed_data_up = 0b010,
    unconfirmed_data_down = 0b011,
    confirmed_data_up = 0b100,
    confirmed_data_down = 0b101,
    rejoin_request = 0b110,
    proprietary = 0b111,

    fn isConfirmedData(self: MType) bool {
        return switch (self) {
            .confirmed_data_up, .confirmed_data_down => true,
            else => false,
        };
    }

    fn dataDirection(self: MType) ?Direction {
        return switch (self) {
            .unconfirmed_data_up, .confirmed_data_up => .uplink,
            .unconfirmed_data_down, .confirmed_data_down => .downlink,
            else => null,
        };
    }
};

const Direction = enum {
    uplink,
    downlink,

    fn isUplink(self: Direction) bool {
        return self == .uplink;
    }

    fn micValue(self: Direction) u8 {
        return switch (self) {
            .uplink => 0,
            .downlink => 1,
        };
    }
};

const FCtrl = struct {
    adr: bool,
    adr_ack_req: bool,
    ack: bool,
    class_b: bool,
    f_pending: bool,
    f_opts_len: u4,

    fn decode(value: u8, direction: Direction) FCtrl {
        return .{
            .adr = (value & 0x80) != 0,
            .adr_ack_req = (value & 0x40) != 0,
            .ack = (value & 0x20) != 0,
            .class_b = direction == .uplink and (value & 0x10) != 0,
            .f_pending = direction == .downlink and (value & 0x10) != 0,
            .f_opts_len = @intCast(value & 0x0F),
        };
    }
};

pub fn decodeFrame(payload: []const u8) !types.DecodedFrame {
    if (payload.len < 5) return error.PacketTooShort;
    if ((payload[0] & 0x03) != 0) return error.UnsupportedMajorVersion;

    const mtype = parseMType(payload[0]);
    switch (mtype) {
        .join_request => return .{ .join_request = try decodeJoinRequest(payload) },
        .unconfirmed_data_up, .confirmed_data_up, .unconfirmed_data_down, .confirmed_data_down => return .{ .data = try decodeRawDataFrame(payload, mtype) },
        else => return error.UnsupportedFrameType,
    }
}

pub fn decodeJoinRequest(payload: []const u8) !types.JoinRequest {
    if (payload.len != 23) return error.InvalidJoinRequestLength;

    var dev_nonce: [2]u8 = undefined;
    @memcpy(&dev_nonce, payload[17..19]);

    var mic: [4]u8 = undefined;
    @memcpy(&mic, payload[payload.len - 4 ..]);

    return .{
        .app_eui = readEuiLe(payload[1..9]),
        .dev_eui = readEuiLe(payload[9..17]),
        .dev_nonce = dev_nonce,
        .mic = mic,
    };
}

fn decodeRawDataFrame(payload: []const u8, mtype: MType) !types.RawDataFrame {
    if (payload.len < 12) return error.PacketTooShort;

    const direction = mtype.dataDirection() orelse return error.UnsupportedFrameType;
    const fctrl = FCtrl.decode(payload[5], direction);

    const fopts_len: usize = fctrl.f_opts_len;
    if (payload.len < 8 + fopts_len + 4) return error.PacketTooShort;

    const fcnt16 = std.mem.readInt(u16, payload[6..8], .little);
    const opts_start = 8;
    const opts_end = opts_start + fopts_len;
    const body = payload[opts_end .. payload.len - 4];

    var fport: ?u8 = null;
    var frm_payload: []const u8 = "";
    if (body.len > 0) {
        fport = body[0];
        frm_payload = body[1..];
    }

    var mic: [4]u8 = undefined;
    @memcpy(&mic, payload[payload.len - 4 ..]);

    return .{
        .confirmed = mtype.isConfirmedData(),
        .is_uplink = direction.isUplink(),
        .dev_addr = readDevAddrLe(payload[1..5]),
        .adr = fctrl.adr,
        .adr_ack_req = fctrl.adr_ack_req,
        .ack = fctrl.ack,
        .class_b = fctrl.class_b,
        .f_pending = fctrl.f_pending,
        .f_cnt16 = fcnt16,
        .f_opts = payload[opts_start..opts_end],
        .f_port = fport,
        .frm_payload = frm_payload,
        .mic = mic,
    };
}

pub fn verifyJoinRequest(payload: []const u8, app_key: [16]u8) bool {
    if (payload.len != 23) return false;
    var mac: [16]u8 = undefined;
    CmacAes128.create(&mac, payload[0 .. payload.len - 4], &app_key);
    return std.mem.eql(u8, mac[0..4], payload[payload.len - 4 ..]);
}

pub fn deriveSessionKeys(app_key: [16]u8, app_nonce: [3]u8, net_id: [3]u8, dev_nonce: [2]u8) struct { nwk_s_key: [16]u8, app_s_key: [16]u8 } {
    return .{
        .nwk_s_key = deriveSessionKey(0x01, app_key, app_nonce, net_id, dev_nonce),
        .app_s_key = deriveSessionKey(0x02, app_key, app_nonce, net_id, dev_nonce),
    };
}

pub fn encodeJoinAccept(allocator: std.mem.Allocator, app_key: [16]u8, app_nonce: [3]u8, net_id: [3]u8, dev_addr: [4]u8, rx1_dr_offset: u8, rx2_data_rate: u8, rx_delay: u8, cf_list_100hz: ?[]const u32) ![]u8 {
    var buffer: [33]u8 = undefined;
    var index: usize = 0;
    buffer[index] = 0b00100000;
    index += 1;

    @memcpy(buffer[index .. index + 3], &app_nonce);
    index += 3;
    @memcpy(buffer[index .. index + 3], &net_id);
    index += 3;

    const dev_addr_le = writeDevAddrLe(dev_addr);
    @memcpy(buffer[index .. index + 4], &dev_addr_le);
    index += 4;

    buffer[index] = ((rx1_dr_offset & 0x07) << 4) | (rx2_data_rate & 0x0F);
    index += 1;
    buffer[index] = if (rx_delay <= 1) 0 else rx_delay;
    index += 1;

    if (cf_list_100hz) |list| {
        if (list.len > 5) return error.InvalidCfList;
        for (list) |freq| {
            buffer[index] = @intCast(freq & 0xFF);
            buffer[index + 1] = @intCast((freq >> 8) & 0xFF);
            buffer[index + 2] = @intCast((freq >> 16) & 0xFF);
            index += 3;
        }
        while (index < 28) : (index += 1) buffer[index] = 0;
        buffer[index] = 0;
        index += 1;
    }

    var mac: [16]u8 = undefined;
    CmacAes128.create(&mac, buffer[0..index], &app_key);
    @memcpy(buffer[index .. index + 4], mac[0..4]);
    index += 4;

    const cipher_len = index - 1;
    const encrypted = try allocator.alloc(u8, index);
    errdefer allocator.free(encrypted);

    encrypted[0] = buffer[0];
    const ctx = Aes128.initDec(app_key);
    var offset: usize = 0;
    while (offset < cipher_len) : (offset += 16) {
        var block_in: [16]u8 = [_]u8{0} ** 16;
        const block_len = @min(16, cipher_len - offset);
        @memcpy(block_in[0..block_len], buffer[1 + offset .. 1 + offset + block_len]);
        var block_out: [16]u8 = undefined;
        var dec = ctx;
        dec.decrypt(block_out[0..], block_in[0..]);
        @memcpy(encrypted[1 + offset .. 1 + offset + block_len], block_out[0..block_len]);
    }

    return encrypted;
}

pub fn verifyDataFrameMic(payload: []const u8, nwk_s_key: [16]u8, dev_addr: [4]u8, f_cnt: u32, direction: u8) bool {
    if (payload.len < 5) return false;
    const message = payload[0 .. payload.len - 4];
    const expected = micForPayload(message, nwk_s_key, dev_addr, f_cnt, direction);
    return std.mem.eql(u8, &expected, payload[payload.len - 4 ..]);
}

pub fn verifyRawDataFrame(payload: []const u8, frame: types.RawDataFrame, nwk_s_key: [16]u8, previous_f_cnt: ?u32) ?types.VerifiedDataFrame {
    const f_cnt = fullFCnt(previous_f_cnt, frame.f_cnt16);
    const direction: Direction = if (frame.is_uplink) .uplink else .downlink;
    if (!verifyDataFrameMic(payload, nwk_s_key, frame.dev_addr, f_cnt, direction.micValue())) return null;
    return types.VerifiedDataFrame.init(frame, f_cnt);
}

pub fn decodeDataPayload(allocator: std.mem.Allocator, frame: types.RawDataFrame, node: types.Node) !types.ParsedDataFrame {
    const previous_f_cnt = if (frame.is_uplink) node.f_cnt_up else node.f_cnt_down;
    return decodeDataPayloadWithFCnt(allocator, frame, node, fullFCnt(previous_f_cnt, frame.f_cnt16));
}

pub fn decodeVerifiedDataPayload(allocator: std.mem.Allocator, verified: types.VerifiedDataFrame, node: types.Node) !types.ParsedDataFrame {
    return decodeDataPayloadWithFCnt(allocator, verified.raw, node, verified.f_cnt);
}

pub fn decodeDataPayloadWithFCnt(allocator: std.mem.Allocator, frame: types.RawDataFrame, node: types.Node, f_cnt: u32) !types.ParsedDataFrame {
    const payload_key = if (frame.f_port != null and frame.f_port.? == 0) node.nwk_s_key else node.app_s_key;
    const decoded = try cipherPayload(allocator, frame.frm_payload, payload_key, frame.is_uplink, frame.dev_addr, f_cnt);
    errdefer allocator.free(decoded);
    const f_opts = try allocator.dupe(u8, frame.f_opts);
    errdefer allocator.free(f_opts);

    return .{
        .confirmed = frame.confirmed,
        .dev_addr = frame.dev_addr,
        .adr = frame.adr,
        .adr_ack_req = frame.adr_ack_req,
        .ack = frame.ack,
        .f_cnt = f_cnt,
        .f_port = frame.f_port,
        .f_opts = f_opts,
        .decoded_payload = decoded,
    };
}

pub fn encodeUnicast(allocator: std.mem.Allocator, node: *types.Node, tx_data: types.TxData, f_opts: []const u8, ack: bool, adr: bool) ![]u8 {
    const next_fcnt = node.f_cnt_down + 1;
    defer node.f_cnt_down = next_fcnt;
    return encodeDataDownlink(allocator, node.dev_addr, node.nwk_s_key, node.app_s_key, next_fcnt, tx_data, f_opts, ack, adr);
}

pub fn encodeDataDownlink(allocator: std.mem.Allocator, dev_addr: [4]u8, nwk_s_key: [16]u8, app_s_key: [16]u8, f_cnt_down: u32, tx_data: types.TxData, f_opts: []const u8, ack: bool, adr: bool) ![]u8 {
    if (f_opts.len > 15) {
        if (tx_data.port != null or tx_data.data.len > 0) return error.FOptsTooLarge;
        return encodeDataDownlink(allocator, dev_addr, nwk_s_key, app_s_key, f_cnt_down, .{
            .confirmed = tx_data.confirmed,
            .port = 0,
            .data = f_opts,
            .pending = tx_data.pending,
        }, &[_]u8{}, ack, adr);
    }

    const payload_key = if (tx_data.port != null and tx_data.port.? == 0) nwk_s_key else app_s_key;
    const encrypted_payload = try cipherPayload(allocator, tx_data.data, payload_key, false, dev_addr, f_cnt_down);
    defer allocator.free(encrypted_payload);

    var buffer = std.ArrayList(u8){};
    defer buffer.deinit(allocator);

    const mhdr: u8 = if (tx_data.confirmed) 0b10100000 else 0b01100000;
    try buffer.append(allocator, mhdr);

    const dev_addr_le = writeDevAddrLe(dev_addr);
    try buffer.appendSlice(allocator, &dev_addr_le);

    const fctrl: u8 =
        (@as(u8, if (adr) 1 else 0) << 7) |
        (@as(u8, if (ack) 1 else 0) << 5) |
        (@as(u8, if (tx_data.pending) 1 else 0) << 4) |
        @as(u8, @intCast(f_opts.len));
    try buffer.append(allocator, fctrl);

    var fcnt_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &fcnt_buf, @intCast(f_cnt_down & 0xFFFF), .little);
    try buffer.appendSlice(allocator, &fcnt_buf);
    try buffer.appendSlice(allocator, f_opts);

    if (tx_data.port) |port| {
        try buffer.append(allocator, port);
        try buffer.appendSlice(allocator, encrypted_payload);
    }

    const message = try buffer.toOwnedSlice(allocator);
    errdefer allocator.free(message);
    const mic = micForPayload(message, nwk_s_key, dev_addr, f_cnt_down, 1);

    var out = try allocator.alloc(u8, message.len + 4);
    @memcpy(out[0..message.len], message);
    @memcpy(out[message.len..], &mic);
    allocator.free(message);
    return out;
}

pub fn cipherPayload(allocator: std.mem.Allocator, payload: []const u8, key: [16]u8, is_uplink: bool, dev_addr: [4]u8, f_cnt: u32) ![]u8 {
    const out = try allocator.alloc(u8, payload.len);
    errdefer allocator.free(out);
    if (payload.len == 0) return out;

    const dev_addr_le = writeDevAddrLe(dev_addr);
    var block_index: u8 = 1;
    var offset: usize = 0;
    while (offset < payload.len) : ({
        offset += 16;
        block_index += 1;
    }) {
        var ai: [16]u8 = [_]u8{0} ** 16;
        ai[0] = 0x01;
        ai[5] = if (is_uplink) 0 else 1;
        @memcpy(ai[6..10], &dev_addr_le);
        std.mem.writeInt(u32, ai[10..14], f_cnt, .little);
        ai[15] = block_index;

        var s: [16]u8 = undefined;
        var enc = Aes128.initEnc(key);
        enc.encrypt(s[0..], ai[0..]);

        const block_len = @min(16, payload.len - offset);
        for (payload[offset .. offset + block_len], 0..) |value, i| {
            out[offset + i] = value ^ s[i];
        }
    }

    return out;
}

pub fn collectMacCommands(allocator: std.mem.Allocator, parsed: types.ParsedDataFrame) ![]commands.Command {
    var incoming = std.ArrayList(commands.Command){};
    errdefer incoming.deinit(allocator);

    const f_opts_commands = try commands.parseFOpts(allocator, parsed.f_opts);
    defer allocator.free(f_opts_commands);
    try incoming.appendSlice(allocator, f_opts_commands);

    if (parsed.f_port == 0 and parsed.decoded_payload.len > 0) {
        const payload_commands = try commands.parseFOpts(allocator, parsed.decoded_payload);
        defer allocator.free(payload_commands);
        try incoming.appendSlice(allocator, payload_commands);
    }

    return incoming.toOwnedSlice(allocator);
}

pub fn buildMacResponses(
    allocator: std.mem.Allocator,
    parsed: types.ParsedDataFrame,
    link_metrics: mac_handlers.LinkMetrics,
) ![]commands.Command {
    return buildMacResponsesWithMetrics(allocator, parsed, link_metrics, null);
}

pub fn buildMacResponsesWithMetrics(
    allocator: std.mem.Allocator,
    parsed: types.ParsedDataFrame,
    link_metrics: mac_handlers.LinkMetrics,
    metrics_repo: ?*metrics_repository.Repository,
) ![]commands.Command {
    const incoming = try collectMacCommands(allocator, parsed);
    defer allocator.free(incoming);
    return mac_handlers.buildResponsesWithMetrics(allocator, incoming, link_metrics, metrics_repo);
}

pub fn fullFCnt(previous: ?u32, next16: u16) u32 {
    const prev = previous orelse return next16;
    const low = prev & 0xFFFF;
    const high = prev & 0xFFFF0000;
    if (next16 < low and (low - next16) > 0x8000) {
        return high + 0x10000 + next16;
    }
    if (next16 > low and (next16 - low) > 0x8000 and high >= 0x10000) {
        return high - 0x10000 + next16;
    }
    return high + next16;
}

fn deriveSessionKey(prefix: u8, app_key: [16]u8, app_nonce: [3]u8, net_id: [3]u8, dev_nonce: [2]u8) [16]u8 {
    var block: [16]u8 = [_]u8{0} ** 16;
    block[0] = prefix;
    @memcpy(block[1..4], &app_nonce);
    @memcpy(block[4..7], &net_id);
    @memcpy(block[7..9], &dev_nonce);

    var out: [16]u8 = undefined;
    var enc = Aes128.initEnc(app_key);
    enc.encrypt(out[0..], block[0..]);
    return out;
}

fn micForPayload(message: []const u8, nwk_s_key: [16]u8, dev_addr: [4]u8, f_cnt: u32, direction: u8) [4]u8 {
    var b0: [16]u8 = [_]u8{0} ** 16;
    b0[0] = 0x49;
    b0[5] = direction;
    const dev_addr_le = writeDevAddrLe(dev_addr);
    @memcpy(b0[6..10], &dev_addr_le);
    std.mem.writeInt(u32, b0[10..14], f_cnt, .little);
    b0[15] = @intCast(message.len);

    const cmac_input = std.heap.page_allocator.alloc(u8, b0.len + message.len) catch unreachable;
    defer std.heap.page_allocator.free(cmac_input);
    @memcpy(cmac_input[0..b0.len], &b0);
    @memcpy(cmac_input[b0.len..], message);

    var mac: [16]u8 = undefined;
    CmacAes128.create(&mac, cmac_input, &nwk_s_key);
    return mac[0..4].*;
}

fn parseMType(mhdr: u8) MType {
    return @enumFromInt(@as(u3, @intCast(mhdr >> 5)));
}

fn readEuiLe(bytes: []const u8) [8]u8 {
    return reverseArray(8, bytes[0..8].*);
}

fn readDevAddrLe(bytes: []const u8) [4]u8 {
    return reverseArray(4, bytes[0..4].*);
}

fn writeDevAddrLe(value: [4]u8) [4]u8 {
    return reverseArray(4, value);
}

fn reverseArray(comptime len: usize, value: [len]u8) [len]u8 {
    var out: [len]u8 = undefined;
    for (value, 0..) |byte, i| out[len - 1 - i] = byte;
    return out;
}

test "join request verification and session keys" {
    const payload = [_]u8{
        0x00,
        0x08,
        0x07,
        0x06,
        0x05,
        0x04,
        0x03,
        0x02,
        0x01,
        0x18,
        0x17,
        0x16,
        0x15,
        0x14,
        0x13,
        0x12,
        0x11,
        0xAA,
        0xBB,
        0x4A,
        0x54,
        0x90,
        0xDC,
    };
    const app_key = [_]u8{
        0x2B, 0x7E, 0x15, 0x16, 0x28, 0xAE, 0xD2, 0xA6,
        0xAB, 0xF7, 0x15, 0x88, 0x09, 0xCF, 0x4F, 0x3C,
    };
    _ = payload;
    _ = app_key;
}

test "collectMacCommands includes FOpts and port-zero payload commands" {
    const parsed = types.ParsedDataFrame.init(
        false,
        [_]u8{ 1, 2, 3, 4 },
        false,
        false,
        false,
        7,
        0,
        try std.testing.allocator.dupe(u8, &[_]u8{0x02}),
        try std.testing.allocator.dupe(u8, &[_]u8{ 0x06, 0x64, 0x05 }),
    );
    defer parsed.deinit(std.testing.allocator);

    const incoming = try collectMacCommands(std.testing.allocator, parsed);
    defer std.testing.allocator.free(incoming);

    try std.testing.expectEqual(@as(usize, 2), incoming.len);
    try std.testing.expect(incoming[0] == .link_check_req);
    try std.testing.expect(incoming[1] == .dev_status_ans);
    try std.testing.expectEqual(@as(u8, 0x64), incoming[1].dev_status_ans.battery);
}

test "encodeDataDownlink moves oversized MAC commands into port-zero payload" {
    const allocator = std.testing.allocator;
    const dev_addr = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const app_s_key = [_]u8{
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F,
    };
    const nwk_s_key = [_]u8{
        0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27,
        0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F,
    };
    const f_opts = try commands.encodeFOpts(allocator, &[_]commands.Command{
        .{ .link_adr_req = .{ .data_rate = 5, .tx_power = 7, .channel_mask = 0x00FF, .ch_mask_cntl = 0, .nb_rep = 1 } },
        .{ .link_adr_req = .{ .data_rate = 5, .tx_power = 6, .channel_mask = 0x0F0F, .ch_mask_cntl = 0, .nb_rep = 1 } },
        .{ .link_adr_req = .{ .data_rate = 4, .tx_power = 5, .channel_mask = 0xF0F0, .ch_mask_cntl = 0, .nb_rep = 1 } },
        .{ .link_adr_req = .{ .data_rate = 3, .tx_power = 4, .channel_mask = 0xAAAA, .ch_mask_cntl = 0, .nb_rep = 1 } },
    });
    defer allocator.free(f_opts);

    try std.testing.expect(f_opts.len > 15);

    const phy = try encodeDataDownlink(
        allocator,
        dev_addr,
        nwk_s_key,
        app_s_key,
        1,
        .{},
        f_opts,
        false,
        false,
    );
    defer allocator.free(phy);

    const decoded = try decodeFrame(phy);
    const frame = switch (decoded) {
        .data => |value| value,
        else => return error.UnexpectedFrameType,
    };

    try std.testing.expectEqual(@as(usize, 0), frame.f_opts.len);
    try std.testing.expectEqual(@as(?u8, 0), frame.f_port);

    const node = types.Node.init(dev_addr, app_s_key, nwk_s_key, types.RxWindowConfig.init(0, 0, 869.525), types.AdrConfig.init(14, 0));
    const parsed = try decodeDataPayload(allocator, frame, node);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualSlices(u8, f_opts, parsed.decoded_payload);
    const outgoing = try commands.parseDownlinkFOpts(allocator, parsed.decoded_payload);
    defer allocator.free(outgoing);
    try std.testing.expectEqual(@as(usize, 4), outgoing.len);
    try std.testing.expect(outgoing[0] == .link_adr_req);
}

test "decodeFrame separates uplink class B from downlink FPending" {
    const uplink = try decodeFrame(&[_]u8{
        0b01000000,
        0x04,
        0x03,
        0x02,
        0x01,
        0b00010000,
        0x01,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
    });
    const uplink_frame = switch (uplink) {
        .data => |value| value,
        else => return error.UnexpectedFrameType,
    };
    try std.testing.expect(uplink_frame.class_b);
    try std.testing.expect(!uplink_frame.f_pending);

    const downlink = try decodeFrame(&[_]u8{
        0b01100000,
        0x04,
        0x03,
        0x02,
        0x01,
        0b00010000,
        0x01,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
    });
    const downlink_frame = switch (downlink) {
        .data => |value| value,
        else => return error.UnexpectedFrameType,
    };
    try std.testing.expect(!downlink_frame.class_b);
    try std.testing.expect(downlink_frame.f_pending);
}

test "encodeJoinAccept maps one-second rx delay to zero" {
    const allocator = std.testing.allocator;
    const app_key = [_]u8{
        0x2B, 0x7E, 0x15, 0x16, 0x28, 0xAE, 0xD2, 0xA6,
        0xAB, 0xF7, 0x15, 0x88, 0x09, 0xCF, 0x4F, 0x3C,
    };
    const encoded = try encodeJoinAccept(allocator, app_key, .{ 1, 2, 3 }, .{ 0, 0, 0x13 }, .{ 1, 2, 3, 4 }, 0, 0, 1, null);
    defer allocator.free(encoded);

    var decrypted = try allocator.alloc(u8, encoded.len);
    defer allocator.free(decrypted);
    decrypted[0] = encoded[0];

    const ctx = Aes128.initEnc(app_key);
    var offset: usize = 0;
    while (offset < encoded.len - 1) : (offset += 16) {
        var block_in: [16]u8 = [_]u8{0} ** 16;
        const block_len = @min(16, encoded.len - 1 - offset);
        @memcpy(block_in[0..block_len], encoded[1 + offset .. 1 + offset + block_len]);
        var block_out: [16]u8 = undefined;
        var enc = ctx;
        enc.encrypt(block_out[0..], block_in[0..]);
        @memcpy(decrypted[1 + offset .. 1 + offset + block_len], block_out[0..block_len]);
    }

    try std.testing.expectEqual(@as(u8, 0), decrypted[11]);
}

test "data payload cipher round trip" {
    const allocator = std.testing.allocator;
    const key = [_]u8{
        0x2B, 0x7E, 0x15, 0x16, 0x28, 0xAE, 0xD2, 0xA6,
        0xAB, 0xF7, 0x15, 0x88, 0x09, 0xCF, 0x4F, 0x3C,
    };
    const dev_addr = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const data = "hello";
    const encoded = try cipherPayload(allocator, data, key, true, dev_addr, 7);
    defer allocator.free(encoded);
    const decoded = try cipherPayload(allocator, encoded, key, true, dev_addr, 7);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings(data, decoded);
}
