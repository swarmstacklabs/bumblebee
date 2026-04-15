const std = @import("std");

const app_mod = @import("../app.zig");
const packets = @import("packets.zig");
const codec = @import("codec.zig");
const commands = @import("commands.zig");
const mac_handlers = @import("handlers/mac_handlers.zig");
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
            @intCast(network.rx1_delay_s),
            null,
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

        var downlink: ?packets.DownlinkRequest = null;
        const response_commands = try codec.buildMacResponses(allocator, parsed, rxTimeMs(rxpk), 1);
        defer allocator.free(response_commands);

        if (response_commands.len > 0 or parsed.confirmed) {
            const f_opts = if (response_commands.len > 0)
                try commands.encodeFOpts(allocator, response_commands)
            else
                try allocator.alloc(u8, 0);
            defer allocator.free(f_opts);
            const phy = try codec.encodeUnicast(allocator, &node, .{}, f_opts, parsed.confirmed, parsed.adr);
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
        } else if (node.pending_confirmed_downlink) |pending_phy| {
            if (node.confirmed_downlink_retries > 0) {
                const dev_addr_hex = try state_repository.hexString(allocator, &node.dev_addr);
                node.confirmed_downlink_retries -= 1;
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
                    .phy_payload = try allocator.dupe(u8, pending_phy),
                };
            } else {
                clearPendingConfirmedDownlink(allocator, &node);
            }
        }

        if (codec.collectMacCommands(allocator, parsed)) |status_commands| {
            defer allocator.free(status_commands);
            const pending_commands = try parsePendingCommands(allocator, node.pending_mac_commands);
            defer allocator.free(pending_commands);

            const remaining_pending = try mac_handlers.applyToNode(allocator, &node, pending_commands, status_commands);
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
