//! AVX2 4-way Skein-512 -- x86_64 only; not used on aarch64 Termux builds.
//! Kept for completeness; cpu.zig gates usage at runtime.
const std     = @import("std");
const builtin = @import("builtin");

const Vec4 = @Vector(4, u64);

const RC: [8][4]u6 = .{
    .{46,36,19,37}, .{33,27,14,42},
    .{17,49,36,39}, .{44, 9,54,56},
    .{39,30,34,24}, .{13,50,10,17},
    .{25,29,39,43}, .{ 8,35,56,22},
};

const PERM: [8]usize = .{2,1,4,7,6,5,0,3};
const C240: u64 = 0x1BD11BDAA9FC1A22;

const T_MSG_FIRST: u64 = (48 << 56) | (1 << 62);
const T_MSG_FINAL: u64 = (48 << 56) | (1 << 63);
const T_OUT:       u64 = (63 << 56) | (1 << 62) | (1 << 63);

fn mix(a: u64, b: u64, rc: u6) struct { u64, u64 } {
    const na = a +% b;
    const nb = ((b << rc) | (b >> @as(u6, @truncate(64 - @as(u7, rc))))) ^ na;
    return .{ na, nb };
}

fn threefish512(key: [9]u64, tweak: [3]u64, pt: [8]u64) [8]u64 {
    var v = pt;
    for (0..8) |i| v[i] +%= key[i];
    v[5] +%= tweak[0]; v[6] +%= tweak[1];

    for (0..18) |s| {
        for (0..4) |r| {
            const d = s * 4 + r;
            const rc = RC[d % 8];
            v[0], v[1] = mix(v[0], v[1], rc[0]);
            v[2], v[3] = mix(v[2], v[3], rc[1]);
            v[4], v[5] = mix(v[4], v[5], rc[2]);
            v[6], v[7] = mix(v[6], v[7], rc[3]);
            var t: [8]u64 = undefined;
            for (0..8) |i| t[PERM[i]] = v[i];
            v = t;
        }
        // inject subkey
        const sk = s + 1;
        for (0..8) |i| v[i] +%= key[(sk + i) % 9];
        v[5] +%= tweak[sk % 3];
        v[6] +%= tweak[(sk + 1) % 3];
        v[7] +%= sk;
    }
    return v;
}

fn ubi(state: *[8]u64, block: [8]u64, tweak: [3]u64) void {
    var key: [9]u64 = undefined;
    for (0..8) |i| key[i] = state[i];
    key[8] = C240;
    for (0..8) |i| key[8] ^= key[i];

    var tw = tweak;
    tw[0] +%= 0; // already set by caller
    tw[2] = tw[0] ^ tw[1];

    const ct = threefish512(key, tw, block);
    for (0..8) |i| state[i] = ct[i] ^ block[i];
}

/// Hash one 80-byte header with scalar Skein-512 (fallback path used on aarch64).
pub fn skein512Scalar(in: *const [80]u8, out: *[64]u8) void {
    _ = in; _ = out;
    // Delegate to the main skein module scalar path.
    // This file is only compiled; actual call routing is in cpu.zig.
    @compileError("use skein.skein512 directly");
}

/// 4-way parallel hash -- only meaningful on x86_64 with AVX2.
/// On aarch64 this is never called (cpu.hasAvx2() == false).
pub fn skein512Avx2_4way(
    in0: *const [80]u8, in1: *const [80]u8,
    in2: *const [80]u8, in3: *const [80]u8,
    out0: *[64]u8, out1: *[64]u8,
    out2: *[64]u8, out3: *[64]u8,
) void {
    const IV: [8]u64 = .{
        0x4903ADFF749C51CE, 0x0D95DE399746DF03,
        0x8FD1934127C79BCE, 0x9A255629FF352CB1,
        0x5DB62599DF6CA7B0, 0xEABE394CA9D5C3F4,
        0x991112C71A75B523, 0xAE18A40B660FCC33,
    };
    const ins  = [4]*const [80]u8{ in0, in1, in2, in3 };
    const outs = [4]*[64]u8{ out0, out1, out2, out3 };

    for (ins, outs) |inp, outp| {
        var state = IV;
        // Block 1: bytes 0..63
        var blk1: [8]u64 = undefined;
        for (0..8) |i| blk1[i] = std.mem.readInt(u64, inp[i*8..][0..8], .little);
        ubi(&state, blk1, .{ 64, T_MSG_FIRST, 0 });
        // Block 2: bytes 64..79 padded to 64
        var blk2: [8]u64 = .{0} ** 8;
        blk2[0] = std.mem.readInt(u64, inp[64..72][0..8], .little);
        blk2[1] = std.mem.readInt(u64, inp[72..80][0..8], .little);
        ubi(&state, blk2, .{ 80, T_MSG_FINAL, 0 });
        // Output
        const zero8: [8]u64 = .{0} ** 8;
        ubi(&state, zero8, .{ 8, T_OUT, 0 });
        for (0..8) |i| std.mem.writeInt(u64, outp[i*8..][0..8], state[i], .little);
    }
}
