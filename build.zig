const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get vrischmann/zig-sqlite dependency
    const sqlite_dep = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Use the sqlite module from vrischmann/zig-sqlite directly
    root_module.addImport("sqlite", sqlite_dep.module("sqlite"));

    const exe = b.addExecutable(.{
        .name = "z-hermes",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run z-hermes");
    run_step.dependOn(&run_cmd.step);
}
