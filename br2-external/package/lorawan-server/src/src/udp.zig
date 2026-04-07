const std = @import("std");
const posix = std.posix;

const config = @import("config.zig");
const logger = @import("logger.zig");
const storage = @import("storage.zig");
const c = storage.c;

const UdpPacketContext = struct {
    sock: posix.socket_t,
    client_addr: posix.sockaddr.in,
    client_len: posix.socklen_t,
    msg: []u8,
};

pub fn serverMain(runtime_config: *const config.Config) !void {
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer posix.close(sock);

    const flags = try posix.fcntl(sock, posix.F.GETFL, 0);
    _ = try posix.fcntl(sock, posix.F.SETFL, flags | posix.SOCK.NONBLOCK);

    const enable: c_int = 1;
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enable));

    var addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, runtime_config.udp_port),
        .addr = 0,
        .zero = [_]u8{0} ** 8,
    };

    try posix.bind(sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    logger.info("udp", "listener_started", "udp listener started", .{
        .bind_address = runtime_config.bind_address,
        .port = runtime_config.udp_port,
    });

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

        const context = try std.heap.page_allocator.create(UdpPacketContext);
        errdefer std.heap.page_allocator.destroy(context);
        context.* = .{
            .sock = sock,
            .client_addr = client_addr,
            .client_len = client_len,
            .msg = try std.heap.page_allocator.dupe(u8, buf[0..n]),
        };

        const thread = std.Thread.spawn(.{}, handleUdpPacketThread, .{context}) catch |err| {
            logger.err("udp", "worker_spawn_failed", "udp worker thread spawn failed", .{
                .error_name = @errorName(err),
            });
            handleUdpPacket(context) catch |handle_err| {
                logger.err("udp", "packet_error", "udp packet handling failed", .{
                    .error_name = @errorName(handle_err),
                });
            };
            continue;
        };
        thread.detach();
    }
}

fn handleUdpPacketThread(context: *UdpPacketContext) void {
    handleUdpPacket(context) catch |err| {
        logger.err("udp", "packet_error", "udp packet handling failed", .{
            .error_name = @errorName(err),
        });
    };
}

fn handleUdpPacket(context: *UdpPacketContext) !void {
    defer std.heap.page_allocator.free(context.msg);
    defer std.heap.page_allocator.destroy(context);

    const port = std.mem.bigToNative(u16, context.client_addr.port);
    const ip = @as([4]u8, @bitCast(context.client_addr.addr));

    logger.debug("udp", "packet_received", "udp packet received", .{
        .bytes = context.msg.len,
        .peer_ip = ip,
        .peer_port = port,
    });

    if (context.msg.len >= 4) {
        logger.debug("udp", "semtech_header", "semtech packet header parsed", .{
            .version = context.msg[0],
            .token_hi = context.msg[1],
            .token_lo = context.msg[2],
            .ident = context.msg[3],
        });
    }

    _ = try posix.sendto(context.sock, context.msg, 0, @ptrCast(&context.client_addr), context.client_len);
    logger.debug("udp", "packet_echoed", "udp packet echoed", .{
        .bytes = context.msg.len,
        .peer_port = port,
    });
}
