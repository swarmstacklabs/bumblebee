const std = @import("std");

const app_mod = @import("../app.zig");
const context_mod = @import("context.zig");
const logger = @import("../logger.zig");
const request_mod = @import("request.zig");
const response_mod = @import("response.zig");
const router_mod = @import("router.zig");
const runtime = @import("runtime.zig");
const services_mod = @import("services.zig");

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

    pub fn handle(self: *const Dispatcher, ctx: *context_mod.Context) runtime.AppError!void {
        const started_ns = std.time.nanoTimestamp();
        var observed = false;
        errdefer {
            if (!observed) {
                observe(ctx, response_mod.Status.internal_server_error, started_ns);
            }
        }

        const matched = try self.router.match(ctx.req);
        switch (matched) {
            .not_found => {
                ctx.res.setText(.not_found, "not found\n");
                observe(ctx, ctx.res.status, started_ns);
                observed = true;
                return;
            },
            .method_not_allowed => {
                ctx.res.setText(.method_not_allowed, "method not allowed\n");
                observe(ctx, ctx.res.status, started_ns);
                observed = true;
                return;
            },
            .matched => |result| {
                try ctx.setParams(result.params.constSlice());

                var exec = runtime.Executor.init(self.middlewares, result.route.middlewares, result.route.handler);
                try exec.next(ctx);
                observe(ctx, ctx.res.status, started_ns);
                observed = true;
            },
        }
    }
};

fn observe(ctx: *context_mod.Context, status: response_mod.Status, started_ns: i128) void {
    const level = metricLevel(status);
    if (@intFromEnum(level) < @intFromEnum(logger.currentLevel())) return;

    ctx.services.http_metrics_repo.insertObservation(
        @tagName(ctx.req.method),
        ctx.req.path,
        status.code(),
        @tagName(level),
        elapsedNs(started_ns),
    ) catch {};
}

fn metricLevel(status: response_mod.Status) logger.Level {
    const code = status.code();
    if (code >= 500) return .err;
    if (code >= 400) return .info;
    return .debug;
}

fn elapsedNs(started_ns: i128) u64 {
    const now_ns = std.time.nanoTimestamp();
    if (now_ns <= started_ns) return 0;
    return @intCast(@min(now_ns - started_ns, std.math.maxInt(u64)));
}

test "dispatcher records not found request metrics at info level" {
    const allocator = std.testing.allocator;
    const db_path = try std.fmt.allocPrint(allocator, "/tmp/lorawan-server-http-dispatcher-metrics-{d}.db", .{std.time.nanoTimestamp()});
    defer allocator.free(db_path);
    defer std.fs.deleteFileAbsolute(db_path) catch {};

    var app = try app_mod.App.init(allocator, db_path);
    defer app.deinit();

    var cfg = try app_mod.Config.initWithDefaultFrontendPath(
        allocator,
        app_mod.default_bind_address,
        app_mod.default_udp_port,
        app_mod.default_http_port,
        db_path,
        app_mod.AdminConfig.init(null, null),
    );
    defer cfg.deinit();

    const services = services_mod.Services.init(&app, &cfg);
    var ctx = context_mod.Context.init(
        allocator,
        services,
        request_mod.Request.init(.GET, "/missing", "/missing", "", &.{}),
    );
    defer ctx.deinit();

    const dispatcher = Dispatcher.init(&.{}, router_mod.Router.init(&.{}));
    try dispatcher.handle(&ctx);

    try std.testing.expectEqual(response_mod.Status.not_found, ctx.res.status);
    try std.testing.expectEqual(@as(i64, 1), try services.http_metrics_repo.countByStatus(404));
}
