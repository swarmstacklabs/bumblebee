const std = @import("std");
const posix = std.posix;

const app_mod = @import("app.zig");
const http = @import("http/http.zig");
const maintenance = @import("maintenance.zig");
const udp = @import("udp/udp.zig");
const http_transport = @import("http/transport.zig");

const App = app_mod.App;
const Config = app_mod.Config;

pub const StartupError = error{ServerStartupFailed};

pub fn run(app: *App, runtime_config: *const Config) !void {
    const allocator = app.allocator;

    const udp_sock = udp.initServerSocket(runtime_config) catch |err| switch (err) {
        error.SocketOpenFailed, error.SocketConfigureFailed, error.SocketBindFailed => return error.ServerStartupFailed,
    };
    defer udp_sock.close();

    const http_sock = http.initServerSocket(runtime_config) catch |err| switch (err) {
        error.SocketOpenFailed, error.SocketConfigureFailed, error.SocketBindFailed, error.SocketListenFailed => return error.ServerStartupFailed,
    };
    defer http_transport.closeServerSocket(http_sock);

    var udp_server = udp.Server.init(app, udp_sock);

    var http_conns = std.ArrayList(http.Connection){};
    defer {
        for (http_conns.items) |conn| conn.close();
        http_conns.deinit(allocator);
    }

    var pollfds = std.ArrayList(posix.pollfd){};
    defer pollfds.deinit(allocator);

    var cleanup_scheduler = maintenance.Scheduler.init(std.time.milliTimestamp());

    while (true) {
        cleanup_scheduler.runIfDue(app, runtime_config);

        try pollfds.resize(allocator, 0);
        try pollfds.append(allocator, .{ .fd = udp_sock.fd, .events = posix.POLL.IN, .revents = 0 });
        try pollfds.append(allocator, .{ .fd = http_sock, .events = posix.POLL.IN, .revents = 0 });
        const ready_http_conn_count = http_conns.items.len;
        for (http_conns.items[0..ready_http_conn_count]) |conn| {
            try pollfds.append(allocator, .{ .fd = conn.fd, .events = posix.POLL.IN, .revents = 0 });
        }

        _ = try posix.poll(pollfds.items, cleanup_scheduler.pollTimeoutMs(std.time.milliTimestamp()));

        if ((pollfds.items[0].revents & posix.POLL.IN) != 0) {
            try udp.drainReady(&udp_server);
        }

        if ((pollfds.items[1].revents & posix.POLL.IN) != 0) {
            try http.acceptReadyClients(http_sock, allocator, &http_conns);
        }

        var i: usize = 0;
        while (i < ready_http_conn_count and i < http_conns.items.len) {
            const revents = pollfds.items[i + 2].revents;
            if ((revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL)) != 0) {
                closeAndRemove(&http_conns, i);
                continue;
            }
            if ((revents & posix.POLL.IN) != 0) {
                const done = http.serviceReadyClient(app, runtime_config, &http_conns.items[i]) catch |err| switch (err) {
                    error.ConnectionClosed => true,
                    else => return err,
                };
                if (done) {
                    closeAndRemove(&http_conns, i);
                    continue;
                }
            }
            i += 1;
        }
    }
}

fn closeAndRemove(conns: *std.ArrayList(http.Connection), index: usize) void {
    conns.items[index].close();
    _ = conns.orderedRemove(index);
}
