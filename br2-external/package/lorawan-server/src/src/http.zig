const std = @import("std");
const posix = std.posix;

const config = @import("config.zig");
const logger = @import("logger.zig");
const storage = @import("storage.zig");
const App = storage.App;
const DeviceJson = storage.DeviceJson;
const DevicePayload = storage.DevicePayload;
const ErrorResponse = storage.ErrorResponse;
const StatusResponse = storage.StatusResponse;
const c = storage.c;

const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8,
};

const HttpClientContext = struct {
    app: *App,
    client: posix.socket_t,
};

pub fn serverMain(app: *App, runtime_config: *const config.Config) !void {
    const server_sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(server_sock);

    const enable: c_int = 1;
    try posix.setsockopt(server_sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enable));

    var addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, runtime_config.http_port),
        .addr = 0,
        .zero = [_]u8{0} ** 8,
    };

    try posix.bind(server_sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    try posix.listen(server_sock, 16);
    logger.info("http", "listener_started", "http listener started", .{
        .bind_address = runtime_config.bind_address,
        .port = runtime_config.http_port,
    });

    while (true) {
        var client_addr: posix.sockaddr.in = undefined;
        var client_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        const client = try posix.accept(server_sock, @ptrCast(&client_addr), &client_len, 0);
        const context = try std.heap.page_allocator.create(HttpClientContext);
        context.* = .{
            .app = app,
            .client = client,
        };
        const thread = std.Thread.spawn(.{}, handleHttpClientThread, .{context}) catch |err| {
            logger.err("http", "worker_spawn_failed", "http worker thread spawn failed", .{
                .error_name = @errorName(err),
            });
            std.heap.page_allocator.destroy(context);
            handleHttpClient(app, client) catch |handle_err| {
                logger.err("http", "client_error", "http client handling failed", .{
                    .error_name = @errorName(handle_err),
                });
            };
            posix.close(client);
            continue;
        };
        thread.detach();
    }
}

fn handleHttpClientThread(context: *HttpClientContext) void {
    defer std.heap.page_allocator.destroy(context);
    defer posix.close(context.client);

    handleHttpClient(context.app, context.client) catch |err| {
        logger.err("http", "client_error", "http client handling failed", .{
            .error_name = @errorName(err),
        });
    };
}

fn handleHttpClient(app: *App, client: posix.socket_t) !void {
    var buf: [65536]u8 = undefined;
    const request = try readHttpRequest(client, &buf);
    try routeHttpRequest(app, client, request);
}

fn readHttpRequest(client: posix.socket_t, buf: []u8) !HttpRequest {
    var total: usize = 0;
    var header_end: ?usize = null;
    var content_length: usize = 0;

    while (total < buf.len) {
        const n = try posix.recv(client, buf[total..], 0);
        if (n == 0) return error.ConnectionClosed;
        total += n;

        if (header_end == null) {
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |idx| {
                header_end = idx + 4;
                content_length = parseContentLength(buf[0..idx]) catch 0;
            }
        }

        if (header_end) |end| {
            if (total >= end + content_length) {
                return parseHttpRequest(buf[0 .. end + content_length], end);
            }
        }
    }

    return error.RequestTooLarge;
}

fn parseContentLength(headers: []const u8) !usize {
    var it = std.mem.tokenizeSequence(u8, headers, "\r\n");
    _ = it.next();
    while (it.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
            const value = std.mem.trim(u8, line["Content-Length:".len..], " \t");
            return std.fmt.parseInt(usize, value, 10);
        }
    }
    return 0;
}

fn parseHttpRequest(raw: []const u8, body_start: usize) !HttpRequest {
    const header_block = raw[0 .. body_start - 4];
    const first_line_end = std.mem.indexOf(u8, header_block, "\r\n") orelse header_block.len;
    const request_line = header_block[0..first_line_end];

    var parts = std.mem.tokenizeScalar(u8, request_line, ' ');
    const method = parts.next() orelse return error.BadRequest;
    const path = parts.next() orelse return error.BadRequest;

    return .{
        .method = method,
        .path = path,
        .body = raw[body_start..],
    };
}

fn routeHttpRequest(app: *App, client: posix.socket_t, req: HttpRequest) !void {
    if (std.mem.eql(u8, req.path, "/healthz")) {
        try sendText(client, "200 OK", "ok\n");
        return;
    }

    if (std.mem.eql(u8, req.path, "/api/devices")) {
        if (std.mem.eql(u8, req.method, "GET")) {
            try handleListDevices(app, client);
            return;
        }
        if (std.mem.eql(u8, req.method, "POST")) {
            try handleCreateDevice(app, client, req.body);
            return;
        }
        try sendMethodNotAllowed(client);
        return;
    }

    if (std.mem.startsWith(u8, req.path, "/api/devices/")) {
        const id_text = req.path["/api/devices/".len..];
        const id = std.fmt.parseInt(i64, id_text, 10) catch {
            try sendBadRequest(app, client, "invalid device id");
            return;
        };

        if (std.mem.eql(u8, req.method, "GET")) {
            try handleGetDevice(app, client, id);
            return;
        }
        if (std.mem.eql(u8, req.method, "PUT")) {
            try handleUpdateDevice(app, client, id, req.body);
            return;
        }
        if (std.mem.eql(u8, req.method, "DELETE")) {
            try handleDeleteDevice(app, client, id);
            return;
        }

        try sendMethodNotAllowed(client);
        return;
    }

    try sendText(client, "404 Not Found", "not found\n");
}

fn handleCreateDevice(app: *App, client: posix.socket_t, body: []const u8) !void {
    const payload = parseDevicePayload(app, body) catch {
        try sendBadRequest(app, client, "invalid device payload");
        return;
    };
    defer payload.deinit(app.allocator);

    app.mutex.lock();
    defer app.mutex.unlock();

    const sql = "INSERT INTO devices(name, dev_eui, app_eui, app_key) VALUES(?, ?, ?, ?);";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(app.db, sql.ptr, @as(c_int, @intCast(sql.len)), &stmt, null) != c.SQLITE_OK) {
        return error.SqlitePrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    bindText(stmt.?, 1, payload.name);
    bindText(stmt.?, 2, payload.dev_eui);
    bindText(stmt.?, 3, payload.app_eui);
    bindText(stmt.?, 4, payload.app_key);

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        try sendConflict(app, client, "device already exists or could not be created");
        return;
    }

    try sendJson(app, client, "201 Created", StatusResponse{ .status = "created" });
}

fn handleUpdateDevice(app: *App, client: posix.socket_t, id: i64, body: []const u8) !void {
    const payload = parseDevicePayload(app, body) catch {
        try sendBadRequest(app, client, "invalid device payload");
        return;
    };
    defer payload.deinit(app.allocator);

    app.mutex.lock();
    defer app.mutex.unlock();

    const sql =
        "UPDATE devices " ++
        "SET name = ?, dev_eui = ?, app_eui = ?, app_key = ?, updated_at = CURRENT_TIMESTAMP " ++
        "WHERE id = ?;";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(app.db, sql.ptr, @as(c_int, @intCast(sql.len)), &stmt, null) != c.SQLITE_OK) {
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

    if (c.sqlite3_changes(app.db) == 0) {
        try sendNotFound(app, client, "device not found");
        return;
    }

    try sendJson(app, client, "200 OK", StatusResponse{ .status = "updated" });
}

fn handleDeleteDevice(app: *App, client: posix.socket_t, id: i64) !void {
    app.mutex.lock();
    defer app.mutex.unlock();

    const sql = "DELETE FROM devices WHERE id = ?;";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(app.db, sql.ptr, @as(c_int, @intCast(sql.len)), &stmt, null) != c.SQLITE_OK) {
        return error.SqlitePrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
        return error.SqliteDeleteFailed;
    }

    if (c.sqlite3_changes(app.db) == 0) {
        try sendNotFound(app, client, "device not found");
        return;
    }

    try sendJson(app, client, "200 OK", StatusResponse{ .status = "deleted" });
}

fn handleListDevices(app: *App, client: posix.socket_t) !void {
    app.mutex.lock();
    defer app.mutex.unlock();

    const sql = "SELECT id, name, dev_eui, app_eui, app_key, created_at, updated_at FROM devices ORDER BY id DESC;";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(app.db, sql.ptr, @as(c_int, @intCast(sql.len)), &stmt, null) != c.SQLITE_OK) {
        return error.SqlitePrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    var out = std.ArrayList(u8){};
    defer out.deinit(app.allocator);

    try out.appendSlice(app.allocator, "[");
    var first = true;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        if (!first) try out.appendSlice(app.allocator, ",");
        first = false;

        const device = rowToDevice(stmt.?);
        const json = try std.json.Stringify.valueAlloc(app.allocator, device, .{});
        defer app.allocator.free(json);
        try out.appendSlice(app.allocator, json);
    }
    try out.appendSlice(app.allocator, "]\n");

    try sendRaw(client, "200 OK", "application/json", out.items);
}

fn handleGetDevice(app: *App, client: posix.socket_t, id: i64) !void {
    app.mutex.lock();
    defer app.mutex.unlock();

    const sql = "SELECT id, name, dev_eui, app_eui, app_key, created_at, updated_at FROM devices WHERE id = ?;";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(app.db, sql.ptr, @as(c_int, @intCast(sql.len)), &stmt, null) != c.SQLITE_OK) {
        return error.SqlitePrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    _ = c.sqlite3_bind_int64(stmt, 1, id);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) {
        try sendNotFound(app, client, "device not found");
        return;
    }

    try sendJson(app, client, "200 OK", rowToDevice(stmt.?));
}

fn rowToDevice(stmt: *c.sqlite3_stmt) DeviceJson {
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

fn parseDevicePayload(app: *App, body: []const u8) !DevicePayload {
    const parsed = try std.json.parseFromSlice(DevicePayload, app.allocator, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return .{
        .name = try app.allocator.dupe(u8, parsed.value.name),
        .dev_eui = try app.allocator.dupe(u8, parsed.value.dev_eui),
        .app_eui = try app.allocator.dupe(u8, parsed.value.app_eui),
        .app_key = try app.allocator.dupe(u8, parsed.value.app_key),
    };
}

fn sendText(client: posix.socket_t, status: []const u8, body: []const u8) !void {
    try sendRaw(client, status, "text/plain; charset=utf-8", body);
}

fn sendJson(app: *App, client: posix.socket_t, status: []const u8, payload: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(app.allocator, payload, .{});
    defer app.allocator.free(json);
    try sendRaw(client, status, "application/json", json);
}

fn sendBadRequest(app: *App, client: posix.socket_t, message: []const u8) !void {
    try sendJson(app, client, "400 Bad Request", ErrorResponse{ .@"error" = message });
}

fn sendNotFound(app: *App, client: posix.socket_t, message: []const u8) !void {
    try sendJson(app, client, "404 Not Found", ErrorResponse{ .@"error" = message });
}

fn sendConflict(app: *App, client: posix.socket_t, message: []const u8) !void {
    try sendJson(app, client, "409 Conflict", ErrorResponse{ .@"error" = message });
}

fn sendMethodNotAllowed(client: posix.socket_t) !void {
    try sendText(client, "405 Method Not Allowed", "method not allowed\n");
}

fn sendRaw(client: posix.socket_t, status: []const u8, content_type: []const u8, body: []const u8) !void {
    var header_buf: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, content_type, body.len },
    );
    try writeAll(client, header);
    try writeAll(client, body);
}

fn writeAll(fd: posix.socket_t, data: []const u8) !void {
    var offset: usize = 0;
    while (offset < data.len) {
        const written = try posix.send(fd, data[offset..], 0);
        if (written == 0) return error.ConnectionClosed;
        offset += written;
    }
}
