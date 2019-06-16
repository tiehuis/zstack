const std = @import("std");
const zs = @import("zstack.zig");

const Timer = std.os.time.Timer;
const Randomizer = zs.Randomizer;
const Piece = zs.Piece;

// See this thread for some useful reading:
//  https://tetrisconcept.net/threads/randomizer-theory.512/
//
// Variances
// ---------
//
// Memoryless: 42
// 63-bag: 34 + 82/275 = 34.29818181...
// NES (ideal): 32 + 2/3 = 32.66666666...
// Cultris II (sample): ~27.65
// 28-bag: 27 + 13/25 = 27.52
// 4 history 2 roll: ~20.56697
// 14-bag: 19
// 5-bag: 18
// 10-bag: 16 + 32/35 = 16.91428571...
// 7 from 8: 15 + 82/175 = 15.46857142...
// 1+7: 12 + 13/14 = 12.92857142...
// 6-bag: 12 + 5/6 = 12.83333333...
// 3 history strict: 12
// 8-bag: 11 + 43/56 = 11.76785714...
// 4 history 4 roll (TGM1): 10.13757557...
// 7-bag: 8
// 7-bag with seam match check: 7.5
// 4 history 6 roll (TGM2): 7.34494156...
// 4 history strict: 6
// TGM3 (sample): ~5.31
const variance = struct {
    const memoryless = 42;
    const nes = 32.6666;
    const bag6 = 12.8333;
    const bag7 = 8;
    const bag7seamcheck = 7.5;
    const multibag2 = 19;
    const multibag4 = 27.52;
    const multibag9 = 34.29819;
    const tgm1 = 10.13757557;
    const tgm2 = 7.34494156;
    const tgm3 = 5.31;
};

fn testDistribution(r: *Randomizer, target_variance: f64) !void {
    const limit = 1000000;

    // Reseed randomizer with random seed.
    var buf: [4]u8 = undefined;
    try std.os.getRandomBytes(buf[0..]);
    const s = std.mem.readIntSliceLittle(u32, buf[0..]);
    r.prng().seed(s);

    var seen = []u64{0} ** Piece.Id.count;
    var last_seen = []u64{0} ** Piece.Id.count;

    var variance_sum: u64 = 0;
    var variance_sum_sq: u64 = 0;

    var timer = try Timer.start();
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        const p = @enumToInt(r.next());
        const x = i - last_seen[p];

        variance_sum += x;
        variance_sum_sq += x * x;

        seen[p] += 1;
        last_seen[p] = i;
    }

    // NOTE: This does include some overhead from the arithmetic above, but this is the same for
    // each randomizer tested.
    const elapsed = timer.read();
    std.debug.warn("\n = {} ns per call\n", elapsed / limit);

    std.debug.warn(" = Distribution\n");
    var j: usize = 0;
    while (j < Piece.Id.count) : (j += 1) {
        const weight = @intToFloat(f64, seen[j]) * 100 / limit;
        std.debug.warn("    {} - {.3}%\n", @tagName(@intToEnum(Piece.Id, @intCast(u3, j))), weight);
    }

    const actual_variance = @intToFloat(f64, variance_sum_sq - (variance_sum * variance_sum) / limit) / (limit - 1);
    std.debug.warn(" = Variance\n");
    std.debug.warn("    target = {.3}\n", target_variance);
    std.debug.warn("    actual = {.3}\n", actual_variance);
}

var seed: u32 = 0;

test "variance.memoryless" {
    var r = Randomizer.init(.memoryless, seed);
    try testDistribution(&r, variance.memoryless);
}

test "variance.nes" {
    var r = Randomizer.init(.nes, seed);
    try testDistribution(&r, variance.nes);
}

test "variance.bag7" {
    var r = Randomizer.init(.bag7, seed);
    try testDistribution(&r, variance.bag7);
}

test "variance.bag7seamcheck" {
    var r = Randomizer.init(.bag7seamcheck, seed);
    try testDistribution(&r, variance.bag7seamcheck);
}

test "variance.bag6" {
    var r = Randomizer.init(.bag6, seed);
    try testDistribution(&r, variance.bag6);
}

test "variance.multibag2" {
    var r = Randomizer.init(.multibag2, seed);
    try testDistribution(&r, variance.multibag2);
}

test "variance.multibag4" {
    var r = Randomizer.init(.multibag4, seed);
    try testDistribution(&r, variance.multibag4);
}

test "variance.multibag9" {
    var r = Randomizer.init(.multibag9, seed);
    try testDistribution(&r, variance.multibag9);
}

test "variance.tgm1" {
    var r = Randomizer.init(.tgm1, seed);
    try testDistribution(&r, variance.tgm1);
}

test "variance.tgm2" {
    var r = Randomizer.init(.tgm2, seed);
    try testDistribution(&r, variance.tgm2);
}

test "variance.tgm3" {
    var r = Randomizer.init(.tgm3, seed);
    try testDistribution(&r, variance.tgm3);
}
