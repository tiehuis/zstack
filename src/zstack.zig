const build_options = @import("build_options");

pub const piece = @import("piece.zig");
pub const randomizer = @import("randomizer.zig");
pub const rotation = @import("rotation.zig");
pub const config = @import("config.zig");
pub const engine = @import("engine.zig");
pub const input = @import("input.zig");
pub const utility = @import("utility.zig");

// Build option to switch this
pub const window = if (build_options.use_sdl2)
    @import("window_sdl.zig")
else
    @import("window_gl.zig");

pub const Engine = engine.Engine;
pub const RotationSystem = rotation.RotationSystem;
pub const Randomizer = randomizer.Randomizer;
pub const Piece = piece.Piece;
pub const Block = piece.Block;
pub const Options = config.Options;
pub const Rotation = rotation.Rotation;
pub const BitSet = utility.BitSet;
pub const FixedQueue = utility.FixedQueue;
pub const uq8p24 = utility.uq8p24;
pub const Window = window.Window;

// compile-time configuration options
pub const max_well_width = 20;
pub const max_well_height = 25;
pub const max_preview_count = 5;

// These were runtime-configurable in faststack, however this seemed overly useless as variable
// tick-rates didn't really add anything (beyond maybe reducing requirements for a slow system
// sans recompilation).
pub const ms_per_tick = 16;
pub const ticks_per_draw_frame = 1;

pub fn ticks(x: var) @typeOf(x) {
    return x / ms_per_tick;
}

pub fn Coord(comptime T: type) type {
    return struct {
        x: T,
        y: T,
    };
}
