const config = @import("config.zig");
const storage = @import("storage.zig");

pub const default_udp_port = config.default_udp_port;
pub const default_http_port = config.default_http_port;
pub const default_bind_address = config.default_bind_address;
pub const env_udp_port = config.env_udp_port;
pub const env_http_port = config.env_http_port;
pub const env_db_path = config.env_db_path;
pub const env_admin_user = config.env_admin_user;
pub const env_admin_pass = config.env_admin_pass;
pub const env_frontend_path = config.env_frontend_path;
pub const AdminConfig = config.AdminConfig;
pub const Config = config.Config;

pub const c = storage.c;
pub const StatusResponse = storage.StatusResponse;
pub const ErrorResponse = storage.ErrorResponse;
pub const SystemMemoryUsage = storage.SystemMemoryUsage;
pub const CpuUsage = storage.CpuUsage;
pub const SystemResourcesRecord = storage.SystemResourcesRecord;
pub const DeviceRecord = storage.DeviceRecord;
pub const DeviceWriteInput = storage.DeviceWriteInput;
pub const Database = storage.Database;
pub const App = storage.App;
