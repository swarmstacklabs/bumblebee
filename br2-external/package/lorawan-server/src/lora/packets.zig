const std = @import("std");
const packet_bytes = @import("../packets.zig");

pub const semtech_version = 1;
pub const push_data_ident = 0;
pub const push_ack_ident = 1;
pub const pull_data_ident = 2;
pub const pull_resp_ident = 3;
pub const pull_ack_ident = 4;
pub const tx_ack_ident = 5;

pub const DataRate = union(enum) {
    lora: []const u8,
    fsk: u32,

    pub fn jsonStringify(self: DataRate, jw: anytype) !void {
        switch (self) {
            .lora => |value| try jw.write(value),
            .fsk => |value| try jw.write(value),
        }
    }
};

pub const Rxpk = struct {
    tmst: u64,
    freq: f64,
    datr: DataRate,
    codr: []const u8,
    data: []u8,
    time: ?[]const u8,
    tmms: ?i64,
    rssi: ?f64,
    lsnr: ?f64,

    pub fn deinit(self: Rxpk, allocator: std.mem.Allocator) void {
        switch (self.datr) {
            .lora => |value| allocator.free(value),
            .fsk => {},
        }
        allocator.free(self.codr);
        allocator.free(self.data);
        if (self.time) |value| allocator.free(value);
    }
};

pub const GatewayStat = struct {
    json: []u8,

    pub fn deinit(self: GatewayStat, allocator: std.mem.Allocator) void {
        allocator.free(self.json);
    }
};

pub const PushDataFrame = struct {
    version: u8,
    token: u16,
    gateway_mac: [8]u8,
    rxpk: std.ArrayList(Rxpk),
    stat: ?GatewayStat,

    pub fn deinit(self: *PushDataFrame, allocator: std.mem.Allocator) void {
        for (self.rxpk.items) |item| item.deinit(allocator);
        self.rxpk.deinit(allocator);
        if (self.stat) |value| value.deinit(allocator);
    }
};

pub const PullDataFrame = struct {
    version: u8,
    token: u16,
    gateway_mac: [8]u8,
};

pub const TxAckFrame = struct {
    version: u8,
    token: u16,
    gateway_mac: [8]u8,
    error_name: ?[]u8,

    pub fn deinit(self: TxAckFrame, allocator: std.mem.Allocator) void {
        if (self.error_name) |value| allocator.free(value);
    }
};

pub const DecodedFrame = union(enum) {
    push_data: PushDataFrame,
    pull_data: PullDataFrame,
    tx_ack: TxAckFrame,
    unsupported: struct {
        version: u8,
        token: u16,
        ident: u8,
        gateway_mac: ?[8]u8,
    },

    pub fn deinit(self: *DecodedFrame, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .push_data => |*frame| frame.deinit(allocator),
            .tx_ack => |frame| frame.deinit(allocator),
            else => {},
        }
    }
};

pub const DownlinkTiming = union(enum) {
    class_a_delay_s: u32,
    immediately,
    absolute_time: []const u8,
};

pub const DownlinkRequest = struct {
    gateway_mac: [8]u8,
    dev_addr: ?[]const u8,
    gateway_tmst: ?u64,
    rfch: u8,
    freq: f64,
    powe: i32,
    datr: DataRate,
    codr: []const u8,
    timing: DownlinkTiming,
    phy_payload: []const u8,
};

pub fn decodeFrame(allocator: std.mem.Allocator, msg: []const u8) !DecodedFrame {
    if (msg.len < 4) return error.PacketTooShort;

    const version = msg[0];
    const token = packet_bytes.readBE16(msg[1..3]);
    const ident = msg[3];

    switch (ident) {
        push_data_ident => {
            if (msg.len < 12) return error.PacketTooShort;
            var parsed = try parsePushPayload(allocator, msg[4..]);
            parsed.version = version;
            parsed.token = token;
            return .{ .push_data = parsed };
        },
        pull_data_ident => {
            if (msg.len < 12) return error.PacketTooShort;
            return .{ .pull_data = .{
                .version = version,
                .token = token,
                .gateway_mac = parseGatewayMac(msg[4..12].*),
            } };
        },
        tx_ack_ident => {
            if (msg.len < 12) return error.PacketTooShort;
            return .{ .tx_ack = try parseTxAckPayload(allocator, version, token, msg[4..]) };
        },
        else => return .{ .unsupported = .{
            .version = version,
            .token = token,
            .ident = ident,
            .gateway_mac = if (msg.len >= 12) parseGatewayMac(msg[4..12].*) else null,
        } },
    }
}

pub fn buildPullRespJson(allocator: std.mem.Allocator, req: DownlinkRequest) ![]u8 {
    const TimingFields = struct {
        imme: bool,
        tmst: ?u64,
        time: ?[]const u8,
    };

    const timing: TimingFields = switch (req.timing) {
        .class_a_delay_s => |seconds| .{
            .imme = false,
            .tmst = (req.gateway_tmst orelse return error.MissingGatewayTimestamp) + @as(u64, seconds) * 1_000_000,
            .time = @as(?[]const u8, null),
        },
        .immediately => .{
            .imme = true,
            .tmst = @as(?u64, null),
            .time = @as(?[]const u8, null),
        },
        .absolute_time => |stamp| .{
            .imme = false,
            .tmst = @as(?u64, null),
            .time = stamp,
        },
    };

    const data_b64 = try encodeBase64(allocator, req.phy_payload);
    defer allocator.free(data_b64);

    const payload = .{
        .txpk = .{
            .imme = timing.imme,
            .tmst = timing.tmst,
            .time = timing.time,
            .freq = req.freq,
            .rfch = req.rfch,
            .powe = req.powe,
            .modu = switch (req.datr) {
                .lora => "LORA",
                .fsk => "FSK",
            },
            .datr = req.datr,
            .codr = req.codr,
            .ipol = true,
            .size = req.phy_payload.len,
            .data = data_b64,
        },
    };

    return std.json.Stringify.valueAlloc(allocator, payload, .{});
}

pub fn encodePullResp(allocator: std.mem.Allocator, version: u8, token: u16, json_payload: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, 4 + json_payload.len);
    out[0] = version;
    packet_bytes.writeBE16(out[1..3], token);
    out[3] = pull_resp_ident;
    @memcpy(out[4..], json_payload);
    return out;
}

pub fn encodeAck(allocator: std.mem.Allocator, version: u8, token: u16, ident: u8) ![]u8 {
    var out = try allocator.alloc(u8, 4);
    out[0] = version;
    packet_bytes.writeBE16(out[1..3], token);
    out[3] = ident;
    return out;
}

pub fn encodeNormalizedRxpk(allocator: std.mem.Allocator, gateway_mac: [8]u8, rxpk: Rxpk) ![]u8 {
    const data_b64 = try encodeBase64(allocator, rxpk.data);
    defer allocator.free(data_b64);

    return std.json.Stringify.valueAlloc(allocator, .{
        .gateway_mac = gatewayMacHex(gateway_mac),
        .tmst = rxpk.tmst,
        .freq = rxpk.freq,
        .datr = rxpk.datr,
        .codr = rxpk.codr,
        .data = data_b64,
        .time = rxpk.time,
        .tmms = rxpk.tmms,
        .rssi = rxpk.rssi,
        .lsnr = rxpk.lsnr,
    }, .{});
}

pub fn encodeTxAckEvent(allocator: std.mem.Allocator, gateway_mac: [8]u8, token: u16, delay_ms: i64, dev_addr: ?[]const u8, error_name: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .gateway_mac = gatewayMacHex(gateway_mac),
        .token = token,
        .delay_ms = delay_ms,
        .dev_addr = dev_addr,
        .@"error" = error_name,
    }, .{});
}

pub fn parseGatewayMac(bytes: [8]u8) [8]u8 {
    return bytes;
}

pub fn gatewayMacHex(mac: [8]u8) [16]u8 {
    var out: [16]u8 = undefined;
    const charset = "0123456789abcdef";
    for (mac, 0..) |byte, index| {
        out[index * 2] = charset[byte >> 4];
        out[index * 2 + 1] = charset[byte & 0x0F];
    }
    return out;
}

pub fn trimJson(data: []const u8) []const u8 {
    var index: usize = 0;
    while (index < data.len) : (index += 1) {
        switch (data[index]) {
            0, ' ', '\t' => {},
            else => return data[index..],
        }
    }
    return data[data.len..];
}

fn parsePushPayload(allocator: std.mem.Allocator, payload: []const u8) !PushDataFrame {
    if (payload.len < 8) return error.PacketTooShort;

    const gateway_mac = parseGatewayMac(payload[0..8].*);
    const json_payload = payload[8..];
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const root = parsed.value.object;
    var rxpks = std.ArrayList(Rxpk){};
    errdefer {
        for (rxpks.items) |item| item.deinit(allocator);
        rxpks.deinit(allocator);
    }

    if (root.get("rxpk")) |value| {
        switch (value) {
            .array => |array| {
                for (array.items) |item| {
                    try rxpks.append(allocator, try parseRxpk(allocator, item));
                }
            },
            else => return error.InvalidRxpk,
        }
    }

    var stat: ?GatewayStat = null;
    if (root.get("stat")) |value| {
        stat = GatewayStat{ .json = try std.json.Stringify.valueAlloc(allocator, value, .{}) };
    }

    return .{
        .version = 0,
        .token = 0,
        .gateway_mac = gateway_mac,
        .rxpk = rxpks,
        .stat = stat,
    };
}

fn parseTxAckPayload(allocator: std.mem.Allocator, version: u8, token: u16, payload: []const u8) !TxAckFrame {
    if (payload.len < 8) return error.PacketTooShort;

    const gateway_mac = parseGatewayMac(payload[0..8].*);
    const trimmed = trimJson(payload[8..]);
    if (trimmed.len == 0) {
        return .{
            .version = version,
            .token = token,
            .gateway_mac = gateway_mac,
            .error_name = null,
        };
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var error_name: ?[]u8 = null;
    if (parsed.value.object.get("txpk_ack")) |ack_value| {
        if (ack_value == .object) {
            if (ack_value.object.get("error")) |error_value| {
                if (error_value == .string) {
                    error_name = try allocator.dupe(u8, error_value.string);
                }
            }
        }
    }

    return .{
        .version = version,
        .token = token,
        .gateway_mac = gateway_mac,
        .error_name = error_name,
    };
}

fn parseRxpk(allocator: std.mem.Allocator, value: std.json.Value) !Rxpk {
    if (value != .object) return error.InvalidRxpk;
    const object = value.object;

    const tmst = try jsonRequiredInteger(object, "tmst");
    const freq = try jsonRequiredFloat(object, "freq");
    const datr = try jsonRequiredDataRate(allocator, object, "datr");
    const codr = try jsonRequiredString(allocator, object, "codr");
    const data_b64 = try jsonRequiredString(allocator, object, "data");
    defer allocator.free(data_b64);

    const data = try decodeBase64(allocator, data_b64);
    errdefer allocator.free(data);

    const best_signal = findBestSignal(object.get("rsig"));
    const rssi = jsonOptionalFloat(object, "rssi") orelse if (best_signal) |signal| signal.rssi else null;
    const lsnr = jsonOptionalFloat(object, "lsnr") orelse if (best_signal) |signal| signal.lsnr else null;

    return .{
        .tmst = @intCast(tmst),
        .freq = freq,
        .datr = datr,
        .codr = codr,
        .data = data,
        .time = try jsonOptionalString(allocator, object, "time"),
        .tmms = jsonOptionalInteger(object, "tmms"),
        .rssi = rssi,
        .lsnr = lsnr,
    };
}

fn jsonRequiredInteger(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.MissingJsonField;
    return switch (value) {
        .integer => |num| num,
        else => error.InvalidJsonField,
    };
}

fn jsonOptionalInteger(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |num| num,
        .null => null,
        else => null,
    };
}

fn jsonRequiredFloat(object: std.json.ObjectMap, key: []const u8) !f64 {
    const value = object.get(key) orelse return error.MissingJsonField;
    return switch (value) {
        .float => |num| num,
        .integer => |num| @floatFromInt(num),
        else => error.InvalidJsonField,
    };
}

fn jsonOptionalFloat(object: std.json.ObjectMap, key: []const u8) ?f64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .float => |num| num,
        .integer => |num| @floatFromInt(num),
        .null => null,
        else => null,
    };
}

fn jsonRequiredString(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return error.MissingJsonField;
    return switch (value) {
        .string => |text| allocator.dupe(u8, text),
        else => error.InvalidJsonField,
    };
}

fn jsonOptionalString(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| try allocator.dupe(u8, text),
        .null => null,
        else => null,
    };
}

fn jsonRequiredDataRate(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) !DataRate {
    const value = object.get(key) orelse return error.MissingJsonField;
    return switch (value) {
        .string => |text| .{ .lora = try allocator.dupe(u8, text) },
        .integer => |num| .{ .fsk = @intCast(num) },
        else => error.InvalidJsonField,
    };
}

const Signal = struct {
    rssi: ?f64,
    lsnr: ?f64,
};

fn findBestSignal(value: ?std.json.Value) ?Signal {
    const rsig = value orelse return null;
    if (rsig != .array) return null;

    var best: ?Signal = null;
    for (rsig.array.items) |item| {
        if (item != .object) continue;
        const rssi = jsonOptionalFloat(item.object, "rssic");
        const lsnr = jsonOptionalFloat(item.object, "lsnr");
        if (rssi == null and lsnr == null) continue;

        if (best) |current| {
            if ((rssi orelse -std.math.inf(f64)) > (current.rssi orelse -std.math.inf(f64))) {
                best = .{ .rssi = rssi, .lsnr = lsnr };
            }
        } else {
            best = .{ .rssi = rssi, .lsnr = lsnr };
        }
    }
    return best;
}

fn decodeBase64(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(text);
    const out = try allocator.alloc(u8, size);
    errdefer allocator.free(out);
    try decoder.decode(out, text);
    return out;
}

fn encodeBase64(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const size = encoder.calcSize(bytes.len);
    const out = try allocator.alloc(u8, size);
    _ = encoder.encode(out, bytes);
    return out;
}

test "decode push data picks best rsig rssi and decodes payload" {
    const allocator = std.testing.allocator;
    const payload =
        \\{"rxpk":[{"tmst":42,"freq":868.1,"datr":"SF12BW125","codr":"4/5","data":"AQID","rssi":-70,"rsig":[{"rssic":-40,"lsnr":5.5},{"rssic":-60,"lsnr":2.0}]}],"stat":{"rxnb":1}}
    ;
    const frame_bytes = try std.fmt.allocPrint(allocator, "{c}{c}{c}{c}\x01\x02\x03\x04\x05\x06\x07\x08{s}", .{
        semtech_version,
        0x12,
        0x34,
        push_data_ident,
        payload,
    });
    defer allocator.free(frame_bytes);

    var frame = try decodeFrame(allocator, frame_bytes);
    defer frame.deinit(allocator);

    const push = frame.push_data;
    try std.testing.expectEqual(@as(u16, 0x1234), push.token);
    try std.testing.expectEqual(@as(usize, 1), push.rxpk.items.len);
    try std.testing.expectEqual(@as(f64, -70), push.rxpk.items[0].rssi.?);
    try std.testing.expectEqual(@as(f64, 5.5), push.rxpk.items[0].lsnr.?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03 }, push.rxpk.items[0].data);
}

test "decode push data falls back to rsig rssi when top-level missing" {
    const allocator = std.testing.allocator;
    const payload =
        \\{"rxpk":[{"tmst":7,"freq":868.3,"datr":"SF7BW125","codr":"4/6","data":"AQ==","rsig":[{"rssic":-90,"lsnr":1.0},{"rssic":-30,"lsnr":7.0}]}]}
    ;
    const frame_bytes = try std.fmt.allocPrint(allocator, "{c}{c}{c}{c}\x01\x02\x03\x04\x05\x06\x07\x08{s}", .{
        semtech_version,
        0x00,
        0x01,
        push_data_ident,
        payload,
    });
    defer allocator.free(frame_bytes);

    var frame = try decodeFrame(allocator, frame_bytes);
    defer frame.deinit(allocator);

    const rxpk = frame.push_data.rxpk.items[0];
    try std.testing.expectEqual(@as(f64, -30), rxpk.rssi.?);
    try std.testing.expectEqual(@as(f64, 7.0), rxpk.lsnr.?);
}

test "decode tx ack trims leading null and whitespace" {
    const allocator = std.testing.allocator;
    const msg = "\x01\x00\x02\x05\x01\x02\x03\x04\x05\x06\x07\x08\x00  \t{\"txpk_ack\":{\"error\":\"TOO_LATE\"}}";

    var frame = try decodeFrame(allocator, msg);
    defer frame.deinit(allocator);

    try std.testing.expectEqualStrings("TOO_LATE", frame.tx_ack.error_name.?);
}

test "build pull resp mirrors semtech txpk shape" {
    const allocator = std.testing.allocator;
    const json = try buildPullRespJson(allocator, .{
        .gateway_mac = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 },
        .dev_addr = null,
        .gateway_tmst = 1_000_000,
        .rfch = 1,
        .freq = 868.1,
        .powe = 14,
        .datr = .{ .lora = "SF9BW125" },
        .codr = "4/5",
        .timing = .{ .class_a_delay_s = 1 },
        .phy_payload = &[_]u8{ 0x10, 0x20, 0x30 },
    });
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const txpk = parsed.value.object.get("txpk").?.object;

    try std.testing.expectEqual(false, txpk.get("imme").?.bool);
    try std.testing.expectEqual(@as(i64, 2_000_000), txpk.get("tmst").?.integer);
    try std.testing.expectEqualStrings("LORA", txpk.get("modu").?.string);
    try std.testing.expectEqualStrings("ECAw", txpk.get("data").?.string);
    try std.testing.expectEqual(@as(i64, 3), txpk.get("size").?.integer);
}

test "encode ack and pull resp headers keep token" {
    const allocator = std.testing.allocator;
    const ack = try encodeAck(allocator, 1, 0xBEEF, pull_ack_ident);
    defer allocator.free(ack);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 0xBE, 0xEF, pull_ack_ident }, ack);

    const resp = try encodePullResp(allocator, 1, 0xCAFE, "{}");
    defer allocator.free(resp);
    try std.testing.expectEqual(@as(u8, pull_resp_ident), resp[3]);
    try std.testing.expectEqualSlices(u8, "{}", resp[4..]);
}
