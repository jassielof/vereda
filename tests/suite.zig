const std = @import("std");
const refAllDecls = std.testing.refAllDecls;

test {
    refAllDecls(@This());

    refAllDecls(@import("fs.zig"));
    refAllDecls(@import("glob.zig"));
    refAllDecls(@import("walk.zig"));
}
