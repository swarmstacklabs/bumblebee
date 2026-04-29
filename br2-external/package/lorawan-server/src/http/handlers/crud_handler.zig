const std = @import("std");

const app_mod = @import("../../app.zig");
const context_mod = @import("../context.zig");
const crud_repository = @import("../../repository/crud_repository.zig");

const StatusResponse = app_mod.StatusResponse;
const ErrorResponse = app_mod.ErrorResponse;

pub fn interface(comptime Record: type, comptime WriteInput: type, comptime Id: type, comptime Repository: type) type {
    _ = Record;
    _ = WriteInput;

    return struct {
        const Self = @This();

        pub fn bind(comptime Impl: type) type {
            comptime ensureCrudHandlerImplementation(Impl);

            return struct {
                pub fn list(ctx: *context_mod.Context) !void {
                    const params = try parseListParams(ctx, Impl);
                    const repo: Repository = Impl.repo(ctx);
                    const page = try repo.list(ctx.allocator, params);
                    defer {
                        for (page.entries) |record| deinitRecord(ctx.allocator, record);
                        ctx.allocator.free(page.entries);
                    }

                    if (@hasDecl(Impl, "normalizeList")) {
                        try Impl.normalizeList(ctx, page.entries);
                    }

                    const json = try std.json.Stringify.valueAlloc(ctx.allocator, page, .{});
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
    if (@hasDecl(@TypeOf(record), "deinit")) {
        var mutable_record = record;
        mutable_record.deinit(allocator);
    }
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

fn parseListParams(ctx: *context_mod.Context, comptime Impl: type) !crud_repository.ListParams {
    const default_page_size: usize = if (@hasDecl(Impl, "default_page_size")) Impl.default_page_size else 50;
    const max_page_size: usize = if (@hasDecl(Impl, "max_page_size")) Impl.max_page_size else 100;
    const default_sort_by: []const u8 = if (@hasDecl(Impl, "default_sort_by")) Impl.default_sort_by else "id";
    const default_sort_order: crud_repository.SortOrder = if (@hasDecl(Impl, "default_sort_order")) Impl.default_sort_order else .asc;

    const page = try parsePositiveQueryInt(ctx.req.queryParam("page"), 1);
    const page_size = try parsePositiveQueryInt(ctx.req.queryParam("page_size"), default_page_size);
    if (page_size > max_page_size) return error.BadRequest;

    const requested_sort_by = ctx.req.queryParam("sort_by") orelse default_sort_by;
    const sort_by = if (@hasDecl(Impl, "normalizeSortBy")) try Impl.normalizeSortBy(requested_sort_by) else requested_sort_by;
    const sort_order = try parseSortOrder(ctx.req.queryParam("sort_order"), default_sort_order);

    return .{
        .page = page,
        .page_size = page_size,
        .sort_by = sort_by,
        .sort_order = sort_order,
    };
}

fn parsePositiveQueryInt(value: ?[]const u8, default_value: usize) !usize {
    const text = value orelse return default_value;
    const parsed = std.fmt.parseInt(usize, text, 10) catch return error.BadRequest;
    if (parsed == 0) return error.BadRequest;
    return parsed;
}

fn parseSortOrder(value: ?[]const u8, default_value: crud_repository.SortOrder) !crud_repository.SortOrder {
    const text = value orelse return default_value;
    if (std.ascii.eqlIgnoreCase(text, "asc")) return .asc;
    if (std.ascii.eqlIgnoreCase(text, "desc")) return .desc;
    return error.BadRequest;
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
        var last_list_page: ?usize = null;
        var last_list_page_size: ?usize = null;
        var last_list_sort_by: ?[]const u8 = null;
        var last_list_sort_order: ?crud_repository.SortOrder = null;
        var last_created_name: ?[]const u8 = null;
        var last_updated_id: ?i64 = null;
        var last_updated_name: ?[]const u8 = null;
        var last_deleted_id: ?i64 = null;
    };

    const Repo = struct {
        pub fn list(_: @This(), allocator: std.mem.Allocator, params: crud_repository.ListParams) !crud_repository.ListPage(Record) {
            State.last_list_page = params.page;
            State.last_list_page_size = params.page_size;
            State.last_list_sort_by = params.sort_by;
            State.last_list_sort_order = params.sort_order;

            var out = try allocator.alloc(Record, 1);
            out[0] = .{ .id = 1, .name = "one" };
            return crud_repository.ListPage(Record).init(out, params, 3);
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
        pub const default_sort_by = "id";
        pub const default_sort_order = crud_repository.SortOrder.asc;

        pub fn repo(_: *context_mod.Context) Repo {
            return .{};
        }

        pub fn parseWriteInput(ctx: *context_mod.Context, body: []const u8) !WriteInput {
            _ = ctx;
            return .{ .name = body };
        }
    };

    const CrudHandler = interface(Record, WriteInput, i64, Repo);
    const Handler = CrudHandler.bind(FakeHandler);

    State.last_created_name = null;
    State.last_list_page = null;
    State.last_list_page_size = null;
    State.last_list_sort_by = null;
    State.last_list_sort_order = null;
    State.last_updated_id = null;
    State.last_updated_name = null;
    State.last_deleted_id = null;

    var ctx = testContext(testing.allocator, .GET, "/devices?page=2&page_size=1&sort_by=name&sort_order=desc", "", null);
    defer ctx.deinit();
    try Handler.list(&ctx);
    try testing.expectEqual(@as(?usize, 2), State.last_list_page);
    try testing.expectEqual(@as(?usize, 1), State.last_list_page_size);
    try testing.expectEqualStrings("name", State.last_list_sort_by.?);
    try testing.expectEqual(@as(?crud_repository.SortOrder, .desc), State.last_list_sort_order);
    try testing.expectEqualStrings("{\"entries\":[{\"id\":1,\"name\":\"one\"}],\"page_number\":2,\"page_size\":1,\"total_entries\":3,\"total_pages\":3,\"sort_by\":\"name\",\"sort_order\":\"desc\"}", ctx.res.body);

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
        pub fn list(_: @This(), allocator: std.mem.Allocator, params: crud_repository.ListParams) !crud_repository.ListPage(Record) {
            return crud_repository.ListPage(Record).init(try allocator.alloc(Record, 0), params, 0);
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
        pub const default_sort_by = "id";
        pub const default_sort_order = crud_repository.SortOrder.asc;

        pub fn repo(_: *context_mod.Context) Repo {
            return .{};
        }

        pub fn parseWriteInput(ctx: *context_mod.Context, body: []const u8) !WriteInput {
            _ = ctx;
            return .{ .name = body };
        }
    };

    const CrudHandler = interface(Record, WriteInput, i64, Repo);
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

test "CRUDHandler rejects invalid paging and sorting query params" {
    const testing = std.testing;

    const Record = struct {
        id: i64,

        pub fn deinit(_: @This(), _: std.mem.Allocator) void {}
    };

    const WriteInput = struct {
        pub fn deinit(_: @This(), _: std.mem.Allocator) void {}
    };

    const Repo = struct {
        pub fn list(_: @This(), allocator: std.mem.Allocator, params: crud_repository.ListParams) !crud_repository.ListPage(Record) {
            return crud_repository.ListPage(Record).init(try allocator.alloc(Record, 0), params, 0);
        }

        pub fn get(_: @This(), _: std.mem.Allocator, _: i64) !?Record {
            return null;
        }

        pub fn create(_: @This(), _: WriteInput) !void {}

        pub fn update(_: @This(), _: i64, _: WriteInput) !bool {
            return false;
        }

        pub fn delete(_: @This(), _: i64) !bool {
            return false;
        }
    };

    const FakeHandler = struct {
        pub const entity_name = "device";
        pub const default_sort_by = "id";

        pub fn repo(_: *context_mod.Context) Repo {
            return .{};
        }

        pub fn parseWriteInput(_: *context_mod.Context, _: []const u8) !WriteInput {
            return .{};
        }

        pub fn normalizeSortBy(sort_by: []const u8) ![]const u8 {
            if (std.mem.eql(u8, sort_by, "id")) return sort_by;
            return error.BadRequest;
        }
    };

    const CrudHandler = interface(Record, WriteInput, i64, Repo);
    const Handler = CrudHandler.bind(FakeHandler);

    var bad_page_ctx = testContext(testing.allocator, .GET, "/devices?page=0", "", null);
    defer bad_page_ctx.deinit();
    try testing.expectError(error.BadRequest, Handler.list(&bad_page_ctx));

    var bad_sort_ctx = testContext(testing.allocator, .GET, "/devices?sort_order=sideways", "", null);
    defer bad_sort_ctx.deinit();
    try testing.expectError(error.BadRequest, Handler.list(&bad_sort_ctx));

    var bad_field_ctx = testContext(testing.allocator, .GET, "/devices?sort_by=name", "", null);
    defer bad_field_ctx.deinit();
    try testing.expectError(error.BadRequest, Handler.list(&bad_field_ctx));
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
