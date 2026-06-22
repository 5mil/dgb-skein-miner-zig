//! cpu.zig -- CPU feature detection for runtime dispatch.
const std     = @import("std");
const builtin = @import("builtin");

/// Returns true only on x86_64 builds compiled with AVX2 enabled.
/// On aarch64 (Moto G Power / Termux) always returns false.
pub fn hasAvx2() bool {
    if (comptime builtin.cpu.arch != .x86_64) return false;
    return std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);
}
