//! Filesystem-independent glob matching.

const std = @import("std");
const path = @import("path");

pub const Options = struct {
    style: path.Style = .native,
};

pub const Error = error{
    UnclosedCharacterClass,
    EmptyCharacterClass,
};

pub const Matcher = struct {
    pattern: []const u8,
    options: Options,

    pub fn init(pattern: []const u8, options: Options) Error!Matcher {
        try validatePattern(pattern);
        return .{ .pattern = pattern, .options = options };
    }

    pub fn matches(self: Matcher, candidate: []const u8) bool {
        return matchUnchecked(self.pattern, 0, candidate, 0, self.options.style.resolve());
    }
};

pub fn match(pattern: []const u8, candidate: []const u8, options: Options) Error!bool {
    return (try Matcher.init(pattern, options)).matches(candidate);
}

pub fn comptimeMatcher(comptime pattern: []const u8, comptime options: Options) fn ([]const u8) bool {
    comptime {
        _ = validatePattern(pattern) catch @compileError("invalid glob pattern");
    }

    return struct {
        fn matches(candidate: []const u8) bool {
            return matchUnchecked(pattern, 0, candidate, 0, options.style.resolve());
        }
    }.matches;
}

fn validatePattern(pattern: []const u8) Error!void {
    var index: usize = 0;
    while (index < pattern.len) : (index += 1) {
        if (pattern[index] != '[') continue;
        const end = findClassEnd(pattern, index) orelse return error.UnclosedCharacterClass;
        if (classCharStart(pattern, index) >= end) return error.EmptyCharacterClass;
        index = end;
    }
}

fn matchUnchecked(pattern: []const u8, pattern_index: usize, candidate: []const u8, candidate_index: usize, style: path.Style) bool {
    var p_index = pattern_index;
    var c_index = candidate_index;

    while (true) {
        if (p_index >= pattern.len) return c_index >= candidate.len;

        switch (pattern[p_index]) {
            '*' => {
                if (p_index + 1 < pattern.len and pattern[p_index + 1] == '*') {
                    var next_pattern_index = p_index + 2;
                    while (next_pattern_index < pattern.len and pattern[next_pattern_index] == '*') {
                        next_pattern_index += 1;
                    }

                    var next_candidate_index = c_index;
                    while (true) {
                        if (matchUnchecked(pattern, next_pattern_index, candidate, next_candidate_index, style)) {
                            return true;
                        }
                        if (next_candidate_index >= candidate.len) return false;
                        next_candidate_index += 1;
                    }
                }

                var next_candidate_index = c_index;
                while (true) {
                    if (matchUnchecked(pattern, p_index + 1, candidate, next_candidate_index, style)) {
                        return true;
                    }
                    if (next_candidate_index >= candidate.len) return false;
                    if (style.isSep(candidate[next_candidate_index])) return false;
                    next_candidate_index += 1;
                }
            },
            '?' => {
                if (c_index >= candidate.len or style.isSep(candidate[c_index])) return false;
                p_index += 1;
                c_index += 1;
            },
            '[' => {
                const end = findClassEnd(pattern, p_index) orelse return false;
                if (c_index >= candidate.len or style.isSep(candidate[c_index])) return false;
                if (!matchClass(pattern[p_index .. end + 1], candidate[c_index])) return false;
                p_index = end + 1;
                c_index += 1;
            },
            else => {
                if (c_index >= candidate.len or candidate[c_index] != pattern[p_index]) return false;
                p_index += 1;
                c_index += 1;
            },
        }
    }
}

fn findClassEnd(pattern: []const u8, index: usize) ?usize {
    var cursor = index + 1;
    if (cursor < pattern.len and pattern[cursor] == '!') cursor += 1;
    while (cursor < pattern.len) : (cursor += 1) {
        if (pattern[cursor] == ']') return cursor;
    }
    return null;
}

fn classCharStart(pattern: []const u8, index: usize) usize {
    var cursor = index + 1;
    if (cursor < pattern.len and pattern[cursor] == '!') cursor += 1;
    return cursor;
}

fn matchClass(class_pattern: []const u8, byte: u8) bool {
    const negated = class_pattern.len >= 3 and class_pattern[1] == '!';
    var matched = false;
    var index: usize = if (negated) 2 else 1;
    while (index + 1 < class_pattern.len) : (index += 1) {
        if (class_pattern[index] == ']') break;
        if (class_pattern[index] == byte) {
            matched = true;
            break;
        }
    }
    return if (negated) !matched else matched;
}

test "glob wildcards respect separators" {
    try std.testing.expect(try match("src/*.zig", "src/lib.zig", .{ .style = .posix }));
    try std.testing.expect(!(try match("src/*.zig", "src/lib/root.zig", .{ .style = .posix })));
    try std.testing.expect(try match("src/**.zig", "src/lib/root.zig", .{ .style = .posix }));
}

test "glob question marks and classes" {
    try std.testing.expect(try match("file-?.txt", "file-a.txt", .{}));
    try std.testing.expect(try match("file-[abc].txt", "file-b.txt", .{}));
    try std.testing.expect(try match("file-[!abc].txt", "file-z.txt", .{}));
    try std.testing.expect(!(try match("file-[!abc].txt", "file-a.txt", .{})));
}

test "comptime matcher" {
    const matcher = comptimeMatcher("**/*.zig", .{ .style = .posix });
    try std.testing.expect(matcher("src/lib/root.zig"));
    try std.testing.expect(!matcher("README.md"));
}

test {
    std.testing.refAllDecls(@This());
}
