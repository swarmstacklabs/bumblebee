const std = @import("std");

pub const DataRate = @import("packets.zig").DataRate;

pub const RxWindowConfig = struct {
    rx1_dr_offset: u8 = 0,
    rx2_data_rate: u8 = 0,
    frequency: f64 = 869.525,

    pub fn init(rx1_dr_offset: u8, rx2_data_rate: u8, frequency: f64) RxWindowConfig {
        return .{
            .rx1_dr_offset = rx1_dr_offset,
            .rx2_data_rate = rx2_data_rate,
            .frequency = frequency,
        };
    }

    pub fn deinit(_: RxWindowConfig) void {}
};

pub const AdrConfig = struct {
    tx_power: i32,
    data_rate: u8,
    max_dcycle: ?u8 = null,
    uplink_dwell_time: ?bool = null,
    downlink_dwell_time: ?bool = null,
    max_eirp: ?u8 = null,

    pub fn init(tx_power: i32, data_rate: u8) AdrConfig {
        return .{
            .tx_power = tx_power,
            .data_rate = data_rate,
            .max_dcycle = null,
            .uplink_dwell_time = null,
            .downlink_dwell_time = null,
            .max_eirp = null,
        };
    }

    pub fn deinit(_: AdrConfig) void {}
};

pub const ChannelMaskState = struct {
    control: u8,
    mask: u16,

    pub fn init(control: u8, mask: u16) ChannelMaskState {
        return .{
            .control = control,
            .mask = mask,
        };
    }

    pub fn deinit(_: ChannelMaskState) void {}
};

pub const ExtraChannel = struct {
    index: u8,
    frequency: f64,
    min_data_rate: u8,
    max_data_rate: u8,

    pub fn init(index: u8, frequency: f64, min_data_rate: u8, max_data_rate: u8) ExtraChannel {
        return .{
            .index = index,
            .frequency = frequency,
            .min_data_rate = min_data_rate,
            .max_data_rate = max_data_rate,
        };
    }

    pub fn deinit(_: ExtraChannel) void {}
};

pub const DlChannelMapping = struct {
    index: u8,
    frequency: f64,

    pub fn init(index: u8, frequency: f64) DlChannelMapping {
        return .{
            .index = index,
            .frequency = frequency,
        };
    }

    pub fn deinit(_: DlChannelMapping) void {}
};

pub const Device = struct {
    id: i64,
    name: []u8,
    dev_eui: [8]u8,
    app_eui: [8]u8,
    app_key: [16]u8,
    network_name: ?[]u8,
    dev_addr_hint: ?[4]u8,
    used_dev_nonces: []u16,
    next_app_nonce: u32,

    pub fn init(id: i64, name: []u8, dev_eui: [8]u8, app_eui: [8]u8, app_key: [16]u8, network_name: ?[]u8, dev_addr_hint: ?[4]u8, used_dev_nonces: []u16, next_app_nonce: u32) Device {
        return .{
            .id = id,
            .name = name,
            .dev_eui = dev_eui,
            .app_eui = app_eui,
            .app_key = app_key,
            .network_name = network_name,
            .dev_addr_hint = dev_addr_hint,
            .used_dev_nonces = used_dev_nonces,
            .next_app_nonce = next_app_nonce,
        };
    }

    pub fn deinit(self: Device, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.network_name) |value| allocator.free(value);
        allocator.free(self.used_dev_nonces);
    }
};

pub const Network = struct {
    name: []u8,
    net_id: [3]u8,
    tx_codr: []u8,
    join1_delay_s: u32,
    rx1_delay_s: u32,
    gw_power: i32,
    rxwin_init: RxWindowConfig,

    pub fn init(name: []u8, net_id: [3]u8, tx_codr: []u8, join1_delay_s: u32, rx1_delay_s: u32, gw_power: i32, rxwin_init: RxWindowConfig) Network {
        return .{
            .name = name,
            .net_id = net_id,
            .tx_codr = tx_codr,
            .join1_delay_s = join1_delay_s,
            .rx1_delay_s = rx1_delay_s,
            .gw_power = gw_power,
            .rxwin_init = rxwin_init,
        };
    }

    pub fn deinit(self: Network, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.tx_codr);
    }
};

pub const Gateway = struct {
    mac: [8]u8,
    tx_rfch: u8,
    network_name: []u8,

    pub fn init(mac: [8]u8, tx_rfch: u8, network_name: []u8) Gateway {
        return .{
            .mac = mac,
            .tx_rfch = tx_rfch,
            .network_name = network_name,
        };
    }

    pub fn deinit(self: Gateway, allocator: std.mem.Allocator) void {
        allocator.free(self.network_name);
    }
};

pub const ApplicationDownlink = struct {
    confirmed: bool,
    port: u8,
    payload: []u8,

    pub fn init(confirmed: bool, port: u8, payload: []u8) ApplicationDownlink {
        return .{
            .confirmed = confirmed,
            .port = port,
            .payload = payload,
        };
    }

    pub fn deinit(self: ApplicationDownlink, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
    }

    pub fn txData(self: ApplicationDownlink, pending: bool) TxData {
        return TxData.init(self.confirmed, self.port, self.payload, pending);
    }
};

pub const Node = struct {
    id: i64,
    dev_addr: [4]u8,
    device_id: ?i64,
    dev_eui: ?[8]u8,
    app_s_key: [16]u8,
    nwk_s_key: [16]u8,
    f_cnt_up: ?u32,
    f_cnt_down: u32,
    rxwin_use: RxWindowConfig,
    rx1_delay_s: ?u8,
    adr_use: AdrConfig,
    channel_masks: ?[]ChannelMaskState,
    enabled_channels: ?[]u8,
    extra_channels: ?[]ExtraChannel,
    dl_channel_map: ?[]DlChannelMapping,
    last_dev_status_margin: ?i8,
    last_battery: ?u8,
    pending_mac_commands: ?[]u8,
    application_downlink_queue: ?[]ApplicationDownlink,
    pending_confirmed_downlink: ?[]u8,
    confirmed_downlink_retries: u8,

    pub fn init(dev_addr: [4]u8, app_s_key: [16]u8, nwk_s_key: [16]u8, rxwin_use: RxWindowConfig, adr_use: AdrConfig) Node {
        return .{
            .id = 0,
            .dev_addr = dev_addr,
            .device_id = null,
            .dev_eui = null,
            .app_s_key = app_s_key,
            .nwk_s_key = nwk_s_key,
            .f_cnt_up = null,
            .f_cnt_down = 0,
            .rxwin_use = rxwin_use,
            .rx1_delay_s = null,
            .adr_use = adr_use,
            .channel_masks = null,
            .enabled_channels = null,
            .extra_channels = null,
            .dl_channel_map = null,
            .last_dev_status_margin = null,
            .last_battery = null,
            .pending_mac_commands = null,
            .application_downlink_queue = null,
            .pending_confirmed_downlink = null,
            .confirmed_downlink_retries = 0,
        };
    }

    pub fn deinit(self: Node, allocator: std.mem.Allocator) void {
        if (self.channel_masks) |value| allocator.free(value);
        if (self.enabled_channels) |value| allocator.free(value);
        if (self.extra_channels) |value| allocator.free(value);
        if (self.dl_channel_map) |value| allocator.free(value);
        if (self.pending_mac_commands) |value| allocator.free(value);
        if (self.application_downlink_queue) |value| {
            for (value) |item| item.deinit(allocator);
            allocator.free(value);
        }
        if (self.pending_confirmed_downlink) |value| allocator.free(value);
    }

    pub fn nextQueuedApplicationDownlink(self: Node) ?TxData {
        const queue = self.application_downlink_queue orelse return null;
        if (queue.len == 0) return null;

        return queue[0].txData(queue.len > 1);
    }
};

pub const TxData = struct {
    confirmed: bool = false,
    port: ?u8 = null,
    data: []const u8 = "",
    pending: bool = false,

    pub fn init(confirmed: bool, port: ?u8, data: []const u8, pending: bool) TxData {
        return .{
            .confirmed = confirmed,
            .port = port,
            .data = data,
            .pending = pending,
        };
    }

    pub fn deinit(_: TxData) void {}
};

pub const JoinRequest = struct {
    app_eui: [8]u8,
    dev_eui: [8]u8,
    dev_nonce: [2]u8,
    mic: [4]u8,

    pub fn init(app_eui: [8]u8, dev_eui: [8]u8, dev_nonce: [2]u8, mic: [4]u8) JoinRequest {
        return .{
            .app_eui = app_eui,
            .dev_eui = dev_eui,
            .dev_nonce = dev_nonce,
            .mic = mic,
        };
    }

    pub fn deinit(_: JoinRequest) void {}
};

pub const DataFrame = struct {
    confirmed: bool,
    is_uplink: bool,
    dev_addr: [4]u8,
    adr: bool,
    adr_ack_req: bool,
    ack: bool,
    pending: bool,
    f_cnt16: u16,
    f_opts: []const u8,
    f_port: ?u8,
    frm_payload: []const u8,
    mic: [4]u8,

    pub fn init(confirmed: bool, is_uplink: bool, dev_addr: [4]u8, adr: bool, adr_ack_req: bool, ack: bool, pending: bool, f_cnt16: u16, f_opts: []const u8, f_port: ?u8, frm_payload: []const u8, mic: [4]u8) DataFrame {
        return .{
            .confirmed = confirmed,
            .is_uplink = is_uplink,
            .dev_addr = dev_addr,
            .adr = adr,
            .adr_ack_req = adr_ack_req,
            .ack = ack,
            .pending = pending,
            .f_cnt16 = f_cnt16,
            .f_opts = f_opts,
            .f_port = f_port,
            .frm_payload = frm_payload,
            .mic = mic,
        };
    }

    pub fn deinit(_: DataFrame) void {}
};

pub const DecodedFrame = union(enum) {
    join_request: JoinRequest,
    data: DataFrame,
};

pub const ParsedDataFrame = struct {
    confirmed: bool,
    dev_addr: [4]u8,
    adr: bool,
    adr_ack_req: bool,
    ack: bool,
    f_cnt: u32,
    f_port: ?u8,
    f_opts: []u8,
    decoded_payload: []u8,

    pub fn init(confirmed: bool, dev_addr: [4]u8, adr: bool, adr_ack_req: bool, ack: bool, f_cnt: u32, f_port: ?u8, f_opts: []u8, decoded_payload: []u8) ParsedDataFrame {
        return .{
            .confirmed = confirmed,
            .dev_addr = dev_addr,
            .adr = adr,
            .adr_ack_req = adr_ack_req,
            .ack = ack,
            .f_cnt = f_cnt,
            .f_port = f_port,
            .f_opts = f_opts,
            .decoded_payload = decoded_payload,
        };
    }

    pub fn deinit(self: ParsedDataFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.f_opts);
        allocator.free(self.decoded_payload);
    }
};

test "node queued application downlink sets pending when more remain" {
    var node = Node.init(.{ 0x01, 0x02, 0x03, 0x04 }, [_]u8{0} ** 16, [_]u8{0} ** 16, .{}, .{ .tx_power = 0, .data_rate = 0 });
    defer node.deinit(std.testing.allocator);

    node.application_downlink_queue = try std.testing.allocator.alloc(ApplicationDownlink, 2);
    node.application_downlink_queue.?[0] = ApplicationDownlink.init(false, 15, try std.testing.allocator.dupe(u8, "hello"));
    node.application_downlink_queue.?[1] = ApplicationDownlink.init(true, 9, try std.testing.allocator.dupe(u8, "bye"));

    const tx_data = node.nextQueuedApplicationDownlink().?;
    try std.testing.expectEqual(false, tx_data.confirmed);
    try std.testing.expectEqual(@as(?u8, 15), tx_data.port);
    try std.testing.expectEqualSlices(u8, "hello", tx_data.data);
    try std.testing.expect(tx_data.pending);
}

test "node queued application downlink clears pending for final item" {
    var node = Node.init(.{ 0x01, 0x02, 0x03, 0x04 }, [_]u8{0} ** 16, [_]u8{0} ** 16, .{}, .{ .tx_power = 0, .data_rate = 0 });
    defer node.deinit(std.testing.allocator);

    node.application_downlink_queue = try std.testing.allocator.alloc(ApplicationDownlink, 1);
    node.application_downlink_queue.?[0] = ApplicationDownlink.init(true, 9, try std.testing.allocator.dupe(u8, "bye"));

    const tx_data = node.nextQueuedApplicationDownlink().?;
    try std.testing.expectEqual(true, tx_data.confirmed);
    try std.testing.expectEqual(@as(?u8, 9), tx_data.port);
    try std.testing.expectEqualSlices(u8, "bye", tx_data.data);
    try std.testing.expect(!tx_data.pending);
}
