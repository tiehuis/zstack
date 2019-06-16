const Builder = @import("std").build.Builder;

const use_opengl = true;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("zstack", "src/main.zig");
    exe.setBuildMode(mode);

    b.detectNativeSystemPaths();
    exe.linkSystemLibrary("c");

    const c_flags = [_][]const u8{ "-Wall", "-O2", "-g" };

    if (!use_opengl) {
        exe.linkSystemLibrary("SDL2");
        exe.linkSystemLibrary("SDL2_ttf");

        exe.addIncludeDir("deps/SDL_FontCache");
        exe.addCSourceFile("deps/SDL_FontCache/SDL_FontCache.c", c_flags);
    } else {
        exe.linkSystemLibrary("glfw");
        exe.linkSystemLibrary("epoxy");

        exe.addIncludeDir("deps/fontstash/src");
        exe.addCSourceFile("deps/fontstash/src/fontstash.c", c_flags ++ [_][]const u8{"-Wno-unused-function"});
    }

    exe.setOutputDir(".");

    const run_cmd = exe.run();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    b.default_step.dependOn(&exe.step);
    b.installArtifact(exe);
}
