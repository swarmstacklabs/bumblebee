const std = @import("std");

pub fn Interface(comptime Record: type) type {
    return struct {
        const Self = @This();

        getFn: *const fn (std.mem.Allocator) anyerror!Record,

        pub fn bind(comptime Impl: type) Self {
            comptime ensureReadOnlyImplementation(Impl);

            return .{
                .getFn = struct {
                    fn call(allocator: std.mem.Allocator) !Record {
                        return Impl.get(allocator);
                    }
                }.call,
            };
        }

        pub fn get(self: Self, allocator: std.mem.Allocator) !Record {
            return self.getFn(allocator);
        }
    };
}

fn ensureReadOnlyImplementation(comptime Impl: type) void {
    if (!@hasDecl(Impl, "get")) {
        @compileError(std.fmt.comptimePrint(
            "{s} must implement `get` to satisfy ReadOnlyRepository",
            .{@typeName(Impl)},
        ));
    }
}

test "ReadOnlyRepository forwards get to implementation" {
    const testing = std.testing;

    const Record = struct { value: u32 };

    const FakeRepository = struct {
        var called = false;

        pub fn get(_: std.mem.Allocator) !Record {
            called = true;
            return .{ .value = 42 };
        }
    };

    FakeRepository.called = false;

    const ReadOnlyRepository = Interface(Record);
    const repo = ReadOnlyRepository.bind(FakeRepository);
    const record = try repo.get(testing.allocator);

    try testing.expect(FakeRepository.called);
    try testing.expectEqual(@as(u32, 42), record.value);
}
