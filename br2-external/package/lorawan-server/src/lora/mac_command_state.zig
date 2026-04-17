const std = @import("std");

const commands = @import("commands.zig");
const context_mod = @import("context.zig");
const metrics_repository = @import("../repository/mac_command_metrics_repository.zig");
const types = @import("types.zig");

pub const Mode = enum {
    response,
    node_update,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    mode: Mode,
    rx_time_ms: ?i64 = null,
    link_margin: u8 = 0,
    gateway_count: usize = 0,
    node: ?*types.Node = null,
    region: ?types.Region = null,
    pending_commands: []const commands.Command = &.{},
    pending_state_ready: bool = false,
    pending_index: usize = 0,
    remaining_pending: std.ArrayListUnmanaged(commands.Command) = .{},
    correlated_pending: ?commands.Command = null,
    metrics_collector: ?*MetricsCollector = null,
    metrics_repo: ?*metrics_repository.Repository = null,
};

pub const CommandMetrics = struct {
    success_count: u64 = 0,
    failure_count: u64 = 0,
    total_latency_ns: u64 = 0,
    min_latency_ns: ?u64 = null,
    max_latency_ns: u64 = 0,
};

pub const MetricsOutcome = enum {
    success,
    failure,
};

pub const MetricsCollector = struct {
    const tag_count = std.meta.tags(commands.Command).len;

    entries: [tag_count]CommandMetrics = initEmptyEntries(),

    pub fn observe(self: *MetricsCollector, tag: context_mod.CommandTag, outcome: MetricsOutcome, latency_ns: u64) void {
        var entry = &self.entries[tagIndex(tag)];
        switch (outcome) {
            .success => entry.success_count += 1,
            .failure => entry.failure_count += 1,
        }
        entry.total_latency_ns += latency_ns;
        if (entry.min_latency_ns == null or latency_ns < entry.min_latency_ns.?) {
            entry.min_latency_ns = latency_ns;
        }
        if (latency_ns > entry.max_latency_ns) {
            entry.max_latency_ns = latency_ns;
        }
    }

    pub fn metricsForTag(self: *const MetricsCollector, tag: context_mod.CommandTag) CommandMetrics {
        return self.entries[tagIndex(tag)];
    }

    fn tagIndex(tag: context_mod.CommandTag) usize {
        return @intFromEnum(tag);
    }

    fn initEmptyEntries() [tag_count]CommandMetrics {
        var entries: [tag_count]CommandMetrics = undefined;
        for (&entries) |*entry| {
            entry.* = .{};
        }
        return entries;
    }
};

pub fn requiresNode(tag: context_mod.CommandTag) bool {
    return switch (tag) {
        .link_adr_ans,
        .duty_cycle_ans,
        .rx_param_setup_ans,
        .dev_status_ans,
        .new_channel_ans,
        .rx_timing_setup_ans,
        .tx_param_setup_ans,
        .dl_channel_ans,
        => true,
        else => false,
    };
}

pub fn requiresRegion(tag: context_mod.CommandTag) bool {
    return switch (tag) {
        .link_adr_ans,
        .tx_param_setup_ans,
        .new_channel_ans,
        .dl_channel_ans,
        => true,
        else => false,
    };
}

pub fn requiresPendingState(tag: context_mod.CommandTag) bool {
    return switch (tag) {
        .link_adr_ans,
        .duty_cycle_ans,
        .rx_param_setup_ans,
        .dev_status_ans,
        .new_channel_ans,
        .rx_timing_setup_ans,
        .tx_param_setup_ans,
        .dl_channel_ans,
        => true,
        else => false,
    };
}
