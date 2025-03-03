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

const SetupModule = struct  {
    name: []const u8,
    mod: *std.Build.Module
};

fn setupExe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, modules: []const SetupModule, name: []const u8, root_file_path: []const u8, cmd: []const u8, desc: []const u8) void {
    const exe = b.addExecutable(.{ .name = name, .root_source_file = b.path(root_file_path), .target = target, .optimize = optimize });
    for (modules) |mod| {
        exe.root_module.addImport(mod.name, mod.mod);
    }

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);

    const run_step = b.step(cmd, desc);
    run_step.dependOn(&run_exe.step);
}

fn setupModule(b: *std.Build, name: []const u8, root_source_file: []const u8) SetupModule {
    return .{
        .name=name,
        .mod=b.addModule(name, .{
            .root_source_file = b.path(root_source_file)
        })
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const modules = [_]SetupModule{
        setupModule(b, "scheduled_task", "src/utils/scheduled_task.zig"),
    };

    setupExe(b, target, optimize, &modules, "zig-bgp", "src/main.zig", "run", "Run bgp-zig");
    setupExe(b, target, optimize, &modules, "scheduled_task", "example_exes/test_scheduled_task.zig", "test_sched_task", "Run Scheduled Task Tests");

    setupTests(b);
}
