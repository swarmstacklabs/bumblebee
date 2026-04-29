const packets = @import("../lora/packets.zig");
const db_mod = @import("../db.zig");
const StorageContext = db_mod.StorageContext;

pub const Repository = struct {
    storage: StorageContext,

    pub fn init(storage: StorageContext) Repository {
        return .{ .storage = storage };
    }

    pub fn deinit(_: Repository) void {}

    pub fn insertGatewayEvent(self: Repository, event_type: []const u8, gateway_mac: [8]u8, payload_json: []u8) !void {
        defer self.storage.allocator.free(payload_json);

        const gateway_hex = packets.gatewayMacHex(gateway_mac);
        self.storage.lock();
        defer self.storage.unlock();

        const sql =
            "INSERT INTO events(event_type, entity_type, entity_id, payload_json) VALUES(?, 'gateway', ?, ?);";
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();

        stmt.bindText(1, event_type);
        stmt.bindText(2, gateway_hex[0..]);
        stmt.bindText(3, payload_json);

        try stmt.expectDone();
    }

    pub fn countByType(self: Repository, event_type: []const u8) !i64 {
        self.storage.lock();
        defer self.storage.unlock();

        const sql = "SELECT COUNT(*) FROM events WHERE event_type = ?;";
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();

        stmt.bindText(1, event_type);
        try stmt.expectRow();
        return stmt.readInt64(0);
    }
};
