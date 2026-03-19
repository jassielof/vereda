//! Vereda — Zig 0.15 path and filesystem utility library.
//!
//! Import once to access the full API:
//!
//! ```zig
//! const vereda = @import("vereda");
//!
//! const p = try vereda.path.join(alloc, &.{"a", "b"});
//! const home = try vereda.dirs.home(alloc);
//! ```
//!
//! Modules:
//! - `path`: pure string-based path manipulation (no I/O, no allocations for simple queries)
//! - `glob`: filesystem-independent glob pattern matching
//! - `walk`: lazy recursive directory traversal with filtering
//! - `fs`:   shutil-style filesystem helpers
//! - `dirs`: platform-aware resolution of standard user directories

pub const path = @import("path.zig");
pub const glob = @import("glob.zig");
pub const walk = @import("walk.zig");
pub const fs = @import("fs.zig");
pub const dirs = @import("dirs.zig");

/// Convenience re-exports from `path`.
pub const Path = path.Path;
pub const PathBuf = path.PathBuf;
pub const PathStyle = path.Style;

/// Shared cross-cutting error set.
///
/// Individual modules may define additional errors; these cover the common cases
/// returned across the public API.
pub const Error = error{
    /// A requested path or resource was not found.
    NotFound,
    /// The caller lacks permission to access the resource.
    PermissionDenied,
    /// Expected a directory but found something else.
    NotADirectory,
    /// Expected a file but found something else.
    NotAFile,
    /// The resource already exists and the operation does not allow overwriting.
    AlreadyExists,
    /// The provided path is syntactically invalid.
    InvalidPath,
    /// The requested feature is not available on the current operating system.
    Unsupported,
    /// A required runtime resource is unavailable (e.g. `XDG_RUNTIME_DIR` not set).
    NotAvailable,
};

test {
    @import("std").testing.refAllDecls(@This());
}
