const std = @import("std");

const app_mod = @import("../app.zig");
const http_transport = @import("transport.zig");
const logger = @import("../logger.zig");
const context_mod = @import("context.zig");
const pipeline = @import("pipeline.zig");
const request_mod = @import("request.zig");
const router_mod = @import("router.zig");
const runtime = @import("runtime.zig");
const services_mod = @import("services.zig");

const frontend_handler = @import("handlers/frontend_handler.zig");
const health_handler = @import("handlers/health_handler.zig");
const devices_handler = @import("handlers/devices_handler.zig");
const gateways_handler = @import("handlers/gateways_handler.zig");
const networks_handler = @import("handlers/networks_handler.zig");
const connectors_handler = @import("handlers/connectors_handler.zig");
const system_resources_handler = @import("handlers/system_resources.zig");
const server_handler = @import("handlers/server_handler.zig");
const events_handler = @import("handlers/events_handler.zig");
const users_handler = @import("handlers/users_handler.zig");
const timeline_handler = @import("handlers/timeline_handler.zig");

const recover_middleware = @import("middleware/recover.zig");
const logger_middleware = @import("middleware/logger.zig");
const request_id_middleware = @import("middleware/request_id.zig");
const cors_middleware = @import("middleware/cors.zig");
const auth_middleware = @import("middleware/auth.zig");

const App = app_mod.App;
const Config = app_mod.Config;

const global_middlewares = [_]runtime.Middleware{
    runtime.Middleware.init("recover", recover_middleware.middleware),
    runtime.Middleware.init("logger", logger_middleware.middleware),
    runtime.Middleware.init("request_id", request_id_middleware.middleware),
    runtime.Middleware.init("cors", cors_middleware.middleware),
};

const api_middlewares = [_]runtime.Middleware{
    runtime.Middleware.init("auth", auth_middleware.middleware),
};

const routes = [_]router_mod.Route{
    router_mod.Route.init(.GET, "/healthz", health_handler.handle, &.{}),
    router_mod.Route.init(.GET, "/api/gateways", gateways_handler.list, &api_middlewares),
    router_mod.Route.init(.POST, "/api/gateways", gateways_handler.create, &api_middlewares),
    router_mod.Route.init(.GET, "/api/gateways/:id", gateways_handler.get, &api_middlewares),
    router_mod.Route.init(.PUT, "/api/gateways/:id", gateways_handler.update, &api_middlewares),
    router_mod.Route.init(.DELETE, "/api/gateways/:id", gateways_handler.delete, &api_middlewares),
    router_mod.Route.init(.GET, "/api/networks", networks_handler.list, &api_middlewares),
    router_mod.Route.init(.POST, "/api/networks", networks_handler.create, &api_middlewares),
    router_mod.Route.init(.GET, "/api/networks/:id", networks_handler.get, &api_middlewares),
    router_mod.Route.init(.PUT, "/api/networks/:id", networks_handler.update, &api_middlewares),
    router_mod.Route.init(.DELETE, "/api/networks/:id", networks_handler.delete, &api_middlewares),
    router_mod.Route.init(.GET, "/api/devices", devices_handler.list, &api_middlewares),
    router_mod.Route.init(.POST, "/api/devices", devices_handler.create, &api_middlewares),
    router_mod.Route.init(.GET, "/api/devices/:id", devices_handler.get, &api_middlewares),
    router_mod.Route.init(.PUT, "/api/devices/:id", devices_handler.update, &api_middlewares),
    router_mod.Route.init(.DELETE, "/api/devices/:id", devices_handler.delete, &api_middlewares),
    router_mod.Route.init(.GET, "/api/connectors", connectors_handler.list, &api_middlewares),
    router_mod.Route.init(.POST, "/api/connectors", connectors_handler.create, &api_middlewares),
    router_mod.Route.init(.GET, "/api/connectors/:id", connectors_handler.get, &api_middlewares),
    router_mod.Route.init(.PUT, "/api/connectors/:id", connectors_handler.update, &api_middlewares),
    router_mod.Route.init(.DELETE, "/api/connectors/:id", connectors_handler.delete, &api_middlewares),
    router_mod.Route.init(.GET, "/api/system/resources", system_resources_handler.list, &api_middlewares),
    router_mod.Route.init(.GET, "/api/system/resources/:id", system_resources_handler.get, &api_middlewares),
    router_mod.Route.init(.GET, "/api/servers", server_handler.list, &api_middlewares),
    router_mod.Route.init(.GET, "/api/servers/:id", server_handler.get, &api_middlewares),
    router_mod.Route.init(.GET, "/api/events", events_handler.list, &api_middlewares),
    router_mod.Route.init(.GET, "/api/users", users_handler.list, &api_middlewares),
    router_mod.Route.init(.GET, "/api/users/:id", users_handler.get, &api_middlewares),
    router_mod.Route.init(.GET, "/api/scopes", users_handler.listScopes, &api_middlewares),
    router_mod.Route.init(.GET, "/admin/timeline", timeline_handler.list, &api_middlewares),
    router_mod.Route.init(.GET, "/*", frontend_handler.handle, &.{}),
};

const dispatcher = pipeline.Dispatcher.init(&global_middlewares, router_mod.Router.init(&routes));

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

            const services = services_mod.Services.init(app, runtime_config);
            var ctx = context_mod.Context.init(app.allocator, services, req);
            defer ctx.deinit();

            dispatcher.handle(&ctx) catch |err| {
                logger.err("http", "dispatcher_failed", "http dispatcher failed", .{
                    .path = req.path,
                    .error_name = @errorName(err),
                });
                ctx.res.setText(.internal_server_error, "internal server error\n");
            };
            ctx.res.prepare(req);
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
