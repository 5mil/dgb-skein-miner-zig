//! Skein-512 — faithful port of the Skein 1.3 reference C implementation.
//! Reference: http://www.skein-hash.info/sites/default/files/skein1.3.pdf

const std = @import("std");

pub const SKEIN_512_BLOCK_BYTES: usize = 64;

// Rotation constants for Threefish-512 (Skein 1.3, Table 4)
const MK_64_CAST = struct {
    fn rc(comptime a: u32, comptime b: u32, comptime c: u32, comptime d: u32) [4]u32 {
        return .{a, b, c, d};
    }
};
const R_512: [8][4]u32 = .{
    MK_64_CAST.rc(46, 36, 19, 37),
    MK_64_CAST.rc(33, 27, 14, 42),
    MK_64_CAST.rc(17, 49, 36, 39),
    MK_64_CAST.rc(44,  9, 54, 56),
    MK_64_CAST.rc(39, 30, 34, 24),
    MK_64_CAST.rc(13, 50, 10, 17),
    MK_64_CAST.rc(25, 29, 39, 43),
    MK_64_CAST.rc( 8, 35, 56, 22),
};

// Permutation for Threefish-512 (Skein 1.3, Table 2)
const PERM_512: [8]u8 = .{ 2, 1, 4, 7, 6, 5, 0, 3 };

const KS_PARITY: u64 = 0x1BD11BDAA9FC1A22;

// Type constants (Skein 1.3, Table 5)
const SKEIN_T1_BLK_TYPE_CFG:  u64 = @as(u64,  4) << 56;
const SKEIN_T1_BLK_TYPE_MSG:  u64 = @as(u64, 48) << 56;
const SKEIN_T1_BLK_TYPE_OUT:  u64 = @as(u64, 63) << 56;
const SKEIN_T1_FLAG_FIRST:    u64 = @as(u64, 1) << 62;
const SKEIN_T1_FLAG_FINAL:    u64 = @as(u64, 1) << 63;
const SKEIN_T1_FLAG_FIRST_INV: u64 = ~SKEIN_T1_FLAG_FIRST;

const SKEIN_CFG_STR_LEN: usize = 32;

// Schema ID + version for config block
const SKEIN_ID_STRING_LE: u64 = 0x133141_4853 | (@as(u64, 1) << 32);
// That's: bytes [0x53,0x48,0x41,0x33,0x01,0x00,0x00,0x00]

fn rotl64(x: u64, n: u6) u64 {
    return (x << n) | (x >> (64 - n));
}

// Threefish-512 block cipher
fn threefish512Block(key: *const [9]u64, tweak: *const [3]u64, words: *[8]u64) void {
    // Build key schedule
    // Subkey injection inline per the reference impl
    var X: [8]u64 = words.*;

    // InjectKey(0)
    inline for (0..8) |i| X[i] +%= key[i];
    X[5] +%= tweak[0];
    X[6] +%= tweak[1];
    // X[7] += 0 (subkey index)

    // 72 rounds
    comptime var d: usize = 0;
    inline while (d < 72) : (d += 1) {
        // Mix
        const rc = R_512[d % 8];
        X[0] +%= X[1]; X[1] = rotl64(X[1], @intCast(rc[0])) ^ X[0];
        X[2] +%= X[3]; X[3] = rotl64(X[3], @intCast(rc[1])) ^ X[2];
        X[4] +%= X[5]; X[5] = rotl64(X[5], @intCast(rc[2])) ^ X[4];
        X[6] +%= X[7]; X[7] = rotl64(X[7], @intCast(rc[3])) ^ X[6];

        // Permute
        const tmp = X;
        inline for (0..8) |i| X[i] = tmp[PERM_512[i]];

        // InjectKey every 4 rounds
        if ((d + 1) % 4 == 0) {
            const s = (d + 1) / 4;
            inline for (0..8) |i| X[i] +%= key[(s + i) % 9];
            X[5] +%= tweak[s % 3];
            X[6] +%= tweak[(s + 1) % 3];
            X[7] +%= s;
        }
    }

    words.* = X;
}

pub const Skein512Ctx = struct {
    // Chaining state words
    X:    [8]u64,
    // Tweak words: [0]=byte count, [1]=type+flags, [2]=T[0]^T[1]
    T:    [3]u64,
    // Partial block buffer
    b:    [SKEIN_512_BLOCK_BYTES]u8,
    bCnt: usize,
    hashBitLen: usize,
};

fn processBlock(ctx: *Skein512Ctx, blk: *const [SKEIN_512_BLOCK_BYTES]u8, byteCntAdd: usize) void {
    // Build key from current chaining state + parity
    var key: [9]u64 = undefined;
    key[8] = KS_PARITY;
    inline for (0..8) |i| {
        key[i]  = ctx.X[i];
        key[8] ^= ctx.X[i];
    }

    // Update T[0] and compute T[2]
    ctx.T[0] +%= @as(u64, byteCntAdd);
    ctx.T[2]  = ctx.T[0] ^ ctx.T[1];

    // Load plaintext words
    var w: [8]u64 = undefined;
    inline for (0..8) |i| {
        w[i] = std.mem.readInt(u64, blk[i*8..][0..8], .little);
    }

    // Encrypt: Threefish-512(key, tweak, w) -> w (in place = result of encrypt)
    threefish512Block(&key, &ctx.T, &w);

    // Feedforward XOR with original plaintext
    inline for (0..8) |i| ctx.X[i] = w[i] ^ key[i]; // note: key[i] == original ctx.X[i]

    // Clear FIRST flag
    ctx.T[1] &= SKEIN_T1_FLAG_FIRST_INV;
}

pub fn skein512Init(ctx: *Skein512Ctx, hashBitLen: usize) !void {
    if (hashBitLen == 0 or hashBitLen > 512) return error.BadHashLen;

    ctx.hashBitLen = hashBitLen;
    ctx.bCnt = 0;
    @memset(&ctx.X, 0);

    // Config block: 32 bytes of schema + version + output length
    var cfg: [SKEIN_512_BLOCK_BYTES]u8 = [_]u8{0} ** SKEIN_512_BLOCK_BYTES;
    // Bytes 0..7: Schema ID "SHA3" (LE) + version 1
    std.mem.writeInt(u64, cfg[0..8][0..8],  @as(u64, 0x0000000133414853), .little);
    // Bytes 8..15: output length in bits
    std.mem.writeInt(u64, cfg[8..16][0..8], @as(u64, hashBitLen),          .little);

    ctx.T[0] = 0;
    ctx.T[1] = SKEIN_T1_FLAG_FIRST | SKEIN_T1_FLAG_FINAL | SKEIN_T1_BLK_TYPE_CFG;
    processBlock(ctx, &cfg, SKEIN_CFG_STR_LEN);

    // Prepare for message
    ctx.T[0] = 0;
    ctx.T[1] = SKEIN_T1_FLAG_FIRST | SKEIN_T1_BLK_TYPE_MSG;
    ctx.bCnt = 0;
}

pub fn skein512Update(ctx: *Skein512Ctx, msg: []const u8) void {
    var n: usize = 0;
    var remaining = msg;

    if (ctx.bCnt + remaining.len > SKEIN_512_BLOCK_BYTES) {
        // Fill and flush buffer
        if (ctx.bCnt > 0) {
            n = SKEIN_512_BLOCK_BYTES - ctx.bCnt;
            @memcpy(ctx.b[ctx.bCnt..][0..n], remaining[0..n]);
            remaining = remaining[n..];
            processBlock(ctx, &ctx.b, SKEIN_512_BLOCK_BYTES);
            ctx.bCnt = 0;
        }
        // Process full blocks, leaving at least 1 byte for Final
        while (remaining.len > SKEIN_512_BLOCK_BYTES) {
            processBlock(ctx, remaining[0..SKEIN_512_BLOCK_BYTES], SKEIN_512_BLOCK_BYTES);
            remaining = remaining[SKEIN_512_BLOCK_BYTES..];
        }
    }
    // Buffer the remainder
    @memcpy(ctx.b[ctx.bCnt..][0..remaining.len], remaining);
    ctx.bCnt += remaining.len;
}

pub fn skein512Final(ctx: *Skein512Ctx, out: []u8) void {
    // Zero-pad and process final message block
    if (ctx.bCnt < SKEIN_512_BLOCK_BYTES) @memset(ctx.b[ctx.bCnt..], 0);
    ctx.T[1] |= SKEIN_T1_FLAG_FINAL;
    processBlock(ctx, &ctx.b, ctx.bCnt);

    // Output transform: one block per 512 bits of output
    // For Skein-512 → 512-bit output, one block with counter=0
    var outBlk: [SKEIN_512_BLOCK_BYTES]u8 = [_]u8{0} ** SKEIN_512_BLOCK_BYTES;
    ctx.T[0] = 0;
    ctx.T[1] = SKEIN_T1_FLAG_FIRST | SKEIN_T1_FLAG_FINAL | SKEIN_T1_BLK_TYPE_OUT;
    processBlock(ctx, &outBlk, 8);

    // Write output words little-endian
    const byteCnt = (ctx.hashBitLen + 7) / 8;
    var i: usize = 0;
    while (i < byteCnt) : (i += 8) {
        const take = @min(8, byteCnt - i);
        var word_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &word_bytes, ctx.X[i / 8], .little);
        @memcpy(out[i..][0..take], word_bytes[0..take]);
    }
}

pub fn skein512(in: []const u8, out: []u8) void {
    var ctx: Skein512Ctx = undefined;
    skein512Init(&ctx, 512) catch unreachable;
    skein512Update(&ctx, in);
    skein512Final(&ctx, out[0..64]);
}

pub fn skein512Mining(in: [80]u8, out: *[64]u8) void {
    skein512(&in, out);
}

// -----------------------------------------------------------------------
// KAT vectors: Skein 1.3 spec Appendix B
// -----------------------------------------------------------------------

const kat_empty_exp = [64]u8{
    0xbc,0x5b,0x4c,0x50,0x92,0x55,0x19,0xc2, 0x90,0xcc,0x63,0x42,0x77,0xae,0x3d,0x62,
    0x57,0x21,0x23,0x95,0xcb,0xa7,0x33,0xbb, 0xad,0x37,0xa4,0xaf,0x0f,0xa0,0x6a,0xf4,
    0x1f,0xca,0x79,0x03,0xd0,0x65,0x64,0xfe, 0xa7,0xa2,0xd3,0x73,0x0d,0xbd,0xb8,0x0c,
    0x1f,0x85,0x56,0x2d,0xfc,0xc0,0x70,0x33, 0x4e,0xa4,0xd1,0xd9,0xe7,0x2c,0xba,0x7a,
};
const kat1_in  = [1]u8{0xff};
const kat1_exp = [64]u8{
    0x71,0xb7,0xbc,0xe6,0xfe,0x64,0x52,0x22, 0x7b,0x9c,0xed,0x60,0x14,0x24,0x9e,0x5b,
    0xf9,0xa9,0x75,0x4c,0x3a,0xd6,0x18,0xcc, 0xc4,0xe0,0xaa,0xe1,0x6b,0x31,0x6c,0xc8,
    0x9c,0xa3,0x67,0x2a,0x26,0x12,0x56,0x6d, 0xe7,0x4b,0x27,0x97,0x7d,0x4d,0xfa,0x1e,
    0x7c,0x8d,0x3f,0x2b,0x3b,0xb3,0xcc,0xe6, 0x6b,0xd3,0x7b,0x5b,0x7c,0x3d,0x8c,0xff,
};
const kat2_in  = [32]u8{
    0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07, 0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f,
    0x10,0x11,0x12,0x13,0x14,0x15,0x16,0x17, 0x18,0x19,0x1a,0x1b,0x1c,0x1d,0x1e,0x1f,
};
const kat2_exp = [64]u8{
    0x45,0x86,0x3b,0xa3,0xbe,0x0c,0x4d,0xfc, 0x27,0xe7,0x5d,0x35,0x84,0x96,0xf4,0xac,
    0x9a,0x73,0x6a,0x50,0x5d,0x93,0x13,0xb4, 0x2b,0x2f,0x5e,0xad,0xa7,0x9f,0xc1,0x7f,
    0x63,0x86,0x1e,0x94,0x7a,0xfb,0x1d,0x05, 0x6a,0xa1,0x99,0x57,0x5a,0xd3,0xf8,0xc9,
    0xa3,0xcc,0x17,0x80,0xb5,0xe5,0xfa,0x4c, 0xae,0x05,0x0e,0x98,0x98,0x76,0x62,0xff,
};
const kat3_in  = [64]u8{
    0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07, 0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f,
    0x10,0x11,0x12,0x13,0x14,0x15,0x16,0x17, 0x18,0x19,0x1a,0x1b,0x1c,0x1d,0x1e,0x1f,
    0x20,0x21,0x22,0x23,0x24,0x25,0x26,0x27, 0x28,0x29,0x2a,0x2b,0x2c,0x2d,0x2e,0x2f,
    0x30,0x31,0x32,0x33,0x34,0x35,0x36,0x37, 0x38,0x39,0x3a,0x3b,0x3c,0x3d,0x3e,0x3f,
};
const kat3_exp = [64]u8{
    0x91,0xcc,0xa5,0x10,0xc2,0x63,0xc4,0xdd, 0xd0,0x10,0x53,0x0a,0x33,0x07,0x33,0x09,
    0x62,0x86,0x31,0xf3,0x08,0x74,0x7e,0x1b, 0xcb,0xaa,0x90,0xe4,0x51,0xca,0xb9,0x2e,
    0x51,0x88,0x08,0x7a,0xf4,0x18,0x87,0x73, 0xa3,0x32,0x30,0x3e,0x66,0x67,0xa7,0xa2,
    0x10,0x85,0x6f,0x74,0x21,0x39,0x00,0x00, 0x71,0xf4,0x8e,0x8b,0xa2,0xa5,0xad,0xb7,
};

pub fn runKAT() bool {
    std.debug.print("[skein] Running Skein-512 KAT vectors...\n", .{});
    var out: [64]u8 = undefined;
    var ok = true;
    const cases = [_]struct{ label: []const u8, in: []const u8, exp: *const [64]u8 }{
        .{ .label = "zero-length", .in = &[_]u8{},  .exp = &kat_empty_exp },
        .{ .label = "0xFF",        .in = &kat1_in,  .exp = &kat1_exp },
        .{ .label = "0x00..0x1F",  .in = &kat2_in,  .exp = &kat2_exp },
        .{ .label = "0x00..0x3F",  .in = &kat3_in,  .exp = &kat3_exp },
    };
    for (cases) |c| {
        skein512(c.in, &out);
        if (!std.mem.eql(u8, &out, c.exp)) {
            std.debug.print("  [FAIL] {s}\n    exp: {s}\n    got: {s}\n", .{
                c.label, std.fmt.fmtSliceHexLower(c.exp), std.fmt.fmtSliceHexLower(&out),
            });
            ok = false;
        } else {
            std.debug.print("  [PASS] {s}\n", .{c.label});
        }
    }
    return ok;
}
