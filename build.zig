const std = @import("std");
const Scanner = @import("zigwayland").Scanner;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nwl = b.dependency("nwl", .{
        .optimize = optimize,
        .target = target,
        .dynamic = optimize == .Debug,
    });

    const scanner = Scanner.create(b, .{});
    scanner.addCustomProtocol(nwl.builder.path("protocol/wlr-layer-shell-unstable-v1.xml"));
    scanner.generate("wl_compositor", 5);
    scanner.generate("zwlr_layer_shell_v1", 4);

    const c_mod = b.addTranslateC(.{
        .root_source_file = b.path("src/cimport.c"),
        .optimize = optimize,
        .target = target,
    });
    c_mod.linkSystemLibrary("cairo", .{});
    const bmi = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .optimize = optimize,
        .target = target,
        .single_threaded = true,
        .imports = &.{
            .{ .name = "nwl", .module = nwl.module("nwl") },
            .{ .name = "wayland", .module = b.createModule(.{ .root_source_file = scanner.result }) },
            .{ .name = "sway", .module = b.createModule(.{ .root_source_file = b.path("dep/sway.zig") }) },
            .{ .name = "c", .module = c_mod.createModule() },
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
