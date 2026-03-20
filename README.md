# Vereda

Zig utilities library for path and filesystem manipulation.

## Glob matching

Vereda includes a filesystem-independent glob engine in src/lib/glob.zig.

Supported syntax:
- * matches any sequence within one path segment
- ** matches across segment boundaries
- ? matches one non-separator character
- [abc], [a-z], [!abc] character classes
- escaped metacharacters with backslash
- brace alternation with safety limits, including nested braces

Example:

```zig
const std = @import("std");
const vereda = @import("vereda");

test "glob examples" {
	try std.testing.expect(try vereda.glob.match("src/*.{zig,zon}", "src/main.zig", .{ .style = .posix }));
	try std.testing.expect(try vereda.glob.match("src/file\\*.txt", "src/file*.txt", .{ .style = .posix }));
}
```

## Walker with pattern filtering

The recursive walker in src/lib/walk.zig can filter entries by glob pattern.

```zig
const std = @import("std");
const vereda = @import("vereda");

test "walk with glob filter" {
	const alloc = std.testing.allocator;
	var walker = try vereda.walk.walk(alloc, ".", .{
		.style = .posix,
		.pattern = "src/**/{*.zig,*.zon}",
		.include_dirs = false,
	});
	defer walker.deinit();

	while (try walker.next()) |entry| {
		_ = entry;
	}
}
```

Notes:
- Pattern filtering is applied to relative paths.
- Walker uses conservative literal-prefix pruning to skip directory branches that cannot match fixed leading path parts.
- Walker also skips descent entirely when the pattern cannot match nested paths (for example `*.zig`).
- Escapes are enabled by default in glob matching.
