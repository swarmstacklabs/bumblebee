const std = @import("std");

const app_mod = @import("../app.zig");
const Database = app_mod.Database;

pub fn Interface(comptime Entity: type, comptime Payload: type, comptime Id: type) type {
    return struct {
        const Self = @This();

        db: Database,
        listFn: *const fn (Database, std.mem.Allocator) anyerror![]Entity,
        getFn: *const fn (Database, std.mem.Allocator, Id) anyerror!?Entity,
        createFn: *const fn (Database, Payload) anyerror!void,
        updateFn: *const fn (Database, Id, Payload) anyerror!bool,
        deleteFn: *const fn (Database, Id) anyerror!bool,

        pub fn bind(comptime Impl: type, db: Database) Self {
            comptime ensureCrudImplementation(Impl);

            return .{
                .db = db,
                .listFn = struct {
                    fn call(repo_db: Database, allocator: std.mem.Allocator) ![]Entity {
                        return Impl.init(repo_db).list(allocator);
                    }
                }.call,
                .getFn = struct {
                    fn call(repo_db: Database, allocator: std.mem.Allocator, id: Id) !?Entity {
                        return Impl.init(repo_db).get(allocator, id);
                    }
                }.call,
                .createFn = struct {
                    fn call(repo_db: Database, payload: Payload) !void {
                        return Impl.init(repo_db).create(payload);
                    }
                }.call,
                .updateFn = struct {
                    fn call(repo_db: Database, id: Id, payload: Payload) !bool {
                        return Impl.init(repo_db).update(id, payload);
                    }
                }.call,
                .deleteFn = struct {
                    fn call(repo_db: Database, id: Id) !bool {
                        return Impl.init(repo_db).delete(id);
                    }
                }.call,
            };
        }

        pub fn list(self: Self, allocator: std.mem.Allocator) ![]Entity {
            return self.listFn(self.db, allocator);
        }

        pub fn get(self: Self, allocator: std.mem.Allocator, id: Id) !?Entity {
            return self.getFn(self.db, allocator, id);
        }

        pub fn create(self: Self, payload: Payload) !void {
            return self.createFn(self.db, payload);
        }

        pub fn update(self: Self, id: Id, payload: Payload) !bool {
            return self.updateFn(self.db, id, payload);
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
