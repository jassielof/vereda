//! The Vereda module is a path and filesystem utility library.
const std = @import("std");

pub const dirs = @import("dirs.zig");
const errors = @import("errors.zig");
pub const Error = errors.Error;
pub const fs = @import("fs.zig");
pub const glob = @import("glob.zig");
pub const path = @import("path.zig");
pub const Path = path.Path;
pub const PathBuf = path.PathBuf;
pub const PathStyle = path.Style;
pub const walk = @import("walk.zig");

comptime {
    std.testing.refAllDecls(@This());
}
