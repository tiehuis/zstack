// Handles user input from a multitude of sources.
//
// A ui component is expected to fill an input object of the "current" keys that are pressed.
// This module computes the corresponding game input based on certain parameters such as das
// and arr configuration and the last known key state.

// How input is expected to work:
//
// A window implementation maps physical keys through to a bitset of virtual keys that the
// engine can understand. This occurs every frame. Next, these virtual keys are matched against
// the existing movement state of the engine and mapped to specific movement and rotation
// accordingly.
//
// Window -> Returns BitSet(VirtualKey)
// Engine -> Maps BitSet(VirtualKey) to input.Actions
// Engine -> Performs game logic, as per input.Actions

const std = @import("std");
const zs = @import("zstack.zig");

const BitSet = zs.BitSet;

/// Virtual key input returned by a frontend.
pub const VirtualKey = enum(u32) {
    Up = 0x01,
    Down = 0x02,
    Left = 0x04,
    Right = 0x08,
    RotateLeft = 0x10,
    RotateRight = 0x20,
    RotateHalf = 0x40,
    Hold = 0x80,
    Start = 0x100,
    Restart = 0x200,
    Quit = 0x400,

    pub fn fromIndex(i: usize) VirtualKey {
        std.debug.assert(i < @memberCount(VirtualKey));
        return @intToEnum(VirtualKey, (u32(1) << @intCast(u5, i)));
    }
};

pub const KeyBindings = struct {
    Up: Key = .space,
    Down: Key = .down,
    Left: Key = .left,
    Right: Key = .right,
    RotateLeft: Key = .z,
    RotateRight: Key = .x,
    RotateHalf: Key = .s,
    Hold: Key = .c,
    Start: Key = .enter,
    Restart: Key = .rshift,
    Quit: Key = .q,

    _scratch: [@memberCount(VirtualKey)]Key = undefined,

    // Only valid until the next call to entries, don't keep this slice around.
    pub fn entries(self: *KeyBindings) []const Key {
        // Must match order of VirtualKey
        self._scratch = [_]Key{
            self.Up,
            self.Down,
            self.Left,
            self.Right,
            self.RotateLeft,
            self.RotateRight,
            self.RotateHalf,
            self.Hold,
            self.Start,
            self.Restart,
            self.Quit,
        };

        return self._scratch;
    }
};

pub const Key = enum {
    space,
    enter,
    tab,
    right,
    left,
    down,
    up,
    rshift,
    lshift,
    capslock,
    comma,
    period,
    slash,
    semicolon,
    apostrophe,
    lbracket,
    rbracket,
    backslash,
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
};

/// Specific game actions for the engine.
pub const Actions = struct {
    pub const Extra = enum(u32) {
        // TODO: Enum set size determined by membercount and not min/max values in the set.
        // Make an issue.
        HardDrop = 0x01,
        Hold = 0x02,
        Lock = 0x04,
        Quit = 0x08,
        Restart = 0x10,
        Move = 0x20,
        Rotate = 0x40,
        FinesseRotate = 0x80,
        FinesseMove = 0x100,
    };

    /// Relative rotation action, e.g. Clockwise, Anticlockwise or Half.
    rotation: ?zs.Rotation,

    /// Left-right movemment in the x-axis (+ is right, - is left)
    movement: i8,

    /// Downwards movement in the y-axis (fractional, see fixed-point).
    gravity: zs.uq8p24,

    /// Extra actions to apply to the piece.
    extra: BitSet(Extra),

    /// All keys that are currently pressed this frame.
    keys: BitSet(VirtualKey),

    /// The new keys that were pressed this frame and not last.
    new_keys: BitSet(VirtualKey),

    // TODO: Don't need an init? Just make the virtualKeys map a member of Actions and construct
    // directly. Keeps it a bit simpler since internally the engine doesn't actually care
    // besides a few counters.
    pub fn init() Actions {
        return Actions{
            .rotation = null,
            .movement = 0,
            .gravity = zs.uq8p24.init(0, 0),
            .extra = BitSet(Extra).init(),
            .keys = BitSet(VirtualKey).init(),
            .new_keys = BitSet(VirtualKey).init(),
        };
    }
};
