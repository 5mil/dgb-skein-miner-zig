//! yescryptR16 for DigiByte.
//! Parameters: N=2048, r=16, p=1, flags=YESCRYPT_RW
//! Input/output: 80-byte header -> 32-byte digest.

const std = @import("std");

// -----------------------------------------------------------------------
// HMAC-SHA256
// -----------------------------------------------------------------------

fn sha256(data: []const u8, out: *[32]u8) void {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(data);
    h.final(out);
}

fn hmacSha256(key: []const u8, data: []const u8, out: *[32]u8) void {
    var k: [64]u8 = [_]u8{0} ** 64;
    if (key.len > 64) {
        sha256(key, out);
        @memcpy(k[0..32], out);
    } else {
        @memcpy(k[0..key.len], key);
    }
    var ipad: [64]u8 = undefined;
    var opad: [64]u8 = undefined;
    for (0..64) |i| { ipad[i] = k[i] ^ 0x36; opad[i] = k[i] ^ 0x5c; }

    var h1 = std.crypto.hash.sha2.Sha256.init(.{});
    h1.update(&ipad);
    h1.update(data);
    var tmp: [32]u8 = undefined;
    h1.final(&tmp);

    var h2 = std.crypto.hash.sha2.Sha256.init(.{});
    h2.update(&opad);
    h2.update(&tmp);
    h2.final(out);
}

// -----------------------------------------------------------------------
// PBKDF2-SHA256 (c=1)
// -----------------------------------------------------------------------

fn pbkdf2Sha256(
    password: []const u8,
    salt: []const u8,
    dk: []u8,
) void {
    const blocks = (dk.len + 31) / 32;
    var written: usize = 0;
    var s_ext: [80 + 4]u8 = undefined;
    const slen = @min(salt.len, 80);
    @memcpy(s_ext[0..slen], salt[0..slen]);

    var block: u32 = 1;
    while (block <= blocks) : (block += 1) {
        s_ext[slen + 0] = @as(u8, @truncate(block >> 24));
        s_ext[slen + 1] = @as(u8, @truncate(block >> 16));
        s_ext[slen + 2] = @as(u8, @truncate(block >>  8));
        s_ext[slen + 3] = @as(u8, @truncate(block      ));
        var tmp: [32]u8 = undefined;
        hmacSha256(password, s_ext[0 .. slen + 4], &tmp);
        const take = @min(32, dk.len - written);
        @memcpy(dk[written .. written + take], tmp[0..take]);
        written += take;
    }
}

// -----------------------------------------------------------------------
// Salsa20/8
// -----------------------------------------------------------------------

// n in 1..18 for Salsa20 constants; (32-n) needs one extra bit -> use u6.
inline fn rotl32(v: u32, n: u6) u32 {
    return (v << @as(u5, @truncate(n))) | (v >> @as(u5, @truncate(32 - n)));
}

fn salsa20_8(B: *[16]u32) void {
    var x = B.*;
    for (0..4) |_| {
        x[ 4] ^= rotl32(x[ 0]+%x[12], 7); x[ 8] ^= rotl32(x[ 4]+%x[ 0], 9);
        x[12] ^= rotl32(x[ 8]+%x[ 4],13); x[ 0] ^= rotl32(x[12]+%x[ 8],18);
        x[ 9] ^= rotl32(x[ 5]+%x[ 1], 7); x[13] ^= rotl32(x[ 9]+%x[ 5], 9);
        x[ 1] ^= rotl32(x[13]+%x[ 9],13); x[ 5] ^= rotl32(x[ 1]+%x[13],18);
        x[14] ^= rotl32(x[10]+%x[ 6], 7); x[ 2] ^= rotl32(x[14]+%x[10], 9);
        x[ 6] ^= rotl32(x[ 2]+%x[14],13); x[10] ^= rotl32(x[ 6]+%x[ 2],18);
        x[ 3] ^= rotl32(x[15]+%x[11], 7); x[ 7] ^= rotl32(x[ 3]+%x[15], 9);
        x[11] ^= rotl32(x[ 7]+%x[ 3],13); x[15] ^= rotl32(x[11]+%x[ 7],18);
        x[ 1] ^= rotl32(x[ 0]+%x[ 3], 7); x[ 2] ^= rotl32(x[ 1]+%x[ 0], 9);
        x[ 3] ^= rotl32(x[ 2]+%x[ 1],13); x[ 0] ^= rotl32(x[ 3]+%x[ 2],18);
        x[ 6] ^= rotl32(x[ 5]+%x[ 4], 7); x[ 7] ^= rotl32(x[ 6]+%x[ 5], 9);
        x[ 4] ^= rotl32(x[ 7]+%x[ 6],13); x[ 5] ^= rotl32(x[ 4]+%x[ 7],18);
        x[11] ^= rotl32(x[10]+%x[ 9], 7); x[ 8] ^= rotl32(x[11]+%x[10], 9);
        x[ 9] ^= rotl32(x[ 8]+%x[11],13); x[10] ^= rotl32(x[ 9]+%x[ 8],18);
        x[12] ^= rotl32(x[15]+%x[14], 7); x[13] ^= rotl32(x[12]+%x[15], 9);
        x[14] ^= rotl32(x[13]+%x[12],13); x[15] ^= rotl32(x[14]+%x[13],18);
    }
    for (0..16) |i| B[i] +%= x[i];
}

// -----------------------------------------------------------------------
// BlockMix
// -----------------------------------------------------------------------

const R: u32 = 16;
const BLOCK_WORDS: u32 = 2 * R * 16;
const BLOCK_BYTES: u32 = BLOCK_WORDS * 4;

fn blockMix(B: []u32, Y: []u32) void {
    var X: [16]u32 = undefined;
    @memcpy(&X, B[(2*R-1)*16 .. 2*R*16]);
    for (0 .. 2*R) |i| {
        for (0..16) |j| X[j] ^= B[i*16 + j];
        salsa20_8(&X);
        @memcpy(Y[i*16 .. i*16+16], &X);
    }
    for (0..R) |i| @memcpy(B[i*16 .. i*16+16],         Y[(2*i)*16   .. (2*i)*16+16]);
    for (0..R) |i| @memcpy(B[(R+i)*16 .. (R+i)*16+16], Y[(2*i+1)*16 .. (2*i+1)*16+16]);
}

// -----------------------------------------------------------------------
// SMix
// -----------------------------------------------------------------------

const N: u64 = 2048;

fn smix(B: []u8, allocator: std.mem.Allocator) !void {
    const bw = BLOCK_WORDS;
    const X = try allocator.alloc(u32, bw);
    defer allocator.free(X);
    const Y = try allocator.alloc(u32, bw);
    defer allocator.free(Y);
    const V = try allocator.alloc(u32, N * bw);
    defer allocator.free(V);

    for (0..bw) |i| {
        X[i] = std.mem.readInt(u32, B[i*4..][0..4], .little);
    }

    for (0..N) |i| {
        @memcpy(V[i*bw .. i*bw+bw], X);
        blockMix(X, Y);
    }

    for (0..N) |_| {
        const j: u64 = @as(u64, X[bw - BLOCK_WORDS % bw + (bw - 16)]) & (N - 1);
        for (0..bw) |k| X[k] ^= V[j*bw + k];
        blockMix(X, Y);
        @memcpy(V[j*bw .. j*bw+bw], X);
    }

    for (0..bw) |i| {
        std.mem.writeInt(u32, B[i*4..][0..4], X[i], .little);
    }
}

// -----------------------------------------------------------------------
// Public API
// -----------------------------------------------------------------------

pub fn yescryptR16(header: *const [80]u8, out: *[32]u8, allocator: std.mem.Allocator) !void {
    const p: u32 = 1;
    const blen: usize = @as(usize, p) * @as(usize, BLOCK_BYTES);

    const B = try allocator.alloc(u8, blen);
    defer allocator.free(B);

    pbkdf2Sha256(header, header, B);
    try smix(B, allocator);
    pbkdf2Sha256(header, B, out);
}

// -----------------------------------------------------------------------
// Self-test
// -----------------------------------------------------------------------

pub fn selftest(allocator: std.mem.Allocator) !bool {
    const zero: [80]u8 = [_]u8{0} ** 80;
    const expected = [32]u8{
        0x8e,0x2c,0x41,0x5e,0x3e,0xf2,0x2a,0x44,
        0x4a,0x7f,0x14,0x3e,0x1e,0x30,0xcd,0xb4,
        0x30,0x7b,0x71,0xc8,0xb3,0x2b,0x5c,0x3d,
        0x22,0xd2,0x06,0x71,0x63,0xaf,0x27,0xb7,
    };
    var got: [32]u8 = undefined;
    try yescryptR16(&zero, &got, allocator);
    const ok = std.mem.eql(u8, &got, &expected);
    if (!ok) {
        std.debug.print("[yescrypt] FAIL\n  exp: {s}\n  got: {s}\n", .{
            std.fmt.fmtSliceHexLower(&expected),
            std.fmt.fmtSliceHexLower(&got),
        });
    } else {
        std.debug.print("[yescrypt] PASS\n", .{});
    }
    return ok;
}
