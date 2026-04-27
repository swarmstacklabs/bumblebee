const std = @import("std");

const app = @import("app.zig");
const storage = @import("storage.zig");
const authenticator = @import("http/authenticator.zig");
const context = @import("http/context.zig");
const pipeline = @import("http/pipeline.zig");
const request = @import("http/request.zig");
const response = @import("http/response.zig");
const router = @import("http/router.zig");
const runtime = @import("http/runtime.zig");
const services = @import("http/services.zig");
const event_repository = @import("repository/event_repository.zig");
const http_request_metrics_repository = @import("repository/http_request_metrics_repository.zig");
const mac_command_metrics_repository = @import("repository/mac_command_metrics_repository.zig");
const device_repository = @import("repository/device_repository.zig");
const gateway_repository = @import("repository/gateway_repository.zig");
const lorawan_state_repository = @import("repository/lorawan_state_repository.zig");
const pending_downlinks = @import("lora/pending_downlinks.zig");
const lorawan_context = @import("lora/context.zig");
const lorawan_dispatcher = @import("lora/dispatcher.zig");
const lorawan_router = @import("lora/router.zig");
const lorawan_runtime = @import("lora/runtime.zig");
const types = @import("lora/types.zig");

fn expectInitDeinit(comptime T: type, comptime name: []const u8) void {
    if (!@hasDecl(T, "init")) @compileError(name ++ " must declare init()");
    if (!@hasDecl(T, "deinit")) @compileError(name ++ " must declare deinit()");
}

test "checked structs declare init and deinit" {
    comptime {
        expectInitDeinit(app.AdminConfig, "AdminConfig");
        expectInitDeinit(app.Config, "Config");
        expectInitDeinit(storage.Statement, "Statement");
        expectInitDeinit(app.StatusResponse, "StatusResponse");
        expectInitDeinit(app.ErrorResponse, "ErrorResponse");
        expectInitDeinit(app.DeviceRecord, "DeviceRecord");
        expectInitDeinit(app.DeviceWriteInput, "DeviceWriteInput");
        expectInitDeinit(app.Database, "Database");
        expectInitDeinit(app.App, "App");

        expectInitDeinit(request.Header, "Header");
        expectInitDeinit(request.Request, "Request");
        expectInitDeinit(context.RouteParam, "RouteParam");
        expectInitDeinit(context.Context, "Context");
        expectInitDeinit(response.Response, "Response");
        expectInitDeinit(runtime.Middleware, "Middleware");
        expectInitDeinit(runtime.Executor, "Executor");
        expectInitDeinit(router.Route, "Route");
        expectInitDeinit(router.Match, "Match");
        expectInitDeinit(router.Router, "Router");
        expectInitDeinit(pipeline.Dispatcher, "Dispatcher");
        expectInitDeinit(services.Services, "Services");
        expectInitDeinit(authenticator.Authenticator, "Authenticator");

        expectInitDeinit(device_repository.Repository, "device_repository.Repository");
        expectInitDeinit(event_repository.Repository, "event_repository.Repository");
        expectInitDeinit(http_request_metrics_repository.Repository, "http_request_metrics_repository.Repository");
        expectInitDeinit(mac_command_metrics_repository.Repository, "mac_command_metrics_repository.Repository");
        expectInitDeinit(gateway_repository.GatewayTarget, "gateway_repository.GatewayTarget");
        expectInitDeinit(gateway_repository.RuntimeRecord, "gateway_repository.RuntimeRecord");
        expectInitDeinit(gateway_repository.Repository, "gateway_repository.Repository");
        expectInitDeinit(lorawan_state_repository.Repository, "lorawan_state_repository.Repository");

        expectInitDeinit(pending_downlinks.Entry, "pending_downlinks.Entry");
        expectInitDeinit(pending_downlinks.Key, "pending_downlinks.Key");
        expectInitDeinit(pending_downlinks.Tracker, "pending_downlinks.Tracker");
        expectInitDeinit(lorawan_context.Context, "lorawan_context.Context");
        expectInitDeinit(lorawan_runtime.Middleware, "lorawan_runtime.Middleware");
        expectInitDeinit(lorawan_runtime.Executor, "lorawan_runtime.Executor");
        expectInitDeinit(lorawan_router.Route, "lorawan_router.Route");
        expectInitDeinit(lorawan_router.Match, "lorawan_router.Match");
        expectInitDeinit(lorawan_router.Router, "lorawan_router.Router");
        expectInitDeinit(lorawan_dispatcher.Dispatcher, "lorawan_dispatcher.Dispatcher");

        expectInitDeinit(types.RxWindowConfig, "types.RxWindowConfig");
        expectInitDeinit(types.AdrConfig, "types.AdrConfig");
        expectInitDeinit(types.ChannelMaskState, "types.ChannelMaskState");
        expectInitDeinit(types.ExtraChannel, "types.ExtraChannel");
        expectInitDeinit(types.DlChannelMapping, "types.DlChannelMapping");
        expectInitDeinit(types.Device, "types.Device");
        expectInitDeinit(types.Network, "types.Network");
        expectInitDeinit(types.Gateway, "types.Gateway");
        expectInitDeinit(types.ApplicationDownlink, "types.ApplicationDownlink");
        expectInitDeinit(types.Node, "types.Node");
        expectInitDeinit(types.TxData, "types.TxData");
        expectInitDeinit(types.JoinRequest, "types.JoinRequest");
        expectInitDeinit(types.DataFrame, "types.DataFrame");
        expectInitDeinit(types.ParsedDataFrame, "types.ParsedDataFrame");
    }

    try std.testing.expect(true);
}
