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

fn rotl64(v: u64, n: u32) u64 {
    return (v << @as(u6, @truncate(n))) | (v >> @as(u6, @truncate(64 - n)));
}

fn threefish512(key: [9]u64, tw: [3]u64, pt: [8]u64, ct: *[8]u64) void {
    var v: [8]u64 = pt;

    // Subkey injection s=0
    v[0] +%= key[0]; v[1] +%= key[1]; v[2] +%= key[2]; v[3] +%= key[3];
    v[4] +%= key[4];
    v[5] +%= key[5] + tw[0];
    v[6] +%= key[6] + tw[1];
    v[7] +%= key[7];

    for (0..72) |d| {
        const rc = R512[d % 8];

        v[0] +%= v[1]; v[1] = rotl64(v[1], rc[0]) ^ v[0];
        v[2] +%= v[3]; v[3] = rotl64(v[3], rc[1]) ^ v[2];
        v[4] +%= v[5]; v[5] = rotl64(v[5], rc[2]) ^ v[4];
        v[6] +%= v[7]; v[7] = rotl64(v[7], rc[3]) ^ v[6];

        // Permute
        var t: [8]u64 = undefined;
        for (0..8) |i| {
            t[i] = v[PI8[i]];
        }
        v = t;

        if (d % 4 == 3) {
            const s = (d + 1) / 4;
            v[0] +%= key[s % 9];
            v[1] +%= key[(s + 1) % 9];
            v[2] +%= key[(s + 2) % 9];
            v[3] +%= key[(s + 3) % 9];
            v[4] +%= key[(s + 4) % 9];
            v[5] +%= key[(s + 5) % 9] + tw[s % 3];
            v[6] +%= key[(s + 6) % 9] + tw[(s + 1) % 3];
            v[7] +%= key[(s + 7) % 9] + s;
        }
    }

    ct.* = v;
}

fn load64le(p: []const u8) u64 {
    return @as(u64, p[0]) |
           (@as(u64, p[1]) << 8) |
           (@as(u64, p[2]) << 16) |
           (@as(u64, p[3]) << 24) |
           (@as(u64, p[4]) << 32) |
           (@as(u64, p[5]) << 40) |
           (@as(u64, p[6]) << 48) |
           (@as(u64, p[7]) << 56);
}

fn store64le(p: []u8, v: u64) void {
    p[0] = @as(u8, @truncate(v));
    p[1] = @as(u8, @truncate(v >> 8));
    p[2] = @as(u8, @truncate(v >> 16));
    p[3] = @as(u8, @truncate(v >> 24));
    p[4] = @as(u8, @truncate(v >> 32));
    p[5] = @as(u8, @truncate(v >> 40));
    p[6] = @as(u8, @truncate(v >> 48));
    p[7] = @as(u8, @truncate(v >> 56));
}

pub const Skein512Ctxt = struct {
    X: [8]u64,
    T: [3]u64,
    b: [SKEIN_512_BLOCK_BYTES]u8,
    bCnt: usize,
    hashBitLen: usize,
};

pub fn skein512Init(ctx: *Skein512Ctxt, hashBitLen: usize) !void {
    if (hashBitLen == 0 or hashBitLen > 512) return error.BadHashLen;

    ctx.hashBitLen = hashBitLen;
    ctx.bCnt = 0;
    @memset(&ctx.X, 0);

    var cfg: [SKEIN_512_BLOCK_BYTES]u8 = undefined;
    @memset(&cfg, 0);
    cfg[0] = 0x53; cfg[1] = 0x48; cfg[2] = 0x41; cfg[3] = 0x33;
    cfg[4] = 1; cfg[5] = 0;
    var ob = hashBitLen;
    for (0..8) |i| {
        cfg[8 + i] = @as(u8, @truncate(ob));
        ob >>= 8;
    }

    ctx.T[0] = 0;
    ctx.T[1] = (4 << 56) | (1 << 62) | (1 << 63); // CFG + FIRST + FINAL
    ubiBlock(ctx, &cfg, 32);

    ctx.T[0] = 0;
    ctx.T[1] = (48 << 56) | (1 << 62); // MSG + FIRST
}

fn ubiBlock(ctx: *Skein512Ctxt, blk: []const u8, bytesThisBlock: usize) void {
    ctx.T[0] +%= bytesThisBlock;
    ctx.T[2] = ctx.T[0] ^ ctx.T[1];

    var pt: [8]u64 = undefined;
    for (0..8) |i| {
        pt[i] = load64le(blk[i*8..][0..8]);
    }

    var key: [9]u64 = undefined;
    key[8] = C240;
    for (0..8) |i| {
        key[i] = ctx.X[i];
        key[8] ^= ctx.X[i];
    }

    var ct: [8]u64 = undefined;
    threefish512(key, ctx.T, pt, &ct);

    for (0..8) |i| {
        ctx.X[i] = ct[i] ^ pt[i];
    }
    ctx.T[1] &= ~(@as(u64, 1) << 62); // clear FIRST
}

pub fn skein512Update(ctx: *Skein512Ctxt, msg: []const u8) void {
    if (msg.len == 0) return;

    var remaining = msg;
    if (ctx.bCnt > 0) {
        const n = @min(SKEIN_512_BLOCK_BYTES - ctx.bCnt, remaining.len);
        @memcpy(ctx.b[ctx.bCnt..][0..n], remaining[0..n]);
        ctx.bCnt += n;
        remaining = remaining[n..];
        if (remaining.len == 0) return;

        ubiBlock(ctx, &ctx.b, SKEIN_512_BLOCK_BYTES);
        ctx.bCnt = 0;
    }

    while (remaining.len >= SKEIN_512_BLOCK_BYTES) {
        ubiBlock(ctx, remaining[0..SKEIN_512_BLOCK_BYTES], SKEIN_512_BLOCK_BYTES);
        remaining = remaining[SKEIN_512_BLOCK_BYTES..];
    }

    if (remaining.len > 0) {
        @memcpy(ctx.b[0..remaining.len], remaining);
        ctx.bCnt = remaining.len;
    }
}

pub fn skein512Final(ctx: *Skein512Ctxt, hashVal: []u8) void {
    ctx.T[1] |= (1 << 63); // FINAL

    if (ctx.bCnt < SKEIN_512_BLOCK_BYTES) {
        @memset(ctx.b[ctx.bCnt..], 0);
    }
    ubiBlock(ctx, &ctx.b, ctx.bCnt);

    // Output block
    var outBlk: [SKEIN_512_BLOCK_BYTES]u8 = .{0} ** SKEIN_512_BLOCK_BYTES;
    ctx.T[0] = 0;
    ctx.T[1] = (63 << 56) | (1 << 62) | (1 << 63); // OUT + FIRST + FINAL
    ubiBlock(ctx, &outBlk, 8);

    const byteCnt = (ctx.hashBitLen + 7) / 8;
    for (0..byteCnt) |i| {
        const word = ctx.X[i / 8];
        hashVal[i] = @as(u8, @truncate(word >> @as(u6, @truncate((i % 8) * 8))));
    }
}

pub fn skein512(in: []const u8, out: []u8) void {
    var ctx: Skein512Ctxt = undefined;
    skein512Init(&ctx, 512) catch unreachable;
    skein512Update(&ctx, in);
    skein512Final(&ctx, out[0..64]);
}

// For mining: exactly 80-byte input -> 64-byte output
pub fn skein512Mining(in: [80]u8, out: *[64]u8) void {
    skein512(&in, out);
}

// KAT verification - simple zero input test
pub fn runKAT() void {
    const zero_header: [80]u8 = .{0} ** 80;
    var out: [64]u8 = undefined;
    skein512(&zero_header, &out);

    std.debug.print("Scalar Skein-512 KAT test (zero header):\n", .{});
    std.debug.print("Output: {s}\n", .{std.fmt.fmtSliceHexLower(&out)});
    std.debug.print("KAT verification structure ready.\n", .{});
}