const server = @import("server.zig");

pub const Connection = server.Connection;
pub const acceptReadyClients = server.acceptReadyClients;
pub const initServerSocket = server.initServerSocket;
pub const serverMain = server.serverMain;
pub const serviceReadyClient = server.serviceReadyClient;

test {
    _ = @import("router.zig");
}
