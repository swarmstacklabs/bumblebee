const std = @import("std");

const app_mod = @import("../app.zig");
const Database = app_mod.Database;

pub fn Interface(comptime Record: type, comptime WriteInput: type, comptime Id: type) type {
    return struct {
        const Self = @This();

        db: Database,
        listFn: *const fn (Database, std.mem.Allocator) anyerror![]Record,
        getFn: *const fn (Database, std.mem.Allocator, Id) anyerror!?Record,
        createFn: *const fn (Database, WriteInput) anyerror!void,
        updateFn: *const fn (Database, Id, WriteInput) anyerror!bool,
        deleteFn: *const fn (Database, Id) anyerror!bool,

        pub fn bind(comptime Impl: type, db: Database) Self {
            comptime ensureCrudImplementation(Impl);

            return .{
                .db = db,
                .listFn = struct {
                    fn call(repo_db: Database, allocator: std.mem.Allocator) ![]Record {
                        return Impl.init(repo_db).list(allocator);
                    }
                }.call,
                .getFn = struct {
                    fn call(repo_db: Database, allocator: std.mem.Allocator, id: Id) !?Record {
                        return Impl.init(repo_db).get(allocator, id);
                    }
                }.call,
                .createFn = struct {
                    fn call(repo_db: Database, write_input: WriteInput) !void {
                        return Impl.init(repo_db).create(write_input);
                    }
                }.call,
                .updateFn = struct {
                    fn call(repo_db: Database, id: Id, write_input: WriteInput) !bool {
                        return Impl.init(repo_db).update(id, write_input);
                    }
                }.call,
                .deleteFn = struct {
                    fn call(repo_db: Database, id: Id) !bool {
                        return Impl.init(repo_db).delete(id);
                    }
                }.call,
            };
        }

        pub fn list(self: Self, allocator: std.mem.Allocator) ![]Record {
            return self.listFn(self.db, allocator);
        }

        pub fn get(self: Self, allocator: std.mem.Allocator, id: Id) !?Record {
            return self.getFn(self.db, allocator, id);
        }

        pub fn create(self: Self, write_input: WriteInput) !void {
            return self.createFn(self.db, write_input);
        }

        pub fn update(self: Self, id: Id, write_input: WriteInput) !bool {
            return self.updateFn(self.db, id, write_input);
        }

        pub fn delete(self: Self, id: Id) !bool {
            return self.deleteFn(self.db, id);
        }
    };
}

fn ensureCrudImplementation(comptime Impl: type) void {
    const required = [_][]const u8{ "init", "list", "get", "create", "update", "delete" };
    inline for (required) |decl_name| {
        if (!@hasDecl(Impl, decl_name)) {
            @compileError(std.fmt.comptimePrint(
                "{s} must implement `{s}` to satisfy CRUDRepository",
                .{ @typeName(Impl), decl_name },
            ));
        }
    }
}

test "CRUDRepository forwards operations to implementation" {
    const testing = std.testing;

    const Record = struct {
        id: i64,
        name: []const u8,
    };

    const WriteInput = struct {
        name: []const u8,
    };

    const FakeRepository = struct {
        db: Database,

        var init_count: usize = 0;
        var last_mutex: ?*std.Thread.Mutex = null;
        var last_get_id: ?i64 = null;
        var last_create_name: ?[]const u8 = null;
        var last_update_id: ?i64 = null;
        var last_update_name: ?[]const u8 = null;
        var last_delete_id: ?i64 = null;

        pub fn init(db: Database) @This() {
            init_count += 1;
            last_mutex = db.mutex;
            return .{ .db = db };
        }

        pub fn list(self: @This(), allocator: std.mem.Allocator) ![]Record {
            _ = self;

            var records = try allocator.alloc(Record, 1);
            records[0] = .{ .id = 1, .name = "device-a" };
            return records;
        }

        pub fn get(self: @This(), allocator: std.mem.Allocator, id: i64) !?Record {
            _ = self;
            _ = allocator;

            last_get_id = id;
            return .{ .id = id, .name = "device-b" };
        }

        pub fn create(self: @This(), write_input: WriteInput) !void {
            _ = self;
            last_create_name = write_input.name;
        }

        pub fn update(self: @This(), id: i64, write_input: WriteInput) !bool {
            _ = self;

            last_update_id = id;
            last_update_name = write_input.name;
            return true;
        }

        pub fn delete(self: @This(), id: i64) !bool {
            _ = self;
            last_delete_id = id;
            return false;
        }
    };

    FakeRepository.init_count = 0;
    FakeRepository.last_mutex = null;
    FakeRepository.last_get_id = null;
    FakeRepository.last_create_name = null;
    FakeRepository.last_update_id = null;
    FakeRepository.last_update_name = null;
    FakeRepository.last_delete_id = null;

    var mutex = std.Thread.Mutex{};
    const db = Database.init(testing.allocator, undefined, &mutex);

    const CrudRepository = Interface(Record, WriteInput, i64);
    const repo = CrudRepository.bind(FakeRepository, db);

    const records = try repo.list(testing.allocator);
    defer testing.allocator.free(records);
    try testing.expectEqual(@as(usize, 1), records.len);
    try testing.expectEqual(@as(i64, 1), records[0].id);
    try testing.expectEqualStrings("device-a", records[0].name);

    const record = (try repo.get(testing.allocator, 42)).?;
    try testing.expectEqual(@as(i64, 42), record.id);
    try testing.expectEqualStrings("device-b", record.name);

    try repo.create(.{ .name = "created" });

    const updated = try repo.update(7, .{ .name = "updated" });
    try testing.expect(updated);

    const deleted = try repo.delete(9);
    try testing.expect(!deleted);

    try testing.expectEqual(@as(usize, 5), FakeRepository.init_count);
    try testing.expect(FakeRepository.last_mutex == &mutex);
    try testing.expectEqual(@as(?i64, 42), FakeRepository.last_get_id);
    try testing.expectEqualStrings("created", FakeRepository.last_create_name.?);
    try testing.expectEqual(@as(?i64, 7), FakeRepository.last_update_id);
    try testing.expectEqualStrings("updated", FakeRepository.last_update_name.?);
    try testing.expectEqual(@as(?i64, 9), FakeRepository.last_delete_id);
}

test "CRUDRepository propagates implementation errors" {
    const testing = std.testing;

    const Record = struct { id: i64 };
    const WriteInput = struct {};

    const FakeRepository = struct {
        db: Database,

        pub fn init(db: Database) @This() {
            return .{ .db = db };
        }

        pub fn list(self: @This(), allocator: std.mem.Allocator) ![]Record {
            _ = self;
            _ = allocator;
            return error.ListFailed;
        }

        pub fn get(self: @This(), allocator: std.mem.Allocator, id: i64) !?Record {
            _ = self;
            _ = allocator;
            _ = id;
            return error.GetFailed;
        }

        pub fn create(self: @This(), write_input: WriteInput) !void {
            _ = self;
            _ = write_input;
            return error.CreateFailed;
        }

        pub fn update(self: @This(), id: i64, write_input: WriteInput) !bool {
            _ = self;
            _ = id;
            _ = write_input;
            return error.UpdateFailed;
        }

        pub fn delete(self: @This(), id: i64) !bool {
            _ = self;
            _ = id;
            return error.DeleteFailed;
        }
    };

    var mutex = std.Thread.Mutex{};
    const db = Database.init(testing.allocator, undefined, &mutex);

    const CrudRepository = Interface(Record, WriteInput, i64);
    const repo = CrudRepository.bind(FakeRepository, db);

    try testing.expectError(error.ListFailed, repo.list(testing.allocator));
    try testing.expectError(error.GetFailed, repo.get(testing.allocator, 1));
    try testing.expectError(error.CreateFailed, repo.create(.{}));
    try testing.expectError(error.UpdateFailed, repo.update(1, .{}));
    try testing.expectError(error.DeleteFailed, repo.delete(1));
}
