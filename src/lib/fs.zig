//! Higher-level filesystem helpers.

const std = @import("std");
const path = @import("path");

const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidFormat,
};

pub fn move(allocator: Allocator, src_dir: std.fs.Dir, src: []const u8, dst_dir: std.fs.Dir, dst: []const u8) !void {
    std.fs.rename(src_dir, src, dst_dir, dst) catch |err| switch (err) {
        error.NotSameFileSystem => try moveAcrossDevices(allocator, src_dir, src, dst_dir, dst),
        else => return err,
    };
}

pub fn copyTree(allocator: Allocator, src_dir: std.fs.Dir, dst_dir: std.fs.Dir) !void {
    var it = src_dir.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .directory => {
                try dst_dir.makeDir(entry.name);
                var child_src = try src_dir.openDir(entry.name, .{ .iterate = true });
                defer child_src.close();
                var child_dst = try dst_dir.openDir(entry.name, .{});
                defer child_dst.close();
                try copyTree(allocator, child_src, child_dst);
            },
            .sym_link => {
                const buffer = try allocator.alloc(u8, std.fs.max_path_bytes);
                defer allocator.free(buffer);
                const target = try src_dir.readLink(entry.name, buffer);

                const is_directory = blk: {
                    if (src_dir.openDir(entry.name, .{})) |dir| {
                        dir.close();
                        break :blk true;
                    } else |_| {
                        break :blk false;
                    }
                };

                try dst_dir.symLink(target, entry.name, .{ .is_directory = is_directory });
            },
            else => try std.fs.Dir.copyFile(src_dir, entry.name, dst_dir, entry.name, .{}),
        }
    }
}

pub fn fromFileUri(allocator: Allocator, uri: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const parsed = try std.Uri.parse(uri);
    if (!std.mem.eql(u8, parsed.scheme, "file")) return error.InvalidFormat;

    if (parsed.host) |host| {
        const host_bytes = try host.toRawMaybeAlloc(arena);
        if (host_bytes.len != 0 and !std.mem.eql(u8, host_bytes, "localhost")) {
            return error.InvalidFormat;
        }
    }

    const raw_path = try parsed.path.toRawMaybeAlloc(arena);
    var decoded = try allocator.dupe(u8, raw_path);
    errdefer allocator.free(decoded);
    decoded = std.Uri.percentDecodeInPlace(decoded);

    if (builtinPathStyle() == .windows) {
        if (decoded.len >= 3 and decoded[0] == '/' and std.ascii.isAlphabetic(decoded[1]) and decoded[2] == ':') {
            std.mem.copyForwards(u8, decoded[0 .. decoded.len - 1], decoded[1..]);
            decoded = decoded[0 .. decoded.len - 1];
        }
        for (decoded) |*byte| {
            if (byte.* == '/') byte.* = '\\';
        }
    }

    return decoded;
}

pub fn toFileUri(allocator: Allocator, file_path: []const u8) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "file://");
    if (builtinPathStyle() == .windows) {
        try buf.append(allocator, '/');
    }

    for (file_path) |byte| {
        const normalized = if (builtinPathStyle() == .windows and byte == '\\') '/' else byte;
        switch (normalized) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '/', ':' => try buf.append(allocator, normalized),
            else => {
                try buf.append(allocator, '%');
                try buf.writer(allocator).print("{X:0>2}", .{normalized});
            },
        }
    }

    return buf.toOwnedSlice(allocator);
}

fn moveAcrossDevices(allocator: Allocator, src_dir: std.fs.Dir, src: []const u8, dst_dir: std.fs.Dir, dst: []const u8) !void {
    const link_buffer = try allocator.alloc(u8, std.fs.max_path_bytes);
    defer allocator.free(link_buffer);

    if (src_dir.readLink(src, link_buffer)) |target| {
        const is_directory = blk: {
            if (src_dir.openDir(src, .{})) |dir| {
                dir.close();
                break :blk true;
            } else |_| {
                break :blk false;
            }
        };

        try dst_dir.symLink(target, dst, .{ .is_directory = is_directory });
        try src_dir.deleteFile(src);
        return;
    } else |_| {}

    if (src_dir.openDir(src, .{ .iterate = true, .no_follow = true })) |directory| {
        var source_subdir = directory;
        defer source_subdir.close();

        try dst_dir.makeDir(dst);
        var dest_subdir = try dst_dir.openDir(dst, .{});
        defer dest_subdir.close();

        try copyTree(allocator, source_subdir, dest_subdir);
        try src_dir.deleteTree(src);
        return;
    } else |err| switch (err) {
        error.NotDir, error.FileNotFound => {},
        else => return err,
    }

    try std.fs.Dir.copyFile(src_dir, src, dst_dir, dst, .{});
    try src_dir.deleteFile(src);
}

fn builtinPathStyle() path.Style {
    return path.Style.native.resolve();
}

test "copyTree copies nested files" {
    const allocator = std.testing.allocator;

    var sandbox = std.testing.tmpDir(.{});
    defer sandbox.cleanup();

    try sandbox.dir.makeDir("src");
    try sandbox.dir.makeDir("dst");

    {
        var src_dir = try sandbox.dir.openDir("src", .{});
        defer src_dir.close();

        try src_dir.makeDir("nested");
        var nested_dir = try src_dir.openDir("nested", .{});
        defer nested_dir.close();

        var file = try nested_dir.createFile("hello.txt", .{});
        defer file.close();
        try file.writeAll("hello vereda");
    }

    var src_dir = try sandbox.dir.openDir("src", .{ .iterate = true });
    defer src_dir.close();
    var dst_dir = try sandbox.dir.openDir("dst", .{});
    defer dst_dir.close();

    try copyTree(allocator, src_dir, dst_dir);

    var copied_dir = try dst_dir.openDir("nested", .{});
    defer copied_dir.close();
    var copied_file = try copied_dir.openFile("hello.txt", .{});
    defer copied_file.close();

    var buffer: [64]u8 = undefined;
    const len = try copied_file.readAll(&buffer);
    try std.testing.expectEqualStrings("hello vereda", buffer[0..len]);
}

test "file uri round trip" {
    const allocator = std.testing.allocator;
    const native_path = if (builtinPathStyle() == .windows) "C:\\Users\\Jassiel\\notes.txt" else "/tmp/notes.txt";

    const uri = try toFileUri(allocator, native_path);
    defer allocator.free(uri);

    const round_trip = try fromFileUri(allocator, uri);
    defer allocator.free(round_trip);

    try std.testing.expectEqualStrings(native_path, round_trip);
}

test {
    std.testing.refAllDecls(@This());
}
