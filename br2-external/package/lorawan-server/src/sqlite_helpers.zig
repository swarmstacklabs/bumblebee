const std = @import("std");

const app_mod = @import("app.zig");
pub const c = app_mod.c;

pub const Statement = struct {
    raw: *c.sqlite3_stmt,

    pub fn prepare(db: *c.sqlite3, sql: []const u8) !Statement {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql.ptr, @as(c_int, @intCast(sql.len)), &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        return .{ .raw = stmt.? };
    }

    pub fn deinit(self: Statement) void {
        _ = c.sqlite3_finalize(self.raw);
    }

    pub fn bindText(self: Statement, index: c_int, value: []const u8) void {
        _ = c.sqlite3_bind_text(self.raw, index, value.ptr, @as(c_int, @intCast(value.len)), null);
    }

    pub fn bindInt(self: Statement, index: c_int, value: anytype) void {
        _ = c.sqlite3_bind_int(self.raw, index, @as(c_int, @intCast(value)));
    }

    pub fn bindInt64(self: Statement, index: c_int, value: anytype) void {
        _ = c.sqlite3_bind_int64(self.raw, index, @as(c.sqlite3_int64, @intCast(value)));
    }

    pub fn bindNull(self: Statement, index: c_int) void {
        _ = c.sqlite3_bind_null(self.raw, index);
    }

    pub fn step(self: Statement) c_int {
        return c.sqlite3_step(self.raw);
    }

    pub fn expectDone(self: Statement) !void {
        if (self.step() != c.SQLITE_DONE) return error.SqliteStepFailed;
    }

    pub fn expectRow(self: Statement) !void {
        if (self.step() != c.SQLITE_ROW) return error.SqliteStepFailed;
    }

    pub fn readInt(self: Statement, column: c_int) c_int {
        return c.sqlite3_column_int(self.raw, column);
    }

    pub fn readInt64(self: Statement, column: c_int) i64 {
        return c.sqlite3_column_int64(self.raw, column);
    }

    pub fn readText(self: Statement, column: c_int) ?[]const u8 {
        const value = c.sqlite3_column_text(self.raw, column) orelse return null;
        return std.mem.span(value);
    }

    pub fn columnType(self: Statement, column: c_int) c_int {
        return c.sqlite3_column_type(self.raw, column);
    }
};

pub fn changes(db: *c.sqlite3) c_int {
    return c.sqlite3_changes(db);
}
