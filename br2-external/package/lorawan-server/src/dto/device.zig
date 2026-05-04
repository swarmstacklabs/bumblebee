const std = @import("std");

pub const DeviceWriteInput = struct {
    name: []const u8,
    dev_eui: []const u8,
    app_eui: []const u8,
    app_key: []const u8,
    network_name: ?[]const u8 = null,

    pub fn init(name: []const u8, dev_eui: []const u8, app_eui: []const u8, app_key: []const u8, network_name: ?[]const u8) DeviceWriteInput {
        return .{
            .name = name,
            .dev_eui = dev_eui,
            .app_eui = app_eui,
            .app_key = app_key,
            .network_name = network_name,
        };
    }

    pub fn deinit(self: DeviceWriteInput, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.dev_eui);
        allocator.free(self.app_eui);
        allocator.free(self.app_key);
        if (self.network_name) |value| allocator.free(value);
    }
};
