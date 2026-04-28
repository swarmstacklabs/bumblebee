const context_mod = @import("../context.zig");
const crud_repository = @import("../../repository/crud_repository.zig");

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

pub fn list(ctx: *context_mod.Context) !void {
    const resources = try ctx.services.system_resource_repo.get(ctx.allocator);
    const entries = [_]ServerRecord{.{
        .memory = .{
            .total_memory = resources.memory.total_bytes,
            .free_memory = resources.memory.available_bytes,
        },
    }};
    const params = crud_repository.ListParams{
        .page = 1,
        .page_size = 1,
        .sort_by = "sname",
        .sort_order = .asc,
    };
    const page = crud_repository.ListPage(ServerRecord).init(@constCast(entries[0..]), params, entries.len);
    try ctx.res.setJson(page);
}

pub fn get(ctx: *context_mod.Context) !void {
    _ = ctx.param("id") orelse return error.BadRequest;
    const resources = try ctx.services.system_resource_repo.get(ctx.allocator);
    try ctx.res.setJson(ServerRecord{ .memory = .{
        .total_memory = resources.memory.total_bytes,
        .free_memory = resources.memory.available_bytes,
    } });
}
