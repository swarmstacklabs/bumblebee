const std = @import("std");

const context_mod = @import("../context.zig");
const mac_command_state = @import("../mac_command_state.zig");
const runtime = @import("../runtime.zig");

pub fn middleware(ctx: *context_mod.Context, exec: *runtime.Executor) runtime.AppError!void {
    const state = ctx.data(mac_command_state.State);
    const collector = state.metrics_collector;
    const metrics_repo = state.metrics_repo;
    if (collector == null and metrics_repo == null) return exec.next(ctx);

    const command_tag = try ctx.currentTag();
    const started_ns = std.time.nanoTimestamp();

    exec.next(ctx) catch |err| {
        const latency_ns = elapsedNs(started_ns);
        if (collector) |value| {
            value.observe(command_tag, .failure, latency_ns);
        }
        if (metrics_repo) |repo| {
            repo.insertObservation(@tagName(command_tag), "failure", latency_ns) catch {};
        }
        return err;
    };

    const latency_ns = elapsedNs(started_ns);
    if (collector) |value| {
        value.observe(command_tag, .success, latency_ns);
    }
    if (metrics_repo) |repo| {
        repo.insertObservation(@tagName(command_tag), "success", latency_ns) catch {};
    }
}

fn elapsedNs(started_ns: i128) u64 {
    const now_ns = std.time.nanoTimestamp();
    if (now_ns <= started_ns) return 0;
    return @intCast(@min(now_ns - started_ns, std.math.maxInt(u64)));
}
