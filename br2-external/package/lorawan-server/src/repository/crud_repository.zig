const std = @import("std");

const db_mod = @import("../db.zig");
const StorageContext = db_mod.StorageContext;

const paging_mod = @import("paging.zig");
pub const SortOrder = paging_mod.SortOrder;
pub const ListParams = paging_mod.ListParams;
pub const ListPage = paging_mod.ListPage;
const totalPages = paging_mod.totalPages;

pub fn interface(comptime Record: type, comptime WriteInput: type, comptime Id: type) type {
    return struct {
        const Self = @This();
        pub const Page = ListPage(Record);

        storage: StorageContext,
        listFn: *const fn (StorageContext, std.mem.Allocator, ListParams) anyerror!Page,
        getFn: *const fn (StorageContext, std.mem.Allocator, Id) anyerror!?Record,
        createFn: *const fn (StorageContext, WriteInput) anyerror!void,
        updateFn: *const fn (StorageContext, Id, WriteInput) anyerror!bool,
        deleteFn: *const fn (StorageContext, Id) anyerror!bool,

        pub fn bind(comptime Impl: type, storage: StorageContext) Self {
            comptime ensureCrudImplementation(Impl);

            return .{
                .storage = storage,
                .listFn = struct {
                    fn call(repo_db: StorageContext, allocator: std.mem.Allocator, params: ListParams) !Page {
                        return Impl.init(repo_db).list(allocator, params);
                    }
                }.call,
                .getFn = struct {
                    fn call(repo_db: StorageContext, allocator: std.mem.Allocator, id: Id) !?Record {
                        return Impl.init(repo_db).get(allocator, id);
                    }
                }.call,
                .createFn = struct {
                    fn call(repo_db: StorageContext, write_input: WriteInput) !void {
                        return Impl.init(repo_db).create(write_input);
                    }
                }.call,
                .updateFn = struct {
                    fn call(repo_db: StorageContext, id: Id, write_input: WriteInput) !bool {
                        return Impl.init(repo_db).update(id, write_input);
                    }
                }.call,
                .deleteFn = struct {
                    fn call(repo_db: StorageContext, id: Id) !bool {
                        return Impl.init(repo_db).delete(id);
                    }
                }.call,
            };
        }

        pub fn list(self: Self, allocator: std.mem.Allocator, params: ListParams) !Page {
            return self.listFn(self.storage, allocator, params);
        }

        pub fn get(self: Self, allocator: std.mem.Allocator, id: Id) !?Record {
            return self.getFn(self.storage, allocator, id);
        }

        pub fn create(self: Self, write_input: WriteInput) !void {
            return self.createFn(self.storage, write_input);
        }

        pub fn update(self: Self, id: Id, write_input: WriteInput) !bool {
            return self.updateFn(self.storage, id, write_input);
        }

        pub fn delete(self: Self, id: Id) !bool {
            return self.deleteFn(self.storage, id);
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
        storage: StorageContext,

        var init_count: usize = 0;
        var last_storage_backend: ?*db_mod.StorageBackend = null;
        var last_get_id: ?i64 = null;
        var last_create_name: ?[]const u8 = null;
        var last_update_id: ?i64 = null;
        var last_update_name: ?[]const u8 = null;
        var last_delete_id: ?i64 = null;

        pub fn init(storage: StorageContext) @This() {
            init_count += 1;
            last_storage_backend = storage.backend;
            return .{ .storage = storage };
        }

        pub fn list(self: @This(), allocator: std.mem.Allocator, params: ListParams) !interface(Record, WriteInput, i64).Page {
            _ = self;
            try testing.expectEqual(@as(usize, 2), params.page);
            try testing.expectEqual(@as(usize, 10), params.page_size);
            try testing.expectEqualStrings("name", params.sort_by);
            try testing.expectEqual(SortOrder.desc, params.sort_order);

            var records = try allocator.alloc(Record, 1);
            records[0] = .{ .id = 1, .name = "device-a" };
            return interface(Record, WriteInput, i64).Page.init(records, params, 31);
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
    FakeRepository.last_storage_backend = null;
    FakeRepository.last_get_id = null;
    FakeRepository.last_create_name = null;
    FakeRepository.last_update_id = null;
    FakeRepository.last_update_name = null;
    FakeRepository.last_delete_id = null;

    const db = StorageContext.init(testing.allocator, undefined);

    const CrudRepository = interface(Record, WriteInput, i64);
    const repo = CrudRepository.bind(FakeRepository, db);

    const page = try repo.list(testing.allocator, .{
        .page = 2,
        .page_size = 10,
        .sort_by = "name",
        .sort_order = .desc,
    });
    defer testing.allocator.free(page.entries);
    try testing.expectEqual(@as(usize, 1), page.entries.len);
    try testing.expectEqual(@as(i64, 1), page.entries[0].id);
    try testing.expectEqualStrings("device-a", page.entries[0].name);
    try testing.expectEqual(@as(usize, 2), page.page_number);
    try testing.expectEqual(@as(usize, 10), page.page_size);
    try testing.expectEqual(@as(usize, 31), page.total_entries);
    try testing.expectEqual(@as(usize, 4), page.total_pages);
    try testing.expectEqualStrings("name", page.sort_by);
    try testing.expectEqual(SortOrder.desc, page.sort_order);

    const record = (try repo.get(testing.allocator, 42)).?;
    try testing.expectEqual(@as(i64, 42), record.id);
    try testing.expectEqualStrings("device-b", record.name);

    try repo.create(.{ .name = "created" });

    const updated = try repo.update(7, .{ .name = "updated" });
    try testing.expect(updated);

    const deleted = try repo.delete(9);
    try testing.expect(!deleted);

    try testing.expectEqual(@as(usize, 5), FakeRepository.init_count);
    try testing.expect(FakeRepository.last_storage_backend == db.backend);
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
        storage: StorageContext,

        pub fn init(storage: StorageContext) @This() {
            return .{ .storage = storage };
        }

        pub fn list(self: @This(), allocator: std.mem.Allocator, params: ListParams) !interface(Record, WriteInput, i64).Page {
            _ = self;
            _ = allocator;
            _ = params;
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

    const db = StorageContext.init(testing.allocator, undefined);

    const CrudRepository = interface(Record, WriteInput, i64);
    const repo = CrudRepository.bind(FakeRepository, db);

    try testing.expectError(error.ListFailed, repo.list(testing.allocator, .{
        .sort_by = "id",
        .sort_order = .asc,
    }));
    try testing.expectError(error.GetFailed, repo.get(testing.allocator, 1));
    try testing.expectError(error.CreateFailed, repo.create(.{}));
    try testing.expectError(error.UpdateFailed, repo.update(1, .{}));
    try testing.expectError(error.DeleteFailed, repo.delete(1));
}

test "CRUDRepository totalPages rounds up and handles empty totals" {
    try std.testing.expectEqual(@as(usize, 0), totalPages(0, 25));
    try std.testing.expectEqual(@as(usize, 1), totalPages(1, 25));
    try std.testing.expectEqual(@as(usize, 2), totalPages(26, 25));
}
