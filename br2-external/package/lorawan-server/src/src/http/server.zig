const std = @import("std");

const app_mod = @import("../app.zig");
const http_transport = @import("../http_transport.zig");
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

pub const Connection = http_transport.Connection;

pub fn serverMain(app: *App, runtime_config: *const Config) !void {
    const server_sock = try initServerSocket(runtime_config);
    defer http_transport.closeServerSocket(server_sock);

    var conns = std.ArrayList(Connection){};
    defer {
        for (conns.items) |conn| conn.close();
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
                conns.items[i].close();
                _ = conns.orderedRemove(i);
                continue;
            }
            i += 1;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

pub fn initServerSocket(runtime_config: *const Config) !std.posix.socket_t {
    const server_sock = try http_transport.initServerSocket(runtime_config);
    logger.info("http", "listener_started", "http listener started", .{
        .bind_address = runtime_config.bind_address,
        .port = runtime_config.http_port,
    });

    return server_sock;
}

pub fn acceptReadyClients(
    server_sock: std.posix.socket_t,
    allocator: std.mem.Allocator,
    conns: *std.ArrayList(Connection),
) !void {
    try http_transport.acceptReadyClients(server_sock, allocator, conns);
}

pub fn serviceReadyClient(app: *App, runtime_config: *const Config, conn: *Connection) !bool {
    while (conn.used < conn.buf.len) {
        const n = conn.recv() catch |err| switch (err) {
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
                    try conn.writeAll("HTTP/1.1 100 Continue\r\n\r\n");
                    conn.sent_continue = true;
                }
            }
        }

        if (conn.requestBytes() != null) {
            var header_buf: [32]request_mod.Header = undefined;
            const req = try request_mod.parseConnection(conn, &header_buf);

            var ctx = context_mod.Context.init(app.allocator, app, runtime_config, req);
            defer ctx.deinit();

            dispatcher.handle(&ctx) catch |err| {
                logger.err("http", "dispatcher_failed", "http dispatcher failed", .{
                    .path = req.path,
                    .error_name = @errorName(err),
                });
                ctx.res.setText(500, "internal server error\n");
            };
            try ctx.res.writeTo(conn);
            return true;
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
