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
const device_repository = @import("repository/device_repository.zig");
const gateway_repository = @import("repository/gateway_repository.zig");
const lorawan_state_repository = @import("repository/lorawan_state_repository.zig");
const pending_downlinks = @import("lorawan/pending_downlinks.zig");
const types = @import("lorawan/types.zig");

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
        expectInitDeinit(gateway_repository.GatewayTarget, "gateway_repository.GatewayTarget");
        expectInitDeinit(gateway_repository.RuntimeRecord, "gateway_repository.RuntimeRecord");
        expectInitDeinit(gateway_repository.Repository, "gateway_repository.Repository");
        expectInitDeinit(lorawan_state_repository.Repository, "lorawan_state_repository.Repository");

        expectInitDeinit(pending_downlinks.Entry, "pending_downlinks.Entry");
        expectInitDeinit(pending_downlinks.Key, "pending_downlinks.Key");
        expectInitDeinit(pending_downlinks.Tracker, "pending_downlinks.Tracker");

        expectInitDeinit(types.RxWindowConfig, "types.RxWindowConfig");
        expectInitDeinit(types.AdrConfig, "types.AdrConfig");
        expectInitDeinit(types.Device, "types.Device");
        expectInitDeinit(types.Network, "types.Network");
        expectInitDeinit(types.Gateway, "types.Gateway");
        expectInitDeinit(types.Node, "types.Node");
        expectInitDeinit(types.TxData, "types.TxData");
        expectInitDeinit(types.JoinRequest, "types.JoinRequest");
        expectInitDeinit(types.DataFrame, "types.DataFrame");
        expectInitDeinit(types.ParsedDataFrame, "types.ParsedDataFrame");
    }

    try std.testing.expect(true);
}
