const std = @import("std");

const app_mod = @import("../app.zig");
const sqlite = @import("../sqlite_helpers.zig");
const App = app_mod.App;
const DeviceJson = app_mod.DeviceJson;
const DevicePayload = app_mod.DevicePayload;

pub const Repository = struct {
    app: *App,

    pub fn init(app: *App) Repository {
        return .{ .app = app };
    }

    pub fn list(self: Repository, allocator: std.mem.Allocator) ![]DeviceJson {
        self.app.mutex.lock();
        defer self.app.mutex.unlock();

        const sql = "SELECT id, name, dev_eui, app_eui, app_key, created_at, updated_at FROM devices ORDER BY id DESC;";
        const stmt = try sqlite.Statement.prepare(self.app.db, sql);
        defer stmt.deinit();

        var out = std.ArrayList(DeviceJson){};
        errdefer {
            for (out.items) |item| item.deinit(allocator);
            out.deinit(allocator);
        }

        while (stmt.step() == sqlite.c.SQLITE_ROW) {
            try out.append(allocator, try rowToDevice(allocator, stmt));
        }

        return out.toOwnedSlice(allocator);
    }

    pub fn get(self: Repository, allocator: std.mem.Allocator, id: i64) !?DeviceJson {
        self.app.mutex.lock();
        defer self.app.mutex.unlock();

        const sql = "SELECT id, name, dev_eui, app_eui, app_key, created_at, updated_at FROM devices WHERE id = ?;";
        const stmt = try sqlite.Statement.prepare(self.app.db, sql);
        defer stmt.deinit();

        stmt.bindInt64(1, id);
        if (stmt.step() != sqlite.c.SQLITE_ROW) return null;

        return try rowToDevice(allocator, stmt);
    }

    pub fn create(self: Repository, payload: DevicePayload) !void {
        self.app.mutex.lock();
        defer self.app.mutex.unlock();

        const sql = "INSERT INTO devices(name, dev_eui, app_eui, app_key) VALUES(?, ?, ?, ?);";
        const stmt = try sqlite.Statement.prepare(self.app.db, sql);
        defer stmt.deinit();

        stmt.bindText(1, payload.name);
        stmt.bindText(2, payload.dev_eui);
        stmt.bindText(3, payload.app_eui);
        stmt.bindText(4, payload.app_key);

        stmt.expectDone() catch return error.DeviceCreateFailed;
    }

    pub fn update(self: Repository, id: i64, payload: DevicePayload) !bool {
        self.app.mutex.lock();
        defer self.app.mutex.unlock();

        const sql =
            "UPDATE devices " ++
            "SET name = ?, dev_eui = ?, app_eui = ?, app_key = ?, updated_at = CURRENT_TIMESTAMP " ++
            "WHERE id = ?;";
        const stmt = try sqlite.Statement.prepare(self.app.db, sql);
        defer stmt.deinit();

        stmt.bindText(1, payload.name);
        stmt.bindText(2, payload.dev_eui);
        stmt.bindText(3, payload.app_eui);
        stmt.bindText(4, payload.app_key);
        stmt.bindInt64(5, id);

        stmt.expectDone() catch return error.DeviceUpdateFailed;
        return sqlite.changes(self.app.db) != 0;
    }

    pub fn delete(self: Repository, id: i64) !bool {
        self.app.mutex.lock();
        defer self.app.mutex.unlock();

        const sql = "DELETE FROM devices WHERE id = ?;";
        const stmt = try sqlite.Statement.prepare(self.app.db, sql);
        defer stmt.deinit();

        stmt.bindInt64(1, id);
        stmt.expectDone() catch return error.DeviceDeleteFailed;
        return sqlite.changes(self.app.db) != 0;
    }
};

fn rowToDevice(allocator: std.mem.Allocator, stmt: sqlite.Statement) !DeviceJson {
    return .{
        .id = stmt.readInt64(0),
        .name = try dupColumnText(allocator, stmt, 1),
        .dev_eui = try dupColumnText(allocator, stmt, 2),
        .app_eui = try dupColumnText(allocator, stmt, 3),
        .app_key = try dupColumnText(allocator, stmt, 4),
        .created_at = try dupColumnText(allocator, stmt, 5),
        .updated_at = try dupColumnText(allocator, stmt, 6),
    };
}

fn dupColumnText(allocator: std.mem.Allocator, stmt: sqlite.Statement, column: c_int) ![]u8 {
    const value = stmt.readText(column) orelse return allocator.alloc(u8, 0);
    return allocator.dupe(u8, value);
}

