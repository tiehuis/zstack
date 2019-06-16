// stb_truetype for font rendering
// stb_vorbis for audio if we do want

const std = @import("std");
const c = @cImport({
    @cInclude("epoxy/gl.h"); // Include statically if possible
    @cInclude("GLFW/glfw3.h"); // Redo build script so it is in zig and cross-platform

    @cInclude("fontstash.h");
    @cInclude("gl3corefontstash.h");
});
const zs = @import("zstack.zig");

const Piece = zs.Piece;
const BitSet = zs.BitSet;
const VirtualKey = zs.input.VirtualKey;
const Key = zs.input.Key;

const debug_opengl = true;

const stack_color = zs.piece.Color{
    .r = 140,
    .g = 140,
    .b = 140,
    .a = 255,
};
const well_color = zs.piece.Color{
    .r = 180,
    .g = 180,
    .b = 180,
    .a = 255,
};

fn checkShader(id: c_uint, status_type: c_uint) !void {
    var status: c_int = undefined;
    var buffer = [_]u8{0} ** 512;

    c.glGetShaderiv(id, status_type, &status);
    if (status != c.GL_TRUE) {
        c.glGetShaderInfoLog(id, buffer.len - 1, null, &buffer[0]);
        std.debug.warn("{}\n", buffer[0..]);
        return error.GlShaderError;
    }
}

fn checkProgram(id: c_uint, status_type: c_uint) !void {
    var status: c_int = undefined;
    var buffer = [_]u8{0} ** 512;

    c.glGetProgramiv(id, status_type, &status);
    if (status != c.GL_TRUE) {
        c.glGetProgramInfoLog(id, buffer.len - 1, null, &buffer[0]);
        std.debug.warn("{}\n", buffer[0..]);
        return error.GlProgramError;
    }
}

fn getUniform(id: c_uint, name: [*c]const u8) !c_int {
    const uniform_id = c.glGetUniformLocation(id, name);
    if (uniform_id == -1) {
        return error.GlUniformError;
    }
    return uniform_id;
}

fn getAttribute(id: c_uint, name: [*c]const u8) !c_uint {
    const attr_id = c.glGetAttribLocation(id, name);
    if (attr_id == -1) {
        return error.GlAttribError;
    }
    return @intCast(c_uint, attr_id);
}

extern fn glDebugCallback(
    source: c.GLenum,
    ty: c.GLenum,
    id: c.GLuint,
    severity: c.GLenum,
    length: c.GLsizei,
    message: [*c]const u8,
    user_param: ?*const c_void,
) void {
    std.debug.warn("{}: {}: {}\n", source, id, message[0..@intCast(usize, length)]);
}

const offsets = struct {
    // Block width is doubled since this viewport is (-1, 1)
    const block_width: f32 = 0.02625;

    const hold_x: f32 = 0.1;
    const hold_y: f32 = 0.1;

    const well_x: f32 = hold_x + 5.0 * block_width;
    const well_y: f32 = 0.1;
    const well_h: f32 = 0.7;
    const well_w: f32 = 10.0 * block_width; // TODO: Varies based on engine width

    // width of well is dependent on the usual width, but assume 10.
    const preview_x: f32 = well_x + well_w + block_width;
    const preview_y: f32 = 0.1;
};

// TODO: Need a quad and/or a uniform to disable all lighting. Take
// a bool to the shader?

// Draw an aribtrary quadrilateral aligned to the x, y plane.
const gl_quad = struct {
    // Our offsets are percentages so assume a (0, 1) coordinate system.
    // Also includes face normals. TODO: orient so front-facing correctly.
    // (x, y, z, N_x, N_y, N_z),
    const vertices = [_]c.GLfloat{
        // Face 1 (Front)
        0, 0, 0, 0,  0,  -1,
        0, 1, 0, 0,  0,  -1,
        1, 0, 0, 0,  0,  -1,
        1, 0, 0, 0,  0,  -1,
        0, 1, 0, 0,  0,  -1,
        1, 1, 0, 0,  0,  -1,
        // Face 2 (Rear)
        0, 0, 1, 0,  0,  1,
        1, 0, 1, 0,  0,  1,
        1, 1, 1, 0,  0,  1,
        1, 1, 1, 0,  0,  1,
        0, 1, 1, 0,  0,  1,
        1, 1, 1, 0,  0,  1,
        // Face 3 (Left)
        0, 0, 0, -1, 0,  0,
        0, 1, 0, -1, 0,  0,
        0, 0, 1, -1, 0,  0,
        0, 0, 1, -1, 0,  0,
        0, 1, 0, -1, 0,  0,
        0, 1, 1, -1, 0,  0,
        // Face 4 (Right)
        1, 0, 0, 1,  0,  0,
        1, 1, 0, 1,  0,  0,
        1, 0, 1, 1,  0,  0,
        1, 0, 1, 1,  0,  0,
        1, 1, 0, 1,  0,  0,
        1, 1, 1, 1,  0,  0,
        // Face 5 (Bottom)
        0, 0, 0, 0,  -1, 0,
        0, 0, 1, 0,  -1, 0,
        1, 0, 0, 0,  -1, 0,
        1, 0, 0, 0,  -1, 0,
        1, 0, 0, 0,  -1, 0,
        1, 0, 1, 0,  -1, 0,
        // Face 6 (Top)
        0, 1, 0, 0,  1,  0,
        0, 1, 1, 0,  1,  0,
        1, 1, 0, 0,  1,  0,
        1, 1, 0, 0,  1,  0,
        1, 1, 0, 0,  1,  0,
        1, 1, 1, 0,  1,  0,
    };

    var vao_id: c_uint = undefined;
    var vbo_id: c_uint = undefined;

    var vertex_shader_id: c_uint = undefined;
    var fragment_shader_id: c_uint = undefined;

    var program_id: c_uint = undefined;

    // vertex shader
    var attr_position: c_uint = undefined;
    var attr_face_normal: c_uint = undefined;
    var uniform_offset: c_int = undefined;
    var uniform_scale: c_int = undefined;
    var uniform_viewport: c_int = undefined;

    // fragment shader
    var attr_normal: c_uint = undefined;
    var attr_frag_pos: c_uint = undefined;
    var uniform_view_pos: c_int = undefined;
    var uniform_surface_color: c_int = undefined;
    var uniform_light_color: c_int = undefined;
    var uniform_light_pos: c_int = undefined;
    var uniform_enable_lighting: c_int = undefined;

    pub fn init(options: Options) !void {
        const vertex_shader_source =
            c\\#version 150 core
            c\\
            c\\in vec3 position;
            c\\in vec3 faceNormal;
            c\\
            c\\out vec3 normal;
            c\\out vec3 fragPos;
            c\\
            c\\uniform vec2 offset;
            c\\uniform mat3 scale;
            c\\uniform mat4 viewport;
            c\\
            c\\void main()
            c\\{
            c\\  //fragPos = vec3(viewport * vec4(position, 1.0));
            c\\  //normal = mat3(transpose(inverse(viewport))) * faceNormal;
            c\\
            c\\  gl_Position = vec4(position, 1.0) * mat4(scale);
            c\\  gl_Position.x += offset.x;
            c\\  gl_Position.y += offset.y;
            c\\  gl_Position = gl_Position * viewport;
            c\\
            c\\  fragPos = vec3(gl_Position);
            c\\  normal = faceNormal;
            c\\}
        ;

        vertex_shader_id = c.glCreateShader(c.GL_VERTEX_SHADER);
        errdefer c.glDeleteShader(vertex_shader_id);

        c.glShaderSource(vertex_shader_id, 1, &vertex_shader_source, null);
        c.glCompileShader(vertex_shader_id);
        try checkShader(vertex_shader_id, c.GL_COMPILE_STATUS);

        const fragment_shader_source =
            c\\#version 150 core
            c\\
            c\\out vec4 outColor;
            c\\
            c\\in vec3 normal;
            c\\in vec3 fragPos;
            c\\
            c\\uniform vec3 viewPos;
            c\\uniform vec3 surfaceColor;
            c\\uniform vec3 lightColor;
            c\\uniform vec3 lightPos;
            c\\uniform bool enableLighting;
            c\\
            c\\void main()
            c\\{
            c\\  if (!enableLighting) {
            c\\     outColor = vec4(surfaceColor, 1.0);
            c\\  } else {
            c\\     float ambientStrength = 0.7;
            c\\     vec3 ambient = ambientStrength * lightColor;
            c\\
            c\\     vec3 norm = normalize(normal);
            c\\     vec3 lightDir = normalize(lightPos - fragPos);
            c\\     float diff = max(dot(norm, lightDir), 0.0);
            c\\     vec3 diffuse = diff * lightColor;
            c\\
            c\\     float specularStrength = 0.5;
            c\\     vec3 viewDir = normalize(viewPos - fragPos);
            c\\     vec3 reflectDir = reflect(-lightDir, norm);
            c\\     float spec = pow(max(dot(viewDir, reflectDir), 0.0), 32);
            c\\     vec3 specular = specularStrength * spec * lightColor;
            c\\
            c\\     vec3 result = (ambient + diffuse + specular) * surfaceColor;
            c\\     outColor = vec4(result, 1.0);
            c\\  }
            c\\}
        ;

        fragment_shader_id = c.glCreateShader(c.GL_FRAGMENT_SHADER);
        errdefer c.glDeleteShader(fragment_shader_id);

        c.glShaderSource(fragment_shader_id, 1, &fragment_shader_source, null);
        c.glCompileShader(fragment_shader_id);
        try checkShader(fragment_shader_id, c.GL_COMPILE_STATUS);

        program_id = c.glCreateProgram();
        errdefer c.glDeleteProgram(program_id);

        c.glAttachShader(program_id, vertex_shader_id);
        c.glAttachShader(program_id, fragment_shader_id);
        c.glLinkProgram(program_id);
        try checkProgram(program_id, c.GL_LINK_STATUS);

        // Only have one program, don't bother using anywhere else.
        c.glUseProgram(program_id);

        // vertex shader
        attr_position = try getAttribute(program_id, c"position");
        attr_face_normal = try getAttribute(program_id, c"faceNormal");
        uniform_offset = try getUniform(program_id, c"offset");
        uniform_scale = try getUniform(program_id, c"scale");
        uniform_viewport = try getUniform(program_id, c"viewport");

        // fragment shader
        uniform_view_pos = try getUniform(program_id, c"viewPos");
        uniform_surface_color = try getUniform(program_id, c"surfaceColor");
        uniform_light_color = try getUniform(program_id, c"lightColor");
        uniform_light_pos = try getUniform(program_id, c"lightPos");
        uniform_enable_lighting = try getUniform(program_id, c"enableLighting");

        c.glGenVertexArrays(1, &vao_id);
        errdefer c.glDeleteVertexArrays(1, &vao_id);

        c.glGenBuffers(1, &vbo_id);
        errdefer c.glDeleteBuffers(1, &vbo_id);

        c.glBindVertexArray(vao_id);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, vbo_id);
        c.glBufferData(c.GL_ARRAY_BUFFER, vertices.len * @sizeOf(c.GLfloat), &vertices[0], c.GL_STATIC_DRAW);

        c.glVertexAttribPointer(attr_position, 3, c.GL_FLOAT, c.GL_FALSE, 6 * @sizeOf(c.GLfloat), null);
        c.glEnableVertexAttribArray(attr_position);
        c.glVertexAttribPointer(attr_face_normal, 3, c.GL_FLOAT, c.GL_FALSE, 6 * @sizeOf(c.GLfloat), null);
        c.glEnableVertexAttribArray(attr_face_normal);

        // Always bound, only use the one vertex array
        c.glBindVertexArray(vao_id);

        // Fixed viewport for now
        if (options.render_3d) {
            const viewport = [_]f32{
                1, 0, 0.5, 0,
                0, 1, 0.3, 0,
                0, 0, 1,   0,
                0, 0, 0,   1,
            };
            c.glUniformMatrix4fv(uniform_viewport, 1, c.GL_FALSE, &viewport[0]);
        } else {
            const viewport = [_]f32{
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1,
            };
            c.glUniformMatrix4fv(uniform_viewport, 1, c.GL_FALSE, &viewport[0]);
        }

        // Fixed light color for now
        c.glUniform3f(uniform_light_color, 0.5, 0.5, 0.5);
        c.glUniform3f(uniform_light_pos, 0.5, 0.5, 0.5);

        // Fixed camera position
        c.glUniform3f(uniform_view_pos, 0.5, 0.5, 0.5);

        // Enable lighting
        c.glUniform1i(uniform_enable_lighting, @boolToInt(options.render_lighting));
    }

    pub fn deinit() void {
        c.glDeleteProgram(program_id);
        c.glDeleteShader(fragment_shader_id);
        c.glDeleteShader(vertex_shader_id);
        c.glDeleteBuffers(1, &vbo_id);
        c.glDeleteVertexArrays(1, &vao_id);
    }

    pub fn setColor(r: u8, g: u8, b: u8) void {
        const x = @intToFloat(c.GLfloat, r) / 255.0;
        const y = @intToFloat(c.GLfloat, g) / 255.0;
        const z = @intToFloat(c.GLfloat, b) / 255.0;
        c.glUniform3f(uniform_surface_color, x, y, z);
    }

    pub fn setScale(x: f32, y: f32, z: f32) void {
        std.debug.assert(0.0 <= x and x <= 1.0);
        std.debug.assert(0.0 <= y and y <= 1.0);
        std.debug.assert(0.0 <= z and z <= 1.0);

        var scale_matrix = [_]f32{
            2 * x, 0,     0,
            0,     2 * y, 0,
            0,     0,     2 * z,
        };

        c.glUniformMatrix3fv(uniform_scale, 1, c.GL_FALSE, &scale_matrix[0]);
    }

    pub fn draw(
        x: f32,
        y: f32,
        // TODO: Fix zig-fmt case here, indent enum content once more (and this doc-comment).
        //    comptime fill: enum {
        //    Fill,
        //    Frame,
        //},
    ) void {
        std.debug.assert(0.0 <= x and x <= 1.0);
        std.debug.assert(0.0 <= y and y <= 1.0);

        // Normalize window (x, y) to (-1, 1) system. We need to invert the
        // y-axis since the window starts with (0, 0) at the top-left.
        const norm_x = 2 * x - 1;
        const norm_y = -(2 * y - 1);

        c.glUniform2f(uniform_offset, norm_x, norm_y);

        // TODO: Actually, we need a lightsource at a pre-defined location so depth can be
        // properly visible.
        c.glDrawArrays(c.GL_TRIANGLES, 0, vertices.len / 6);
    }
};

pub const Options = struct {
    width: c_int = 640,
    height: c_int = 480,
    render_3d: bool = false,
    render_lighting: bool = false,
    debug: bool = true,
};

// Need copy-elision to avoid this. Or, pass the window and init that way. Kind of annoying.
var actual_keymap: zs.input.KeyBindings = undefined;

pub const Window = struct {
    window: ?*c.GLFWwindow,
    font: ?*c.FONScontext,
    keymap: zs.input.KeyBindings,
    width: c_int,
    height: c_int,
    debug: bool,

    pub fn init(options: Options, keymap: zs.input.KeyBindings) !Window {
        var w = Window{
            .window = null,
            .font = null,
            .keymap = keymap,
            .width = options.width,
            .height = options.height,
            .debug = options.debug,
        };
        // TODO: Pass as glfw user window data, see above.
        actual_keymap = keymap;

        if (c.glfwInit() == 0) {
            return error.GlfwError;
        }
        errdefer c.glfwTerminate();

        // Target OpenGL 3.2 Core Profile.
        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 2);
        c.glfwWindowHint(c.GLFW_OPENGL_PROFILE, c.GLFW_OPENGL_CORE_PROFILE);
        c.glfwWindowHint(c.GLFW_OPENGL_FORWARD_COMPAT, c.GL_TRUE);
        c.glfwWindowHint(c.GLFW_RESIZABLE, c.GL_FALSE);

        // We use OpenGL as a 2-D view so don't need any depth.
        //c.glfwWindowHint(c.GLFW_DEPTH_BITS, 0);
        //c.glfwWindowHint(c.GLFW_STENCIL_BITS, 0);

        if (debug_opengl) {
            c.glfwWindowHint(c.GLFW_OPENGL_DEBUG_CONTEXT, c.GL_TRUE);
        }

        w.window = c.glfwCreateWindow(w.width, w.height, c"zstack", null, null);
        if (w.window == null) {
            return error.GlfwError;
        }
        errdefer c.glfwDestroyWindow(w.window);

        c.glfwMakeContextCurrent(w.window);
        _ = c.glfwSetKeyCallback(w.window, keyCallback);
        c.glfwSwapInterval(0);

        if (debug_opengl) {
            c.glDebugMessageCallback(glDebugCallback, null);
            c.glDebugMessageControl(c.GL_DONT_CARE, c.GL_DONT_CARE, c.GL_DONT_CARE, 0, null, c.GL_TRUE);
        }

        c.glClearColor(0, 0, 0, 1);
        c.glClear(c.GL_COLOR_BUFFER_BIT);

        if (false) {
            w.font = c.glfonsCreate(512, 512, @enumToInt(c.FONS_ZERO_TOPLEFT));
            if (w.font == null) {
                return error.FontStashError;
            }

            var ttf_font = []const u8{}; //@embedFile("unscii-16.ttf");
            const font_id = c.fonsAddFontMem(
                w.font,
                c"unscii",
                &ttf_font[0],
                ttf_font.len,
                0,
            );
            if (font_id == c.FONS_INVALID) {
                return error.FontStashError;
            }
            c.fonsSetFont(w.font, font_id);
            c.fonsSetSize(w.font, 12);
            c.fonsSetColor(w.font, c.glfonsRGBA(255, 255, 255, 255));
        }

        try gl_quad.init(options);

        if (debug_opengl) {
            //c.glPolygonMode(c.GL_FRONT_AND_BACK, c.GL_LINE);
        }

        return w;
    }

    pub fn deinit(w: Window) void {
        gl_quad.deinit();
        c.glfwDestroyWindow(w.window);
        c.glfwTerminate();
    }

    fn mapKeyToGlfwKey(key: Key) c_int {
        // TODO: This switch doesn't compile correctly in release fast?
        return switch (key) {
            .space => c_int(c.GLFW_KEY_SPACE),
            .enter => c.GLFW_KEY_ENTER,
            .tab => c.GLFW_KEY_TAB,
            .right => c.GLFW_KEY_RIGHT,
            .left => c.GLFW_KEY_LEFT,
            .down => c.GLFW_KEY_DOWN,
            .up => c.GLFW_KEY_UP,
            .rshift => c.GLFW_KEY_RIGHT_SHIFT,
            .lshift => c.GLFW_KEY_LEFT_SHIFT,
            .capslock => c.GLFW_KEY_CAPS_LOCK,
            .comma => c.GLFW_KEY_COMMA,
            .period => c.GLFW_KEY_PERIOD,
            .slash => c.GLFW_KEY_SLASH,
            .semicolon => c.GLFW_KEY_SEMICOLON,
            .apostrophe => c.GLFW_KEY_APOSTROPHE,
            .lbracket => c.GLFW_KEY_LEFT_BRACKET,
            .rbracket => c.GLFW_KEY_RIGHT_BRACKET,
            .backslash => c.GLFW_KEY_BACKSLASH,
            .a => c.GLFW_KEY_A,
            .b => c.GLFW_KEY_B,
            .c => c.GLFW_KEY_C,
            .d => c.GLFW_KEY_D,
            .e => c.GLFW_KEY_E,
            .f => c.GLFW_KEY_F,
            .g => c.GLFW_KEY_G,
            .h => c.GLFW_KEY_H,
            .i => c.GLFW_KEY_I,
            .j => c.GLFW_KEY_J,
            .k => c.GLFW_KEY_K,
            .l => c.GLFW_KEY_L,
            .m => c.GLFW_KEY_M,
            .n => c.GLFW_KEY_N,
            .o => c.GLFW_KEY_O,
            .p => c.GLFW_KEY_P,
            .q => c.GLFW_KEY_Q,
            .r => c.GLFW_KEY_R,
            .s => c.GLFW_KEY_S,
            .t => c.GLFW_KEY_T,
            .u => c.GLFW_KEY_U,
            .v => c.GLFW_KEY_V,
            .w => c.GLFW_KEY_W,
            .x => c.GLFW_KEY_X,
            .y => c.GLFW_KEY_Y,
            .z => c.GLFW_KEY_Z,
        };
    }

    var keys_pressed = BitSet(VirtualKey).init();

    extern fn keyCallback(window: ?*c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) void {
        if (c.glfwGetWindowAttrib(window, c.GLFW_FOCUSED) == 0) {
            return;
        }

        for (actual_keymap.entries()) |km, i| {
            if (key == mapKeyToGlfwKey(km)) {
                const to = VirtualKey.fromIndex(i);
                switch (action) {
                    c.GLFW_PRESS => keys_pressed.set(to),
                    c.GLFW_RELEASE => keys_pressed.clear(to),
                    else => {},
                }
                break;
            }
        }
    }

    pub fn readKeys(w: *Window) BitSet(VirtualKey) {
        c.glfwPollEvents();

        var keys = keys_pressed;
        if (c.glfwWindowShouldClose(w.window) != 0) {
            keys.set(.Quit);
        }

        return keys;
    }

    fn renderWell(w: Window, e: zs.Engine) void {
        // TODO: Decide on the format to use (0, 1) (-1, 1), (0, w) and use that everywhere
        // instead of converting here and there.
        //
        // Well border. This is not a one-pixel rectangle but instead made up of 3 3-dimensional
        // planes (think a box with a missing back/front/top.
        //
        // TODO: We can maybe add a back into the well, but adjust the color and check shading.
        const well_thickness = offsets.block_width * 0.1;
        gl_quad.setColor(well_color.r, well_color.g, well_color.b);

        // Sides
        gl_quad.setScale(
            well_thickness,
            offsets.block_width * @intToFloat(f32, e.options.well_height),
            offsets.block_width,
        );
        gl_quad.draw(
            offsets.well_x - well_thickness,
            offsets.well_y + offsets.block_width * @intToFloat(f32, e.options.well_height - 1),
        );
        gl_quad.draw(
            offsets.well_x + 10 * offsets.block_width,
            offsets.well_y + offsets.block_width * @intToFloat(f32, e.options.well_height - 1),
        );
        // Bottom
        gl_quad.setScale(
            offsets.well_w,
            well_thickness,
            offsets.block_width,
        );
        gl_quad.draw(
            offsets.well_x,
            offsets.well_y + offsets.block_width * @intToFloat(f32, e.options.well_height - 1) + well_thickness,
        );

        gl_quad.setColor(stack_color.r, stack_color.g, stack_color.b);
        gl_quad.setScale(offsets.block_width, offsets.block_width, offsets.block_width);

        var y = e.options.well_hidden;
        while (y < e.options.well_height) : (y += 1) {
            const block_y = offsets.well_y + offsets.block_width * @intToFloat(f32, y - e.options.well_hidden);

            var x: usize = 0;
            while (x < e.options.well_width) : (x += 1) {
                const block_x = offsets.well_x + offsets.block_width * @intToFloat(f32, x);

                if (e.well[y][x] != null) {
                    gl_quad.draw(block_x, block_y);
                }
            }
        }
    }

    fn renderHoldPiece(w: Window, e: zs.Engine) void {
        const id = e.hold_piece orelse return;
        const color = id.color();

        gl_quad.setScale(offsets.block_width, offsets.block_width, offsets.block_width);
        gl_quad.setColor(color.r, color.g, color.b);

        const bx_off = if (id != .O) offsets.block_width / 2.0 else 0.0;
        const by_off = if (id == .I) offsets.block_width / 2.0 else 0.0;

        const blocks = e.rotation_system.blocks(id, .R0);
        for (blocks) |b| {
            const block_x = bx_off + offsets.hold_x + offsets.block_width * @intToFloat(f32, b.x);
            const block_y = by_off + offsets.hold_y + offsets.block_width * @intToFloat(f32, b.y);
            gl_quad.draw(block_x, block_y);
        }
    }

    fn renderCurrentPieceAndShadow(w: Window, e: zs.Engine) void {
        const p = e.piece orelse return;
        const color = p.id.color();
        const blocks = e.rotation_system.blocks(p.id, p.theta);

        gl_quad.setScale(offsets.block_width, offsets.block_width, offsets.block_width);
        // Dim ghost color
        gl_quad.setColor(color.r / 2, color.g / 2, color.b / 2);

        // Ghost
        if (e.options.show_ghost) {
            for (blocks) |b| {
                const x = @intCast(u8, p.x + @intCast(i8, b.x));
                const y = @intCast(u8, p.y_hard_drop) + b.y - e.options.well_hidden;

                // Filter blocks greater than visible field height
                if (b.y < 0) {
                    continue;
                }

                const block_x = offsets.well_x + offsets.block_width * @intToFloat(f32, x);
                const block_y = offsets.well_y + offsets.block_width * @intToFloat(f32, y);

                gl_quad.draw(block_x, block_y);
            }
        }

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
        // Slowly dim block if in ARE state.
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
        gl_quad.setColor(nc.r, nc.g, nc.b);

        // Piece
        for (blocks) |b| {
            const x = @intCast(u8, p.x + @intCast(i8, b.x));
            // TODO: fix non-zero well_hidden
            const y = p.uy() + b.y - e.options.well_hidden;

            if (y < 0) {
                continue;
            }

            const block_x = offsets.well_x + offsets.block_width * @intToFloat(f32, x);
            const block_y = offsets.well_y + offsets.block_width * @intToFloat(f32, y);

            gl_quad.draw(block_x, block_y);
        }
    }

    fn renderPreviewPieces(w: Window, e: zs.Engine) void {
        gl_quad.setScale(offsets.block_width, offsets.block_width, offsets.block_width);

        var i: usize = 0;
        while (i < e.options.preview_piece_count) : (i += 1) {
            const id = e.preview_pieces.peek(i);
            const color = id.color();
            const blocks = e.rotation_system.blocks(id, .R0);

            gl_quad.setColor(color.r, color.g, color.b);

            const by = offsets.preview_y + offsets.block_width * @intToFloat(f32, 4 * i);
            for (blocks) |b| {
                var block_x = offsets.preview_x + offsets.block_width * @intToFloat(f32, b.x);
                var block_y = by + offsets.block_width * @intToFloat(f32, b.y);

                switch (id) {
                    .I => block_y -= offsets.block_width / 2.0,
                    .O => block_x += offsets.block_width / 2.0,
                    else => {},
                }

                gl_quad.draw(block_x, block_y);
            }
        }
    }

    fn renderString(w: Window, x: usize, y: usize, comptime fmt: []const u8, args: ...) !void {
        var buffer: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(buffer[0..], fmt ++ "\x00", args);
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

        const elapsed_time = 0;
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

    pub fn render(w: Window, e: zs.Engine) error{}!void {
        c.glClearColor(0, 0, 0, 1);
        c.glClear(c.GL_COLOR_BUFFER_BIT);

        w.renderWell(e);
        w.renderHoldPiece(e);
        w.renderCurrentPieceAndShadow(e);
        w.renderPreviewPieces(e);
        //try w.renderStatistics(e);

        if (false) {
            const text = "Here is some text";
            _ = c.fonsDrawText(w.font, 10, 10, &text[0], text.len);
        }

        //switch (e.State) {
        //    .Excellent => w.renderFieldString("EXCELLENT"),
        //    .Ready => w.renderFieldString("READY"),
        //    .Go => w.renderFieldString("GO"),
        //    else => {},
        //}

        //if (w.debug) {
        //    w.renderDebug();
        //}

        c.glfwSwapBuffers(w.window);
    }
};
