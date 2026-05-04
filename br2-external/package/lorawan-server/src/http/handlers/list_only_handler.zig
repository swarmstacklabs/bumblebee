const std = @import("std");

const context_mod = @import("../context.zig");
const handler_utils = @import("handler_utils.zig");

pub fn interface(comptime Record: type, comptime Repository: type) type {
    _ = Record;

    return struct {
        pub fn bind(comptime Impl: type) type {
            comptime ensureListOnlyHandlerImplementation(Impl);

            return struct {
                pub fn list(ctx: *context_mod.Context) anyerror!void {
                    const params = try handler_utils.parseListParams(ctx, Impl);
                    const repo: Repository = Impl.repo(ctx);
                    const page = try repo.list(ctx.allocator, params);
                    defer {
                        for (page.entries) |record| handler_utils.deinitRecord(ctx.allocator, record);
                        ctx.allocator.free(page.entries);
                    }

                    try ctx.res.setJson(page);
                }
            };
        }
    };
}

fn ensureListOnlyHandlerImplementation(comptime Impl: type) void {
    const required = [_][]const u8{ "entity_name", "repo" };
    inline for (required) |decl_name| {
        if (!@hasDecl(Impl, decl_name)) {
            @compileError(std.fmt.comptimePrint(
                "{s} must implement `{s}` to satisfy ListOnlyHandler",
                .{ @typeName(Impl), decl_name },
            ));
        }
    }
}
