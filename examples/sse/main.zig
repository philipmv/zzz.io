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
const SSEWriter = http.SSEWriter;
const ChunkWriter = http.ChunkWriter;

fn base_handler(ctx: *const Context, _: void) !Respond {
    const body =
        \\ <!DOCTYPE html>
        \\ <html>
        \\ <head>
        \\ <script type="module" src="https://cdn.jsdelivr.net/gh/starfederation/datastar@1.0.0-RC.7/bundles/datastar.js"></script>
        \\ </head>
        \\ <body>
        \\ <div id="counter">0</div>
        \\ <button data-on:click="@post('counter')">Start</button>
        \\ </body>
        \\ </html>
    ;

    return try ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = body[0..],
    });
}

fn sendData(io: Io, w: *Io.Writer) !void {
    var buf: [128]u8 = undefined;
    var cw: ChunkWriter = .init(w, &buf);

    var ssebuf: [1024]u8 = undefined;
    var cnt: u32 = 0;

    const div =
        \\<div id="counter">
        \\{d}
        \\</div>
    ;

    while (cnt <= 10) : (cnt += 1) {
        var sse: SSEWriter = try .init(
            &cw.interface,
            &ssebuf,
            "event: datastar-patch-elements",
            "data: elements",
        );
        const ws = &sse.interface;
        try ws.print(div, .{cnt});
        try ws.flush();
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
        switch (err) {
            error.WriteFailed => {
                if (writer.err) |e| {
                    switch (e) {
                        error.SocketUnconnected => return .close, // connection is closed
                        else => |ee| return ee,
                    }
                }
            },
            else => {},
        }
        return err;
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
