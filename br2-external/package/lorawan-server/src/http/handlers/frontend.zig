const std = @import("std");

const context_mod = @import("../context.zig");
const frontend_assets = @import("../frontend_assets.zig");
const response_mod = @import("../response.zig");

pub fn handle(ctx: *context_mod.Context) !void {
    if (!frontend_assets.shouldHandleSpaPath(ctx.req.path)) {
        ctx.res.setText(.not_found, "not found\n");
        return;
    }

    var lookup_result = frontend_assets.lookup(ctx.allocator, ctx.services.frontend_root, ctx.req.path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => {
            try serveInvalidFrontendRoot(ctx, ctx.services.frontend_root, err);
            return;
        },
        else => return err,
    };
    defer lookup_result.deinit(ctx.allocator);

    switch (lookup_result) {
        .file => |asset| try serveAsset(ctx, asset.path, asset.content_type),
        .index => |asset| try serveAsset(ctx, asset.path, asset.content_type),
        .missing_index => |index_path| try serveMissingIndex(ctx, index_path),
    }
}

fn serveAsset(ctx: *context_mod.Context, path: []const u8, content_type: []const u8) !void {
    const body = frontend_assets.readFileAlloc(ctx.allocator, path) catch |err| {
        try serveReadFailure(ctx, path, err);
        return;
    };

    ctx.res.setOwnedBody(.ok, content_type, body);
}

fn serveMissingIndex(ctx: *context_mod.Context, index_path: []const u8) !void {
    const body = try std.fmt.allocPrint(
        ctx.allocator,
        "UI build missing ({s}). Set {s} to the Vue dist directory.\n",
        .{ index_path, "LORAWAN_SERVER_FRONTEND_ROOT" },
    );
    ctx.res.setOwnedBody(.service_unavailable, "text/plain; charset=utf-8", body);
}

fn serveInvalidFrontendRoot(ctx: *context_mod.Context, frontend_root: []const u8, err: anyerror) !void {
    const body = try std.fmt.allocPrint(
        ctx.allocator,
        "Invalid frontend root ({s}): {s}. Set {s} to the Vue dist directory.\n",
        .{ frontend_root, @errorName(err), "LORAWAN_SERVER_FRONTEND_ROOT" },
    );
    ctx.res.setOwnedBody(.service_unavailable, "text/plain; charset=utf-8", body);
}

fn serveReadFailure(ctx: *context_mod.Context, path: []const u8, err: anyerror) !void {
    const body = try std.fmt.allocPrint(
        ctx.allocator,
        "Failed to read {s}: {s}\n",
        .{ path, @errorName(err) },
    );
    ctx.res.setOwnedBody(response_mod.Status.internal_server_error, "text/plain; charset=utf-8", body);
}
