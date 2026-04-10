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
};

pub const Datagram = struct {
    client_addr: posix.sockaddr.in,
    client_len: posix.socklen_t,
    len: usize,
};

pub const Socket = struct {
    fd: posix.socket_t,

    pub fn initServer(runtime_config: *const Config) InitError!Socket {
        const sock = c.socket(c.AF_INET, c.SOCK_DGRAM, 0);
        if (sock < 0) {
            logErrnoFailure("socket_open_failed", "failed to open UDP socket", runtime_config);
            return error.SocketOpenFailed;
        }
        errdefer posix.close(@intCast(sock));

        if (!setNonBlocking(sock)) {
            logErrnoFailure("socket_configure_failed", "failed to configure UDP socket", runtime_config);
            return error.SocketConfigureFailed;
        }

        const enable: c_int = 1;
        if (c.setsockopt(sock, c.SOL_SOCKET, c.SO_REUSEADDR, std.mem.asBytes(&enable).ptr, @sizeOf(c_int)) != 0) {
            logErrnoFailure("socket_configure_failed", "failed to configure UDP socket", runtime_config);
            return error.SocketConfigureFailed;
        }

        var addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, runtime_config.udp_port),
            .addr = 0,
            .zero = [_]u8{0} ** 8,
        };

        if (c.bind(sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) {
            logErrnoFailure("socket_bind_failed", "failed to bind UDP socket", runtime_config);
            return error.SocketBindFailed;
        }
        return .{ .fd = @intCast(sock) };
    }

    pub fn close(self: Socket) void {
        posix.close(self.fd);
    }

    pub fn recvFrom(self: *const Socket, buf: []u8) !?Datagram {
        var client_addr: posix.sockaddr.in = undefined;
        var client_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);

        const n = posix.recvfrom(self.fd, buf, 0, @ptrCast(&client_addr), &client_len) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };

        return .{
            .client_addr = client_addr,
            .client_len = client_len,
            .len = n,
        };
    }

    pub fn sendTo(self: *const Socket, client_addr: *const posix.sockaddr.in, client_len: posix.socklen_t, data: []const u8) !void {
        _ = try posix.sendto(self.fd, data, 0, @ptrCast(client_addr), client_len);
    }
};

fn setNonBlocking(sock: c_int) bool {
    const flags = c.fcntl(sock, c.F_GETFL, @as(c_int, 0));
    if (flags < 0) return false;
    return c.fcntl(sock, c.F_SETFL, flags | c.O_NONBLOCK) == 0;
}

fn logErrnoFailure(event: []const u8, message: []const u8, runtime_config: *const Config) void {
    logger.err("udp", event, message, .{
        .bind_address = runtime_config.bind_address,
        .port = runtime_config.udp_port,
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
