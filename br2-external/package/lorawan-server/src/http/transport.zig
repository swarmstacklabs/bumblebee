const std = @import("std");
const posix = std.posix;

const app_mod = @import("../app.zig");
const logger = @import("../logger.zig");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("netinet/in.h");
    @cInclude("sys/socket.h");
});

const Config = app_mod.Config;
pub const InitError = error{
    SocketOpenFailed,
    SocketConfigureFailed,
    SocketBindFailed,
    SocketListenFailed,
};

pub const Connection = struct {
    fd: posix.socket_t,
    buf: [65536]u8 = undefined,
    used: usize = 0,
    header_end: ?usize = null,
    content_length: usize = 0,
    sent_continue: bool = false,

    pub fn close(self: Connection) void {
        posix.close(self.fd);
    }

    pub fn recv(self: *Connection) !usize {
        return posix.recv(self.fd, self.buf[self.used..], 0) catch |err| switch (err) {
            error.WouldBlock => error.WouldBlock,
            else => |other| other,
        };
    }

    pub fn writeAll(self: *const Connection, data: []const u8) !void {
        var offset: usize = 0;
        while (offset < data.len) {
            const written = posix.send(self.fd, data[offset..], 0) catch |err| switch (err) {
                error.WouldBlock => {
                    var pollfd = [_]posix.pollfd{.{ .fd = self.fd, .events = posix.POLL.OUT, .revents = 0 }};
                    _ = try posix.poll(&pollfd, -1);
                    continue;
                },
                else => return err,
            };
            if (written == 0) return error.ConnectionClosed;
            offset += written;
        }
    }

    pub fn requestBytes(self: *const Connection) ?[]const u8 {
        const end = self.header_end orelse return null;
        if (self.used < end + self.content_length) return null;
        return self.buf[0 .. end + self.content_length];
    }
};

pub fn initServerSocket(runtime_config: *const Config) InitError!posix.socket_t {
    const server_sock = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (server_sock < 0) {
        logErrnoFailure("socket_open_failed", "failed to open HTTP socket", runtime_config);
        return error.SocketOpenFailed;
    }
    errdefer posix.close(@intCast(server_sock));

    const enable: c_int = 1;
    if (c.setsockopt(server_sock, c.SOL_SOCKET, c.SO_REUSEADDR, std.mem.asBytes(&enable).ptr, @sizeOf(c_int)) != 0) {
        logErrnoFailure("socket_configure_failed", "failed to configure HTTP socket", runtime_config);
        return error.SocketConfigureFailed;
    }
    if (!setNonBlocking(server_sock)) {
        logErrnoFailure("socket_configure_failed", "failed to configure HTTP socket", runtime_config);
        return error.SocketConfigureFailed;
    }

    var addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, runtime_config.http_port),
        .addr = 0,
        .zero = [_]u8{0} ** 8,
    };

    if (c.bind(server_sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) {
        logErrnoFailure("socket_bind_failed", "failed to bind HTTP socket", runtime_config);
        return error.SocketBindFailed;
    }
    if (c.listen(server_sock, 16) != 0) {
        logErrnoFailure("socket_listen_failed", "failed to listen on HTTP socket", runtime_config);
        return error.SocketListenFailed;
    }
    return @intCast(server_sock);
}

pub fn closeServerSocket(server_sock: posix.socket_t) void {
    posix.close(server_sock);
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
        if (!setNonBlocking(@intCast(client))) return error.Unexpected;
        try conns.append(allocator, .{ .fd = client });
    }
}

fn setNonBlocking(sock: c_int) bool {
    const flags = c.fcntl(sock, c.F_GETFL, @as(c_int, 0));
    if (flags < 0) return false;
    return c.fcntl(sock, c.F_SETFL, flags | c.O_NONBLOCK) == 0;
}

fn logErrnoFailure(event: []const u8, message: []const u8, runtime_config: *const Config) void {
    logger.err("http", event, message, .{
        .bind_address = runtime_config.bind_address,
        .port = runtime_config.http_port,
        .errno_name = errnoName(),
        .errno_code = errnoCode(),
    });
}

fn errnoCode() c_int {
    return std.c._errno().*;
}

fn errnoName() []const u8 {
    return switch (errnoCode()) {
        c.EPERM => "EPERM",
        c.EACCES => "EACCES",
        c.EADDRINUSE => "EADDRINUSE",
        c.EADDRNOTAVAIL => "EADDRNOTAVAIL",
        c.EAFNOSUPPORT => "EAFNOSUPPORT",
        c.EINVAL => "EINVAL",
        c.EMFILE => "EMFILE",
        c.ENFILE => "ENFILE",
        c.ENOBUFS => "ENOBUFS",
        c.ENOMEM => "ENOMEM",
        c.ENOTSOCK => "ENOTSOCK",
        else => "UNKNOWN",
    };
}
