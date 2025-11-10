const std = @import("std");

const Respond = @import("../response.zig").Respond;
const Middleware = @import("../router/middleware.zig").Middleware;
const Next = @import("../router/middleware.zig").Next;
const Layer = @import("../router/middleware.zig").Layer;
const TypedMiddlewareFn = @import("../router/middleware.zig").TypedMiddlewareFn;

const Kind = union(enum) {
    gzip: std.compress.flate.Compress.Options,
};

/// Compression Middleware.
///
/// Provides a Compression Layer for all routes under this that
/// will properly compress the body and add the proper `Content-Encoding` header.
pub fn Compression(comptime compression: Kind) Layer {
    const func: TypedMiddlewareFn(void) = switch (compression) {
        .gzip => |inner| struct {
            fn gzip_mw(next: *Next, _: void) !Respond {
                const respond = try next.run();
                const response = next.context.response;
                if (response.body) |body| if (respond == .standard) {
                    var compressed: std.Io.Writer.Allocating = try .initCapacity(next.context.allocator, @max(body.len, 64));
                    errdefer compressed.deinit();

                    var buf: [std.compress.flate.max_window_len]u8 = undefined;
                    var compress: std.compress.flate.Compress = try .init(&compressed.writer, &buf, .gzip, inner);
                    var writer = &compress.writer;
                    try writer.writeAll(body);
                    try writer.flush();

                    try response.headers.put("Content-Encoding", "gzip");
                    response.body = compressed.written();
                    return .standard;
                };

                return respond;
            }
        }.gzip_mw,
    };

    return Middleware.init({}, func).layer();
}
