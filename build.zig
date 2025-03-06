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

const SetupModule = struct  {
    name: []const u8,
    mod: *std.Build.Module
};

const ExeSpec = struct {
    name: []const u8,
    root_source_file: []const u8,
    cmd: []const u8,
    desc: []const u8,
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

fn setupExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: []const SetupModule,
    spec: *const ExeSpec
) void {
    const exe = b.addExecutable(.{
        .name = spec.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(spec.root_source_file),
            .target = target,
            .optimize = optimize
        }),
    });
    for (modules) |mod| {
        exe.root_module.addImport(mod.name, mod.mod);
    }

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);

    const run_step = b.step(spec.cmd, spec.desc);
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

    const exes = [_]ExeSpec{
        .{.name="zig-bgp", .root_source_file="src/main.zig", .cmd="run", .desc="Run main binary"},
        .{.name="scheduled_task", .root_source_file="example_exes/test_scheduled_task.zig", .cmd="test_sched_task", .desc="Run Scheduled Task Example Binary"},
    };

    for (exes) |exeSpec| {
        setupExe(b, target, optimize, &modules, &exeSpec);
    }

    setupTests(b);
}
