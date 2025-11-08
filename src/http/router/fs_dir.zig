const std = @import("std");
const log = std.log.scoped(.@"zzz/http/router");
const assert = std.debug.assert;

const Route = @import("route.zig").Route;
const Layer = @import("middleware.zig").Layer;
const Request = @import("../request.zig").Request;
const Respond = @import("../response.zig").Respond;
const Mime = @import("../mime.zig").Mime;
const Context = @import("../context.zig").Context;

const Io = std.Io;
const Dir = std.Io.Dir;

pub const FsDir = struct {
    fn fs_dir_handler(ctx: *const Context, dir: *const Dir) !Respond {
        if (ctx.captures.len == 0) return ctx.response.apply(.{
            .status = .@"Not Found",
            .mime = Mime.HTML,
        });

        const response = ctx.response;

        // Resolving the requested file.
        const search_path = ctx.captures[0].remaining;
        const file_path_z = try ctx.allocator.dupeZ(u8, search_path);

        // TODO: check that the path is valid.

        const extension_start = std.mem.lastIndexOfScalar(u8, search_path, '.');
        const mime: Mime = blk: {
            if (extension_start) |start| {
                if (search_path.len - start == 0) break :blk Mime.BIN;
                break :blk Mime.from_extension(search_path[start + 1 ..]);
            } else {
                break :blk Mime.BIN;
            }
        };

        const file = dir.openFile(ctx.io, file_path_z, .{ .mode = .read_only }) catch |e| switch (e) {
            error.FileNotFound => {
                return ctx.response.apply(.{
                    .status = .@"Not Found",
                    .mime = Mime.HTML,
                });
            },
            else => return e,
        };
        const stat = try file.stat(ctx.io);

        var hash = std.hash.Wyhash.init(0);
        hash.update(std.mem.asBytes(&stat.size));
        hash.update(std.mem.asBytes(&stat.mtime.toSeconds()));
        const etag_hash = hash.final();

        const calc_etag = try std.fmt.allocPrint(ctx.allocator, "\"{d}\"", .{etag_hash});
        try response.headers.put("ETag", calc_etag);

        // If we have an ETag on the request...
        if (ctx.request.headers.get("If-None-Match")) |etag| {
            if (std.mem.eql(u8, etag, calc_etag)) {
                // If the ETag matches.
                return ctx.response.apply(.{
                    .status = .@"Not Modified",
                    .mime = Mime.HTML,
                });
            }
        }

        // apply the fields.
        response.status = .OK;
        response.mime = mime;

        var bufw: [1024]u8 = undefined;
        var writer = ctx.stream.writer(ctx.io, &bufw);
        const w = &writer.interface;

        try response.headers_into_writer(w, stat.size);

        var bufr: [1024]u8 = undefined;
        var reader = file.reader(ctx.io, &bufr);
        _ = try w.sendFileAll(&reader, .unlimited);
        try w.flush();

        return .responded;
    }

    /// Serve a Filesystem Directory as a Layer.
    pub fn serve(comptime url_path: []const u8, dir: *const Dir) Layer {
        const url_with_match_all = comptime std.fmt.comptimePrint(
            "{s}/%r",
            .{std.mem.trimRight(u8, url_path, "/")},
        );

        return Route.init(url_with_match_all).get(dir, fs_dir_handler).layer();
    }
};
