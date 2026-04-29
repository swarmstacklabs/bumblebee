const commands = @import("commands.zig");
const context_mod = @import("context.zig");
const router_mod = @import("router.zig");
const runtime = @import("runtime.zig");

pub const Dispatcher = struct {
    middlewares: []const runtime.Middleware,
    router: router_mod.Router,

    pub fn init(middlewares: []const runtime.Middleware, router: router_mod.Router) Dispatcher {
        return .{
            .middlewares = middlewares,
            .router = router,
        };
    }

    pub fn deinit(_: Dispatcher) void {}

    pub fn handle(self: *const Dispatcher, ctx: *context_mod.Context, command_index: usize, command: commands.Command) runtime.AppError!void {
        ctx.setCommand(command_index, command);

        const matched = self.router.match(command);
        switch (matched) {
            .not_found => return error.CommandHandlerNotFound,
            .matched => |result| {
                var exec = runtime.Executor.init(self.middlewares, result.route.middlewares, result.route.handler);
                try exec.next(ctx);
            },
        }
    }

    pub fn handleAll(self: *const Dispatcher, ctx: *context_mod.Context, incoming: []const commands.Command) runtime.AppError!void {
        for (incoming, 0..) |command, command_index| {
            try self.handle(ctx, command_index, command);
        }
    }
};

test "dispatcher runs middlewares and handler in http-style order" {
    const std = @import("std");

    const State = struct {
        trace: std.ArrayListUnmanaged([]const u8) = .{},

        fn push(self: *@This(), allocator: std.mem.Allocator, value: []const u8) !void {
            try self.trace.append(allocator, value);
        }

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.trace.deinit(allocator);
        }
    };

    const TestHandler = struct {
        fn global(ctx: *context_mod.Context, exec: *runtime.Executor) !void {
            try ctx.data(State).push(ctx.allocator, "global");
            try exec.next(ctx);
        }

        fn route(ctx: *context_mod.Context, exec: *runtime.Executor) !void {
            try ctx.data(State).push(ctx.allocator, "route");
            try exec.next(ctx);
        }

        fn handle(ctx: *context_mod.Context) !void {
            try ctx.data(State).push(ctx.allocator, "handler");
            try ctx.appendResponse(.{ .dev_status_req = {} });
        }
    };

    const global_middlewares = [_]runtime.Middleware{
        runtime.Middleware.init("global", TestHandler.global),
    };
    const route_middlewares = [_]runtime.Middleware{
        runtime.Middleware.init("route", TestHandler.route),
    };
    const routes = [_]router_mod.Route{
        router_mod.Route.init(.device_time_req, TestHandler.handle, &route_middlewares),
    };

    var ctx = context_mod.Context.init(std.testing.allocator);
    defer ctx.deinit();

    var state = State{};
    defer state.deinit(std.testing.allocator);
    ctx.setData(&state);

    const dispatcher = Dispatcher.init(&global_middlewares, router_mod.Router.init(&routes));
    try dispatcher.handle(&ctx, 0, .device_time_req);

    try std.testing.expectEqual(@as(usize, 3), state.trace.items.len);
    try std.testing.expectEqualStrings("global", state.trace.items[0]);
    try std.testing.expectEqualStrings("route", state.trace.items[1]);
    try std.testing.expectEqualStrings("handler", state.trace.items[2]);
    try std.testing.expect(ctx.response_commands.items[0] == .dev_status_req);
}

test "dispatcher reports missing handlers" {
    const std = @import("std");

    var ctx = context_mod.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const dispatcher = Dispatcher.init(&.{}, router_mod.Router.init(&.{}));
    try std.testing.expectError(error.CommandHandlerNotFound, dispatcher.handle(&ctx, 0, .device_time_req));
}
