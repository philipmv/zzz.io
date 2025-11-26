const std = @import("std");
const builtin = @import("builtin");
const tag = builtin.os.tag;
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/http/server");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Stream = Io.net.Stream;

const TypedStorage = @import("../core/typed_storage.zig").TypedStorage;
const AnyCaseStringMap = @import("../core/any_case_string_map.zig").AnyCaseStringMap;

const Context = @import("context.zig").Context;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Respond = @import("response.zig").Respond;
const Capture = @import("router/routing_trie.zig").Capture;

const Mime = @import("mime.zig").Mime;
const Router = @import("router.zig").Router;
const Route = @import("router/route.zig").Route;
const Layer = @import("router/middleware.zig").Layer;
const Middleware = @import("router/middleware.zig").Middleware;
const HTTPError = @import("lib.zig").HTTPError;

const HandlerWithData = @import("router/route.zig").HandlerWithData;

const Next = @import("router/middleware.zig").Next;

const Pool = @import("../core/pool.zig").Pool;
const ZeroCopy = @import("../core/zerocopy.zig").ZeroCopy;

/// These are various general configuration
/// options that are important for the actual framework.
///
/// This includes various different options and limits
/// for interacting with the underlying network.
pub const ServerConfig = struct {
    /// Number of Maximum Concurrent Connections.
    ///
    /// This is applied PER runtime.
    /// zzz will drop/close any connections greater
    /// than this.
    ///
    /// You can set this to `null` to have no maximum.
    ///
    /// Default: `null`
    connection_count_max: ?u32 = null,
    /// Number of times a Request-Response can happen with keep-alive.
    ///
    /// Setting this to `null` will set no limit.
    ///
    /// Default: `null`
    keepalive_count_max: ?u16 = null,
    /// Amount of allocated memory retained
    /// after an arena is cleared.
    ///
    /// A higher value will increase memory usage but
    /// should make allocators faster.
    ///
    /// A lower value will reduce memory usage but
    /// will make allocators slower.
    ///
    /// Default: 1KB
    connection_arena_bytes_retain: u32 = 1024,
    /// Amount of space on the `recv_buffer` retained
    /// after every send.
    ///
    /// Default: 1KB
    list_recv_bytes_retain: u32 = 1024,
    /// Maximum size (in bytes) of the Recv buffer.
    /// This is mainly a concern when you are reading in
    /// large requests before responding.
    ///
    /// Default: 2MB
    list_recv_bytes_max: u32 = 1024 * 1024 * 2,
    /// Size of the buffer (in bytes) used for
    /// interacting with the socket.
    ///
    /// Default: 1 KB
    socket_buffer_bytes: u32 = 1024,
    /// Maximum number of Captures in a Route
    ///
    /// Default: 8
    capture_count_max: u16 = 8,
    /// Maximum size (in bytes) of the Request.
    ///
    /// Default: 2MB
    request_bytes_max: u32 = 1024 * 1024 * 2,
    /// Maximum size (in bytes) of the Request URI.
    ///
    /// Default: 2KB
    request_uri_bytes_max: u32 = 1024 * 2,
};

pub const Provision = struct {
    initalized: bool = false,
    recv_slice: []u8,
    zc_recv_buffer: ZeroCopy(u8),
    arena: std.heap.ArenaAllocator,
    storage: TypedStorage,
    captures: []Capture,
    queries: AnyCaseStringMap,
    request: Request,
    response: Response,
};

pub const Server = struct {
    const Self = @This();
    config: ServerConfig,
    provision_pool: *Pool(Provision),
    connection_count: *usize,
    allocator: std.mem.Allocator,
    stop_event: [2]std.posix.fd_t,

    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) !Self {
        const count = config.connection_count_max orelse 1024;

        const provision_pool = try allocator.create(Pool(Provision));
        provision_pool.* = try Pool(Provision).init(allocator, count);
        errdefer allocator.destroy(provision_pool);

        const connection_count = try allocator.create(usize);
        errdefer allocator.destroy(connection_count);
        connection_count.* = 0;

        // initialize first batch of provisions :)
        for (provision_pool.items) |*provision| {
            provision.initalized = true;
            provision.zc_recv_buffer = ZeroCopy(u8).init(
                allocator,
                config.socket_buffer_bytes,
            ) catch {
                @panic("attempting to allocate more memory than available. (ZeroCopy)");
            };
            provision.arena = std.heap.ArenaAllocator.init(allocator);
            provision.captures = allocator.alloc(Capture, config.capture_count_max) catch {
                @panic("attempting to allocate more memory than available. (Captures)");
            };
            provision.queries = AnyCaseStringMap.init(allocator);
            provision.storage = TypedStorage.init(allocator);
            provision.request = Request.init(allocator);
            provision.response = Response.init(allocator);
        }
        return Self{ .config = config, .provision_pool = provision_pool, .connection_count = connection_count, .allocator = allocator, .stop_event = try std.posix.pipe() };
    }

    pub fn deinit(self: *const Self) void {
        self.allocator.destroy(self.connection_count);
        for (self.provision_pool.items) |*provision| {
            provision.zc_recv_buffer.deinit();
            provision.arena.deinit();
            self.allocator.free(provision.captures);
            provision.queries.deinit();
            provision.storage.deinit();
            provision.request.deinit();
            provision.response.deinit();
        }
        self.provision_pool.deinit();
        self.allocator.destroy(self.provision_pool);
        std.posix.close(self.stop_event[0]);
        std.posix.close(self.stop_event[1]);
    }

    pub fn stop(self: *const Self) void {
        _ = std.posix.write(self.stop_event[1], std.mem.asBytes(&@as(u64, 1))) catch {};
    }

    const RequestBodyState = struct {
        content_length: usize,
        current_length: usize,
    };

    const RequestState = union(enum) {
        header,
        body: RequestBodyState,
    };

    const State = union(enum) {
        request: RequestState,
        handler,
        respond,
    };

    fn prepare_new_request(state: ?*State, provision: *Provision, config: ServerConfig) void {
        assert(provision.initalized);
        provision.request.clear();
        provision.response.clear();
        provision.storage.clear();
        provision.zc_recv_buffer.clear_retaining_capacity();
        _ = provision.arena.reset(.{ .retain_with_limit = config.connection_arena_bytes_retain });
        provision.recv_slice = provision.zc_recv_buffer.get_write_area_assume_space(config.socket_buffer_bytes);

        if (state) |s| s.* = .{ .request = .header };
    }

    fn doWork(
        allocator: Allocator,
        io: Io,
        config: ServerConfig,
        router: *const Router,
        stream: Stream,
        provisions: *Pool(Provision),
        connection_count: *usize,
    ) void {
        _ = @atomicRmw(usize, connection_count, .Add, 1, .acq_rel);
        defer _ = @atomicRmw(usize, connection_count, .Sub, 1, .acq_rel);

        defer stream.close(io);

        const index = provisions.borrow(io) catch {
            log.err("Provision pool is full", .{});
            return;
        };
        defer provisions.release(io, index);
        const provision = provisions.get_ptr(index);
        defer prepare_new_request(null, provision, config);

        std.debug.assert(provision.initalized);

        var state: State = .{ .request = .header };
        provision.recv_slice = provision.zc_recv_buffer.get_write_area_assume_space(config.socket_buffer_bytes);

        var keepalive_count: u16 = 0;

        var bufr: [1024]u8 = undefined;
        var reader = stream.reader(io, &bufr);
        const r = &reader.interface;

        var bufw: [1024]u8 = undefined;
        var writer = stream.writer(io, &bufw);
        const w = &writer.interface;

        const res = http_loop: while (true) switch (state) {
            .request => |*kind| switch (kind.*) {
                .header => {
                    var vecs: [1][]u8 = .{provision.recv_slice};
                    const recv_count = r.readVec(&vecs) catch |e| switch (e) {
                        error.EndOfStream => break, // Closed
                        else => break :http_loop e,
                    };

                    provision.zc_recv_buffer.mark_written(recv_count);
                    provision.recv_slice = provision.zc_recv_buffer.get_write_area(config.socket_buffer_bytes) catch |e| break :http_loop e;
                    if (provision.zc_recv_buffer.len > config.request_bytes_max) break;
                    const search_area_start = (provision.zc_recv_buffer.len - recv_count) -| 4;

                    if (std.mem.indexOf(
                        u8,
                        // Minimize the search area.
                        provision.zc_recv_buffer.subslice(.{ .start = search_area_start }),
                        "\r\n\r\n",
                    )) |header_end| {
                        const real_header_end = header_end + 4;
                        provision.request.parse_headers(
                            // Add 4 to account for the actual header end sequence.
                            provision.zc_recv_buffer.subslice(.{ .end = real_header_end }),
                            .{
                                .request_bytes_max = config.request_bytes_max,
                                .request_uri_bytes_max = config.request_uri_bytes_max,
                            },
                        ) catch |e| break :http_loop e;

                        log.info("req{d} - \"{s} {s}\" {s} ({any})", .{
                            index,
                            @tagName(provision.request.method.?),
                            provision.request.uri.?,
                            provision.request.headers.get("User-Agent") orelse "N/A",
                            stream.socket.address,
                        });

                        const content_length_str = provision.request.headers.get("Content-Length") orelse "0";
                        const content_length = std.fmt.parseUnsigned(usize, content_length_str, 10) catch |e|
                            break :http_loop e;
                        log.debug("content length={d}", .{content_length});

                        if (provision.request.expect_body() and content_length != 0) {
                            state = .{
                                .request = .{
                                    .body = .{
                                        .current_length = provision.zc_recv_buffer.len - real_header_end,
                                        .content_length = content_length,
                                    },
                                },
                            };
                        } else state = .handler;
                    }
                },
                .body => |*info| {
                    if (info.current_length == info.content_length) {
                        provision.request.body = provision.zc_recv_buffer.subslice(
                            .{ .start = provision.zc_recv_buffer.len - info.content_length },
                        );
                        state = .handler;
                        continue;
                    }

                    var vecs: [1][]u8 = .{provision.recv_slice};
                    const recv_count = r.readVec(&vecs) catch |e| switch (e) {
                        error.EndOfStream => break, // Closed
                        else => break :http_loop e,
                    };

                    provision.zc_recv_buffer.mark_written(recv_count);
                    provision.recv_slice = provision.zc_recv_buffer.get_write_area(config.socket_buffer_bytes) catch |e| break :http_loop e;
                    if (provision.zc_recv_buffer.len > config.request_bytes_max) break;

                    info.current_length += recv_count;
                    assert(info.current_length <= info.content_length);
                },
            },
            .handler => {
                const found = router.get_bundle_from_host(
                    allocator,
                    provision.request.uri.?,
                    provision.captures,
                    &provision.queries,
                ) catch |e| break :http_loop e;
                defer allocator.free(found.duped);
                defer for (found.duped) |dupe| allocator.free(dupe);

                const h_with_data: HandlerWithData = found.route.get_handler(
                    provision.request.method.?,
                ) orelse {
                    provision.response.headers.clearRetainingCapacity();
                    provision.response.status = .@"Method Not Allowed";
                    provision.response.mime = Mime.TEXT;
                    provision.response.body = "";

                    state = .respond;
                    continue;
                };

                const context: Context = .{
                    .io = io,
                    .allocator = provision.arena.allocator(),
                    .request = &provision.request,
                    .response = &provision.response,
                    .storage = &provision.storage,
                    .stream = stream,
                    .captures = found.captures,
                    .queries = found.queries,
                };

                var next: Next = .{
                    .context = &context,
                    .middlewares = h_with_data.middlewares,
                    .handler = h_with_data,
                };

                const next_respond: Respond = next.run() catch |e| blk: {
                    log.warn("req{d} - \"{s} {s}\" {} ({any})", .{
                        index,
                        @tagName(provision.request.method.?),
                        provision.request.uri.?,
                        e,
                        stream.socket.address,
                    });

                    // If in Debug Mode, we will return the error name. In other modes,
                    // we won't to avoid leaking implemenation details.
                    const body = if (comptime builtin.mode == .Debug) @errorName(e) else "";

                    break :blk provision.response.apply(.{
                        .status = .@"Internal Server Error",
                        .mime = Mime.TEXT,
                        .body = body,
                    }) catch |err| break :http_loop err;
                };

                switch (next_respond) {
                    .standard => {
                        // applies the respond onto the response
                        //try provision.response.apply(respond);
                        state = .respond;
                    },
                    .responded => {
                        const connection = provision.request.headers.get("Connection") orelse "keep-alive";
                        if (std.mem.eql(u8, connection, "close")) break :http_loop;
                        if (config.keepalive_count_max) |max| {
                            if (keepalive_count > max) {
                                log.warn("closing connection, exceeded keepalive max", .{});
                                break :http_loop;
                            }

                            keepalive_count += 1;
                        }

                        prepare_new_request(&state, provision, config);
                    },
                    .close => break :http_loop,
                }
            },
            .respond => {
                const body = provision.response.body orelse "";
                const content_length = body.len;

                provision.response.headers_into_writer(w, content_length) catch |e| break :http_loop e;
                w.writeAll(body) catch |e| break :http_loop e;
                w.flush() catch |e| break :http_loop e;

                const connection = provision.request.headers.get("Connection") orelse "keep-alive";
                if (std.mem.eql(u8, connection, "close")) break;
                if (config.keepalive_count_max) |max| {
                    if (keepalive_count > max) {
                        log.warn("closing connection, exceeded keepalive max", .{});
                        break;
                    }

                    keepalive_count += 1;
                }

                prepare_new_request(&state, provision, config);
            },
        };

        res catch |e| {
            log.err("{}", .{e});
        };
    }

    /// Serve an HTTP server.
    pub fn serve(self: *Self, io: Io, router: *const Router, server: *Io.net.Server) !void {
        var group: Io.Group = .init;
        defer group.cancel(io);

        var e = io.async(stopEvent, .{ io, .{ .handle = self.stop_event[0] } });
        defer e.cancel(io);

        while (true) {
            var s = io.async(Io.net.Server.accept, .{ server, io });
            defer _ = s.cancel(io) catch {};

            switch (try io.select(.{ .e = &e, .s = &s })) {
                .e => break,
                .s => |stream| {
                    if (self.config.connection_count_max) |max| if (@atomicLoad(usize, self.connection_count, .acquire) > max) {
                        log.warn("over connection max, closing", .{});
                        (try stream).close(io);
                        continue;
                    };

                    log.debug("queuing up a new accept request", .{});

                    group.async(io, doWork, .{ self.allocator, io, self.config, router, try stream, self.provision_pool, self.connection_count });
                },
            }
        }
    }
};

fn stopEvent(io: Io, event: Io.File) void {
    var buf: [8]u8 = undefined;
    var reader = event.reader(io, &buf);
    const r = &reader.interface;
    var cnt: u64 = undefined;
    r.readSliceAll(std.mem.asBytes(&cnt)) catch unreachable;
}
