const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module
    const uzon_mod = b.addModule("uzon", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static library artifact
    const lib = b.addLibrary(.{
        .name = "uzon",
        .root_module = uzon_mod,
    });
    b.installArtifact(lib);

    // Unit tests: tests_root.zig pulls in the library plus the test-only
    // files (eval_test.zig, conformance.zig). The library artifact above
    // builds from root.zig and does NOT include those test files.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib_unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
