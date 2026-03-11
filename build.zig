const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const path_mod = b.addModule("path", .{
        .root_source_file = b.path("src/lib/path.zig"),
        .target = target,
        .optimize = optimize,
    });

    const glob_mod = b.addModule("glob", .{
        .root_source_file = b.path("src/lib/glob.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{
            .name = "path",
            .module = path_mod,
        }},
    });

    const walk_mod = b.addModule("walk", .{
        .root_source_file = b.path("src/lib/walk.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "path",
                .module = path_mod,
            },
            .{
                .name = "glob",
                .module = glob_mod,
            },
        },
    });

    const fs_mod = b.addModule("fs", .{
        .root_source_file = b.path("src/lib/fs.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "path",
                .module = path_mod,
            },
            .{
                .name = "walk",
                .module = walk_mod,
            },
        },
    });

    const lib_mod = b.addModule("vereda", .{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "path",
                .module = path_mod,
            },
            .{
                .name = "glob",
                .module = glob_mod,
            },
            .{
                .name = "walk",
                .module = walk_mod,
            },
            .{
                .name = "fs",
                .module = fs_mod,
            },
        },
    });

    const lib = b.addLibrary(.{
        .name = "vereda",
        .root_module = lib_mod,
    });

    const docs_step = b.step("docs", "Generate the documentation");
    const docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&docs.step);

    const tests_step = b.step("tests", "Run the test suite");

    const unit_tests = b.addTest(.{
        .name = "unit tests",
        .root_module = lib_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    tests_step.dependOn(&run_unit_tests.step);

    const integration_tests = b.addTest(.{
        .name = "integration tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/suite.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "vereda",
                    .module = lib_mod,
                },
                .{
                    .name = "path",
                    .module = path_mod,
                },
                .{
                    .name = "glob",
                    .module = glob_mod,
                },
                .{
                    .name = "walk",
                    .module = walk_mod,
                },
                .{
                    .name = "fs",
                    .module = fs_mod,
                },
            },
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    tests_step.dependOn(&run_integration_tests.step);
}
