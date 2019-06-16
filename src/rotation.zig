const std = @import("std");
const zs = @import("zstack.zig");

const Coord = zs.Coord;
const Piece = zs.Piece;
const Engine = zs.Engine;

/// Represents a relative rotation that can be applied to a piece.
pub const Rotation = enum(i8) {
    Clockwise = 1,
    AntiClockwise = -1,
    Half = 2,
};

const Wallkick = Coord(i8);
fn wk(comptime x: comptime_int, comptime y: comptime_int) Wallkick {
    return Wallkick{ .x = x, .y = y };
}

/// A RotationSystem details the set of blocks that make up each piece per rotation. And, the
/// wallkicks that are applied when a rotation is performed on a piece.
pub const RotationSystem = struct {
    id: Id,

    pub const Id = enum {
        srs,
        sega,
        dtet,
        nes,
        ars,
        tgm,
        tgm3,
    };

    pub fn init(id: Id) RotationSystem {
        return RotationSystem{ .id = id };
    }

    /// Returns the set of blocks for a piece in the RotationSystem at a given theta.
    /// These are always 0-offset, so the caller needs to add any x,y offsets if required.
    pub fn blocks(self: RotationSystem, id: Piece.Id, theta: Piece.Theta) Piece.Blocks {
        return switch (self.id) {
            .srs => SrsRotationSystem.blocks(id, theta),
            .sega => SegaRotationSystem.blocks(id, theta),
            .dtet => DtetRotationSystem.blocks(id, theta),
            .nes => NintendoRotationSystem.blocks(id, theta),
            .ars => ArikaSrsRotationSystem.blocks(id, theta),
            .tgm => TgmRotationSystem.blocks(id, theta),
            .tgm3 => Tgm3RotationSystem.blocks(id, theta),
        };
    }

    /// Attempts to rotation a piece in its current position in the well, applying any number
    /// of wallkicks as needed. If successful, true is returned and the pieces position is
    /// modified to match.
    pub fn rotate(self: RotationSystem, engine: Engine, piece: *Piece, rotation: Rotation) bool {
        return switch (self.id) {
            .srs => SrsRotationSystem.rotate(engine, piece, rotation),
            .sega => SegaRotationSystem.rotate(engine, piece, rotation),
            .dtet => DtetRotationSystem.rotate(engine, piece, rotation),
            .nes => NintendoRotationSystem.rotate(engine, piece, rotation),
            .ars => ArikaSrsRotationSystem.rotate(engine, piece, rotation),
            .tgm => TgmRotationSystem.rotate(engine, piece, rotation),
            .tgm3 => Tgm3RotationSystem.rotate(engine, piece, rotation),
        };
    }
};

/// Parse an offset specification, defining how a piece is to be rotated in a given system.
fn parseOffsetSpec(
    comptime spec: [Piece.Id.count][]const u8,
) [Piece.Id.count][Piece.Theta.count]Piece.Blocks {
    var result: [Piece.Id.count][Piece.Theta.count]Piece.Blocks = undefined;

    @setEvalBranchQuota(5000);

    for (spec) |piece_spec, id| {
        const line_length = 20;

        var offset: usize = 0;
        var rotation: usize = 0;
        while (rotation < Piece.Theta.count) : ({
            rotation += 1;
            offset += 5;
        }) {
            var x: usize = 0;
            var i: usize = 0;
            while (x < 4) : (x += 1) {
                var y: usize = 0;
                while (y < 4) : (y += 1) {
                    switch (piece_spec[offset + y * line_length + x]) {
                        '@' => {
                            result[id][rotation][i] = Coord(u8){
                                .x = x,
                                .y = y,
                            };
                            i += 1;
                        },
                        '.' => {},
                        else => unreachable,
                    }
                }
            }

            std.debug.assert(i == 4);
        }
    }

    return result;
}

fn rotateWithWallkicks(engine: Engine, piece: *Piece, rotation: Rotation, kicks: []const Wallkick) bool {
    const new_theta = piece.theta.rotate(rotation);

    for (kicks) |kick| {
        if (!engine.isCollision(piece.id, piece.x + kick.x, piece.y + kick.y, new_theta)) {
            // A floorkick is indicated by a negative y-movement wallkick. If we exceed
            // our floorkick limit then immediately request a lock on this frame by setting the
            // lock_timer to exceed the lock delay.
            piece.handleFloorkick(engine, kick.y < 0);
            piece.move(engine, piece.x + kick.x, piece.y + kick.y, new_theta);
            return true;
        }
    }

    return false;
}

const no_wallkicks = [_]Wallkick{wk(0, 0)};

/// Super Rotation System. Current Tetris Guideline standard.
/// https://tetris.wiki/SRS.
pub const SrsRotationSystem = struct {
    // TODO: ziglang/zig:#2456.
    const offsets = parseOffsetSpec([_][]const u8{
        \\.... ..@. .... .@..
        \\@@@@ ..@. .... .@..
        \\.... ..@. @@@@ .@..
        \\.... ..@. .... .@..
    ,
        \\@... .@@. .... .@..
        \\@@@. .@.. @@@. .@..
        \\.... .@.. ..@. @@..
        \\.... .... .... ....
    ,
        \\..@. .@.. .... @@..
        \\@@@. .@.. @@@. .@..
        \\.... .@@. @... .@..
        \\.... .... .... ....
    ,
        \\.@@. .@@. .@@. .@@.
        \\.@@. .@@. .@@. .@@.
        \\.... .... .... ....
        \\.... .... .... ....
    ,
        \\.@@. .@.. .... @...
        \\@@.. .@@. .@@. @@..
        \\.... ..@. @@.. .@..
        \\.... .... .... ....
    ,
        \\.@.. .@.. .... .@..
        \\@@@. .@@. @@@. @@..
        \\.... .@.. .@.. .@..
        \\.... .... .... ....
    ,
        \\@@.. ..@. .... .@..
        \\.@@. .@@. @@.. @@..
        \\.... .@.. .@@. @...
        \\.... .... .... ....
    });

    const jlstz_wallkicks_clockwise = [4][5]Wallkick{
        // 0 -> R
        [_]Wallkick{ wk(0, 0), wk(-1, 0), wk(-1, 1), wk(0, -2), wk(-1, -2) },
        // R -> 2
        [_]Wallkick{ wk(0, 0), wk(1, 0), wk(1, -1), wk(0, 2), wk(1, 2) },
        // 2 -> L
        [_]Wallkick{ wk(0, 0), wk(1, 0), wk(1, 1), wk(0, -2), wk(1, -2) },
        // L -> 0
        [_]Wallkick{ wk(0, 0), wk(-1, 0), wk(-1, -1), wk(0, 2), wk(-1, 2) },
    };

    const jlstz_wallkicks_anticlockwise = [4][5]Wallkick{
        // 0 -> L
        [_]Wallkick{ wk(0, 0), wk(1, 0), wk(1, 1), wk(0, -2), wk(1, -2) },
        // L -> 2
        [_]Wallkick{ wk(0, 0), wk(-1, 0), wk(-1, -1), wk(0, 2), wk(-1, 2) },
        // 2 -> R
        [_]Wallkick{ wk(0, 0), wk(-1, 0), wk(-1, 1), wk(0, -2), wk(-1, -2) },
        // R -> 0
        [_]Wallkick{ wk(0, 0), wk(1, 0), wk(1, -1), wk(0, 2), wk(1, 2) },
    };

    const i_wallkicks_clockwise = [4][5]Wallkick{
        // 0 -> R
        [_]Wallkick{ wk(0, 0), wk(-2, 0), wk(1, 0), wk(-2, -1), wk(1, 2) },
        // R -> 2
        [_]Wallkick{ wk(0, 0), wk(-1, 0), wk(2, 0), wk(-1, 2), wk(2, -1) },
        // 2 -> L
        [_]Wallkick{ wk(0, 0), wk(2, 0), wk(-1, 0), wk(2, 1), wk(-1, -2) },
        // L -> 0
        [_]Wallkick{ wk(0, 0), wk(1, 0), wk(-2, 0), wk(1, -2), wk(-2, 1) },
    };

    const i_wallkicks_anticlockwise = [4][5]Wallkick{
        // 0 -> L
        [_]Wallkick{ wk(0, 0), wk(-1, 0), wk(2, 0), wk(-1, 2), wk(2, -1) },
        // L -> 2
        [_]Wallkick{ wk(0, 0), wk(-2, 0), wk(1, 0), wk(-2, -1), wk(1, 2) },
        // 2 -> R
        [_]Wallkick{ wk(0, 0), wk(1, 0), wk(-2, 0), wk(1, -2), wk(-2, 1) },
        // R -> 0
        [_]Wallkick{ wk(0, 0), wk(2, 0), wk(-1, 0), wk(2, 1), wk(-1, -2) },
    };

    pub fn blocks(id: Piece.Id, theta: Piece.Theta) Piece.Blocks {
        return offsets[@enumToInt(id)][@enumToInt(theta)];
    }

    pub fn rotate(engine: Engine, piece: *Piece, rotation: Rotation) bool {
        const wallkicks = switch (rotation) {
            .Clockwise => (if (piece.id == .I) i_wallkicks_clockwise else jlstz_wallkicks_clockwise)[@enumToInt(piece.theta)],
            .AntiClockwise => (if (piece.id == .I) i_wallkicks_anticlockwise else jlstz_wallkicks_anticlockwise)[@enumToInt(piece.theta)],
            .Half => no_wallkicks,
        };

        return rotateWithWallkicks(engine, piece, rotation, wallkicks);
    }
};

/// As found on the Sega arcade version of Tetris.
/// https://tetris.wiki/Sega_Rotation
pub const SegaRotationSystem = struct {
    const offsets = parseOffsetSpec([_][]const u8{
        \\.... ..@. .... ..@.
        \\@@@@ ..@. @@@@ ..@.
        \\.... ..@. .... ..@.
        \\.... ..@. .... ..@.
    ,
        \\.... .@.. .... .@@.
        \\@@@. .@.. @... .@..
        \\..@. @@.. @@@. .@..
        \\.... .... .... ....
    ,
        \\.... @@.. .... .@..
        \\@@@. .@.. ..@. .@..
        \\@... .@.. @@@. .@@.
        \\.... .... .... ....
    ,
        \\.... .... .... ....
        \\.@@. .@@. .@@. .@@.
        \\.@@. .@@. .@@. .@@.
        \\.... .... .... ....
    ,
        \\.... @... .... @...
        \\.@@. @@.. .@@. @@..
        \\@@.. .@.. @@.. .@..
        \\.... .... .... ....
    ,
        \\.... .@.. .... .@..
        \\@@@. @@.. .@.. .@@.
        \\.@.. .@.. @@@. .@..
        \\.... .... .... ....
    ,
        \\.... ..@. .... ..@.
        \\@@.. .@@. @@.. .@@.
        \\.@@. .@.. .@@. .@..
        \\.... .... .... ....
    });

    pub fn blocks(id: Piece.Id, theta: Piece.Theta) Piece.Blocks {
        return offsets[@enumToInt(id)][@enumToInt(theta)];
    }

    pub fn rotate(engine: Engine, piece: *Piece, rotation: Rotation) bool {
        return rotateWithWallkicks(engine, piece, rotation, no_wallkicks);
    }
};

/// As found on the original NES tetris games. Right-handed I variant.
/// https://tetris.wiki/Nintendo_Rotation_System
pub const NintendoRotationSystem = struct {
    const offsets = parseOffsetSpec([_][]const u8{
        \\.... ..@. .... ..@.
        \\.... ..@. .... ..@.
        \\@@@@ ..@. @@@@ ..@.
        \\.... ..@. .... ..@.
    ,
        \\.... .@.. @... .@@.
        \\@@@. .@.. @@@. .@..
        \\..@. @@.. .... .@..
        \\.... .... .... ....
    ,
        \\.... @@.. ..@. .@..
        \\@@@. .@.. @@@. .@..
        \\@... .@.. .... .@@.
        \\.... .... .... ....
    ,
        \\.... .... .... ....
        \\.@@. .@@. .@@. .@@.
        \\.@@. .@@. .@@. .@@.
        \\.... .... .... ....
    ,
        \\.... .@.. .... .@..
        \\.@@. .@@. .@@. .@@.
        \\@@.. ..@. @@.. ..@.
        \\.... .... .... ....
    ,
        \\.... .@.. .@.. .@..
        \\@@@. @@.. @@@. .@@.
        \\.@.. .@.. .... .@..
        \\.... .... .... ....
    ,
        \\.... ..@. .... ..@.
        \\@@.. .@@. @@.. .@@.
        \\.@@. .@.. .@@. .@..
        \\.... .... .... ....
    });

    pub fn blocks(id: Piece.Id, theta: Piece.Theta) Piece.Blocks {
        return offsets[@enumToInt(id)][@enumToInt(theta)];
    }

    pub fn rotate(engine: Engine, piece: *Piece, rotation: Rotation) bool {
        return rotateWithWallkicks(engine, piece, rotation, no_wallkicks);
    }
};

/// Used in the fan-game DTET. Similar to Sega Rotation with a few changes and symmetric wallkicks.
/// https://tetris.wiki/DTET_Rotation_System
pub const DtetRotationSystem = struct {
    const offsets = parseOffsetSpec([_][]const u8{
        \\.... .@.. .... .@..
        \\.... .@.. .... .@..
        \\@@@@ .@.. @@@@ .@..
        \\.... .@.. .... .@..
    ,
        \\.... .@.. .... .@@.
        \\@@@. .@.. @... .@..
        \\..@. @@.. @@@. .@..
        \\.... .... .... ....
    ,
        \\.... @@.. .... .@..
        \\@@@. .@.. ..@. .@..
        \\@... .@.. @@@. .@@.
        \\.... .... .... ....
    ,
        \\.... .... .... ....
        \\.@@. .@@. .@@. .@@.
        \\.@@. .@@. .@@. .@@.
        \\.... .... .... ....
    ,
        \\.... .@.. .... @...
        \\.@@. .@@. .@@. @@..
        \\@@.. ..@. @@.. .@..
        \\.... .... .... ....
    ,
        \\.... .@.. .... .@..
        \\@@@. @@.. .@.. .@@.
        \\.@.. .@.. @@@. .@..
        \\.... .... .... ....
    ,
        \\.... ..@. .... .@..
        \\@@.. .@@. @@.. @@..
        \\.@@. .@.. .@@. @...
        \\.... .... .... ....
    });

    const clockwise_wallkicks = [_]Wallkick{
        wk(0, 0), wk(1, 0), wk(-1, 0), wk(0, 1), wk(1, 1), wk(-1, 1),
    };

    const anticlockwise_wallkicks = [_]Wallkick{
        wk(0, 0), wk(-1, 0), wk(1, 0), wk(0, 1), wk(-1, 1), wk(1, 1),
    };

    pub fn blocks(id: Piece.Id, theta: Piece.Theta) Piece.Blocks {
        return offsets[@enumToInt(id)][@enumToInt(theta)];
    }

    pub fn rotate(engine: Engine, piece: *Piece, rotation: Rotation) bool {
        const wallkicks = switch (rotation) {
            .Clockwise => clockwise_wallkicks,
            .AntiClockwise => anticlockwise_wallkicks,
            .Half => no_wallkicks,
        };

        return rotateWithWallkicks(engine, piece, rotation, wallkicks);
    }
};

/// Arika SRS as implemented in TGM3 and TGM:Ace. This is listed in TGM under 'World Rule'.
/// Uses the same offsets/kick-data as SRS, except for a modified I wallkick.
/// https://tetris.wiki/SRS#Arika_SRS.
pub const ArikaSrsRotationSystem = struct {
    const i_wallkicks_clockwise = [4][5]Wallkick{
        // 0 -> R
        [_]Wallkick{ wk(0, 0), wk(-2, 0), wk(1, 0), wk(1, 2), wk(-2, 1) },
        // R -> 2
        [_]Wallkick{ wk(0, 0), wk(-1, 0), wk(2, 0), wk(-1, 2), wk(2, -1) },
        // 2 -> L
        [_]Wallkick{ wk(0, 0), wk(2, 0), wk(-1, 0), wk(2, 1), wk(-1, -1) },
        // L -> 0
        [_]Wallkick{ wk(0, 0), wk(-2, 0), wk(1, 0), wk(-2, 1), wk(1, -2) },
    };

    const i_wallkicks_anticlockwise = [4][5]Wallkick{
        // 0 -> L
        [_]Wallkick{ wk(0, 0), wk(2, 0), wk(-1, 0), wk(-1, 2), wk(2, -1) },
        // L -> 2
        [_]Wallkick{ wk(0, 0), wk(1, 0), wk(-2, 0), wk(1, 2), wk(-2, -1) },
        // 2 -> R
        [_]Wallkick{ wk(0, 0), wk(-2, 0), wk(1, 0), wk(-2, 1), wk(1, -1) },
        // R -> 0
        [_]Wallkick{ wk(0, 0), wk(2, 0), wk(-1, 0), wk(2, 1), wk(-1, -2) },
    };

    pub fn blocks(id: Piece.Id, theta: Piece.Theta) Piece.Blocks {
        return SrsRotationSystem.offsets[@enumToInt(id)][@enumToInt(theta)];
    }

    pub fn rotate(engine: Engine, piece: *Piece, rotation: Rotation) bool {
        const kicks = switch (rotation) {
            .Clockwise => (if (piece.id == .I) i_wallkicks_clockwise else SrsRotationSystem.jlstz_wallkicks_clockwise)[@enumToInt(piece.theta)],
            .AntiClockwise => (if (piece.id == .I) i_wallkicks_anticlockwise else SrsRotationSystem.jlstz_wallkicks_anticlockwise)[@enumToInt(piece.theta)],
            .Half => no_wallkicks,
        };

        return rotateWithWallkicks(engine, piece, rotation, kicks);
    }
};

/// As found in TGM1 and TGM2. Similar to Sega Rotation with a few changes and wallkicks.
/// https://tetris.wiki/TGM_Rotation
pub const TgmRotationSystem = struct {
    const offsets = parseOffsetSpec([_][]const u8{
        \\.... ..@. .... ..@.
        \\@@@@ ..@. @@@@ ..@.
        \\.... ..@. .... ..@.
        \\.... ..@. .... ..@.
    ,
        \\.... .@.. .... .@@.
        \\@@@. .@.. @... .@..
        \\..@. @@.. @@@. .@..
        \\.... .... .... ....
    ,
        \\.... @@.. .... .@..
        \\@@@. .@.. ..@. .@..
        \\@... .@.. @@@. .@@.
        \\.... .... .... ....
    ,
        \\.... .... .... ....
        \\.@@. .@@. .@@. .@@.
        \\.@@. .@@. .@@. .@@.
        \\.... .... .... ....
    ,
        \\.... @... .... @...
        \\.@@. @@.. .@@. @@..
        \\@@.. .@.. @@.. .@..
        \\.... .... .... ....
    ,
        \\.... .@.. .... .@..
        \\@@@. .@@. @@@. @@..
        \\.@.. .@.. .@.. .@..
        \\.... .... .... ....
    ,
        \\.... .@.. .... .@..
        \\@@.. @@.. @@.. @@..
        \\.@@. @... .@@. @...
        \\.... .... .... ....
    });

    const wallkicks = [_]Wallkick{
        wk(0, 0), wk(1, 0), wk(-1, 1),
    };

    const i_wallkicks = [_]Wallkick{wk(0, 0)};

    pub fn blocks(id: Piece.Id, theta: Piece.Theta) Piece.Blocks {
        return offsets[@enumToInt(id)][@enumToInt(theta)];
    }

    // Wallkicks will not occur if a block fills the x slot AND a block does not fill
    // the `c` spot when rotating clockwise, or `a` when rotating anti-clockwise.
    fn wallkickException(engine: Engine, piece: Piece, rotation: Rotation) bool {
        switch (piece.id) {
            .L => {
                // c     x
                // @@@  @@@
                // @x   @
                if (piece.theta == .R0) {
                    if (engine.well[piece.uy() + 2][piece.ux() + 1] != null and
                        !(rotation == .Clockwise and engine.well[piece.uy()][piece.ux()] != null))
                    {
                        return true;
                    }
                    if (engine.well[piece.uy()][piece.ux() + 1] != null) {
                        return true;
                    }
                }
                //  x   a
                //   @   x@
                // @@@  @@@
                else if (piece.theta == .R180) {
                    if (engine.well[piece.uy()][piece.ux() + 1] != null) {
                        return true;
                    }
                    if (engine.well[piece.uy() + 1][piece.ux() + 1] != null and
                        !(rotation == .AntiClockwise and engine.well[piece.uy()][piece.ux()] != null))
                    {
                        return true;
                    }
                }
            },
            .J => {
                //   a   x
                // @@@  @@@
                //  x@    @
                if (piece.theta == .R0) {
                    if (engine.well[piece.uy() + 2][piece.ux() + 1] != null and
                        !(rotation == .AntiClockwise and engine.well[piece.uy()][piece.ux() + 2] != null))
                    {
                        return true;
                    }
                    if (engine.well[piece.uy()][piece.ux() + 1] != null) {
                        return true;
                    }
                }
                //  x     c
                // @    @x
                // @@@  @@@
                else if (piece.theta == .R180) {
                    if (engine.well[piece.uy()][piece.ux() + 1] != null) {
                        return true;
                    }
                    if (engine.well[piece.uy() + 1][piece.ux() + 1] != null and
                        !(rotation == .Clockwise and engine.well[piece.uy()][piece.ux() + 2] != null))
                    {
                        return true;
                    }
                }
            },
            .T => {
                //  x    x
                //  @   @@@
                // @@@   @
                if ((piece.theta == .R0 or piece.theta == .R180) and
                    engine.well[piece.uy()][piece.ux() + 1] != null)
                {
                    return false;
                }
            },
            else => {},
        }

        return false;
    }

    pub fn rotate(engine: Engine, piece: *Piece, rotation: Rotation) bool {
        const new_theta = piece.theta.rotate(rotation);

        const kicks = switch (rotation) {
            .Clockwise, .AntiClockwise => if (piece.id == .I) i_wallkicks else wallkicks,
            .Half => no_wallkicks,
        };

        for (kicks) |kick| {
            if (!engine.isCollision(piece.id, piece.x + kick.x, piece.y + kick.y, new_theta) and
                !wallkickException(engine, piece.*, rotation))
            {
                piece.handleFloorkick(engine, kick.y < 0);
                piece.move(engine, piece.x + kick.x, piece.y + kick.y, new_theta);
                return true;
            }
        }

        return false;
    }
};

/// As found in TGM3. This is the same as TGM1/2 Rotation however with extra wallkicks/floorkicks.
/// https://tetris.wiki/TGM_Rotation#New_wall_kicks_in_TGM3
pub const Tgm3RotationSystem = struct {
    const wallkicks = [_]Wallkick{
        wk(0, 0), wk(1, 0), wk(-1, 1),
    };

    const i_wallkicks = [_]Wallkick{
        wk(0, 0),  wk(1, 0),  wk(2, 0), wk(-1, 0),
        wk(-1, 0), wk(-2, 0), // Floorkicks: TODO: Check we cannot rotate into a floating position.
    };

    const t_wallkicks = [_]Wallkick{
        wk(0, 0),  wk(1, 0), wk(-1, 1),
        wk(-1, 0), // Floorkicks: TODO: Check we cannot rotate into a floating position.
    };

    pub fn blocks(id: Piece.Id, theta: Piece.Theta) Piece.Blocks {
        return TgmRotationSystem.offsets[@enumToInt(id)][@enumToInt(theta)];
    }

    pub fn rotate(engine: Engine, piece: *Piece, rotation: Rotation) bool {
        const new_theta = piece.theta.rotate(rotation);

        const kicks = switch (rotation) {
            .Clockwise, .AntiClockwise => if (piece.id == .I) i_wallkicks else if (piece.id == .T) t_wallkicks else wallkicks,
            .Half => no_wallkicks,
        };

        for (kicks) |kick| {
            if (!engine.isCollision(piece.id, piece.x + kick.x, piece.y + kick.y, new_theta) and
                !TgmRotationSystem.wallkickException(engine, piece.*, rotation))
            {
                // TODO: Implement floorkick limit. 2 for T, 1 for I.
                piece.handleFloorkick(engine, kick.y < 0);
                piece.move(engine, piece.x + kick.x, piece.y + kick.y, new_theta);
                return true;
            }
        }

        return false;
    }
};

test "rotation" {
    std.debug.warn("\n");

    for (DtetRotationSystem.offsets) |rotations, id| {
        std.debug.warn("{}\n", @intToEnum(Piece.Id, @intCast(u3, id)));
        for (rotations) |rotation, i| {
            std.debug.warn("    {}: ", i);
            for (rotation) |s| {
                std.debug.warn("({} {}) ", s.x, s.y);
            }
            std.debug.warn("\n");
        }
    }
}
