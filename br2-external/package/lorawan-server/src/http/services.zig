const app_mod = @import("../app.zig");
const device_repository = @import("../repository/device_repository.zig");
const authenticator_mod = @import("authenticator.zig");

pub const Services = struct {
    device_repo: device_repository.Repository,
    authenticator: authenticator_mod.Authenticator,

    pub fn init(app: *app_mod.App, config: *const app_mod.Config) Services {
        return .{
            .device_repo = device_repository.Repository.init(app.database()),
            .authenticator = authenticator_mod.Authenticator.init(config.admin),
        };
    }
};
