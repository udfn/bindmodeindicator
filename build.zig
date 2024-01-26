const std = @import("std");
const ScanProtocolsStep = @import("zigwayland").ScanProtocolsStep;

pub fn build(b: *std.Build) !void {
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
    exe.root_module.addAnonymousImport("options", .{
        .root_source_file = .{.generated = &opts.generated_file}});
    exe.root_module.addImport("nwl", nwl.module("nwl"));
    exe.linkSystemLibrary("cairo");
    b.installArtifact(exe);
    exe.root_module.addAnonymousImport("sway", .{.root_source_file = .{.path = "dep/sway.zig" }});
    exe.root_module.addAnonymousImport("wayland", .{
        .root_source_file = .{ .generated = &scanner.result}
    });
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
