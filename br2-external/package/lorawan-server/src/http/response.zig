const std = @import("std");

const http_transport = @import("transport.zig");
const request_mod = @import("request.zig");

pub const Status = enum(u16) {
    @"continue" = 100,
    ok = 200,
    created = 201,
    no_content = 204,
    not_modified = 304,
    bad_request = 400,
    unauthorized = 401,
    not_found = 404,
    method_not_allowed = 405,
    conflict = 409,
    service_unavailable = 503,
    internal_server_error = 500,
    _,

    pub fn code(self: Status) u16 {
        return @intFromEnum(self);
    }

    pub fn reason(self: Status) []const u8 {
        return switch (self) {
            .@"continue" => "Continue",
            .ok => "OK",
            .created => "Created",
            .no_content => "No Content",
            .not_modified => "Not Modified",
            .bad_request => "Bad Request",
            .unauthorized => "Unauthorized",
            .not_found => "Not Found",
            .method_not_allowed => "Method Not Allowed",
            .conflict => "Conflict",
            .service_unavailable => "Service Unavailable",
            .internal_server_error => "Internal Server Error",
            else => "Unknown Status",
        };
    }

    pub fn isInformational(self: Status) bool {
        const status_code = self.code();
        return status_code >= 100 and status_code < 200;
    }

    pub fn isEmpty(self: Status) bool {
        return switch (self) {
            .no_content, .not_modified => true,
            else => false,
        };
    }
};

pub const Response = struct {
    allocator: std.mem.Allocator,
    status: Status = .ok,
    content_type: ?[]const u8 = "text/plain; charset=utf-8",
    body: []const u8 = "",
    owns_body: bool = false,
    prepared_content_length: ?usize = null,
    headers: std.ArrayListUnmanaged(request_mod.Header) = .{},

    pub fn init(allocator: std.mem.Allocator) Response {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Response) void {
        self.resetBody();
        self.headers.deinit(self.allocator);
    }

    pub fn setText(self: *Response, status: Status, body: []const u8) void {
        self.resetBody();
        self.status = status;
        self.content_type = "text/plain; charset=utf-8";
        self.body = body;
    }

    pub fn setJson(self: *Response, payload: anytype) !void {
        try self.setJsonStatus(.ok, payload);
    }

    pub fn setJsonStatus(self: *Response, status: Status, payload: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(self.allocator, payload, .{});
        self.resetBody();
        self.status = status;
        self.content_type = "application/json";
        self.body = json;
        self.owns_body = true;
    }

    pub fn setOwnedBody(self: *Response, status: Status, content_type: []const u8, body: []const u8) void {
        self.resetBody();
        self.status = status;
        self.content_type = content_type;
        self.body = body;
        self.owns_body = true;
    }

    pub fn prepare(self: *Response, req: request_mod.Request) void {
        self.prepared_content_length = null;

        if (self.status.isInformational() or self.status.isEmpty()) {
            self.content_type = null;
            self.body = "";
            return;
        }

        if (req.method == .HEAD) {
            self.prepared_content_length = self.body.len;
            self.body = "";
        }
    }

    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) !void {
        for (self.headers.items) |*header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) {
                header.value = value;
                return;
            }
        }
        try self.headers.append(self.allocator, request_mod.Header.init(name, value));
    }

    pub fn writeTo(self: *const Response, conn: *http_transport.Connection) !void {
        var header_buf: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&header_buf);
        const writer = stream.writer();

        try writer.print("HTTP/1.1 {d} {s}\r\n", .{ self.status.code(), self.status.reason() });
        if (self.content_type) |content_type| {
            try writer.print("Content-Type: {s}\r\n", .{content_type});
        }
        if (!self.status.isInformational() and !self.status.isEmpty()) {
            try writer.print("Content-Length: {d}\r\n", .{self.prepared_content_length orelse self.body.len});
        }
        try writer.writeAll("Connection: close\r\n");
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

test "prepare removes entity headers for no content responses" {
    var res = Response.init(std.testing.allocator);
    defer res.deinit();

    res.setText(.no_content, "should be dropped");
    res.prepare(testRequest(.GET));

    try std.testing.expectEqual(Status.no_content, res.status);
    try std.testing.expectEqual(@as(?[]const u8, null), res.content_type);
    try std.testing.expectEqualStrings("", res.body);
    try std.testing.expectEqual(@as(?usize, null), res.prepared_content_length);
}

test "prepare keeps head content length while suppressing body" {
    var res = Response.init(std.testing.allocator);
    defer res.deinit();

    res.setText(.ok, "hello");
    res.prepare(testRequest(.HEAD));

    try std.testing.expectEqual(Status.ok, res.status);
    try std.testing.expectEqualStrings("", res.body);
    try std.testing.expectEqual(@as(?usize, 5), res.prepared_content_length);
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", res.content_type.?);
}

fn testRequest(method: request_mod.Method) request_mod.Request {
    return request_mod.Request.init(method, "/", "/", "", &.{});
}
