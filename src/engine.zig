const std = @import("std");
const zs = @import("zstack.zig");

const Piece = zs.Piece;
const Block = zs.Block;
const BitSet = zs.BitSet;
const VirtualKey = zs.input.VirtualKey;
const Actions = zs.input.Actions;
const FixedQueue = zs.FixedQueue;

pub const Engine = struct {
    pub const State = enum {
        /// When "READY" is displayed.
        Ready,

        /// When "GO" is displayed.
        Go,

        /// When piece has nothing beneath it.
        Falling,

        /// When piece has hit top of stack/floor.
        Landed,

        /// When waiting for new piece to spawn after previous piece is placed.
        Are,

        /// When a new piece needs to be spawned. Occurs instantly.
        NewPiece,

        /// When a line clear is occurring.
        ClearLines,

        /// User-specified quit action.
        Quit,

        /// User lost (topped out).
        GameOver,

        /// User restarts.
        Restart,
    };

    pub const Statistics = struct {
        lines_cleared: usize,
        blocks_placed: usize,

        pub fn init() Statistics {
            return Statistics{
                .lines_cleared = 0,
                .blocks_placed = 0,
            };
        }
    };

    state: State,

    // The well is the main field where all pieces are dropped in to. We provide an upper-bound
    // on the height and width so we can have fixed memory for it.
    well: [zs.max_well_height][zs.max_well_width]?Block,

    // The current piece contains the x, y, theta and current raw blocks it occupies. To rotate
    // the piece a rotation system must be used.
    piece: ?Piece,
    // TODO: Play around with having a multiple hold piece queue. Use a ring buffer, but allow
    // entries to be null to suit.
    hold_piece: ?Piece.Id,

    // Preview pieces have a fixed upper bound. Note that this is the viewable preview pieces.
    const PreviewQueue = FixedQueue(Piece.Id, zs.max_preview_count);
    preview_pieces: PreviewQueue,

    randomizer: zs.Randomizer,
    rotation_system: zs.RotationSystem,

    total_ticks_raw: i64,
    hold_available: bool,
    generic_counter: u32,

    /// Keys pressed this frame
    keys: BitSet(VirtualKey),

    /// How many ticks have elapsed with DAS applied
    das_counter: i32,
    are_counter: u32,

    stats: Statistics,

    // This contains a lot of the main functionality, for example well_width, well_height etc.
    options: zs.Options,

    pub fn init(options: zs.Options) Engine {
        // TODO: Caller must set seed if not set. Don't want os specific stuff here.
        std.debug.assert(options.seed != null);

        var engine = Engine{
            .state = .Ready,

            .well = [_][zs.max_well_width]?Block{([_]?Block{null} ** zs.max_well_width)} ** zs.max_well_height,

            .piece = null,
            .hold_piece = null,

            .preview_pieces = PreviewQueue.init(options.preview_piece_count),

            .randomizer = zs.Randomizer.init(options.randomizer, options.seed.?),
            .rotation_system = zs.RotationSystem.init(options.rotation_system),

            .total_ticks_raw = 0,
            .hold_available = true,
            .generic_counter = 0,

            .keys = BitSet(VirtualKey).init(),
            .das_counter = 0,
            .are_counter = 0,

            .stats = Statistics.init(),
            .options = options,
        };

        // Queue up initial preview pieces
        var i: usize = 0;
        while (i < options.preview_piece_count) : (i += 1) {
            engine.preview_pieces.insert(engine.randomizer.next());
        }

        return engine;
    }

    pub fn quit(self: Engine) bool {
        return switch (self.state) {
            .Quit => true,
            else => false,
        };
    }

    // Various statistics.

    // Returns true if the hold was successful.
    fn holdPiece(e: *Engine) bool {
        if (!e.hold_available) {
            return false;
        }

        if (e.hold_piece) |hold| {
            e.hold_piece = e.piece.?.id;
            e.piece = Piece.init(e.*, hold, @intCast(i8, e.options.well_width / 2 - 1), 1, .R0);
        } else {
            e.nextPiece();
            e.hold_piece = e.piece.?.id;
        }

        e.hold_available = false;
        return true;
    }

    fn nextPiece(e: *Engine) void {
        e.piece = Piece.init(e.*, e.nextPreviewPiece(), @intCast(i8, e.options.well_width / 2 - 1), 1, .R0);
        e.hold_available = true;
    }

    fn nextPreviewPiece(e: *Engine) Piece.Id {
        return e.preview_pieces.take(e.randomizer.next());
    }

    fn clearLines(e: *Engine) u8 {
        var found: u64 = 0;
        var filled: u8 = 0;

        var y: usize = 0;
        while (y < e.options.well_height) : (y += 1) {
            next_row: {
                var x: usize = 0;
                while (x < e.options.well_width) : (x += 1) {
                    if (e.well[y][x] == null) {
                        break :next_row;
                    }
                }

                found |= 1;
                filled += 1;
            }

            found <<= 1;
        }

        found >>= 1;

        // Shift and replace fill rows.
        var dst = e.options.well_height - 1;
        var src = dst;
        while (src >= 0) : ({
            src -= 1;
            found >>= 1;
        }) {
            if (found & 1 != 0) {
                continue;
            }

            if (src != dst) {
                // TODO: Cannot copy like this?
                std.mem.copy(?Block, e.well[dst][0..e.options.well_width], e.well[src][0..e.options.well_width]);
            }

            // TODO: Handle dst being negative cleaner.
            if (dst == 0 or src == 0) {
                break;
            }

            dst -= 1;
        }

        var i: usize = 0;
        while (i < filled) : (i += 1) {
            std.mem.set(?Block, e.well[dst][0..], null);
        }

        return filled;
    }

    fn rotatePiece(e: *Engine, rotation: zs.Rotation) bool {
        return e.rotation_system.rotate(e.*, &e.piece.?, rotation);
    }

    fn isOccupied(e: Engine, x: i8, y: i8) bool {
        if (x < 0 or x >= @intCast(i8, e.options.well_width) or y < 0 or y >= @intCast(i8, e.options.well_height)) {
            return true;
        }

        return e.well[@intCast(u8, y)][@intCast(u8, x)] != null;
    }

    fn isCollision(e: Engine, id: Piece.Id, x: i8, y: i8, theta: Piece.Theta) bool {
        const blocks = e.rotation_system.blocks(id, theta);
        for (blocks) |b| {
            if (isOccupied(e, x + @intCast(i8, b.x), y + @intCast(i8, b.y))) {
                return true;
            }
        }

        return false;
    }

    fn applyPieceGravity(e: *Engine, gravity: zs.uq8p24) void {
        var p = &e.piece.?;

        p.y_actual = p.y_actual.add(gravity);
        p.y = @intCast(i8, p.y_actual.whole());

        // if we overshoot bottom of field, fix to lowest possible y and enter locking phase.
        if (@intCast(i8, p.y_actual.whole()) >= p.y_hard_drop) {
            p.y_actual = zs.uq8p24.init(@intCast(u8, p.y_hard_drop), 0);
            p.y = p.y_hard_drop;
            e.state = .Landed;
        } else {
            // If falling reset lock timer.
            // TODO: Handle elsewhere?
            if (e.options.lock_style == .Step or e.options.lock_style == .Move and
                @intCast(i8, p.y_actual.whole()) > p.y)
            {
                p.lock_timer = 0;
            }

            p.y = @intCast(i8, p.y_actual.whole());
            e.state = .Falling;
        }
    }

    // Lock the current piece to the playing field.
    fn lockPiece(e: *Engine) void {
        const p = e.piece.?;

        const blocks = e.rotation_system.blocks(p.id, p.theta);
        for (blocks) |b| {
            e.well[@intCast(u8, p.y_hard_drop + @intCast(i8, b.y))][@intCast(u8, p.x + @intCast(i8, b.x))] = Block{ .id = p.id };
        }

        // TODO: Handle finesse
        e.stats.blocks_placed += 1;
    }

    fn inDrawFrame(e: Engine) bool {
        // TODO: Handle first quit/restart frame, only show on the one frame
        return (@mod(e.total_ticks_raw, zs.ticks_per_draw_frame) == 0) or
            (switch (e.state) {
            .Quit => true,
            else => false,
        });
    }

    // TODO: Make the first input a bit more responsive on first click. A bit clunky.
    fn virtualKeysToActions(e: *Engine, keys: BitSet(VirtualKey)) Actions {
        var actions = Actions.init();

        const last_tick_keys = e.keys;
        e.keys = keys;

        actions.keys = keys;
        actions.new_keys = BitSet(VirtualKey).initRaw(keys.raw & ~last_tick_keys.raw);

        const i_das_delay = @intCast(i32, zs.ticks(e.options.das_delay_ms));
        const i_das_speed = @intCast(i32, zs.ticks(e.options.das_speed_ms));
        if (keys.get(.Left)) {
            if (e.das_counter > -i_das_delay) {
                if (e.das_counter >= 0) {
                    e.das_counter = -1;
                    actions.movement = -1;
                } else {
                    e.das_counter -= 1;
                }
            } else {
                if (i_das_speed != 0) {
                    e.das_counter -= i_das_speed - 1;
                    actions.movement = -1;
                } else {
                    actions.movement = -@intCast(i8, e.options.well_width);
                }
            }
        } else if (keys.get(.Right)) {
            if (e.das_counter < i_das_delay) {
                if (e.das_counter <= 0) {
                    e.das_counter = 1;
                    actions.movement = 1;
                } else {
                    e.das_counter += 1;
                }
            } else {
                if (i_das_speed != 0) {
                    e.das_counter += i_das_speed - 1;
                    actions.movement = 1;
                } else {
                    actions.movement = @intCast(i8, e.options.well_width);
                }
            }
        } else {
            e.das_counter = 0;
        }

        // NOTE: Gravity is not additive. That is, soft drop does not add to the base gravity
        // but replaces it.
        // TODO: If base gravity is greater than soft drop don't replace.
        const soft_drop_keys = if (e.options.one_shot_soft_drop) &actions.new_keys else &actions.keys;
        if (soft_drop_keys.get(.Down)) {
            // Example: 96ms per full cell move means we move tick_rate / 96 per tick.
            //  = 4/96 = 0.0417 cells per tick at 4ms per tick.
            actions.gravity = zs.uq8p24.initFraction(zs.ms_per_tick, e.options.soft_drop_gravity_ms_per_cell);
        } else {
            actions.gravity = zs.uq8p24.initFraction(zs.ms_per_tick, e.options.gravity_ms_per_cell);
        }

        if (actions.new_keys.get(.Right) or actions.new_keys.get(.Left)) {
            actions.extra.set(.FinesseMove);
        }
        if (actions.new_keys.get(.RotateLeft)) {
            actions.rotation = zs.Rotation.AntiClockwise;
            actions.extra.set(.FinesseRotate);
        }
        if (actions.new_keys.get(.RotateRight)) {
            actions.rotation = zs.Rotation.Clockwise;
            actions.extra.set(.FinesseRotate);
        }
        if (actions.new_keys.get(.RotateHalf)) {
            actions.rotation = zs.Rotation.Half;
            actions.extra.set(.FinesseRotate);
        }
        if (actions.new_keys.get(.Hold)) {
            actions.extra.set(.Hold);
        }
        // TODO: Don't repeat this, not handling new keys correctly.
        if (actions.new_keys.get(.Up)) {
            actions.gravity = zs.uq8p24.init(e.options.well_height, 0);
            actions.extra.set(.HardDrop);
            actions.extra.set(.Lock);
        }
        if (actions.keys.get(.Quit)) {
            actions.extra.set(.Quit);
        }
        if (actions.keys.get(.Restart)) {
            actions.extra.set(.Restart);
        }

        return actions;
    }

    // Note that the game can tick at varying speeds. All configuration options are rounded up to the
    // nearest tick so if a configuration option is not specified as a multiple of the tick rate, odd
    // things will likely occur.
    //
    // Most testing occurs with a tick rate of 8ms which is ~120fps. The draw cycle is independent of
    // the internal tick rate but will occur at a fixed multiple of them.
    pub fn tick(e: *Engine, i: BitSet(VirtualKey)) void {
        var actions = e.virtualKeysToActions(i);

        e.total_ticks_raw += 1;

        if (actions.extra.get(.Restart)) {
            e.state = .Restart;
        }
        if (actions.extra.get(.Quit)) {
            e.state = .Quit;
        }

        switch (e.state) {
            .Ready, .Go => {
                // Ready, go has slightly different hold mechanics than normal. Since we do not have
                // a piece, we need to copy directly from the next queue to the hold piece instead of
                // copying between the current piece. Further, we can optionally hold as many time as
                // we want and may need to discard the existing hold piece.
                if (e.hold_available and actions.extra.get(.Hold)) {
                    e.hold_piece = nextPreviewPiece(e);
                    if (!e.options.infinite_ready_go_hold) {
                        e.hold_available = false;
                    }
                }

                if (e.generic_counter == zs.ticks(e.options.ready_phase_length_ms)) {
                    e.state = .Go;
                }
                if (e.generic_counter == zs.ticks(e.options.ready_phase_length_ms + e.options.go_phase_length_ms)) {
                    // TODO: New Piece needs to be instant?
                    e.state = .NewPiece;
                }

                e.generic_counter += 1;
            },

            .Are => {
                // TODO: The well should not be cleared until the ARE action is performed.
                // Don't clear here. Do Are -> ClearLines -> NewPiece instead.
                if (e.options.are_cancellable and actions.new_keys.raw != 0) {
                    e.are_counter = 0;
                    e.state = .NewPiece;
                } else {
                    e.are_counter += 1;
                    if (e.are_counter > zs.ticks(e.options.are_delay_ms)) {
                        e.are_counter = 0;
                        e.state = .NewPiece;
                    }
                }
            },

            .NewPiece => {
                nextPiece(e);

                // Apply IHS/IRS before top-out condition is checked.
                //if (e.irs != .None) {
                //    e.rotatePiece(e.irs);
                //}
                //if (e.ihs) {
                //    e.holdPiece();
                //}

                //e.irs = .None;
                //e.ihs = false;

                const p = e.piece.?;
                if (e.isCollision(p.id, p.x, p.y, p.theta)) {
                    e.piece = null; // Don't display piece on board
                    e.state = .GameOver;
                } else {
                    e.state = .Falling;
                }
            },

            // TODO: Input feels a bit janky in certain points.
            .Falling, .Landed => {
                var p = &e.piece.?;

                e.applyPieceGravity(actions.gravity);

                // Handle locking prior to all movement. This is much more natural as applying movement
                // after locking is to occur feels wrong.
                if (actions.extra.get(.HardDrop) or
                    ((p.lock_timer >= zs.ticks(e.options.lock_delay_ms) and e.state == .Landed)))
                {
                    // TODO: Assert we are on bottom of field
                    lockPiece(e);

                    e.state = .ClearLines;
                    return;
                }

                if (actions.extra.get(.Hold)) {
                    _ = holdPiece(e);
                }

                if (actions.rotation) |rotation| {
                    _ = e.rotatePiece(rotation);
                }

                // Left movement is prioritized over right moment.
                var mv = actions.movement;
                while (mv < 0) : (mv += 1) {
                    if (!isCollision(e.*, p.id, p.x - 1, p.y, p.theta)) {
                        p.x -= 1;
                    }
                }
                while (mv > 0) : (mv -= 1) {
                    if (!isCollision(e.*, p.id, p.x + 1, p.y, p.theta)) {
                        p.x += 1;
                    }
                }
                // TODO: Handle this better.
                p.y_hard_drop = Piece.yHardDrop(e.*, p.id, p.x, p.y, p.theta);

                if (e.state == .Landed) {
                    p.lock_timer += 1;
                } else {
                    // TODO: Don't reset lock delay like this, this should be handled elsewhere
                    // and take into account floorkick limits etc.
                    p.lock_timer = 0;
                }
            },

            .ClearLines => {
                e.stats.lines_cleared += clearLines(e);
                if (e.stats.lines_cleared < e.options.goal) {
                    e.state = .Are;
                } else {
                    e.state = .GameOver;
                    e.piece = null;
                }
            },

            .GameOver, .Quit, .Restart => {},
        }
    }
};
