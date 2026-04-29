const context_mod = @import("../context.zig");
const read_only_repository = @import("../../repository/read_only_repository.zig");

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

pub fn list(ctx: *context_mod.Context) !void {
    const params = ListParams{
        .page = 1,
        .page_size = 50,
        .sort_by = "sname",
        .sort_order = .asc,
    };
    const resources = try ctx.services.system_resource_repo.get(ctx.allocator, "local");
    const entries = [_]ServerRecord{.{
        .memory = .{
            .total_memory = resources.memory.total_bytes,
            .free_memory = resources.memory.available_bytes,
        },
    }};
    const page = read_only_repository.ListPage(ServerRecord).init(@constCast(entries[0..]), params, entries.len);
    try ctx.res.setJson(page);
}

pub fn get(ctx: *context_mod.Context) !void {
    const id = ctx.param("id") orelse return error.BadRequest;
    const resources = try ctx.services.system_resource_repo.get(ctx.allocator, id);
    try ctx.res.setJson(ServerRecord{ .memory = .{
        .total_memory = resources.memory.total_bytes,
        .free_memory = resources.memory.available_bytes,
    } });
}
