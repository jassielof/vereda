//! Pure string-based path manipulation.
//!
//! No filesystem access. All functions operate on byte slices.
//! Platform separator is handled at comptime via `builtin.os.tag`.
//!
//! Two layers are provided:
//! - Free functions (`basename`, `join`, `normalize`, …) for simple slice-in / slice-out use.
//! - `Path` and `PathBuf` structs for richer, object-oriented manipulation.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const ascii = std.ascii;
const mem = std.mem;

// ── Comptime platform constants ──────────────────────────────────────────────

/// The native path separator character (`\` on Windows, `/` everywhere else).
pub const sep: u8 = if (builtin.os.tag == .windows) '\\' else '/';

/// The native path separator as a string literal.
pub const sep_str: []const u8 = if (builtin.os.tag == .windows) "\\" else "/";

// ── Style ────────────────────────────────────────────────────────────────────

/// Selects the path syntax conventions used by path operations.
pub const Style = enum {
    /// Use the conventions of the host operating system at compile time.
    native,
    /// POSIX conventions: `/` as separator, case-sensitive.
    posix,
    /// Windows conventions: `\` as canonical separator, `/` also accepted on input,
    /// case-insensitive component comparison.
    windows,

    /// Resolves `.native` to either `.posix` or `.windows` based on `builtin.os.tag`.
    pub fn resolve(self: Style) Style {
        return switch (self) {
            .native => switch (builtin.target.os.tag) {
                .windows => .windows,
                else => .posix,
            },
            else => self,
        };
    }

    /// Returns the canonical separator byte for this style.
    pub fn separator(self: Style) u8 {
        return switch (self.resolve()) {
            .posix => '/',
            .windows => '\\',
            .native => unreachable,
        };
    }

    /// Returns true if `byte` is a path separator under this style.
    ///
    /// Windows accepts both `/` and `\`; POSIX accepts only `/`.
    pub fn isSep(self: Style, byte: u8) bool {
        return switch (self.resolve()) {
            .posix => byte == '/',
            .windows => byte == '/' or byte == '\\',
            .native => unreachable,
        };
    }
};

// ── Error set ────────────────────────────────────────────────────────────────

/// Errors specific to path operations.
pub const Error = error{
    /// Both paths must be absolute for this operation.
    RequiresAbsolutePaths,
    /// Paths have incompatible roots (e.g. different Windows drive letters).
    DifferentRoots,
    /// The provided name contains path separator characters or is otherwise invalid.
    InvalidName,
    /// The path has no filename component (e.g. a bare root like `/` or `C:\`).
    NoFileName,
};

// ── Internal types ───────────────────────────────────────────────────────────

const RootKind = enum { none, rooted, drive, unc };

const RootInfo = struct {
    kind: RootKind,
    absolute: bool,
    root_len: usize,
    disk_designator_len: usize,
};

const Range = struct { start: usize, end: usize };

// ── Public types ─────────────────────────────────────────────────────────────

/// A single path component together with the cumulative path up to and including it.
pub const Component = struct {
    /// The component name (no separators).
    name: []const u8,
    /// Slice of the original path bytes ending at this component.
    path: []const u8,
};

/// A borrowed, immutable view of a path string.
///
/// All methods return slices into the original bytes or new `PathBuf` values.
/// Does not allocate unless explicitly noted.
pub const Path = struct {
    bytes: []const u8,
    style: Style = .native,

    /// Wraps a byte slice with native style.
    pub fn init(bytes: []const u8) Path {
        return .{ .bytes = bytes };
    }

    /// Wraps a byte slice with an explicit style.
    pub fn initWithStyle(style: Style, bytes: []const u8) Path {
        return .{ .bytes = bytes, .style = style };
    }

    /// Returns the raw byte slice.
    pub fn slice(self: Path) []const u8 {
        return self.bytes;
    }

    /// Returns the final path component (no separators).
    ///
    /// Returns an empty slice if the path has no filename (bare root or empty string).
    pub fn basename(self: Path) []const u8 {
        return basenameStyle(self.style.resolve(), self.bytes);
    }

    /// Returns the stem of the filename — basename without the last extension.
    ///
    /// A leading dot (e.g. `.gitignore`) is treated as part of the stem.
    pub fn stem(self: Path) []const u8 {
        return stemStyle(self.style.resolve(), self.bytes);
    }

    /// Returns the file extension including the leading dot, or an empty slice.
    ///
    /// A leading dot is not treated as an extension: `.gitignore` → `""`.
    pub fn extension(self: Path) []const u8 {
        return extensionStyle(self.style.resolve(), self.bytes);
    }

    /// Returns the directory portion of the path, or `null` for a root or bare filename.
    pub fn parent(self: Path) ?Path {
        const parent_bytes = dirnameStyle(self.style.resolve(), self.bytes) orelse return null;
        return .{ .bytes = parent_bytes, .style = self.style };
    }

    /// Returns true if the path is absolute.
    pub fn isAbsolute(self: Path) bool {
        return rootInfo(self.style.resolve(), self.bytes).absolute;
    }

    /// Returns an iterator over non-root path components.
    pub fn components(self: Path) Components {
        return Components.init(self);
    }

    /// Returns an iterator over ancestor paths (closest parent first).
    pub fn parents(self: Path) Parents {
        return Parents.init(self);
    }

    /// Returns a new `PathBuf` with the file extension replaced by `ext`.
    ///
    /// If `ext` does not start with `.`, one is prepended automatically.
    /// Caller owns the returned `PathBuf`; call `PathBuf.deinit` when done.
    pub fn withSuffix(self: Path, allocator: Allocator, ext: []const u8) (Allocator.Error || Error)!PathBuf {
        const style = self.style.resolve();
        const file_range = fileNameRange(style, self.bytes) orelse return error.NoFileName;
        const stem_part = stemStyle(style, self.bytes);
        const stem_end = file_range.start + stem_part.len;
        const needs_dot = ext.len != 0 and ext[0] != '.';

        var buf = PathBuf.init(self.style);
        errdefer buf.deinit(allocator);

        try buf.appendSlice(allocator, self.bytes[0..stem_end]);
        if (needs_dot) try buf.appendByte(allocator, '.');
        try buf.appendSlice(allocator, ext);
        return buf;
    }

    /// Returns a new `PathBuf` with the final component replaced by `name`.
    ///
    /// `name` must not contain separator characters.
    /// Caller owns the returned `PathBuf`.
    pub fn withName(self: Path, allocator: Allocator, name: []const u8) (Allocator.Error || Error)!PathBuf {
        const style = self.style.resolve();
        if (name.len == 0) return error.InvalidName;
        for (name) |byte| {
            if (style.isSep(byte)) return error.InvalidName;
        }

        const file_range = fileNameRange(style, self.bytes) orelse return error.NoFileName;

        var buf = PathBuf.init(self.style);
        errdefer buf.deinit(allocator);

        try buf.appendSlice(allocator, self.bytes[0..file_range.start]);
        try buf.appendSlice(allocator, name);
        return buf;
    }

    /// Returns this path expressed relative to `base`.
    ///
    /// Both paths must be absolute and share the same root.
    /// Caller owns the returned `PathBuf`.
    ///
    /// ```zig
    /// const t = Path.initWithStyle(.posix, "/usr/local/bin/tool");
    /// const b = Path.initWithStyle(.posix, "/usr/share/doc");
    /// var rel = try t.relativeTo(alloc, b); // "../../local/bin/tool"
    /// defer rel.deinit(alloc);
    /// ```
    pub fn relativeTo(self: Path, allocator: Allocator, base: Path) (Allocator.Error || Error)!PathBuf {
        const self_style = self.style.resolve();
        const base_style = base.style.resolve();

        if (self_style != base_style) return error.DifferentRoots;

        const self_root = rootInfo(self_style, self.bytes);
        const base_root = rootInfo(base_style, base.bytes);

        if (!self_root.absolute or !base_root.absolute) return error.RequiresAbsolutePaths;
        if (!rootsEqual(self_style, self.bytes, self_root, base.bytes, base_root)) return error.DifferentRoots;

        var target_it = self.components();
        var base_it = base.components();

        var common_target_end = self_root.root_len;
        var mismatch_target_start: ?usize = null;
        var base_up_count: usize = 0;

        while (true) {
            const maybe_target = target_it.next();
            const maybe_base = base_it.next();

            if (maybe_target == null and maybe_base == null) break;

            if (maybe_target == null) {
                base_up_count += 1;
                while (base_it.next() != null) base_up_count += 1;
                break;
            }

            if (maybe_base == null) {
                const tc = maybe_target.?;
                mismatch_target_start = tc.path.len - tc.name.len;
                break;
            }

            const tc = maybe_target.?;
            const bc = maybe_base.?;
            if (!componentNameEqual(self_style, tc.name, bc.name)) {
                mismatch_target_start = tc.path.len - tc.name.len;
                base_up_count += 1;
                while (base_it.next() != null) base_up_count += 1;
                break;
            }

            common_target_end = tc.path.len;
        }

        if (mismatch_target_start == null) {
            const target_trimmed_len = trimmedEnd(self_style, self.bytes);
            if (target_trimmed_len > common_target_end) {
                mismatch_target_start = common_target_end + separatorRunLength(self_style, self.bytes, common_target_end);
            } else {
                mismatch_target_start = target_trimmed_len;
            }
        }

        const target_suffix = self.bytes[mismatch_target_start.?..trimmedEnd(self_style, self.bytes)];

        if (base_up_count == 0 and target_suffix.len == 0) {
            return PathBuf.fromSlice(allocator, self.style, ".");
        }

        var buf = PathBuf.init(self.style);
        errdefer buf.deinit(allocator);

        var i: usize = 0;
        while (i < base_up_count) : (i += 1) {
            if (buf.items().len != 0) try buf.appendByte(allocator, self_style.separator());
            try buf.appendSlice(allocator, "..");
        }

        if (target_suffix.len != 0) {
            if (buf.items().len != 0) try buf.appendByte(allocator, self_style.separator());
            try buf.appendSlice(allocator, target_suffix);
        }

        return buf;
    }
};

/// A growable, owned path buffer.
///
/// Caller must call `deinit` when done.
pub const PathBuf = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    style: Style = .native,

    /// Creates an empty buffer with the given style.
    pub fn init(style: Style) PathBuf {
        return .{ .style = style };
    }

    /// Creates a buffer pre-populated with `bytes`.
    ///
    /// Caller owns the returned buffer.
    pub fn fromSlice(allocator: Allocator, style: Style, bytes: []const u8) Allocator.Error!PathBuf {
        var buf = PathBuf.init(style);
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, bytes);
        return buf;
    }

    /// Releases all allocated memory.
    pub fn deinit(self: *PathBuf, allocator: Allocator) void {
        self.bytes.deinit(allocator);
        self.* = .{};
    }

    /// Returns a read-only slice of the current contents.
    pub fn items(self: *const PathBuf) []const u8 {
        return self.bytes.items;
    }

    /// Returns a borrowed `Path` view of this buffer.
    ///
    /// The returned `Path` is only valid while this `PathBuf` is alive.
    pub fn asPath(self: *const PathBuf) Path {
        return .{ .bytes = self.bytes.items, .style = self.style };
    }

    /// Appends a byte slice to the buffer.
    pub fn appendSlice(self: *PathBuf, allocator: Allocator, bytes: []const u8) Allocator.Error!void {
        try self.bytes.appendSlice(allocator, bytes);
    }

    /// Appends a single byte to the buffer.
    pub fn appendByte(self: *PathBuf, allocator: Allocator, byte: u8) Allocator.Error!void {
        try self.bytes.append(allocator, byte);
    }
};

/// Iterator over the non-root components of a path.
///
/// Yields `Component` values; each `Component.path` is a slice into the original bytes
/// and is valid for the lifetime of the source path.
pub const Components = struct {
    path: Path,
    root_len: usize,
    cursor: usize,

    pub fn init(path: Path) Components {
        const style = path.style.resolve();
        const info = rootInfo(style, path.bytes);
        return .{
            .path = .{ .bytes = path.bytes, .style = style },
            .root_len = info.root_len,
            .cursor = info.root_len,
        };
    }

    /// Returns the next component, or `null` when exhausted.
    pub fn next(self: *Components) ?Component {
        const style = self.path.style.resolve();
        const bytes = self.path.bytes;

        var start = self.cursor;
        while (start < bytes.len and style.isSep(bytes[start])) start += 1;
        if (start >= bytes.len) {
            self.cursor = bytes.len;
            return null;
        }

        var end = start;
        while (end < bytes.len and !style.isSep(bytes[end])) end += 1;

        self.cursor = end;
        return .{ .name = bytes[start..end], .path = bytes[0..end] };
    }
};

/// Iterator over ancestor paths, starting from the immediate parent.
///
/// Each yielded `Path` is a slice into the original bytes.
pub const Parents = struct {
    current: ?Path,

    pub fn init(path: Path) Parents {
        const style = path.style.resolve();
        return .{
            .current = if (dirnameStyle(style, path.bytes)) |p|
                Path.initWithStyle(style, p)
            else
                null,
        };
    }

    /// Returns the next ancestor, or `null` when the root is passed.
    pub fn next(self: *Parents) ?Path {
        const current = self.current orelse return null;
        const style = current.style.resolve();
        self.current = if (dirnameStyle(style, current.bytes)) |p|
            Path.initWithStyle(style, p)
        else
            null;
        return current;
    }
};

// ── Free functions ────────────────────────────────────────────────────────────

/// Returns the final component of a path.
///
/// Does not access the filesystem. Returns a slice into the input.
///
/// ```zig
/// basename("/foo/bar.txt") // "bar.txt"
/// basename("/foo/")        // "foo"
/// basename("/")            // ""
/// ```
pub fn basename(p: []const u8) []const u8 {
    return basenameStyle(Style.native.resolve(), p);
}

/// Returns the directory portion of a path, or `null` for a bare root or filename.
///
/// Returns a slice into the input.
///
/// ```zig
/// dirname("/foo/bar.txt") // "/foo"
/// dirname("file.txt")     // null
/// dirname("/")            // null
/// ```
pub fn dirname(p: []const u8) ?[]const u8 {
    return dirnameStyle(Style.native.resolve(), p);
}

/// Returns the file extension including the leading dot, or an empty slice.
///
/// A leading-dot filename (e.g. `.gitignore`) is treated as having no extension.
///
/// ```zig
/// extension("archive.tar.gz") // ".gz"
/// extension(".gitignore")     // ""
/// ```
pub fn extension(p: []const u8) []const u8 {
    return extensionStyle(Style.native.resolve(), p);
}

/// Returns the stem of the filename — basename without the last extension.
///
/// ```zig
/// stem("archive.tar.gz") // "archive.tar"
/// stem(".gitignore")     // ".gitignore"
/// ```
pub fn stem(p: []const u8) []const u8 {
    return stemStyle(Style.native.resolve(), p);
}

/// Returns true if the path is absolute.
pub fn isAbsolute(p: []const u8) bool {
    return rootInfo(Style.native.resolve(), p).absolute;
}

/// Joins path segments with the native separator.
///
/// Empty segments are skipped. Trailing separators on a segment are preserved
/// but do not cause a duplicate separator to be emitted before the next segment.
/// Caller owns the returned memory.
///
/// ```zig
/// const p = try path.join(alloc, &.{"a", "b", "c"}); // "a/b/c" or "a\b\c"
/// defer alloc.free(p);
/// ```
pub fn join(alloc: Allocator, parts: []const []const u8) ![]u8 {
    const style = Style.native.resolve();
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);

    for (parts) |part| {
        if (part.len == 0) continue;
        if (buf.items.len > 0) {
            const last = buf.items[buf.items.len - 1];
            if (!style.isSep(last)) try buf.append(alloc, style.separator());
        }
        try buf.appendSlice(alloc, part);
    }

    return buf.toOwnedSlice(alloc);
}

/// Normalizes a path: resolves `.` and `..` components, collapses redundant separators.
///
/// Does not access the filesystem — symbolic links and mount points are not resolved.
/// Caller owns the returned memory.
///
/// ```zig
/// normalize(alloc, "/a/b/../c")  // "/a/c"
/// normalize(alloc, "foo/./bar")  // "foo/bar"
/// normalize(alloc, "")           // "."
/// ```
pub fn normalize(alloc: Allocator, p: []const u8) ![]u8 {
    const style = Style.native.resolve();
    const info = rootInfo(style, p);

    var stack: std.ArrayListUnmanaged([]const u8) = .empty;
    defer stack.deinit(alloc);

    var cursor: usize = info.root_len;
    while (cursor < p.len) {
        while (cursor < p.len and style.isSep(p[cursor])) cursor += 1;
        if (cursor >= p.len) break;

        var end = cursor;
        while (end < p.len and !style.isSep(p[end])) end += 1;

        const comp = p[cursor..end];
        if (mem.eql(u8, comp, ".")) {
            // skip
        } else if (mem.eql(u8, comp, "..")) {
            if (stack.items.len > 0) {
                _ = stack.pop();
            } else if (!info.absolute) {
                try stack.append(alloc, comp);
            }
        } else {
            try stack.append(alloc, comp);
        }
        cursor = end;
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);

    // Emit root (normalized: collapse multiple POSIX slashes to one)
    switch (style) {
        .posix => if (info.root_len > 0) try buf.append(alloc, '/'),
        .windows => try buf.appendSlice(alloc, p[0..info.root_len]),
        .native => unreachable,
    }

    for (stack.items, 0..) |comp, i| {
        if (i > 0) try buf.append(alloc, style.separator());
        try buf.appendSlice(alloc, comp);
    }

    if (buf.items.len == 0) try buf.append(alloc, '.');

    return buf.toOwnedSlice(alloc);
}

/// Resolves `rel` against `base`, returning a normalized absolute or relative path.
///
/// If `rel` is absolute it is returned normalized. Otherwise `rel` is appended to
/// `base` and the result is normalized.
/// Caller owns the returned memory.
///
/// ```zig
/// const p = try path.resolve(alloc, "/home/user", "docs/file.txt");
/// // → "/home/user/docs/file.txt"
/// ```
pub fn resolve(alloc: Allocator, base: []const u8, rel: []const u8) ![]u8 {
    const style = Style.native.resolve();
    if (rootInfo(style, rel).absolute) {
        return normalize(alloc, rel);
    }
    const joined = try join(alloc, &.{ base, rel });
    defer alloc.free(joined);
    return normalize(alloc, joined);
}

/// Returns `target` expressed relative to `base`.
///
/// Both paths must be absolute and share the same root.
/// Caller owns the returned memory.
///
/// ```zig
/// const r = try path.relativeTo(alloc, "/usr/share/doc", "/usr/local/bin/tool");
/// // → "../../local/bin/tool"
/// ```
pub fn relativeTo(alloc: Allocator, base: []const u8, target: []const u8) ![]u8 {
    const target_path = Path.init(target);
    const base_path = Path.init(base);
    var result = try target_path.relativeTo(alloc, base_path);
    defer result.deinit(alloc);
    return alloc.dupe(u8, result.items());
}

// ── Internal helpers ──────────────────────────────────────────────────────────

fn rootInfo(style: Style, path: []const u8) RootInfo {
    return switch (style) {
        .posix => posixRootInfo(path),
        .windows => windowsRootInfo(path),
        .native => unreachable,
    };
}

fn posixRootInfo(path: []const u8) RootInfo {
    var root_len: usize = 0;
    while (root_len < path.len and path[root_len] == '/') root_len += 1;
    return .{
        .kind = if (root_len == 0) .none else .rooted,
        .absolute = root_len != 0,
        .root_len = root_len,
        .disk_designator_len = 0,
    };
}

fn windowsRootInfo(path: []const u8) RootInfo {
    if (path.len >= 2 and ascii.isAlphabetic(path[0]) and path[1] == ':') {
        if (path.len >= 3 and isWindowsSep(path[2])) {
            var root_len: usize = 3;
            while (root_len < path.len and isWindowsSep(path[root_len])) root_len += 1;
            return .{ .kind = .drive, .absolute = true, .root_len = root_len, .disk_designator_len = 2 };
        }
        return .{ .kind = .drive, .absolute = false, .root_len = 2, .disk_designator_len = 2 };
    }

    if (path.len >= 2 and isWindowsSep(path[0]) and isWindowsSep(path[1])) {
        var index: usize = 2;
        if (index < path.len and isWindowsSep(path[index])) {
            return .{ .kind = .rooted, .absolute = true, .root_len = 1, .disk_designator_len = 0 };
        }

        const server_start = index;
        while (index < path.len and !isWindowsSep(path[index])) index += 1;
        if (index == server_start or index == path.len) {
            return .{ .kind = .rooted, .absolute = true, .root_len = 1, .disk_designator_len = 0 };
        }
        while (index < path.len and isWindowsSep(path[index])) index += 1;

        const share_start = index;
        while (index < path.len and !isWindowsSep(path[index])) index += 1;
        if (index == share_start) {
            return .{ .kind = .rooted, .absolute = true, .root_len = 1, .disk_designator_len = 0 };
        }
        while (index < path.len and isWindowsSep(path[index])) index += 1;

        return .{ .kind = .unc, .absolute = true, .root_len = index, .disk_designator_len = index };
    }

    if (path.len != 0 and isWindowsSep(path[0])) {
        return .{ .kind = .rooted, .absolute = true, .root_len = 1, .disk_designator_len = 0 };
    }

    return .{ .kind = .none, .absolute = false, .root_len = 0, .disk_designator_len = 0 };
}

fn basenameStyle(style: Style, path: []const u8) []const u8 {
    const range = fileNameRange(style, path) orelse return path[path.len..];
    return path[range.start..range.end];
}

fn extensionStyle(style: Style, path: []const u8) []const u8 {
    const filename = basenameStyle(style, path);
    const dot_index = mem.lastIndexOfScalar(u8, filename, '.') orelse return filename[filename.len..];
    if (dot_index == 0) return filename[filename.len..];
    return filename[dot_index..];
}

fn stemStyle(style: Style, path: []const u8) []const u8 {
    const filename = basenameStyle(style, path);
    const dot_index = mem.lastIndexOfScalar(u8, filename, '.') orelse return filename;
    if (dot_index == 0) return filename;
    return filename[0..dot_index];
}

fn dirnameStyle(style: Style, path: []const u8) ?[]const u8 {
    if (path.len == 0) return null;

    const info = rootInfo(style, path);
    const trimmed_end = trimmedEnd(style, path);
    if (trimmed_end <= info.root_len) return null;

    var end = trimmed_end;
    while (end > info.root_len and !style.isSep(path[end - 1])) end -= 1;

    if (end <= info.root_len) {
        return if (info.root_len == 0) null else path[0..info.root_len];
    }

    while (end > info.root_len and style.isSep(path[end - 1])) end -= 1;

    if (end <= info.root_len) return path[0..info.root_len];
    return path[0..end];
}

fn fileNameRange(style: Style, path: []const u8) ?Range {
    if (path.len == 0) return null;

    const info = rootInfo(style, path);
    const end = trimmedEnd(style, path);
    if (end <= info.root_len) return null;

    var start = end;
    while (start > info.root_len and !style.isSep(path[start - 1])) start -= 1;

    return .{ .start = start, .end = end };
}

fn trimmedEnd(style: Style, path: []const u8) usize {
    if (path.len == 0) return 0;
    const info = rootInfo(style, path);
    var end = path.len;
    while (end > info.root_len and style.isSep(path[end - 1])) end -= 1;
    return end;
}

fn separatorRunLength(style: Style, path: []const u8, index: usize) usize {
    var cursor = index;
    while (cursor < path.len and style.isSep(path[cursor])) cursor += 1;
    return cursor - index;
}

fn rootsEqual(style: Style, left: []const u8, left_root: RootInfo, right: []const u8, right_root: RootInfo) bool {
    if (left_root.kind != right_root.kind) return false;
    return switch (style) {
        .posix => true,
        .windows => switch (left_root.kind) {
            .none, .rooted => true,
            .drive => ascii.toUpper(left[0]) == ascii.toUpper(right[0]),
            .unc => eqlIgnoreCase(left[0..left_root.disk_designator_len], right[0..right_root.disk_designator_len]),
        },
        .native => unreachable,
    };
}

fn componentNameEqual(style: Style, left: []const u8, right: []const u8) bool {
    return switch (style) {
        .posix => mem.eql(u8, left, right),
        .windows => eqlIgnoreCase(left, right),
        .native => unreachable,
    };
}

fn eqlIgnoreCase(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (ascii.toUpper(a) != ascii.toUpper(b)) return false;
    }
    return true;
}

fn isWindowsSep(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "sep constants match platform" {
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqual('\\', sep);
        try std.testing.expectEqualStrings("\\", sep_str);
    } else {
        try std.testing.expectEqual('/', sep);
        try std.testing.expectEqualStrings("/", sep_str);
    }
}

test "free function basename" {
    try std.testing.expectEqualStrings("bar.txt", Path.initWithStyle(.posix, "/foo/bar.txt").basename());
    try std.testing.expectEqualStrings("foo", Path.initWithStyle(.posix, "/foo/").basename());
    try std.testing.expectEqualStrings("", Path.initWithStyle(.posix, "/").basename());
    try std.testing.expectEqualStrings("", Path.initWithStyle(.posix, "").basename());
}

test "free function dirname" {
    try std.testing.expectEqualStrings("/foo", dirnameStyle(.posix, "/foo/bar.txt").?);
    try std.testing.expect(dirnameStyle(.posix, "file.txt") == null);
    try std.testing.expect(dirnameStyle(.posix, "/") == null);
}

test "join posix" {
    const alloc = std.testing.allocator;
    const p = try join(alloc, &.{ "a", "b", "c" });
    defer alloc.free(p);
    if (sep == '/') {
        try std.testing.expectEqualStrings("a/b/c", p);
    }
}

test "join empty parts skipped" {
    const alloc = std.testing.allocator;
    const p = try join(alloc, &.{ "a", "", "c" });
    defer alloc.free(p);
    if (sep == '/') {
        try std.testing.expectEqualStrings("a/c", p);
    }
}

test "join no trailing double separator" {
    const alloc = std.testing.allocator;
    const p = try join(alloc, &.{ "a/", "b" });
    defer alloc.free(p);
    if (sep == '/') {
        try std.testing.expectEqualStrings("a/b", p);
    }
}

test "normalize dot and dotdot" {
    if (sep != '/') return error.SkipZigTest;
    const alloc = std.testing.allocator;
    {
        const n = try normalize(alloc, "/a/b/../c");
        defer alloc.free(n);
        try std.testing.expectEqualStrings("/a/c", n);
    }
    {
        const n = try normalize(alloc, "foo/./bar");
        defer alloc.free(n);
        try std.testing.expectEqualStrings("foo/bar", n);
    }
    {
        const n = try normalize(alloc, "/a/b/../../..");
        defer alloc.free(n);
        try std.testing.expectEqualStrings("/", n);
    }
    {
        const n = try normalize(alloc, "");
        defer alloc.free(n);
        try std.testing.expectEqualStrings(".", n);
    }
    {
        const n = try normalize(alloc, "../../foo");
        defer alloc.free(n);
        try std.testing.expectEqualStrings("../../foo", n);
    }
}

test "normalize collapses multiple slashes" {
    if (sep != '/') return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const n = try normalize(alloc, "//a//b");
    defer alloc.free(n);
    try std.testing.expectEqualStrings("/a/b", n);
}

test "resolve relative to base" {
    if (sep != '/') return error.SkipZigTest;
    const alloc = std.testing.allocator;
    {
        const p = try resolve(alloc, "/home/user", "docs/file.txt");
        defer alloc.free(p);
        try std.testing.expectEqualStrings("/home/user/docs/file.txt", p);
    }
    {
        const p = try resolve(alloc, "/home/user", "/etc/passwd");
        defer alloc.free(p);
        try std.testing.expectEqualStrings("/etc/passwd", p);
    }
}

test "posix stem and suffix handling" {
    const allocator = std.testing.allocator;
    const path = Path.initWithStyle(.posix, "/tmp/archive.tar.gz");

    try std.testing.expectEqualStrings("archive.tar", path.stem());
    try std.testing.expectEqualStrings(".gz", path.extension());

    var updated = try path.withSuffix(allocator, ".zip");
    defer updated.deinit(allocator);

    try std.testing.expectEqualStrings("/tmp/archive.tar.zip", updated.items());
}

test "withName replaces the final component" {
    const allocator = std.testing.allocator;
    const path = Path.initWithStyle(.posix, "/tmp/archive.tar.gz");

    var updated = try path.withName(allocator, "release.tgz");
    defer updated.deinit(allocator);

    try std.testing.expectEqualStrings("/tmp/release.tgz", updated.items());
}

test "relativeTo posix" {
    const allocator = std.testing.allocator;
    const target = Path.initWithStyle(.posix, "/usr/local/bin/tool");
    const base = Path.initWithStyle(.posix, "/usr/share/doc");

    var relative = try target.relativeTo(allocator, base);
    defer relative.deinit(allocator);

    try std.testing.expectEqualStrings("../../local/bin/tool", relative.items());
}

test "relativeTo windows drive paths" {
    const allocator = std.testing.allocator;
    const target = Path.initWithStyle(.windows, "C:\\Users\\Jassiel\\src\\vereda");
    const base = Path.initWithStyle(.windows, "C:\\Users\\Jassiel\\docs");

    var relative = try target.relativeTo(allocator, base);
    defer relative.deinit(allocator);

    try std.testing.expectEqualStrings("..\\src\\vereda", relative.items());
}

test "relativeTo rejects different windows roots" {
    const allocator = std.testing.allocator;
    const target = Path.initWithStyle(.windows, "D:\\data\\report.txt");
    const base = Path.initWithStyle(.windows, "C:\\data\\docs");

    try std.testing.expectError(error.DifferentRoots, target.relativeTo(allocator, base));
}

test "components iterates windows UNC paths" {
    var it = Path.initWithStyle(.windows, "\\\\server\\share\\logs\\app.txt").components();

    const first = it.next().?;
    try std.testing.expectEqualStrings("logs", first.name);
    try std.testing.expectEqualStrings("\\\\server\\share\\logs", first.path);

    const second = it.next().?;
    try std.testing.expectEqualStrings("app.txt", second.name);
    try std.testing.expectEqualStrings("\\\\server\\share\\logs\\app.txt", second.path);
    try std.testing.expect(it.next() == null);
}

test "parents include roots and stop at empty" {
    var parents = Path.initWithStyle(.windows, "C:\\Users\\Jassiel\\src").parents();

    try std.testing.expectEqualStrings("C:\\Users\\Jassiel", parents.next().?.bytes);
    try std.testing.expectEqualStrings("C:\\Users", parents.next().?.bytes);
    try std.testing.expectEqualStrings("C:\\", parents.next().?.bytes);
    try std.testing.expect(parents.next() == null);
}

test "empty and root paths have no filename" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqualStrings("", Path.initWithStyle(.posix, "").basename());
    try std.testing.expectEqualStrings("", Path.initWithStyle(.posix, "/").basename());
    try std.testing.expectError(error.NoFileName, Path.initWithStyle(.windows, "C:\\").withSuffix(allocator, ".txt"));
}

test {
    std.testing.refAllDecls(@This());
}
