const std = @import("std");
const log = std.log.scoped(.@"examples/cookies");

const zzz = @import("zzz");
const http = zzz.HTTP;

const Io = std.Io;

const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Middleware = http.Middleware;
const Respond = http.Respond;
const Cookie = http.Cookie;

fn base_handler(ctx: *const Context, _: void) !Respond {
    var iter = ctx.request.cookies.iterator();
    while (iter.next()) |kv| log.debug("cookie: k={s} v={s}", .{ kv.key_ptr.*, kv.value_ptr.* });

    const cookie = Cookie.init("example_cookie", "abcdef123");
    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = "Hello, world!",
        .headers = &.{
            .{ "Set-Cookie", try cookie.to_string_alloc(ctx.allocator) },
        },
    });
}

fn shutdown(_: std.c.SIG) callconv(.c) void {
    server.stop();
}

var server: Server = undefined;

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    std.posix.sigaction(std.posix.SIG.TERM, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    var threaded: std.Io.Threaded = .init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    var router = try Router.init(allocator, &.{
        Route.init("/").get({}, base_handler).layer(),
    }, .{});
    defer router.deinit(allocator);

    const addr = try Io.net.IpAddress.parse(host, port);
    var s = try addr.listen(io, .{});
    defer s.deinit(io);

    server = try Server.init(allocator, .{
        .socket_buffer_bytes = 1024 * 2,
        .keepalive_count_max = null,
        .connection_count_max = 10,
    });
    defer server.deinit();
    try server.serve(io, &router, &s);
}
