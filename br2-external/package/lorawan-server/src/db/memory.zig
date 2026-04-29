const std = @import("std");

const db_mod = @import("../db.zig");

const StorageBackend = db_mod.StorageBackend;
const Statement = db_mod.Statement;

const MemoryStorageBackend = struct {
    allocator: std.mem.Allocator,
    interface: StorageBackend,

    const vtable = StorageBackend.VTable{
        .lock = lock,
        .unlock = unlock,
        .exec = exec,
        .prepare = prepare,
        .changes = changes,
        .runMigrations = runMigrations,
        .destroy = destroy,
    };

    pub fn create(allocator: std.mem.Allocator) !*StorageBackend {
        const self = try allocator.create(MemoryStorageBackend);
        self.* = .{
            .allocator = allocator,
            .interface = .{
                .vtable = &vtable,
            },
        };
        return &self.interface;
    }

    fn fromDb(db: *StorageBackend) *MemoryStorageBackend {
        return @fieldParentPtr("interface", db);
    }

    fn lock(_: *StorageBackend) void {}

    fn unlock(_: *StorageBackend) void {}

    fn exec(_: *StorageBackend, _: []const u8) !void {}

    fn prepare(_: *StorageBackend, _: []const u8) !Statement {
        return error.UnsupportedMemoryStorageBackendPrepare;
    }

    fn changes(_: *StorageBackend) c_int {
        return 0;
    }

    fn runMigrations(_: *StorageBackend) !void {}

    fn destroy(db: *StorageBackend) void {
        const self = fromDb(db);
        self.allocator.destroy(self);
    }
};

pub const create = MemoryStorageBackend.create;
