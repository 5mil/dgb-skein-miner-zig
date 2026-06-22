//! cpu.zig — runtime AVX2 detection via CPUID leaf 7.
const std = @import("std");

pub fn hasAvx2() bool {
    // CPUID leaf 7, sub-leaf 0: EBX bit 5 = AVX2
    // Only meaningful on x86_64.
    if (@import("builtin").cpu.arch != .x86_64) return false