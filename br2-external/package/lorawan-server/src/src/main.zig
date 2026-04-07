const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const c = @cImport({
    @cInclude("sqlite3.h");
});

const udp_port = 1700;
const http_port = 8080;
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var app: App = undefined;

const StatusResponse = struct {
    status: []const u8,
};

const ErrorResponse = struct {
    @"error": []const u8,
};

const DeviceJson = struct {
    id: i64,
    name: []const u8,
    dev_eui: []const u8,
    app_eui: []const u8,
    app_key: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

const DevicePayload = struct {
    name: []const u8,
    dev_eui: []const u8,
    app_eui: []const u8,
    app_key: []const u8,

    fn deinit(self: DevicePayload, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.dev_eui);
        allocator.free(self.app_eui);
        allocator.free(self.app_key);
    }
};

const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8,
};

const App = struct {
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    mutex: std.Thread.Mutex = .{},

    fn init(allocator: std.mem.Allocator, path: []const u8) !App {
        try ensureDbDir(path);

        var db_ptr: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path.ptr, &db_ptr) != c.SQLITE_OK or db_ptr == null) {
            return error.SqliteOpenFailed;
        }

        var self = App{
            .allocator = allocator,
            .db = db_ptr.?,
        };
        errdefer _ = c.sqlite3_close(self.db);

        try self.exec(
            "CREATE TABLE IF NOT EXISTS devices (" ++ "id INTEGER PRIMARY KEY AUTOINCREMENT, " ++ "name TEXT NOT NULL, " ++ "dev_eui TEXT NOT NULL UNIQUE, " ++ "app_eui TEXT NOT NULL, " ++ "app_key TEXT NOT NULL, " ++ "created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, " ++ "updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP" ++ ");",
        );
        return self;
    }

    fn deinit(self: *App) void {
        _ = c.sqlite3_close(self.db);
    }

    fn exec(self: *App, sql: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try execUnlocked(self, sql);
    }

    fn execUnlocked(self: *App, sql: []const u8) !void {
        var err_msg: [*c]u8 = null;
        if (c.sqlite3_exec(self.db, sql.ptr, null, null, &err_msg) != c.SQLITE_OK) {
            if (err_msg != null) {
                std.log.err("sqlite exec failed: {s}", .{std.mem.span(@as([*:0]const u8, err_msg))});
                c.sqlite3_free(err_msg);
            }
            return error.SqliteExecFailed;
        }
    }
};

fn ensureDbDir(path: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse return;
    try std.fs.cwd().makePath(dir_path);
}

fn defaultDbPath() []const u8 {
    return switch (builtin.cpu.arch) {
        .arm, .aarch64 => "/var/lib/lorawan-server/lorawan-server.db",
        else => "data/lorawan-server.db",
    };
}

fn resolveDbPath(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "LORAWAN_SERVER_DB_PATH") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => allocator.dupe(u8, defaultDbPath()),
        else => err,
    };
}

fn httpServerMain() !void {
    const server_sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(server_sock);

    const enable: c_int = 1;
    try posix.setsockopt(server_sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enable));

    var addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, http_port),
        .addr = 0,
        .zero = [_]u8{0} ** 8,
    };

    try posix.bind(server_sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    try posix.listen(server_sock, 16);
    std.log.info("HTTP listening on 0.0.0.0:{d}", .{http_port});

    while (true) {
        var client_addr: posix.sockaddr.in = undefined;
        var client_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        const client = try posix.accept(server_sock, @ptrCast(&client_addr), &client_len, 0);
        handleHttpClient(client) catch |err| {
            std.log.err("http client error: {}", .{err});
        };
        posix.close(client);
    }
}

fn handleHttpClient(client: posix.socket_t) !void {
    var buf: [65536]u8 = undefined;
    const request = try readHttpRequest(client, &buf);
    try routeHttpRequest(client, request);
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

fn routeHttpRequest(client: posix.socket_t, req: HttpRequest) !void {
    if (std.mem.eql(u8, req.path, "/healthz")) {
        try sendText(client, "200 OK", "ok\n");
        return;
    }

    if (std.mem.eql(u8, req.path, "/api/devices")) {
        if (std.mem.eql(u8, req.method, "GET")) {
            try handleListDevices(client);
            return;
        }
        if (std.mem.eql(u8, req.method, "POST")) {
            try handleCreateDevice(client, req.body);
            return;
        }
        try sendMethodNotAllowed(client);
        return;
    }

    if (std.mem.startsWith(u8, req.path, "/api/devices/")) {
        const id_text = req.path["/api/devices/".len..];
        const id = std.fmt.parseInt(i64, id_text, 10) catch {
            try sendBadRequest(client, "invalid device id");
            return;
        };

        if (std.mem.eql(u8, req.method, "GET")) {
            try handleGetDevice(client, id);
            return;
        }
        if (std.mem.eql(u8, req.method, "PUT")) {
            try handleUpdateDevice(client, id, req.body);
            return;
        }
        if (std.mem.eql(u8, req.method, "DELETE")) {
            try handleDeleteDevice(client, id);
            return;
        }

        try sendMethodNotAllowed(client);
        return;
    }

    try sendText(client, "404 Not Found", "not found\n");
}

fn handleCreateDevice(client: posix.socket_t, body: []const u8) !void {
    const payload = parseDevicePayload(body) catch {
        try sendBadRequest(client, "invalid device payload");
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
        try sendConflict(client, "device already exists or could not be created");
        return;
    }

    try sendJson(client, "201 Created", StatusResponse{ .status = "created" });
}

fn handleUpdateDevice(client: posix.socket_t, id: i64, body: []const u8) !void {
    const payload = parseDevicePayload(body) catch {
        try sendBadRequest(client, "invalid device payload");
        return;
    };
    defer payload.deinit(app.allocator);

    app.mutex.lock();
    defer app.mutex.unlock();

    const sql =
        "UPDATE devices " ++ "SET name = ?, dev_eui = ?, app_eui = ?, app_key = ?, updated_at = CURRENT_TIMESTAMP " ++ "WHERE id = ?;";
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
        try sendNotFound(client, "device not found");
        return;
    }

    try sendJson(client, "200 OK", StatusResponse{ .status = "updated" });
}

fn handleDeleteDevice(client: posix.socket_t, id: i64) !void {
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
        try sendNotFound(client, "device not found");
        return;
    }

    try sendJson(client, "200 OK", StatusResponse{ .status = "deleted" });
}

fn handleListDevices(client: posix.socket_t) !void {
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

fn handleGetDevice(client: posix.socket_t, id: i64) !void {
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
        try sendNotFound(client, "device not found");
        return;
    }

    try sendJson(client, "200 OK", rowToDevice(stmt.?));
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

fn parseDevicePayload(body: []const u8) !DevicePayload {
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

fn sendJson(client: posix.socket_t, status: []const u8, payload: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(app.allocator, payload, .{});
    defer app.allocator.free(json);
    try sendRaw(client, status, "application/json", json);
}

fn sendBadRequest(client: posix.socket_t, message: []const u8) !void {
    try sendJson(client, "400 Bad Request", ErrorResponse{ .@"error" = message });
}

fn sendNotFound(client: posix.socket_t, message: []const u8) !void {
    try sendJson(client, "404 Not Found", ErrorResponse{ .@"error" = message });
}

fn sendConflict(client: posix.socket_t, message: []const u8) !void {
    try sendJson(client, "409 Conflict", ErrorResponse{ .@"error" = message });
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

fn udpServerMain() !void {
    var out_buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&out_buf);
    const out = &writer.interface;

    const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(sock);

    const flags = try posix.fcntl(sock, posix.F.GETFL, 0);
    _ = try posix.fcntl(sock, posix.F.SETFL, flags | posix.SOCK.NONBLOCK);

    const enable: c_int = 1;
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enable));

    var addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, udp_port),
        .addr = 0,
        .zero = [_]u8{0} ** 8,
    };

    try posix.bind(sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    try out.print("lorawan-server UDP listening on 0.0.0.0:{d}\n", .{udp_port});
    try out.flush();

    var buf: [4096]u8 = undefined;

    while (true) {
        var client_addr: posix.sockaddr.in = undefined;
        var client_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);

        const n = posix.recvfrom(sock, buf[0..], 0, @ptrCast(&client_addr), &client_len) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };

        const msg = buf[0..n];
        const port = std.mem.bigToNative(u16, client_addr.port);
        const ip = @as([4]u8, @bitCast(client_addr.addr));

        try out.print(
            "rx {d} bytes from {d}.{d}.{d}.{d}:{d}\n",
            .{ n, ip[0], ip[1], ip[2], ip[3], port },
        );

        if (msg.len >= 4) {
            try out.print(
                "  semtech header version={d} token=0x{x:0>2}{x:0>2} ident=0x{x:0>2}\n",
                .{ msg[0], msg[1], msg[2], msg[3] },
            );
        }

        _ = try posix.sendto(sock, msg, 0, @ptrCast(&client_addr), client_len);
        try out.flush();
    }
}

pub fn main() !void {
    defer _ = gpa.detectLeaks();
    const allocator = gpa.allocator();

    const resolved_db_path = try resolveDbPath(allocator);
    defer allocator.free(resolved_db_path);

    app = try App.init(allocator, resolved_db_path);
    defer app.deinit();

    const http_thread = try std.Thread.spawn(.{}, httpServerMain, .{});
    defer http_thread.join();

    try udpServerMain();
}
