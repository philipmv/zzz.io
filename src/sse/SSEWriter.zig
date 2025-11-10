const std = @import("std");
const Writer = std.Io.Writer;

writer: *Writer,
interface: Writer,
data: []const u8,
cont: bool,

const Self = @This();

pub fn init(writer: *Writer, buf: []u8, event: []const u8, data: []const u8) Writer.Error!Self {
    try writer.print("{s}\n", .{event});
    return initInstance(writer, buf, data);
}

fn initInstance(writer: *Writer, buf: []u8, data: []const u8) Self {
    return .{
        .writer = writer,
        .data = data,
        .cont = false,
        .interface = .{
            .buffer = buf,
            .vtable = &.{
                .drain = Self.drain,
                .flush = Self.flush,
            },
        },
    };
}

pub fn flush(w: *Writer) Writer.Error!void {
    const self: *@This() = @fieldParentPtr("interface", w);
    try w.defaultFlush();
    if (self.cont)
        try self.writer.writeByte('\n');
    try self.writer.writeAll("\n\n");
}

fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
    const self: *@This() = @fieldParentPtr("interface", w);
    const buffered = w.buffered();
    var n: usize = 0;
    if (buffered.len > 0)
        n = try self.writeAll(buffered);
    for (data[0 .. data.len - 1]) |d| {
        if (d.len == 0) continue;
        n += try self.writeAll(d);
    }
    const pattern = data[data.len - 1];
    if (splat > 0 and pattern.len > 0) {
        for (0..splat) |_| {
            n += try self.writeAll(pattern);
        }
    }
    return w.consume(n);
}

fn writeAll(self: *Self, data: []const u8) Writer.Error!usize {
    std.debug.assert(data.len > 0);
    const w = self.writer;
    const cont = self.cont;
    self.cont = (data[data.len - 1] != '\n');

    var it = std.mem.splitScalar(u8, data, '\n');

    if (cont) {
        try w.writeAll(it.first());
    } else {
        try w.print("{s} {s}", .{ self.data, it.first() });
    }

    while (it.next()) |s| {
        try w.writeByte('\n');
        if (it.peek() == null and s.len == 0) break;
        try w.print("{s} {s}", .{ self.data, s });
    }

    return data.len;
}
