//! cpu.zig -- runtime AVX2 detection via CPUID leaf 7.
const std = @import("std");
const builtin = @import("builtin");

pub fn hasAvx2() bool {
    if (builtin.cpu.arch != .x86_64) return false;
    // Check compile-time CPU features first (works on native builds)
    return std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);
}
