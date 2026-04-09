const std = @import("std");

pub const DataRate = @import("packets.zig").DataRate;

pub const RxWindowConfig = struct {
    rx1_dr_offset: u8 = 0,
    rx2_data_rate: u8 = 0,
    frequency: f64 = 869.525,
};

pub const AdrConfig = struct {
    tx_power: i32,
    data_rate: u8,
};

pub const Device = struct {
    id: i64,
    name: []u8,
    dev_eui: [8]u8,
    app_eui: [8]u8,
    app_key: [16]u8,
    network_name: ?[]u8,
    dev_addr_hint: ?[4]u8,

    pub fn deinit(self: Device, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.network_name) |value| allocator.free(value);
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

    pub fn deinit(self: Network, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.tx_codr);
    }
};

pub const Gateway = struct {
    mac: [8]u8,
    tx_rfch: u8,
    network_name: []u8,

    pub fn deinit(self: Gateway, allocator: std.mem.Allocator) void {
        allocator.free(self.network_name);
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
    adr_use: AdrConfig,
    last_dev_status_margin: ?i8,
    last_battery: ?u8,

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
            .adr_use = adr_use,
            .last_dev_status_margin = null,
            .last_battery = null,
        };
    }
};

pub const TxData = struct {
    confirmed: bool = false,
    port: ?u8 = null,
    data: []const u8 = "",
    pending: bool = false,
};

pub const JoinRequest = struct {
    app_eui: [8]u8,
    dev_eui: [8]u8,
    dev_nonce: [2]u8,
    mic: [4]u8,
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

    pub fn deinit(self: ParsedDataFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.f_opts);
        allocator.free(self.decoded_payload);
    }
};
