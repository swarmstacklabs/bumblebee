test {
    _ = @import("conventions.zig");
    _ = @import("db/memory.zig");
    _ = @import("db/sqlite.zig");
    _ = @import("http/handlers/crud_handler.zig");
    _ = @import("http/handlers/get_only_handler.zig");
    _ = @import("http/handlers/read_only_handler.zig");
    _ = @import("http/response.zig");
    _ = @import("http/http.zig");
    _ = @import("lora.zig");
    _ = @import("maintenance.zig");
    _ = @import("byte_utils.zig");
    _ = @import("repository/crud_repository.zig");
    _ = @import("repository/get_only_repository.zig");
    _ = @import("repository/http_request_metrics_repository.zig");
    _ = @import("repository/read_only_repository.zig");
    _ = @import("repository/system_resource_repository.zig");
    _ = @import("udp/udp.zig");
}
