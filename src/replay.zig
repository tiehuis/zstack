const std = @import("std");
const zs = @import("zstack.zig");

// Puts an upper bound on a game of 49.7 days for 1 ms tick cycle, or 397 days for
// a more usual 8ms tick cycle.
pub const ReplayInput = packed struct {
    tick: u32,
    keys: u32,
};

pub const ReplayInputIterator = struct {
    const Self = @This();

    // Bytes are stored as little-endian.
    raw: []const u8,
    pos: usize,

    pub fn init(bytes: []const u8) !Self {
        if (bytes.len % @sizeOf(ReplayInput) != 0) {
            return error.InvalidInputLength;
        }

        return Self{
            .raw = bytes,
            .pos = 0,
        };
    }

    pub fn next(self: *Self) ?ReplayInput {
        if (self.pos >= self.raw.len) return null;

        const input = ReplayInput{
            .tick = std.mem.readIntSliceLittle(u32, self.raw[self.pos..]),
            .keys = std.mem.readIntSliceLittle(u32, self.raw[self.pos + 4 ..]),
        };

        self.pos += 8;
        return input;
    }
};

// A callback is provided to the engine which is used to periodically dump an array
// of inputs with their tickstamps. This can be used to store the partial data or
// write to disk immediately.
fn replayCallback(inputs: []ReplayInput) void {
    //
}

// We need to serialize the following content for a replay:
//
// - file version
// - random seed
// - game options
// - input sequence
// - statistics
//
// A replay also indicates overall statistics in the same file.

// 1832 01 // Magic number followed by file version
// seed=120397124
// rotation_system=srs // options are specified via key:value pairs, can we re-use config parser?
// <ffff>
// <binary inputs>
// <ffff>
// time_ticks=19383
// kpt=302983
// finesse=34

// Format is as follows:
//
// ```
// ZS1
// seed=12301824
// ```
pub const v1 = struct {
    const header = "ZS1\n";
    const marker = []u8{0xff} ** 8;

    // var r = Reader.init();
    // r.readOptions();
    // var keys = r.readInput(engine.tick);   // return the input for the current tick

    // TODO: Make a Reader and take an instream instead. Can use a SliceInStream if needed.
    pub fn read(options: *zs.Options, inputs: *ReplayInputIterator, game: []const u8) !void {
        if (std.mem.eql(u8, header, game)) {
            return error.InvalidV1Header;
        }

        const maybe_replay_inputs = std.mem.indexOf(u8, game, marker);
        const replay_inputs = maybe_replay_inputs orelse return error.NoInputsFound;

        const replay_options = game[header.len..replay_inputs];
        try zs.config.parseIni(options, replay_options);

        inputs.* = try ReplayInputIterator.init(game[replay_inputs + marker.len ..]);
    }

    pub fn Writer(comptime Error: type) type {
        return struct {
            const Self = @This();

            stream: *std.io.OutStream(Error),
            last_keys: u32,

            pub fn init(stream: *std.io.OutStream(Error)) Self {
                return Self{ .stream = stream, .last_keys = std.math.maxInt(u32) };
            }

            pub fn writeHeader(self: Self, options: zs.Options) !void {
                try self.stream.write(header);

                // write options
                // TODO: Don't require [game] header if possible
                try self.stream.print("[game]\n");
                inline for (@typeInfo(@typeOf(options)).Struct.fields) |field| {
                    switch (@typeInfo(field.field_type)) {
                        .Enum => {
                            try self.stream.print("{}={}\n", field.name, @tagName(@field(options, field.name)));
                        },
                        else => {
                            try self.stream.print("{}={}\n", field.name, @field(options, field.name));
                        },
                    }
                }

                try self.stream.writeIntLittle(u32, 0xffffffff); // tick marker
                try self.stream.writeIntLittle(u32, 0xffffffff); // keys marker
            }

            pub fn writeInputs(self: Self, inputs: []const ReplayInput) !void {
                for (inputs) |input| {
                    try self.stream.writeIntLittle(u32, input.tick);
                    try self.stream.writeIntLittle(u32, input.keys);
                }
            }

            pub fn writeKeys(self: Self, tick: u32, keys: u32) !void {
                if (keys != self.last_keys) {
                    try self.stream.writeIntLittle(u32, tick);
                    try self.stream.writeIntLittle(u32, keys);
                    self.last_keys = keys;
                }
            }
        };
    }
};

test "v1.read" {
    const game_replay =
        \\ZS1
        \\;TODO: Handle no group specification or don't use ini parser
        \\[game]
        \\rotation_system =dtet
        \\goal=10
    ++ v1.marker ++ "\x12\x03\x00\x00\x98\x01\x00\x30";

    var options = zs.Options{};
    var inputs: ReplayInputIterator = undefined;

    try v1.read(&options, &inputs, game_replay);

    std.testing.expectEqual(options.rotation_system, .dtet);
    std.testing.expectEqual(options.goal, 10);

    const expected_inputs = []ReplayInput{ReplayInput{ .tick = 786, .keys = 0x30000198 }};
    var i: usize = 0;

    while (inputs.next()) |input| {
        std.testing.expect(i < expected_inputs.len);

        std.testing.expectEqual(input.tick, expected_inputs[i].tick);
        std.testing.expectEqual(input.keys, expected_inputs[i].keys);
        i += 1;
    }

    std.testing.expectEqual(i, expected_inputs.len);
}

test "v1.write" {
    const options = zs.Options{};
    const inputs = []ReplayInput{ReplayInput{ .tick = 786, .keys = 0x30000198 }};

    var storage: [1024]u8 = undefined;
    var slice_out_stream = std.io.SliceOutStream.init(storage[0..]);

    var writer = v1.Writer(std.io.SliceOutStream.Error).init(&slice_out_stream.stream);
    try writer.writeHeader(options);
    try writer.writeInputs(inputs[0..]);

    const replay_output = slice_out_stream.getWritten();

    var read_options: zs.Options = undefined;
    var read_inputs: ReplayInputIterator = undefined;
    try v1.read(&read_options, &read_inputs, replay_output);

    inline for (@typeInfo(zs.Options).Struct.fields) |field| {
        std.testing.expectEqual(@field(read_options, field.name), @field(options, field.name));
    }

    var i: usize = 0;
    while (read_inputs.next()) |read_input| {
        std.testing.expectEqual(read_input.tick, inputs[i].tick);
        std.testing.expectEqual(read_input.keys, inputs[i].keys);
        i += 1;
    }
}

// TODO: Statistics are stored separately and point to a filename. We can then
// merge all hiscore details into a single file.
