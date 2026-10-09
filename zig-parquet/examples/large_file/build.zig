const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const codecs = b.option([]const u8, "codecs", "Compression codecs (default: all). See zig-parquet for values.") orelse "all";

    const parquet_dep = b.dependency("parquet", .{
        .target = target,
        .optimize = optimize,
        .codecs = codecs,
    });
    const parquet_mod = parquet_dep.module("parquet");

    const exe = b.addExecutable(.{
        .name = "large_file_roundtrip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("parquet", parquet_mod);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the large file roundtrip test");
    run_step.dependOn(&run_cmd.step);
}
