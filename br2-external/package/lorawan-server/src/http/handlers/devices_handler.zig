const std = @import("std");

const app_mod = @import("../../app.zig");
const device_repository = @import("../../repository/device_repository.zig");
const crud_handler = @import("crud_handler.zig");
const context_mod = @import("../context.zig");
const crud_repository = @import("../../repository/crud_repository.zig");

pub const CRUDHandler = crud_handler.interface(
    app_mod.DeviceRecord,
    app_mod.DeviceWriteInput,
    i64,
    device_repository.CRUDRepository,
);

const Handler = CRUDHandler.bind(struct {
    pub const entity_name = "device";
    pub const default_page_size: usize = 50;
    pub const max_page_size: usize = 100;
    pub const default_sort_by = "id";
    pub const default_sort_order = crud_repository.SortOrder.asc;

    pub fn repo(ctx: *context_mod.Context) device_repository.CRUDRepository {
        return ctx.services.device_repo;
    }

    pub fn parseWriteInput(ctx: *context_mod.Context, body: []const u8) !app_mod.DeviceWriteInput {
        return parseDeviceWriteInput(ctx, body);
    }

    pub fn normalizeSortBy(sort_by: []const u8) ![]const u8 {
        if (std.mem.eql(u8, sort_by, "id")) return sort_by;
        if (std.mem.eql(u8, sort_by, "name")) return sort_by;
        if (std.mem.eql(u8, sort_by, "dev_eui")) return sort_by;
        if (std.mem.eql(u8, sort_by, "app_eui")) return sort_by;
        if (std.mem.eql(u8, sort_by, "created_at")) return sort_by;
        if (std.mem.eql(u8, sort_by, "updated_at")) return sort_by;
        return error.BadRequest;
    }
});

pub const list = Handler.list;
pub const get = Handler.get;
pub const create = Handler.create;
pub const update = Handler.update;
pub const delete = Handler.delete;

fn parseDeviceWriteInput(ctx: *context_mod.Context, body: []const u8) !app_mod.DeviceWriteInput {
    const parsed = try std.json.parseFromSlice(app_mod.DeviceWriteInput, ctx.allocator, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const trimmed_name = std.mem.trim(u8, parsed.value.name, " \t\r\n");
    if (trimmed_name.len == 0) return error.BadRequest;

    return app_mod.DeviceWriteInput.init(
        try ctx.allocator.dupe(u8, trimmed_name),
        try normalizeHexLower(ctx.allocator, parsed.value.dev_eui, 16),
        try normalizeHexLower(ctx.allocator, parsed.value.app_eui, 16),
        try normalizeHexLower(ctx.allocator, parsed.value.app_key, 32),
        parsed.value.network_name,
    );
}

fn normalizeHexLower(allocator: std.mem.Allocator, source: []const u8, expected_len: usize) ![]u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len != expected_len) return error.BadRequest;

    const out = try allocator.alloc(u8, trimmed.len);
    errdefer allocator.free(out);

    for (trimmed, 0..) |char, i| {
        if (!std.ascii.isHex(char)) return error.BadRequest;
        out[i] = std.ascii.toLower(char);
    }
    return out;
}
