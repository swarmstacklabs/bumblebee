const std = @import("std");

const context_mod = @import("../context.zig");
const get_only_handler = @import("get_only_handler.zig");
const read_only_repository = @import("../../repository/read_only_repository.zig");
const system_resource_repository = @import("../../repository/system_resource_repository.zig");

const ListParams = read_only_repository.ListParams;

const ModuleVersions = struct {
    bumblebee: []const u8 = "local",
};

const DashboardMemory = struct {
    total_memory: u64,
    free_memory: u64,
    buffered_memory: u64 = 0,
    cached_memory: u64 = 0,
};

const ServerRecord = struct {
    sname: []const u8 = "local",
    modules: ModuleVersions = .{},
    memory: DashboardMemory,
    disk: []const u8 = "",
    health_alerts: []const []const u8 = &.{},
    health_decay: u8 = 0,
};

const ServerRepository = struct {
    pub const IdType = []const u8;

    system_resource_repo: system_resource_repository.ReadOnlyRepository,

    pub fn get(self: ServerRepository, allocator: std.mem.Allocator, id: []const u8) !ServerRecord {
        const resources = try self.system_resource_repo.get(allocator, id);
        defer resources.deinit(allocator);
        return serverRecordFromResources(resources);
    }
};

pub const GetOnlyHandler = get_only_handler.interface(ServerRecord, ServerRepository);

const Handler = GetOnlyHandler.bind(struct {
    pub const entity_name = "server";

    pub fn repo(ctx: *context_mod.Context) ServerRepository {
        return .{ .system_resource_repo = ctx.services.system_resource_repo };
    }
});

pub fn list(ctx: *context_mod.Context) !void {
    const params = ListParams{
        .page = 1,
        .page_size = 50,
        .sort_by = "sname",
        .sort_order = .asc,
    };
    const resources = try ctx.services.system_resource_repo.get(ctx.allocator, "local");
    defer resources.deinit(ctx.allocator);
    const entries = [_]ServerRecord{.{
        .memory = dashboardMemoryFromResources(resources),
    }};
    const page = read_only_repository.ListPage(ServerRecord).init(@constCast(entries[0..]), params, entries.len);
    try ctx.res.setJson(page);
}

pub const get = Handler.get;

fn serverRecordFromResources(resources: @import("../../app.zig").SystemResourcesRecord) ServerRecord {
    return .{ .memory = dashboardMemoryFromResources(resources) };
}

fn dashboardMemoryFromResources(resources: @import("../../app.zig").SystemResourcesRecord) DashboardMemory {
    return .{
        .total_memory = resources.memory.total_bytes,
        .free_memory = resources.memory.available_bytes,
    };
}
