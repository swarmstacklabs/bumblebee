const app_mod = @import("../app.zig");
const packets = @import("../lora/packets.zig");
const Database = app_mod.Database;

pub const Repository = struct {
    db: Database,

    pub fn init(db: Database) Repository {
        return .{ .db = db };
    }

    pub fn deinit(_: Repository) void {}

    pub fn insertGatewayEvent(self: Repository, event_type: []const u8, gateway_mac: [8]u8, payload_json: []u8) !void {
        defer self.db.allocator.free(payload_json);

        const gateway_hex = packets.gatewayMacHex(gateway_mac);
        self.db.lock();
        defer self.db.unlock();

        const sql =
            "INSERT INTO events(event_type, entity_type, entity_id, payload_json) VALUES(?, 'gateway', ?, ?);";
        const stmt = try self.db.prepare(sql);
        defer stmt.deinit();

        stmt.bindText(1, event_type);
        stmt.bindText(2, gateway_hex[0..]);
        stmt.bindText(3, payload_json);

        try stmt.expectDone();
    }

    pub fn countByType(self: Repository, event_type: []const u8) !i64 {
        self.db.lock();
        defer self.db.unlock();

        const sql = "SELECT COUNT(*) FROM events WHERE event_type = ?;";
        const stmt = try self.db.prepare(sql);
        defer stmt.deinit();

        stmt.bindText(1, event_type);
        try stmt.expectRow();
        return stmt.readInt64(0);
    }
};
