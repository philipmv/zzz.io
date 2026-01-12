const std = @import("std");
const log = std.log.scoped(.@"examples/basic");

const zzz = @import("zzz");
const http = zzz.HTTP;

const Io = std.Io;

const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Respond = http.Respond;

fn base_handler(ctx: *const Context, _: void) !Respond {
    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = "Hello, world!",
    });
}

fn shutdown(_: std.c.SIG) callconv(.c) void {
    server.stop();
}

var server: Server = undefined;

pub fn main(init: std.process.Init) !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    std.posix.sigaction(std.posix.SIG.TERM, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    var router = try Router.init(init.gpa, &.{
        Route.init("/").get({}, base_handler).layer(),
    }, .{});
    defer router.deinit(init.gpa);

    const addr = try Io.net.IpAddress.parse(host, port);
    var s = try addr.listen(init.io, .{ .kernel_backlog = 4096 });
    defer s.deinit(init.io);

    server = try Server.init(init.gpa, init.io, .{
        .socket_buffer_bytes = 1024 * 2,
        .keepalive_count_max = null,
        .connection_count_max = 1024,
    });
    defer server.deinit();
    try server.serve(&router, &s);
}
