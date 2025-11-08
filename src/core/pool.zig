const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const Io = std.Io;

pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        // Buffer for the Pool.
        items: []T,
        dirty: std.DynamicBitSetUnmanaged,
        mutex: std.Io.Mutex,

        /// Initalizes our items buffer as undefined.
        pub fn init(allocator: std.mem.Allocator, size: usize) std.mem.Allocator.Error!Self {
            return .{
                .allocator = allocator,
                .items = try allocator.alloc(T, size),
                .dirty = try .initEmpty(allocator, size),
                .mutex = .init,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
            self.dirty.deinit(self.allocator);
        }

        /// Deinitalizes our items buffer with a passed in hook.
        pub fn deinit_with_hook(
            self: *Self,
            args: anytype,
            deinit_hook: ?*const fn (buffer: []T, args: @TypeOf(args)) void,
        ) void {
            if (deinit_hook) |hook| {
                @call(.auto, hook, .{ self.items, args });
            }

            self.allocator.free(self.items);
            self.dirty.deinit(self.allocator);
        }

        pub fn get(self: *const Self, index: usize) T {
            assert(index < self.items.len);
            return self.items[index];
        }

        pub fn get_ptr(self: *const Self, index: usize) *T {
            assert(index < self.items.len);
            return &self.items[index];
        }

        /// Is this empty?
        pub fn empty(self: *const Self, io: Io) bool {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            return self.dirty.count() == 0;
        }

        /// Is this full?
        pub fn full(self: *const Self, io: Io) bool {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            return self.dirty.count() == self.list.len;
        }

        /// Returns the number of clean (or available) slots.
        pub fn clean(self: *const Self, io: Io) usize {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            return self.items.len - self.dirty.count();
        }

        /// Linearly probes for an available slot in the pool.
        /// If dynamic, this *might* grow the Pool.
        ///
        /// Returns the index into the Pool.
        pub fn borrow(self: *Self, io: Io) error{Full}!usize {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            var iter = self.dirty.iterator(.{ .kind = .unset });
            const index = iter.next() orelse return error.Full;
            self.dirty.set(index);
            return index;
        }

        /// Linearly probes for an available slot in the pool.
        /// Uses a provided hint value as the starting index.
        ///
        /// Returns the index into the Pool.
        pub fn borrow_hint(self: *Self, io: Io, hint: usize) error{Full}!usize {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            const length = self.items.len;
            for (0..length) |i| {
                const index = @mod(hint + i, length);
                if (!self.dirty.isSet(index)) {
                    self.dirty.set(index);
                    return index;
                }
            }

            return error.Full;
        }

        /// Attempts to borrow at the given index.
        /// Asserts that it is an available slot.
        /// This will never grow the Pool.
        pub fn borrow_assume_unset(self: *Self, io: Io, index: usize) usize {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            assert(!self.dirty.isSet(index));
            self.dirty.set(index);
            return index;
        }

        /// Releases the item with the given index back to the Pool.
        /// Asserts that the given index was borrowed.
        pub fn release(self: *Self, io: Io, index: usize) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            assert(self.dirty.isSet(index));
            self.dirty.unset(index);
        }
    };
}

test "Pool: Initalization (integer)" {
    const io = std.testing.io;
    var byte_pool: Pool(u8) = try .init(testing.allocator, 1024);
    defer byte_pool.deinit();

    for (0..1024) |i| {
        const index = try byte_pool.borrow_hint(io, i);
        const byte_ptr = byte_pool.get_ptr(index);
        byte_ptr.* = 2;
    }

    for (byte_pool.items) |item| {
        try testing.expectEqual(item, 2);
    }
}

test "Pool: Initalization & Deinit (ArrayList)" {
    // const io = std.testing.io;
    var list_pool: Pool(std.ArrayList(u8)) = try .init(testing.allocator, 256);
    defer list_pool.deinit();

    for (list_pool.items, 0..) |*item, i| {
        item.* = .empty;
        try item.appendNTimes(testing.allocator, 0, i);
    }

    for (list_pool.items, 0..) |item, i| {
        try testing.expectEqual(item.items.len, i);
    }

    for (list_pool.items) |*item| {
        item.deinit(testing.allocator);
    }
}

test "Pool: BufferPool ([][]u8)" {
    var buffer_pool: Pool([1024]u8) = try .init(testing.allocator, 1024);
    defer buffer_pool.deinit();

    for (buffer_pool.items) |*item| {
        std.mem.copyForwards(u8, item, "ABCDEF");
    }

    for (buffer_pool.items) |item| {
        try testing.expectEqualStrings("ABCDEF", item[0..6]);
    }
}

test "Pool: Borrowing" {
    const io = std.testing.io;
    var byte_pool: Pool(u8) = try .init(testing.allocator, 1024);
    defer byte_pool.deinit();

    for (0..byte_pool.items.len) |_| {
        _ = try byte_pool.borrow(io);
    }

    // Expect a Full.
    try testing.expectError(error.Full, byte_pool.borrow(io));

    for (0..byte_pool.items.len) |i| {
        byte_pool.release(io, i);
    }
}

test "Pool: Borrowing Hint" {
    const io = std.testing.io;
    var byte_pool: Pool(u8) = try .init(testing.allocator, 1024);
    defer byte_pool.deinit();

    for (0..byte_pool.items.len) |i| {
        _ = try byte_pool.borrow_hint(io, i);
    }

    for (0..byte_pool.items.len) |i| {
        byte_pool.release(io, i);
    }
}

test "Pool: Borrowing Unset" {
    const io = std.testing.io;
    var byte_pool: Pool(u8) = try .init(testing.allocator, 1024);
    defer byte_pool.deinit();

    for (0..byte_pool.items.len) |i| {
        _ = byte_pool.borrow_assume_unset(io, i);
    }

    for (0..byte_pool.items.len) |i| {
        byte_pool.release(io, i);
    }
}
