const context_mod = @import("context.zig");

pub const AppError = anyerror;
pub const HandlerFn = *const fn (*context_mod.Context) AppError!void;
pub const MiddlewareFn = *const fn (*context_mod.Context, *Executor) AppError!void;

pub const Middleware = struct {
    name: []const u8,
    func: MiddlewareFn,
};

pub const Executor = struct {
    global_middlewares: []const Middleware,
    route_middlewares: []const Middleware,
    handler: HandlerFn,
    global_index: usize = 0,
    route_index: usize = 0,

    pub fn next(self: *Executor, ctx: *context_mod.Context) AppError!void {
        if (self.global_index < self.global_middlewares.len) {
            const current = self.global_middlewares[self.global_index];
            self.global_index += 1;
            return current.func(ctx, self);
        }

        if (self.route_index < self.route_middlewares.len) {
            const current = self.route_middlewares[self.route_index];
            self.route_index += 1;
            return current.func(ctx, self);
        }

        return self.handler(ctx);
    }
};
