const std = @import("std");

pub fn rake_skein512_avx2_4way(
    in0: []const u8, in1: []const u8, in2: []const u8, in3: []const u8,
    out0: []u8, out1: []u8, out2: []u8, out3: []u8,
) void {
    // Full AVX2 4-way port coming
    std.debug.print("AVX2 4-way path (WIP)\n", .{{}});
}