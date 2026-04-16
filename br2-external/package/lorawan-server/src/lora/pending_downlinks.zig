const std = @import("std");

pub const pending_ttl_ms: i64 = 30_000;

pub const Entry = struct {
    gateway_mac: [8]u8,
    dev_addr: ?[]u8,
    sent_at_ms: i64,

    pub fn init(gateway_mac: [8]u8, dev_addr: ?[]u8, sent_at_ms: i64) Entry {
        return .{
            .gateway_mac = gateway_mac,
            .dev_addr = dev_addr,
            .sent_at_ms = sent_at_ms,
        };
    }

    pub fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        if (self.dev_addr) |value| allocator.free(value);
    }
};

pub const Key = struct {
    gateway_mac: [8]u8,
    token: u16,

    pub fn init(gateway_mac: [8]u8, token: u16) Key {
        return .{
            .gateway_mac = gateway_mac,
            .token = token,
        };
    }

    pub fn deinit(_: Key) void {}
};

pub const Tracker = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    pending: std.AutoHashMap(Key, Entry),

    pub fn init(allocator: std.mem.Allocator) Tracker {
        return .{
            .allocator = allocator,
            .pending = std.AutoHashMap(Key, Entry).init(allocator),
        };
    }

    pub fn deinit(self: *Tracker) void {
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            freeEntry(self.allocator, entry.value_ptr.*);
        }
        self.pending.deinit();
    }

    pub fn remember(self: *Tracker, gateway_mac: [8]u8, token: u16, dev_addr: ?[]const u8) !void {
        const entry = Entry.init(
            gateway_mac,
            if (dev_addr) |value| try self.allocator.dupe(u8, value) else null,
            std.time.milliTimestamp(),
        );
        errdefer entry.deinit(self.allocator);

        self.mutex.lock();
        defer self.mutex.unlock();

        const key = Key.init(gateway_mac, token);

        if (self.pending.fetchRemove(key)) |removed| {
            removed.value.deinit(self.allocator);
        }
        try self.pending.put(key, entry);
    }

    pub fn take(self: *Tracker, gateway_mac: [8]u8, token: u16) ?Entry {
        self.mutex.lock();
        defer self.mutex.unlock();

        const removed = self.pending.fetchRemove(Key.init(gateway_mac, token)) orelse return null;
        return removed.value;
    }

    pub fn pruneExpired(self: *Tracker) void {
        const now_ms = std.time.milliTimestamp();
        self.mutex.lock();
        defer self.mutex.unlock();

        var to_remove = std.ArrayList(Key){};
        defer to_remove.deinit(self.allocator);

        var it = self.pending.iterator();
        while (it.next()) |entry| {
            if (now_ms - entry.value_ptr.sent_at_ms >= pending_ttl_ms) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.pending.fetchRemove(key)) |removed| {
                removed.value.deinit(self.allocator);
            }
        }
    }
};

pub fn freeEntry(allocator: std.mem.Allocator, entry: Entry) void {
    entry.deinit(allocator);
}

pub fn randomToken() u16 {
    var bytes: [2]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return std.mem.readInt(u16, &bytes, .big);
}
