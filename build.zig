const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const regex_mod = b.dependency("regex", .{ .target = target, .optimize = optimize }).module("regex");

    // CLI executable
    const exe = b.addExecutable(.{
        .name = "hound",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "regex", .module = regex_mod }},
        }),
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
    const lib = b.addLibrary(.{
        .name = "hound",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "regex", .module = regex_mod }},
        }),
    });
    lib.linkLibC();
    b.installArtifact(lib);

    // C API static library
    const c_lib_static = b.addLibrary(.{
        .name = "hound_c",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "regex", .module = regex_mod }},
        }),
    });
    c_lib_static.linkLibC();
    b.installArtifact(c_lib_static);

    // C API shared library
    const c_lib_shared = b.addLibrary(.{
        .name = "hound_c",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "regex", .module = regex_mod }},
        }),
    });
    c_lib_shared.linkLibC();
    b.installArtifact(c_lib_shared);

    // Install the C header
    const install_header = b.addInstallFile(b.path("include/hound.h"), "include/hound.h");
    b.getInstallStep().dependOn(&install_header.step);

    // Unit tests
    const lib_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "regex", .module = regex_mod }},
        }),
    });
    lib_unit_tests.linkLibC();

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // C API tests - run after lib_unit_tests to avoid path conflicts
    // (both test binaries include tests from shared modules that use the same /tmp paths)
    const c_api_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "regex", .module = regex_mod }},
        }),
    });
    c_api_tests.linkLibC();
    const run_c_api_tests = b.addRunArtifact(c_api_tests);
    run_c_api_tests.step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_c_api_tests.step);

    // Library module for examples
    const hound_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{.{ .name = "regex", .module = regex_mod }},
    });

    // Segment demo
    const segment_demo = b.addExecutable(.{
        .name = "segment_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/segment_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "hound", .module = hound_mod }},
        }),
    });

    const run_segment_demo = b.addRunArtifact(segment_demo);
    const demo_step = b.step("demo", "Run segment architecture demo");
    demo_step.dependOn(&run_segment_demo.step);
}
