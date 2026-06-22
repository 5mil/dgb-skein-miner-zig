//! cpu.zig — runtime AVX2 detection via CPUID leaf 7.
const std = @import("std");
const builtin = @import("builtin");

pub fn hasAvx2() bool {
    if (builtin.cpu.arch != .x86_64) return false;

    // CPUID leaf 7, sub-leaf 0: EBX bit 5 = AVX2
    var ebx: u32 = 0;
    asm volatile (
        "cpuid"
        : [ebx] "={ebx}" (ebx),
        : [leaf] "{eax}" (@as(u32, 7)),
          [subleaf] "{ecx}" (@as(u32, 0)),
        : "memory"
    );
    return (ebx >> 5) & 1 == 1;
}
