const std = @import("std");

pub fn initDispatch() void {
    if (std.cpu.x86.has_avx2()) {
        std.debug.print("AVX2 enabled\n", .{{}});
    } else {
        std.debug.print("Scalar fallback\n", .{{}});
    }
}