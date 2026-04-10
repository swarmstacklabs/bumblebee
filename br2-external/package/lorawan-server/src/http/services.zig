const app_mod = @import("../app.zig");
const device_repository = @import("../repository/device_repository.zig");
const system_resource_repository = @import("../repository/system_resource_repository.zig");
const authenticator_mod = @import("authenticator.zig");

pub const Services = struct {
    device_repo: device_repository.CRUDRepository,
    system_resource_repo: system_resource_repository.ReadOnlyRepository,
    authenticator: authenticator_mod.Authenticator,

    pub fn init(app: *app_mod.App, config: *const app_mod.Config) Services {
        return .{
            .device_repo = device_repository.crud(app.database()),
            .system_resource_repo = system_resource_repository.readOnly(),
            .authenticator = authenticator_mod.Authenticator.init(config.admin),
        };
    }

    pub fn deinit(_: Services) void {}
};
