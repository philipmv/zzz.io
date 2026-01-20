const std = @import("std");
const Writer = std.Io.Writer;

writer: *Writer,
interface: Writer,

const Self = @This();

/// chunk size is <= buf.len
pub fn init(writer: *Writer, buf: []u8) Self {
    return .{
        .writer = writer,
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
    try self.writer.writeAll("0\r\n\r\n");
    try self.writer.flush();
}

fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
    const header = w.buffered();
    const n = try write(w, header, data, splat);
    return w.consume(n);
}

fn write(w: *Writer, header: []const u8, data: []const []const u8, splat: usize) Writer.Error!usize {
    const self: *@This() = @fieldParentPtr("interface", w);
    if (header.len != 0) {
        return self.writeChunk(header);
    }
    for (data[0 .. data.len - 1]) |buf| {
        if (buf.len == 0) continue;
        return self.writeChunk(buf);
    }
    const pattern = data[data.len - 1];
    if (pattern.len == 0 or splat == 0) return 0;
    return self.writeChunk(pattern);
}

fn writeChunk(self: *Self, data: []const u8) Writer.Error!usize {
    std.debug.assert(data.len > 0);
    const w = self.writer;

    const len = @min(self.interface.buffer.len, data.len);
    try w.print("{x}\r\n{s}\r\n", .{ len, data[0..len] });
    try w.flush();

    return len;
}
