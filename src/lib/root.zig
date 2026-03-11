//! Vereda is a Zig 0.15 path and filesystem utility library.
//!
//! The package is split into four focused modules:
//!
//! - `path`: pure string-based path manipulation.
//! - `glob`: filesystem-independent glob matching.
//! - `walk`: lazy recursive directory traversal with filtering.
//! - `fs`: higher-level filesystem helpers.

pub const path = @import("path");
pub const glob = @import("glob");
pub const walk = @import("walk");
pub const fs = @import("fs");

pub const Path = path.Path;
pub const PathBuf = path.PathBuf;
pub const PathStyle = path.Style;

test {
    @import("std").testing.refAllDecls(@This());
}
