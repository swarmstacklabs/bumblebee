const std = @import("std");

pub fn interface(comptime Record: type, comptime Id: type) type {
    return struct {
        const Self = @This();
        pub const IdType = Id;

        getFn: *const fn (std.mem.Allocator, Id) anyerror!Record,

        pub fn bind(comptime Impl: type) Self {
            comptime ensureGetOnlyImplementation(Impl);

            return .{
                .getFn = struct {
                    fn call(allocator: std.mem.Allocator, id: Id) anyerror!Record {
                        return Impl.init().get(allocator, id);
                    }
                }.call,
            };
        }

        pub fn get(self: Self, allocator: std.mem.Allocator, id: Id) !Record {
            return self.getFn(allocator, id);
        }
    };
}

fn ensureGetOnlyImplementation(comptime Impl: type) void {
    const required = [_][]const u8{"get"};
    inline for (required) |decl_name| {
        if (!@hasDecl(Impl, decl_name)) {
            @compileError(std.fmt.comptimePrint(
                "{s} must implement `{s}` to satisfy GetOnlyRepository",
                .{ @typeName(Impl), decl_name },
            ));
        }
    }
}

test "GetOnlyRepository forwards get to implementation" {
    const testing = std.testing;

    const Record = struct { value: u32 };

    const FakeRepository = struct {
        var get_called = false;

        pub fn init() @This() {
            return .{};
        }

        pub fn get(_: @This(), _: std.mem.Allocator, id: u32) !Record {
            get_called = true;
            return .{ .value = id };
        }
    };

    FakeRepository.get_called = false;

    const GetOnlyRepository = interface(Record, u32);
    const repo = GetOnlyRepository.bind(FakeRepository);

    const record = try repo.get(testing.allocator, 7);
    try testing.expect(FakeRepository.get_called);
    try testing.expectEqual(@as(u32, 7), record.value);
}
