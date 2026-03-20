//! Filesystem-independent glob pattern matching.
//!
//! Matching is purely string-based - no filesystem access occurs.
//! Patterns are validated on construction; see `Error` for invalid-pattern cases.
//!
//! Supported syntax:
//! - `*`       - any sequence of characters within a single path segment
//! - `**`      - any sequence of characters across segment boundaries (recursive)
//! - `?`       - exactly one character (not a separator)
//! - `[abc]`   - character class: matches any listed character
//! - `[a-z]`   - character class with range
//! - `[!abc]`  - negated character class
//! - `\x`     - escape metacharacter `x` (when `Options.escapes = true`)

const std = @import("std");
const path = @import("path.zig");

const Allocator = std.mem.Allocator;
const mem = std.mem;

// -- Options -----------------------------------------------------------------

/// Options controlling glob matching behavior.
pub const Options = struct {
    /// Path style used when interpreting separator characters.
    style: path.Style = .native,
    /// Whether backslash escapes are interpreted.
    escapes: bool = true,
};

// -- Errors ------------------------------------------------------------------

/// Errors that can occur when compiling a glob pattern.
pub const Error = error{
    /// A `[` was not matched by a closing `]`.
    UnclosedCharacterClass,
    /// A character class `[]` contains no characters.
    EmptyCharacterClass,
    /// Escape handling is enabled and pattern ends with a trailing `\`.
    TrailingEscape,
    /// A `{` was not matched by a closing `}`.
    UnclosedBrace,
    /// Brace nesting exceeds the safety limit.
    BraceExpansionTooDeep,
    /// Number of brace groups exceeds the safety limit.
    TooManyBraceGroups,
};

const MAX_BRACE_GROUPS: usize = 256;
const MAX_BRACE_DEPTH: usize = 8;
const MAX_BRACE_PATTERN_BYTES: usize = 8192;
const MAX_BRACE_EXPANSIONS: usize = 1024;

const PatternTemplate = enum {
    none,
    literal,
    star_only,
    suffix,
    prefix,
    prefix_suffix,
};

const Compiled = struct {
    pattern: []const u8,
    options: Options,
    style: path.Style,
    has_wildcards: bool,
    has_braces: bool,
    required_last_char: ?u8,
    template: PatternTemplate,
    template_prefix: []const u8,
    template_suffix: []const u8,
};

// -- Matcher -----------------------------------------------------------------

/// A validated, lightweight glob matcher.
///
/// `Matcher` does not allocate - the pattern string is borrowed.
/// For owned, heap-allocated patterns see `Pattern`.
pub const Matcher = struct {
    compiled: Compiled,

    /// Creates a `Matcher` after validating the pattern.
    ///
    /// Returns `error.UnclosedCharacterClass`, `error.EmptyCharacterClass`, or
    /// `error.TrailingEscape` if the pattern is malformed.
    pub fn init(pattern: []const u8, options: Options) Error!Matcher {
        return .{ .compiled = try compilePattern(pattern, options) };
    }

    /// Returns true if `candidate` matches this pattern.
    pub fn matches(self: Matcher, candidate: []const u8) bool {
        return matchCompiled(self.compiled, candidate);
    }
};

// -- Pattern -----------------------------------------------------------------

/// A compiled, heap-allocated glob pattern.
///
/// Use when the pattern string lifetime cannot be guaranteed to outlive the matcher,
/// or when patterns are constructed at runtime.
/// Caller must call `deinit` when done.
pub const Pattern = struct {
    pattern: []u8,
    compiled: Compiled,

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
        _ = try compilePattern(pattern_str, options);
        const owned = try alloc.dupe(u8, pattern_str);

        return .{
            .pattern = owned,
            .compiled = try compilePattern(owned, options),
        };
    }

    /// Releases the allocated pattern string.
    pub fn deinit(self: *Pattern, alloc: Allocator) void {
        alloc.free(self.pattern);
        self.* = undefined;
    }

    /// Returns true if `candidate` matches this pattern.
    pub fn match(self: Pattern, candidate: []const u8) bool {
        return matchCompiled(self.compiled, candidate);
    }
};

// -- Convenience functions ----------------------------------------------------

/// Compiles and matches in a single call.
///
/// Returns `error.UnclosedCharacterClass`, `error.EmptyCharacterClass`, or
/// `error.TrailingEscape` for invalid patterns.
pub fn match(pattern: []const u8, candidate: []const u8, options: Options) Error!bool {
    return (try Matcher.init(pattern, options)).matches(candidate);
}

/// Returns a statically-validated matcher function for use in comptime contexts.
///
/// The pattern is validated at compile time; invalid patterns cause a compile error.
pub fn comptimeMatcher(comptime pattern: []const u8, comptime options: Options) fn ([]const u8) bool {
    comptime {
        _ = compilePattern(pattern, options) catch @compileError("invalid glob pattern");
    }

    return struct {
        fn matches(candidate: []const u8) bool {
            const compiled = compilePattern(pattern, options) catch unreachable;
            return matchCompiled(compiled, candidate);
        }
    }.matches;
}

// -- Internal ----------------------------------------------------------------

fn compilePattern(pattern: []const u8, options: Options) Error!Compiled {
    try validatePattern(pattern, options.escapes);
    const has_wildcards = hasWildcards(pattern, options.escapes);
    const has_braces = hasUnescapedBrace(pattern, options.escapes);
    const required_last_char = requiredLastChar(pattern, options.escapes);
    const style = options.style.resolve();

    const template = detectTemplate(pattern, options.escapes, has_wildcards);

    return .{
        .pattern = pattern,
        .options = options,
        .style = style,
        .has_wildcards = has_wildcards,
        .has_braces = has_braces,
        .required_last_char = required_last_char,
        .template = template.kind,
        .template_prefix = template.prefix,
        .template_suffix = template.suffix,
    };
}

fn matchCompiled(compiled: Compiled, candidate: []const u8) bool {
    if (compiled.has_braces) {
        var state = BraceState{ .expansions = 0 };
        return matchWithBraces(compiled.pattern, candidate, compiled.style, compiled.options.escapes, &state, 0);
    }

    if (compiled.required_last_char) |last| {
        if (candidate.len == 0 or candidate[candidate.len - 1] != last) return false;
    }

    if (matchTemplate(compiled, candidate)) |res| return res;

    return matchUnchecked(compiled.pattern, 0, candidate, 0, compiled.style, compiled.options.escapes);
}

fn validatePattern(pattern: []const u8, escapes: bool) Error!void {
    var brace_depth: usize = 0;
    var brace_groups: usize = 0;

    var index: usize = 0;
    while (index < pattern.len) : (index += 1) {
        const byte = pattern[index];

        if (escapes and byte == '\\') {
            if (index + 1 >= pattern.len) return error.TrailingEscape;
            index += 1;
            continue;
        }

        if (byte == '{') {
            brace_depth += 1;
            if (brace_depth > MAX_BRACE_DEPTH) return error.BraceExpansionTooDeep;
            continue;
        }

        if (byte == '}') {
            if (brace_depth == 0) return error.UnclosedBrace;
            brace_depth -= 1;
            if (brace_depth == 0) {
                brace_groups += 1;
                if (brace_groups > MAX_BRACE_GROUPS) return error.TooManyBraceGroups;
            }
            continue;
        }

        if (byte != '[') continue;
        const end = findClassEnd(pattern, index, escapes) orelse return error.UnclosedCharacterClass;
        if (classCharStart(pattern, index) >= end) return error.EmptyCharacterClass;
        index = end;
    }

    if (brace_depth != 0) return error.UnclosedBrace;
}

fn hasWildcards(pattern: []const u8, escapes: bool) bool {
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (escapes and pattern[i] == '\\') {
            if (i + 1 < pattern.len) i += 1;
            continue;
        }
        switch (pattern[i]) {
            '*', '?', '[' => return true,
            else => {},
        }
    }
    return false;
}

fn hasUnescapedBrace(pattern: []const u8, escapes: bool) bool {
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (escapes and pattern[i] == '\\') {
            if (i + 1 < pattern.len) i += 1;
            continue;
        }
        if (pattern[i] == '{') return true;
    }
    return false;
}

fn requiredLastChar(pattern: []const u8, escapes: bool) ?u8 {
    if (pattern.len == 0) return null;

    var i: usize = pattern.len;
    while (i > 0) {
        i -= 1;
        const ch = pattern[i];

        if (escapes and ch == '\\') {
            // If the pattern ends in a valid escape, the escaped byte determines last char.
            if (i + 1 < pattern.len and i + 1 == pattern.len - 1) return pattern[i + 1];
            continue;
        }

        if (ch == '*' or ch == '?' or ch == ']') return null;
        return ch;
    }

    return null;
}

fn detectTemplate(pattern: []const u8, escapes: bool, has_wildcards: bool) struct { kind: PatternTemplate, prefix: []const u8, suffix: []const u8 } {
    if (hasUnescapedBrace(pattern, escapes)) {
        return .{ .kind = .none, .prefix = "", .suffix = "" };
    }

    if (escapes and mem.indexOfScalar(u8, pattern, '\\') != null) {
        return .{ .kind = .none, .prefix = "", .suffix = "" };
    }

    if (!has_wildcards) {
        return .{ .kind = .literal, .prefix = pattern, .suffix = "" };
    }

    var star_count: usize = 0;
    var has_q_or_class = false;
    var first_star: ?usize = null;

    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (escapes and pattern[i] == '\\' and i + 1 < pattern.len) {
            i += 1;
            continue;
        }

        switch (pattern[i]) {
            '*' => {
                star_count += 1;
                if (first_star == null) first_star = i;
            },
            '?', '[' => has_q_or_class = true,
            else => {},
        }
    }

    if (!has_q_or_class and pattern.len == 1 and pattern[0] == '*') {
        return .{ .kind = .star_only, .prefix = "", .suffix = "" };
    }

    if (has_q_or_class or star_count != 1) {
        return .{ .kind = .none, .prefix = "", .suffix = "" };
    }

    const pos = first_star.?;
    if (pos == 0 and pattern.len > 1) {
        return .{ .kind = .suffix, .prefix = "", .suffix = pattern[1..] };
    }
    if (pos == pattern.len - 1) {
        return .{ .kind = .prefix, .prefix = pattern[0..pos], .suffix = "" };
    }
    return .{ .kind = .prefix_suffix, .prefix = pattern[0..pos], .suffix = pattern[pos + 1 ..] };
}

fn matchTemplate(compiled: Compiled, candidate: []const u8) ?bool {
    return switch (compiled.template) {
        .none => null,
        .literal => mem.eql(u8, compiled.template_prefix, candidate),
        .star_only => blk: {
            for (candidate) |ch| {
                if (compiled.style.isSep(ch)) break :blk false;
            }
            break :blk true;
        },
        .suffix => blk: {
            if (candidate.len < compiled.template_suffix.len) break :blk false;
            const start = candidate.len - compiled.template_suffix.len;
            if (start > 0 and compiled.style.isSep(candidate[start - 1]) and compiled.style.isSep(compiled.template_suffix[0])) {
                break :blk false;
            }
            break :blk mem.eql(u8, candidate[start..], compiled.template_suffix);
        },
        .prefix => {
            if (!mem.startsWith(u8, candidate, compiled.template_prefix)) return false;
            // Ensure '*' tail does not cross separator.
            const rest = candidate[compiled.template_prefix.len..];
            for (rest) |ch| {
                if (compiled.style.isSep(ch)) return false;
            }
            return true;
        },
        .prefix_suffix => {
            const min_len = compiled.template_prefix.len + compiled.template_suffix.len;
            if (candidate.len < min_len) return false;
            if (!mem.startsWith(u8, candidate, compiled.template_prefix)) return false;
            if (!mem.endsWith(u8, candidate, compiled.template_suffix)) return false;
            const middle = candidate[compiled.template_prefix.len .. candidate.len - compiled.template_suffix.len];
            for (middle) |ch| {
                if (compiled.style.isSep(ch)) return false;
            }
            return true;
        },
    };
}

fn matchUnchecked(
    pattern: []const u8,
    pattern_index: usize,
    candidate: []const u8,
    candidate_index: usize,
    style: path.Style,
    escapes: bool,
) bool {
    var p_index = pattern_index;
    var c_index = candidate_index;

    while (true) {
        if (p_index >= pattern.len) return c_index >= candidate.len;

        if (escapes and pattern[p_index] == '\\') {
            if (p_index + 1 >= pattern.len) return false;
            if (c_index >= candidate.len or candidate[c_index] != pattern[p_index + 1]) return false;
            p_index += 2;
            c_index += 1;
            continue;
        }

        switch (pattern[p_index]) {
            '*' => {
                var star_count: usize = 1;
                while (p_index + star_count < pattern.len and pattern[p_index + star_count] == '*') {
                    star_count += 1;
                }
                const cross_segments = star_count >= 2;
                const next_p = p_index + star_count;

                if (next_p >= pattern.len) {
                    if (cross_segments) return true;
                    for (candidate[c_index..]) |ch| {
                        if (style.isSep(ch)) return false;
                    }
                    return true;
                }

                var next_c = c_index;
                const next_literal = nextLiteralAfterStar(pattern, next_p, escapes);

                if (next_literal) |literal| {
                    while (true) {
                        if (next_c >= candidate.len) return false;
                        const found_offset = simdFindChar(candidate[next_c..], literal) orelse return false;
                        next_c += found_offset;

                        if (!cross_segments and style.isSep(candidate[next_c])) return false;
                        if (matchUnchecked(pattern, next_p, candidate, next_c, style, escapes)) return true;

                        if (next_c >= candidate.len) return false;
                        if (!cross_segments and style.isSep(candidate[next_c])) return false;
                        next_c += 1;
                    }
                }

                while (true) {
                    if (matchUnchecked(pattern, next_p, candidate, next_c, style, escapes)) return true;
                    if (next_c >= candidate.len) return false;
                    if (!cross_segments and style.isSep(candidate[next_c])) return false;
                    next_c += 1;
                }
            },
            '?' => {
                if (c_index >= candidate.len or style.isSep(candidate[c_index])) return false;
                p_index += 1;
                c_index += 1;
            },
            '[' => {
                const end = findClassEnd(pattern, p_index, escapes) orelse return false;
                if (c_index >= candidate.len or style.isSep(candidate[c_index])) return false;
                if (!matchClass(pattern[p_index .. end + 1], candidate[c_index], escapes)) return false;
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

fn nextLiteralAfterStar(pattern: []const u8, next_index: usize, escapes: bool) ?u8 {
    if (next_index >= pattern.len) return null;

    if (escapes and pattern[next_index] == '\\') {
        if (next_index + 1 < pattern.len) return pattern[next_index + 1];
        return null;
    }

    return switch (pattern[next_index]) {
        '*', '?', '[' => null,
        else => pattern[next_index],
    };
}

fn simdFindChar(haystack: []const u8, needle: u8) ?usize {
    const vec_len = std.simd.suggestVectorLength(u8) orelse 16;
    if (haystack.len < vec_len) {
        for (haystack, 0..) |ch, idx| {
            if (ch == needle) return idx;
        }
        return null;
    }

    const Vec = @Vector(vec_len, u8);
    const MaskInt = std.meta.Int(.unsigned, vec_len);
    const needle_vec: Vec = @splat(needle);

    var i: usize = 0;
    while (i + vec_len <= haystack.len) : (i += vec_len) {
        const chunk: Vec = haystack[i..][0..vec_len].*;
        const mask = @as(MaskInt, @bitCast(chunk == needle_vec));
        if (mask != 0) {
            return i + @ctz(mask);
        }
    }

    for (haystack[i..], i..) |ch, idx| {
        if (ch == needle) return idx;
    }
    return null;
}

fn findClassEnd(pattern: []const u8, index: usize, escapes: bool) ?usize {
    var cursor = index + 1;
    if (cursor < pattern.len and (pattern[cursor] == '!' or pattern[cursor] == '^')) cursor += 1;

    while (cursor < pattern.len) : (cursor += 1) {
        if (escapes and pattern[cursor] == '\\' and cursor + 1 < pattern.len) {
            cursor += 1;
            continue;
        }
        if (pattern[cursor] == ']') return cursor;
    }
    return null;
}

fn classCharStart(pattern: []const u8, index: usize) usize {
    var cursor = index + 1;
    if (cursor < pattern.len and (pattern[cursor] == '!' or pattern[cursor] == '^')) cursor += 1;
    return cursor;
}

/// Matches `byte` against a bracket expression `[...]`.
fn matchClass(class_pattern: []const u8, byte: u8, escapes: bool) bool {
    const negated = class_pattern.len >= 3 and (class_pattern[1] == '!' or class_pattern[1] == '^');
    var matched = false;
    var index: usize = if (negated) 2 else 1;

    while (index + 1 < class_pattern.len) {
        if (class_pattern[index] == ']') break;

        var current = class_pattern[index];
        if (escapes and current == '\\' and index + 2 < class_pattern.len) {
            current = class_pattern[index + 1];
            index += 1;
        }

        if (index + 3 < class_pattern.len and class_pattern[index + 1] == '-' and class_pattern[index + 2] != ']') {
            var range_end = class_pattern[index + 2];
            if (escapes and range_end == '\\' and index + 3 < class_pattern.len) {
                range_end = class_pattern[index + 3];
                if (byte >= current and byte <= range_end) {
                    matched = true;
                    break;
                }
                index += 4;
                continue;
            }

            if (byte >= current and byte <= range_end) {
                matched = true;
                break;
            }
            index += 3;
            continue;
        }

        if (current == byte) {
            matched = true;
            break;
        }
        index += 1;
    }

    return if (negated) !matched else matched;
}

const BraceState = struct {
    expansions: usize,
};

fn matchWithBraces(
    pattern: []const u8,
    candidate: []const u8,
    style: path.Style,
    escapes: bool,
    state: *BraceState,
    depth: usize,
) bool {
    if (depth > MAX_BRACE_DEPTH) return false;

    const open = findFirstUnescaped(pattern, '{', escapes) orelse {
        return matchUnchecked(pattern, 0, candidate, 0, style, escapes);
    };
    const close = findMatchingBrace(pattern, open, escapes) orelse return false;

    const prefix = pattern[0..open];
    const body = pattern[open + 1 .. close];
    const suffix = pattern[close + 1 ..];

    var cursor: usize = 0;
    var alt_start: usize = 0;
    var nested: usize = 0;
    while (cursor <= body.len) : (cursor += 1) {
        const is_end = cursor == body.len;
        if (!is_end) {
            const ch = body[cursor];
            if (escapes and ch == '\\' and cursor + 1 < body.len) {
                cursor += 1;
                continue;
            }
            if (ch == '{') {
                nested += 1;
                continue;
            }
            if (ch == '}') {
                if (nested > 0) nested -= 1;
                continue;
            }
            if (ch != ',' or nested != 0) continue;
        }

        const alt = body[alt_start..cursor];
        if (state.expansions >= MAX_BRACE_EXPANSIONS) return false;
        state.expansions += 1;

        const total_len = prefix.len + alt.len + suffix.len;
        if (total_len > MAX_BRACE_PATTERN_BYTES) return false;

        var rebuilt: [MAX_BRACE_PATTERN_BYTES]u8 = undefined;
        @memcpy(rebuilt[0..prefix.len], prefix);
        @memcpy(rebuilt[prefix.len .. prefix.len + alt.len], alt);
        @memcpy(rebuilt[prefix.len + alt.len .. total_len], suffix);

        if (matchWithBraces(rebuilt[0..total_len], candidate, style, escapes, state, depth + 1)) {
            return true;
        }

        alt_start = cursor + 1;
    }

    return false;
}

fn findFirstUnescaped(pattern: []const u8, needle: u8, escapes: bool) ?usize {
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (escapes and pattern[i] == '\\' and i + 1 < pattern.len) {
            i += 1;
            continue;
        }
        if (pattern[i] == needle) return i;
    }
    return null;
}

fn findMatchingBrace(pattern: []const u8, open_index: usize, escapes: bool) ?usize {
    var depth: usize = 1;
    var i: usize = open_index + 1;
    while (i < pattern.len) : (i += 1) {
        const ch = pattern[i];
        if (escapes and ch == '\\' and i + 1 < pattern.len) {
            i += 1;
            continue;
        }
        if (ch == '{') {
            depth += 1;
            continue;
        }
        if (ch == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

// -- Tests -------------------------------------------------------------------

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

test "glob escaping literals" {
    try std.testing.expect(try match("file\\*.txt", "file*.txt", .{}));
    try std.testing.expect(!(try match("file\\*.txt", "fileA.txt", .{})));
    try std.testing.expect(try match("\\[abc\\]", "[abc]", .{}));
    try std.testing.expectError(error.TrailingEscape, match("abc\\", "abc", .{}));
}

test "glob escaping disabled" {
    try std.testing.expect(!(try match("file\\*.txt", "file*.txt", .{ .escapes = false })));
}

test "glob brace expansion" {
    try std.testing.expect(try match("src/*.{zig,zon}", "src/main.zig", .{ .style = .posix }));
    try std.testing.expect(try match("src/*.{zig,zon}", "src/build.zon", .{ .style = .posix }));
    try std.testing.expect(!(try match("src/*.{zig,zon}", "src/readme.md", .{ .style = .posix })));
}

test "glob nested brace expansion" {
    try std.testing.expect(try match("{src,lib}/**/*.{zig,{toml,zon}}", "lib/core/build.zon", .{ .style = .posix }));
    try std.testing.expect(try match("{src,lib}/**/*.{zig,{toml,zon}}", "src/x/config.toml", .{ .style = .posix }));
}

test "glob brace validation" {
    try std.testing.expectError(error.UnclosedBrace, match("src/{a,b", "src/a", .{ .style = .posix }));
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
