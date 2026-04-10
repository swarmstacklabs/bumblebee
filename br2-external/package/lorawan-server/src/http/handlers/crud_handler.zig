const std = @import("std");

const app_mod = @import("../../app.zig");
const context_mod = @import("../context.zig");

const StatusResponse = app_mod.StatusResponse;
const ErrorResponse = app_mod.ErrorResponse;

pub fn Interface(comptime Record: type, comptime WriteInput: type, comptime Id: type, comptime Repository: type) type {
    _ = Record;
    _ = WriteInput;

    return struct {
        const Self = @This();

        pub fn bind(comptime Impl: type) type {
            comptime ensureCrudHandlerImplementation(Impl);

            return struct {
                pub fn list(ctx: *context_mod.Context) !void {
                    const repo: Repository = Impl.repo(ctx);
                    const records = try repo.list(ctx.allocator);
                    defer {
                        for (records) |record| deinitRecord(ctx.allocator, record);
                        ctx.allocator.free(records);
                    }

                    if (@hasDecl(Impl, "normalizeList")) {
                        try Impl.normalizeList(ctx, records);
                    }

                    const json = try std.json.Stringify.valueAlloc(ctx.allocator, records, .{});
                    ctx.res.setOwnedBody(.ok, "application/json", json);
                }

                pub fn get(ctx: *context_mod.Context) !void {
                    const id = try parseRouteId(ctx);
                    const repo: Repository = Impl.repo(ctx);
                    const maybe_record = try repo.get(ctx.allocator, id);
                    if (maybe_record == null) {
                        try ctx.res.setJsonStatus(.not_found, ErrorResponse.init(notFoundMessage(Impl.entity_name)));
                        return;
                    }

                    const record = maybe_record.?;
                    defer deinitRecord(ctx.allocator, record);

                    try ctx.res.setJson(record);
                }

                pub fn create(ctx: *context_mod.Context) !void {
                    const write_input = try Impl.parseWriteInput(ctx, ctx.req.body);
                    defer deinitWriteInput(ctx.allocator, write_input);

                    const repo: Repository = Impl.repo(ctx);
                    repo.create(write_input) catch {
                        try ctx.res.setJsonStatus(.conflict, ErrorResponse.init(createConflictMessage(Impl.entity_name)));
                        return;
                    };

                    try ctx.res.setJsonStatus(.created, StatusResponse.init("created"));
                }

                pub fn update(ctx: *context_mod.Context) !void {
                    const id = try parseRouteId(ctx);
                    const write_input = try Impl.parseWriteInput(ctx, ctx.req.body);
                    defer deinitWriteInput(ctx.allocator, write_input);

                    const repo: Repository = Impl.repo(ctx);
                    const updated = try repo.update(id, write_input);
                    if (!updated) {
                        try ctx.res.setJsonStatus(.not_found, ErrorResponse.init(notFoundMessage(Impl.entity_name)));
                        return;
                    }

                    try ctx.res.setJson(StatusResponse.init("updated"));
                }

                pub fn delete(ctx: *context_mod.Context) !void {
                    const id = try parseRouteId(ctx);
                    const repo: Repository = Impl.repo(ctx);
                    const deleted = try repo.delete(id);
                    if (!deleted) {
                        try ctx.res.setJsonStatus(.not_found, ErrorResponse.init(notFoundMessage(Impl.entity_name)));
                        return;
                    }

                    try ctx.res.setJson(StatusResponse.init("deleted"));
                }

                fn parseRouteId(ctx: *context_mod.Context) !Id {
                    const id_text = ctx.param("id") orelse return error.BadRequest;
                    return parseId(Id, id_text);
                }
            };
        }
    };
}

fn ensureCrudHandlerImplementation(comptime Impl: type) void {
    const required = [_][]const u8{ "entity_name", "repo", "parseWriteInput" };
    inline for (required) |decl_name| {
        if (!@hasDecl(Impl, decl_name)) {
            @compileError(std.fmt.comptimePrint(
                "{s} must implement `{s}` to satisfy CRUDHandler",
                .{ @typeName(Impl), decl_name },
            ));
        }
    }
}

fn notFoundMessage(comptime entity_name: []const u8) []const u8 {
    return std.fmt.comptimePrint("{s} not found", .{entity_name});
}

fn createConflictMessage(comptime entity_name: []const u8) []const u8 {
    return std.fmt.comptimePrint("{s} already exists or could not be created", .{entity_name});
}

fn deinitRecord(allocator: std.mem.Allocator, record: anytype) void {
    if (@hasDecl(@TypeOf(record), "deinit")) record.deinit(allocator);
}

fn deinitWriteInput(allocator: std.mem.Allocator, write_input: anytype) void {
    if (@hasDecl(@TypeOf(write_input), "deinit")) write_input.deinit(allocator);
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

test "CRUDHandler forwards operations to implementation" {
    const testing = std.testing;

    const Record = struct {
        id: i64,
        name: []const u8,

        pub fn deinit(_: @This(), _: std.mem.Allocator) void {}
    };

    const WriteInput = struct {
        name: []const u8,

        pub fn deinit(_: @This(), _: std.mem.Allocator) void {}
    };

    const State = struct {
        var last_created_name: ?[]const u8 = null;
        var last_updated_id: ?i64 = null;
        var last_updated_name: ?[]const u8 = null;
        var last_deleted_id: ?i64 = null;
    };

    const Repo = struct {
        pub fn list(_: @This(), allocator: std.mem.Allocator) ![]Record {
            var out = try allocator.alloc(Record, 1);
            out[0] = .{ .id = 1, .name = "one" };
            return out;
        }

        pub fn get(_: @This(), _: std.mem.Allocator, id: i64) !?Record {
            return .{ .id = id, .name = "picked" };
        }

        pub fn create(_: @This(), write_input: WriteInput) !void {
            State.last_created_name = write_input.name;
        }

        pub fn update(_: @This(), id: i64, write_input: WriteInput) !bool {
            State.last_updated_id = id;
            State.last_updated_name = write_input.name;
            return true;
        }

        pub fn delete(_: @This(), id: i64) !bool {
            State.last_deleted_id = id;
            return true;
        }
    };

    const FakeHandler = struct {
        pub const entity_name = "device";

        pub fn repo(_: *context_mod.Context) Repo {
            return .{};
        }

        pub fn parseWriteInput(ctx: *context_mod.Context, body: []const u8) !WriteInput {
            _ = ctx;
            return .{ .name = body };
        }
    };

    const CrudHandler = Interface(Record, WriteInput, i64, Repo);
    const Handler = CrudHandler.bind(FakeHandler);

    State.last_created_name = null;
    State.last_updated_id = null;
    State.last_updated_name = null;
    State.last_deleted_id = null;

    var ctx = testContext(testing.allocator, .GET, "/devices", "", null);
    defer ctx.deinit();
    try Handler.list(&ctx);
    try testing.expectEqualStrings("[{\"id\":1,\"name\":\"one\"}]", ctx.res.body);

    var get_ctx = testContext(testing.allocator, .GET, "/devices/42", "", "42");
    defer get_ctx.deinit();
    try Handler.get(&get_ctx);
    try testing.expectEqualStrings("{\"id\":42,\"name\":\"picked\"}", get_ctx.res.body);

    var create_ctx = testContext(testing.allocator, .POST, "/devices", "created", null);
    defer create_ctx.deinit();
    try Handler.create(&create_ctx);
    try testing.expectEqualStrings("created", State.last_created_name.?);
    try testing.expectEqual(@as(u16, 201), create_ctx.res.status.code());

    var update_ctx = testContext(testing.allocator, .PUT, "/devices/7", "updated", "7");
    defer update_ctx.deinit();
    try Handler.update(&update_ctx);
    try testing.expectEqual(@as(?i64, 7), State.last_updated_id);
    try testing.expectEqualStrings("updated", State.last_updated_name.?);

    var delete_ctx = testContext(testing.allocator, .DELETE, "/devices/9", "", "9");
    defer delete_ctx.deinit();
    try Handler.delete(&delete_ctx);
    try testing.expectEqual(@as(?i64, 9), State.last_deleted_id);
}

test "CRUDHandler emits not found and conflict responses" {
    const testing = std.testing;

    const Record = struct {
        id: i64,

        pub fn deinit(_: @This(), _: std.mem.Allocator) void {}
    };

    const WriteInput = struct {
        name: []const u8,

        pub fn deinit(_: @This(), _: std.mem.Allocator) void {}
    };

    const Repo = struct {
        pub fn list(_: @This(), allocator: std.mem.Allocator) ![]Record {
            return allocator.alloc(Record, 0);
        }

        pub fn get(_: @This(), _: std.mem.Allocator, _: i64) !?Record {
            return null;
        }

        pub fn create(_: @This(), _: WriteInput) !void {
            return error.AlreadyExists;
        }

        pub fn update(_: @This(), _: i64, _: WriteInput) !bool {
            return false;
        }

        pub fn delete(_: @This(), _: i64) !bool {
            return false;
        }
    };

    const FakeHandler = struct {
        pub const entity_name = "device";

        pub fn repo(_: *context_mod.Context) Repo {
            return .{};
        }

        pub fn parseWriteInput(ctx: *context_mod.Context, body: []const u8) !WriteInput {
            _ = ctx;
            return .{ .name = body };
        }
    };

    const CrudHandler = Interface(Record, WriteInput, i64, Repo);
    const Handler = CrudHandler.bind(FakeHandler);

    var get_ctx = testContext(testing.allocator, .GET, "/devices/1", "", "1");
    defer get_ctx.deinit();
    try Handler.get(&get_ctx);
    try testing.expectEqual(@as(u16, 404), get_ctx.res.status.code());
    try testing.expectEqualStrings("{\"error\":\"device not found\"}", get_ctx.res.body);

    var create_ctx = testContext(testing.allocator, .POST, "/devices", "dupe", null);
    defer create_ctx.deinit();
    try Handler.create(&create_ctx);
    try testing.expectEqual(@as(u16, 409), create_ctx.res.status.code());
    try testing.expectEqualStrings("{\"error\":\"device already exists or could not be created\"}", create_ctx.res.body);

    var update_ctx = testContext(testing.allocator, .PUT, "/devices/1", "body", "1");
    defer update_ctx.deinit();
    try Handler.update(&update_ctx);
    try testing.expectEqual(@as(u16, 404), update_ctx.res.status.code());

    var delete_ctx = testContext(testing.allocator, .DELETE, "/devices/1", "", "1");
    defer delete_ctx.deinit();
    try Handler.delete(&delete_ctx);
    try testing.expectEqual(@as(u16, 404), delete_ctx.res.status.code());
}

fn testContext(
    allocator: std.mem.Allocator,
    method: @import("../request.zig").Method,
    path: []const u8,
    body: []const u8,
    id_param: ?[]const u8,
) context_mod.Context {
    var ctx = context_mod.Context.init(
        allocator,
        undefined,
        @import("../request.zig").Request.init(method, path, path, body, &.{}),
    );
    if (id_param) |id| {
        ctx.params.append(allocator, context_mod.RouteParam.init("id", id)) catch unreachable;
    }
    return ctx;
}
