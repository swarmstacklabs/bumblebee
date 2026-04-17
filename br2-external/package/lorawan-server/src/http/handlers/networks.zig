const std = @import("std");

const networks_repository = @import("../../repository/networks_repository.zig");
const crud_handler = @import("crud_handler.zig");
const context_mod = @import("../context.zig");
const crud_repository = @import("../../repository/crud_repository.zig");
const region_mod = @import("../../lora/region.zig");

pub const CRUDHandler = crud_handler.Interface(
    networks_repository.Record,
    networks_repository.WriteInput,
    []const u8,
    networks_repository.CRUDRepository,
);

const Handler = CRUDHandler.bind(struct {
    pub const entity_name = "network";
    pub const default_page_size: usize = 50;
    pub const max_page_size: usize = 100;
    pub const default_sort_by = "id";
    pub const default_sort_order = crud_repository.SortOrder.asc;

    pub fn repo(ctx: *context_mod.Context) networks_repository.CRUDRepository {
        return ctx.services.network_repo;
    }

    pub fn parseWriteInput(ctx: *context_mod.Context, body: []const u8) !networks_repository.WriteInput {
        return parseNetworkWriteInput(ctx, body);
    }

    pub fn normalizeSortBy(sort_by: []const u8) ![]const u8 {
        if (std.mem.eql(u8, sort_by, "id")) return sort_by;
        if (std.mem.eql(u8, sort_by, "name")) return sort_by;
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

const RxWinInitBody = struct {
    rx1_dr_offset: ?u8 = null,
    rx2_data_rate: ?u8 = null,
    frequency: ?f64 = null,
};

const NetworkWriteBody = struct {
    name: []const u8,
    region: ?[]const u8 = null,
    netid: []const u8,
    tx_codr: ?[]const u8 = null,
    join1_delay: ?u32 = null,
    rx1_delay: ?u32 = null,
    gw_power: ?i32 = null,
    rxwin_init: ?RxWinInitBody = null,
    cflist: ?[]const f64 = null,
};

fn parseNetworkWriteInput(ctx: *context_mod.Context, body: []const u8) !networks_repository.WriteInput {
    const parsed = try std.json.parseFromSlice(NetworkWriteBody, ctx.allocator, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const trimmed_name = std.mem.trim(u8, parsed.value.name, " \t\r\n");
    if (trimmed_name.len == 0) return error.BadRequest;

    const region_text = parsed.value.region orelse "EU868";
    const region = region_mod.Region.parse(region_text) catch return error.BadRequest;
    const rx_defaults = region.defaultRxWindow();
    const tx_codr = std.mem.trim(u8, parsed.value.tx_codr orelse "4/5", " \t\r\n");
    if (tx_codr.len == 0) return error.BadRequest;

    const cflist_values = parsed.value.cflist orelse &.{};
    if (cflist_values.len > 0 and !region.supportsFrequencyCfList()) return error.BadRequest;
    if (cflist_values.len > 5) return error.BadRequest;
    for (cflist_values) |freq| {
        if (freq <= 0) return error.BadRequest;
    }

    const netid = try normalizeHexLower(ctx.allocator, parsed.value.netid, 6);
    defer ctx.allocator.free(netid);

    const network_json = try std.json.Stringify.valueAlloc(ctx.allocator, .{
        .region = region.canonicalName(),
        .netid = netid,
        .tx_codr = tx_codr,
        .join1_delay = parsed.value.join1_delay orelse 5,
        .rx1_delay = parsed.value.rx1_delay orelse 1,
        .gw_power = parsed.value.gw_power orelse 14,
        .rxwin_init = .{
            .rx1_dr_offset = if (parsed.value.rxwin_init) |rx| rx.rx1_dr_offset orelse rx_defaults.rx1_dr_offset else rx_defaults.rx1_dr_offset,
            .rx2_data_rate = if (parsed.value.rxwin_init) |rx| rx.rx2_data_rate orelse rx_defaults.rx2_data_rate else rx_defaults.rx2_data_rate,
            .frequency = if (parsed.value.rxwin_init) |rx| rx.frequency orelse rx_defaults.frequency else rx_defaults.frequency,
        },
        .cflist = if (cflist_values.len > 0) cflist_values else null,
    }, .{});

    return .{
        .name = try ctx.allocator.dupe(u8, trimmed_name),
        .network_json = network_json,
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
