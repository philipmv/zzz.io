const std = @import("std");
const log = std.log.scoped(.@"examples/middleware");

const zzz = @import("zzz");
const http = zzz.HTTP;

const Io = std.Io;

const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Next = http.Next;
const Respond = http.Respond;
const Middleware = http.Middleware;

fn root_handler(ctx: *const Context, id: i8) !Respond {
    const body_fmt =
        \\ <!DOCTYPE html>
        \\ <html>
        \\ <body>
        \\ <h1>Hello, World!</h1>
        \\ <p>id: {d}</p>
        \\ <p>stored: {d}</p>
        \\ </body>
        \\ </html>
    ;
    const body = try std.fmt.allocPrint(
        ctx.allocator,
        body_fmt,
        .{ id, ctx.storage.get(usize).? },
    );

    // This is the standard response and what you
    // will usually be using. This will send to the
    // client and then continue to await more requests.
    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = body[0..],
    });
}

fn passing_middleware(next: *Next, _: void) !Respond {
    log.info("pass middleware: {s}", .{next.context.request.uri.?});
    try next.context.storage.put(usize, 100);
    return try next.run();
}

fn failing_middleware(next: *Next, _: void) !Respond {
    log.info("fail middleware: {s}", .{next.context.request.uri.?});
    return error.FailingMiddleware;
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

    const num: i8 = 12;

    var router = try Router.init(allocator, &.{
        Middleware.init({}, passing_middleware).layer(),
        Route.init("/").get(num, root_handler).layer(),
        Middleware.init({}, failing_middleware).layer(),
        Route.init("/").post(num, root_handler).layer(),
        Route.init("/fail").get(num, root_handler).layer(),
    }, .{});
    defer router.deinit(allocator);

    const addr = try Io.net.IpAddress.parse(host, port);
    var s = try addr.listen(io, .{});
    defer s.deinit(io);

    server = try Server.init(allocator, .{});
    defer server.deinit();
    try server.serve(io, &router, &s);
}
