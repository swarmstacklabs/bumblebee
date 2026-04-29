const std = @import("std");

const context_mod = @import("../context.zig");

pub fn interface(comptime Record: type, comptime Repository: type) type {
    _ = Record;

    return struct {
        pub fn bind(comptime Impl: type) type {
            comptime ensureReadOnlyHandlerImplementation(Impl);

            return struct {
                pub fn list(ctx: *context_mod.Context) !void {
                    const params = try parseListParams(ctx, Impl);
                    const repo: Repository = Impl.repo(ctx);
                    const page = try repo.list(ctx.allocator, params);
                    defer {
                        for (page.entries) |record| deinitRecord(ctx.allocator, record);
                        ctx.allocator.free(page.entries);
                    }

                    try ctx.res.setJson(page);
                }

                pub fn get(ctx: *context_mod.Context) !void {
                    const repo: Repository = Impl.repo(ctx);
                    const id_text = ctx.param("id") orelse return error.BadRequest;
                    const record = try repo.get(ctx.allocator, try parseId(Repository.IdType, id_text));
                    defer deinitRecord(ctx.allocator, record);
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

fn deinitRecord(allocator: std.mem.Allocator, record: anytype) void {
    if (@hasDecl(@TypeOf(record), "deinit")) {
        var mutable_record = record;
        switch (@typeInfo(@TypeOf(@TypeOf(record).deinit)).@"fn".params.len) {
            1 => mutable_record.deinit(),
            2 => mutable_record.deinit(allocator),
            else => @compileError("record deinit must accept either self or self plus allocator"),
        }
    }
}

fn parseId(comptime T: type, value: []const u8) !T {
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, value, 10),
        .pointer => |pointer| switch (pointer.size) {
            .slice => if (pointer.child == u8) value else @compileError(std.fmt.comptimePrint(
                "CRUDHandler only supports []const u8 slice ids, got {s}",
                .{@typeName(T)},
            )),
            else => @compileError(std.fmt.comptimePrint(
                "CRUDHandler does not support id type {s}",
                .{@typeName(T)},
            )),
        },
        else => @compileError(std.fmt.comptimePrint(
            "CRUDHandler does not support id type {s}",
            .{@typeName(T)},
        )),
    };
}

fn parseListParams(ctx: *context_mod.Context, comptime Impl: type) !@import("../../repository/read_only_repository.zig").ListParams {
    const default_page_size: usize = if (@hasDecl(Impl, "default_page_size")) Impl.default_page_size else 50;
    const max_page_size: usize = if (@hasDecl(Impl, "max_page_size")) Impl.max_page_size else 100;
    const default_sort_by: []const u8 = if (@hasDecl(Impl, "default_sort_by")) Impl.default_sort_by else "id";
    const default_sort_order: @import("../../repository/read_only_repository.zig").SortOrder = if (@hasDecl(Impl, "default_sort_order")) Impl.default_sort_order else .asc;

    const page = try parsePositiveQueryInt(ctx.req.queryParam("page"), 1);
    const page_size = try parsePositiveQueryInt(ctx.req.queryParam("page_size"), default_page_size);
    if (page_size > max_page_size) return error.BadRequest;

    return .{
        .page = page,
        .page_size = page_size,
        .sort_by = ctx.req.queryParam("sort_by") orelse default_sort_by,
        .sort_order = try parseSortOrder(ctx.req.queryParam("sort_order"), default_sort_order),
    };
}

fn parsePositiveQueryInt(value: ?[]const u8, default_value: usize) !usize {
    const text = value orelse return default_value;
    const parsed = std.fmt.parseInt(usize, text, 10) catch return error.BadRequest;
    if (parsed == 0) return error.BadRequest;
    return parsed;
}

fn parseSortOrder(
    value: ?[]const u8,
    default_value: @import("../../repository/read_only_repository.zig").SortOrder,
) !@import("../../repository/read_only_repository.zig").SortOrder {
    const text = value orelse return default_value;
    if (std.ascii.eqlIgnoreCase(text, "asc")) return .asc;
    if (std.ascii.eqlIgnoreCase(text, "desc")) return .desc;
    return error.BadRequest;
}

test "ReadOnlyHandler forwards get to repository" {
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

    const ReadOnlyHandler = interface(Record, Repo);
    const Handler = ReadOnlyHandler.bind(FakeHandler);

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
