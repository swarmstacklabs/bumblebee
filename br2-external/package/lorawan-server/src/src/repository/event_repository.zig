const app_mod = @import("../app.zig");
const packets = @import("../lorawan/packets.zig");
const sqlite = @import("../sqlite_helpers.zig");
const App = app_mod.App;

pub const Repository = struct {
    app: *App,

    pub fn init(app: *App) Repository {
        return .{ .app = app };
    }

    pub fn insertGatewayEvent(self: Repository, event_type: []const u8, gateway_mac: [8]u8, payload_json: []u8) !void {
        defer self.app.allocator.free(payload_json);

        const gateway_hex = packets.gatewayMacHex(gateway_mac);
        self.app.mutex.lock();
        defer self.app.mutex.unlock();

        const sql =
            "INSERT INTO events(event_type, entity_type, entity_id, payload_json) VALUES(?, 'gateway', ?, ?);";
        const stmt = try sqlite.Statement.prepare(self.app.db, sql);
        defer stmt.deinit();

        stmt.bindText(1, event_type);
        stmt.bindText(2, gateway_hex[0..]);
        stmt.bindText(3, payload_json);

        try stmt.expectDone();
    }

    pub fn countByType(self: Repository, event_type: []const u8) !i64 {
        self.app.mutex.lock();
        defer self.app.mutex.unlock();

        const sql = "SELECT COUNT(*) FROM events WHERE event_type = ?;";
        const stmt = try sqlite.Statement.prepare(self.app.db, sql);
        defer stmt.deinit();

        stmt.bindText(1, event_type);
        try stmt.expectRow();
        return stmt.readInt64(0);
    }
};
