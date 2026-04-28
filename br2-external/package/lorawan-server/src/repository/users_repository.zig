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
    scopes: [][]u8,
    email: []const u8 = "",
    send_alerts: bool = false,
    created_at: []u8,
    updated_at: []u8,

    pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.scopes) |scope| allocator.free(scope);
        allocator.free(self.scopes);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
    }
};

pub const ScopeRecord = struct {
    scope: []const u8,
};

pub const Page = crud_repository.ListPage(Record);
pub const ScopePage = crud_repository.ListPage(ScopeRecord);

const all_scopes = [_]ScopeRecord{
    .{ .scope = "admin" },
    .{ .scope = "read" },
    .{ .scope = "write" },
};

pub const Repository = struct {
    db: Database,

    pub fn init(db: Database) Repository {
        return .{ .db = db };
    }

    pub fn list(self: Repository, allocator: std.mem.Allocator, params: ListParams) !Page {
        self.db.mutex.lock();
        defer self.db.mutex.unlock();

        const total_entries = try countUsers(self.db.conn);
        const sort_column = try sqlSortColumn(params.sort_by);
        const sort_direction = sqlSortDirection(params.sort_order);

        var sql_buf: [320]u8 = undefined;
        const sql = try std.fmt.bufPrint(
            &sql_buf,
            "SELECT id, name, scope_json, created_at, updated_at " ++
                "FROM users ORDER BY {s} {s}, id {s} LIMIT ? OFFSET ?;",
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
                .scopes = try parseScopes(allocator, stmt.readText(2) orelse "[]"),
                .created_at = try allocator.dupe(u8, stmt.readText(3) orelse ""),
                .updated_at = try allocator.dupe(u8, stmt.readText(4) orelse ""),
            });
        }

        return Page.init(try out.toOwnedSlice(allocator), params, total_entries);
    }

    pub fn get(self: Repository, allocator: std.mem.Allocator, name: []const u8) !?Record {
        self.db.mutex.lock();
        defer self.db.mutex.unlock();

        const sql = "SELECT id, name, scope_json, created_at, updated_at FROM users WHERE name = ?;";
        const stmt = try storage.Statement.prepare(self.db.conn, sql);
        defer stmt.deinit();

        stmt.bindText(1, name);
        if (stmt.step() != storage.c.SQLITE_ROW) return null;

        return .{
            .id = stmt.readInt64(0),
            .name = try allocator.dupe(u8, stmt.readText(1) orelse ""),
            .scopes = try parseScopes(allocator, stmt.readText(2) orelse "[]"),
            .created_at = try allocator.dupe(u8, stmt.readText(3) orelse ""),
            .updated_at = try allocator.dupe(u8, stmt.readText(4) orelse ""),
        };
    }
};

pub fn scopesPage(params: ListParams) ScopePage {
    const start = @min(params.offset(), all_scopes.len);
    const end = @min(start + params.page_size, all_scopes.len);
    return ScopePage.init(@constCast(all_scopes[start..end]), params, all_scopes.len);
}

fn countUsers(conn: *storage.c.sqlite3) !usize {
    const stmt = try storage.Statement.prepare(conn, "SELECT COUNT(*) FROM users;");
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

fn parseScopes(allocator: std.mem.Allocator, scope_json: []const u8) ![][]u8 {
    const parsed = std.json.parseFromSlice([]const []const u8, allocator, scope_json, .{}) catch {
        return allocator.alloc([]u8, 0);
    };
    defer parsed.deinit();

    var out = try allocator.alloc([]u8, parsed.value.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |scope| allocator.free(scope);
        allocator.free(out);
    }
    for (parsed.value, 0..) |scope, index| {
        out[index] = try allocator.dupe(u8, scope);
        initialized += 1;
    }
    return out;
}
