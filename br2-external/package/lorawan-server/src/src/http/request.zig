const std = @import("std");
const http_transport = @import("transport.zig");

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    OPTIONS,
    HEAD,
    UNKNOWN,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: Method,
    target: []const u8,
    path: []const u8,
    body: []const u8,
    headers: []const Header,

    pub fn header(self: Request, name: []const u8) ?[]const u8 {
        for (self.headers) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
        }
        return null;
    }
};

pub fn parse(raw: []const u8, body_start: usize, header_buf: []Header) !Request {
    const header_block = raw[0 .. body_start - 4];
    const first_line_end = std.mem.indexOf(u8, header_block, "\r\n") orelse header_block.len;
    const request_line = header_block[0..first_line_end];

    var parts = std.mem.tokenizeScalar(u8, request_line, ' ');
    const method_text = parts.next() orelse return error.BadRequest;
    const target = parts.next() orelse return error.BadRequest;

    var header_count: usize = 0;
    var it = std.mem.tokenizeSequence(u8, header_block[first_line_end..], "\r\n");
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const sep = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadRequest;
        if (header_count >= header_buf.len) return error.TooManyHeaders;

        header_buf[header_count] = .{
            .name = std.mem.trim(u8, line[0..sep], " \t"),
            .value = std.mem.trim(u8, line[sep + 1 ..], " \t"),
        };
        header_count += 1;
    }

    return .{
        .method = parseMethod(method_text),
        .target = target,
        .path = stripQuery(target),
        .body = raw[body_start..],
        .headers = header_buf[0..header_count],
    };
}

pub fn parseConnection(conn: *const http_transport.Connection, header_buf: []Header) !Request {
    const raw = conn.requestBytes() orelse return error.IncompleteRequest;
    const body_start = conn.header_end orelse return error.IncompleteRequest;
    return parse(raw, body_start, header_buf);
}

pub fn parseMethod(value: []const u8) Method {
    if (std.ascii.eqlIgnoreCase(value, "GET")) return .GET;
    if (std.ascii.eqlIgnoreCase(value, "POST")) return .POST;
    if (std.ascii.eqlIgnoreCase(value, "PUT")) return .PUT;
    if (std.ascii.eqlIgnoreCase(value, "DELETE")) return .DELETE;
    if (std.ascii.eqlIgnoreCase(value, "PATCH")) return .PATCH;
    if (std.ascii.eqlIgnoreCase(value, "OPTIONS")) return .OPTIONS;
    if (std.ascii.eqlIgnoreCase(value, "HEAD")) return .HEAD;
    return .UNKNOWN;
}

fn stripQuery(target: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, target, "?#") orelse target.len;
    return target[0..end];
}
