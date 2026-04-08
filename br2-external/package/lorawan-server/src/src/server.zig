const std = @import("std");
const posix = std.posix;

const app_mod = @import("app.zig");
const http = @import("http.zig");
const udp = @import("udp.zig");

const App = app_mod.App;
const Config = app_mod.Config;

pub fn serverMain(app: *App, runtime_config: *const Config) !void {
    const allocator = app.allocator;

    const udp_sock = try udp.initServerSocket(runtime_config);
    defer posix.close(udp_sock);

    const http_sock = try http.initServerSocket(runtime_config);
    defer posix.close(http_sock);

    var udp_server = udp.Server.init(app, udp_sock);
    defer udp_server.deinit();

    var http_conns = std.ArrayList(http.Connection){};
    defer {
        for (http_conns.items) |conn| posix.close(conn.fd);
        http_conns.deinit(allocator);
    }

    var pollfds = std.ArrayList(posix.pollfd){};
    defer pollfds.deinit(allocator);

    while (true) {
        try pollfds.resize(allocator, 0);
        try pollfds.append(allocator, .{ .fd = udp_sock, .events = posix.POLL.IN, .revents = 0 });
        try pollfds.append(allocator, .{ .fd = http_sock, .events = posix.POLL.IN, .revents = 0 });
        const ready_http_conn_count = http_conns.items.len;
        for (http_conns.items[0..ready_http_conn_count]) |conn| {
            try pollfds.append(allocator, .{ .fd = conn.fd, .events = posix.POLL.IN, .revents = 0 });
        }

        _ = try posix.poll(pollfds.items, -1);

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
    posix.close(conns.items[index].fd);
    _ = conns.orderedRemove(index);
}
