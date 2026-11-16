const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("uring", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&run_tests.step);

    const bench_exe = b.addExecutable(.{
        .name = "uring-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/loop.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "uring", .module = mod }},
        }),
        .use_llvm = true,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.addPassthruArgs();
    const bench_step = b.step("bench", "Compare the loop against the hand-written one");
    bench_step.dependOn(&run_bench.step);
}
