//! Lazy recursive directory traversal with filtering.

const std = @import("std");
const glob = @import("glob");
const path = @import("path");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    style: path.Style = .native,
    pattern: ?[]const u8 = null,
    extension: ?[]const u8 = null,
    max_depth: ?usize = null,
    follow_symlinks: bool = false,
    skip_hidden: bool = false,
};

pub const Entry = struct {
    dir: std.fs.Dir,
    basename: []const u8,
    path: []const u8,
    kind: std.fs.Dir.Entry.Kind,
    depth: usize,
};

const Frame = struct {
    dir: std.fs.Dir,
    iter: std.fs.Dir.Iterator,
    close_on_pop: bool,
    depth: usize,
    prefix_len: usize,
};

pub const Walker = struct {
    allocator: Allocator,
    options: Options,
    matcher: ?glob.Matcher,
    frames: std.ArrayListUnmanaged(Frame) = .empty,
    path_buffer: std.ArrayListUnmanaged(u8) = .empty,
    visited_dirs: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(allocator: Allocator, root_dir: std.fs.Dir, options: Options) (Allocator.Error || glob.Error)!Walker {
        var walker = Walker{
            .allocator = allocator,
            .options = options,
            .matcher = if (options.pattern) |pattern| try glob.Matcher.init(pattern, .{ .style = options.style }) else null,
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

    pub fn deinit(self: *Walker) void {
        const allocator = self.allocator;
        for (self.frames.items) |frame| {
            if (frame.close_on_pop) frame.dir.close();
        }

        var it = self.visited_dirs.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.visited_dirs.deinit(allocator);
        self.frames.deinit(allocator);
        self.path_buffer.deinit(allocator);
        self.* = undefined;
    }

    pub fn next(self: *Walker) !?Entry {
        const style = self.options.style.resolve();

        while (self.frames.items.len != 0) {
            var top = &self.frames.items[self.frames.items.len - 1];
            self.path_buffer.shrinkRetainingCapacity(top.prefix_len);

            const maybe_base = top.iter.next() catch |err| {
                const frame = self.frames.pop().?;
                self.path_buffer.shrinkRetainingCapacity(if (self.frames.items.len == 0) 0 else self.frames.items[self.frames.items.len - 1].prefix_len);
                if (frame.close_on_pop) frame.dir.close();
                return err;
            };

            if (maybe_base == null) {
                const frame = self.frames.pop().?;
                self.path_buffer.shrinkRetainingCapacity(if (self.frames.items.len == 0) 0 else self.frames.items[self.frames.items.len - 1].prefix_len);
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

    fn matchesFilters(self: *Walker, kind: std.fs.Dir.Entry.Kind, basename: []const u8, rel_path: []const u8) bool {
        if (kind == .directory) {
            if (self.options.extension != null) return false;
            if (self.matcher) |matcher| return matcher.matches(rel_path);
            return true;
        }

        if (self.options.extension) |ext| {
            const actual_ext = path.Path.initWithStyle(self.options.style, basename).extension();
            if (!std.mem.eql(u8, actual_ext, ext)) return false;
        }

        if (self.matcher) |matcher| return matcher.matches(rel_path);
        return true;
    }

    fn tryPushChildDir(self: *Walker, parent_dir: std.fs.Dir, name: []const u8, kind: std.fs.Dir.Entry.Kind, rel_path: []const u8, depth: usize) !void {
        const should_open = switch (kind) {
            .directory => true,
            .sym_link => self.options.follow_symlinks,
            else => false,
        };
        if (!should_open) return;

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

pub fn init(allocator: Allocator, root_dir: std.fs.Dir, options: Options) (Allocator.Error || glob.Error)!Walker {
    return Walker.init(allocator, root_dir, options);
}

fn shouldDescend(options: Options, depth: usize, kind: std.fs.Dir.Entry.Kind) bool {
    if (kind != .directory and !(kind == .sym_link and options.follow_symlinks)) return false;
    if (options.max_depth) |max_depth| return depth < max_depth;
    return true;
}

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

        const main_file = try src_dir.createFile("main.zig", .{});
        main_file.close();

        const note_file = try src_dir.createFile("notes.txt", .{});
        note_file.close();
    }

    {
        var hidden_dir = try sandbox.dir.openDir(".hidden", .{});
        defer hidden_dir.close();

        const hidden_file = try hidden_dir.createFile("secret.zig", .{});
        hidden_file.close();
    }

    var walker = try Walker.init(allocator, sandbox.dir, .{
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

test {
    std.testing.refAllDecls(@This());
}
