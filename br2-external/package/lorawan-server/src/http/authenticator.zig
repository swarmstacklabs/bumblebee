const std = @import("std");

const app_mod = @import("../app.zig");

pub const Authenticator = struct {
    admin: app_mod.AdminConfig,

    pub fn init(admin: app_mod.AdminConfig) Authenticator {
        return .{ .admin = admin };
    }

    pub fn deinit(_: Authenticator) void {}

    pub fn authenticateBasic(self: Authenticator, allocator: std.mem.Allocator, header: ?[]const u8) !?[]const u8 {
        if (!self.admin.isConfigured()) return "anonymous";

        const value = header orelse return error.Unauthorized;
        if (!std.ascii.startsWithIgnoreCase(value, "Basic ")) return error.Unauthorized;

        const encoded = std.mem.trim(u8, value["Basic ".len..], " \t");
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.Unauthorized;
        const decoded = try allocator.alloc(u8, decoded_len);
        defer allocator.free(decoded);

        _ = std.base64.standard.Decoder.decode(decoded, encoded) catch return error.Unauthorized;
        const sep = std.mem.indexOfScalar(u8, decoded, ':') orelse return error.Unauthorized;

        const user = decoded[0..sep];
        const pass = decoded[sep + 1 ..];
        if (!std.mem.eql(u8, user, self.admin.user.?) or !std.mem.eql(u8, pass, self.admin.pass.?)) {
            return error.Unauthorized;
        }

        return self.admin.user.?;
    }
};
