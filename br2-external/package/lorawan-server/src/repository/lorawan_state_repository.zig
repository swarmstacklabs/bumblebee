const std = @import("std");

const app_mod = @import("../app.zig");
const storage = @import("../storage.zig");
const types = @import("../lorawan/types.zig");
const Database = app_mod.Database;

pub const Repository = struct {
    db: Database,

    pub fn init(db: Database) Repository {
        return .{ .db = db };
    }

    pub fn deinit(_: Repository) void {}

    pub fn loadGateway(self: Repository, allocator: std.mem.Allocator, gateway_mac_hex: []const u8) !?types.Gateway {
        self.db.mutex.lock();
        defer self.db.mutex.unlock();

        const sql = "SELECT mac, network_name, gateway_json FROM gateways WHERE lower(mac) = lower(?);";
        const stmt = try storage.Statement.prepare(self.db.conn, sql);
        defer stmt.deinit();
        stmt.bindText(1, gateway_mac_hex);
        if (stmt.step() != storage.c.SQLITE_ROW) return null;

        const network_name = stmt.readText(1) orelse return null;
        const gateway_json = stmt.readText(2) orelse "{}";
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, gateway_json, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        return types.Gateway.init(
            try parseHexArray(8, stmt.readText(0).?),
            jsonOptionalU8(parsed.value.object, "tx_rfch") orelse 0,
            try allocator.dupe(u8, network_name),
        );
    }

    pub fn loadNetworkByName(self: Repository, allocator: std.mem.Allocator, name: []const u8) !?types.Network {
        self.db.mutex.lock();
        defer self.db.mutex.unlock();

        const sql = "SELECT name, network_json FROM networks WHERE name = ?;";
        const stmt = try storage.Statement.prepare(self.db.conn, sql);
        defer stmt.deinit();
        stmt.bindText(1, name);
        if (stmt.step() != storage.c.SQLITE_ROW) return null;

        const json_text = stmt.readText(1) orelse "{}";
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const object = parsed.value.object;

        return types.Network.init(
            try allocator.dupe(u8, stmt.readText(0).?),
            try parseHexArray(3, try jsonRequiredString(object, "netid")),
            try allocator.dupe(u8, jsonOptionalString(object, "tx_codr") orelse "4/5"),
            jsonOptionalU32(object, "join1_delay") orelse 5,
            jsonOptionalU32(object, "rx1_delay") orelse 1,
            jsonOptionalI32(object, "gw_power") orelse 14,
            parseRxWindow(object.get("rxwin_init")),
        );
    }

    pub fn findDeviceByDevEui(self: Repository, allocator: std.mem.Allocator, dev_eui: [8]u8) !?types.Device {
        const dev_eui_hex = try hexString(allocator, &dev_eui);
        defer allocator.free(dev_eui_hex);

        self.db.mutex.lock();
        defer self.db.mutex.unlock();

        const sql = "SELECT id, name, dev_eui, app_eui, app_key, device_json FROM devices WHERE lower(dev_eui) = lower(?);";
        const stmt = try storage.Statement.prepare(self.db.conn, sql);
        defer stmt.deinit();
        stmt.bindText(1, dev_eui_hex);
        if (stmt.step() != storage.c.SQLITE_ROW) return null;

        const json_text = stmt.readText(5) orelse "{}";
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const object = parsed.value.object;

        return types.Device.init(
            stmt.readInt64(0),
            try allocator.dupe(u8, stmt.readText(1).?),
            try parseHexArray(8, stmt.readText(2).?),
            try parseHexArray(8, stmt.readText(3).?),
            try parseHexArray(16, stmt.readText(4).?),
            if (jsonOptionalString(object, "network_name")) |value| try allocator.dupe(u8, value) else null,
            if (jsonOptionalString(object, "dev_addr")) |value| try parseHexArray(4, value) else null,
        );
    }

    pub fn findNodeByDevAddr(self: Repository, allocator: std.mem.Allocator, dev_addr: [4]u8) !?types.Node {
        const dev_addr_hex = try hexString(allocator, &dev_addr);
        defer allocator.free(dev_addr_hex);

        self.db.mutex.lock();
        defer self.db.mutex.unlock();

        const sql = "SELECT id, device_id, node_json FROM nodes WHERE lower(dev_addr) = lower(?);";
        const stmt = try storage.Statement.prepare(self.db.conn, sql);
        defer stmt.deinit();
        stmt.bindText(1, dev_addr_hex);
        if (stmt.step() != storage.c.SQLITE_ROW) return null;

        const json_text = stmt.readText(2) orelse "{}";
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const object = parsed.value.object;

        var node = types.Node.init(
            dev_addr,
            try parseHexArray(16, try jsonRequiredString(object, "appskey")),
            try parseHexArray(16, try jsonRequiredString(object, "nwkskey")),
            parseRxWindow(object.get("rxwin_use")),
            types.AdrConfig.init(
                jsonOptionalI32(object, "adr_tx_power") orelse 14,
                jsonOptionalU8(object, "adr_data_rate") orelse 0,
            ),
        );
        node.id = stmt.readInt64(0);
        node.device_id = if (stmt.columnType(1) == storage.c.SQLITE_NULL) null else stmt.readInt64(1);
        node.dev_eui = if (jsonOptionalString(object, "dev_eui")) |value| try parseHexArray(8, value) else null;
        node.f_cnt_up = jsonOptionalU32(object, "fcntup");
        node.f_cnt_down = jsonOptionalU32(object, "fcntdown") orelse 0;
        node.last_battery = jsonOptionalU8(object, "last_battery");
        node.last_dev_status_margin = jsonOptionalI8(object, "last_margin");
        node.pending_mac_commands = if (jsonOptionalString(object, "pending_mac_commands")) |value| try parseHexSlice(allocator, value) else null;
        return node;
    }

    pub fn upsertNode(self: Repository, allocator: std.mem.Allocator, node: types.Node) !void {
        const node_json = try encodeNodeJson(allocator, node);
        defer allocator.free(node_json);
        const dev_addr_hex = try hexString(allocator, &node.dev_addr);
        defer allocator.free(dev_addr_hex);
        const device_id = node.device_id;

        self.db.mutex.lock();
        defer self.db.mutex.unlock();

        const sql =
            "INSERT INTO nodes(dev_addr, device_id, node_json) VALUES(?, ?, ?) " ++
            "ON CONFLICT(dev_addr) DO UPDATE SET device_id = excluded.device_id, node_json = excluded.node_json, updated_at = CURRENT_TIMESTAMP;";
        const stmt = try storage.Statement.prepare(self.db.conn, sql);
        defer stmt.deinit();
        stmt.bindText(1, dev_addr_hex);
        if (device_id) |value| stmt.bindInt64(2, value) else stmt.bindNull(2);
        stmt.bindText(3, node_json);
        try stmt.expectDone();
    }

    pub fn createNodeForJoin(self: Repository, allocator: std.mem.Allocator, device: types.Device, network: types.Network, dev_addr: [4]u8, app_s_key: [16]u8, nwk_s_key: [16]u8) !types.Node {
        var node = types.Node.init(dev_addr, app_s_key, nwk_s_key, network.rxwin_init, types.AdrConfig.init(network.gw_power, 0));
        node.device_id = device.id;
        node.dev_eui = device.dev_eui;
        try self.upsertNode(allocator, node);
        return (try self.findNodeByDevAddr(allocator, dev_addr)).?;
    }
};

fn encodeNodeJson(allocator: std.mem.Allocator, node: types.Node) ![]u8 {
    const app_s_key = try hexString(allocator, &node.app_s_key);
    defer allocator.free(app_s_key);
    const nwk_s_key = try hexString(allocator, &node.nwk_s_key);
    defer allocator.free(nwk_s_key);

    const dev_eui = if (node.dev_eui) |value| try hexString(allocator, &value) else null;
    defer if (dev_eui) |value| allocator.free(value);
    const pending_mac_commands = if (node.pending_mac_commands) |value| try hexString(allocator, value) else null;
    defer if (pending_mac_commands) |value| allocator.free(value);

    return std.json.Stringify.valueAlloc(allocator, .{
        .appskey = app_s_key,
        .nwkskey = nwk_s_key,
        .dev_eui = dev_eui,
        .fcntup = node.f_cnt_up,
        .fcntdown = node.f_cnt_down,
        .rxwin_use = .{
            .rx1_dr_offset = node.rxwin_use.rx1_dr_offset,
            .rx2_data_rate = node.rxwin_use.rx2_data_rate,
            .frequency = node.rxwin_use.frequency,
        },
        .adr_tx_power = node.adr_use.tx_power,
        .adr_data_rate = node.adr_use.data_rate,
        .last_battery = node.last_battery,
        .last_margin = node.last_dev_status_margin,
        .pending_mac_commands = pending_mac_commands,
    }, .{});
}

fn parseRxWindow(value: ?std.json.Value) types.RxWindowConfig {
    const root = value orelse return types.RxWindowConfig.init(0, 0, 869.525);
    if (root != .object) return types.RxWindowConfig.init(0, 0, 869.525);
    return types.RxWindowConfig.init(
        jsonOptionalU8(root.object, "rx1_dr_offset") orelse 0,
        jsonOptionalU8(root.object, "rx2_data_rate") orelse 0,
        jsonOptionalF64(root.object, "frequency") orelse 869.525,
    );
}

fn jsonRequiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.MissingJsonField;
    if (value != .string) return error.InvalidJsonField;
    return value.string;
}

fn jsonOptionalString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn jsonOptionalU32(object: std.json.ObjectMap, key: []const u8) ?u32 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |num| @intCast(num),
        else => null,
    };
}

fn jsonOptionalU8(object: std.json.ObjectMap, key: []const u8) ?u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |num| @intCast(num),
        else => null,
    };
}

fn jsonOptionalI8(object: std.json.ObjectMap, key: []const u8) ?i8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |num| @intCast(num),
        else => null,
    };
}

fn jsonOptionalI32(object: std.json.ObjectMap, key: []const u8) ?i32 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |num| @intCast(num),
        else => null,
    };
}

fn jsonOptionalF64(object: std.json.ObjectMap, key: []const u8) ?f64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .float => |num| num,
        .integer => |num| @floatFromInt(num),
        else => null,
    };
}

pub fn parseHexArray(comptime len: usize, text: []const u8) ![len]u8 {
    if (text.len != len * 2) return error.InvalidHexLength;
    var out: [len]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, text);
    return out;
}

pub fn parseHexSlice(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if ((text.len % 2) != 0) return error.InvalidHexLength;
    const out = try allocator.alloc(u8, text.len / 2);
    errdefer allocator.free(out);
    _ = try std.fmt.hexToBytes(out, text);
    return out;
}

pub fn hexString(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, bytes.len * 2);
    const charset = "0123456789abcdef";
    for (bytes, 0..) |byte, index| {
        out[index * 2] = charset[byte >> 4];
        out[index * 2 + 1] = charset[byte & 0x0F];
    }
    return out;
}
