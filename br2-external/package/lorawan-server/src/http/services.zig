const app_mod = @import("../app.zig");
const device_repository = @import("../repository/device_repository.zig");
const gateways_repository = @import("../repository/gateways_repository.zig");
const networks_repository = @import("../repository/networks_repository.zig");
const connectors_repository = @import("../repository/connectors_repository.zig");
const system_resource_repository = @import("../repository/system_resource_repository.zig");
const authenticator_mod = @import("authenticator.zig");

pub const Services = struct {
    device_repo: device_repository.CRUDRepository,
    gateway_repo: gateways_repository.CRUDRepository,
    network_repo: networks_repository.CRUDRepository,
    connector_repo: connectors_repository.CRUDRepository,
    system_resource_repo: system_resource_repository.ReadOnlyRepository,
    authenticator: authenticator_mod.Authenticator,
    frontend_path: []const u8,

    pub fn init(app: *app_mod.App, config: *const app_mod.Config) Services {
        return .{
            .device_repo = device_repository.crud(app.database()),
            .gateway_repo = gateways_repository.crud(app.database()),
            .network_repo = networks_repository.crud(app.database()),
            .connector_repo = connectors_repository.crud(app.database()),
            .system_resource_repo = system_resource_repository.readOnly(),
            .authenticator = authenticator_mod.Authenticator.init(config.admin),
            .frontend_path = config.frontend_path,
        };
    }

    pub fn deinit(_: Services) void {}
};
