const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
        },
    });
    const optimize = b.standardOptimizeOption(.{});
    const codecs = b.option([]const u8, "codecs", "Compression codecs (default: all). See zig-parquet for values.") orelse "all";

    const parquet_dep = b.dependency("parquet", .{
        .target = target,
        .optimize = optimize,
        .codecs = codecs,
    });

    // We add an executable instead of just a module, since WASM demo compiles to a wasm binary.
    const exe = b.addExecutable(.{
        .name = "wasm-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("parquet", parquet_dep.module("parquet"));

    const install_wasm = b.addInstallArtifact(exe, .{});

    const wasm_step = b.step("wasm-demo", "Build WASM demo executable");
    wasm_step.dependOn(&install_wasm.step);
}
