const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // libusb (zweiler2 fork) — same dependency the pcba-tester uses.
    const libusb_dep = b.dependency("libusb", .{
        .target = target,
        .optimize = optimize,
        .@"use-rc" = true,
    });

    // The library module — this is the dependency surface for other Zig projects.
    const wlink_mod = b.addModule("wlink", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    wlink_mod.addIncludePath(libusb_dep.path("libusb"));
    wlink_mod.linkLibrary(libusb_dep.artifact("usb-1.0"));

    // Serial monitor (SDI print / watch-serial).
    const serial_dep = b.dependency("serial", .{ .target = target, .optimize = optimize });
    wlink_mod.addImport("serial", serial_dep.module("serial"));

    // The CLI executable — a thin consumer of the library module.
    const exe = b.addExecutable(.{
        .name = "wlink",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wlink", .module = wlink_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // `zig build run -- <args>`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the wlink CLI");
    run_step.dependOn(&run_cmd.step);

    // `zig build test`
    const tests = b.addTest(.{ .root_module = wlink_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library unit tests");
    test_step.dependOn(&run_tests.step);
}
