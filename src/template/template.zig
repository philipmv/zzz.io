const std = @import("std");
const assert = std.debug.assert;
const meta = std.meta;
const indexOfPosLinear = std.mem.indexOfPosLinear;
const Writer = std.Io.Writer;

pub fn Iterator(comptime T: type) type {
    return struct {
        nextFn: *const fn (self: *@This()) ?T,
        pub fn next(self: *@This()) ?T {
            return self.nextFn(self);
        }
    };
}

pub fn print(writer: *Writer, comptime tmpl: []const u8, args: anytype) !void {
    const ArgsType = @TypeOf(args);
    const args_type_info: std.builtin.Type = @typeInfo(ArgsType);
    if (args_type_info != .@"struct") {
        @compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
    }
    const fields_info = args_type_info.@"struct".fields;

    @setEvalBranchQuota(4000);
    comptime var i = 0;
    inline while (i < tmpl.len) {
        const start_index = i;

        comptime var brace = false;
        inline while (i < tmpl.len) : (i += 1) {
            switch (tmpl[i]) {
                '{', '}' => {
                    if (brace and tmpl[i] == tmpl[i - 1]) break;
                    brace = true;
                },
                else => brace = false,
            }
        }

        const end_index = if (brace) i - 1 else i;

        if (start_index != end_index) {
            try writer.writeAll(tmpl[start_index..end_index]);
        }

        if (i >= tmpl.len) break;

        if (tmpl[i] == '}') {
            @compileError("missing opening {{");
        }

        // Get past the {
        comptime assert(tmpl[i] == '{');
        i += 1;

        const fmt_begin = i;

        // Find the closing brace
        brace = false;
        inline while (i < tmpl.len) : (i += 1) {
            if (tmpl[i] == '}') {
                if (brace and tmpl[i] == tmpl[i - 1]) break;
                brace = true;
            } else brace = false;
        }
        if (i >= tmpl.len) {
            @compileError("missing closing }}");
        }

        comptime assert(tmpl[i] == '}');
        const fmt_end = i - 1;
        // Get past the }
        i += 1;

        if (tmpl[fmt_begin] == '#') {
            const name = tmpl[fmt_begin + 1 .. fmt_end];
            const end_tag = "{{/" ++ name ++ "}}";

            const pos = comptime std.mem.indexOfPosLinear(u8, tmpl, i, end_tag);
            if (pos == null) @compileError("missing closing tag '" ++ end_tag ++ "'");

            const field_pos = meta.fieldIndex(ArgsType, name) orelse
                @compileError("no field with name '" ++ name ++ "'");
            const value = @field(args, fields_info[field_pos].name);
            const value_type = if (meta.fieldIndex(ArgsType, name ++ "_type")) |type_pos| @field(args, fields_info[type_pos].name) else void;
            const t = tmpl[i .. pos.? + 1];

            switch (@TypeOf(value)) {
                std.SinglyLinkedList, std.DoublyLinkedList => {
                    var node = value.first;
                    while (node) |n| : (node = n.next) {
                        const v: *value_type = @fieldParentPtr("node", n);
                        try print(writer, t, v.*);
                    }
                },
                *Iterator(value_type) => {
                    while (value.next()) |v| try print(writer, t, v);
                },
                else => |typ| switch (@typeInfo(typ)) {
                    .pointer, .array => for (value) |v| {
                        try print(writer, t, v);
                    },
                    else => @compileError("not an indexable field with name '" ++ name ++ "'"),
                },
            }
            // Go past end tag
            i = pos.? + end_tag.len;
        } else {
            const name = tmpl[fmt_begin..fmt_end];
            const pos = meta.fieldIndex(ArgsType, name) orelse
                @compileError("no field with name '" ++ name ++ "'");

            const value = @field(args, fields_info[pos].name);
            switch (@typeInfo(@TypeOf(value))) {
                .pointer, .array => try writer.print("{s}", .{value}),
                .int, .float => try writer.print("{d}", .{value}),
                .@"enum" => try writer.print("{s}", .{@tagName(value)}),
                else => try writer.print("{f}", .{value}),
            }
        }
    }
}

pub fn include(comptime tmpl: []const u8, comptime tag: []const u8, comptime content: []const u8) []const u8 {
    @setEvalBranchQuota(20000);
    const sec = "<!--#" ++ tag ++ "-->";
    const start = comptime indexOfPosLinear(u8, tmpl, 0, sec);
    if (start == null) @compileError("missing tag " ++ sec);
    const end = start.? + sec.len;
    return tmpl[0..start.?] ++ content ++ tmpl[end..];
}
