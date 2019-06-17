const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("zstack", "src/main.zig");
    exe.setBuildMode(mode);

    const use_sdl2 = b.option(bool, "use-sdl2", "Use SDL2 instead of OpenGL (default) for graphics") orelse false;
    exe.addBuildOption(bool, "use_sdl2", use_sdl2);

    b.detectNativeSystemPaths();
    exe.linkSystemLibrary("c");

    if (use_sdl2) {
        exe.linkSystemLibrary("SDL2");
        exe.linkSystemLibrary("SDL2_ttf");

        exe.addIncludeDir("deps/SDL_FontCache");
        exe.addCSourceFile("deps/SDL_FontCache/SDL_FontCache.c", [_][]const u8{});
    } else {
        exe.linkSystemLibrary("glfw");
        exe.linkSystemLibrary("epoxy");

        exe.addIncludeDir("deps/fontstash/src");
        exe.addCSourceFile("deps/fontstash/src/fontstash.c", [_][]const u8{"-Wno-unused-function"});
    }

    exe.setOutputDir(".");

    const run_cmd = exe.run();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    b.default_step.dependOn(&exe.step);
    b.installArtifact(exe);
}
