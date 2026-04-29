const std = @import("std");

pub const ListParams = @import("paging.zig").ListParams;
pub const ListPage = @import("paging.zig").ListPage;
pub const SortOrder = @import("paging.zig").SortOrder;

pub fn interface(comptime Record: type, comptime Id: type) type {
    return struct {
        const Self = @This();
        pub const IdType = Id;
        pub const Page = ListPage(Record);

        listFn: *const fn (std.mem.Allocator, ListParams) anyerror!Page,
        getFn: *const fn (std.mem.Allocator, Id) anyerror!Record,

        pub fn bind(comptime Impl: type) Self {
            comptime ensureReadOnlyImplementation(Impl);

            return .{
                .listFn = struct {
                    fn call(allocator: std.mem.Allocator, params: ListParams) anyerror!Page {
                        return Impl.init().list(allocator, params);
                    }
                }.call,
                .getFn = struct {
                    fn call(allocator: std.mem.Allocator, id: Id) anyerror!Record {
                        return Impl.init().get(allocator, id);
                    }
                }.call,
            };
        }

        pub fn list(self: Self, allocator: std.mem.Allocator, params: ListParams) !Page {
            return self.listFn(allocator, params);
        }

        pub fn get(self: Self, allocator: std.mem.Allocator, id: Id) !Record {
            return self.getFn(allocator, id);
        }
    };
}

fn ensureReadOnlyImplementation(comptime Impl: type) void {
    const required = [_][]const u8{ "get", "list" };
    inline for (required) |decl_name| {
        if (!@hasDecl(Impl, decl_name)) {
            @compileError(std.fmt.comptimePrint(
                "{s} must implement `{s}` to satisfy ReadOnlyRepository",
                .{ @typeName(Impl), decl_name },
            ));
        }
    }
}

test "ReadOnlyRepository forwards get and list to implementation" {
    const testing = std.testing;

    const Record = struct { value: u32 };

    const FakeRepository = struct {
        var get_called = false;
        var list_called = false;

        pub fn init() @This() {
            return .{};
        }

        pub fn get(_: @This(), _: std.mem.Allocator, id: u32) !Record {
            get_called = true;
            return .{ .value = id };
        }

        pub fn list(_: @This(), allocator: std.mem.Allocator, params: ListParams) !ListPage(Record) {
            list_called = true;
            const entries = try allocator.alloc(Record, 1);
            entries[0] = .{ .value = 42 };
            return ListPage(Record).init(entries, params, 1);
        }
    };

    FakeRepository.get_called = false;
    FakeRepository.list_called = false;

    const ReadOnlyRepository = interface(Record, u32);
    const repo = ReadOnlyRepository.bind(FakeRepository);

    const record = try repo.get(testing.allocator, 7);
    try testing.expect(FakeRepository.get_called);
    try testing.expectEqual(@as(u32, 7), record.value);

    const page = try repo.list(testing.allocator, .{
        .page = 1,
        .page_size = 50,
        .sort_by = "id",
        .sort_order = .asc,
    });
    defer testing.allocator.free(page.entries);

    try testing.expect(FakeRepository.list_called);
    try testing.expectEqual(@as(usize, 1), page.entries.len);
    try testing.expectEqual(@as(u32, 42), page.entries[0].value);
}
