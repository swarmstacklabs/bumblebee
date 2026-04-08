const std = @import("std");
const posix = std.posix;

const app_mod = @import("../app.zig");
const logger = @import("../logger.zig");
const context_mod = @import("context.zig");
const pipeline = @import("pipeline.zig");
const request_mod = @import("request.zig");
const router_mod = @import("router.zig");
const runtime = @import("runtime.zig");

const home_handler = @import("../handlers/home.zig");
const health_handler = @import("../handlers/health.zig");
const devices_handler = @import("../handlers/devices.zig");

const recover_middleware = @import("../middleware/recover.zig");
const logger_middleware = @import("../middleware/logger.zig");
const request_id_middleware = @import("../middleware/request_id.zig");
const cors_middleware = @import("../middleware/cors.zig");
const auth_middleware = @import("../middleware/auth.zig");

const App = app_mod.App;
const Config = app_mod.Config;
const c = app_mod.c;

const global_middlewares = [_]runtime.Middleware{
    .{ .name = "recover", .func = recover_middleware.middleware },
    .{ .name = "logger", .func = logger_middleware.middleware },
    .{ .name = "request_id", .func = request_id_middleware.middleware },
    .{ .name = "cors", .func = cors_middleware.middleware },
};

const api_middlewares = [_]runtime.Middleware{
    .{ .name = "auth", .func = auth_middleware.middleware },
};

const routes = [_]router_mod.Route{
    .{ .method = .GET, .path = "/", .handler = home_handler.handle },
    .{ .method = .GET, .path = "/healthz", .handler = health_handler.handle },
    .{ .method = .GET, .path = "/api/devices", .handler = devices_handler.list, .middlewares = &api_middlewares },
    .{ .method = .POST, .path = "/api/devices", .handler = devices_handler.create, .middlewares = &api_middlewares },
    .{ .method = .GET, .path = "/api/devices/:id", .handler = devices_handler.get, .middlewares = &api_middlewares },
    .{ .method = .PUT, .path = "/api/devices/:id", .handler = devices_handler.update, .middlewares = &api_middlewares },
    .{ .method = .DELETE, .path = "/api/devices/:id", .handler = devices_handler.delete, .middlewares = &api_middlewares },
};

const dispatcher = pipeline.Dispatcher{
    .middlewares = &global_middlewares,
    .router = .{ .routes = &routes },
};

pub const Connection = struct {
    fd: posix.socket_t,
    buf: [65536]u8 = undefined,
    used: usize = 0,
    header_end: ?usize = null,
    content_length: usize = 0,
    sent_continue: bool = false,
};

pub fn serverMain(app: *App, runtime_config: *const Config) !void {
    const server_sock = try initServerSocket(runtime_config);
    defer posix.close(server_sock);

    var conns = std.ArrayList(Connection){};
    defer {
        for (conns.items) |conn| posix.close(conn.fd);
        conns.deinit(app.allocator);
    }

    while (true) {
        try acceptReadyClients(server_sock, app.allocator, &conns);
        var i: usize = 0;
        while (i < conns.items.len) {
            const done = serviceReadyClient(app, runtime_config, &conns.items[i]) catch |err| switch (err) {
                error.WouldBlock => false,
                error.ConnectionClosed => true,
                else => return err,
            };
            if (done) {
                posix.close(conns.items[i].fd);
                _ = conns.orderedRemove(i);
                continue;
            }
            i += 1;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

pub fn initServerSocket(runtime_config: *const Config) !posix.socket_t {
    const server_sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    errdefer posix.close(server_sock);

    const enable: c_int = 1;
    try posix.setsockopt(server_sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enable));
    try setNonBlocking(server_sock);

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

    return server_sock;
}

pub fn acceptReadyClients(
    server_sock: posix.socket_t,
    allocator: std.mem.Allocator,
    conns: *std.ArrayList(Connection),
) !void {
    while (true) {
        var client_addr: posix.sockaddr.in = undefined;
        var client_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        const client = posix.accept(server_sock, @ptrCast(&client_addr), &client_len, 0) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        errdefer posix.close(client);
        try setNonBlocking(client);
        try conns.append(allocator, .{ .fd = client });
    }
}

pub fn serviceReadyClient(app: *App, runtime_config: *const Config, conn: *Connection) !bool {
    while (conn.used < conn.buf.len) {
        const n = posix.recv(conn.fd, conn.buf[conn.used..], 0) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => return err,
        };
        if (n == 0) return true;
        conn.used += n;

        if (conn.header_end == null) {
            if (std.mem.indexOf(u8, conn.buf[0..conn.used], "\r\n\r\n")) |idx| {
                conn.header_end = idx + 4;
                const headers = conn.buf[0..idx];
                conn.content_length = parseContentLength(headers) catch 0;
                if (!conn.sent_continue and expectsContinue(headers)) {
                    try writeAll(conn.fd, "HTTP/1.1 100 Continue\r\n\r\n");
                    conn.sent_continue = true;
                }
            }
        }

        if (conn.header_end) |end| {
            if (conn.used >= end + conn.content_length) {
                var header_buf: [32]request_mod.Header = undefined;
                const req = try request_mod.parse(conn.buf[0 .. end + conn.content_length], end, &header_buf);

                var ctx = context_mod.Context.init(app.allocator, app, runtime_config, req);
                defer ctx.deinit();

                dispatcher.handle(&ctx) catch |err| {
                    logger.err("http", "dispatcher_failed", "http dispatcher failed", .{
                        .path = req.path,
                        .error_name = @errorName(err),
                    });
                    ctx.res.setText(500, "internal server error\n");
                };
                try ctx.res.writeTo(conn.fd);
                return true;
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

fn expectsContinue(headers: []const u8) bool {
    var it = std.mem.tokenizeSequence(u8, headers, "\r\n");
    _ = it.next();
    while (it.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "Expect:")) {
            const value = std.mem.trim(u8, line["Expect:".len..], " \t");
            if (std.ascii.eqlIgnoreCase(value, "100-continue")) return true;
        }
    }
    return false;
}

fn writeAll(fd: posix.socket_t, data: []const u8) !void {
    var offset: usize = 0;
    while (offset < data.len) {
        const written = posix.send(fd, data[offset..], 0) catch |err| switch (err) {
            error.WouldBlock => {
                var pollfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
                _ = try posix.poll(&pollfd, -1);
                continue;
            },
            else => return err,
        };
        if (written == 0) return error.ConnectionClosed;
        offset += written;
    }
}

fn setNonBlocking(sock: posix.socket_t) !void {
    const flags = try posix.fcntl(sock, posix.F.GETFL, 0);
    _ = try posix.fcntl(sock, posix.F.SETFL, flags | posix.SOCK.NONBLOCK);
}
