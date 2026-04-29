const std = @import("std");

const app_mod = @import("../app.zig");
const crud_repository = @import("crud_repository.zig");
const Statement = @import("../db.zig").Statement;
const StorageContext = app_mod.StorageContext;
const DeviceRecord = app_mod.DeviceRecord;
const DeviceWriteInput = app_mod.DeviceWriteInput;
const ListParams = crud_repository.ListParams;
const SortOrder = crud_repository.SortOrder;

pub const CRUDRepository = crud_repository.Interface(DeviceRecord, DeviceWriteInput, i64);

pub const Repository = struct {
    storage: StorageContext,

    pub fn init(storage: StorageContext) Repository {
        return .{ .storage = storage };
    }

    pub fn deinit(_: Repository) void {}

    pub fn list(self: Repository, allocator: std.mem.Allocator, params: ListParams) !CRUDRepository.Page {
        self.storage.lock();
        defer self.storage.unlock();

        const total_entries = try countDevices(self.storage);
        const sort_column = try sqlSortColumn(params.sort_by);
        const sort_direction = sqlSortDirection(params.sort_order);

        var sql_buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrint(
            &sql_buf,
            "SELECT id, name, dev_eui, app_eui, app_key, created_at, updated_at " ++
                "FROM devices ORDER BY {s} {s}, id {s} LIMIT ? OFFSET ?;",
            .{ sort_column, sort_direction, sort_direction },
        );
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();

        stmt.bindInt64(1, params.page_size);
        stmt.bindInt64(2, params.offset());

        var out = std.ArrayList(DeviceRecord){};
        errdefer {
            for (out.items) |item| item.deinit(allocator);
            out.deinit(allocator);
        }

        while (stmt.step() == .row) {
            try out.append(allocator, try rowToDevice(allocator, stmt));
        }

        return CRUDRepository.Page.init(try out.toOwnedSlice(allocator), params, total_entries);
    }

    pub fn get(self: Repository, allocator: std.mem.Allocator, id: i64) !?DeviceRecord {
        self.storage.lock();
        defer self.storage.unlock();

        const sql = "SELECT id, name, dev_eui, app_eui, app_key, created_at, updated_at FROM devices WHERE id = ?;";
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();

        stmt.bindInt64(1, id);
        if (stmt.step() != .row) return null;

        return try rowToDevice(allocator, stmt);
    }

    pub fn create(self: Repository, write_input: DeviceWriteInput) !void {
        self.storage.lock();
        defer self.storage.unlock();

        const sql = "INSERT INTO devices(name, dev_eui, app_eui, app_key) VALUES(?, ?, ?, ?);";
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();

        stmt.bindText(1, write_input.name);
        stmt.bindText(2, write_input.dev_eui);
        stmt.bindText(3, write_input.app_eui);
        stmt.bindText(4, write_input.app_key);

        stmt.expectDone() catch return error.DeviceCreateFailed;
    }

    pub fn update(self: Repository, id: i64, write_input: DeviceWriteInput) !bool {
        self.storage.lock();
        defer self.storage.unlock();

        const sql =
            "UPDATE devices " ++
            "SET name = ?, dev_eui = ?, app_eui = ?, app_key = ?, updated_at = CURRENT_TIMESTAMP " ++
            "WHERE id = ?;";
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();

        stmt.bindText(1, write_input.name);
        stmt.bindText(2, write_input.dev_eui);
        stmt.bindText(3, write_input.app_eui);
        stmt.bindText(4, write_input.app_key);
        stmt.bindInt64(5, id);

        stmt.expectDone() catch return error.DeviceUpdateFailed;
        return self.storage.changes() != 0;
    }

    pub fn delete(self: Repository, id: i64) !bool {
        self.storage.lock();
        defer self.storage.unlock();

        const sql = "DELETE FROM devices WHERE id = ?;";
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();

        stmt.bindInt64(1, id);
        stmt.expectDone() catch return error.DeviceDeleteFailed;
        return self.storage.changes() != 0;
    }
};

pub fn crud(storage: StorageContext) CRUDRepository {
    return CRUDRepository.bind(Repository, storage);
}

fn countDevices(storage: StorageContext) !usize {
    const stmt = try storage.prepare("SELECT COUNT(*) FROM devices;");
    defer stmt.deinit();

    try stmt.expectRow();
    return @as(usize, @intCast(stmt.readInt64(0)));
}

fn sqlSortColumn(sort_by: []const u8) ![]const u8 {
    if (std.mem.eql(u8, sort_by, "id")) return "id";
    if (std.mem.eql(u8, sort_by, "name")) return "name";
    if (std.mem.eql(u8, sort_by, "dev_eui")) return "dev_eui";
    if (std.mem.eql(u8, sort_by, "app_eui")) return "app_eui";
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

fn rowToDevice(allocator: std.mem.Allocator, stmt: Statement) !DeviceRecord {
    return DeviceRecord.init(
        stmt.readInt64(0),
        try dupColumnText(allocator, stmt, 1),
        try dupColumnText(allocator, stmt, 2),
        try dupColumnText(allocator, stmt, 3),
        try dupColumnText(allocator, stmt, 4),
        try dupColumnText(allocator, stmt, 5),
        try dupColumnText(allocator, stmt, 6),
    );
}

fn dupColumnText(allocator: std.mem.Allocator, stmt: Statement, column: c_int) ![]u8 {
    const value = stmt.readText(column) orelse return allocator.alloc(u8, 0);
    return allocator.dupe(u8, value);
}
