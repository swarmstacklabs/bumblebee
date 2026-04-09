const std = @import("std");
const posix = std.posix;

const app_mod = @import("../app.zig");

const Config = app_mod.Config;
pub const Datagram = struct {
    client_addr: posix.sockaddr.in,
    client_len: posix.socklen_t,
    len: usize,
};

pub const Socket = struct {
    fd: posix.socket_t,

    pub fn initServer(runtime_config: *const Config) !Socket {
        const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
        errdefer posix.close(sock);

        try setNonBlocking(sock);

        const enable: c_int = 1;
        try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enable));

        var addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, runtime_config.udp_port),
            .addr = 0,
            .zero = [_]u8{0} ** 8,
        };

        try posix.bind(sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        return .{ .fd = sock };
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

fn setNonBlocking(sock: posix.socket_t) !void {
    const flags = try posix.fcntl(sock, posix.F.GETFL, 0);
    _ = try posix.fcntl(sock, posix.F.SETFL, flags | posix.SOCK.NONBLOCK);
}
