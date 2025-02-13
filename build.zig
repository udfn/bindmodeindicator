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

    const scanner = ScanProtocolsStep.create(b.dependency("zigwayland", .{.no_build = true}).builder);
    scanner.generate("wl_compositor", 5);
    scanner.addProtocolPath(nwl.builder.path("protocol/wlr-layer-shell-unstable-v1.xml"), false);
    scanner.generate("zwlr_layer_shell_v1", 4);
    const bmi = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .optimize = optimize,
        .target = target,
    });
    const poll = b.option(bool, "poll", "Use a nwl_poll based event loop instead of io_uring") orelse false;
    const opts = b.addOptions();
    opts.addOption(bool, "uring", !poll);
    bmi.addImport("options", opts.createModule());
    bmi.addImport("nwl", nwl.module("nwl"));
    bmi.linkSystemLibrary("cairo", .{});
    bmi.linkSystemLibrary("wayland-client", .{});
    bmi.addAnonymousImport("sway", .{.root_source_file = b.path("dep/sway.zig")});
    bmi.addImport("wayland", scanner.module);
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
