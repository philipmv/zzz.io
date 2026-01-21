const std = @import("std");
const log = std.log.scoped(.@"examples/basic");

const zzz = @import("zzz");
const http = zzz.HTTP;
const template = zzz.template;

const Io = std.Io;

const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Respond = http.Respond;
const SSEWriter = http.SSEWriter;
const ChunkWriter = http.ChunkWriter;

fn base_handler(ctx: *const Context, _: void) !Respond {
    var res: std.Io.Writer.Allocating = .init(ctx.allocator);
    const writer = &res.writer;

    const html = comptime template.include(
        @embedFile("html/index.html"),
        "counter",
        @embedFile("html/counter.html"),
    );
    try template.print(writer, html, .{ .counter = 0 });

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = res.written(),
    });
}

fn writeCounter(w: *Io.Writer, cnt: u32) !void {
    const html = @embedFile("html/counter.html");
    try template.print(w, html, .{ .counter = cnt });
}

fn sendData(io: Io, w: *Io.Writer) !void {
    var buf: [128]u8 = undefined;
    var cw: ChunkWriter = .init(w, &buf);

    var ssebuf: [1024]u8 = undefined;
    var cnt: u32 = 0;

    while (cnt <= 10) : (cnt += 1) {
        var sse: SSEWriter = try .init(
            &cw.interface,
            &ssebuf,
            "event: datastar-patch-elements",
            "data: elements",
        );
        try writeCounter(&sse.interface, cnt);
        try sse.end();
        try io.sleep(.fromSeconds(1), .awake);
    }

    try cw.end();
}

fn counter_handler(ctx: *const Context, _: void) !Respond {
    var buf: [1024]u8 = undefined;
    var writer = ctx.stream.writer(ctx.io, &buf);
    const w = &writer.interface;

    try ctx.response.headers.put("Cache-Control", "no-cache");
    try ctx.response.headers.put("Transfer-Encoding", "chunked");
    ctx.response.status = .OK;
    ctx.response.mime = .SSE;
    try ctx.response.headers_into_writer(w, null);
    try w.flush();

    sendData(ctx.io, w) catch |err| {
        sw: switch (@as(anyerror, err)) {
            error.Canceled => return error.Canceled,
            error.WriteFailed => continue :sw writer.err.?,
            error.SocketUnconnected => return .close, // connection is closed
            else => |e| return e,
        }
    };

    return .responded;
}

fn shutdown(_: std.c.SIG) callconv(.c) void {
    server.stop();
}

var server: Server = undefined;

pub fn main(init: std.process.Init.Minimal) !void {
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

    var threaded: std.Io.Threaded = .init(allocator, .{ .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();

    var router = try Router.init(allocator, &.{
        Route.init("/").get({}, base_handler).layer(),
        Route.init("/counter").post({}, counter_handler).layer(),
    }, .{});
    defer router.deinit(allocator);

    const addr = try Io.net.IpAddress.parse(host, port);
    var s = try addr.listen(io, .{});
    defer s.deinit(io);

    server = try Server.init(allocator, io, .{
        .socket_buffer_bytes = 1024 * 2,
    });
    defer server.deinit();
    try server.serve(&router, &s);
}
