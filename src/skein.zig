const std = @import("std");

pub const SKEIN_512_BLOCK_BYTES: usize = 64;
pub const SKEIN_512_STATE_WORDS: usize = 8;

const C240: u64 = 0x1BD11BDAA9FC1A22;

const R512: [8][4]u32 = .{
    .{46, 36, 19, 37}, .{33, 27, 14, 42},
    .{17, 49, 36, 39}, .{44,  9, 54, 56},
    .{39, 30, 34, 24}, .{13, 50, 10, 17},
    .{25, 29, 39, 43}, .{ 8, 35, 56, 22},
};

const PI8: [8]usize = .{2, 1, 4, 7, 6, 5, 0, 3};

const T_CFG: u64 = 4;
const T_MSG: u64 = 48;
const T_OUT: u64 = 63;

const T1_FIRST: u64 = @as(u64, 1) << 62;
const T1_FINAL: u64 = @as(u64, 1) << 63;
const T1_FIRST_MASK: u64 = ~T1_FIRST; // complement computed at comptime as u64

fn rotl64(v: u64, n: u32) u64 {
    return (v << @as(u6, @truncate(n))) | (v >> @as(u6, @truncate(64 - n)));
}

fn threefish512(key: [9]u64, tw: [3]u64, pt: [8]u64, ct: *[8]u64) void {
    var v: [8]u64 = pt;

    v[0] +%= key[0]; v[1] +%= key[1]; v[2] +%= key[2]; v[3] +%= key[3];
    v[4] +%= key[4];
    v[5] +%= key[5] +% tw[0];
    v[6] +%= key[6] +% tw[1];
    v[7] +%= key[7];

    for (0..72) |d| {
        const rc = R512[d % 8];
        v[0] +%= v[1]; v[1] = rotl64(v[1], rc[0]) ^ v[0];
        v[2] +%= v[3]; v[3] = rotl64(v[3], rc[1]) ^ v[2];
        v[4] +%= v[5]; v[5] = rotl64(v[5], rc[2]) ^ v[4];
        v[6] +%= v[7]; v[7] = rotl64(v[7], rc[3]) ^ v[6];

        var t: [8]u64 = undefined;
        for (0..8) |i| t[i] = v[PI8[i]];
        v = t;

        if (d % 4 == 3) {
            const s = (d + 1) / 4;
            v[0] +%= key[s % 9];
            v[1] +%= key[(s+1) % 9];
            v[2] +%= key[(s+2) % 9];
            v[3] +%= key[(s+3) % 9];
            v[4] +%= key[(s+4) % 9];
            v[5] +%= key[(s+5) % 9] +% tw[s % 3];
            v[6] +%= key[(s+6) % 9] +% tw[(s+1) % 3];
            v[7] +%= key[(s+7) % 9] +% s;
        }
    }
    ct.* = v;
}

fn load64le(p: *const [8]u8) u64 {
    return std.mem.readInt(u64, p, .little);
}

pub const Skein512Ctxt = struct {
    X:          [8]u64,
    T:          [3]u64,
    b:          [SKEIN_512_BLOCK_BYTES]u8,
    bCnt:       usize,
    hashBitLen: usize,
    byteCount:  u64,
};

fn ubiBlock(ctx: *Skein512Ctxt, blk: *const [SKEIN_512_BLOCK_BYTES]u8, bytesDone: u64) void {
    ctx.T[0] = bytesDone;
    ctx.T[2] = ctx.T[0] ^ ctx.T[1];

    var pt: [8]u64 = undefined;
    for (0..8) |i| pt[i] = load64le(blk[i*8..][0..8]);

    var key: [9]u64 = undefined;
    key[8] = C240;
    for (0..8) |i| { key[i] = ctx.X[i]; key[8] ^= ctx.X[i]; }

    var ct: [8]u64 = undefined;
    threefish512(key, ctx.T, pt, &ct);
    for (0..8) |i| ctx.X[i] = ct[i] ^ pt[i];

    ctx.T[1] &= T1_FIRST_MASK;
}

pub fn skein512Init(ctx: *Skein512Ctxt, hashBitLen: usize) !void {
    if (hashBitLen == 0 or hashBitLen > 512) return error.BadHashLen;
    ctx.hashBitLen = hashBitLen;
    ctx.bCnt       = 0;
    ctx.byteCount  = 0;
    @memset(&ctx.X, 0);
    @memset(&ctx.b, 0);

    var cfg: [SKEIN_512_BLOCK_BYTES]u8 = [_]u8{0} ** SKEIN_512_BLOCK_BYTES;
    cfg[0] = 0x53; cfg[1] = 0x48; cfg[2] = 0x41; cfg[3] = 0x33;
    cfg[4] = 0x01; cfg[5] = 0x00;
    std.mem.writeInt(u64, cfg[8..16][0..8], @as(u64, hashBitLen), .little);

    ctx.T[1] = (T_CFG << 56) | T1_FIRST | T1_FINAL;
    ubiBlock(ctx, &cfg, 32);

    ctx.T[1]      = (T_MSG << 56) | T1_FIRST;
    ctx.byteCount = 0;
}

pub fn skein512Update(ctx: *Skein512Ctxt, msg: []const u8) void {
    if (msg.len == 0) return;
    var remaining = msg;

    if (ctx.bCnt > 0) {
        const n = @min(SKEIN_512_BLOCK_BYTES - ctx.bCnt, remaining.len);
        @memcpy(ctx.b[ctx.bCnt..][0..n], remaining[0..n]);
        ctx.bCnt  += n;
        remaining  = remaining[n..];
        if (remaining.len == 0) return;
        ctx.byteCount += SKEIN_512_BLOCK_BYTES;
        ubiBlock(ctx, &ctx.b, ctx.byteCount);
        ctx.bCnt = 0;
    }

    while (remaining.len > SKEIN_512_BLOCK_BYTES) {
        ctx.byteCount += SKEIN_512_BLOCK_BYTES;
        ubiBlock(ctx, remaining[0..SKEIN_512_BLOCK_BYTES], ctx.byteCount);
        remaining = remaining[SKEIN_512_BLOCK_BYTES..];
    }

    @memcpy(ctx.b[0..remaining.len], remaining);
    ctx.bCnt = remaining.len;
}

pub fn skein512Final(ctx: *Skein512Ctxt, hashVal: []u8) void {
    if (ctx.bCnt < SKEIN_512_BLOCK_BYTES) @memset(ctx.b[ctx.bCnt..], 0);
    ctx.T[1] |= T1_FINAL;
    ctx.byteCount += ctx.bCnt;
    ubiBlock(ctx, &ctx.b, ctx.byteCount);

    // Output transform: counter block = 64 zero bytes, T0 = 8 (8-byte counter)
    const outBlk = [_]u8{0} ** SKEIN_512_BLOCK_BYTES;
    ctx.T[1] = (T_OUT << 56) | T1_FIRST | T1_FINAL;
    ubiBlock(ctx, &outBlk, 8);

    const byteCnt = (ctx.hashBitLen + 7) / 8;
    for (0..byteCnt) |i| {
        hashVal[i] = @as(u8, @truncate(ctx.X[i / 8] >> @as(u6, @truncate((i % 8) * 8))));
    }
}

pub fn skein512(in: []const u8, out: []u8) void {
    var ctx: Skein512Ctxt = undefined;
    skein512Init(&ctx, 512) catch unreachable;
    skein512Update(&ctx, in);
    skein512Final(&ctx, out[0..64]);
}

pub fn skein512Mining(in: [80]u8, out: *[64]u8) void {
    skein512(&in, out);
}

// KAT vectors: Skein 1.3 spec Appendix B

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
                c.label,
                std.fmt.fmtSliceHexLower(c.exp),
                std.fmt.fmtSliceHexLower(&out),
            });
            ok = false;
        } else {
            std.debug.print("  [PASS] {s}\n", .{c.label});
        }
    }
    return ok;
}
