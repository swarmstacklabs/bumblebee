const std = @import("std");

const http_transport = @import("transport.zig");
const request_mod = @import("request.zig");

pub const Response = struct {
    allocator: std.mem.Allocator,
    status: u16 = 200,
    content_type: []const u8 = "text/plain; charset=utf-8",
    body: []const u8 = "",
    owns_body: bool = false,
    headers: std.ArrayListUnmanaged(request_mod.Header) = .{},

    pub fn init(allocator: std.mem.Allocator) Response {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Response) void {
        self.resetBody();
        self.headers.deinit(self.allocator);
    }

    pub fn setText(self: *Response, status: u16, body: []const u8) void {
        self.resetBody();
        self.status = status;
        self.content_type = "text/plain; charset=utf-8";
        self.body = body;
    }

    pub fn setJson(self: *Response, payload: anytype) !void {
        try self.setJsonStatus(200, payload);
    }

    pub fn setJsonStatus(self: *Response, status: u16, payload: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(self.allocator, payload, .{});
        self.resetBody();
        self.status = status;
        self.content_type = "application/json";
        self.body = json;
        self.owns_body = true;
    }

    pub fn setOwnedBody(self: *Response, status: u16, content_type: []const u8, body: []const u8) void {
        self.resetBody();
        self.status = status;
        self.content_type = content_type;
        self.body = body;
        self.owns_body = true;
    }

    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) !void {
        for (self.headers.items) |*header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) {
                header.value = value;
                return;
            }
        }
        try self.headers.append(self.allocator, .{ .name = name, .value = value });
    }

    pub fn writeTo(self: *const Response, conn: *http_transport.Connection) !void {
        var header_buf: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&header_buf);
        const writer = stream.writer();

        try writer.print(
            "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n",
            .{ self.status, reasonPhrase(self.status), self.content_type, self.body.len },
        );
        for (self.headers.items) |header| {
            try writer.print("{s}: {s}\r\n", .{ header.name, header.value });
        }
        try writer.writeAll("\r\n");

        try conn.writeAll(stream.getWritten());
        try conn.writeAll(self.body);
    }

    fn resetBody(self: *Response) void {
        if (self.owns_body) {
            self.allocator.free(self.body);
            self.owns_body = false;
        }
        self.body = "";
    }
};

fn reasonPhrase(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        500 => "Internal Server Error",
        else => "OK",
    };
}
