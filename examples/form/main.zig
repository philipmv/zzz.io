const std = @import("std");
const log = std.log.scoped(.@"examples/form");

const zzz = @import("zzz");
const http = zzz.HTTP;

const Io = std.Io;

const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Form = http.Form;
const Query = http.Query;
const Respond = http.Respond;

fn base_handler(ctx: *const Context, _: void) !Respond {
    const body =
        \\<form>
        \\    <label for="fname">First name:</label>
        \\    <input type="text" id="fname" name="fname"><br><br>
        \\    <label for="lname">Last name:</label>
        \\    <input type="text" id="lname" name="lname"><br><br>
        \\    <label for="age">Age:</label>
        \\    <input type="text" id="age" name="age"><br><br>
        \\    <label for="height">Height:</label>
        \\    <input type="text" id="height" name="height"><br><br>
        \\    <button formaction="/generate" formmethod="get">GET Submit</button>
        \\    <button formaction="/generate" formmethod="post">POST Submit</button>
        \\</form> 
    ;

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = body,
    });
}

const UserInfo = struct {
    fname: []const u8,
    mname: []const u8 = "Middle",
    lname: []const u8,
    age: u8,
    height: f32,
    weight: ?[]const u8,
};

fn generate_handler(ctx: *const Context, _: void) !Respond {
    const info = switch (ctx.request.method.?) {
        .GET => try Query(UserInfo).parse(ctx.allocator, ctx),
        .POST => try Form(UserInfo).parse(ctx.allocator, ctx),
        else => return error.UnexpectedMethod,
    };

    const body = try std.fmt.allocPrint(
        ctx.allocator,
        "First: {s} | Middle: {s} | Last: {s} | Age: {d} | Height: {d} | Weight: {s}",
        .{
            info.fname,
            info.mname,
            info.lname,
            info.age,
            info.height,
            info.weight orelse "none",
        },
    );

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.TEXT,
        .body = body,
    });
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var threaded: std.Io.Threaded = .init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    var router = try Router.init(allocator, &.{
        Route.init("/").get({}, base_handler).layer(),
        Route.init("/generate").get({}, generate_handler).post({}, generate_handler).layer(),
    }, .{});
    defer router.deinit(allocator);

    const addr = try Io.net.IpAddress.parse(host, port);
    var s = try addr.listen(io, .{});
    defer s.deinit(io);

    var server = try Server.init(allocator, .{
        .socket_buffer_bytes = 1024 * 2,
    });
    defer server.deinit();
    try server.serve(io, &router, &s);
}
