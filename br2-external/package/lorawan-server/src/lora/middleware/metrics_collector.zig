const std = @import("std");

const commands = @import("../commands.zig");
const context_mod = @import("../context.zig");
const logger = @import("../../logger.zig");
const mac_command_state = @import("../mac_command_state.zig");
const metrics_repository = @import("../../repository/mac_command_metrics_repository.zig");
const runtime = @import("../runtime.zig");

pub fn middleware(ctx: *context_mod.Context, exec: *runtime.Executor) runtime.AppError!void {
    const state = ctx.data(mac_command_state.State);
    const collector = state.metrics_collector;
    const metrics_repo = state.metrics_repo;

    if (collector == null and metrics_repo == null) return exec.next(ctx);

    const command = try ctx.currentCommand();
    const started_ns = std.time.nanoTimestamp();

    exec.next(ctx) catch |err| {
        const latency_ns = elapsedNs(started_ns);
        observe(state, collector, metrics_repo, command, .failure, latency_ns);
        return err;
    };

    const latency_ns = elapsedNs(started_ns);
    observe(state, collector, metrics_repo, command, .success, latency_ns);
}

fn observe(
    state: *const mac_command_state.State,
    collector: ?*mac_command_state.MetricsCollector,
    metrics_repo: ?*metrics_repository.Repository,
    command: commands.Command,
    outcome: mac_command_state.MetricsOutcome,
    latency_ns: u64,
) void {
    const level = metricLevel(command, outcome);
    if (@intFromEnum(level) < @intFromEnum(state.metrics_min_level)) return;

    const command_tag = std.meta.activeTag(command);
    // Collect in-memory metrics (probably not nedded anymore, but leaving for now for easy access in tests and potential future use)
    if (collector) |value| {
        value.observe(command_tag, outcome, latency_ns);
    }

    // Collect in repository
    if (metrics_repo) |repo| {
        repo.insertObservation(@tagName(command_tag), @tagName(outcome), @tagName(level), latency_ns) catch {};
    }
}

fn elapsedNs(started_ns: i128) u64 {
    const now_ns = std.time.nanoTimestamp();
    if (now_ns <= started_ns) return 0;
    return @intCast(@min(now_ns - started_ns, std.math.maxInt(u64)));
}

fn metricLevel(command: commands.Command, outcome: mac_command_state.MetricsOutcome) logger.Level {
    if (outcome == .failure) return .err;
    return if (isAnomaly(command)) .info else .debug;
}

fn isAnomaly(command: commands.Command) bool {
    return switch (command) {
        .link_adr_ans => |answer| !answer.power_ack or !answer.data_rate_ack or !answer.channel_mask_ack,
        .rx_param_setup_ans => |answer| !answer.rx1_dr_offset_ack or !answer.rx2_data_rate_ack or !answer.channel_ack,
        .new_channel_ans => |answer| !answer.data_rate_range_ok or !answer.channel_freq_ok,
        .dl_channel_ans => |answer| !answer.uplink_freq_exists or !answer.channel_freq_ok,
        else => false,
    };
}
