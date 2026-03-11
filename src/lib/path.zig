//! Pure path manipulation helpers.
//!
//! This module intentionally performs zero filesystem access and avoids
//! importing `std.fs` so it remains usable in freestanding code.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const ascii = std.ascii;
const mem = std.mem;

pub const Style = enum {
    native,
    posix,
    windows,

    pub fn resolve(self: Style) Style {
        return switch (self) {
            .native => switch (builtin.target.os.tag) {
                .windows => .windows,
                else => .posix,
            },
            else => self,
        };
    }

    pub fn separator(self: Style) u8 {
        return switch (self.resolve()) {
            .posix => '/',
            .windows => '\\',
            .native => unreachable,
        };
    }

    pub fn isSep(self: Style, byte: u8) bool {
        return switch (self.resolve()) {
            .posix => byte == '/',
            .windows => byte == '/' or byte == '\\',
            .native => unreachable,
        };
    }
};

pub const Error = error{
    RequiresAbsolutePaths,
    DifferentRoots,
    InvalidName,
    NoFileName,
};

const RootKind = enum {
    none,
    rooted,
    drive,
    unc,
};

const RootInfo = struct {
    kind: RootKind,
    absolute: bool,
    root_len: usize,
    disk_designator_len: usize,
};

const Range = struct {
    start: usize,
    end: usize,
};

pub const Component = struct {
    name: []const u8,
    path: []const u8,
};

pub const Path = struct {
    bytes: []const u8,
    style: Style = .native,

    pub fn init(bytes: []const u8) Path {
        return .{ .bytes = bytes };
    }

    pub fn initWithStyle(style: Style, bytes: []const u8) Path {
        return .{ .bytes = bytes, .style = style };
    }

    pub fn slice(self: Path) []const u8 {
        return self.bytes;
    }

    pub fn basename(self: Path) []const u8 {
        return basenameStyle(self.style.resolve(), self.bytes);
    }

    pub fn stem(self: Path) []const u8 {
        return stemStyle(self.style.resolve(), self.bytes);
    }

    pub fn extension(self: Path) []const u8 {
        return extensionStyle(self.style.resolve(), self.bytes);
    }

    pub fn parent(self: Path) ?Path {
        const parent_bytes = dirnameStyle(self.style.resolve(), self.bytes) orelse return null;
        return .{ .bytes = parent_bytes, .style = self.style };
    }

    pub fn isAbsolute(self: Path) bool {
        return rootInfo(self.style.resolve(), self.bytes).absolute;
    }

    pub fn components(self: Path) Components {
        return Components.init(self);
    }

    pub fn parents(self: Path) Parents {
        return Parents.init(self);
    }

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
                while (base_it.next() != null) {
                    base_up_count += 1;
                }
                break;
            }

            if (maybe_base == null) {
                const target_component = maybe_target.?;
                mismatch_target_start = target_component.path.len - target_component.name.len;
                break;
            }

            const target_component = maybe_target.?;
            const base_component = maybe_base.?;
            if (!componentNameEqual(self_style, target_component.name, base_component.name)) {
                mismatch_target_start = target_component.path.len - target_component.name.len;
                base_up_count += 1;
                while (base_it.next() != null) {
                    base_up_count += 1;
                }
                break;
            }

            common_target_end = target_component.path.len;
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

pub const PathBuf = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    style: Style = .native,

    pub fn init(style: Style) PathBuf {
        return .{ .style = style };
    }

    pub fn fromSlice(allocator: Allocator, style: Style, bytes: []const u8) Allocator.Error!PathBuf {
        var buf = PathBuf.init(style);
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, bytes);
        return buf;
    }

    pub fn deinit(self: *PathBuf, allocator: Allocator) void {
        self.bytes.deinit(allocator);
        self.* = .{};
    }

    pub fn items(self: *const PathBuf) []const u8 {
        return self.bytes.items;
    }

    pub fn asPath(self: *const PathBuf) Path {
        return .{ .bytes = self.bytes.items, .style = self.style };
    }

    pub fn appendSlice(self: *PathBuf, allocator: Allocator, bytes: []const u8) Allocator.Error!void {
        try self.bytes.appendSlice(allocator, bytes);
    }

    pub fn appendByte(self: *PathBuf, allocator: Allocator, byte: u8) Allocator.Error!void {
        try self.bytes.append(allocator, byte);
    }
};

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

    pub fn next(self: *Components) ?Component {
        const style = self.path.style.resolve();
        const bytes = self.path.bytes;

        var start = self.cursor;
        while (start < bytes.len and style.isSep(bytes[start])) {
            start += 1;
        }
        if (start >= bytes.len) {
            self.cursor = bytes.len;
            return null;
        }

        var end = start;
        while (end < bytes.len and !style.isSep(bytes[end])) {
            end += 1;
        }

        self.cursor = end;
        return .{
            .name = bytes[start..end],
            .path = bytes[0..end],
        };
    }
};

pub const Parents = struct {
    current: ?Path,

    pub fn init(path: Path) Parents {
        const style = path.style.resolve();
        return .{
            .current = if (dirnameStyle(style, path.bytes)) |parent_bytes|
                Path.initWithStyle(style, parent_bytes)
            else
                null,
        };
    }

    pub fn next(self: *Parents) ?Path {
        const current = self.current orelse return null;
        const style = current.style.resolve();
        self.current = if (dirnameStyle(style, current.bytes)) |parent_bytes|
            Path.initWithStyle(style, parent_bytes)
        else
            null;
        return current;
    }
};

fn rootInfo(style: Style, path: []const u8) RootInfo {
    return switch (style) {
        .posix => posixRootInfo(path),
        .windows => windowsRootInfo(path),
        .native => unreachable,
    };
}

fn posixRootInfo(path: []const u8) RootInfo {
    var root_len: usize = 0;
    while (root_len < path.len and path[root_len] == '/') {
        root_len += 1;
    }
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
            while (root_len < path.len and isWindowsSep(path[root_len])) {
                root_len += 1;
            }
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
        while (index < path.len and !isWindowsSep(path[index])) {
            index += 1;
        }
        if (index == server_start or index == path.len) {
            return .{ .kind = .rooted, .absolute = true, .root_len = 1, .disk_designator_len = 0 };
        }
        while (index < path.len and isWindowsSep(path[index])) {
            index += 1;
        }

        const share_start = index;
        while (index < path.len and !isWindowsSep(path[index])) {
            index += 1;
        }
        if (index == share_start) {
            return .{ .kind = .rooted, .absolute = true, .root_len = 1, .disk_designator_len = 0 };
        }
        while (index < path.len and isWindowsSep(path[index])) {
            index += 1;
        }

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
    while (end > info.root_len and !style.isSep(path[end - 1])) {
        end -= 1;
    }

    if (end <= info.root_len) {
        return if (info.root_len == 0) null else path[0..info.root_len];
    }

    while (end > info.root_len and style.isSep(path[end - 1])) {
        end -= 1;
    }

    if (end <= info.root_len) return path[0..info.root_len];
    return path[0..end];
}

fn fileNameRange(style: Style, path: []const u8) ?Range {
    if (path.len == 0) return null;

    const info = rootInfo(style, path);
    const end = trimmedEnd(style, path);
    if (end <= info.root_len) return null;

    var start = end;
    while (start > info.root_len and !style.isSep(path[start - 1])) {
        start -= 1;
    }

    return .{ .start = start, .end = end };
}

fn trimmedEnd(style: Style, path: []const u8) usize {
    if (path.len == 0) return 0;

    const info = rootInfo(style, path);
    var end = path.len;
    while (end > info.root_len and style.isSep(path[end - 1])) {
        end -= 1;
    }
    return end;
}

fn separatorRunLength(style: Style, path: []const u8, index: usize) usize {
    var cursor = index;
    while (cursor < path.len and style.isSep(path[cursor])) {
        cursor += 1;
    }
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
