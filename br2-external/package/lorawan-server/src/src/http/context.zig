const std = @import("std");

const app_mod = @import("../app.zig");
const request_mod = @import("request.zig");
const response_mod = @import("response.zig");

pub const RouteParam = struct {
    name: []const u8,
    value: []const u8,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    app: *app_mod.App,
    config: *const app_mod.Config,
    req: request_mod.Request,
    res: response_mod.Response,
    user_id: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    params: std.ArrayListUnmanaged(RouteParam) = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        app: *app_mod.App,
        config: *const app_mod.Config,
        req: request_mod.Request,
    ) Context {
        return .{
            .allocator = allocator,
            .app = app,
            .config = config,
            .req = req,
            .res = response_mod.Response.init(allocator),
        };
    }

    pub fn deinit(self: *Context) void {
        if (self.request_id) |request_id| self.allocator.free(request_id);
        self.params.deinit(self.allocator);
        self.res.deinit();
    }

    pub fn setParams(self: *Context, params: []const RouteParam) !void {
        self.params.clearRetainingCapacity();
        try self.params.appendSlice(self.allocator, params);
    }

    pub fn param(self: *const Context, name: []const u8) ?[]const u8 {
        for (self.params.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.value;
        }
        return null;
    }
};
