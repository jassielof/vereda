//! Filesystem-independent glob pattern matching.
//!
//! Matching is purely string-based — no filesystem access occurs.
//! Patterns are validated on construction; see `Error` for invalid-pattern cases.
//!
//! Supported syntax:
//! - `*`       — any sequence of characters within a single path segment
//! - `**`      — any sequence of characters across segment boundaries (recursive)
//! - `?`       — exactly one character (not a separator)
//! - `[abc]`   — character class: matches any listed character
//! - `[a-z]`   — character class with range
//! - `[!abc]`  — negated character class

const std = @import("std");
const path = @import("path.zig");

const Allocator = std.mem.Allocator;

// ── Options ───────────────────────────────────────────────────────────────────

/// Options controlling glob matching behaviour.
pub const Options = struct {
    /// Path style used when interpreting separator characters.
    style: path.Style = .native,
};

// ── Errors ────────────────────────────────────────────────────────────────────

/// Errors that can occur when compiling a glob pattern.
pub const Error = error{
    /// A `[` was not matched by a closing `]`.
    UnclosedCharacterClass,
    /// A character class `[]` contains no characters.
    EmptyCharacterClass,
};

// ── Matcher ───────────────────────────────────────────────────────────────────

/// A validated, lightweight glob matcher.
///
/// `Matcher` does not allocate — the pattern string is borrowed.
/// For owned, heap-allocated patterns see `Pattern`.
pub const Matcher = struct {
    pattern: []const u8,
    options: Options,

    /// Creates a `Matcher` after validating the pattern.
    ///
    /// Returns `error.UnclosedCharacterClass` or `error.EmptyCharacterClass`
    /// if the pattern is malformed.
    pub fn init(pattern: []const u8, options: Options) Error!Matcher {
        try validatePattern(pattern);
        return .{ .pattern = pattern, .options = options };
    }

    /// Returns true if `candidate` matches this pattern.
    pub fn matches(self: Matcher, candidate: []const u8) bool {
        return matchUnchecked(self.pattern, 0, candidate, 0, self.options.style.resolve());
    }
};

// ── Pattern ───────────────────────────────────────────────────────────────────

/// A compiled, heap-allocated glob pattern.
///
/// Use when the pattern string's lifetime cannot be guaranteed to outlive the matcher,
/// or when patterns are constructed at runtime.
/// Caller must call `deinit` when done.
pub const Pattern = struct {
    pattern: []u8,
    options: Options,

    /// Compiles `pattern_str` with default options and returns an owned `Pattern`.
    ///
    /// Caller owns the returned `Pattern`; call `deinit` when done.
    pub fn compile(alloc: Allocator, pattern_str: []const u8) (Error || Allocator.Error)!Pattern {
        return compileWithOptions(alloc, pattern_str, .{});
    }

    /// Compiles `pattern_str` with explicit `options` and returns an owned `Pattern`.
    ///
    /// Caller owns the returned `Pattern`; call `deinit` when done.
    pub fn compileWithOptions(alloc: Allocator, pattern_str: []const u8, options: Options) (Error || Allocator.Error)!Pattern {
        try validatePattern(pattern_str);
        const owned = try alloc.dupe(u8, pattern_str);
        return .{ .pattern = owned, .options = options };
    }

    /// Releases the allocated pattern string.
    pub fn deinit(self: *Pattern, alloc: Allocator) void {
        alloc.free(self.pattern);
        self.* = undefined;
    }

    /// Returns true if `candidate` matches this pattern.
    pub fn match(self: Pattern, candidate: []const u8) bool {
        return matchUnchecked(self.pattern, 0, candidate, 0, self.options.style.resolve());
    }
};

// ── Convenience functions ─────────────────────────────────────────────────────

/// Compiles and matches in a single call.
///
/// Returns `error.UnclosedCharacterClass` or `error.EmptyCharacterClass` for
/// invalid patterns.
pub fn match(pattern: []const u8, candidate: []const u8, options: Options) Error!bool {
    return (try Matcher.init(pattern, options)).matches(candidate);
}

/// Returns a statically-validated matcher function for use in comptime contexts.
///
/// The pattern is validated at compile time; invalid patterns cause a compile error.
///
/// ```zig
/// const isZig = glob.comptimeMatcher("**/*.zig", .{ .style = .posix });
/// isZig("src/lib/root.zig") // true
/// ```
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

// ── Internal ──────────────────────────────────────────────────────────────────

fn validatePattern(pattern: []const u8) Error!void {
    var index: usize = 0;
    while (index < pattern.len) : (index += 1) {
        if (pattern[index] != '[') continue;
        const end = findClassEnd(pattern, index) orelse return error.UnclosedCharacterClass;
        if (classCharStart(pattern, index) >= end) return error.EmptyCharacterClass;
        index = end;
    }
}

fn matchUnchecked(
    pattern: []const u8,
    pattern_index: usize,
    candidate: []const u8,
    candidate_index: usize,
    style: path.Style,
) bool {
    var p_index = pattern_index;
    var c_index = candidate_index;

    while (true) {
        if (p_index >= pattern.len) return c_index >= candidate.len;

        switch (pattern[p_index]) {
            '*' => {
                if (p_index + 1 < pattern.len and pattern[p_index + 1] == '*') {
                    // `**` — cross-segment wildcard
                    var next_p = p_index + 2;
                    while (next_p < pattern.len and pattern[next_p] == '*') next_p += 1;

                    var next_c = c_index;
                    while (true) {
                        if (matchUnchecked(pattern, next_p, candidate, next_c, style)) return true;
                        if (next_c >= candidate.len) return false;
                        next_c += 1;
                    }
                }

                // `*` — single-segment wildcard (does not cross separators)
                var next_c = c_index;
                while (true) {
                    if (matchUnchecked(pattern, p_index + 1, candidate, next_c, style)) return true;
                    if (next_c >= candidate.len) return false;
                    if (style.isSep(candidate[next_c])) return false;
                    next_c += 1;
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

/// Matches `byte` against a bracket expression `[…]`.
///
/// Supports:
/// - Literal characters: `[abc]`
/// - Ranges: `[a-z]`, `[0-9]`
/// - Negation: `[!abc]`, `[!a-z]`
fn matchClass(class_pattern: []const u8, byte: u8) bool {
    const negated = class_pattern.len >= 3 and class_pattern[1] == '!';
    var matched = false;
    var index: usize = if (negated) 2 else 1;

    while (index + 1 < class_pattern.len) {
        if (class_pattern[index] == ']') break;

        // Range: a-z (requires at least 3 chars: char, '-', char, before ']')
        if (index + 3 < class_pattern.len and
            class_pattern[index + 1] == '-' and
            class_pattern[index + 2] != ']')
        {
            if (byte >= class_pattern[index] and byte <= class_pattern[index + 2]) {
                matched = true;
                break;
            }
            index += 3;
            continue;
        }

        if (class_pattern[index] == byte) {
            matched = true;
            break;
        }
        index += 1;
    }

    return if (negated) !matched else matched;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

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

test "glob character class ranges" {
    try std.testing.expect(try match("[a-z].txt", "b.txt", .{}));
    try std.testing.expect(!(try match("[a-z].txt", "B.txt", .{})));
    try std.testing.expect(try match("[0-9].log", "5.log", .{}));
    try std.testing.expect(!(try match("[0-9].log", "a.log", .{})));
    try std.testing.expect(try match("[!0-9].txt", "a.txt", .{}));
    try std.testing.expect(!(try match("[!0-9].txt", "5.txt", .{})));
}

test "comptime matcher" {
    const matcher = comptimeMatcher("**/*.zig", .{ .style = .posix });
    try std.testing.expect(matcher("src/lib/root.zig"));
    try std.testing.expect(!matcher("README.md"));
}

test "Pattern compile and match" {
    const alloc = std.testing.allocator;
    var p = try Pattern.compile(alloc, "src/*.zig");
    defer p.deinit(alloc);
    try std.testing.expect(p.match("src/main.zig"));
    try std.testing.expect(!p.match("src/nested/main.zig"));
}

test "Pattern with options" {
    const alloc = std.testing.allocator;
    var p = try Pattern.compileWithOptions(alloc, "src/*.zig", .{ .style = .posix });
    defer p.deinit(alloc);
    try std.testing.expect(p.match("src/main.zig"));
}

test "invalid pattern errors" {
    try std.testing.expectError(error.UnclosedCharacterClass, match("[abc", "a", .{}));
    try std.testing.expectError(error.EmptyCharacterClass, match("[]", "a", .{}));
}

test {
    std.testing.refAllDecls(@This());
}
