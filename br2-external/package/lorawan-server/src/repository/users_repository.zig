const std = @import("std");

const crud_repository = @import("crud_repository.zig");
const db_mod = @import("../db.zig");

const StorageContext = db_mod.StorageContext;
const ListParams = crud_repository.ListParams;
const SortOrder = crud_repository.SortOrder;

pub const Record = struct {
    id: i64,
    name: []u8,
    scopes: [][]u8,
    email: []const u8 = "",
    send_alerts: bool = false,
    created_at: []u8,
    updated_at: []u8,

    pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.scopes) |scope| allocator.free(scope);
        allocator.free(self.scopes);
        allocator.free(self.email);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
    }
};

pub const ScopeRecord = struct {
    scope: []const u8,
};

pub const WriteInput = struct {
    name: []const u8,
    password: ?[]const u8 = null,
    scopes: []const []const u8,
    email: []const u8 = "",
    send_alerts: bool = false,

    pub fn deinit(self: WriteInput, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.password) |value| allocator.free(value);
        for (self.scopes) |scope| allocator.free(scope);
        allocator.free(self.scopes);
        allocator.free(self.email);
    }
};

pub const Page = crud_repository.ListPage(Record);
pub const ScopePage = crud_repository.ListPage(ScopeRecord);

const all_scopes = [_]ScopeRecord{
    .{ .scope = "unlimited" },
    .{ .scope = "web-admin" },
    .{ .scope = "server:read" },
    .{ .scope = "server:write" },
    .{ .scope = "network:read" },
    .{ .scope = "network:write" },
    .{ .scope = "gateway:link" },
    .{ .scope = "device:read" },
    .{ .scope = "device:write" },
    .{ .scope = "device:send" },
    .{ .scope = "backend:read" },
    .{ .scope = "backend:write" },
};

pub fn scopes() []const ScopeRecord {
    return &all_scopes;
}

pub const Repository = struct {
    storage: StorageContext,

    pub fn init(storage: StorageContext) Repository {
        return .{ .storage = storage };
    }

    pub fn list(self: Repository, allocator: std.mem.Allocator, params: ListParams) !Page {
        self.storage.lock();
        defer self.storage.unlock();

        const total_entries = try countUsers(self.storage);
        const sort_column = try sqlSortColumn(params.sort_by);
        const sort_direction = sqlSortDirection(params.sort_order);

        var sql_buf: [320]u8 = undefined;
        const sql = try std.fmt.bufPrint(
            &sql_buf,
            "SELECT id, name, scope_json, user_json, created_at, updated_at " ++
                "FROM users ORDER BY {s} {s}, id {s} LIMIT ? OFFSET ?;",
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
            try out.append(allocator, .{
                .id = stmt.readInt64(0),
                .name = try allocator.dupe(u8, stmt.readText(1) orelse ""),
                .scopes = try parseScopes(allocator, stmt.readText(2) orelse "[]"),
                .email = try parseUserEmail(allocator, stmt.readText(3) orelse "{}"),
                .send_alerts = parseUserSendAlerts(allocator, stmt.readText(3) orelse "{}"),
                .created_at = try allocator.dupe(u8, stmt.readText(4) orelse ""),
                .updated_at = try allocator.dupe(u8, stmt.readText(5) orelse ""),
            });
        }

        return Page.init(try out.toOwnedSlice(allocator), params, total_entries);
    }

    pub fn get(self: Repository, allocator: std.mem.Allocator, name: []const u8) !?Record {
        self.storage.lock();
        defer self.storage.unlock();

        const sql = "SELECT id, name, scope_json, user_json, created_at, updated_at FROM users WHERE name = ?;";
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();

        stmt.bindText(1, name);
        if (stmt.step() != .row) return null;

        return .{
            .id = stmt.readInt64(0),
            .name = try allocator.dupe(u8, stmt.readText(1) orelse ""),
            .scopes = try parseScopes(allocator, stmt.readText(2) orelse "[]"),
            .email = try parseUserEmail(allocator, stmt.readText(3) orelse "{}"),
            .send_alerts = parseUserSendAlerts(allocator, stmt.readText(3) orelse "{}"),
            .created_at = try allocator.dupe(u8, stmt.readText(4) orelse ""),
            .updated_at = try allocator.dupe(u8, stmt.readText(5) orelse ""),
        };
    }

    pub fn create(self: Repository, write_input: WriteInput) !void {
        try validateScopes(write_input.scopes);

        const scope_json = try encodeScopes(self.storage.allocator, write_input.scopes);
        defer self.storage.allocator.free(scope_json);
        const password_hash = try passwordHash(self.storage.allocator, write_input.password orelse "");
        defer self.storage.allocator.free(password_hash);
        const user_json = try encodeUserJson(self.storage.allocator, write_input);
        defer self.storage.allocator.free(user_json);

        self.storage.lock();
        defer self.storage.unlock();

        const sql = "INSERT INTO users(name, password_hash, scope_json, user_json, updated_at) VALUES(?, ?, ?, ?, CURRENT_TIMESTAMP);";
        const stmt = try self.storage.prepare(sql);
        defer stmt.deinit();

        stmt.bindText(1, write_input.name);
        stmt.bindText(2, password_hash);
        stmt.bindText(3, scope_json);
        stmt.bindText(4, user_json);
        stmt.expectDone() catch return error.UserCreateFailed;
    }

    pub fn update(self: Repository, name: []const u8, write_input: WriteInput) !bool {
        try validateScopes(write_input.scopes);

        const scope_json = try encodeScopes(self.storage.allocator, write_input.scopes);
        defer self.storage.allocator.free(scope_json);
        const user_json = try encodeUserJson(self.storage.allocator, write_input);
        defer self.storage.allocator.free(user_json);

        self.storage.lock();
        defer self.storage.unlock();

        if (write_input.password) |password| {
            const password_hash_value = try passwordHash(self.storage.allocator, password);
            defer self.storage.allocator.free(password_hash_value);

            const sql =
                "UPDATE users SET name = ?, password_hash = ?, scope_json = ?, user_json = ?, updated_at = CURRENT_TIMESTAMP " ++
                "WHERE name = ?;";
            const stmt = try self.storage.prepare(sql);
            defer stmt.deinit();

            stmt.bindText(1, write_input.name);
            stmt.bindText(2, password_hash_value);
            stmt.bindText(3, scope_json);
            stmt.bindText(4, user_json);
            stmt.bindText(5, name);
            stmt.expectDone() catch return error.UserUpdateFailed;
        } else {
            const sql =
                "UPDATE users SET name = ?, scope_json = ?, user_json = ?, updated_at = CURRENT_TIMESTAMP " ++
                "WHERE name = ?;";
            const stmt = try self.storage.prepare(sql);
            defer stmt.deinit();

            stmt.bindText(1, write_input.name);
            stmt.bindText(2, scope_json);
            stmt.bindText(3, user_json);
            stmt.bindText(4, name);
            stmt.expectDone() catch return error.UserUpdateFailed;
        }

        return self.storage.changes() != 0;
    }

    pub fn delete(self: Repository, name: []const u8) !bool {
        self.storage.lock();
        defer self.storage.unlock();

        const stmt = try self.storage.prepare("DELETE FROM users WHERE name = ?;");
        defer stmt.deinit();

        stmt.bindText(1, name);
        stmt.expectDone() catch return error.UserDeleteFailed;
        return self.storage.changes() != 0;
    }
};

pub fn scopesPage(params: ListParams) ScopePage {
    const start = @min(params.offset(), all_scopes.len);
    const end = @min(start + params.page_size, all_scopes.len);
    return ScopePage.init(@constCast(all_scopes[start..end]), params, all_scopes.len);
}

fn countUsers(storage: StorageContext) !usize {
    const stmt = try storage.prepare("SELECT COUNT(*) FROM users;");
    defer stmt.deinit();

    try stmt.expectRow();
    return @intCast(stmt.readInt64(0));
}

fn sqlSortColumn(sort_by: []const u8) ![]const u8 {
    if (std.mem.eql(u8, sort_by, "id")) return "id";
    if (std.mem.eql(u8, sort_by, "name")) return "name";
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

fn parseScopes(allocator: std.mem.Allocator, scope_json: []const u8) ![][]u8 {
    const parsed = std.json.parseFromSlice([]const []const u8, allocator, scope_json, .{}) catch {
        return allocator.alloc([]u8, 0);
    };
    defer parsed.deinit();

    var out = try allocator.alloc([]u8, parsed.value.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |scope| allocator.free(scope);
        allocator.free(out);
    }
    for (parsed.value, 0..) |scope, index| {
        out[index] = try allocator.dupe(u8, scope);
        initialized += 1;
    }
    return out;
}

fn encodeScopes(allocator: std.mem.Allocator, values: []const []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, values, .{});
}

fn validateScopes(values: []const []const u8) !void {
    for (values) |value| {
        if (!isKnownScope(value)) return error.InvalidScope;
    }
}

fn isKnownScope(value: []const u8) bool {
    for (all_scopes) |scope| {
        if (std.mem.eql(u8, value, scope.scope)) return true;
    }
    return false;
}

fn passwordHash(allocator: std.mem.Allocator, password: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(password, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

fn encodeUserJson(allocator: std.mem.Allocator, write_input: WriteInput) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .email = write_input.email,
        .send_alerts = write_input.send_alerts,
    }, .{});
}

fn parseUserEmail(allocator: std.mem.Allocator, user_json: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, user_json, .{ .ignore_unknown_fields = true }) catch {
        return allocator.alloc(u8, 0);
    };
    defer parsed.deinit();

    const value = parsed.value.object.get("email") orelse return allocator.alloc(u8, 0);
    if (value != .string) return allocator.alloc(u8, 0);
    return allocator.dupe(u8, value.string);
}

fn parseUserSendAlerts(allocator: std.mem.Allocator, user_json: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, user_json, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();

    const value = parsed.value.object.get("send_alerts") orelse return false;
    if (value != .bool) return false;
    return value.bool;
}
