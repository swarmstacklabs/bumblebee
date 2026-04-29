const std = @import("std");

const app_mod = @import("../app.zig");
const crud_repository = @import("crud_repository.zig");

const StorageContext = app_mod.StorageContext;
const ListParams = crud_repository.ListParams;
const SortOrder = crud_repository.SortOrder;

pub const Record = struct {
    evid: i64,
    datetime: []u8,
    last_rx: []u8,
    severity: []const u8 = "info",
    entity: []u8,
    eid: []u8,
    text: []u8,
    args: []u8,

    pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        allocator.free(self.datetime);
        allocator.free(self.last_rx);
        allocator.free(self.entity);
        allocator.free(self.eid);
        allocator.free(self.text);
        allocator.free(self.args);
    }
};

pub const Page = crud_repository.ListPage(Record);

pub const Repository = struct {
    storage: StorageContext,

    pub fn init(storage: StorageContext) Repository {
        return .{ .storage = storage };
    }

    pub fn list(self: Repository, allocator: std.mem.Allocator, params: ListParams) !Page {
        self.storage.lock();
        defer self.storage.unlock();

        const total_entries = try countEvents(self.storage);
        const sort_column = try sqlSortColumn(params.sort_by);
        const sort_direction = sqlSortDirection(params.sort_order);

        var sql_buf: [384]u8 = undefined;
        const sql = try std.fmt.bufPrint(
            &sql_buf,
            "SELECT id, created_at, event_type, entity_type, entity_id, payload_json " ++
                "FROM events ORDER BY {s} {s}, id {s} LIMIT ? OFFSET ?;",
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
            const created_at = stmt.readText(1) orelse "";
            try out.append(allocator, .{
                .evid = stmt.readInt64(0),
                .datetime = try allocator.dupe(u8, created_at),
                .last_rx = try allocator.dupe(u8, created_at),
                .entity = try allocator.dupe(u8, stmt.readText(3) orelse ""),
                .eid = try allocator.dupe(u8, stmt.readText(4) orelse ""),
                .text = try allocator.dupe(u8, stmt.readText(2) orelse ""),
                .args = try allocator.dupe(u8, stmt.readText(5) orelse "{}"),
            });
        }

        return Page.init(try out.toOwnedSlice(allocator), params, total_entries);
    }
};

fn countEvents(storage: StorageContext) !usize {
    const stmt = try storage.prepare("SELECT COUNT(*) FROM events;");
    defer stmt.deinit();

    try stmt.expectRow();
    return @intCast(stmt.readInt64(0));
}

fn sqlSortColumn(sort_by: []const u8) ![]const u8 {
    if (std.mem.eql(u8, sort_by, "id") or std.mem.eql(u8, sort_by, "evid")) return "id";
    if (std.mem.eql(u8, sort_by, "datetime") or std.mem.eql(u8, sort_by, "last_rx")) return "created_at";
    if (std.mem.eql(u8, sort_by, "text") or std.mem.eql(u8, sort_by, "severity")) return "event_type";
    if (std.mem.eql(u8, sort_by, "entity")) return "entity_type";
    if (std.mem.eql(u8, sort_by, "eid")) return "entity_id";
    if (std.mem.eql(u8, sort_by, "args")) return "payload_json";
    return error.BadRequest;
}

fn sqlSortDirection(sort_order: SortOrder) []const u8 {
    return switch (sort_order) {
        .asc => "ASC",
        .desc => "DESC",
    };
}
