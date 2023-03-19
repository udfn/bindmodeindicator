const std = @import("std");
const ScanProtocolsStep = @import("zigwayland").ScanProtocolsStep;

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const nwl = b.dependency("nwl", .{
        .optimize = optimize,
        .target = target,
    });

    const scanner = ScanProtocolsStep.create(b);
    scanner.generate("wl_compositor", 5);
    scanner.addProtocolPath(nwl.builder.pathFromRoot("protocol/wlr-layer-shell-unstable-v1.xml"));
    scanner.generate("zwlr_layer_shell_v1", 4);
    const exe = b.addExecutable(.{
        .name = "bindmodeindicator",
        .root_source_file = .{ .path = "src/main.zig"},
        .optimize = optimize,
        .target = target
    });
    const poll = b.option(bool, "poll", "Use a nwl_poll based event loop instead of io_uring") orelse false;
    const opts = b.addOptions();
    opts.addOption(bool, "uring", !poll);
    exe.addOptions("options", opts);
    exe.addModule("nwl", nwl.module("nwl"));
    exe.linkLibrary(nwl.artifact("nwl"));
    exe.linkSystemLibrary("cairo");
    exe.install();
    exe.addAnonymousModule("sway", .{.source_file = .{.path = "dep/sway.zig" }});
    exe.addAnonymousModule("wayland", .{
        .source_file = .{ .generated = &scanner.result}
    });
    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
