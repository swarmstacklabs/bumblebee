const context_mod = @import("../context.zig");
const mac_command_state = @import("../mac_command_state.zig");
const runtime = @import("../runtime.zig");

pub fn middleware(ctx: *context_mod.Context, exec: *runtime.Executor) runtime.AppError!void {
    const command_tag = try ctx.currentTag();
    const state = ctx.data(mac_command_state.State);

    if (state.mode == .node_update) {
        if (mac_command_state.requiresNode(command_tag) and state.node == null) {
            return error.MissingMacCommandNodeContext;
        }
        if (mac_command_state.requiresRegion(command_tag) and state.region == null) {
            return error.MissingMacCommandRegionContext;
        }
        if (mac_command_state.requiresPendingState(command_tag)) {
            if (!state.pending_state_ready) return error.MissingMacCommandPendingState;
            if (state.pending_index > state.pending_commands.len) return error.InvalidMacCommandPendingState;
        }
    }

    return exec.next(ctx);
}
