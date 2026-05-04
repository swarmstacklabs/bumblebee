const server = @import("server.zig");

pub const Connection = server.Connection;
pub const acceptReadyClients = server.acceptReadyClients;
pub const initServerSocket = server.initServerSocket;
pub const serverMain = server.serverMain;
pub const serviceReadyClient = server.serviceReadyClient;

test {
    _ = @import("router.zig");
}

pub const StatusResponse = struct {
    status: []const u8,

    pub fn init(status: []const u8) StatusResponse {
        return .{ .status = status };
    }

    pub fn deinit(_: StatusResponse) void {}
};

pub const ErrorResponse = struct {
    @"error": []const u8,

    pub fn init(message: []const u8) ErrorResponse {
        return .{ .@"error" = message };
    }

    pub fn deinit(_: ErrorResponse) void {}
};
