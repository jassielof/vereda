//! Integration tests for `fs` — exercises real filesystem operations via
//! `std.testing.tmpDir`.

const std = @import("std");
const fs = @import("vereda").fs;

test "mkdirAll creates nested directories" {
    var sandbox = std.testing.tmpDir(.{});
    defer sandbox.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try sandbox.dir.realpath(".", &buf);

    const nested = try std.fs.path.join(std.testing.allocator, &.{ root, "a", "b", "c" });
    defer std.testing.allocator.free(nested);

    try fs.mkdirAll(nested);
    try std.testing.expect(fs.isDir(nested));

    // Idempotent — calling again must not error
    try fs.mkdirAll(nested);
}

test "writeFile and readFile round trip" {
    const alloc = std.testing.allocator;

    var sandbox = std.testing.tmpDir(.{});
    defer sandbox.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try sandbox.dir.realpath(".", &buf);

    const file_path = try std.fs.path.join(alloc, &.{ root, "greeting.txt" });
    defer alloc.free(file_path);

    const content = "hello vereda";
    try fs.writeFile(file_path, content);
    try std.testing.expect(fs.isFile(file_path));

    const read_back = try fs.readFile(alloc, file_path);
    defer alloc.free(read_back);
    try std.testing.expectEqualStrings(content, read_back);
}

test "exists returns false for missing path" {
    try std.testing.expect(!fs.exists("/this/path/does/not/exist/vereda_test_xyz"));
}

test "remove deletes a file" {
    const alloc = std.testing.allocator;

    var sandbox = std.testing.tmpDir(.{});
    defer sandbox.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try sandbox.dir.realpath(".", &buf);

    const p = try std.fs.path.join(alloc, &.{ root, "to_delete.txt" });
    defer alloc.free(p);

    try fs.writeFile(p, "bye");
    try std.testing.expect(fs.exists(p));

    try fs.remove(p);
    try std.testing.expect(!fs.exists(p));
}

test "removeAll removes a directory tree" {
    const alloc = std.testing.allocator;

    var sandbox = std.testing.tmpDir(.{});
    defer sandbox.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try sandbox.dir.realpath(".", &buf);

    const tree = try std.fs.path.join(alloc, &.{ root, "tree" });
    defer alloc.free(tree);

    try fs.mkdirAll(tree);
    const nested_file = try std.fs.path.join(alloc, &.{ tree, "nested.txt" });
    defer alloc.free(nested_file);
    try fs.writeFile(nested_file, "data");

    try fs.removeAll(alloc, tree);
    try std.testing.expect(!fs.exists(tree));

    // No-op on non-existent path
    try fs.removeAll(alloc, tree);
}

test "copyFile copies file content" {
    const alloc = std.testing.allocator;

    var sandbox = std.testing.tmpDir(.{});
    defer sandbox.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try sandbox.dir.realpath(".", &buf);

    const src = try std.fs.path.join(alloc, &.{ root, "src.txt" });
    defer alloc.free(src);
    const dst = try std.fs.path.join(alloc, &.{ root, "dst.txt" });
    defer alloc.free(dst);

    try fs.writeFile(src, "copy me");
    try fs.copyFile(src, dst);

    const read_back = try fs.readFile(alloc, dst);
    defer alloc.free(read_back);
    try std.testing.expectEqualStrings("copy me", read_back);
}

test "fileSize returns correct byte count" {
    const alloc = std.testing.allocator;

    var sandbox = std.testing.tmpDir(.{});
    defer sandbox.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try sandbox.dir.realpath(".", &buf);

    const p = try std.fs.path.join(alloc, &.{ root, "sized.txt" });
    defer alloc.free(p);

    const content = "0123456789";
    try fs.writeFile(p, content);

    const size = try fs.fileSize(p);
    try std.testing.expectEqual(@as(u64, content.len), size);
}

test "move renames a file" {
    const alloc = std.testing.allocator;

    var sandbox = std.testing.tmpDir(.{});
    defer sandbox.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try sandbox.dir.realpath(".", &buf);

    const src = try std.fs.path.join(alloc, &.{ root, "old.txt" });
    defer alloc.free(src);
    const dst = try std.fs.path.join(alloc, &.{ root, "new.txt" });
    defer alloc.free(dst);

    try fs.writeFile(src, "moving");
    try fs.move(alloc, src, dst);

    try std.testing.expect(!fs.exists(src));
    try std.testing.expect(fs.isFile(dst));
}
