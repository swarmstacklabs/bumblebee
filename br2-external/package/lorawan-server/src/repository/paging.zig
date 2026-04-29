pub const SortOrder = enum {
    asc,
    desc,
};

pub const ListParams = struct {
    page: usize = 1,
    page_size: usize = 50,
    sort_by: []const u8,
    sort_order: SortOrder,

    pub fn offset(self: ListParams) usize {
        return (self.page - 1) * self.page_size;
    }
};

pub fn ListPage(comptime Record: type) type {
    return struct {
        entries: []Record,
        page_number: usize,
        page_size: usize,
        total_entries: usize,
        total_pages: usize,
        sort_by: []const u8,
        sort_order: SortOrder,

        pub fn init(entries: []Record, params: ListParams, total_entries: usize) @This() {
            return .{
                .entries = entries,
                .page_number = params.page,
                .page_size = params.page_size,
                .total_entries = total_entries,
                .total_pages = totalPages(total_entries, params.page_size),
                .sort_by = params.sort_by,
                .sort_order = params.sort_order,
            };
        }
    };
}

pub fn totalPages(total_entries: usize, page_size: usize) usize {
    if (total_entries == 0) return 0;
    return (total_entries + page_size - 1) / page_size;
}
