const std = @import("std");
const zs = @import("zstack.zig");

const Engine = zs.Engine;
const Options = zs.Options;
const Window = zs.window.Window;

const Flag = zstack.input.Flag;
const Action = zstack.input.Action;
const ActionFlag = zstack.input.ActionFlag;
const ActionFlags = zstack.input.ActionFlags;

const Timer = struct {
    timer: std.time.Timer,

    pub fn init() !Timer {
        return Timer{ .timer = try std.time.Timer.start() };
    }

    pub fn read(self: *Timer) i64 {
        return @intCast(i64, self.timer.read() / 1000);
    }

    pub fn sleep(self: Timer, microseconds: i64) void {
        if (microseconds < 0) return;
        std.time.sleep(@intCast(u64, microseconds * 1000));
    }
};

fn loop(window: var, engine: *Engine) !void {
    const tick_rate = zs.ms_per_tick * 1000;

    var timer = try Timer.init();

    var total_render_time_us: i64 = 0;
    var total_render_frames: i64 = 0;
    var total_engine_time_us: i64 = 0;
    var total_engine_frames: i64 = 0;
    var total_frames: i64 = 0;

    var last_time = timer.read() - tick_rate; // Ensure 0-lag for first frame.
    var lag: i64 = 0;
    var average_frame: i64 = 0;

    // If no replays are wanted, then use a NullOutStream.

    // Write history, note that the writer should actually keep track of the current tick
    // and only write when a key change is encountered.
    //var w = zs.replay.Writer(std.os.File.OutStream).init("1.replay");
    //w.writeheader(engine.total_ticks_raw, keys);
    //defer w.flush();
    // On completion, if state == .GameWin, call w.finalize() else w.remove() the output.
    // NOTE: Engine does not handle replays at all, that is an above layer.

    // Two different input handlers, one for normal play, and the other which wraps any other
    // handler and reads from a replay file. This handler should also handle quit events.
    //var r = try zs.replay.v1.read(&engine.options, ReplayInputIterator);
    //var input_handler = r;
    //input_handler.readKeys();

    // The input could also abstract different input types, such as joystick keyboard etc.

    // Fixed timestep with lag reduction.
    while (!engine.quit()) {
        const start_time = timer.read();
        const elapsed = start_time - last_time;
        last_time = start_time;

        // Lag can be negative, which means the frame we are processing will be slightly
        // longer. This works out alright in practice so leave it.
        lag += (elapsed - tick_rate);

        const engine_start = timer.read();
        const keys = window.readKeys();
        engine.tick(keys);

        const frame_engine_time_us = timer.read() - engine_start;
        total_engine_time_us += frame_engine_time_us;
        total_engine_frames += 1;

        var frame_render_time_us: i64 = 0;
        if (engine.inDrawFrame()) {
            const render_start = timer.read();
            try window.render(engine.*);
            frame_render_time_us = timer.read() - render_start;
            total_render_time_us += frame_render_time_us;
            total_render_frames += 1;
        }

        // Keep track of average frame time during execution to ensure we haven't stalled.
        const current_time = timer.read();
        average_frame += @divTrunc((current_time - start_time) - average_frame, engine.total_ticks_raw);

        const tick_end = start_time + tick_rate;
        // The frame took too long. NOTE: We cannot display this in most cases since the render
        // time is capped to the refresh rate usually and thus will exceed the specified limit.
        // We should add a specific blit call and avoid a blocking render call if possible. This
        // causes the game to run slower and disrupts usually function unless the swap interval
        // is set to 0.
        if (false) { // tick_end < current_time) {
            std.debug.warn(
                "frame {} exceeded tick-rate of {}us: engine: {}us, render: {}us\n",
                total_frames,
                u64(tick_rate),
                frame_engine_time_us,
                frame_render_time_us,
            );
        }

        // If a frame has taken too long, then the required sleep value will be negative.
        // We do not handle this case by shortening frames, instead we assume we will catch up
        // in subsequent frames to compensate.
        //
        // TODO: Test on a really slow machine. I would rather spend time making everything
        // as quick as possible than spend time thinking of ways to handle cases where we don't
        // run quick enough. We should be able to run sub 1-ms every tick 100%.
        //
        // Note that it will practically always be the rendering cycle that consumes excess cpu time.
        // Time engine, read keys and ui render portions of the loop to check what is talking
        // how long.
        //
        // TODO: Also check when vsync is enabled and the engine rate is under the render rate.
        const sleep_time = tick_end - lag - current_time;
        if (sleep_time > 0) {
            timer.sleep(sleep_time);
        }

        total_frames += 1;
    }

    // Render the final frame, this may have been missed during the main loop if we were
    // in between draw frames.
    try window.render(engine.*);

    // Cross-reference in-game time based on ticks to a system reference clock to confirm
    // long-term accuracy.
    const actual_elapsed = @divTrunc(timer.read(), 1000);
    const ingame_elapsed = engine.total_ticks_raw * zs.ms_per_tick;

    std.debug.warn(
        \\Average engine frame: {}us
        \\Average render frame: {}us
        \\Actual time elapsed:  {}
        \\In-game time elapsed: {}
        \\Maximum difference:   {}
        \\
    ,
        @divTrunc(total_engine_time_us, total_frames),
        @divTrunc(total_render_time_us, total_frames),
        actual_elapsed,
        ingame_elapsed,
        actual_elapsed - ingame_elapsed,
    );
}

pub fn main() !void {
    var options = Options{};
    var ui_options = zs.window.Options{};
    var keybindings = zs.input.KeyBindings{};

    // Read from zstack.ini file located in the same directory as the executable?
    // Has some issues but treating this as a portable application for now is fine.
    zs.config.loadFromIniFile(&options, &keybindings, &ui_options, "zstack.ini") catch |err| {
        std.debug.warn("failed to open ini file: {}\n", err);
    };

    if (options.seed == null) {
        var buf: [4]u8 = undefined;
        try std.crypto.randomBytes(buf[0..]);
        options.seed = std.mem.readIntSliceLittle(u32, buf[0..4]);
    }

    var engine = Engine.init(options);

    var window = try Window.init(ui_options, keybindings);
    defer window.deinit();

    try loop(&window, &engine);
}
