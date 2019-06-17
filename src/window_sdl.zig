const std = @import("std");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL_FontCache.h");
});
const zs = @import("zstack.zig");

const Piece = zs.Piece;
const BitSet = zs.BitSet;
const VirtualKey = zs.input.VirtualKey;
const Key = zs.input.Key;

const Measure = enum {
    BlockSide,

    WellX,
    WellY,
    WellH,
    WellW,

    HoldX,
    HoldY,
    HoldW,
    HoldH,

    PreviewX,
    PreviewY,
    PreviewW,
    PreviewH,

    StatsX,
    StatsY,
    StatsW,
    StatsH,
};

const stack_color = zs.piece.Color{
    .r = 140,
    .g = 140,
    .b = 140,
    .a = 255,
};

fn len(w: Window, e: zs.Engine, comptime measure: Measure) usize {
    return switch (measure) {
        .BlockSide => @floatToInt(usize, @intToFloat(f64, w.width) * 0.02625),

        .WellX => @floatToInt(usize, @intToFloat(f64, w.width) * 0.13125),
        .WellY => @floatToInt(usize, @intToFloat(f64, w.height) * 0.15),
        .WellW => e.options.well_width * len(w, e, .BlockSide),
        .WellH => (e.options.well_height - e.options.well_hidden) * len(w, e, .BlockSide),

        .HoldX => len(w, e, .WellX) - @floatToInt(usize, (5 * @intToFloat(f64, len(w, e, .BlockSide)))),
        .HoldY => len(w, e, .WellY),
        .HoldW => 4 * len(w, e, .BlockSide),
        .HoldH => 4 * len(w, e, .BlockSide),

        .PreviewX => len(w, e, .WellX) + len(w, e, .WellW) + 10,
        .PreviewY => len(w, e, .WellY),
        .PreviewW => 4 * len(w, e, .BlockSide),
        .PreviewH => len(w, e, .WellH),

        .StatsX => len(w, e, .PreviewX) + len(w, e, .previewW) + 20,
        .StatsY => len(w, e, .WellY),
        .StatsW => @floatToInt(usize, @intToFloat(f64, w.width) * 0.125),
        .StatsH => len(w, e, .WellH),
    };
}

fn SDL_Check(result: c_int) !void {
    if (result < 0) {
        std.debug.warn("SDL error: {c}\n", c.SDL_GetError());
        return error.SDLError;
    }
}

fn calcFontSize(w: c_int) c_int {
    return @divTrunc(w, 40);
}

pub const Options = struct {
    width: c_int = 640,
    height: c_int = 480,
    debug: bool = true,
};

pub const Window = struct {
    window: ?*c.SDL_Window,
    renderer: ?*c.SDL_Renderer,
    font: ?*c.FC_Font,
    keymap: zs.input.KeyBindings,
    width: c_int,
    height: c_int,
    debug: bool,

    pub fn init(options: Options, keymap: zs.input.KeyBindings) !Window {
        var w = Window{
            .window = null,
            .renderer = null,
            .font = null,
            .keymap = keymap,
            .width = options.width,
            .height = options.height,
            .debug = options.debug,
        };

        try SDL_Check(c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO));
        errdefer c.SDL_Quit();

        try SDL_Check(c.SDL_CreateWindowAndRenderer(
            w.width,
            w.height,
            c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_ALLOW_HIGHDPI,
            &w.window,
            &w.renderer,
        ));
        errdefer c.SDL_DestroyWindow(w.window);

        w.font = c.FC_CreateFont();
        errdefer c.FC_FreeFont(w.font);

        // http://pelulamu.net/unscii/, Public Domain.
        // The stripped variant uses pyftsubset to omit all but the ascii range `--gids=0-128`.
        // TODO: Not the font, tried with open sans. Not embedFile, happens with raw data used in
        // c version.
        const ttf_font = @embedFile("unscii-16.subset.ttf");
        const rwops = c.SDL_RWFromConstMem(&ttf_font[0], ttf_font.len);
        if (c.FC_LoadFont_RW(
            w.font,
            w.renderer,
            rwops,
            1,
            @intCast(c_uint, calcFontSize(w.width)),
            c.FC_MakeColor(200, 200, 200, 255),
            c.TTF_STYLE_NORMAL,
        ) == 0) {
            return error.SDLFontCacheError;
        }

        c.SDL_SetWindowResizable(w.window, c.SDL_bool.SDL_FALSE);
        c.SDL_SetWindowTitle(w.window, c"zstack");
        try SDL_Check(c.SDL_SetRenderDrawColor(w.renderer, 0, 0, 0, 255));
        try SDL_Check(c.SDL_RenderClear(w.renderer));
        c.SDL_RenderPresent(w.renderer);

        return w;
    }

    pub fn deinit(w: Window) void {
        c.FC_FreeFont(w.font);
        c.SDL_DestroyWindow(w.window);
        c.SDL_Quit();
    }

    fn mapKeyToSDLKey(key: Key) c_int {
        return switch (key) {
            .space => c_int(c.SDLK_SPACE),
            .enter => c.SDLK_RETURN,
            .tab => c.SDLK_TAB,
            .right => c.SDLK_RIGHT,
            .left => c.SDLK_LEFT,
            .down => c.SDLK_DOWN,
            .up => c.SDLK_UP,
            .rshift => c.SDLK_RSHIFT,
            .lshift => c.SDLK_LSHIFT,
            .capslock => c.SDLK_CAPSLOCK,
            .comma => c.SDLK_COMMA,
            .period => c.SDLK_PERIOD,
            .slash => c.SDLK_SLASH,
            .semicolon => c.SDLK_SEMICOLON,
            .apostrophe => c.SDLK_QUOTE,
            .lbracket => c.SDLK_LEFTBRACKET,
            .rbracket => c.SDLK_RIGHTBRACKET,
            .backslash => c.SDLK_BACKSLASH,
            .a => c.SDLK_a,
            .b => c.SDLK_b,
            .c => c.SDLK_c,
            .d => c.SDLK_d,
            .e => c.SDLK_e,
            .f => c.SDLK_f,
            .g => c.SDLK_g,
            .h => c.SDLK_h,
            .i => c.SDLK_i,
            .j => c.SDLK_j,
            .k => c.SDLK_k,
            .l => c.SDLK_l,
            .m => c.SDLK_m,
            .n => c.SDLK_n,
            .o => c.SDLK_o,
            .p => c.SDLK_p,
            .q => c.SDLK_q,
            .r => c.SDLK_r,
            .s => c.SDLK_s,
            .t => c.SDLK_t,
            .u => c.SDLK_u,
            .v => c.SDLK_v,
            .w => c.SDLK_w,
            .x => c.SDLK_x,
            .y => c.SDLK_y,
            .z => c.SDLK_z,
        };
    }

    pub fn readKeys(w: *Window) BitSet(VirtualKey) {
        c.SDL_PumpEvents();
        const keystate = c.SDL_GetKeyboardState(null);

        var keys = BitSet(VirtualKey).init();
        for (w.keymap.entries()) |km, i| {
            const from = mapKeyToSDLKey(km);
            if (keystate[@intCast(usize, @enumToInt(c.SDL_GetScancodeFromKey(from)))] != 0) {
                keys.set(VirtualKey.fromIndex(i));
            }
        }

        // Handle window exit request
        if (c.SDL_PeepEvents(null, 0, @intToEnum(c.SDL_eventaction, c.SDL_PEEKEVENT), c.SDL_QUIT, c.SDL_QUIT) > 0) {
            keys.set(.Quit);
        }

        return keys;
    }

    fn renderWell(w: Window, e: zs.Engine) !void {
        const border = c.SDL_Rect{
            .x = @intCast(c_int, len(w, e, .WellX)) - 1,
            .y = @intCast(c_int, len(w, e, .WellY)) - 1,
            .w = @intCast(c_int, len(w, e, .WellW)) + 2,
            .h = @intCast(c_int, len(w, e, .WellH)) + 2,
        };

        try SDL_Check(c.SDL_SetRenderDrawColor(w.renderer, 255, 255, 255, 255));
        try SDL_Check(c.SDL_RenderDrawRect(w.renderer, &border));

        var block = c.SDL_Rect{
            .x = undefined,
            .y = undefined,
            .w = @intCast(c_int, len(w, e, .BlockSide)) + 1,
            .h = @intCast(c_int, len(w, e, .BlockSide)) + 1,
        };

        var y = e.options.well_hidden;
        while (y < e.options.well_height) : (y += 1) {
            block.y = @intCast(c_int, len(w, e, .WellY) + (y - e.options.well_hidden) * len(w, e, .BlockSide));

            var x: usize = 0;
            while (x < e.options.well_width) : (x += 1) {
                block.x = @intCast(c_int, len(w, e, .WellX) + x * len(w, e, .BlockSide));
                if (e.well[y][x] != null) {
                    try SDL_Check(c.SDL_SetRenderDrawColor(w.renderer, stack_color.r, stack_color.g, stack_color.b, stack_color.a));
                    try SDL_Check(c.SDL_RenderFillRect(w.renderer, &block));
                }
            }
        }
    }

    fn renderHoldPiece(w: Window, e: zs.Engine) !void {
        var block = c.SDL_Rect{
            .x = undefined,
            .y = undefined,
            .w = @intCast(c_int, len(w, e, .BlockSide)) + 1,
            .h = @intCast(c_int, len(w, e, .BlockSide)) + 1,
        };

        const id = e.hold_piece orelse return;
        const color = id.color();

        try SDL_Check(c.SDL_SetRenderDrawColor(w.renderer, color.r, color.g, color.b, color.a));

        const bx_off = if (id != .O) len(w, e, .BlockSide) / 2 else 0;
        const by_off = if (id == .I) len(w, e, .BlockSide) / 2 else 0;

        const blocks = e.rotation_system.blocks(id, .R0);
        for (blocks) |b| {
            block.x = @intCast(c_int, bx_off + len(w, e, .HoldX) + b.x * len(w, e, .BlockSide));
            block.y = @intCast(c_int, by_off + len(w, e, .HoldY) + b.y * len(w, e, .BlockSide));
            try SDL_Check(c.SDL_RenderFillRect(w.renderer, &block));
        }
    }

    fn renderCurrentPieceAndShadow(w: Window, e: zs.Engine) !void {
        var block = c.SDL_Rect{
            .x = undefined,
            .y = undefined,
            .w = @intCast(c_int, len(w, e, .BlockSide)) + 1,
            .h = @intCast(c_int, len(w, e, .BlockSide)) + 1,
        };

        const p = e.piece orelse return;
        const color = p.id.color();
        const blocks = e.rotation_system.blocks(p.id, p.theta);

        // Ghost
        if (e.options.show_ghost) {
            for (blocks) |b| {
                const x = @intCast(u8, p.x + @intCast(i8, b.x));
                const y = @intCast(u8, p.y_hard_drop) + b.y - e.options.well_hidden;

                // Filter blocks greater than visible field height
                if (b.y < 0) {
                    continue;
                }

                block.x = @intCast(c_int, len(w, e, .WellX) + x * len(w, e, .BlockSide));
                block.y = @intCast(c_int, len(w, e, .WellY) + y * len(w, e, .BlockSide));

                // Dim ghost color
                try SDL_Check(c.SDL_SetRenderDrawColor(w.renderer, color.r / 2, color.g / 2, color.b / 2, color.a / 2));
                try SDL_Check(c.SDL_RenderFillRect(w.renderer, &block));
            }
        }

        // Piece
        for (blocks) |b| {
            const x = @intCast(u8, p.x + @intCast(i8, b.x));
            // TODO: fix non-zero well_hidden
            const y = p.uy() + b.y - e.options.well_hidden;

            if (y < 0) {
                continue;
            }

            block.x = @intCast(c_int, len(w, e, .WellX) + x * len(w, e, .BlockSide));
            block.y = @intCast(c_int, len(w, e, .WellY) + y * len(w, e, .BlockSide));

            // Slowly dim block to stack color if locking.
            var nc = color;
            if (e.options.lock_delay_ms != 0) {
                const lock_ratio = @intToFloat(f32, p.lock_timer) / @intToFloat(f32, zs.ticks(e.options.lock_delay_ms));
                if (lock_ratio != 0) {
                    inline for (([_][]const u8{ "r", "g", "b" })[0..]) |entry| {
                        if (@field(nc, entry) < @field(stack_color, entry)) {
                            @field(nc, entry) += @floatToInt(u8, @intToFloat(f32, @field(stack_color, entry) - @field(nc, entry)) * lock_ratio);
                        } else {
                            @field(nc, entry) -= @floatToInt(u8, @intToFloat(f32, @field(nc, entry) - @field(stack_color, entry)) * lock_ratio);
                        }
                    }
                }
            }
            if (e.state == .Are and e.options.are_delay_ms != 0) {
                const lock_ratio = @intToFloat(f32, e.are_counter) / @intToFloat(f32, zs.ticks(e.options.are_delay_ms));
                if (lock_ratio != 0) {
                    inline for (([_][]const u8{ "r", "g", "b" })[0..]) |entry| {
                        if (@field(nc, entry) < @field(stack_color, entry)) {
                            @field(nc, entry) += @floatToInt(u8, @intToFloat(f32, @field(stack_color, entry) - @field(nc, entry)) * lock_ratio);
                        } else {
                            @field(nc, entry) -= @floatToInt(u8, @intToFloat(f32, @field(nc, entry) - @field(stack_color, entry)) * lock_ratio);
                        }
                    }
                }
            }

            try SDL_Check(c.SDL_SetRenderDrawColor(w.renderer, nc.r, nc.g, nc.b, nc.a));
            try SDL_Check(c.SDL_RenderFillRect(w.renderer, &block));
        }
    }

    fn renderPreviewPieces(w: Window, e: zs.Engine) !void {
        var block = c.SDL_Rect{
            .x = undefined,
            .y = undefined,
            .w = @intCast(c_int, len(w, e, .BlockSide) + 1),
            .h = @intCast(c_int, len(w, e, .BlockSide) + 1),
        };

        var i: usize = 0;
        while (i < e.options.preview_piece_count) : (i += 1) {
            const id = e.preview_pieces.peek(i);
            const color = id.color();
            const blocks = e.rotation_system.blocks(id, .R0);

            try SDL_Check(c.SDL_SetRenderDrawColor(w.renderer, color.r, color.g, color.b, color.a));

            const by = len(w, e, .PreviewY) + (4 * i) * len(w, e, .BlockSide);
            for (blocks) |b| {
                block.y = @intCast(c_int, by + len(w, e, .BlockSide) * b.y);
                block.x = @intCast(c_int, len(w, e, .PreviewX) + len(w, e, .BlockSide) * b.x);

                switch (id) {
                    .I => block.y -= @intCast(c_int, len(w, e, .BlockSide) / 2),
                    .O => block.x += @intCast(c_int, len(w, e, .BlockSide) / 2),
                    else => {},
                }

                try SDL_Check(c.SDL_RenderFillRect(w.renderer, &block));
            }
        }
    }

    fn renderStatistics(w: Window, e: zs.Engine) !void {
        try renderString(w, 10, 10, "Here is a string: {}", usize(54));
    }

    fn renderString(w: Window, x: usize, y: usize, comptime fmt: []const u8, args: ...) !void {
        var buffer: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(buffer[0..], fmt ++ "\x00", args);

        // TODO: Error here, check line is null terminated?
        const rect = c.FC_Draw(w.font, w.renderer, 10, 50, c"hello"); //line[0..].ptr);
        if (rect.x == 0 and rect.y == 0 and rect.w == 0 and rect.h == 0) {
            return error.SDLFontCacheDrawError;
        }
    }

    fn renderFieldString(w: Window, comptime fmt: []const u8, args: ...) void {
        var buffer: [128]u8 = undefined;
        const line = std.fmt.bufPrint(buffer[0..], fmt ++ "\x00", args);

        const width = c.FC_GetWidth(w.font, line);
        const x = len(w, e, .WellX) + len(w, e, .WellW) / 2 - width / 2;
        const y = len(w, e, .WellY) + len(w, e, .WellH) / 2;

        c.FC_Draw(w.font, w.renderer, x, y, line[0..]);
    }

    fn renderDebug(w: Window, e: zs.Engine) void {
        const ux = w.width * 0.7;
        const uy = 1;

        const elapsed_time = SDL_Ticks();
        const render_fps = elapsed_time / (1000 * e.total_ticks / zs.ticks_per_draw);
        const logic_fps = elapsed_time / (1000 * e.total_ticks);

        const line_skip_y = c.FC_GetLineHeight(w.font);
        const pos_y = 0;

        w.renderString(ux, uy + pos_y * line_skip.uy(), "Render FPS: {.5}", render_fps);
        pos_y += 1;

        w.renderString(ux, uy + pos_y * line_skip.uy(), "Logic GPS: {.5}", logic_fps);
        pos_y += 1;

        w.renderString(ux, uy + pos_y * line_skip.uy(), "Block:");
        pos_y += 1;

        w.renderString(ux, uy + pos_y * line_skip.uy(), "      x: {}", engine.piece_x);
        pos_y += 1;

        w.renderString(ux, uy + pos_y * line_skip.uy(), "      y: {}", engine.piece_y);
        pos_y += 1;

        w.renderString(ux, uy + pos_y * line_skip.uy(), "  theta: {}", engine.piece_theta);
        pos_y += 1;

        w.renderString(ux, uy + pos_y * line_skip.uy(), "  low-y: {}", engine.y_hard_drop);
        pos_y += 1;

        w.renderString(ux, uy + pos_y * line_skip.uy(), "Field:");
        pos_y += 1;

        w.renderString(ux, uy + pos_y * line_skip.uy(), "  gravity: {.3}", engine.gravity);
        pos_y += 1;
    }

    pub fn render(w: Window, e: zs.Engine) !void {
        try SDL_Check(c.SDL_SetRenderDrawColor(w.renderer, 0, 0, 0, 255));
        try SDL_Check(c.SDL_RenderClear(w.renderer));

        try w.renderWell(e);
        try w.renderHoldPiece(e);
        try w.renderCurrentPieceAndShadow(e);
        try w.renderPreviewPieces(e);
        //try w.renderStatistics(e);

        //const rect = c.FC_Draw(w.font, w.renderer, 10, 10, c"hello");

        //switch (e.State) {
        //    .Excellent => w.renderFieldString("EXCELLENT"),
        //    .Ready => w.renderFieldString("READY"),
        //    .Go => w.renderFieldString("GO"),
        //    else => {},
        //}

        //if (w.debug) {
        //    w.renderDebug();
        //}

        c.SDL_RenderPresent(w.renderer);
    }
};
