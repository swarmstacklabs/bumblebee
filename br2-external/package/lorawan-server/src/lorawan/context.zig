const std = @import("std");

const commands = @import("commands.zig");

pub const CommandTag = std.meta.Tag(commands.Command);

pub const Context = struct {
    allocator: std.mem.Allocator,
    command: ?commands.Command = null,
    command_index: usize = 0,
    response_commands: std.ArrayListUnmanaged(commands.Command) = .{},
    user_data: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator) Context {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Context) void {
        self.response_commands.deinit(self.allocator);
    }

    pub fn setCommand(self: *Context, command_index: usize, command: commands.Command) void {
        self.command_index = command_index;
        self.command = command;
    }

    pub fn currentCommand(self: *const Context) !commands.Command {
        return self.command orelse error.MissingCommand;
    }

    pub fn currentTag(self: *const Context) !CommandTag {
        return std.meta.activeTag(try self.currentCommand());
    }

    pub fn appendResponse(self: *Context, command: commands.Command) !void {
        try self.response_commands.append(self.allocator, command);
    }

    pub fn setUserData(self: *Context, ptr: anytype) void {
        const Ptr = @TypeOf(ptr);
        const info = @typeInfo(Ptr);
        if (info != .pointer or info.pointer.size != .one) {
            @compileError("setUserData expects a single-item pointer");
        }

        self.user_data = @ptrCast(ptr);
    }

    pub fn data(self: *const Context, comptime T: type) *T {
        return @ptrCast(@alignCast(self.user_data orelse unreachable));
    }
};

test "context tracks command and queued responses" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    ctx.setCommand(1, .device_time_req);
    try std.testing.expectEqual(@as(usize, 1), ctx.command_index);
    try std.testing.expect((try ctx.currentCommand()) == .device_time_req);
    try std.testing.expectEqual(CommandTag.device_time_req, try ctx.currentTag());

    try ctx.appendResponse(.{ .device_time_ans = .{ .milliseconds_since_epoch = 1234 } });
    try std.testing.expectEqual(@as(usize, 1), ctx.response_commands.items.len);
    try std.testing.expect(ctx.response_commands.items[0] == .device_time_ans);
}

test "context exposes typed user data" {
    const State = struct {
        value: u8,
    };

    var state = State{ .value = 7 };
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    ctx.setUserData(&state);
    ctx.data(State).value += 1;

    try std.testing.expectEqual(@as(u8, 8), state.value);
}
