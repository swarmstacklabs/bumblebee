const std = @import("std");

const gateways_repository = @import("../../repository/gateways_repository.zig");
const crud_handler = @import("crud_handler.zig");
const context_mod = @import("../context.zig");
const crud_repository = @import("../../repository/crud_repository.zig");

pub const CRUDHandler = crud_handler.interface(
    gateways_repository.Record,
    gateways_repository.WriteInput,
    []const u8,
    gateways_repository.CRUDRepository,
);

const Handler = CRUDHandler.bind(struct {
    pub const entity_name = "gateway";
    pub const default_page_size: usize = 50;
    pub const max_page_size: usize = 100;
    pub const default_sort_by = "id";
    pub const default_sort_order = crud_repository.SortOrder.asc;

    pub fn repo(ctx: *context_mod.Context) gateways_repository.CRUDRepository {
        return ctx.services.gateway_repo;
    }

    pub fn parseWriteInput(ctx: *context_mod.Context, body: []const u8) !gateways_repository.WriteInput {
        return parseGatewayWriteInput(ctx, body);
    }

    pub fn getListMetadata(ctx: *context_mod.Context) !GatewayMetadata {
        return getGatewayMetadata(ctx);
    }

    pub fn getMetadata(ctx: *context_mod.Context, record: gateways_repository.Record) !GatewayMetadata {
        _ = record;
        return getGatewayMetadata(ctx);
    }

    pub fn deinitMetadata(ctx: *context_mod.Context, metadata: GatewayMetadata) void {
        metadata.deinit(ctx.allocator);
    }

    pub fn normalizeSortBy(sort_by: []const u8) ![]const u8 {
        if (std.mem.eql(u8, sort_by, "id")) return sort_by;
        if (std.mem.eql(u8, sort_by, "mac")) return sort_by;
        if (std.mem.eql(u8, sort_by, "name")) return sort_by;
        if (std.mem.eql(u8, sort_by, "network_name")) return sort_by;
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

const GatewayWriteBody = struct {
    mac: []const u8,
    name: []const u8,
    network_name: []const u8,
    tx_rfch: u8 = 0,
};

const GatewayMetadata = struct {
    networks: []gateways_repository.NetworkOption,
    tx_rf_channels: [8]u16 = .{ 0, 1, 2, 3, 4, 5, 6, 7 },

    fn deinit(self: GatewayMetadata, allocator: std.mem.Allocator) void {
        for (self.networks) |*network| network.deinit(allocator);
        allocator.free(self.networks);
    }
};

fn getGatewayMetadata(ctx: *context_mod.Context) !GatewayMetadata {
    return .{
        .networks = try gateways_repository.listNetworkOptions(ctx.services.gateway_repo.storage, ctx.allocator),
    };
}

fn parseGatewayWriteInput(ctx: *context_mod.Context, body: []const u8) !gateways_repository.WriteInput {
    const parsed = try std.json.parseFromSlice(GatewayWriteBody, ctx.allocator, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const trimmed_name = std.mem.trim(u8, parsed.value.name, " \t\r\n");
    const trimmed_network_name = std.mem.trim(u8, parsed.value.network_name, " \t\r\n");
    if (trimmed_name.len == 0 or trimmed_network_name.len == 0) return error.BadRequest;

    return .{
        .mac = try normalizeHexLower(ctx.allocator, parsed.value.mac, 16),
        .name = try ctx.allocator.dupe(u8, trimmed_name),
        .network_name = try ctx.allocator.dupe(u8, trimmed_network_name),
        .tx_rfch = parsed.value.tx_rfch,
    };
}

fn normalizeHexLower(allocator: std.mem.Allocator, source: []const u8, expected_len: usize) ![]u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len != expected_len) return error.BadRequest;

    const out = try allocator.alloc(u8, trimmed.len);
    errdefer allocator.free(out);

    for (trimmed, 0..) |char, i| {
        if (!std.ascii.isHex(char)) return error.BadRequest;
        out[i] = std.ascii.toLower(char);
    }
    return out;
}
