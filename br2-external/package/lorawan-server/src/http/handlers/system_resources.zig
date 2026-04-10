const app_mod = @import("../../app.zig");
const system_resource_repository = @import("../../repository/system_resource_repository.zig");
const read_only_handler = @import("read_only_handler.zig");
const context_mod = @import("../context.zig");

pub const ReadOnlyHandler = read_only_handler.Interface(
    app_mod.SystemResourcesRecord,
    system_resource_repository.ReadOnlyRepository,
);

const Handler = ReadOnlyHandler.bind(struct {
    pub const entity_name = "system resource";

    pub fn repo(ctx: *context_mod.Context) system_resource_repository.ReadOnlyRepository {
        return ctx.services.system_resource_repo;
    }
});

pub const get = Handler.get;
