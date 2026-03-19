//! Integration test suite entry point.
//!
//! Each sub-file exercises a module against the real filesystem using
//! `std.testing.tmpDir` for isolation. Run alongside unit tests via `zig build tests`.

test {
    _ = @import("fs.zig");
    _ = @import("walk.zig");
}
