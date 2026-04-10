const std = @import("std");

const context_mod = @import("../context.zig");

pub fn Interface(comptime Record: type, comptime Repository: type) type {
    _ = Record;

    return struct {
        pub fn bind(comptime Impl: type) type {
            comptime ensureReadOnlyHandlerImplementation(Impl);

            return struct {
                pub fn get(ctx: *context_mod.Context) !void {
                    const repo: Repository = Impl.repo(ctx);
                    const record = try repo.get(ctx.allocator);
                    try ctx.res.setJson(record);
                }
            };
        }
    };
}

fn ensureReadOnlyHandlerImplementation(comptime Impl: type) void {
    const required = [_][]const u8{ "entity_name", "repo" };
    inline for (required) |decl_name| {
        if (!@hasDecl(Impl, decl_name)) {
            @compileError(std.fmt.comptimePrint(
                "{s} must implement `{s}` to satisfy ReadOnlyHandler",
                .{ @typeName(Impl), decl_name },
            ));
        }
    }
}

test "ReadOnlyHandler forwards get to repository" {
    const testing = std.testing;

    const Record = struct {
        value: u32,

        pub fn deinit(_: @This()) void {}
    };

    const Repo = struct {
        pub fn get(_: @This(), _: std.mem.Allocator) !Record {
            return .{ .value = 7 };
        }
    };

    const FakeHandler = struct {
        pub const entity_name = "resource";

        pub fn repo(_: *context_mod.Context) Repo {
            return .{};
        }
    };

    const ReadOnlyHandler = Interface(Record, Repo);
    const Handler = ReadOnlyHandler.bind(FakeHandler);

    var ctx = testContext(testing.allocator, .GET, "/resource");
    defer ctx.deinit();

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
