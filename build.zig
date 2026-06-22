const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "rake",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target   = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // zig build run [-- args]
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run rake");
    run_step.dependOn(&run_cmd.step);

    // zig build windows  ->  zig-out/bin/rake.exe  (x86_64)
    const win64 = b.resolveTargetQuery(.{
        .cpu_arch  = .x86_64,
        .os_tag    = .windows,
        .abi       = .gnu,
    });
    const exe_win = b.addExecutable(.{
        .name = "rake",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target   = win64,
            .optimize = optimize,
        }),
    });
    const install_win = b.addInstallArtifact(exe_win, .{});
    const win_step = b.step("windows", "Cross-compile rake.exe for Windows x86_64");
    win_step.dependOn(&install_win.step);
}
