const std = @import("std");

const db_mod = @import("../db.zig");

const Db = db_mod.Db;
const Statement = db_mod.Statement;

const MemoryDb = struct {
    allocator: std.mem.Allocator,
    interface: Db,

    const vtable = Db.VTable{
        .lock = lock,
        .unlock = unlock,
        .exec = exec,
        .prepare = prepare,
        .changes = changes,
        .runMigrations = runMigrations,
        .destroy = destroy,
    };

    pub fn create(allocator: std.mem.Allocator) !*Db {
        const self = try allocator.create(MemoryDb);
        self.* = .{
            .allocator = allocator,
            .interface = .{
                .vtable = &vtable,
            },
        };
        return &self.interface;
    }

    fn fromDb(db: *Db) *MemoryDb {
        return @fieldParentPtr("interface", db);
    }

    fn lock(_: *Db) void {}

    fn unlock(_: *Db) void {}

    fn exec(_: *Db, _: []const u8) !void {}

    fn prepare(_: *Db, _: []const u8) !Statement {
        return error.UnsupportedMemoryDbPrepare;
    }

    fn changes(_: *Db) c_int {
        return 0;
    }

    fn runMigrations(_: *Db) !void {}

    fn destroy(db: *Db) void {
        const self = fromDb(db);
        self.allocator.destroy(self);
    }
};

pub const create = MemoryDb.create;
