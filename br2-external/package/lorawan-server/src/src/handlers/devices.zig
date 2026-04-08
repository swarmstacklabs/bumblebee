const std = @import("std");

const app_mod = @import("../app.zig");
const context_mod = @import("../http/context.zig");
const c = app_mod.c;

pub fn list(ctx: *context_mod.Context) !void {
    ctx.app.mutex.lock();
    defer ctx.app.mutex.unlock();

    const sql = "SELECT id, name, dev_eui, app_eui, app_key, created_at, updated_at FROM devices ORDER BY id DESC;";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(ctx.app.db, sql.ptr, @as(c_int, @intCast(sql.len)), &stmt, null) != c.SQLITE_OK) {
        return error.SqlitePrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    var out = std.ArrayList(u8){};
    defer out.deinit(ctx.allocator);

    try out.appendSlice(ctx.allocator, "[");
    var first = true;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (!first) try out.appendSlice(ctx.allocator, ",");
        first = false;

        const device = rowToDevice(stmt.?);
        const json = try std.json.Stringify.valueAlloc(ctx.allocator, device, .{});
        defer ctx.allocator.free(json);
        try out.appendSlice(ctx.allocator, json);
    }
    try out.appendSlice(ctx.allocator, "]\n");

    ctx.res.setOwnedBody(200, "application/json", try out.toOwnedSlice(ctx.allocator));
}

pub fn get(ctx: *context_mod.Context) !void {
    const id = try parseRouteId(ctx);

    ctx.app.mutex.lock();
    defer ctx.app.mutex.unlock();

    const sql = "SELECT id, name, dev_eui, app_eui, app_key, created_at, updated_at FROM devices WHERE id = ?;";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(ctx.app.db, sql.ptr, @as(c_int, @intCast(sql.len)), &stmt, null) != c.SQLITE_OK) {
        return error.SqlitePrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) {
        try ctx.res.setJsonStatus(404, app_mod.ErrorResponse{ .@"error" = "device not found" });
        return;
    }

    try ctx.res.setJson(rowToDevice(stmt.?));
}

pub fn create(ctx: *context_mod.Context) !void {
    const payload = try parseDevicePayload(ctx, ctx.req.body);
    defer payload.deinit(ctx.allocator);

    ctx.app.mutex.lock();
    defer ctx.app.mutex.unlock();

    const sql = "INSERT INTO devices(name, dev_eui, app_eui, app_key) VALUES(?, ?, ?, ?);";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(ctx.app.db, sql.ptr, @as(c_int, @intCast(sql.len)), &stmt, null) != c.SQLITE_OK) {
        return error.SqlitePrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    bindText(stmt.?, 1, payload.name);
    bindText(stmt.?, 2, payload.dev_eui);
    bindText(stmt.?, 3, payload.app_eui);
    bindText(stmt.?, 4, payload.app_key);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        try ctx.res.setJsonStatus(409, app_mod.ErrorResponse{ .@"error" = "device already exists or could not be created" });
        return;
    }

    try ctx.res.setJsonStatus(201, app_mod.StatusResponse{ .status = "created" });
}

pub fn update(ctx: *context_mod.Context) !void {
    const id = try parseRouteId(ctx);
    const payload = try parseDevicePayload(ctx, ctx.req.body);
    defer payload.deinit(ctx.allocator);

    ctx.app.mutex.lock();
    defer ctx.app.mutex.unlock();

    const sql =
        "UPDATE devices " ++
        "SET name = ?, dev_eui = ?, app_eui = ?, app_key = ?, updated_at = CURRENT_TIMESTAMP " ++
        "WHERE id = ?;";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(ctx.app.db, sql.ptr, @as(c_int, @intCast(sql.len)), &stmt, null) != c.SQLITE_OK) {
        return error.SqlitePrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    bindText(stmt.?, 1, payload.name);
    bindText(stmt.?, 2, payload.dev_eui);
    bindText(stmt.?, 3, payload.app_eui);
    bindText(stmt.?, 4, payload.app_key);
    _ = c.sqlite3_bind_int64(stmt, 5, id);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        return error.SqliteUpdateFailed;
    }

    if (c.sqlite3_changes(ctx.app.db) == 0) {
        try ctx.res.setJsonStatus(404, app_mod.ErrorResponse{ .@"error" = "device not found" });
        return;
    }

    try ctx.res.setJson(app_mod.StatusResponse{ .status = "updated" });
}

pub fn delete(ctx: *context_mod.Context) !void {
    const id = try parseRouteId(ctx);

    ctx.app.mutex.lock();
    defer ctx.app.mutex.unlock();

    const sql = "DELETE FROM devices WHERE id = ?;";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(ctx.app.db, sql.ptr, @as(c_int, @intCast(sql.len)), &stmt, null) != c.SQLITE_OK) {
        return error.SqlitePrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        return error.SqliteDeleteFailed;
    }

    if (c.sqlite3_changes(ctx.app.db) == 0) {
        try ctx.res.setJsonStatus(404, app_mod.ErrorResponse{ .@"error" = "device not found" });
        return;
    }

    try ctx.res.setJson(app_mod.StatusResponse{ .status = "deleted" });
}

fn rowToDevice(stmt: *c.sqlite3_stmt) app_mod.DeviceJson {
    const name_ptr = c.sqlite3_column_text(stmt, 1);
    const dev_eui_ptr = c.sqlite3_column_text(stmt, 2);
    const app_eui_ptr = c.sqlite3_column_text(stmt, 3);
    const app_key_ptr = c.sqlite3_column_text(stmt, 4);
    const created_ptr = c.sqlite3_column_text(stmt, 5);
    const updated_ptr = c.sqlite3_column_text(stmt, 6);

    return .{
        .id = c.sqlite3_column_int64(stmt, 0),
        .name = if (name_ptr != null) std.mem.span(name_ptr) else "",
        .dev_eui = if (dev_eui_ptr != null) std.mem.span(dev_eui_ptr) else "",
        .app_eui = if (app_eui_ptr != null) std.mem.span(app_eui_ptr) else "",
        .app_key = if (app_key_ptr != null) std.mem.span(app_key_ptr) else "",
        .created_at = if (created_ptr != null) std.mem.span(created_ptr) else "",
        .updated_at = if (updated_ptr != null) std.mem.span(updated_ptr) else "",
    };
}

fn bindText(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) void {
    _ = c.sqlite3_bind_text(stmt, index, value.ptr, @as(c_int, @intCast(value.len)), null);
}

fn parseDevicePayload(ctx: *context_mod.Context, body: []const u8) !app_mod.DevicePayload {
    const parsed = try std.json.parseFromSlice(app_mod.DevicePayload, ctx.allocator, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return .{
        .name = try ctx.allocator.dupe(u8, parsed.value.name),
        .dev_eui = try ctx.allocator.dupe(u8, parsed.value.dev_eui),
        .app_eui = try ctx.allocator.dupe(u8, parsed.value.app_eui),
        .app_key = try ctx.allocator.dupe(u8, parsed.value.app_key),
    };
}

fn parseRouteId(ctx: *context_mod.Context) !i64 {
    const id_text = ctx.param("id") orelse return error.BadRequest;
    return std.fmt.parseInt(i64, id_text, 10);
}
