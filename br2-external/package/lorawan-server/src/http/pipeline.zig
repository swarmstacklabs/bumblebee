const context_mod = @import("context.zig");
const router_mod = @import("router.zig");
const runtime = @import("runtime.zig");

pub const Dispatcher = struct {
    middlewares: []const runtime.Middleware,
    router: router_mod.Router,

    pub fn handle(self: *const Dispatcher, ctx: *context_mod.Context) runtime.AppError!void {
        const matched = try self.router.match(ctx.req);
        switch (matched) {
            .not_found => {
                ctx.res.setText(404, "not found\n");
                return;
            },
            .method_not_allowed => {
                ctx.res.setText(405, "method not allowed\n");
                return;
            },
            .matched => |result| {
                try ctx.setParams(result.params.constSlice());

                var exec = runtime.Executor{
                    .global_middlewares = self.middlewares,
                    .route_middlewares = result.route.middlewares,
                    .handler = result.route.handler,
                };
                try exec.next(ctx);
            },
        }
    }
};
