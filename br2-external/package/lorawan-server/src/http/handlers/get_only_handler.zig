const std = @import("std");

const context_mod = @import("../context.zig");
const handler_utils = @import("handler_utils.zig");

pub fn interface(comptime Record: type, comptime Repository: type) type {
    _ = Record;

    return struct {
        pub fn bind(comptime Impl: type) type {
            comptime ensureGetOnlyHandlerImplementation(Impl);

            return struct {
                pub fn get(ctx: *context_mod.Context) !void {
                    const repo: Repository = Impl.repo(ctx);
                    const record = try repo.get(ctx.allocator, try handler_utils.parseRouteId(ctx, Repository.IdType));
                    defer handler_utils.deinitRecord(ctx.allocator, record);
                    try ctx.res.setJson(record);
                }
            };
        }
    };
}

fn ensureGetOnlyHandlerImplementation(comptime Impl: type) void {
    const required = [_][]const u8{ "entity_name", "repo" };
    inline for (required) |decl_name| {
        if (!@hasDecl(Impl, decl_name)) {
            @compileError(std.fmt.comptimePrint(
                "{s} must implement `{s}` to satisfy GetOnlyHandler",
                .{ @typeName(Impl), decl_name },
            ));
        }
    }
}

test "GetOnlyHandler forwards get to repository" {
    const testing = std.testing;

    const Record = struct {
        value: u32,

        pub fn deinit(_: @This()) void {}
    };

    const Repo = struct {
        pub const IdType = u32;

        pub fn get(_: @This(), _: std.mem.Allocator, id: u32) !Record {
            return .{ .value = id };
        }
    };

    const FakeHandler = struct {
        pub const entity_name = "resource";

        pub fn repo(_: *context_mod.Context) Repo {
            return .{};
        }
    };

    const GetOnlyHandler = interface(Record, Repo);
    const Handler = GetOnlyHandler.bind(FakeHandler);

    var ctx = testContext(testing.allocator, .GET, "/resource/7");
    defer ctx.deinit();
    try ctx.setParams(&.{.{ .name = "id", .value = "7" }});

    try Handler.get(&ctx);
    try testing.expectEqualStrings("{\"value\":7}", ctx.res.body);
}

fn testContext(
    allocator: std.mem.Allocator,
    method: @import("../request.zig").Method,
    path: []const u8,
) context_mod.Context {
    return context_mod.Context.init(
        allocator,
        undefined,
        @import("../request.zig").Request.init(method, path, path, "", &.{}),
    );
}
