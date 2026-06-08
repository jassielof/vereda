//! Integration tests for `walk` — uses real filesystem via `std.testing.tmpDir`.

const std = @import("std");
const walk_mod = @import("vereda").walk;

test "walk yields all files in a tree" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var sandbox = std.testing.tmpDir(.{});
    defer sandbox.cleanup();

    try sandbox.dir.createDir(io, "a", .default_dir);
    try sandbox.dir.createDirPath(io, "a/b");

    {
        const f = try sandbox.dir.createFile(io, "root.txt", .{});
        f.close(io);
    }
    {
        var a = try sandbox.dir.openDir(io, "a", .{});
        defer a.close(io);
        const f = try a.createFile(io, "a.txt", .{});
        f.close(io);
    }
    {
        var b = try sandbox.dir.openDir(io, "a/b", .{});
        defer b.close(io);
        const f = try b.createFile(io, "b.txt", .{});
        f.close(io);
    }

    // Use realpath so the `walk` free function can open with iterate rights
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_path = root_buf[0..try sandbox.dir.realPathFile(io, ".", &root_buf)];

    var walker = try walk_mod.walk(alloc, io, root_path, .{
        .style = .posix,
        .include_dirs = false,
    });
    defer walker.deinit();

    var names: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }

    while (try walker.next()) |entry| {
        try names.append(alloc, try alloc.dupe(u8, entry.path));
    }

    // Order is not guaranteed; sort for deterministic comparison
    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    try std.testing.expectEqual(@as(usize, 3), names.items.len);
    try std.testing.expectEqualStrings("a/a.txt", names.items[0]);
    try std.testing.expectEqualStrings("a/b/b.txt", names.items[1]);
    try std.testing.expectEqualStrings("root.txt", names.items[2]);
}

test "walk max_depth=0 yields only root-level entries" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var sandbox = std.testing.tmpDir(.{});
    defer sandbox.cleanup();

    try sandbox.dir.createDir(io, "subdir", .default_dir);
    {
        const f = try sandbox.dir.createFile(io, "top.txt", .{});
        f.close(io);
    }
    {
        var sub = try sandbox.dir.openDir(io, "subdir", .{});
        defer sub.close(io);
        const f = try sub.createFile(io, "deep.txt", .{});
        f.close(io);
    }

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_path = root_buf[0..try sandbox.dir.realPathFile(io, ".", &root_buf)];

    var walker = try walk_mod.walk(alloc, io, root_path, .{
        .style = .posix,
        .max_depth = 0,
        .include_dirs = false,
    });
    defer walker.deinit();

    var count: usize = 0;
    while (try walker.next()) |_| count += 1;

    try std.testing.expectEqual(@as(usize, 1), count);
}

test "walk glob pattern filters results" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var sandbox = std.testing.tmpDir(.{});
    defer sandbox.cleanup();

    {
        const f = try sandbox.dir.createFile(io, "main.zig", .{});
        f.close(io);
    }
    {
        const f = try sandbox.dir.createFile(io, "README.md", .{});
        f.close(io);
    }
    {
        const f = try sandbox.dir.createFile(io, "build.zig", .{});
        f.close(io);
    }

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_path = root_buf[0..try sandbox.dir.realPathFile(io, ".", &root_buf)];

    var walker = try walk_mod.walk(alloc, io, root_path, .{
        .style = .posix,
        .pattern = "*.zig",
        .include_dirs = false,
    });
    defer walker.deinit();

    var count: usize = 0;
    while (try walker.next()) |entry| {
        try std.testing.expect(std.mem.endsWith(u8, entry.basename, ".zig"));
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}
