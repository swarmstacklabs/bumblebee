const std = @import("std");

const context_mod = @import("../context.zig");
const paging = @import("../../repository/paging.zig");

pub fn notFoundMessage(comptime entity_name: []const u8) []const u8 {
    return std.fmt.comptimePrint("{s} not found", .{entity_name});
}

pub fn createConflictMessage(comptime entity_name: []const u8) []const u8 {
    return std.fmt.comptimePrint("{s} already exists or could not be created", .{entity_name});
}

pub fn deinitRecord(allocator: std.mem.Allocator, record: anytype) void {
    if (@hasDecl(@TypeOf(record), "deinit")) {
        var mutable_record = record;
        switch (@typeInfo(@TypeOf(@TypeOf(record).deinit)).@"fn".params.len) {
            1 => mutable_record.deinit(),
            2 => mutable_record.deinit(allocator),
            else => @compileError("record deinit must accept either self or self plus allocator"),
        }
    }
}

pub fn deinitWriteInput(allocator: std.mem.Allocator, write_input: anytype) void {
    if (@hasDecl(@TypeOf(write_input), "deinit")) {
        var mutable_write_input = write_input;
        switch (@typeInfo(@TypeOf(@TypeOf(write_input).deinit)).@"fn".params.len) {
            1 => mutable_write_input.deinit(),
            2 => mutable_write_input.deinit(allocator),
            else => @compileError("write input deinit must accept either self or self plus allocator"),
        }
    }
}

pub fn parseRouteId(ctx: *context_mod.Context, comptime Id: type) !Id {
    const id_text = ctx.param("id") orelse return error.BadRequest;
    return parseId(Id, id_text);
}

pub fn parseId(comptime T: type, value: []const u8) !T {
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, value, 10),
        .pointer => |pointer| switch (pointer.size) {
            .slice => if (pointer.child == u8) value else @compileError(std.fmt.comptimePrint(
                "handler only supports []const u8 slice ids, got {s}",
                .{@typeName(T)},
            )),
            else => @compileError(std.fmt.comptimePrint(
                "handler does not support id type {s}",
                .{@typeName(T)},
            )),
        },
        else => @compileError(std.fmt.comptimePrint(
            "handler does not support id type {s}",
            .{@typeName(T)},
        )),
    };
}

pub fn parseListParams(ctx: *context_mod.Context, comptime Impl: type) !paging.ListParams {
    const default_page_size: usize = if (@hasDecl(Impl, "default_page_size")) Impl.default_page_size else 50;
    const max_page_size: usize = if (@hasDecl(Impl, "max_page_size")) Impl.max_page_size else 100;
    const default_sort_by: []const u8 = if (@hasDecl(Impl, "default_sort_by")) Impl.default_sort_by else "id";
    const default_sort_order: paging.SortOrder = if (@hasDecl(Impl, "default_sort_order")) Impl.default_sort_order else .asc;

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

fn parseSortOrder(value: ?[]const u8, default_value: paging.SortOrder) !paging.SortOrder {
    const text = value orelse return default_value;
    if (std.ascii.eqlIgnoreCase(text, "asc")) return .asc;
    if (std.ascii.eqlIgnoreCase(text, "desc")) return .desc;
    return error.BadRequest;
}
