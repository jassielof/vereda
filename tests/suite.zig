//! Integration test suite entry point.
//!
//! Each sub-file exercises a module against the real filesystem using `std.testing.tmpDir` for isolation. Run alongside unit tests via `zig build tests`.
const std = @import("std");
const refAllDecls = std.testing.refAllDecls;

test {
    refAllDecls(@This());

    refAllDecls(@import("fs.zig"));
    refAllDecls(@import("glob.zig"));
    refAllDecls(@import("walk.zig"));
}
