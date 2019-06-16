// Read an ini file and parse options into an options struct.
//
// This works at compile-time and can be used to have a configure-from-source option.
//
// ```
// [game]
// ; specifies the randomizer to use
// randomizer = bag7
//
// [ui.terminal]
// glyph = unicode
// ```

const std = @import("std");
const zs = @import("zstack.zig");

pub const LockStyle = enum {
    /// Lock delay is reset on entry of new piece.
    Entry,

    /// Lock delay is reset on downwards movement.
    Step,

    /// Lock delay is reset on any successful movement.
    Move,
};

pub const InitialActionStyle = enum {
    /// IHS/IRS is disabled.
    None,

    /// Can be triggered from last frame action.
    Persistent,

    /// Must get new event to trigger.
    Trigger,
};

// Options are things that are runtime-configurable by the user for a specific game.
pub const Options = struct {
    seed: ?u32 = null,

    well_width: u8 = 10,
    well_height: u8 = 22,
    well_hidden: u8 = 2,

    das_speed_ms: u16 = 0,
    das_delay_ms: u16 = 150,
    are_delay_ms: u16 = 0,
    warn_on_bad_finesse: bool = false,
    are_cancellable: bool = false,

    lock_style: LockStyle = .Move,
    lock_delay_ms: u32 = 150,
    floorkick_limit: u32 = 1,
    one_shot_soft_drop: bool = false,
    rotation_system: zs.RotationSystem.Id = .srs,
    initial_action_style: InitialActionStyle = .None,

    gravity_ms_per_cell: u32 = 1000,
    soft_drop_gravity_ms_per_cell: u32 = 200,
    randomizer: zs.Randomizer.Id = .bag7seamcheck,

    ready_phase_length_ms: u32 = 833,
    go_phase_length_ms: u32 = 833,
    infinite_ready_go_hold: bool = false,
    preview_piece_count: u8 = 4,
    goal: u32 = 40,

    show_ghost: bool = true,

    // Some options have tighter bounds than their types suggest. Verify the invariants
    // hold for all values.
    pub fn verify(options: *Options) bool {
        if (options.well_width > zs.max_well_width) {
            return false;
        }
        if (options.well_height > zs.max_well_height) {
            return false;
        }
        if (options.preview_piece_count > zs.max_preview_count) {
            return false;
        }

        return true;
    }
};

fn toUpper(c: u8) u8 {
    return if (c -% 'a' < 26) c & 0x5f else c;
}

fn eqli(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;

    for (a) |_, i| {
        if (toUpper(a[i]) != toUpper(b[i])) {
            return false;
        }
    }

    return true;
}

// NOTE: This method can be be performed in the json parser to deserialize directly into
// types.
fn deserializeValue(dest: var, key: []const u8, value: []const u8) !void {
    const T = @typeOf(dest).Child;

    // Workaround since above errors at comptime, the above may be known completely and the branches
    // will not be analyzed, thus no errors will be returned and a compile error will occur
    // indicating that no inferred errors were found.
    // TODO: Use explicit error set, is there a std.meta function to get error set value from func def?
    if (zs.utility.forceRuntime(bool, false)) {
        return error.Unreachable;
    }

    switch (@typeInfo(T)) {
        // TODO: Handle fixed array type with length, iterate over, split by comma.
        .Optional => |optional| {
            if (eqli(value, "null")) {
                dest.* = null;
            } else {
                try deserializeValue(@ptrCast(*optional.child, dest), key, value);
            }
        },
        .Enum => |e| {
            inline for (e.fields) |field| {
                if (eqli(value, field.name)) {
                    dest.* = @intToEnum(T, field.value);
                    break;
                }
            } else {
                return error.UnknownEnumEntry;
            }
        },
        .Int => {
            dest.* = try std.fmt.parseInt(T, value, 10);
        },
        .Bool => {
            if (eqli(value, "true") or eqli(value, "yes") or eqli(value, "1")) {
                dest.* = true;
            } else if (eqli(value, "false") or eqli(value, "no") or eqli(value, "0")) {
                dest.* = false;
            } else {
                return error.UnknownBoolValue;
            }
        },
        else => {
            @panic("unsupported deserialization type: " ++ @typeName(T));
        },
    }
}

fn processOption(
    options: *Options,
    keybindings: *zs.input.KeyBindings,
    ui_options: var,
    group: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    if (eqli(group, "game")) {
        inline for (@typeInfo(Options).Struct.fields) |field| {
            if (eqli(key, field.name)) {
                try deserializeValue(&@field(options, field.name), key, value);
            }
        }
    } else if (eqli(group, "keybind")) {
        inline for (@typeInfo(zs.input.KeyBindings).Struct.fields) |field| {
            if (eqli(key, field.name)) {
                try deserializeValue(&@field(keybindings, field.name), key, value);
            }
        }
    } else if (eqli(group, "ui")) {
        // TODO: Handle specific group names so multiple ui options can be configured? Or ignore non-useful?
        inline for (@typeInfo(zs.window.Options).Struct.fields) |field| {
            if (eqli(key, field.name)) {
                try deserializeValue(&@field(ui_options, field.name), key, value);
            }
        }
    } else {
        std.debug.warn("unknown group: {}.{} = {}\n", group, key, value);
    }
}

var buffer: [8192]u8 = undefined;
var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(buffer[0..]);
var allocator = &fixed_buffer_allocator.allocator;

pub fn loadFromIniFile(
    options: *Options,
    keybindings: *zs.input.KeyBindings,
    ui_options: var,
    ini_filename: []const u8,
) !void {
    const ini_contents = try std.io.readFileAlloc(allocator, ini_filename);
    defer allocator.free(ini_contents);

    try parseIni(options, keybindings, ui_options, ini_contents);
}

pub fn parseIni(
    options: *Options,
    keybindings: *zs.input.KeyBindings,
    ui_options: var,
    ini: []const u8,
) !void {
    const max_group_key_length = 64;
    const whitespace = " \t";

    var group_storage: [max_group_key_length]u8 = undefined;
    var group = group_storage[0..0];

    var lines = std.mem.separate(ini, "\n");
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == ';' or line[0] == '#') continue;

        var line_it = std.mem.trimLeft(u8, line, whitespace);
        if (line_it.len == 0) continue;

        switch (line_it[0]) {
            // [group.key]
            '[' => {
                line_it = line_it[1..]; // skip '['
                line_it = std.mem.trimLeft(u8, line_it, whitespace);

                const maybe_group_end = std.mem.indexOfScalar(u8, line_it, ']');
                if (maybe_group_end == null) {
                    return error.UnmatchedBracket;
                }

                const group_key = line_it[0..maybe_group_end.?];
                if (group_key.len > max_group_key_length) {
                    return error.KeyIsToolarge;
                }

                std.mem.copy(u8, group_storage[0..], group_key);
                group = group_storage[0..group_key.len];
            },

            // k=v
            else => {
                const maybe_end_of_key = std.mem.indexOfScalar(u8, line_it, '=');
                if (maybe_end_of_key == null) {
                    return error.MissingEqualFromKeyValue;
                }
                if (maybe_end_of_key.? == 0) {
                    return error.MissingKey;
                }

                const key = std.mem.trimRight(u8, line_it[0..maybe_end_of_key.?], whitespace);

                line_it = line_it[maybe_end_of_key.? + 1 ..];
                const value = std.mem.trim(u8, line_it, whitespace);

                try processOption(options, keybindings, ui_options, group, key, value);
            },
        }
    }

    if (!options.verify()) {
        return error.InvalidOptions;
    }
}

test "parseIni" {
    const example_ini =
        \\; zstack config
        \\; ================
        \\;
        \\; Note:
        \\;  * All values are case-insensitive.
        \\;
        \\;  * Values specified in ms are usually rounded up to the nearest multiple
        \\;    of the tick rate.
        \\
        \\
        \\[keybind]
        \\
        \\rotate_left = z
        \\rotate_right = x
        \\rotate_180= a
        \\left = left
        \\right = right
        \\down = down
        \\up = space
        \\hold = c
        \\quit = q
        \\restart = rshift
        \\
        \\
        \\[game]
        \\
        \\
        \\; Which randomizer to use.
        \\;
        \\; simple    - Memoryless
        \\; bag6      - Bag of length 6
        \\; bag7      - Standard Bag (default)
        \\; bag7-seam - Standard Bag \w Seam Check
        \\; bag14     - Double bag
        \\; bag28     - Quadruple bag
        \\; bag63     - Nontuple bag
        \\; tgm1      - TGM1
        \\; tgm2      - TGM2
        \\; tgm3      - TGM3
        \\randomizer = tgm3
        \\
        \\; Which rotation system to use.
        \\;
        \\; simple    - Sega Rotation; No wallkicks
        \\; sega      - Sega Rotation
        \\; srs       - Super Rotation System (default)
        \\; arikasrs  - SRS \w symmetric I wallkick
        \\; tgm12     - Sega Rotation; Symmetric Wallkicks
        \\; tgm3      - tgm12 \w I floorkicks
        \\; dtet      - Sega Rotation; Simple Symmetric Wallkicks
        \\rotation_system = srs
        \\
        \\; How many blocks gravity will cause the piece to fall every ms.
        \\;
        \\; To convert G's to this form, divide input by 17 and multiply by 10e6.
        \\; i.e. 20G = 20 / 17 * 1000000 = 1127000.
        \\gravity = 625
        \\
        \\; How many blocks soft drop will cause the piece to fall every ms.
        \\; (multiplied by 10e6).
        \\soft_drop_gravity = 5000000
        \\
        \\; Whether a sound should be played on bad finesse
        \\warn_on_bad_finesse = false
        \\
        \\; Delay (in ms) between piece placement and piece spawn.
        \\are_delay = 0
        \\
        \\; Whether ARE delay be cancelled on user input.
        \\are_cancellable = false
        \\
        \\; Delay (in ms) before a piece begins to auto shift.
        \\das_delay = 150
        \\
        \\; Number of blocks to move per ms during DAS (0 = infinite)
        \\das_speed = 0
        \\
        \\; Delay (in ms) before a piece locks.
        \\lock_delay_ms = 150
        \\
        \\; How many floorkicks can be performed before the piece locks. (0 = infinite)
        \\floorkick_limit = 1
        \\
        \\; Behaviour used for initial actions (IRS/IHS).
        \\;
        \\; none       - IRS/IHS disabled (default)
        \\; persistent - Triggered solely by current keystate
        \\; trigger    - Explicit new event required (unimplemented)
        \\initial_action_style = none
        \\
        \\; Behaviour used for lock reset.
        \\;
        \\; entry      - Reset only on new piece spawn
        \\; step       - Reset on downward movement
        \\; move       - Reset on any succssful movement/rotation (default)
        \\lock_style = move
        \\
        \\; Whether soft drop is held through new piece spawns.
        \\;
        \\; Note: The current implementation only works properly with 'softDropGravity'
        \\; set to instant (above 2).
        \\one_shot_soft_drop = true
        \\
        \\; Period at which the draw phase is performed.
        \\ticks_per_draw = 2
        \\
        \\; Width of the play field.
        \\field_width = 10
        \\
        \\; Height of the playfield.
        \\field_height = 22
        \\
        \\; Number of hidden rows
        \\field_hidden = 2
        \\
        \\; Whether we can hold as many times as we want during pre-game.
        \\infinite_ready_go_hold = true
        \\
        \\; Length (in ms) of the Ready phase.
        \\ready_phase_length_ms = 833
        \\
        \\; Length (in ms) of the Go phase.
        \\go_phase_length_ms = 833
        \\
        \\; Number of preview pieces to display (max 4).
        \\preview_piece_count = 2
        \\
        \\; Target number of lines to clear.
        \\goal = 40
        \\
        \\
        \\[frontend.sdl2]
        \\
        \\; Width of the display window
        \\width = 800
        \\
        \\; Height of the display window
        \\height = 600
        \\
        \\; Show the debug screen during execution
        \\show_debug = false
        \\
        \\
        \\[frontend.terminal]
        \\
        \\; Glyphs to use when drawing to screen
        \\;
        \\; ascii   - Use only characters only from the ascii charset (default)
        \\; unicode - Use unicode box-drawing chars for borders
        \\glyphs = unicode
        \\
        \\; Center the field in the middle of the window.
        \\;
        \\; If not set, the field will be drawn from the top-left corner of the screen.
        \\center_field = true
        \\
        \\; Should the field be colored or a single palette?
        \\colored_field = false
    ;

    var options = Options.default();
    var ui_options = zs.window.Options.default();
    var keys = zs.input.KeyBindings.default();
    try parseIni(&options, &keys, &ui_options, example_ini);
}

test "parseIni k=v no space" {
    const example_ini =
        \\[game]
        \\goal=10
        \\seed=15
        \\
    ;

    var options = Options.default();
    var ui_options = zs.window.Options.default();
    var keys = zs.input.KeyBindings.default();
    try parseIni(&options, &keys, &ui_options, example_ini);

    std.testing.expectEqual(options.goal, 10);
    std.testing.expectEqual(options.seed, 15);
}
