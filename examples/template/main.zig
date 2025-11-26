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

fn base_handler(ctx: *const Context, _: void) !Respond {
    var res: std.Io.Writer.Allocating = .init(ctx.allocator);
    const writer = &res.writer;

    try template.print(writer, @embedFile("html/index.html"), .{ .title = "HTML template demo!" });

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = res.written(),
    });
}

const Person = struct {
    name: []const u8,
    age: u8,
    node: std.SinglyLinkedList.Node = .{},
};

fn array_handler(ctx: *const Context, _: void) !Respond {
    var res: std.Io.Writer.Allocating = .init(ctx.allocator);
    const writer = &res.writer;

    const persons: [3]Person = .{ .{ .name = "John", .age = 30 }, .{ .name = "Peter", .age = 38 }, .{ .name = "Maria", .age = 20 } };

    const html = comptime template.include(
        @embedFile("html/index.html"),
        "content",
        @embedFile("html/content.html"),
    );
    try template.print(writer, html, .{ .title = "HTML template 'Array'!", .persons = persons });

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = res.written(),
    });
}

fn list_handler(ctx: *const Context, _: void) !Respond {
    var res: std.Io.Writer.Allocating = .init(ctx.allocator);
    const writer = &res.writer;

    var persons: [3]Person = .{ .{ .name = "John", .age = 30 }, .{ .name = "Peter", .age = 38 }, .{ .name = "Maria", .age = 20 } };

    var persons_list: std.SinglyLinkedList = .{ .first = &persons[0].node };
    persons_list.first.?.next = &persons[1].node;
    persons_list.first.?.next.?.next = &persons[2].node;

    const html = comptime template.include(
        @embedFile("html/index.html"),
        "content",
        @embedFile("html/content.html"),
    );
    try template.print(writer, html, .{ .title = "HTML template 'Linked list'!", .persons = persons_list, .persons_type = Person });

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = res.written(),
    });
}

fn iterator_handler(ctx: *const Context, _: void) !Respond {
    var res: std.Io.Writer.Allocating = .init(ctx.allocator);
    const writer = &res.writer;

    const persons: [3]Person = .{ .{ .name = "John", .age = 30 }, .{ .name = "Peter", .age = 38 }, .{ .name = "Maria", .age = 20 } };

    const Iter = struct {
        index: usize,
        inner: []const Person,
        iterator: template.Iterator(Person),
        pub fn next(iterator: *template.Iterator(Person)) ?Person {
            const self: *@This() = @fieldParentPtr("iterator", iterator);
            if (self.index < self.inner.len) {
                defer self.index += 1;
                return self.inner[self.index];
            }
            return null;
        }
        pub fn init(inner: []const Person) @This() {
            return .{ .index = 0, .inner = inner, .iterator = .{ .nextFn = next } };
        }
    };
    var iter: Iter = .init(&persons);

    const html = comptime template.include(
        @embedFile("html/index.html"),
        "content",
        @embedFile("html/content.html"),
    );
    try template.print(writer, html, .{ .title = "HTML template 'Iterator'!", .persons = &iter.iterator, .persons_type = Person });

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = res.written(),
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
        Route.init("/array").get({}, array_handler).layer(),
        Route.init("/list").get({}, list_handler).layer(),
        Route.init("/iterator").get({}, iterator_handler).layer(),
    }, .{});
    defer router.deinit(allocator);

    const addr = try Io.net.IpAddress.parse(host, port);
    var s = try addr.listen(io, .{});
    defer s.deinit(io);

    server = try Server.init(allocator, .{
        .socket_buffer_bytes = 1024 * 2,
    });
    defer server.deinit();
    try server.serve(io, &router, &s);
}
