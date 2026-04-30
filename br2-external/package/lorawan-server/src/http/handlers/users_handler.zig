const std = @import("std");

const app_mod = @import("../../app.zig");
const context_mod = @import("../context.zig");
const crud_repository = @import("../../repository/crud_repository.zig");
const users_repository = @import("../../repository/users_repository.zig");

pub fn list(ctx: *context_mod.Context) !void {
    const params = try listParams(ctx, "name", .asc);
    const page = try ctx.services.users_repo.list(ctx.allocator, params);
    defer {
        for (page.entries) |*record| record.deinit(ctx.allocator);
        ctx.allocator.free(page.entries);
    }

    try ctx.res.setJson(page);
}

pub fn get(ctx: *context_mod.Context) !void {
    const name = ctx.param("id") orelse return error.BadRequest;
    const maybe_record = try ctx.services.users_repo.get(ctx.allocator, name);
    if (maybe_record == null) {
        try ctx.res.setJsonStatus(.not_found, app_mod.ErrorResponse.init("user not found"));
        return;
    }

    var record = maybe_record.?;
    defer record.deinit(ctx.allocator);
    try ctx.res.setJson(.{
        .data = record,
        .metadata = .{
            .scopes = users_repository.scopes(),
        },
    });
}

pub fn listScopes(ctx: *context_mod.Context) !void {
    const params = try listParams(ctx, "scope", .asc);
    const page = users_repository.scopesPage(params);
    try ctx.res.setJson(page);
}

pub fn create(ctx: *context_mod.Context) !void {
    const write_input = try parseWriteInput(ctx, ctx.req.body, .create);
    defer write_input.deinit(ctx.allocator);

    ctx.services.users_repo.create(write_input) catch {
        try ctx.res.setJsonStatus(.conflict, app_mod.ErrorResponse.init("user already exists or could not be created"));
        return;
    };

    try ctx.res.setJsonStatus(.created, app_mod.StatusResponse.init("created"));
}

pub fn update(ctx: *context_mod.Context) !void {
    const name = ctx.param("id") orelse return error.BadRequest;
    const write_input = try parseWriteInput(ctx, ctx.req.body, .update);
    defer write_input.deinit(ctx.allocator);

    const updated = try ctx.services.users_repo.update(name, write_input);
    if (!updated) {
        try ctx.res.setJsonStatus(.not_found, app_mod.ErrorResponse.init("user not found"));
        return;
    }

    try ctx.res.setJson(app_mod.StatusResponse.init("updated"));
}

pub fn delete(ctx: *context_mod.Context) !void {
    const name = ctx.param("id") orelse return error.BadRequest;
    const deleted = try ctx.services.users_repo.delete(name);
    if (!deleted) {
        try ctx.res.setJsonStatus(.not_found, app_mod.ErrorResponse.init("user not found"));
        return;
    }

    try ctx.res.setJson(app_mod.StatusResponse.init("deleted"));
}

const ParseMode = enum { create, update };

const UserWriteBody = struct {
    name: []const u8,
    password: ?[]const u8 = null,
    scopes: []const []const u8 = &.{},
    email: []const u8 = "",
    send_alerts: bool = false,
};

fn parseWriteInput(ctx: *context_mod.Context, body: []const u8, mode: ParseMode) !users_repository.WriteInput {
    const parsed = try std.json.parseFromSlice(UserWriteBody, ctx.allocator, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const trimmed_name = std.mem.trim(u8, parsed.value.name, " \t\r\n");
    if (trimmed_name.len == 0) return error.BadRequest;
    if (parsed.value.scopes.len == 0) return error.BadRequest;

    const password = if (parsed.value.password) |value| blk: {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0 and mode == .create) return error.BadRequest;
        break :blk if (trimmed.len == 0) null else try ctx.allocator.dupe(u8, trimmed);
    } else blk: {
        if (mode == .create) return error.BadRequest;
        break :blk null;
    };
    errdefer if (password) |value| ctx.allocator.free(value);

    var scopes = try ctx.allocator.alloc([]const u8, parsed.value.scopes.len);
    var initialized: usize = 0;
    errdefer {
        for (scopes[0..initialized]) |scope| ctx.allocator.free(scope);
        ctx.allocator.free(scopes);
    }
    for (parsed.value.scopes, 0..) |scope, index| {
        const trimmed = std.mem.trim(u8, scope, " \t\r\n");
        if (trimmed.len == 0) return error.BadRequest;
        scopes[index] = try ctx.allocator.dupe(u8, trimmed);
        initialized += 1;
    }

    return .{
        .name = try ctx.allocator.dupe(u8, trimmed_name),
        .password = password,
        .scopes = scopes,
        .email = try ctx.allocator.dupe(u8, std.mem.trim(u8, parsed.value.email, " \t\r\n")),
        .send_alerts = parsed.value.send_alerts,
    };
}

fn listParams(ctx: *context_mod.Context, default_sort_by: []const u8, default_sort_order: crud_repository.SortOrder) !crud_repository.ListParams {
    const page = try positiveQueryInt(ctx.req.queryParam("page"), 1);
    const page_size = try positiveQueryInt(ctx.req.queryParam("page_size"), 50);
    if (page_size > 200) return error.BadRequest;

    return .{
        .page = page,
        .page_size = page_size,
        .sort_by = ctx.req.queryParam("sort_by") orelse default_sort_by,
        .sort_order = try sortOrder(ctx.req.queryParam("sort_order"), default_sort_order),
    };
}

fn positiveQueryInt(value: ?[]const u8, default_value: usize) !usize {
    const text = value orelse return default_value;
    const parsed = std.fmt.parseInt(usize, text, 10) catch return error.BadRequest;
    if (parsed == 0) return error.BadRequest;
    return parsed;
}

fn sortOrder(value: ?[]const u8, default_value: crud_repository.SortOrder) !crud_repository.SortOrder {
    const text = value orelse return default_value;
    if (std.ascii.eqlIgnoreCase(text, "asc")) return .asc;
    if (std.ascii.eqlIgnoreCase(text, "desc")) return .desc;
    return error.BadRequest;
}
