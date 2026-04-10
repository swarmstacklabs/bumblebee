const std = @import("std");

const context_mod = @import("context.zig");
const request_mod = @import("request.zig");
const runtime = @import("runtime.zig");

pub const Route = struct {
    method: request_mod.Method,
    path: []const u8,
    handler: runtime.HandlerFn,
    middlewares: []const runtime.Middleware = &.{},

    pub fn init(method: request_mod.Method, path: []const u8, handler: runtime.HandlerFn, middlewares: []const runtime.Middleware) Route {
        return .{
            .method = method,
            .path = path,
            .handler = handler,
            .middlewares = middlewares,
        };
    }

    pub fn deinit(_: Route) void {}
};

pub const Match = struct {
    route: *const Route,
    params: ParamBuffer,

    pub fn init(route: *const Route, params: ParamBuffer) Match {
        return .{ .route = route, .params = params };
    }

    pub fn deinit(_: Match) void {}
};

pub const MatchResult = union(enum) {
    matched: Match,
    method_not_allowed: void,
    not_found: void,
};

pub const Router = struct {
    routes: []const Route,

    pub fn init(routes: []const Route) Router {
        return .{ .routes = routes };
    }

    pub fn deinit(_: Router) void {}

    pub fn match(self: *const Router, req: request_mod.Request) !MatchResult {
        var path_matched = false;
        for (self.routes) |*route| {
            if (try matchPath(route.path, req.path)) |params| {
                if (route.method == req.method) {
                    return .{ .matched = Match.init(route, params) };
                }
                path_matched = true;
            }
        }
        if (path_matched) return .{ .method_not_allowed = {} };
        return .{ .not_found = {} };
    }
};

const ParamBuffer = struct {
    items: [8]context_mod.RouteParam = undefined,
    len: usize = 0,

    fn init() ParamBuffer {
        return .{ .len = 0 };
    }

    fn deinit(_: *ParamBuffer) void {}

    fn append(self: *ParamBuffer, param: context_mod.RouteParam) !void {
        if (self.len >= self.items.len) return error.TooManyRouteParams;
        self.items[self.len] = param;
        self.len += 1;
    }

    pub fn constSlice(self: *const ParamBuffer) []const context_mod.RouteParam {
        return self.items[0..self.len];
    }
};

fn matchPath(pattern: []const u8, path: []const u8) !?ParamBuffer {
    var params = ParamBuffer.init();

    var pattern_it = std.mem.tokenizeScalar(u8, std.mem.trim(u8, pattern, "/"), '/');
    var path_it = std.mem.tokenizeScalar(u8, std.mem.trim(u8, path, "/"), '/');

    while (true) {
        const pattern_part = pattern_it.next();
        const path_part = path_it.next();

        if (pattern_part == null and path_part == null) return params;
        if (pattern_part == null or path_part == null) return null;

        const pattern_value = pattern_part.?;
        const path_value = path_part.?;

        if (pattern_value.len > 1 and pattern_value[0] == ':') {
            try params.append(context_mod.RouteParam.init(pattern_value[1..], path_value));
            continue;
        }

        if (!std.mem.eql(u8, pattern_value, path_value)) return null;
    }
}

test "router matches parameterized routes" {
    const routes = [_]Route{
        Route.init(.GET, "/api/devices/:id", undefined, &.{}),
    };

    const req = request_mod.Request.init(.GET, "/api/devices/42", "/api/devices/42", "", &.{});

    const router = Router.init(&routes);
    const matched = try router.match(req);
    try std.testing.expect(matched == .matched);
    try std.testing.expectEqualStrings("42", matched.matched.params.constSlice()[0].value);
}
