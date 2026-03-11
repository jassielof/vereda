const std = @import("std");
const vereda = @import("vereda");

test {
    std.testing.refAllDecls(vereda);
}
