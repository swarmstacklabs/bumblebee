const std = @import("std");

pub const DeviceRecord = struct {
    id: i64,
    name: []const u8,
    dev_eui: []const u8,
    app_eui: []const u8,
    app_key: []const u8,
    network_name: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,

    pub fn init(id: i64, name: []const u8, dev_eui: []const u8, app_eui: []const u8, app_key: []const u8, network_name: ?[]const u8, created_at: []const u8, updated_at: []const u8) DeviceRecord {
        return .{
            .id = id,
            .name = name,
            .dev_eui = dev_eui,
            .app_eui = app_eui,
            .app_key = app_key,
            .network_name = network_name,
            .created_at = created_at,
            .updated_at = updated_at,
        };
    }

    pub fn deinit(self: DeviceRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.dev_eui);
        allocator.free(self.app_eui);
        allocator.free(self.app_key);
        if (self.network_name) |value| allocator.free(value);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
    }
};
