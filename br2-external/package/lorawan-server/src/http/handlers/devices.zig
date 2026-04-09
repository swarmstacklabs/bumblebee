const std = @import("std");

const app_mod = @import("../../app.zig");
const context_mod = @import("../context.zig");

pub fn list(ctx: *context_mod.Context) !void {
    const repo = ctx.services.device_repo;
    const devices = try repo.list(ctx.allocator);
    defer {
        for (devices) |device| device.deinit(ctx.allocator);
        ctx.allocator.free(devices);
    }

    var out = std.ArrayList(u8){};
    defer out.deinit(ctx.allocator);

    try out.appendSlice(ctx.allocator, "[");
    var first = true;
    for (devices) |device| {
        if (!first) try out.appendSlice(ctx.allocator, ",");
        first = false;

        const json = try std.json.Stringify.valueAlloc(ctx.allocator, device, .{});
        defer ctx.allocator.free(json);
        try out.appendSlice(ctx.allocator, json);
    }
    try out.appendSlice(ctx.allocator, "]\n");

    ctx.res.setOwnedBody(200, "application/json", try out.toOwnedSlice(ctx.allocator));
}

pub fn get(ctx: *context_mod.Context) !void {
    const id = try parseRouteId(ctx);
    const repo = ctx.services.device_repo;
    const maybe_device = try repo.get(ctx.allocator, id);
    if (maybe_device == null) {
        try ctx.res.setJsonStatus(404, app_mod.ErrorResponse{ .@"error" = "device not found" });
        return;
    }
    const device = maybe_device.?;
    defer device.deinit(ctx.allocator);

    try ctx.res.setJson(device);
}

pub fn create(ctx: *context_mod.Context) !void {
    const write_input = try parseDeviceWriteInput(ctx, ctx.req.body);
    defer write_input.deinit(ctx.allocator);

    const repo = ctx.services.device_repo;
    repo.create(write_input) catch {
        try ctx.res.setJsonStatus(409, app_mod.ErrorResponse{ .@"error" = "device already exists or could not be created" });
        return;
    };

    try ctx.res.setJsonStatus(201, app_mod.StatusResponse{ .status = "created" });
}

pub fn update(ctx: *context_mod.Context) !void {
    const id = try parseRouteId(ctx);
    const write_input = try parseDeviceWriteInput(ctx, ctx.req.body);
    defer write_input.deinit(ctx.allocator);

    const repo = ctx.services.device_repo;
    const updated = try repo.update(id, write_input);
    if (!updated) {
        try ctx.res.setJsonStatus(404, app_mod.ErrorResponse{ .@"error" = "device not found" });
        return;
    }

    try ctx.res.setJson(app_mod.StatusResponse{ .status = "updated" });
}

pub fn delete(ctx: *context_mod.Context) !void {
    const id = try parseRouteId(ctx);
    const repo = ctx.services.device_repo;
    const deleted = try repo.delete(id);
    if (!deleted) {
        try ctx.res.setJsonStatus(404, app_mod.ErrorResponse{ .@"error" = "device not found" });
        return;
    }

    try ctx.res.setJson(app_mod.StatusResponse{ .status = "deleted" });
}

fn parseDeviceWriteInput(ctx: *context_mod.Context, body: []const u8) !app_mod.DeviceWriteInput {
    const parsed = try std.json.parseFromSlice(app_mod.DeviceWriteInput, ctx.allocator, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return .{
        .name = try ctx.allocator.dupe(u8, parsed.value.name),
        .dev_eui = try ctx.allocator.dupe(u8, parsed.value.dev_eui),
        .app_eui = try ctx.allocator.dupe(u8, parsed.value.app_eui),
        .app_key = try ctx.allocator.dupe(u8, parsed.value.app_key),
    };
}

fn parseRouteId(ctx: *context_mod.Context) !i64 {
    const id_text = ctx.param("id") orelse return error.BadRequest;
    return std.fmt.parseInt(i64, id_text, 10);
}
