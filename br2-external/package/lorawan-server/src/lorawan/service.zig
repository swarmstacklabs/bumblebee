const std = @import("std");

const app_mod = @import("../app.zig");
const packets = @import("packets.zig");
const codec = @import("codec.zig");
const commands = @import("commands.zig");
const state_repository = @import("../repository/lorawan_state_repository.zig");
const types = @import("types.zig");
const Database = app_mod.Database;
const Rxpk = packets.Rxpk;

pub const IngestResult = struct {
    event_type: []const u8,
    event_json: []u8,
    downlink: ?packets.DownlinkRequest,

    pub fn deinit(self: IngestResult, allocator: std.mem.Allocator) void {
        allocator.free(self.event_json);
        if (self.downlink) |value| {
            switch (value.datr) {
                .lora => |text| allocator.free(text),
                .fsk => {},
            }
            allocator.free(value.codr);
            switch (value.timing) {
                .absolute_time => |time| allocator.free(time),
                else => {},
            }
            allocator.free(value.phy_payload);
            if (value.dev_addr) |addr| allocator.free(addr);
        }
    }
};

pub const Service = struct {
    state_repo: state_repository.Repository,

    pub fn init(db: Database) Service {
        return .{
            .state_repo = state_repository.Repository.init(db),
        };
    }

    pub fn ingestRxpk(self: Service, allocator: std.mem.Allocator, gateway_mac: [8]u8, rxpk: Rxpk) !?IngestResult {
        const decoded = codec.decodeFrame(rxpk.data) catch return null;

        const gateway_hex = try state_repository.hexString(allocator, &gateway_mac);
        defer allocator.free(gateway_hex);

        const gateway = (try self.state_repo.loadGateway(allocator, gateway_hex)) orelse return null;
        defer gateway.deinit(allocator);

        const network = blk: {
            if (try self.state_repo.loadNetworkByName(allocator, gateway.network_name)) |value| break :blk value;
            return null;
        };
        defer network.deinit(allocator);

        return switch (decoded) {
            .join_request => |join| try self.handleJoinRequest(allocator, gateway_mac, gateway, network, rxpk, join),
            .data => |frame| try self.handleDataFrame(allocator, gateway_mac, gateway, network, rxpk, frame),
        };
    }

    fn handleJoinRequest(self: Service, allocator: std.mem.Allocator, gateway_mac: [8]u8, gateway: types.Gateway, network: types.Network, rxpk: Rxpk, join: types.JoinRequest) !?IngestResult {
        var device = (try self.state_repo.findDeviceByDevEui(allocator, join.dev_eui)) orelse return null;
        defer device.deinit(allocator);

        if (!std.mem.eql(u8, &device.app_eui, &join.app_eui)) return null;
        if (!codec.verifyJoinRequest(rxpk.data, device.app_key)) return null;

        var app_nonce: [3]u8 = undefined;
        std.crypto.random.bytes(&app_nonce);
        const session = codec.deriveSessionKeys(device.app_key, app_nonce, network.net_id, join.dev_nonce);

        const dev_addr = device.dev_addr_hint orelse try randomDevAddr(network.net_id);
        _ = try self.state_repo.createNodeForJoin(allocator, device, network, dev_addr, session.app_s_key, session.nwk_s_key);

        const join_accept = try codec.encodeJoinAccept(
            device.app_key,
            app_nonce,
            network.net_id,
            dev_addr,
            network.rxwin_init.rx1_dr_offset,
            network.rxwin_init.rx2_data_rate,
            @intCast(network.rx1_delay_s),
            null,
        );

        const dev_addr_hex = try state_repository.hexString(allocator, &dev_addr);
        errdefer allocator.free(dev_addr_hex);

        const event_json = try std.json.Stringify.valueAlloc(allocator, .{
            .gateway_mac = gateway_mac_hex(gateway_mac),
            .dev_eui = try state_repository.hexString(allocator, &join.dev_eui),
            .app_eui = try state_repository.hexString(allocator, &join.app_eui),
            .dev_addr = dev_addr_hex,
            .join_nonce = try state_repository.hexString(allocator, &app_nonce),
        }, .{});

        return .{
            .event_type = "lorawan_join_request",
            .event_json = event_json,
            .downlink = .{
                .gateway_mac = gateway_mac,
                .dev_addr = dev_addr_hex,
                .gateway_tmst = rxpk.tmst,
                .rfch = gateway.tx_rfch,
                .freq = rxpk.freq,
                .powe = network.gw_power,
                .datr = cloneDataRate(allocator, rxpk.datr),
                .codr = try allocator.dupe(u8, network.tx_codr),
                .timing = .{ .class_a_delay_s = network.join1_delay_s },
                .phy_payload = join_accept,
            },
        };
    }

    fn handleDataFrame(self: Service, allocator: std.mem.Allocator, gateway_mac: [8]u8, gateway: types.Gateway, network: types.Network, rxpk: Rxpk, frame: types.DataFrame) !?IngestResult {
        var node = (try self.state_repo.findNodeByDevAddr(allocator, frame.dev_addr)) orelse return null;
        if (!codec.verifyDataFrameMic(rxpk.data, node.nwk_s_key, frame.dev_addr, codec.fullFCnt(node.f_cnt_up, frame.f_cnt16), if (frame.is_uplink) 0 else 1)) {
            return null;
        }

        var parsed = try codec.decodeDataPayload(allocator, frame, node);
        defer parsed.deinit(allocator);

        node.f_cnt_up = parsed.f_cnt;

        var downlink: ?packets.DownlinkRequest = null;
        const response_commands = try codec.buildMacResponses(allocator, parsed, rxTimeMs(rxpk), 1);
        defer allocator.free(response_commands);

        if (response_commands.len > 0) {
            const f_opts = try commands.encodeFOpts(allocator, response_commands);
            defer allocator.free(f_opts);
            const phy = try codec.encodeUnicast(allocator, &node, .{}, f_opts, false, parsed.adr);
            const dev_addr_hex = try state_repository.hexString(allocator, &node.dev_addr);
            downlink = .{
                .gateway_mac = gateway_mac,
                .dev_addr = dev_addr_hex,
                .gateway_tmst = rxpk.tmst,
                .rfch = gateway.tx_rfch,
                .freq = rxpk.freq,
                .powe = network.gw_power,
                .datr = cloneDataRate(allocator, rxpk.datr),
                .codr = try allocator.dupe(u8, network.tx_codr),
                .timing = .{ .class_a_delay_s = network.rx1_delay_s },
                .phy_payload = phy,
            };
        }

        if (parsed.f_port == 0 and parsed.decoded_payload.len > 0) {
            const status_commands = commands.parseFOpts(allocator, parsed.decoded_payload) catch &[_]commands.Command{};
            if (@TypeOf(status_commands) != []commands.Command) {} else {
                defer allocator.free(status_commands);
                for (status_commands) |command| {
                    if (command == .dev_status_ans) {
                        node.last_battery = command.dev_status_ans.battery;
                        node.last_dev_status_margin = command.dev_status_ans.margin;
                    }
                }
            }
        }

        try self.state_repo.upsertNode(allocator, node);

        const f_opts_hex = try state_repository.hexString(allocator, parsed.f_opts);
        defer allocator.free(f_opts_hex);
        const payload_hex = try state_repository.hexString(allocator, parsed.decoded_payload);
        defer allocator.free(payload_hex);
        const dev_addr_hex = try state_repository.hexString(allocator, &parsed.dev_addr);
        defer allocator.free(dev_addr_hex);

        const event_json = try std.json.Stringify.valueAlloc(allocator, .{
            .gateway_mac = gateway_mac_hex(gateway_mac),
            .dev_addr = dev_addr_hex,
            .confirmed = parsed.confirmed,
            .adr = parsed.adr,
            .adr_ack_req = parsed.adr_ack_req,
            .ack = parsed.ack,
            .f_cnt = parsed.f_cnt,
            .f_port = parsed.f_port,
            .f_opts = f_opts_hex,
            .payload = payload_hex,
        }, .{});

        return .{
            .event_type = "lorawan_uplink",
            .event_json = event_json,
            .downlink = downlink,
        };
    }
};

fn cloneDataRate(allocator: std.mem.Allocator, datr: packets.DataRate) packets.DataRate {
    return switch (datr) {
        .lora => |text| .{ .lora = allocator.dupe(u8, text) catch unreachable },
        .fsk => |value| .{ .fsk = value },
    };
}

fn randomDevAddr(net_id: [3]u8) ![4]u8 {
    var out: [4]u8 = undefined;
    std.crypto.random.bytes(&out);
    out[0] = (out[0] & 0x01) | ((net_id[2] & 0x7F) << 1);
    return out;
}

fn rxTimeMs(rxpk: Rxpk) i64 {
    return rxpk.tmms orelse std.time.milliTimestamp();
}

fn gateway_mac_hex(mac: [8]u8) [16]u8 {
    return packets.gatewayMacHex(mac);
}
