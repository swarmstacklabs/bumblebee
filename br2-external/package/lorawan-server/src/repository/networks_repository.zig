const std = @import("std");

const app_mod = @import("../app.zig");
const crud_repository = @import("crud_repository.zig");
const storage = @import("../storage.zig");
const Database = app_mod.Database;
const ListParams = crud_repository.ListParams;
const SortOrder = crud_repository.SortOrder;

pub const Record = struct {
    id: i64,
    name: []u8,
    network_json: []u8,
    created_at: []u8,
    updated_at: []u8,

    pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.network_json);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
    }
};

pub const WriteInput = struct {
    name: []const u8,
    network_json: []const u8,

    pub fn deinit(self: WriteInput, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.network_json);
    }
};

pub const CRUDRepository = crud_repository.Interface(Record, WriteInput, []const u8);

pub const Repository = struct {
    db: Database,

    pub fn init(db: Database) Repository {
        return .{ .db = db };
    }

    pub fn deinit(_: Repository) void {}

    pub fn list(self: Repository, allocator: std.mem.Allocator, params: ListParams) !CRUDRepository.Page {
        self.db.mutex.lock();
        defer self.db.mutex.unlock();

        const total_entries = try countNetworks(self.db.conn);
        const sort_column = try sqlSortColumn(params.sort_by);
        const sort_direction = sqlSortDirection(params.sort_order);

        var sql_buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrint(
            &sql_buf,
            "SELECT id, name, network_json, created_at, updated_at " ++
                "FROM networks ORDER BY {s} {s}, id {s} LIMIT ? OFFSET ?;",
            .{ sort_column, sort_direction, sort_direction },
        );
        const stmt = try storage.Statement.prepare(self.db.conn, sql);
        defer stmt.deinit();

        stmt.bindInt64(1, params.page_size);
        stmt.bindInt64(2, params.offset());

        var out = std.ArrayList(Record){};
        errdefer {
            for (out.items) |*item| item.deinit(allocator);
            out.deinit(allocator);
        }

        while (stmt.step() == storage.c.SQLITE_ROW) {
            try out.append(allocator, .{
                .id = stmt.readInt64(0),
                .name = try allocator.dupe(u8, stmt.readText(1) orelse ""),
                .network_json = try allocator.dupe(u8, stmt.readText(2) orelse "{}"),
                .created_at = try allocator.dupe(u8, stmt.readText(3) orelse ""),
                .updated_at = try allocator.dupe(u8, stmt.readText(4) orelse ""),
            });
        }

        return CRUDRepository.Page.init(try out.toOwnedSlice(allocator), params, total_entries);
    }

    pub fn get(self: Repository, allocator: std.mem.Allocator, name: []const u8) !?Record {
        self.db.mutex.lock();
        defer self.db.mutex.unlock();

        const sql = "SELECT id, name, network_json, created_at, updated_at FROM networks WHERE name = ?;";
        const stmt = try storage.Statement.prepare(self.db.conn, sql);
        defer stmt.deinit();

        stmt.bindText(1, name);
        if (stmt.step() != storage.c.SQLITE_ROW) return null;
        return .{
            .id = stmt.readInt64(0),
            .name = try allocator.dupe(u8, stmt.readText(1) orelse ""),
            .network_json = try allocator.dupe(u8, stmt.readText(2) orelse "{}"),
            .created_at = try allocator.dupe(u8, stmt.readText(3) orelse ""),
            .updated_at = try allocator.dupe(u8, stmt.readText(4) orelse ""),
        };
    }

    pub fn create(self: Repository, write_input: WriteInput) !void {
        self.db.mutex.lock();
        defer self.db.mutex.unlock();

        const sql = "INSERT INTO networks(name, network_json, updated_at) VALUES(?, ?, CURRENT_TIMESTAMP);";
        const stmt = try storage.Statement.prepare(self.db.conn, sql);
        defer stmt.deinit();

        stmt.bindText(1, write_input.name);
        stmt.bindText(2, write_input.network_json);
        stmt.expectDone() catch return error.NetworkCreateFailed;
    }

    pub fn update(self: Repository, name: []const u8, write_input: WriteInput) !bool {
        self.db.mutex.lock();
        defer self.db.mutex.unlock();

        const sql =
            "UPDATE networks SET name = ?, network_json = ?, updated_at = CURRENT_TIMESTAMP " ++
            "WHERE name = ?;";
        const stmt = try storage.Statement.prepare(self.db.conn, sql);
        defer stmt.deinit();

        stmt.bindText(1, write_input.name);
        stmt.bindText(2, write_input.network_json);
        stmt.bindText(3, name);
        stmt.expectDone() catch return error.NetworkUpdateFailed;
        return storage.changes(self.db.conn) != 0;
    }

    pub fn delete(self: Repository, name: []const u8) !bool {
        self.db.mutex.lock();
        defer self.db.mutex.unlock();

        const sql = "DELETE FROM networks WHERE name = ?;";
        const stmt = try storage.Statement.prepare(self.db.conn, sql);
        defer stmt.deinit();

        stmt.bindText(1, name);
        stmt.expectDone() catch return error.NetworkDeleteFailed;
        return storage.changes(self.db.conn) != 0;
    }
};

pub fn crud(db: Database) CRUDRepository {
    return CRUDRepository.bind(Repository, db);
}

fn countNetworks(conn: *storage.c.sqlite3) !usize {
    const stmt = try storage.Statement.prepare(conn, "SELECT COUNT(*) FROM networks;");
    defer stmt.deinit();

    try stmt.expectRow();
    return @intCast(stmt.readInt64(0));
}

fn sqlSortColumn(sort_by: []const u8) ![]const u8 {
    if (std.mem.eql(u8, sort_by, "id")) return "id";
    if (std.mem.eql(u8, sort_by, "name")) return "name";
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
