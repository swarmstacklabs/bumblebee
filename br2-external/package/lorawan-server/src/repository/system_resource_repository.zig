const std = @import("std");

const app_mod = @import("../app.zig");
const read_only_repository = @import("read_only_repository.zig");

const SystemResourcesRecord = app_mod.SystemResourcesRecord;
const SystemMemoryUsage = app_mod.SystemMemoryUsage;
const CpuUsage = app_mod.CpuUsage;

const paging_module = @import("paging.zig");
const ListParams = paging_module.ListParams;

pub const ReadOnlyRepository = read_only_repository.interface(SystemResourcesRecord, []const u8);
const Page = ReadOnlyRepository.Page;

pub const Repository = struct {
    pub fn init() Repository {
        return .{};
    }

    pub fn deinit(_: Repository) void {}

    pub fn get(_: Repository, allocator: std.mem.Allocator, _: []const u8) !SystemResourcesRecord {
        return getSystemResources(allocator);
    }

    pub fn list(_: Repository, allocator: std.mem.Allocator, params: ListParams) !Page {
        const systemResource = try getSystemResources(allocator);

        var out = std.ArrayList(SystemResourcesRecord){};

        errdefer {
            for (out.items) |item| item.deinit(allocator);
            out.deinit(allocator);
        }

        try out.append(allocator, systemResource);

        return ReadOnlyRepository.Page.init(try out.toOwnedSlice(allocator), params, 1);
    }
};

fn getSystemResources(allocator: std.mem.Allocator) !SystemResourcesRecord {
    const meminfo = try readProcFile(allocator, "/proc/meminfo", 4096);
    defer allocator.free(meminfo);

    const status = try readProcFile(allocator, "/proc/self/status", 4096);
    defer allocator.free(status);

    const stat = try readProcFile(allocator, "/proc/self/stat", 4096);
    defer allocator.free(stat);

    const uptime_text = try readProcFile(allocator, "/proc/uptime", 256);
    defer allocator.free(uptime_text);

    const memory = try parseMemoryUsage(meminfo, status);
    const cpu = try parseCpuUsage(stat, uptime_text);
    const uptime_ms = try parseProcessUptimeMs(stat, uptime_text);

    return SystemResourcesRecord.init(uptime_ms, memory, cpu);
}

pub fn readOnly() ReadOnlyRepository {
    return ReadOnlyRepository.bind(Repository);
}

fn readProcFile(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

fn parseMemoryUsage(meminfo_text: []const u8, status_text: []const u8) !SystemMemoryUsage {
    const total_bytes = (try parseMeminfoValue(meminfo_text, "MemTotal")) * 1024;
    const available_bytes = (try parseMeminfoValue(meminfo_text, "MemAvailable")) * 1024;
    const resident_bytes = (try parseStatusValue(status_text, "VmRSS")) * 1024;
    const virtual_bytes = (try parseStatusValue(status_text, "VmSize")) * 1024;
    const used_bytes = total_bytes -| available_bytes;

    return SystemMemoryUsage.init(
        total_bytes,
        available_bytes,
        used_bytes,
        resident_bytes,
        virtual_bytes,
    );
}

fn parseCpuUsage(stat_text: []const u8, uptime_text: []const u8) !CpuUsage {
    const proc_stat = try parseProcStat(stat_text);
    const system_uptime_s = try parseUptimeSeconds(uptime_text);
    const cpu_times = try getProcessCpuTimes();
    const logical_cores = try std.Thread.getCpuCount();

    const started_at_s = @as(f64, @floatFromInt(proc_stat.start_ticks)) / @as(f64, @floatFromInt(try getClockTicksPerSecond()));
    const elapsed_s = @max(system_uptime_s - started_at_s, 0.001);
    const total_cpu_s = @as(f64, @floatFromInt(cpu_times.user_time_us + cpu_times.system_time_us)) / @as(f64, std.time.us_per_s);
    const usage_percent = (total_cpu_s / elapsed_s) * 100.0;

    return CpuUsage.init(
        usage_percent,
        microsToRoundedMs(cpu_times.user_time_us),
        microsToRoundedMs(cpu_times.system_time_us),
        logical_cores,
    );
}

fn parseProcessUptimeMs(stat_text: []const u8, uptime_text: []const u8) !u64 {
    const proc_stat = try parseProcStat(stat_text);
    const system_uptime_s = try parseUptimeSeconds(uptime_text);
    const ticks_per_second = try getClockTicksPerSecond();
    const started_at_s = @as(f64, @floatFromInt(proc_stat.start_ticks)) / @as(f64, @floatFromInt(ticks_per_second));
    const elapsed_s = @max(system_uptime_s - started_at_s, 0.0);
    return @intFromFloat(elapsed_s * std.time.ms_per_s);
}

const ProcStat = struct {
    user_ticks: u64,
    system_ticks: u64,
    start_ticks: u64,
};

fn parseProcStat(stat_text: []const u8) !ProcStat {
    const end_name = std.mem.lastIndexOfScalar(u8, stat_text, ')') orelse return error.InvalidProcStat;
    var fields = std.mem.tokenizeScalar(u8, stat_text[end_name + 1 ..], ' ');

    var index: usize = 0;
    var user_ticks: ?u64 = null;
    var system_ticks: ?u64 = null;
    var start_ticks: ?u64 = null;

    while (fields.next()) |field| {
        if (field.len == 0) continue;
        index += 1;

        switch (index) {
            12 => user_ticks = try std.fmt.parseInt(u64, field, 10),
            13 => system_ticks = try std.fmt.parseInt(u64, field, 10),
            20 => start_ticks = try std.fmt.parseInt(u64, field, 10),
            else => {},
        }
    }

    return .{
        .user_ticks = user_ticks orelse return error.InvalidProcStat,
        .system_ticks = system_ticks orelse return error.InvalidProcStat,
        .start_ticks = start_ticks orelse return error.InvalidProcStat,
    };
}

fn parseUptimeSeconds(uptime_text: []const u8) !f64 {
    const first_field_end = std.mem.indexOfScalar(u8, uptime_text, ' ') orelse uptime_text.len;
    return std.fmt.parseFloat(f64, std.mem.trim(u8, uptime_text[0..first_field_end], " \t\r\n"));
}

fn parseMeminfoValue(text: []const u8, label: []const u8) !u64 {
    return parseProcKeyValue(text, label);
}

fn parseStatusValue(text: []const u8, label: []const u8) !u64 {
    return parseProcKeyValue(text, label);
}

fn parseProcKeyValue(text: []const u8, label: []const u8) !u64 {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.mem.eql(u8, name, label)) continue;

        var tokens = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        const value = tokens.next() orelse return error.MissingProcValue;
        return std.fmt.parseInt(u64, value, 10);
    }

    return error.MissingProcValue;
}

fn getClockTicksPerSecond() !u64 {
    const c = @cImport({
        @cInclude("unistd.h");
    });

    const value = c.sysconf(c._SC_CLK_TCK);
    if (value <= 0) return error.SysconfFailed;
    return @intCast(value);
}

const ProcessCpuTimes = struct {
    user_time_us: u64,
    system_time_us: u64,
};

fn getProcessCpuTimes() !ProcessCpuTimes {
    const c = @cImport({
        @cInclude("sys/resource.h");
    });

    var usage: c.struct_rusage = undefined;
    if (c.getrusage(c.RUSAGE_SELF, &usage) != 0) return error.GetrusageFailed;

    return .{
        .user_time_us = timevalToMicros(usage.ru_utime),
        .system_time_us = timevalToMicros(usage.ru_stime),
    };
}

fn timevalToMicros(value: anytype) u64 {
    const sec: u64 = @intCast(value.tv_sec);
    const usec: u64 = @intCast(value.tv_usec);
    return (sec * std.time.us_per_s) + usec;
}

fn microsToRoundedMs(micros: u64) u64 {
    if (micros == 0) return 0;
    return @divTrunc(micros + (std.time.us_per_ms - 1), std.time.us_per_ms);
}

test "system resource parsing computes memory and cpu fields" {
    const testing = std.testing;

    const meminfo =
        \\MemTotal:       1024000 kB
        \\MemAvailable:    256000 kB
    ;
    const status =
        \\Name:   lorawan-server
        \\VmSize:   2048 kB
        \\VmRSS:    1024 kB
    ;
    const stat = "123 (lorawan-server) S 1 2 3 4 5 6 7 8 9 10 120 30 14 15 16 17 18 19 100";
    const uptime = "10.0 123.0\n";

    const memory = try parseMemoryUsage(meminfo, status);
    try testing.expectEqual(@as(u64, 1024000 * 1024), memory.total_bytes);
    try testing.expectEqual(@as(u64, 256000 * 1024), memory.available_bytes);
    try testing.expectEqual(@as(u64, 768000 * 1024), memory.used_bytes);
    try testing.expectEqual(@as(u64, 1024 * 1024), memory.process_resident_bytes);
    try testing.expectEqual(@as(u64, 2048 * 1024), memory.process_virtual_bytes);

    const proc_stat = try parseProcStat(stat);
    try testing.expectEqual(@as(u64, 120), proc_stat.user_ticks);
    try testing.expectEqual(@as(u64, 30), proc_stat.system_ticks);
    try testing.expectEqual(@as(u64, 100), proc_stat.start_ticks);

    const uptime_seconds = try parseUptimeSeconds(uptime);
    try testing.expectEqual(@as(f64, 10.0), uptime_seconds);
}
