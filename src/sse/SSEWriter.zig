const std = @import("std");
const Writer = std.Io.Writer;

writer: *Writer,
interface: Writer,
prefix: []const u8,
cont: bool,

const Self = @This();
const splat_buffer_size = 64;

pub fn init(writer: *Writer, buf: []u8, header: []const u8, dataprefix: []const u8) Writer.Error!Self {
    if (header.len > 0)
        try writer.print("{s}\n", .{header});
    return initInstance(writer, buf, dataprefix);
}

fn initInstance(writer: *Writer, buf: []u8, dataprefix: []const u8) Self {
    return .{
        .writer = writer,
        .prefix = dataprefix,
        .cont = false,
        .interface = .{
            .buffer = buf,
            .vtable = &.{
                .drain = Self.drain,
            },
        },
    };
}

pub fn end(self: *Self) Writer.Error!void {
    const w = &self.interface;
    try w.flush();
    if (self.cont) {
        try self.writer.writeAll("\n\n\n");
    } else {
        try self.writer.writeAll("\n\n");
    }
    try self.writer.flush();
}

fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
    const self: *@This() = @fieldParentPtr("interface", w);
    const buffered = w.buffered();
    var n: usize = 0;

    if (buffered.len > 0)
        n = try self.write(buffered);

    for (data[0 .. data.len - 1]) |d| {
        if (d.len == 0) continue;
        n += try self.write(d);
    }

    const pattern = data[data.len - 1];
    switch (splat) {
        0 => {},
        1 => {
            if (pattern.len > 0)
                n += try self.write(pattern);
        },
        else => switch (pattern.len) {
            0 => {},
            1 => {
                var splat_backup_buffer: [splat_buffer_size]u8 = undefined;
                const splat_buffer = &splat_backup_buffer;
                const memset_len = @min(splat_buffer.len, splat);
                const buf = splat_buffer[0..memset_len];
                @memset(buf, pattern[0]);
                n += try self.write(buf);
                var remaining_splat = splat - buf.len;
                while (remaining_splat > splat_buffer.len) {
                    std.debug.assert(buf.len == splat_buffer.len);
                    n += try self.write(splat_buffer);
                    remaining_splat -= splat_buffer.len;
                }
                n += try self.write(splat_buffer[0..@min(remaining_splat, splat_buffer.len)]);
            },
            else => for (0..splat) |_| {
                n += try self.write(pattern);
            },
        },
    }

    return w.consume(n);
}

fn write(self: *Self, data: []const u8) Writer.Error!usize {
    std.debug.assert(data.len > 0);
    const w = self.writer;
    var cont = self.cont;
    self.cont = (data[data.len - 1] != '\n');

    var d = data;
    if (std.mem.findScalar(u8, d, '\n')) |i| {
        if (cont) {
            try w.writeAll(d[0 .. i + 1]);
        } else {
            try w.print("{s} {s}", .{ self.prefix, d[0 .. i + 1] });
        }
        d = d[i + 1 ..];
        while (std.mem.findScalar(u8, d, '\n')) |j| : (d = d[j + 1 ..]) {
            try w.print("{s} {s}", .{ self.prefix, d[0 .. j + 1] });
        }
        cont = false;
    }

    if (d.len > 0) {
        if (cont) {
            try w.writeAll(d);
        } else {
            try w.print("{s} {s}", .{ self.prefix, d });
        }
    }

    return data.len;
}
