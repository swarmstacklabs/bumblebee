const std = @import("std");

const app_mod = @import("../app.zig");
const crud_repository = @import("crud_repository.zig");
const db_mod = @import("../db.zig");
const StorageContext = app_mod.StorageContext;
const ListParams = crud_repository.ListParams;
const SortOrder = crud_repository.SortOrder;

pub const Record = struct {
    id: i64,
    name: []u8,
    connector_type: []u8,
    uri: []u8,
    enabled: bool,
    topic: ?[]u8,
    exchange_name: ?[]u8,
    routing_key: ?[]u8,
    partition: i32,
    client_id: ?[]u8,
    username: ?[]u8,
    password: ?[]u8,

    pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.connector_type);
        allocator.free(self.uri);
        if (self.topic) |value| allocator.free(value);
        if (self.exchange_name) |value| allocator.free(value);
        if (self.routing_key) |value| allocator.free(value);
        if (self.client_id) |value| allocator.free(value);
        if (self.username) |value| allocator.free(value);
        if (self.password) |value| allocator.free(value);
    }
};

pub const WriteInput = struct {
    name: []const u8,
    connector_type: []const u8,
    uri: []const u8,
    enabled: bool = true,
    topic: ?[]const u8 = null,
    exchange_name: ?[]const u8 = null,
    routing_key: ?[]const u8 = null,
    partition: i32 = 0,
    client_id: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,

    pub fn deinit(self: WriteInput, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.connector_type);
        allocator.free(self.uri);
        if (self.topic) |value| allocator.free(value);
        if (self.exchange_name) |value| allocator.free(value);
        if (self.routing_key) |value| allocator.free(value);
        if (self.client_id) |value| allocator.free(value);
        if (self.username) |value| allocator.free(value);
        if (self.password) |value| allocator.free(value);
    }
};

pub const CRUDRepository = crud_repository.Interface(Record, WriteInput, i64);

pub const Repository = struct {
    storage: StorageContext,

    pub fn init(storage: StorageContext) Repository {
        return .{ .storage = storage };
    }

    pub fn deinit(_: Repository) void {}

    pub fn listEnabled(self: Repository, allocator: std.mem.Allocator) ![]Record {
        return self.listWithEnabledFilter(allocator, true);
    }

    pub fn listAll(self: Repository, allocator: std.mem.Allocator) ![]Record {
        return self.listWithEnabledFilter(allocator, false);
    }

    pub fn list(self: Repository, allocator: std.mem.Allocator, params: ListParams) !CRUDRepository.Page {
        self.storage.lock();
        defer self.storage.unlock();

        const total_entries = try countConnectors(self.storage);
        const sort_column = try sqlSortColumn(params.sort_by);
        const sort_direction = sqlSortDirection(params.sort_order);

        var sql_buf: [320]u8 = undefined;
        const sql = try std.fmt.bufPrint(
            &sql_buf,
            "SELECT id, name, connector_type, uri, enabled, topic, exchange_name, routing_key, partition, client_id, username, password " ++
                "FROM connectors ORDER BY {s} {s}, id {s} LIMIT ? OFFSET ?;",
            .{ sort_column, sort_direction, sort_direction },
        );
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();

        stmt.bindInt64(1, params.page_size);
        stmt.bindInt64(2, params.offset());

        var out = std.ArrayList(Record){};
        errdefer {
            for (out.items) |*item| item.deinit(allocator);
            out.deinit(allocator);
        }

        while (stmt.step() == .row) {
            try out.append(allocator, try rowToRecord(allocator, stmt));
        }

        return CRUDRepository.Page.init(try out.toOwnedSlice(allocator), params, total_entries);
    }

    pub fn get(self: Repository, allocator: std.mem.Allocator, id: i64) !?Record {
        self.storage.lock();
        defer self.storage.unlock();

        const sql =
            "SELECT id, name, connector_type, uri, enabled, topic, exchange_name, routing_key, partition, client_id, username, password " ++
            "FROM connectors WHERE id = ?;";
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();

        stmt.bindInt64(1, id);
        if (stmt.step() != .row) return null;
        return try rowToRecord(allocator, stmt);
    }

    pub fn create(self: Repository, write_input: WriteInput) !void {
        self.storage.lock();
        defer self.storage.unlock();

        const sql =
            "INSERT INTO connectors(name, connector_type, uri, enabled, topic, exchange_name, routing_key, partition, client_id, username, password, updated_at) " ++
            "VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP);";
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();

        bindWriteInput(stmt, write_input);
        stmt.expectDone() catch return error.ConnectorCreateFailed;
    }

    pub fn update(self: Repository, id: i64, write_input: WriteInput) !bool {
        self.storage.lock();
        defer self.storage.unlock();

        const sql =
            "UPDATE connectors SET " ++
            "name = ?, connector_type = ?, uri = ?, enabled = ?, topic = ?, exchange_name = ?, routing_key = ?, partition = ?, client_id = ?, username = ?, password = ?, updated_at = CURRENT_TIMESTAMP " ++
            "WHERE id = ?;";
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();

        bindWriteInput(stmt, write_input);
        stmt.bindInt64(12, id);

        stmt.expectDone() catch return error.ConnectorUpdateFailed;
        return self.storage.changes() != 0;
    }

    pub fn delete(self: Repository, id: i64) !bool {
        self.storage.lock();
        defer self.storage.unlock();

        const sql = "DELETE FROM connectors WHERE id = ?;";
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();

        stmt.bindInt64(1, id);
        stmt.expectDone() catch return error.ConnectorDeleteFailed;
        return self.storage.changes() != 0;
    }

    pub fn upsert(self: Repository, input: WriteInput) !void {
        self.storage.lock();
        defer self.storage.unlock();

        const sql =
            "INSERT INTO connectors(name, connector_type, uri, enabled, topic, exchange_name, routing_key, partition, client_id, username, password, updated_at) " ++
            "VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP) " ++
            "ON CONFLICT(name) DO UPDATE SET " ++
            "connector_type = excluded.connector_type, " ++
            "uri = excluded.uri, " ++
            "enabled = excluded.enabled, " ++
            "topic = excluded.topic, " ++
            "exchange_name = excluded.exchange_name, " ++
            "routing_key = excluded.routing_key, " ++
            "partition = excluded.partition, " ++
            "client_id = excluded.client_id, " ++
            "username = excluded.username, " ++
            "password = excluded.password, " ++
            "updated_at = CURRENT_TIMESTAMP;";
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();

        bindWriteInput(stmt, input);
        try stmt.expectDone();
    }

    pub fn setEnabled(self: Repository, name: []const u8, enabled: bool) !void {
        self.storage.lock();
        defer self.storage.unlock();

        const sql = "UPDATE connectors SET enabled = ?, updated_at = CURRENT_TIMESTAMP WHERE name = ?;";
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();

        stmt.bindInt(1, if (enabled) 1 else 0);
        stmt.bindText(2, name);
        try stmt.expectDone();
    }

    fn listWithEnabledFilter(self: Repository, allocator: std.mem.Allocator, enabled_only: bool) ![]Record {
        self.storage.lock();
        defer self.storage.unlock();

        const sql =
            "SELECT id, name, connector_type, uri, enabled, topic, exchange_name, routing_key, partition, client_id, username, password " ++
            "FROM connectors WHERE (? = 0 OR enabled = 1) ORDER BY id ASC;";
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();
        stmt.bindInt(1, @as(c_int, if (enabled_only) 1 else 0));

        var out = std.ArrayList(Record){};
        errdefer {
            for (out.items) |*item| item.deinit(allocator);
            out.deinit(allocator);
        }

        while (stmt.step() == .row) {
            try out.append(allocator, try rowToRecord(allocator, stmt));
        }

        return out.toOwnedSlice(allocator);
    }
};

pub fn crud(storage: StorageContext) CRUDRepository {
    return CRUDRepository.bind(Repository, storage);
}

fn rowToRecord(allocator: std.mem.Allocator, stmt: db_mod.Statement) !Record {
    return .{
        .id = stmt.readInt64(0),
        .name = try allocator.dupe(u8, stmt.readText(1) orelse ""),
        .connector_type = try allocator.dupe(u8, stmt.readText(2) orelse ""),
        .uri = try allocator.dupe(u8, stmt.readText(3) orelse ""),
        .enabled = (stmt.readInt(4) != 0),
        .topic = try dupOptionalText(allocator, stmt, 5),
        .exchange_name = try dupOptionalText(allocator, stmt, 6),
        .routing_key = try dupOptionalText(allocator, stmt, 7),
        .partition = stmt.readInt(8),
        .client_id = try dupOptionalText(allocator, stmt, 9),
        .username = try dupOptionalText(allocator, stmt, 10),
        .password = try dupOptionalText(allocator, stmt, 11),
    };
}

fn bindWriteInput(stmt: db_mod.Statement, input: WriteInput) void {
    stmt.bindText(1, input.name);
    stmt.bindText(2, input.connector_type);
    stmt.bindText(3, input.uri);
    stmt.bindInt(4, @as(c_int, if (input.enabled) 1 else 0));
    bindOptionalText(stmt, 5, input.topic);
    bindOptionalText(stmt, 6, input.exchange_name);
    bindOptionalText(stmt, 7, input.routing_key);
    stmt.bindInt(8, input.partition);
    bindOptionalText(stmt, 9, input.client_id);
    bindOptionalText(stmt, 10, input.username);
    bindOptionalText(stmt, 11, input.password);
}

fn countConnectors(storage: StorageContext) !usize {
    const stmt = try storage.prepare("SELECT COUNT(*) FROM connectors;");
    defer stmt.deinit();

    try stmt.expectRow();
    return @intCast(stmt.readInt64(0));
}

fn sqlSortColumn(sort_by: []const u8) ![]const u8 {
    if (std.mem.eql(u8, sort_by, "id")) return "id";
    if (std.mem.eql(u8, sort_by, "name")) return "name";
    if (std.mem.eql(u8, sort_by, "connector_type")) return "connector_type";
    if (std.mem.eql(u8, sort_by, "uri")) return "uri";
    if (std.mem.eql(u8, sort_by, "enabled")) return "enabled";
    if (std.mem.eql(u8, sort_by, "partition")) return "partition";
    if (std.mem.eql(u8, sort_by, "created_at")) return "created_at";
    if (std.mem.eql(u8, sort_by, "updated_at")) return "updated_at";
    return error.BadRequest;
}

fn sqlSortDirection(sort_order: SortOrder) []const u8 {
    return switch (sort_order) {
        .asc => "ASC",
        .desc => "DESC",
    };
}

fn dupOptionalText(allocator: std.mem.Allocator, stmt: db_mod.Statement, column: c_int) !?[]u8 {
    const text = stmt.readText(column) orelse return null;
    return try allocator.dupe(u8, text);
}

fn bindOptionalText(stmt: db_mod.Statement, index: c_int, value: ?[]const u8) void {
    if (value) |text| stmt.bindText(index, text) else stmt.bindNull(index);
}

test "connectors repository upsert and list enabled records" {
    const allocator = std.testing.allocator;
    var app = try testApp(allocator);
    defer testAppDeinit(&app);

    const repo = Repository.init(app.app.storage());
    try repo.upsert(.{
        .name = "mqtt-main",
        .connector_type = "mqtt",
        .uri = "mqtt://localhost:1883",
        .enabled = true,
        .topic = "lorawan/uplinks",
    });
    try repo.upsert(.{
        .name = "ws-disabled",
        .connector_type = "ws",
        .uri = "ws://localhost:8081/events",
        .enabled = false,
    });

    const enabled = try repo.listEnabled(allocator);
    defer {
        for (enabled) |*item| item.deinit(allocator);
        allocator.free(enabled);
    }

    try std.testing.expectEqual(@as(usize, 1), enabled.len);
    try std.testing.expectEqualStrings("mqtt-main", enabled[0].name);
    try std.testing.expectEqualStrings("lorawan/uplinks", enabled[0].topic.?);
}

test "connectors repository implements CRUD operations" {
    const allocator = std.testing.allocator;
    var app = try testApp(allocator);
    defer testAppDeinit(&app);

    const repo = Repository.init(app.app.storage());
    try repo.create(.{
        .name = "crud-one",
        .connector_type = "kafka",
        .uri = "kafka://localhost:9092",
        .enabled = true,
        .topic = "events",
        .partition = 3,
    });

    const page = try repo.list(allocator, .{
        .page = 1,
        .page_size = 10,
        .sort_by = "id",
        .sort_order = .asc,
    });
    defer {
        for (page.entries) |*entry| entry.deinit(allocator);
        allocator.free(page.entries);
    }
    try std.testing.expectEqual(@as(usize, 1), page.entries.len);

    const id = page.entries[0].id;
    var one = (try repo.get(allocator, id)).?;
    defer one.deinit(allocator);
    try std.testing.expectEqualStrings("crud-one", one.name);

    const updated = try repo.update(id, .{
        .name = "crud-two",
        .connector_type = "mqtt",
        .uri = "mqtt://localhost:1883",
        .enabled = true,
        .topic = "uplinks",
    });
    try std.testing.expect(updated);

    const deleted = try repo.delete(id);
    try std.testing.expect(deleted);
}

const TestApp = struct {
    app: app_mod.App,
    db_path: []u8,
    allocator: std.mem.Allocator,
};

fn testApp(allocator: std.mem.Allocator) !TestApp {
    const db_path = try std.fmt.allocPrint(allocator, "/tmp/lorawan-server-connectors-repo-{d}.db", .{std.time.nanoTimestamp()});
    errdefer allocator.free(db_path);

    const app = try app_mod.App.init(allocator, db_path);
    return .{
        .app = app,
        .db_path = db_path,
        .allocator = allocator,
    };
}

fn testAppDeinit(test_app: *TestApp) void {
    test_app.app.deinit();
    std.fs.deleteFileAbsolute(test_app.db_path) catch {};
    test_app.allocator.free(test_app.db_path);
}
