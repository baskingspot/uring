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

    // testingx is a benchmark-only dependency, and lazy: a consumer of this
    // package must not resolve it, so the wiring below runs only when this is
    // the root package. `lazyImport` imports the dependency's build script,
    // which is where `addBench` lives.
    if (b.pkg_hash.len == 0) {
        if (b.lazyImport(@This(), "testingx")) |testingx| {
            const bench_dep = (b.dependencyLazy("testingx", .{
                .target = target,
            }) catch null).?;
            const run_bench = testingx.addBench(b, .{
                .name = "uring-bench",
                .module = bench_dep.module("testingx"),
                .root_source_file = b.path("bench/loop.zig"),
                .target = target,
                .imports = &.{.{ .name = "uring", .module = mod }},
            });
            run_bench.addPassthruArgs();
            const bench_step = b.step("bench", "Compare the loop against the hand-written one");
            bench_step.dependOn(&run_bench.step);
        }
    }
}
