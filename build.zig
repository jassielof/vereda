const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Single public module ──────────────────────────────────────────────────

    const lib_mod = b.addModule("vereda", .{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "vereda",
        .root_module = lib_mod,
    });

    // ── Docs ──────────────────────────────────────────────────────────────────

    const docs_step = b.step("docs", "Generate documentation (zig-out/docs/)");
    const docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&docs.step);

    // ── Tests (unit + integration) ────────────────────────────────────────────

    const tests_step = b.step("tests", "Run all tests (unit + integration)");

    const unit_tests = b.addTest(.{
        .name = "unit-tests",
        .root_module = lib_mod,
    });
    tests_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const integration_tests = b.addTest(.{
        .name = "integration-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/suite.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vereda", .module = lib_mod },
            },
        }),
    });
    tests_step.dependOn(&b.addRunArtifact(integration_tests).step);
}
