const std = @import("std");

const test_targets = [_]std.Target.Query{
    .{}, // native
    .{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
    },
    .{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
    },
};

const testFiles = [_][]const u8{
    "src/main.zig",
};

fn setupTests(b: *std.Build) void {
    const test_step = b.step("test", "Run unit tests");

    for (test_targets) |test_target| {
        for (testFiles) |testFile| {
            const unit_tests = b.addTest(.{
                .root_source_file = b.path(testFile),
                .target = b.resolveTargetQuery(test_target),
            });

            const run_unit_tests = b.addRunArtifact(unit_tests);
            run_unit_tests.skip_foreign_checks = true;
            test_step.dependOn(&run_unit_tests.step);
        }
    }
}

fn setupExe(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{ .name = "hello", .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);
}

pub fn build(b: *std.Build) void {
    setupExe(b);
    setupTests(b);
}
