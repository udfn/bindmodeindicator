const std = @import("std");
const ScanProtocolsStep = @import("zigwayland").ScanProtocolsStep;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nwl = b.dependency("nwl", .{
        .optimize = optimize,
        .target = target,
        .dynamic = optimize == .Debug,
    });

    const scanner = ScanProtocolsStep.create(b.dependency("zigwayland", .{ .no_build = true }).builder);
    scanner.addProtocolPath(nwl.builder.path("protocol/wlr-layer-shell-unstable-v1.xml"), false);
    scanner.generate("wl_compositor", 5);
    scanner.generate("zwlr_layer_shell_v1", 4);
    const bmi = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .optimize = optimize,
        .target = target,
        .single_threaded = true,
        .imports = &.{
            .{ .name = "nwl", .module = nwl.module("nwl") },
            .{ .name = "wayland", .module = scanner.module },
            .{ .name = "sway", .module = b.createModule(.{ .root_source_file = b.path("dep/sway.zig") }) },
        },
    });
    bmi.linkSystemLibrary("wayland-client", .{});
    bmi.linkSystemLibrary("cairo", .{});
    const exe = b.addExecutable(.{
        .name = "bindmodeindicator",
        .root_module = bmi,
    });
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
