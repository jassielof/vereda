//! Platform-aware resolution of standard user directories.
//!
//! On Linux, the XDG Base Directory Specification is followed.
//! On macOS, standard Apple directory conventions are used.
//! On Windows, `%APPDATA%` and `%LOCALAPPDATA%` are used.
//!
// TODO(xdg-migration): The Linux implementation of config(), data(), cache(),
// and runtime() is currently inlined here. Once the xdg Zig port is available
// as a dependency, replace these calls with xdg.base_dirs.configHome(), etc.
// Tracked: https://github.com/jassielof/xdg

const std = @import("std");
const builtin = @import("builtin");
const path = @import("path.zig");

const Allocator = std.mem.Allocator;

// ── Errors ────────────────────────────────────────────────────────────────────

/// Errors specific to directory resolution.
pub const Error = error{
    /// A required runtime directory is not available (e.g. `XDG_RUNTIME_DIR` not set).
    NotAvailable,
    /// The user's home directory could not be determined.
    HomeDirUnknown,
};

// ── Public API ────────────────────────────────────────────────────────────────

/// Returns the user's home directory.
///
/// Caller owns the returned memory.
///
/// - Linux/macOS: reads `$HOME`
/// - Windows: reads `%USERPROFILE%`, then falls back to `%HOMEDRIVE%+%HOMEPATH%`
pub fn home(alloc: Allocator) ![]u8 {
    return switch (builtin.os.tag) {
        .windows => homeWindows(alloc),
        else => homePosix(alloc),
    };
}

/// Returns the user-specific configuration directory.
///
/// Caller owns the returned memory.
///
/// - Linux:   `$XDG_CONFIG_HOME` or `~/.config`  // xdg-migration
/// - Windows: `%APPDATA%`
/// - macOS:   `~/Library/Application Support`
pub fn config(alloc: Allocator) ![]u8 {
    return switch (builtin.os.tag) {
        .windows => envOwned(alloc, "APPDATA"),
        .macos => joinHome(alloc, "Library/Application Support"),
        else => xdgOrHome(alloc, "XDG_CONFIG_HOME", ".config"), // xdg-migration
    };
}

/// Returns the user-specific data directory.
///
/// Caller owns the returned memory.
///
/// - Linux:   `$XDG_DATA_HOME` or `~/.local/share`  // xdg-migration
/// - Windows: `%APPDATA%`
/// - macOS:   `~/Library/Application Support`
pub fn data(alloc: Allocator) ![]u8 {
    return switch (builtin.os.tag) {
        .windows => envOwned(alloc, "APPDATA"),
        .macos => joinHome(alloc, "Library/Application Support"),
        else => xdgOrHome(alloc, "XDG_DATA_HOME", ".local/share"), // xdg-migration
    };
}

/// Returns the user-specific cache directory.
///
/// Caller owns the returned memory.
///
/// - Linux:   `$XDG_CACHE_HOME` or `~/.cache`  // xdg-migration
/// - Windows: `%LOCALAPPDATA%`
/// - macOS:   `~/Library/Caches`
pub fn cache(alloc: Allocator) ![]u8 {
    return switch (builtin.os.tag) {
        .windows => envOwned(alloc, "LOCALAPPDATA"),
        .macos => joinHome(alloc, "Library/Caches"),
        else => xdgOrHome(alloc, "XDG_CACHE_HOME", ".cache"), // xdg-migration
    };
}

/// Returns the user-specific runtime directory.
///
/// Caller owns the returned memory.
///
/// - Linux:   `$XDG_RUNTIME_DIR` (returns `error.NotAvailable` if unset)  // xdg-migration
/// - Windows: `%LOCALAPPDATA%\Temp`
/// - macOS:   `$TMPDIR`
pub fn runtime(alloc: Allocator) ![]u8 {
    return switch (builtin.os.tag) {
        .windows => blk: {
            const base = try envOwned(alloc, "LOCALAPPDATA");
            defer alloc.free(base);
            break :blk path.join(alloc, &.{ base, "Temp" });
        },
        .macos => envOwned(alloc, "TMPDIR"),
        else => envOwned(alloc, "XDG_RUNTIME_DIR"), // xdg-migration
    };
}

// ── Internal helpers ──────────────────────────────────────────────────────────

fn homePosix(alloc: Allocator) ![]u8 {
    return std.process.getEnvVarOwned(alloc, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => error.HomeDirUnknown,
        else => |e| e,
    };
}

fn homeWindows(alloc: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(alloc, "USERPROFILE")) |v| return v else |_| {}

    const drive = std.process.getEnvVarOwned(alloc, "HOMEDRIVE") catch return error.HomeDirUnknown;
    defer alloc.free(drive);

    const home_path = std.process.getEnvVarOwned(alloc, "HOMEPATH") catch return error.HomeDirUnknown;
    defer alloc.free(home_path);

    return path.join(alloc, &.{ drive, home_path });
}

/// Returns the value of environment variable `var_name`, or `error.NotAvailable`.
fn envOwned(alloc: Allocator, var_name: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(alloc, var_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => error.NotAvailable,
        else => |e| e,
    };
}

/// Returns `$HOME/<suffix>` as an owned string.
fn joinHome(alloc: Allocator, suffix: []const u8) ![]u8 {
    const home_dir = try home(alloc);
    defer alloc.free(home_dir);
    return path.join(alloc, &.{ home_dir, suffix });
}

/// Returns `$xdg_var` if set, otherwise `$HOME/<fallback>`.
fn xdgOrHome(alloc: Allocator, xdg_var: []const u8, fallback_suffix: []const u8) ![]u8 {
    if (std.process.getEnvVarOwned(alloc, xdg_var)) |v| return v else |_| {}
    return joinHome(alloc, fallback_suffix);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "home returns a non-empty string on supported platforms" {
    const alloc = std.testing.allocator;

    const h = home(alloc) catch return;
    defer alloc.free(h);

    try std.testing.expect(h.len > 0);
}

test "config returns a non-empty string" {
    const alloc = std.testing.allocator;

    const c = config(alloc) catch return;
    defer alloc.free(c);

    try std.testing.expect(c.len > 0);
}

test "cache returns a non-empty string" {
    const alloc = std.testing.allocator;

    const c = cache(alloc) catch return;
    defer alloc.free(c);

    try std.testing.expect(c.len > 0);
}

test {
    std.testing.refAllDecls(@This());
}
