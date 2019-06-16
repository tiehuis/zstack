const std = @import("std");
const zs = @import("zstack.zig");

/// A piece is made up of many blocks. A block right now only indicates which piece it belonds to.
/// However, in the future we can add new attributes to do some more interesting mechanics to
/// the field.
///
/// Note that a field block is different from a piece block and a falling piece does only
/// requires a bitset.
pub const Block = struct {
    id: Piece.Id,
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const Piece = struct {
    pub const Id = enum {
        pub const count = @memberCount(@This());

        I,
        J,
        L,
        O,
        S,
        T,
        Z,

        pub fn fromInt(i: var) Id {
            std.debug.assert(i >= 0 and i < count);
            return @intToEnum(Piece.Id, @intCast(u3, i));
        }

        // Default color-scheme for a specific id.
        pub fn color(self: Id) Color {
            return switch (self) {
                .I => Color{ .r = 5, .g = 186, .b = 221, .a = 255 },
                .J => Color{ .r = 238, .g = 23, .b = 234, .a = 255 },
                .L => Color{ .r = 249, .g = 187, .b = 0, .a = 255 },
                .O => Color{ .r = 7, .g = 94, .b = 240, .a = 255 },
                .S => Color{ .r = 93, .g = 224, .b = 31, .a = 255 },
                .T => Color{ .r = 250, .g = 105, .b = 0, .a = 255 },
                .Z => Color{ .r = 237, .g = 225, .b = 0, .a = 255 },
            };
        }
    };

    pub const Theta = enum {
        pub const count = @memberCount(@This());

        R0,
        R90,
        R180,
        R270,

        pub fn rotate(self: Theta, rotation: zs.Rotation) Piece.Theta {
            const p = @intCast(u8, i8(@enumToInt(self)) + 4 + i8(@enumToInt(rotation)));
            return @intToEnum(Piece.Theta, @intCast(u2, p % Theta.count));
        }
    };

    pub const Blocks = [4]zs.Coord(u8);

    /// What kind of piece this is.
    id: Id,

    /// x coodinate. Origin is top-left corner of bounding box.
    x: i8,
    fn ux(piece: Piece) u8 {
        return @intCast(u8, piece.x);
    }

    /// y coordinate. Origin is top-left corner of bounding box.
    y: i8,
    fn uy(piece: Piece) u8 {
        return @intCast(u8, piece.y);
    }

    /// When falling, we don't drop a square every tick. We need to have a fractional value
    /// stored which represents how far through the current block we actually are.
    ///
    /// TODO: Maybe change y so only actual value exists and user has to call y() to get the whole value.
    y_actual: zs.uq8p24,

    /// Maximum y this piece can fall to. Cached since this is used every render frame for a ghost.
    y_hard_drop: i8,

    /// Current rotation.
    theta: Theta,

    /// Number of ticks elapsed in a locking state (e.g. .Landed).
    lock_timer: u32,

    /// Number of times this piece has been floorkicked.
    /// NOTE: Make floorkicks not configurable?
    floorkick_count: u32,

    pub fn init(engine: zs.Engine, id: Id, x: i8, y: i8, theta: Theta) Piece {
        return Piece{
            .id = id,
            .x = x,
            .y = y,
            .y_actual = zs.uq8p24.init(@intCast(u8, y), 0),
            .y_hard_drop = yHardDrop(engine, id, x, y, theta),
            .theta = theta,
            .lock_timer = 0,
            .floorkick_count = 0,
        };
    }

    pub fn yHardDrop(e: zs.Engine, id: Id, x: i8, y: i8, theta: Theta) i8 {
        if (x >= @intCast(i8, e.options.well_width) or y >= @intCast(i8, e.options.well_height)) {
            return @intCast(i8, e.options.well_height);
        }

        var y_new = y + 1;
        while (!e.isCollision(id, x, y_new, theta)) : (y_new += 1) {}
        return y_new - 1;
    }

    pub fn handleFloorkick(piece: *Piece, engine: zs.Engine, is_floorkick: bool) void {
        if (is_floorkick and engine.options.floorkick_limit != 0) {
            piece.floorkick_count += 1;
            if (piece.floorkick_count >= engine.options.floorkick_limit) {
                piece.lock_timer = zs.ticks(engine.options.lock_delay_ms);
            }
        }
    }

    // Unchecked move to an arbitrary position in the well.
    pub fn move(piece: *Piece, engine: zs.Engine, x: i8, y: i8, theta: Theta) void {
        piece.x = x;
        piece.y = y;
        piece.y_actual = zs.uq8p24.init(piece.uy(), piece.y_actual.frac()); // preserve fractional y position
        piece.y_hard_drop = yHardDrop(engine, piece.id, x, y, theta);
        piece.theta = theta;
    }
};
