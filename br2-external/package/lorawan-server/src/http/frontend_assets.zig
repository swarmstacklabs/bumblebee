const std = @import("std");

pub const Asset = struct {
    path: []u8,
    content_type: []const u8,

    pub fn deinit(self: Asset, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const LookupResult = union(enum) {
    file: Asset,
    index: Asset,
    missing_index: []u8,

    pub fn deinit(self: LookupResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .file => |asset| asset.deinit(allocator),
            .index => |asset| asset.deinit(allocator),
            .missing_index => |path| allocator.free(path),
        }
    }
};

pub fn shouldHandleSpaPath(path: []const u8) bool {
    return !(std.mem.eql(u8, path, "/api") or std.mem.startsWith(u8, path, "/api/"));
}

pub fn lookup(allocator: std.mem.Allocator, root: []const u8, request_path: []const u8) !LookupResult {
    const root_abs = try std.fs.path.resolve(allocator, &.{root});
    defer allocator.free(root_abs);

    const cleaned_path = cleanPath(request_path);
    if (cleaned_path.len > 0) {
        if (try resolveExistingFile(allocator, root_abs, cleaned_path)) |asset_path| {
            return .{ .file = .{
                .path = asset_path,
                .content_type = mimeFor(asset_path),
            } };
        }
    }

    const index_path = try std.fs.path.resolve(allocator, &.{ root_abs, "index.html" });
    if (try isRegularFile(index_path)) {
        return .{ .index = .{
            .path = index_path,
            .content_type = "text/html; charset=utf-8",
        } };
    }

    return .{ .missing_index = index_path };
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    return try file.readToEndAlloc(allocator, stat.size);
}

pub fn mimeFor(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);

    if (std.mem.eql(u8, ext, ".html")) return "text/html; charset=utf-8";
    if (std.mem.eql(u8, ext, ".css")) return "text/css; charset=utf-8";
    if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".mjs")) return "application/javascript; charset=utf-8";
    if (std.mem.eql(u8, ext, ".json")) return "application/json";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, ".gif")) return "image/gif";
    if (std.mem.eql(u8, ext, ".webp")) return "image/webp";
    if (std.mem.eql(u8, ext, ".ico")) return "image/x-icon";
    if (std.mem.eql(u8, ext, ".txt")) return "text/plain; charset=utf-8";
    if (std.mem.eql(u8, ext, ".map")) return "application/json";
    if (std.mem.eql(u8, ext, ".woff")) return "font/woff";
    if (std.mem.eql(u8, ext, ".woff2")) return "font/woff2";
    if (std.mem.eql(u8, ext, ".ttf")) return "font/ttf";
    if (std.mem.eql(u8, ext, ".wasm")) return "application/wasm";

    return "application/octet-stream";
}

fn cleanPath(path: []const u8) []const u8 {
    return std.mem.trim(u8, path, "/");
}

fn resolveExistingFile(allocator: std.mem.Allocator, root_abs: []const u8, rel_path: []const u8) !?[]u8 {
    const candidate = try std.fs.path.resolve(allocator, &.{ root_abs, rel_path });
    errdefer allocator.free(candidate);

    if (!isWithinRoot(root_abs, candidate)) {
        allocator.free(candidate);
        return null;
    }

    if (!try isRegularFile(candidate)) {
        allocator.free(candidate);
        return null;
    }

    return candidate;
}

fn isWithinRoot(root_abs: []const u8, candidate_abs: []const u8) bool {
    if (std.mem.eql(u8, root_abs, candidate_abs)) return true;
    if (!std.mem.startsWith(u8, candidate_abs, root_abs)) return false;
    return candidate_abs.len > root_abs.len and candidate_abs[root_abs.len] == std.fs.path.sep;
}

fn isRegularFile(path: []const u8) !bool {
    var file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    return stat.kind == .file;
}

test "lookup serves an existing asset under the configured root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("frontend/assets");
    try tmp.dir.writeFile(.{ .sub_path = "frontend/assets/app.js", .data = "console.log('ok');" });
    try tmp.dir.writeFile(.{ .sub_path = "frontend/index.html", .data = "<html></html>" });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, "frontend");
    defer std.testing.allocator.free(root);

    var result = try lookup(std.testing.allocator, root, "/assets/app.js");
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result == .file);
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", result.file.content_type);
}

test "lookup falls back to index for client-side routes and traversal attempts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("frontend/assets");
    try tmp.dir.writeFile(.{ .sub_path = "frontend/index.html", .data = "<html>spa</html>" });
    try tmp.dir.writeFile(.{ .sub_path = "secret.txt", .data = "nope" });

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, "frontend");
    defer std.testing.allocator.free(root);

    var client_route = try lookup(std.testing.allocator, root, "/devices/42");
    defer client_route.deinit(std.testing.allocator);
    try std.testing.expect(client_route == .index);

    var traversal = try lookup(std.testing.allocator, root, "/../secret.txt");
    defer traversal.deinit(std.testing.allocator);
    try std.testing.expect(traversal == .index);
}

test "lookup reports missing index when configured root does not exist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const missing_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(missing_root);

    const configured_root = try std.fs.path.resolve(std.testing.allocator, &.{ missing_root, "missing-frontend" });
    defer std.testing.allocator.free(configured_root);

    var result = try lookup(std.testing.allocator, configured_root, "/");
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result == .missing_index);
    try std.testing.expect(std.mem.endsWith(u8, result.missing_index, "missing-frontend/index.html"));
}

test "isRegularFile returns false for a relative missing path" {
    try std.testing.expect(!(try isRegularFile("missing-relative-file.txt")));
}
