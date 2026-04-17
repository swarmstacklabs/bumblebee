const std = @import("std");

const app_mod = @import("../app.zig");
const packets = @import("packets.zig");
const codec = @import("codec.zig");
const commands = @import("commands.zig");
const mac_handlers = @import("handlers/mac_handlers.zig");
const mac_command_metrics_repository = @import("../repository/mac_command_metrics_repository.zig");
const region_mod = @import("region.zig");
const state_repository = @import("../repository/lorawan_state_repository.zig");
const types = @import("types.zig");
const Database = app_mod.Database;
const Rxpk = packets.Rxpk;
const Command = commands.Command;
const confirmed_downlink_max_retries: u8 = 2;

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
    metrics_repo: mac_command_metrics_repository.Repository,

    pub fn init(db: Database) Service {
        return .{
            .state_repo = state_repository.Repository.init(db),
            .metrics_repo = mac_command_metrics_repository.Repository.init(db),
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

    pub fn syncAcknowledgedDownlink(self: Service, allocator: std.mem.Allocator, pending_json: []const u8) !void {
        const phy_payload = try decodePendingPhyPayload(allocator, pending_json);
        defer allocator.free(phy_payload);

        const decoded = codec.decodeFrame(phy_payload) catch return;
        const frame = switch (decoded) {
            .data => |value| value,
            else => return,
        };

        var node = (try self.state_repo.findNodeByDevAddr(allocator, frame.dev_addr)) orelse return;
        defer node.deinit(allocator);

        if (frame.confirmed) {
            if (node.pending_confirmed_downlink) |pending_phy| {
                if (std.mem.eql(u8, pending_phy, phy_payload)) return;
            }
        }

        if (frame.f_opts.len > 0) {
            const combined = try appendPendingMacCommands(allocator, node.pending_mac_commands, frame.f_opts);
            if (node.pending_mac_commands) |value| allocator.free(value);
            node.pending_mac_commands = combined;
        }

        if (frame.f_port == 0 and frame.frm_payload.len > 0) {
            const parsed = try codec.decodeDataPayloadWithFCnt(allocator, frame, node, node.f_cnt_down);
            defer parsed.deinit(allocator);
            const combined = try appendPendingMacCommands(allocator, node.pending_mac_commands, parsed.decoded_payload);
            if (node.pending_mac_commands) |value| allocator.free(value);
            node.pending_mac_commands = combined;
        } else if (frame.f_port) |port| {
            const parsed = try codec.decodeDataPayloadWithFCnt(allocator, frame, node, node.f_cnt_down);
            defer parsed.deinit(allocator);
            acknowledgeApplicationDownlink(allocator, &node, frame.confirmed, port, parsed.decoded_payload);
        }

        if (frame.confirmed) {
            try replacePendingConfirmedDownlink(allocator, &node, phy_payload, confirmed_downlink_max_retries);
        }

        try self.state_repo.upsertNode(allocator, node);
    }

    fn handleJoinRequest(self: Service, allocator: std.mem.Allocator, gateway_mac: [8]u8, gateway: types.Gateway, network: types.Network, rxpk: Rxpk, join: types.JoinRequest) !?IngestResult {
        var device = (try self.state_repo.findDeviceByDevEui(allocator, join.dev_eui)) orelse return null;
        defer device.deinit(allocator);

        if (!std.mem.eql(u8, &device.app_eui, &join.app_eui)) return null;
        if (!codec.verifyJoinRequest(rxpk.data, device.app_key)) return null;
        const dev_nonce = std.mem.readInt(u16, &join.dev_nonce, .little);
        if (containsDevNonce(device.used_dev_nonces, dev_nonce)) return null;

        const app_nonce = allocateAppNonce(&device) orelse return null;
        const session = codec.deriveSessionKeys(device.app_key, app_nonce, network.net_id, join.dev_nonce);

        const dev_addr = device.dev_addr_hint orelse try randomDevAddr(network.net_id);
        _ = try self.state_repo.createNodeForJoin(allocator, device, network, dev_addr, session.app_s_key, session.nwk_s_key);
        const used_dev_nonces = try appendDevNonce(allocator, device.used_dev_nonces, dev_nonce);
        allocator.free(device.used_dev_nonces);
        device.used_dev_nonces = used_dev_nonces;
        try self.state_repo.upsertDevice(allocator, device);

        const join_accept = try codec.encodeJoinAccept(
            allocator,
            device.app_key,
            app_nonce,
            network.net_id,
            dev_addr,
            network.rxwin_init.rx1_dr_offset,
            network.rxwin_init.rx2_data_rate,
            @intCast(if (network.rx1_delay_s <= 1) 0 else network.rx1_delay_s),
            network.cf_list_100hz,
        );

        const dev_addr_hex = try state_repository.hexString(allocator, &dev_addr);
        errdefer allocator.free(dev_addr_hex);

        const dev_eui_hex = try state_repository.hexString(allocator, &join.dev_eui);
        defer allocator.free(dev_eui_hex);
        const app_eui_hex = try state_repository.hexString(allocator, &join.app_eui);
        defer allocator.free(app_eui_hex);
        const join_nonce_hex = try state_repository.hexString(allocator, &app_nonce);
        defer allocator.free(join_nonce_hex);

        const event_json = try std.json.Stringify.valueAlloc(allocator, .{
            .gateway_mac = gateway_mac_hex(gateway_mac),
            .dev_eui = dev_eui_hex,
            .app_eui = app_eui_hex,
            .dev_addr = dev_addr_hex,
            .join_nonce = join_nonce_hex,
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
        defer node.deinit(allocator);
        if (!frame.is_uplink) return null;

        const full_f_cnt = codec.fullFCnt(node.f_cnt_up, frame.f_cnt16);
        if (!codec.verifyDataFrameMic(rxpk.data, node.nwk_s_key, frame.dev_addr, full_f_cnt, 0)) {
            return null;
        }
        if (node.f_cnt_up) |previous_f_cnt| {
            if (full_f_cnt <= previous_f_cnt) return null;
        }

        var parsed = try codec.decodeDataPayload(allocator, frame, node);
        defer parsed.deinit(allocator);

        node.f_cnt_up = parsed.f_cnt;
        if (parsed.ack) clearPendingConfirmedDownlink(allocator, &node);
        updateAdrObservations(&node, network.region, parsed.adr, rxpk);

        var downlink: ?packets.DownlinkRequest = null;
        const response_commands = try codec.buildMacResponsesWithMetrics(allocator, parsed, currentLinkMetrics(rxpk), &self.metrics_repo);
        defer allocator.free(response_commands);
        const pending_commands = try parsePendingCommands(allocator, node.pending_mac_commands);
        defer allocator.free(pending_commands);
        const network_commands = try mac_handlers.buildNetworkCommands(
            allocator,
            node,
            network.rxwin_init,
            network.rx1_delay_s,
            network.region,
            pending_commands,
        );
        defer allocator.free(network_commands);
        const outgoing_commands = try appendCommands(allocator, response_commands, network_commands);
        defer allocator.free(outgoing_commands);
        const queued_application = node.nextQueuedApplicationDownlink();
        const has_queued_application = queued_application != null;

        if (outgoing_commands.len > 0 or parsed.confirmed or has_queued_application) {
            const tx_data = if (queued_application != null and outgoing_commands.len <= 15)
                queued_application.?
            else
                types.TxData.init(false, null, "", has_queued_application);
            const f_opts = if (outgoing_commands.len > 0)
                try commands.encodeFOpts(allocator, outgoing_commands)
            else
                try allocator.alloc(u8, 0);
            defer allocator.free(f_opts);
            const phy = try codec.encodeUnicast(allocator, &node, tx_data, f_opts, parsed.confirmed, parsed.adr);
            defer allocator.free(phy);
            downlink = try buildNodeDownlinkRequest(allocator, gateway_mac, gateway, network, rxpk, node, phy);
        } else if (node.pending_confirmed_downlink) |pending_phy| {
            if (node.confirmed_downlink_retries > 0) {
                node.confirmed_downlink_retries -= 1;
                downlink = try buildNodeDownlinkRequest(allocator, gateway_mac, gateway, network, rxpk, node, pending_phy);
            } else {
                clearPendingConfirmedDownlink(allocator, &node);
            }
        }

        if (codec.collectMacCommands(allocator, parsed)) |status_commands| {
            defer allocator.free(status_commands);
            const remaining_pending = try mac_handlers.applyToNode(allocator, network.region, &node, pending_commands, status_commands);
            defer allocator.free(remaining_pending);

            if (node.pending_mac_commands) |value| {
                allocator.free(value);
                node.pending_mac_commands = null;
            }
            if (remaining_pending.len > 0) {
                node.pending_mac_commands = try commands.encodeFOpts(allocator, remaining_pending);
            }
        } else |_| {}

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

fn currentLinkMetrics(rxpk: Rxpk) mac_handlers.LinkMetrics {
    return .{
        .rx_time_ms = rxpk.tmms,
        .margin = linkCheckMargin(rxpk),
        .gateway_count = linkCheckGatewayCount(rxpk),
    };
}

fn linkCheckMargin(rxpk: Rxpk) u8 {
    const lsnr = rxpk.lsnr orelse return 0;
    const required_lsnr = requiredLinkCheckSnr(rxpk.datr) orelse return 0;
    const margin = @max(0.0, lsnr - required_lsnr);
    return @intFromFloat(@min(margin, @as(f64, @floatFromInt(std.math.maxInt(u8)))));
}

fn linkCheckGatewayCount(_: Rxpk) usize {
    // The current ingest path handles one verified uplink reception at a time.
    return 1;
}

fn requiredLinkCheckSnr(datr: packets.DataRate) ?f64 {
    const spreading_factor = switch (datr) {
        .lora => |value| spreadingFactorForDataRate(value) orelse return null,
        .fsk => return null,
    };
    return -5.0 - 2.5 * @as(f64, @floatFromInt(spreading_factor - 6));
}

fn spreadingFactorForDataRate(datr: []const u8) ?u8 {
    if (std.mem.eql(u8, datr, "SF12BW125")) return 12;
    if (std.mem.eql(u8, datr, "SF11BW125")) return 11;
    if (std.mem.eql(u8, datr, "SF10BW125")) return 10;
    if (std.mem.eql(u8, datr, "SF9BW125")) return 9;
    if (std.mem.eql(u8, datr, "SF8BW125")) return 8;
    if (std.mem.eql(u8, datr, "SF7BW125")) return 7;
    if (std.mem.eql(u8, datr, "SF7BW250")) return 7;
    return null;
}

fn gateway_mac_hex(mac: [8]u8) [16]u8 {
    return packets.gatewayMacHex(mac);
}

fn parsePendingCommands(allocator: std.mem.Allocator, pending_mac_commands: ?[]const u8) ![]Command {
    const bytes = pending_mac_commands orelse return allocator.alloc(Command, 0);
    return commands.parseDownlinkFOpts(allocator, bytes);
}

fn appendPendingMacCommands(allocator: std.mem.Allocator, existing: ?[]const u8, new: []const u8) ![]u8 {
    const existing_len = if (existing) |value| value.len else 0;
    const out = try allocator.alloc(u8, existing_len + new.len);
    if (existing) |value| @memcpy(out[0..value.len], value);
    @memcpy(out[existing_len..], new);
    return out;
}

fn appendCommands(allocator: std.mem.Allocator, first: []const Command, second: []const Command) ![]Command {
    const out = try allocator.alloc(Command, first.len + second.len);
    @memcpy(out[0..first.len], first);
    @memcpy(out[first.len..], second);
    return out;
}

fn acknowledgeApplicationDownlink(allocator: std.mem.Allocator, node: *types.Node, confirmed: bool, port: u8, payload: []const u8) void {
    const queue = node.application_downlink_queue orelse return;
    if (queue.len == 0) return;

    const first = queue[0];
    if (first.confirmed != confirmed or first.port != port) return;
    if (!std.mem.eql(u8, first.payload, payload)) return;

    allocator.free(first.payload);
    if (queue.len == 1) {
        allocator.free(queue);
        node.application_downlink_queue = null;
        return;
    }

    const remaining = allocator.alloc(types.ApplicationDownlink, queue.len - 1) catch return;
    for (queue[1..], 0..) |item, i| remaining[i] = item;
    allocator.free(queue);
    node.application_downlink_queue = remaining;
}

fn buildNodeDownlinkRequest(allocator: std.mem.Allocator, gateway_mac: [8]u8, gateway: types.Gateway, network: types.Network, rxpk: Rxpk, node: types.Node, phy_payload: []const u8) !packets.DownlinkRequest {
    const dev_addr_hex = try state_repository.hexString(allocator, &node.dev_addr);
    errdefer allocator.free(dev_addr_hex);

    const rx_window = try selectClassADownlinkWindowWithDelay(allocator, network, rxpk, node.rxwin_use, node.rx1_delay_s);

    return .{
        .gateway_mac = gateway_mac,
        .dev_addr = dev_addr_hex,
        .gateway_tmst = rxpk.tmst,
        .rfch = gateway.tx_rfch,
        .freq = rx_window.freq,
        .powe = network.gw_power,
        .datr = rx_window.datr,
        .codr = try allocator.dupe(u8, network.tx_codr),
        .timing = .{ .class_a_delay_s = rx_window.delay_s },
        .phy_payload = try allocator.dupe(u8, phy_payload),
    };
}

const SelectedClassAWindow = struct {
    freq: f64,
    datr: packets.DataRate,
    delay_s: u32,
};

fn selectClassADownlinkWindow(allocator: std.mem.Allocator, network: types.Network, rxpk: Rxpk, rxwin_use: types.RxWindowConfig) !SelectedClassAWindow {
    return selectClassADownlinkWindowWithDelay(allocator, network, rxpk, rxwin_use, null);
}

fn selectClassADownlinkWindowWithDelay(allocator: std.mem.Allocator, network: types.Network, rxpk: Rxpk, rxwin_use: types.RxWindowConfig, rx1_delay_override: ?u8) !SelectedClassAWindow {
    const rx1_delay_s = @as(u32, rx1_delay_override orelse @as(u8, @intCast(network.rx1_delay_s)));
    if (try rx1DataRate(network.region, allocator, rxpk.datr, rxwin_use.rx1_dr_offset)) |datr| {
        return .{
            .freq = region_mod.rx1DownlinkFrequency(network.region, rxpk.freq) orelse rxpk.freq,
            .datr = datr,
            .delay_s = rx1_delay_s,
        };
    }

    return .{
        .freq = rxwin_use.frequency,
        .datr = try rx2DataRate(network.region, allocator, rxwin_use.rx2_data_rate),
        .delay_s = rx1_delay_s + 1,
    };
}

fn rx1DataRate(region: types.Region, allocator: std.mem.Allocator, uplink_datr: packets.DataRate, rx1_dr_offset: u8) !?packets.DataRate {
    return try region_mod.downlinkRx1DataRate(region, allocator, uplink_datr, rx1_dr_offset);
}

fn rx2DataRate(region: types.Region, allocator: std.mem.Allocator, data_rate: u8) !packets.DataRate {
    return try region_mod.rx2DataRate(region, allocator, data_rate);
}

fn replacePendingConfirmedDownlink(allocator: std.mem.Allocator, node: *types.Node, phy_payload: []const u8, retries: u8) !void {
    if (node.pending_confirmed_downlink) |value| allocator.free(value);
    node.pending_confirmed_downlink = try allocator.dupe(u8, phy_payload);
    node.confirmed_downlink_retries = retries;
}

fn clearPendingConfirmedDownlink(allocator: std.mem.Allocator, node: *types.Node) void {
    if (node.pending_confirmed_downlink) |value| {
        allocator.free(value);
        node.pending_confirmed_downlink = null;
    }
    node.confirmed_downlink_retries = 0;
}

fn updateAdrObservations(node: *types.Node, region: types.Region, adr_enabled: bool, rxpk: Rxpk) void {
    if (!adr_enabled) {
        resetAdrObservationState(node);
        node.adr_last_data_rate = null;
        return;
    }

    const data_rate = region_mod.uplinkDataRateIndex(region, rxpk.datr) catch null orelse {
        resetAdrObservationState(node);
        node.adr_last_data_rate = null;
        return;
    };

    if (node.adr_last_data_rate == null or node.adr_last_data_rate.? != data_rate) {
        resetAdrObservationState(node);
    }
    node.adr_last_data_rate = data_rate;

    if (rxpk.rssi) |rssi| {
        node.adr_average_rssi = nextAverage(node.adr_average_rssi, node.adr_observation_count, rssi);
    }
    if (rxpk.lsnr) |lsnr| {
        node.adr_average_lsnr = nextAverage(node.adr_average_lsnr, node.adr_observation_count, lsnr);
    }

    if (node.adr_observation_count < std.math.maxInt(u16)) {
        node.adr_observation_count += 1;
    }
}

fn resetAdrObservationState(node: *types.Node) void {
    node.adr_observation_count = 0;
    node.adr_average_rssi = null;
    node.adr_average_lsnr = null;
}

fn nextAverage(current: ?f64, sample_count: u16, sample: f64) f64 {
    if (current == null or sample_count == 0) return sample;
    const count = @as(f64, @floatFromInt(sample_count));
    return ((current.? * count) + sample) / (count + 1.0);
}

fn containsDevNonce(used_dev_nonces: []const u16, dev_nonce: u16) bool {
    for (used_dev_nonces) |used| {
        if (used == dev_nonce) return true;
    }
    return false;
}

fn appendDevNonce(allocator: std.mem.Allocator, used_dev_nonces: []const u16, dev_nonce: u16) ![]u16 {
    const out = try allocator.alloc(u16, used_dev_nonces.len + 1);
    @memcpy(out[0..used_dev_nonces.len], used_dev_nonces);
    out[used_dev_nonces.len] = dev_nonce;
    return out;
}

fn allocateAppNonce(device: *types.Device) ?[3]u8 {
    if (device.next_app_nonce > 0x00FF_FFFF) return null;

    const app_nonce = [3]u8{
        @intCast(device.next_app_nonce & 0xFF),
        @intCast((device.next_app_nonce >> 8) & 0xFF),
        @intCast((device.next_app_nonce >> 16) & 0xFF),
    };
    device.next_app_nonce += 1;
    return app_nonce;
}

fn decodePendingPhyPayload(allocator: std.mem.Allocator, pending_json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, pending_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const root = parsed.value.object;
    const txpk = root.get("txpk") orelse return error.MissingTxpk;
    if (txpk != .object) return error.InvalidPendingJson;
    const data = txpk.object.get("data") orelse return error.MissingTxpkData;
    if (data != .string) return error.InvalidPendingJson;

    const decoder = std.base64.standard.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(data.string);
    const out = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(out);
    try decoder.decode(out, data.string);
    return out;
}

test "current link metrics derive LinkCheckAns margin from uplink lsnr" {
    const rxpk = packets.Rxpk{
        .tmst = 1,
        .freq = 868.1,
        .datr = .{ .lora = try std.testing.allocator.dupe(u8, "SF10BW125") },
        .codr = try std.testing.allocator.dupe(u8, "4/5"),
        .data = try std.testing.allocator.alloc(u8, 0),
        .time = null,
        .tmms = 1234,
        .rssi = -80,
        .lsnr = 3.0,
    };
    defer rxpk.deinit(std.testing.allocator);

    const metrics = currentLinkMetrics(rxpk);
    try std.testing.expectEqual(@as(i64, 1234), metrics.rx_time_ms);
    try std.testing.expectEqual(@as(u8, 18), metrics.margin);
    try std.testing.expectEqual(@as(usize, 1), metrics.gateway_count);
}

test "link check margin falls back to zero when data rate has no LoRa SNR floor" {
    const rxpk = packets.Rxpk{
        .tmst = 1,
        .freq = 868.1,
        .datr = .{ .fsk = 50000 },
        .codr = try std.testing.allocator.dupe(u8, "4/5"),
        .data = try std.testing.allocator.alloc(u8, 0),
        .time = null,
        .tmms = null,
        .rssi = -80,
        .lsnr = 12.0,
    };
    defer rxpk.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 0), linkCheckMargin(rxpk));
}

test "class A window respects node rx1 delay override" {
    const network = types.Network.init(
        try std.testing.allocator.dupe(u8, "public"),
        .eu868,
        .{ 0x00, 0x00, 0x13 },
        try std.testing.allocator.dupe(u8, "4/5"),
        5,
        1,
        14,
        .{},
        null,
    );
    defer network.deinit(std.testing.allocator);

    const rxpk = packets.Rxpk{
        .tmst = 1,
        .freq = 868.1,
        .datr = .{ .lora = try std.testing.allocator.dupe(u8, "SF7BW125") },
        .codr = try std.testing.allocator.dupe(u8, "4/5"),
        .data = try std.testing.allocator.alloc(u8, 0),
        .time = null,
        .tmms = null,
        .rssi = null,
        .lsnr = null,
    };
    defer rxpk.deinit(std.testing.allocator);

    const selected = try selectClassADownlinkWindowWithDelay(std.testing.allocator, network, rxpk, .{}, 3);
    defer switch (selected.datr) {
        .lora => |value| std.testing.allocator.free(value),
        .fsk => {},
    };

    try std.testing.expectEqual(@as(u32, 3), selected.delay_s);
    try std.testing.expectEqual(@as(f64, 868.1), selected.freq);
}

test "class A FSK uplink in EU868 can stay in RX1 with overridden delay" {
    const network = types.Network.init(
        try std.testing.allocator.dupe(u8, "public"),
        .eu868,
        .{ 0x00, 0x00, 0x13 },
        try std.testing.allocator.dupe(u8, "4/5"),
        5,
        1,
        14,
        .{},
        null,
    );
    defer network.deinit(std.testing.allocator);

    const rxpk = packets.Rxpk{
        .tmst = 1,
        .freq = 868.1,
        .datr = .{ .fsk = 50000 },
        .codr = try std.testing.allocator.dupe(u8, "4/5"),
        .data = try std.testing.allocator.alloc(u8, 0),
        .time = null,
        .tmms = null,
        .rssi = null,
        .lsnr = null,
    };
    defer rxpk.deinit(std.testing.allocator);

    const selected = try selectClassADownlinkWindowWithDelay(std.testing.allocator, network, rxpk, .{ .rx2_data_rate = 2, .frequency = 869.525 }, 4);
    defer switch (selected.datr) {
        .lora => |value| std.testing.allocator.free(value),
        .fsk => {},
    };

    try std.testing.expectEqual(@as(u32, 4), selected.delay_s);
    try std.testing.expectEqual(@as(f64, 868.1), selected.freq);
    try std.testing.expectEqual(@as(u32, 50_000), selected.datr.fsk);
}

test "currentLinkMetrics only exposes device time when tmms is present" {
    const with_tmms = packets.Rxpk{
        .tmst = 1,
        .freq = 868.1,
        .datr = .{ .lora = try std.testing.allocator.dupe(u8, "SF7BW125") },
        .codr = try std.testing.allocator.dupe(u8, "4/5"),
        .data = try std.testing.allocator.alloc(u8, 0),
        .time = null,
        .tmms = 1234,
        .rssi = null,
        .lsnr = null,
    };
    defer with_tmms.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?i64, 1234), currentLinkMetrics(with_tmms).rx_time_ms);

    const without_tmms = packets.Rxpk{
        .tmst = 1,
        .freq = 868.1,
        .datr = .{ .lora = try std.testing.allocator.dupe(u8, "SF7BW125") },
        .codr = try std.testing.allocator.dupe(u8, "4/5"),
        .data = try std.testing.allocator.alloc(u8, 0),
        .time = null,
        .tmms = null,
        .rssi = null,
        .lsnr = null,
    };
    defer without_tmms.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?i64, null), currentLinkMetrics(without_tmms).rx_time_ms);
}
