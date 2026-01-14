const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // CLI executable
    const exe = b.addExecutable(.{
        .name = "hound",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the hound CLI");
    run_step.dependOn(&run_cmd.step);

    // Zig library (for Zig consumers)
    const lib = b.addStaticLibrary(.{
        .name = "hound",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    // C API static library
    const c_lib_static = b.addStaticLibrary(.{
        .name = "hound_c",
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    c_lib_static.linkLibC();
    b.installArtifact(c_lib_static);

    // C API shared library
    const c_lib_shared = b.addSharedLibrary(.{
        .name = "hound_c",
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    c_lib_shared.linkLibC();
    b.installArtifact(c_lib_shared);

    // Install the C header
    const install_header = b.addInstallFile(b.path("include/hound.h"), "include/hound.h");
    b.getInstallStep().dependOn(&install_header.step);

    // Unit tests
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // C API tests
    const c_api_tests = b.addTest(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_c_api_tests = b.addRunArtifact(c_api_tests);
    test_step.dependOn(&run_c_api_tests.step);
}
