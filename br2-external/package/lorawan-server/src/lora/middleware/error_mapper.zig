const std = @import("std");

const context_mod = @import("../context.zig");
const logger = @import("../../logger.zig");
const runtime = @import("../runtime.zig");

pub fn middleware(ctx: *context_mod.Context, exec: *runtime.Executor) runtime.AppError!void {
    exec.next(ctx) catch |err| {
        const mapped = mapError(err) orelse return err;
        const command_tag = ctx.currentTag() catch null;

        logger.warn("lora_mac", "command_error_mapped", "normalized low-level mac command error", .{
            .command = if (command_tag) |tag| @tagName(tag) else null,
            .command_index = ctx.command_index,
            .error_category = mapped.category,
            .source_error = @errorName(err),
            .app_error = @errorName(mapped.err),
        });

        return mapped.err;
    };
}

const MappedError = struct {
    err: anyerror,
    category: []const u8,
};

fn mapError(err: anyerror) ?MappedError {
    return switch (err) {
        error.MalformedMacCommandPayload => .{
            .err = error.MacCommandInvalidInput,
            .category = "validation",
        },
        error.UnsupportedMacCommandPayload => .{
            .err = error.MacCommandUnsupportedInput,
            .category = "validation",
        },
        error.MissingMacCommandNodeContext,
        error.MissingMacCommandRegionContext,
        error.MissingMacCommandPendingState,
        => .{
            .err = error.MacCommandContextMissing,
            .category = "context",
        },
        error.InvalidMacCommandPendingState => .{
            .err = error.MacCommandStateInvalid,
            .category = "state",
        },
        error.UnmatchedMacCommandAnswer => .{
            .err = error.MacCommandCorrelationFailed,
            .category = "correlation",
        },
        else => null,
    };
}

test "mapError normalizes validation and context errors" {
    try std.testing.expectEqual(error.MacCommandInvalidInput, mapError(error.MalformedMacCommandPayload).?.err);
    try std.testing.expectEqual(error.MacCommandUnsupportedInput, mapError(error.UnsupportedMacCommandPayload).?.err);
    try std.testing.expectEqual(error.MacCommandContextMissing, mapError(error.MissingMacCommandNodeContext).?.err);
    try std.testing.expectEqual(error.MacCommandStateInvalid, mapError(error.InvalidMacCommandPendingState).?.err);
    try std.testing.expectEqual(error.MacCommandCorrelationFailed, mapError(error.UnmatchedMacCommandAnswer).?.err);
    try std.testing.expectEqual(@as(?MappedError, null), mapError(error.OutOfMemory));
}
