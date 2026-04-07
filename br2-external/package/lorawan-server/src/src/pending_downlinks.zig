const std = @import("std");

pub const pending_ttl_ms: i64 = 30_000;

pub const Entry = struct {
    gateway_mac: [8]u8,
    dev_addr: ?[]u8,
    sent_at_ms: i64,
};

pub const Tracker = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    pending: std.AutoHashMap(u16, Entry),

    pub fn init(allocator: std.mem.Allocator) Tracker {
        return .{
            .allocator = allocator,
            .pending = std.AutoHashMap(u16, Entry).init(allocator),
        };
    }

    pub fn deinit(self: *Tracker) void {
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            freeEntry(self.allocator, entry.value_ptr.*);
        }
        self.pending.deinit();
    }

    pub fn remember(self: *Tracker, token: u16, gateway_mac: [8]u8, dev_addr: ?[]const u8) !void {
        const entry = Entry{
            .gateway_mac = gateway_mac,
            .dev_addr = if (dev_addr) |value| try self.allocator.dupe(u8, value) else null,
            .sent_at_ms = std.time.milliTimestamp(),
        };
        errdefer freeEntry(self.allocator, entry);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pending.fetchRemove(token)) |removed| {
            freeEntry(self.allocator, removed.value);
        }
        try self.pending.put(token, entry);
    }

    pub fn take(self: *Tracker, token: u16) ?Entry {
        self.mutex.lock();
        defer self.mutex.unlock();

        const removed = self.pending.fetchRemove(token) orelse return null;
        return removed.value;
    }

    pub fn pruneExpired(self: *Tracker) void {
        const now_ms = std.time.milliTimestamp();
        self.mutex.lock();
        defer self.mutex.unlock();

        var to_remove = std.ArrayList(u16){};
        defer to_remove.deinit(self.allocator);

        var it = self.pending.iterator();
        while (it.next()) |entry| {
            if (now_ms - entry.value_ptr.sent_at_ms >= pending_ttl_ms) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |token| {
            if (self.pending.fetchRemove(token)) |removed| {
                freeEntry(self.allocator, removed.value);
            }
        }
    }
};

pub fn freeEntry(allocator: std.mem.Allocator, entry: Entry) void {
    if (entry.dev_addr) |value| allocator.free(value);
}

pub fn randomToken() u16 {
    var bytes: [2]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return std.mem.readInt(u16, &bytes, .big);
}
