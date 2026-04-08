const std = @import("std");
const posix = std.posix;

const app_mod = @import("app.zig");

const Config = app_mod.Config;
const c = app_mod.c;

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
    return server_sock;
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
        try setNonBlocking(client);
        try conns.append(allocator, .{ .fd = client });
    }
}

fn setNonBlocking(sock: posix.socket_t) !void {
    const flags = try posix.fcntl(sock, posix.F.GETFL, 0);
    _ = try posix.fcntl(sock, posix.F.SETFL, flags | posix.SOCK.NONBLOCK);
}
