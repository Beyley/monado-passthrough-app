const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const src = b.path("src");

    const sdl_include = b.dependency("SDL", .{}).path("include");

    const translate_c = b.addTranslateC(.{
        .link_libc = true,
        .optimize = optimize,
        .target = target,
        .root_source_file = src.path(b, "c.h"),
    });
    translate_c.addIncludePath(sdl_include);

    const translate_c_mod = translate_c.createModule();

    const exe_mod = b.createModule(.{
        .root_source_file = src.path(b, "main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "c",
                .module = translate_c_mod,
            },
        },
        .link_libc = true,
    });
    exe_mod.linkSystemLibrary("SDL3", .{});
    exe_mod.linkSystemLibrary("openxr_loader", .{});

    const exe = b.addExecutable(.{
        .name = "monado-passthrough-app",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);
}
