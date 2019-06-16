const std = @import("std");

// Force a load of a value. This is useful in particular to avoid branches being optimized
// out at compile-time for to force error-inference on otherwise empty error functions.
pub fn forceRuntime(comptime T: type, n: T) T {
    var p = @intToPtr(*volatile T, @ptrToInt(&n));
    return p.*;
}

pub fn BitSet(comptime T: type) type {
    inline for (@typeInfo(T).Enum.fields) |field| {
        std.debug.assert(@popCount(@TagType(T), field.value) == 1);
    }

    return struct {
        const Self = @This();
        pub const Type = @TagType(T);

        raw: Type,

        pub fn init() Self {
            return Self{ .raw = 0 };
        }

        pub fn initRaw(raw: Type) Self {
            return Self{ .raw = raw };
        }

        pub fn set(self: *Self, flag: T) void {
            self.raw |= @enumToInt(flag);
        }

        pub fn clear(self: *Self, flag: T) void {
            self.raw &= ~@enumToInt(flag);
        }

        pub fn get(self: Self, flag: T) bool {
            return self.raw & @enumToInt(flag) != 0;
        }

        pub fn count(self: Self) u8 {
            return @popCount(self.raw);
        }
    };
}

pub fn FixedQueue(comptime T: type, comptime max_length: usize) type {
    return struct {
        const Self = @This();

        head: usize,
        length: usize,
        buffer: [max_length]T,

        // Caller must call `insert` length times to seed with valid data.
        pub fn init(length: usize) Self {
            std.debug.assert(length <= max_length);

            return Self{
                .head = 0,
                .length = length,
                .buffer = undefined,
            };
        }

        pub fn insert(self: *Self, item: T) void {
            self.buffer[self.head] = item;
            self.head = (self.head + 1) % self.length;
        }

        pub fn take(self: *Self, next: T) T {
            const item = self.buffer[self.head];
            self.buffer[self.head] = next;
            self.head = (self.head + 1) % self.length;
            return item;
        }

        pub fn peek(self: Self, i: usize) T {
            return self.buffer[(self.head + i) % self.length];
        }
    };
}

// Simple fixed-point storage for a UQ8.24 type.
pub const uq8p24 = struct {
    inner: u32,

    pub fn init(w: u8, f: u24) uq8p24 {
        return uq8p24{ .inner = (@intCast(u32, w) << 24) | f };
    }

    pub fn initFraction(a: u32, b: u32) uq8p24 {
        return uq8p24{ .inner = @truncate(u32, (u64(a) << 24) / b) };
    }

    pub fn whole(self: uq8p24) u8 {
        return @intCast(u8, self.inner >> 24);
    }

    pub fn frac(self: uq8p24) u24 {
        return @truncate(u24, self.inner);
    }

    pub fn add(a: uq8p24, b: uq8p24) uq8p24 {
        // TODO: Handle overflow case.
        return uq8p24{ .inner = a.inner + b.inner };
    }
};
