const std = @import("std");

const app_mod = @import("../app.zig");
const crud_repository = @import("crud_repository.zig");
const db_mod = @import("../db.zig");
const StorageContext = db_mod.StorageContext;
const ListParams = crud_repository.ListParams;
const SortOrder = crud_repository.SortOrder;

pub const Record = struct {
    id: i64,
    mac: []u8,
    name: []u8,
    network_name: []u8,
    tx_rfch: u8,
    created_at: []u8,
    updated_at: []u8,

    pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        allocator.free(self.mac);
        allocator.free(self.name);
        allocator.free(self.network_name);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
    }
};

pub const WriteInput = struct {
    mac: []const u8,
    name: []const u8,
    network_name: []const u8,
    tx_rfch: u8 = 0,

    pub fn deinit(self: WriteInput, allocator: std.mem.Allocator) void {
        allocator.free(self.mac);
        allocator.free(self.name);
        allocator.free(self.network_name);
    }
};

pub const CRUDRepository = crud_repository.interface(Record, WriteInput, []const u8);

pub const Repository = struct {
    storage: StorageContext,

    pub fn init(storage: StorageContext) Repository {
        return .{ .storage = storage };
    }

    pub fn deinit(_: Repository) void {}

    pub fn list(self: Repository, allocator: std.mem.Allocator, params: ListParams) !CRUDRepository.Page {
        self.storage.lock();
        defer self.storage.unlock();

        const total_entries = try countGateways(self.storage);
        const sort_column = try sqlSortColumn(params.sort_by);
        const sort_direction = sqlSortDirection(params.sort_order);

        var sql_buf: [320]u8 = undefined;
        const sql = try std.fmt.bufPrint(
            &sql_buf,
            "SELECT id, mac, name, network_name, gateway_json, created_at, updated_at " ++
                "FROM gateways ORDER BY {s} {s}, id {s} LIMIT ? OFFSET ?;",
            .{ sort_column, sort_direction, sort_direction },
        );
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();

        stmt.bindInt64(1, params.page_size);
        stmt.bindInt64(2, params.offset());

        var out = std.ArrayList(Record){};
        errdefer {
            for (out.items) |*item| item.deinit(allocator);
            out.deinit(allocator);
        }

        while (stmt.step() == .row) {
            try out.append(allocator, try rowToRecord(allocator, stmt));
        }

        return CRUDRepository.Page.init(try out.toOwnedSlice(allocator), params, total_entries);
    }

    pub fn get(self: Repository, allocator: std.mem.Allocator, mac: []const u8) !?Record {
        self.storage.lock();
        defer self.storage.unlock();

        const sql = "SELECT id, mac, name, network_name, gateway_json, created_at, updated_at FROM gateways WHERE lower(mac) = lower(?);";
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();

        stmt.bindText(1, mac);
        if (stmt.step() != .row) return null;
        return try rowToRecord(allocator, stmt);
    }

    pub fn create(self: Repository, write_input: WriteInput) !void {
        self.storage.lock();
        defer self.storage.unlock();

        const gateway_json = try encodeGatewayJson(self.storage.allocator, write_input.tx_rfch);
        defer self.storage.allocator.free(gateway_json);

        const sql = "INSERT INTO gateways(mac, name, network_name, gateway_json, updated_at) VALUES(?, ?, ?, ?, CURRENT_TIMESTAMP);";
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();

        stmt.bindText(1, write_input.mac);
        stmt.bindText(2, write_input.name);
        stmt.bindText(3, write_input.network_name);
        stmt.bindText(4, gateway_json);

        stmt.expectDone() catch return error.GatewayCreateFailed;
    }

    pub fn update(self: Repository, mac: []const u8, write_input: WriteInput) !bool {
        self.storage.lock();
        defer self.storage.unlock();

        const gateway_json = try encodeGatewayJson(self.storage.allocator, write_input.tx_rfch);
        defer self.storage.allocator.free(gateway_json);

        const sql =
            "UPDATE gateways " ++
            "SET mac = ?, name = ?, network_name = ?, gateway_json = ?, updated_at = CURRENT_TIMESTAMP " ++
            "WHERE lower(mac) = lower(?);";
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();

        stmt.bindText(1, write_input.mac);
        stmt.bindText(2, write_input.name);
        stmt.bindText(3, write_input.network_name);
        stmt.bindText(4, gateway_json);
        stmt.bindText(5, mac);

        stmt.expectDone() catch return error.GatewayUpdateFailed;
        return self.storage.changes() != 0;
    }

    pub fn delete(self: Repository, mac: []const u8) !bool {
        self.storage.lock();
        defer self.storage.unlock();

        const sql = "DELETE FROM gateways WHERE lower(mac) = lower(?);";
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();

        stmt.bindText(1, mac);
        stmt.expectDone() catch return error.GatewayDeleteFailed;
        return self.storage.changes() != 0;
    }
};

pub fn crud(storage: StorageContext) CRUDRepository {
    return CRUDRepository.bind(Repository, storage);
}

fn countGateways(storage: StorageContext) !usize {
    const stmt = try storage.prepare("SELECT COUNT(*) FROM gateways;");
    defer stmt.deinit();

    try stmt.expectRow();
    return @intCast(stmt.readInt64(0));
}

fn sqlSortColumn(sort_by: []const u8) ![]const u8 {
    if (std.mem.eql(u8, sort_by, "id")) return "id";
    if (std.mem.eql(u8, sort_by, "mac")) return "mac";
    if (std.mem.eql(u8, sort_by, "name")) return "name";
    if (std.mem.eql(u8, sort_by, "network_name")) return "network_name";
    if (std.mem.eql(u8, sort_by, "created_at")) return "created_at";
    if (std.mem.eql(u8, sort_by, "updated_at")) return "updated_at";
    return error.BadRequest;
}

fn sqlSortDirection(sort_order: SortOrder) []const u8 {
    return switch (sort_order) {
        .asc => "ASC",
        .desc => "DESC",
    };
}

fn rowToRecord(allocator: std.mem.Allocator, stmt: db_mod.Statement) !Record {
    return .{
        .id = stmt.readInt64(0),
        .mac = try allocator.dupe(u8, stmt.readText(1) orelse ""),
        .name = try allocator.dupe(u8, stmt.readText(2) orelse ""),
        .network_name = try allocator.dupe(u8, stmt.readText(3) orelse ""),
        .tx_rfch = parseTxRfch(allocator, stmt.readText(4) orelse "{}"),
        .created_at = try allocator.dupe(u8, stmt.readText(5) orelse ""),
        .updated_at = try allocator.dupe(u8, stmt.readText(6) orelse ""),
    };
}

fn encodeGatewayJson(allocator: std.mem.Allocator, tx_rfch: u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{ .tx_rfch = tx_rfch }, .{});
}

fn parseTxRfch(allocator: std.mem.Allocator, gateway_json: []const u8) u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, gateway_json, .{
        .ignore_unknown_fields = true,
    }) catch return 0;
    defer parsed.deinit();

    const value = parsed.value.object.get("tx_rfch") orelse return 0;
    return switch (value) {
        .integer => |number| @intCast(std.math.clamp(number, 0, std.math.maxInt(u8))),
        else => 0,
    };
}
