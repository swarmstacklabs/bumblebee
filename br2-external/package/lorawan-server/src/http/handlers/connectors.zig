const std = @import("std");

const connectors_repository = @import("../../repository/connectors_repository.zig");
const crud_handler = @import("crud_handler.zig");
const context_mod = @import("../context.zig");
const crud_repository = @import("../../repository/crud_repository.zig");

pub const CRUDHandler = crud_handler.Interface(
    connectors_repository.Record,
    connectors_repository.WriteInput,
    i64,
    connectors_repository.CRUDRepository,
);

const Handler = CRUDHandler.bind(struct {
    pub const entity_name = "connector";
    pub const default_page_size: usize = 50;
    pub const max_page_size: usize = 100;
    pub const default_sort_by = "id";
    pub const default_sort_order = crud_repository.SortOrder.asc;

    pub fn repo(ctx: *context_mod.Context) connectors_repository.CRUDRepository {
        return ctx.services.connector_repo;
    }

    pub fn parseWriteInput(ctx: *context_mod.Context, body: []const u8) !connectors_repository.WriteInput {
        return parseConnectorWriteInput(ctx, body);
    }

    pub fn normalizeSortBy(sort_by: []const u8) ![]const u8 {
        if (std.mem.eql(u8, sort_by, "id")) return sort_by;
        if (std.mem.eql(u8, sort_by, "name")) return sort_by;
        if (std.mem.eql(u8, sort_by, "connector_type")) return sort_by;
        if (std.mem.eql(u8, sort_by, "uri")) return sort_by;
        if (std.mem.eql(u8, sort_by, "enabled")) return sort_by;
        if (std.mem.eql(u8, sort_by, "partition")) return sort_by;
        if (std.mem.eql(u8, sort_by, "created_at")) return sort_by;
        if (std.mem.eql(u8, sort_by, "updated_at")) return sort_by;
        return error.BadRequest;
    }
});

pub const list = Handler.list;
pub const get = Handler.get;
pub const create = Handler.create;
pub const update = Handler.update;
pub const delete = Handler.delete;

const ConnectorWriteBody = struct {
    name: []const u8,
    connector_type: []const u8,
    uri: []const u8,
    enabled: bool = true,
    topic: ?[]const u8 = null,
    exchange_name: ?[]const u8 = null,
    exchange: ?[]const u8 = null,
    routing_key: ?[]const u8 = null,
    partition: i32 = 0,
    client_id: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

fn parseConnectorWriteInput(ctx: *context_mod.Context, body: []const u8) !connectors_repository.WriteInput {
    const parsed = try std.json.parseFromSlice(ConnectorWriteBody, ctx.allocator, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return .{
        .name = try ctx.allocator.dupe(u8, parsed.value.name),
        .connector_type = try ctx.allocator.dupe(u8, parsed.value.connector_type),
        .uri = try ctx.allocator.dupe(u8, parsed.value.uri),
        .enabled = parsed.value.enabled,
        .topic = try dupeOptional(ctx.allocator, parsed.value.topic),
        .exchange_name = try dupeOptional(ctx.allocator, parsed.value.exchange_name orelse parsed.value.exchange),
        .routing_key = try dupeOptional(ctx.allocator, parsed.value.routing_key),
        .partition = parsed.value.partition,
        .client_id = try dupeOptional(ctx.allocator, parsed.value.client_id),
        .username = try dupeOptional(ctx.allocator, parsed.value.username),
        .password = try dupeOptional(ctx.allocator, parsed.value.password),
    };
}

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |text| return try allocator.dupe(u8, text);
    return null;
}
