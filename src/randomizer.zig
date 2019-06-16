const std = @import("std");
const zs = @import("zstack.zig");

const Piece = zs.Piece;

/// We implement this specifically and don't use std.rand, since we want to be able to recreate
/// an exact piece sequence from a single seed. The implementation is small and it is easier to
/// just rely on a small one we write.
///
/// http://burtleburtle.net/bob/rand/smallprng.html
pub const Prng = struct {
    a: u32,
    b: u32,
    c: u32,
    d: u32,

    pub fn init(s: u32) Prng {
        var r: Prng = undefined;
        r.seed(s);
        return r;
    }

    pub fn seed(r: *Prng, s: u32) void {
        r.a = 0xF1EA5EED;
        r.b = s;
        r.c = s;
        r.d = s;

        var i: usize = 0;
        while (i < 20) : (i += 1) {
            _ = r.next();
        }
    }

    pub fn next(r: *Prng) u32 {
        const e = r.a -% std.math.rotl(u32, r.b, u32(27));
        r.a = r.b ^ std.math.rotl(u32, r.c, u32(17));
        r.b = r.c +% r.d;
        r.c = r.d +% e;
        r.d = e +% r.a;
        return r.d;
    }

    pub fn nextRange(r: *Prng, lo: u32, hi: u32) u32 {
        std.debug.assert(lo <= hi);

        const range = hi - lo;
        const rem = std.math.maxInt(u32) % range;

        var x: u32 = undefined;
        while (true) {
            x = r.next();
            if (x < std.math.maxInt(u32) - rem) {
                break;
            }
        }

        return lo + x % range;
    }

    pub fn shuffle(r: *Prng, comptime T: type, array: []T) void {
        if (array.len < 2) return;

        const len = @intCast(u32, array.len);
        var i: u32 = 0;
        while (i < len - 1) : (i += 1) {
            const j = r.nextRange(i, len);
            std.mem.swap(T, &array[j], &array[i]);
        }
    }
};

/// A Randomizer produces an infinite sequence of pieces. The method with which these pieces
/// are chosen differs between the randomizers, and they have different behavior during play.
pub const Randomizer = union(enum) {
    pub const Id = enum {
        memoryless,
        nes,
        tgm1,
        tgm2,
        tgm3,
        bag7,
        bag7seamcheck,
        bag6,
        multibag2,
        multibag4,
        multibag9,
    };

    Memoryless: MemorylessRandomizer,
    Nes: NesRandomizer,
    Bag: BagRandomizer,
    MultiBag: MultiBagRandomizer,
    Tgm4Bag: Tgm4BagRandomizer,
    Tgm35Bag: Tgm35BagRandomizer,

    pub fn init(id: Id, seed: u32) Randomizer {
        return switch (id) {
            .memoryless => Randomizer{ .Memoryless = MemorylessRandomizer.init(seed) },
            .nes => Randomizer{ .Nes = NesRandomizer.init(seed) },
            .tgm1 => Randomizer{ .Tgm4Bag = Tgm4BagRandomizer.init(seed, 4) },
            .tgm2 => Randomizer{ .Tgm4Bag = Tgm4BagRandomizer.init(seed, 6) },
            .tgm3 => Randomizer{ .Tgm35Bag = Tgm35BagRandomizer.init(seed) },
            .bag7 => Randomizer{ .Bag = BagRandomizer.init(seed, 7, false) },
            .bag7seamcheck => Randomizer{ .Bag = BagRandomizer.init(seed, 7, true) },
            .bag6 => Randomizer{ .Bag = BagRandomizer.init(seed, 6, false) },
            .multibag2 => Randomizer{ .MultiBag = MultiBagRandomizer.init(seed, 2) },
            .multibag4 => Randomizer{ .MultiBag = MultiBagRandomizer.init(seed, 4) },
            .multibag9 => Randomizer{ .MultiBag = MultiBagRandomizer.init(seed, 9) },
        };
    }

    /// Returns the underlying prng state used for a randomizer. Useful for reseeding an
    /// already existing randomizer.
    pub fn prng(self: *Randomizer) *Prng {
        // TODO: Could have a struct { prng, Randomizer } and pass the prng through to each
        // randomizer explicitly. Simplifies the seed process for each randomizer, although
        // complicates some other things.
        return switch (self.*) {
            .Memoryless => |*r| &r.prng,
            .Nes => |*r| &r.prng,
            .Bag => |*r| &r.prng,
            .MultiBag => |*r| &r.prng,
            .Tgm4Bag => |*r| &r.prng,
            .Tgm35Bag => |*r| &r.prng,
        };
    }

    /// Returns the next piece in the sequence.
    pub fn next(self: *Randomizer) Piece.Id {
        return switch (self.*) {
            .Memoryless => |*r| r.next(),
            .Nes => |*r| r.next(),
            .Bag => |*r| r.next(),
            .MultiBag => |*r| r.next(),
            .Tgm4Bag => |*r| r.next(),
            .Tgm35Bag => |*r| r.next(),
            else => unreachable,
        };
    }
};

/// Returns a random piece without any knowledge of the past previous pieces. This is very
/// susceptible to runs of the same piece and droughts, where an individual piece does not show
/// up for a long period.
pub const MemorylessRandomizer = struct {
    const Self = @This();

    prng: Prng,

    pub fn init(s: u32) Self {
        return Self{ .prng = Prng.init(s) };
    }

    pub fn next(self: *Self) Piece.Id {
        return Piece.Id.fromInt(self.prng.nextRange(0, Piece.Id.count));
    }
};

/// Keep a history of the last piece returned. Roll an 8-sided die. If the die lands on the last
/// piece or an 8, then roll a a 7-sided die and return the piece, else return the new piece.
pub const NesRandomizer = struct {
    const Self = @This();

    prng: Prng,
    history: Piece.Id,

    pub fn init(s: u32) Self {
        return Self{
            .prng = Prng.init(s),
            .history = .S, // be nicer
        };
    }

    pub fn next(self: *Self) Piece.Id {
        const roll = self.prng.nextRange(0, Piece.Id.count + 1);

        const b = blk: {
            if (roll == Piece.Id.count or Piece.Id.fromInt(roll) == self.history) {
                break :blk Piece.Id.fromInt(self.prng.nextRange(0, Piece.Id.count));
            } else {
                break :blk Piece.Id.fromInt(roll);
            }
        };

        self.history = b;
        return b;
    }
};

/// Put all pieces into a bag and shuffle. Take out pieces from the bag until we have pulled out
/// some N, where N < 7 (number of total pieces). Once N pieces have been removed, put all pieces
/// back into the bag and repeat.
///
/// Optionally, check the seam that occurs between reshuffles. If piece that is removed after
/// the bag has just been shuffled is the same as the last that was removed in the last bag, take
/// another piece from the bag and put this piece back.
pub const BagRandomizer = struct {
    const Self = @This();

    prng: Prng,
    bag: [Piece.Id.count]Piece.Id,
    index: usize,
    length: usize,
    check_seam: bool,

    pub fn init(s: u32, length: usize, check_seam: bool) Self {
        std.debug.assert(length <= Piece.Id.count);

        var r = Self{
            .prng = Prng.init(s),
            .bag = [_]Piece.Id{
                Piece.Id.I,
                Piece.Id.J,
                Piece.Id.L,
                Piece.Id.O,
                Piece.Id.S,
                Piece.Id.T,
                Piece.Id.Z,
            },
            .index = 0,
            .length = length,
            .check_seam = check_seam,
        };

        while (true) {
            r.prng.shuffle(Piece.Id, r.bag[0..]);
            switch (r.bag[0]) {
                .S, .Z, .O => {},
                else => break,
            }
        }

        return r;
    }

    pub fn next(self: *Self) Piece.Id {
        const b = self.bag[self.index];
        self.index += 1;

        if (self.index == self.length) {
            self.index = 0;
            self.prng.shuffle(Piece.Id, self.bag[0..]);

            // Duplicate across bag seams, swap the head with a random piece in the bag.
            if (self.check_seam and b == self.bag[0]) {
                const i = self.prng.nextRange(1, self.bag.len);
                std.mem.swap(Piece.Id, &self.bag[0], &self.bag[i]);
            }
        }

        return b;
    }
};

/// Similar to a Bag Randomizer but instead of our pool of pieces being 7 (1 of each), add
/// multiple numbers of each piece into a larger bag. e.g. 2, 3 of each piece into the same bag.
/// Shuffle the set of pieces and remove pieces until the bag is empty, then repeat.
pub const MultiBagRandomizer = struct {
    const max_bag_count = 9;
    const Self = @This();

    prng: Prng,
    bag: [max_bag_count * Piece.Id.count]Piece.Id,
    index: usize,
    bag_count: usize,

    pub fn init(s: u32, bag_count: usize) Self {
        std.debug.assert(bag_count <= max_bag_count);

        var r = Self{
            .prng = Prng.init(s),
            .bag = [_]Piece.Id{
                Piece.Id.I,
                Piece.Id.J,
                Piece.Id.L,
                Piece.Id.O,
                Piece.Id.S,
                Piece.Id.T,
                Piece.Id.Z,
            } ** max_bag_count,
            .index = 0,
            .bag_count = bag_count,
        };

        while (true) {
            r.prng.shuffle(Piece.Id, r.bag[0 .. r.bag_count * Piece.Id.count]);
            switch (r.bag[0]) {
                .S, .Z, .O => {},
                else => break,
            }
        }

        return r;
    }

    pub fn next(self: *Self) Piece.Id {
        const b = self.bag[self.index];
        self.index += 1;

        if (self.index == self.bag_count * Piece.Id.count) {
            self.index = 0;
            self.prng.shuffle(Piece.Id, self.bag[0 .. self.bag_count * Piece.Id.count]);
        }

        return b;
    }
};

/// An extension of the NES Randomizer. Keep a history of the last four pieces returned. Choose
/// a random piece. If this is in the history, reroll and pick another random piece, rolling up
/// to N times. If we exceed N rolls, return the piece, even if it is already in the history.
pub const Tgm4BagRandomizer = struct {
    const Self = @This();

    prng: Prng,
    index: usize,
    history: [4]Piece.Id,
    first_roll: bool,
    number_of_rolls: usize,

    pub fn init(s: u32, number_of_rolls: usize) Self {
        return Self{
            .prng = Prng.init(s),
            .index = 0,
            .history = [_]Piece.Id{ Piece.Id.Z, Piece.Id.Z, Piece.Id.Z, Piece.Id.Z },
            .first_roll = true,
            .number_of_rolls = number_of_rolls,
        };
    }

    pub fn initTgm2(s: u32, number_of_rolls: usize) Self {
        return Self{
            .prng = Prng.init(s),
            .index = 0,
            .history = [_]Piece.Id{ Piece.Id.Z, Piece.Id.S, Piece.Id.S, Piece.Id.Z },
            .first_roll = true,
            .number_of_rolls = number_of_rolls,
        };
    }

    pub fn next(self: *Self) Piece.Id {
        var b: Piece.Id = undefined;

        if (self.first_roll) {
            self.first_roll = false;
            b = ([_]Piece.Id{
                Piece.Id.J,
                Piece.Id.I,
                Piece.Id.L,
                Piece.Id.T,
            })[self.prng.nextRange(0, 4)];
        } else {
            var i: usize = 0;
            while (i < self.number_of_rolls) : (i += 1) {
                b = Piece.Id.fromInt(self.prng.nextRange(0, Piece.Id.count));

                if (b != self.history[0] and
                    b != self.history[1] and
                    b != self.history[2] and
                    b != self.history[3])
                {
                    break;
                }
            }
        }

        self.history[self.index] = b;
        self.index = (self.index + 1) & 3;
        return b;
    }
};

/// Similar to the Tgm Randomizer with added drought prevention features. The number of rerolls
/// is 6, the same as in TGM2.
///
/// Instead of choosing a random piece and rerolling, queue of 35 pieces (5 of each) is used. When
/// a piece is removed from the queue, the least recently seen is pushed to the back of the queue.
///
/// Also implements a small bug found in the original TGM3 code which results in the queue not
/// being updated correctly under certain conditions.
pub const Tgm35BagRandomizer = struct {
    const Self = @This();

    prng: Prng,
    index: usize,
    history: [4]Piece.Id,
    bag: [35]Piece.Id,
    drought_order: [Piece.Id.count]Piece.Id,
    seen_count_bug: u32,
    first_roll: bool,

    pub fn init(s: u32) Self {
        return Self{
            .prng = Prng.init(s),
            .index = 0,
            .history = [_]Piece.Id{ Piece.Id.S, Piece.Id.Z, Piece.Id.S, Piece.Id.Z },
            .bag = [_]Piece.Id{
                Piece.Id.I,
                Piece.Id.J,
                Piece.Id.L,
                Piece.Id.O,
                Piece.Id.S,
                Piece.Id.T,
                Piece.Id.Z,
            } ** 5,
            .drought_order = [_]Piece.Id{
                Piece.Id.J,
                Piece.Id.I,
                Piece.Id.Z,
                Piece.Id.L,
                Piece.Id.O,
                Piece.Id.T,
                Piece.Id.S,
            },
            .seen_count_bug = 0,
            .first_roll = true,
        };
    }

    pub fn next(self: *Self) Piece.Id {
        var b: Piece.Id = undefined;

        if (self.first_roll) {
            self.first_roll = false;
            b = ([_]Piece.Id{
                Piece.Id.J,
                Piece.Id.I,
                Piece.Id.L,
                Piece.Id.T,
            })[self.prng.nextRange(0, 4)];
        } else {
            var roll: usize = 0;
            var i: usize = 0;
            while (roll < 6) : (roll += 1) {
                i = self.prng.nextRange(0, 35);
                b = self.bag[i];

                if (b != self.history[0] and
                    b != self.history[1] and
                    b != self.history[2] and
                    b != self.history[3])
                {
                    break;
                }

                if (roll < 5) {
                    // Update bag to bias against current least-common piece
                    self.bag[i] = self.drought_order[0];
                }
            }

            self.seen_count_bug |= (u32(1) << @enumToInt(b));

            // The bag is not updated in the case that every piece has been seen.
            // A reroll occurs on the piece and we choose the most droughted piece.
            const bug = roll > 0 and
                b == self.drought_order[0] and
                self.seen_count_bug == ((1 << Piece.Id.count) - 1);
            if (!bug) {
                self.bag[i] = self.drought_order[0];
            }

            // Put current drought piece to back of drought queue
            for (self.drought_order[0..]) |d, j| {
                if (b == d) {
                    var k = j + 1;
                    while (k < Piece.Id.count) : (k += 1) {
                        self.drought_order[k - 1] = self.drought_order[k];
                    }
                    self.drought_order[Piece.Id.count - 1] = b;
                    break;
                }
            }
        }

        self.history[self.index] = b;
        self.index = (self.index + 1) & 3;
        return b;
    }
};
