const std = @import("std");

pub const SystemMemoryUsage = struct {
    total_bytes: u64,
    available_bytes: u64,
    used_bytes: u64,
    process_resident_bytes: u64,
    process_virtual_bytes: u64,

    pub fn init(
        total_bytes: u64,
        available_bytes: u64,
        used_bytes: u64,
        process_resident_bytes: u64,
        process_virtual_bytes: u64,
    ) SystemMemoryUsage {
        return .{
            .total_bytes = total_bytes,
            .available_bytes = available_bytes,
            .used_bytes = used_bytes,
            .process_resident_bytes = process_resident_bytes,
            .process_virtual_bytes = process_virtual_bytes,
        };
    }

    pub fn deinit(_: SystemMemoryUsage, _: std.mem.Allocator) void {}
};

pub const CpuUsage = struct {
    usage_percent: f64,
    user_time_ms: u64,
    system_time_ms: u64,
    logical_cores: usize,

    pub fn init(usage_percent: f64, user_time_ms: u64, system_time_ms: u64, logical_cores: usize) CpuUsage {
        return .{
            .usage_percent = usage_percent,
            .user_time_ms = user_time_ms,
            .system_time_ms = system_time_ms,
            .logical_cores = logical_cores,
        };
    }

    pub fn deinit(_: CpuUsage, _: std.mem.Allocator) void {}
};

pub const SystemResourcesRecord = struct {
    uptime_ms: u64,
    memory: SystemMemoryUsage,
    cpu: CpuUsage,

    pub fn init(uptime_ms: u64, memory: SystemMemoryUsage, cpu: CpuUsage) SystemResourcesRecord {
        return .{
            .uptime_ms = uptime_ms,
            .memory = memory,
            .cpu = cpu,
        };
    }

    pub fn deinit(self: SystemResourcesRecord, allocator: std.mem.Allocator) void {
        self.memory.deinit(allocator);
        self.cpu.deinit(allocator);
    }
};
