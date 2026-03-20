//! Lazy recursive directory traversal with filtering.
//!
//! Directory entries are yielded one at a time via `Walker.next`; no eager
//! allocation of the full tree occurs. Internally a stack (not recursion) is
//! used to avoid stack overflows on deep trees.
//!
//! Cycle detection for symlinks is performed via realpath when `follow_symlinks`
//! is enabled.

const std = @import("std");
const glob_mod = @import("glob.zig");
const path = @import("path.zig");

const Allocator = std.mem.Allocator;

// ── Options ───────────────────────────────────────────────────────────────────

/// Options controlling `Walker` behaviour.
pub const Options = struct {
    /// Path style used for separator handling and glob matching.
    style: path.Style = .native,

    /// When set, only entries whose relative path matches this glob pattern are
    /// yielded. Directories are still descended regardless of pattern match.
    pattern: ?[]const u8 = null,

    /// When set, only files whose extension equals this string are yielded.
    /// Extension comparison is exact (including the leading dot).
    extension: ?[]const u8 = null,

    /// Maximum recursion depth. `null` means unlimited.
    max_depth: ?usize = null,

    /// Follow symbolic links into directories.
    ///
    /// Cycle detection is performed via realpath to avoid infinite loops.
    follow_symlinks: bool = false,

    /// Skip entries whose basename starts with `.`.
    skip_hidden: bool = false,

    /// Yield directory entries.
    include_dirs: bool = true,

    /// Yield file (and other non-directory) entries.
    include_files: bool = true,

    /// Optional filter callback. When set, an entry is only yielded if this
    /// function returns `true`. Filtering does not affect directory descent.
    filter: ?*const fn (entry: Entry) bool = null,
};

// ── Entry ─────────────────────────────────────────────────────────────────────

/// A single filesystem entry yielded by `Walker.next`.
///
/// **Lifetime:** `path` and `basename` are slices into an internal buffer owned
/// by the `Walker`. They are only valid until the next call to `Walker.next` or
/// `Walker.deinit`. Duplicate them with `alloc.dupe(u8, entry.path)` if you
/// need them to outlive the next iteration.
pub const Entry = struct {
    /// The open directory that contains this entry.
    dir: std.fs.Dir,
    /// The entry name within its parent directory (no separators).
    /// Slice into `path`.
    basename: []const u8,
    /// Path relative to the walk root (uses the style's separator).
    /// Valid only until the next `Walker.next` call.
    path: []const u8,
    /// Entry kind (file, directory, symlink, …).
    kind: std.fs.Dir.Entry.Kind,
    /// Depth relative to the walk root (root entries are at depth 0).
    depth: usize,
};

// ── Internal frame ────────────────────────────────────────────────────────────

const Frame = struct {
    dir: std.fs.Dir,
    iter: std.fs.Dir.Iterator,
    close_on_pop: bool,
    depth: usize,
    prefix_len: usize,
};

// ── Walker ────────────────────────────────────────────────────────────────────

/// A lazy, stack-based recursive directory walker.
///
/// Obtain one via `Walker.init` (passing an open `std.fs.Dir`) or the
/// convenience `walk` free function (passing a path string).
/// Call `deinit` when finished to release all resources.
pub const Walker = struct {
    allocator: Allocator,
    options: Options,
    matcher: ?glob_mod.Pattern,
    prune_dir_prefix: ?[]u8 = null,
    pattern_may_match_nested: bool = true,
    frames: std.ArrayListUnmanaged(Frame) = .empty,
    path_buffer: std.ArrayListUnmanaged(u8) = .empty,
    visited_dirs: std.StringHashMapUnmanaged(void) = .empty,

    /// Creates a `Walker` rooted at `root_dir`.
    ///
    /// The caller remains responsible for closing `root_dir`; the walker will
    /// not close it on `deinit`. Use `initOwned` or the `walk` free function
    /// if you want the walker to take ownership.
    pub fn init(allocator: Allocator, root_dir: std.fs.Dir, options: Options) !Walker {
        const style = options.style.resolve();

        var walker = Walker{
            .allocator = allocator,
            .options = options,
            .matcher = if (options.pattern) |pattern|
                try glob_mod.Pattern.compileWithOptions(allocator, pattern, .{ .style = options.style })
            else
                null,
            .prune_dir_prefix = if (options.pattern) |pattern|
                try extractLiteralDirPrefix(allocator, pattern, style)
            else
                null,
            .pattern_may_match_nested = if (options.pattern) |pattern|
                canPatternMatchNested(pattern, style)
            else
                true,
        };
        errdefer walker.deinit();

        try walker.frames.append(allocator, .{
            .dir = root_dir,
            .iter = root_dir.iterate(),
            .close_on_pop = false,
            .depth = 0,
            .prefix_len = 0,
        });

        if (options.follow_symlinks) {
            const root_realpath = try root_dir.realpathAlloc(allocator, ".");
            errdefer allocator.free(root_realpath);
            try walker.visited_dirs.put(allocator, root_realpath, {});
        }

        return walker;
    }

    /// Creates a `Walker` that owns `root_dir` and will close it on `deinit`.
    pub fn initOwned(allocator: Allocator, root_dir: std.fs.Dir, options: Options) !Walker {
        var w = try Walker.init(allocator, root_dir, options);
        w.frames.items[0].close_on_pop = true;
        return w;
    }

    /// Releases all resources, including closing any opened child directories.
    ///
    /// If the walker was created via `walk` (string path), also closes the root dir.
    pub fn deinit(self: *Walker) void {
        const allocator = self.allocator;

        if (self.matcher) |*matcher| {
            matcher.deinit(allocator);
        }

        if (self.prune_dir_prefix) |prefix| {
            allocator.free(prefix);
        }

        for (self.frames.items) |*frame| {
            if (frame.close_on_pop) frame.dir.close();
        }

        var it = self.visited_dirs.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        self.visited_dirs.deinit(allocator);
        self.frames.deinit(allocator);
        self.path_buffer.deinit(allocator);
        self.* = undefined;
    }

    /// Returns the next matching entry, or `null` when the walk is complete.
    ///
    /// **Note:** the `Entry.path` and `Entry.basename` slices are only valid
    /// until the next call to `next` or `deinit`. Duplicate them if needed.
    pub fn next(self: *Walker) !?Entry {
        const style = self.options.style.resolve();

        while (self.frames.items.len != 0) {
            var top = &self.frames.items[self.frames.items.len - 1];
            self.path_buffer.shrinkRetainingCapacity(top.prefix_len);

            const maybe_base = top.iter.next() catch |err| {
                var frame = self.frames.pop().?;
                self.path_buffer.shrinkRetainingCapacity(
                    if (self.frames.items.len == 0) 0 else self.frames.items[self.frames.items.len - 1].prefix_len,
                );
                if (frame.close_on_pop) frame.dir.close();
                return err;
            };

            if (maybe_base == null) {
                var frame = self.frames.pop().?;
                self.path_buffer.shrinkRetainingCapacity(
                    if (self.frames.items.len == 0) 0 else self.frames.items[self.frames.items.len - 1].prefix_len,
                );
                if (frame.close_on_pop) frame.dir.close();
                continue;
            }

            const base = maybe_base.?;
            if (self.options.skip_hidden and base.name.len != 0 and base.name[0] == '.') {
                continue;
            }

            if (top.prefix_len != 0) {
                try self.path_buffer.append(self.allocator, style.separator());
            }
            try self.path_buffer.appendSlice(self.allocator, base.name);

            const entry_depth = top.depth;
            const containing_dir = top.dir;
            const rel_path = self.path_buffer.items;

            if (shouldDescend(self.options, entry_depth, base.kind)) {
                try self.tryPushChildDir(containing_dir, base.name, base.kind, rel_path, entry_depth + 1);
            }

            if (!self.matchesFilters(base.kind, base.name, rel_path)) {
                continue;
            }

            return .{
                .dir = containing_dir,
                .basename = base.name,
                .path = rel_path,
                .kind = base.kind,
                .depth = entry_depth,
            };
        }

        return null;
    }

    fn matchesFilters(self: *Walker, kind: std.fs.Dir.Entry.Kind, base_name: []const u8, rel_path: []const u8) bool {
        const is_dir = kind == .directory;

        if (is_dir and !self.options.include_dirs) return false;
        if (!is_dir and !self.options.include_files) return false;

        if (is_dir) {
            if (self.options.extension != null) return false;
            if (self.matcher) |matcher| return matcher.match(rel_path);
            if (self.options.filter) |f| return f(.{
                .dir = undefined,
                .basename = base_name,
                .path = rel_path,
                .kind = kind,
                .depth = 0,
            });
            return true;
        }

        if (self.options.extension) |ext| {
            const actual_ext = path.Path.initWithStyle(self.options.style, base_name).extension();
            if (!std.mem.eql(u8, actual_ext, ext)) return false;
        }

        if (self.matcher) |matcher| {
            if (!matcher.match(rel_path)) return false;
        }

        return true;
    }

    fn tryPushChildDir(
        self: *Walker,
        parent_dir: std.fs.Dir,
        name: []const u8,
        kind: std.fs.Dir.Entry.Kind,
        rel_path: []const u8,
        depth: usize,
    ) !void {
        const style = self.options.style.resolve();

        const should_open = switch (kind) {
            .directory => true,
            .sym_link => self.options.follow_symlinks,
            else => false,
        };
        if (!should_open) return;

        if (self.matcher != null and !self.pattern_may_match_nested) {
            return;
        }

        if (self.prune_dir_prefix) |prefix| {
            if (!pathPrefixCompatible(rel_path, prefix, style)) {
                return;
            }
        }

        var child_dir = parent_dir.openDir(name, .{ .iterate = true }) catch |err| switch (err) {
            error.NotDir, error.FileNotFound => return,
            else => return err,
        };
        errdefer child_dir.close();

        if (self.options.follow_symlinks) {
            const canonical = try parent_dir.realpathAlloc(self.allocator, name);
            errdefer self.allocator.free(canonical);

            const result = try self.visited_dirs.getOrPut(self.allocator, canonical);
            if (result.found_existing) {
                self.allocator.free(canonical);
                return;
            }
        }

        try self.frames.append(self.allocator, .{
            .dir = child_dir,
            .iter = child_dir.iterate(),
            .close_on_pop = true,
            .depth = depth,
            .prefix_len = rel_path.len,
        });
    }
};

// ── Free functions ────────────────────────────────────────────────────────────

/// Creates a `Walker` rooted at the directory at `root_path`.
///
/// The walker takes ownership of the opened directory and closes it on `deinit`.
/// `root_path` is resolved relative to the current working directory.
/// Caller must call `Walker.deinit` when done.
pub fn walk(alloc: Allocator, root_path: []const u8, options: Options) !Walker {
    var root_dir = try std.fs.cwd().openDir(root_path, .{ .iterate = true });
    errdefer root_dir.close();
    return Walker.initOwned(alloc, root_dir, options);
}

/// Creates a `Walker` that yields only entries matching `pattern`.
///
/// Equivalent to calling `walk` with `Options{ .pattern = pattern }`.
/// Caller must call `Walker.deinit` when done.
pub fn glob(alloc: Allocator, dir_path: []const u8, pattern: []const u8) !Walker {
    return walk(alloc, dir_path, .{ .pattern = pattern });
}

// ── Internal helpers ──────────────────────────────────────────────────────────

fn shouldDescend(options: Options, depth: usize, kind: std.fs.Dir.Entry.Kind) bool {
    if (kind != .directory and !(kind == .sym_link and options.follow_symlinks)) return false;
    if (options.max_depth) |max_depth| return depth < max_depth;
    return true;
}

fn extractLiteralDirPrefix(allocator: Allocator, pattern: []const u8, style: path.Style) Allocator.Error!?[]u8 {
    if (pattern.len == 0) return null;

    var literal_end: usize = pattern.len;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '\\' and i + 1 < pattern.len) {
            i += 1;
            continue;
        }

        switch (pattern[i]) {
            '*', '?', '[', '{' => {
                literal_end = i;
                break;
            },
            else => {},
        }
    }

    if (literal_end == 0) return null;

    var last_sep: ?usize = null;
    for (pattern[0..literal_end], 0..) |ch, idx| {
        if (style.isSep(ch)) last_sep = idx;
    }

    if (last_sep == null) return null;
    const prefix_len = last_sep.?;
    if (prefix_len == 0) return null;

    const prefix = try allocator.alloc(u8, prefix_len);
    for (pattern[0..prefix_len], 0..) |ch, idx| {
        prefix[idx] = if (style.isSep(ch)) style.separator() else ch;
    }
    return prefix;
}

fn pathPrefixCompatible(rel_path: []const u8, prefix: []const u8, style: path.Style) bool {
    if (prefix.len == 0) return true;
    return hasComponentPrefix(prefix, rel_path, style) or hasComponentPrefix(rel_path, prefix, style);
}

fn hasComponentPrefix(full: []const u8, prefix: []const u8, style: path.Style) bool {
    if (!std.mem.startsWith(u8, full, prefix)) return false;
    if (full.len == prefix.len) return true;
    return style.isSep(full[prefix.len]);
}

fn canPatternMatchNested(pattern: []const u8, style: path.Style) bool {
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const ch = pattern[i];

        if (ch == '\\' and i + 1 < pattern.len) {
            i += 1;
            continue;
        }

        if (style.isSep(ch)) return true;

        if (ch == '*' and i + 1 < pattern.len and pattern[i + 1] == '*') {
            return true;
        }
    }

    return false;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "walker filters extension depth and hidden entries" {
    const allocator = std.testing.allocator;

    var sandbox = std.testing.tmpDir(.{});
    defer sandbox.cleanup();

    try sandbox.dir.makeDir("src");
    try sandbox.dir.makeDir(".hidden");

    {
        const file = try sandbox.dir.createFile("root.zig", .{});
        file.close();
    }
    {
        var src_dir = try sandbox.dir.openDir("src", .{});
        defer src_dir.close();
        const f1 = try src_dir.createFile("main.zig", .{});
        f1.close();
        const f2 = try src_dir.createFile("notes.txt", .{});
        f2.close();
    }
    {
        var hidden_dir = try sandbox.dir.openDir(".hidden", .{});
        defer hidden_dir.close();
        const f = try hidden_dir.createFile("secret.zig", .{});
        f.close();
    }

    // Open with iterate = true to satisfy Windows access rights for directory listing.
    var iter_root = try sandbox.dir.openDir(".", .{ .iterate = true });
    defer iter_root.close();

    var walker = try Walker.init(allocator, iter_root, .{
        .style = .posix,
        .extension = ".zig",
        .skip_hidden = true,
        .max_depth = 1,
    });
    defer walker.deinit();

    var saw_root = false;
    var saw_nested = false;
    var count: usize = 0;

    while (try walker.next()) |entry| {
        count += 1;
        if (std.mem.eql(u8, entry.path, "root.zig")) {
            saw_root = true;
            continue;
        }
        if (std.mem.eql(u8, entry.path, "src/main.zig")) {
            saw_nested = true;
            continue;
        }
        return error.UnexpectedEntry;
    }

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(saw_root);
    try std.testing.expect(saw_nested);
}

test "walker include_dirs and include_files flags" {
    const allocator = std.testing.allocator;

    var sandbox = std.testing.tmpDir(.{});
    defer sandbox.cleanup();

    try sandbox.dir.makeDir("subdir");
    const f = try sandbox.dir.createFile("file.txt", .{});
    f.close();

    var iter_root = try sandbox.dir.openDir(".", .{ .iterate = true });
    defer iter_root.close();

    // Files only
    {
        var walker = try Walker.init(allocator, iter_root, .{
            .style = .posix,
            .include_dirs = false,
            .include_files = true,
        });
        defer walker.deinit();

        var count: usize = 0;
        while (try walker.next()) |entry| {
            try std.testing.expect(entry.kind != .directory);
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), count);
    }

    // Dirs only
    {
        var iter_root2 = try sandbox.dir.openDir(".", .{ .iterate = true });
        defer iter_root2.close();
        var walker = try Walker.init(allocator, iter_root2, .{
            .style = .posix,
            .include_dirs = true,
            .include_files = false,
        });
        defer walker.deinit();

        var count: usize = 0;
        while (try walker.next()) |entry| {
            try std.testing.expect(entry.kind == .directory);
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), count);
    }
}

test "canPatternMatchNested heuristic" {
    try std.testing.expect(!canPatternMatchNested("*.zig", .posix));
    try std.testing.expect(!canPatternMatchNested("file-{a,b}.txt", .posix));
    try std.testing.expect(canPatternMatchNested("src/*.zig", .posix));
    try std.testing.expect(canPatternMatchNested("**.zig", .posix));
    try std.testing.expect(!canPatternMatchNested("src\\*.zig", .windows));
}

test {
    std.testing.refAllDecls(@This());
}
