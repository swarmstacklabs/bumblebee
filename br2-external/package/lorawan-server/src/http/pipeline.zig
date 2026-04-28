const std = @import("std");

const Context = @import("context.zig").Context;
const logger = @import("../logger.zig");
const Status = @import("response.zig").Status;
const Router = @import("router.zig").Router;
const runtime = @import("runtime.zig");

pub const Dispatcher = struct {
    middlewares: []const runtime.Middleware,
    router: Router,

    pub fn init(middlewares: []const runtime.Middleware, router: Router) Dispatcher {
        return .{
            .middlewares = middlewares,
            .router = router,
        };
    }

    pub fn deinit(_: Dispatcher) void {}

    pub fn handle(self: *const Dispatcher, ctx: *Context) runtime.AppError!void {
        const started_ns = std.time.nanoTimestamp();
        var observed = false;
        errdefer {
            if (!observed) {
                observe(ctx, Status.internal_server_error, started_ns);
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

fn observe(ctx: *Context, status: Status, started_ns: i128) void {
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

fn metricLevel(status: Status) logger.Level {
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
