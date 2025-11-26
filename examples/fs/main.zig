const std = @import("std");
const log = std.log.scoped(.@"examples/fs");

const zzz = @import("zzz");
const http = zzz.HTTP;

const Io = std.Io;

const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Respond = http.Respond;
const FsDir = http.FsDir;

const Compression = http.Middlewares.Compression;

fn base_handler(ctx: *const Context, _: void) !Respond {
    const body =
        \\ <!DOCTYPE html>
        \\ <html>
        \\ <body>
        \\ <h1>Hello, World!</h1>
        \\ </body>
        \\ </html>
    ;

    return try ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = body[0..],
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

    const static_dir = try std.Io.Dir.cwd().openDir(io, "examples/fs/static", .{});

    var router = try Router.init(allocator, &.{
        Compression(.{ .gzip = .default }),
        Route.init("/").get({}, base_handler).layer(),
        FsDir.serve("/", &static_dir),
    }, .{});
    defer router.deinit(allocator);

    const addr = try Io.net.IpAddress.parse(host, port);
    var s = try addr.listen(io, .{});
    defer s.deinit(io);

    server = try Server.init(allocator, .{
        .socket_buffer_bytes = 1024 * 4,
    });
    defer server.deinit();
    try server.serve(io, &router, &s);
}
