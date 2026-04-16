const std = @import("std");

const commands = @import("commands.zig");
const context_mod = @import("context.zig");
const runtime = @import("runtime.zig");

pub const CommandTag = context_mod.CommandTag;

pub const Route = struct {
    tag: CommandTag,
    handler: runtime.HandlerFn,
    middlewares: []const runtime.Middleware = &.{},

    pub fn init(tag: CommandTag, handler: runtime.HandlerFn, middlewares: []const runtime.Middleware) Route {
        return .{
            .tag = tag,
            .handler = handler,
            .middlewares = middlewares,
        };
    }

    pub fn deinit(_: Route) void {}
};

pub const Match = struct {
    route: *const Route,

    pub fn init(route: *const Route) Match {
        return .{ .route = route };
    }

    pub fn deinit(_: Match) void {}
};

pub const MatchResult = union(enum) {
    matched: Match,
    not_found: void,
};

pub const Router = struct {
    routes: []const Route,

    pub fn init(routes: []const Route) Router {
        return .{ .routes = routes };
    }

    pub fn deinit(_: Router) void {}

    pub fn match(self: *const Router, command: commands.Command) MatchResult {
        const tag = std.meta.activeTag(command);
        for (self.routes) |*route| {
            if (route.tag == tag) return .{ .matched = Match.init(route) };
        }
        return .{ .not_found = {} };
    }
};

test "router matches commands by active tag" {
    const routes = [_]Route{
        Route.init(.dev_status_ans, undefined, &.{}),
    };

    const router = Router.init(&routes);
    const matched = router.match(.{ .dev_status_ans = .{ .battery = 1, .margin = 2 } });

    try std.testing.expect(matched == .matched);
    try std.testing.expectEqual(CommandTag.dev_status_ans, matched.matched.route.tag);
}
