const std = @import("std");

const Vec4 = @Vector(4, u64);

const RC: [8][4]u32 = .{
    .{46,36,19,37}, .{33,27,14,42},
    .{17,49,36,39}, .{44,9,54,56},
    .{39,30,34,24}, .{13,50,10,17},
    .{25,29,39,43}, .{8,35,56,22},
};

const PERM: [8]u32 = .{2,1,4,7,6,5,0,3};

const C240: u64 = 0x1BD11BDAA9FC1A22;

const SKEIN_BLK_TYPE_MSG: u64 = 48;
const SKEIN_BLK_TYPE_OUT: u64 = 63;
const SKEIN_T1_POS_FIRST: u64 = 1 << 62;
const SKEIN_T1_POS_FINAL: u64 = 1 << 63;

fn rot64(v: Vec4, n: u32) Vec4 {
    const shift: @Vector(4, u6) = @splat(@as(u6, @truncate(n)));
    return (v << shift) | (v >> @as(@Vector(4, u6), @splat(@as(u6, @truncate(64 - n)))));
}

fn ubiProcessBlockAvx2(state: *[8]Vec4, block: [8]Vec4, tweak: [3]u64) void {
    var st: [4][8]u64 = undefined;
    for (0..8) |i| {
        const tmp = @as([4]u64, state[i]);
        for (0..4) |lane| st[lane][i] = tmp[lane];
    }

    var results: [4][8]u64 = undefined;

    for (0..4) |lane| {
        var key: [9]u64 = undefined;
        for (0..8) |i| key[i] = st[lane][i];
        key[8] = C240;
        for (0..8) |i| key[8] ^= key[i];

        var pt: [8]u64 = undefined;
        for (0..8) |i| {
            const tmp = @as([4]u64, block[i]);
            pt[i] = tmp[lane];
        }

        var ks: [19][8]u64 = undefined;
        for (0..19) |s| {
            for (0..8) |i| ks[s][i] = key[(s + i) % 9];
            ks[s][5] ^= tweak[s % 3];
            ks[s][6] ^= tweak[(s + 1) % 3];
            ks[s][7] ^= s;
        }

        var v: [8]u64 = undefined;
        for (0..8) |i| v[i] = pt[i] +% ks[0][i];

        for (0..72) |r| {
            const rm = r % 8;
            const rc = RC[rm];

            v[0] +%= v[1]; v[1] = ((v[1] << rc[0]) | (v[1] >> (64 - rc[0]))) ^ v[0];
            v[2] +%= v[3]; v[3] = ((v[3] << rc[1]) | (v[3] >> (64 - rc[1]))) ^ v[2];
            v[4] +%= v[5]; v[5] = ((v[5] << rc[2]) | (v[5] >> (64 - rc[2]))) ^ v[4];
            v[6] +%= v[7]; v[7] = ((v[7] << rc[3]) | (v[7] >> (64 - rc[3]))) ^ v[6];

            var t: [8]u64 = undefined;
            for (0..8) |i| t[PERM[i]] = v[i];
            v = t;

            if (r % 4 == 3) {
                const s = (r + 1) / 4;
                for (0..8) |i| v[i] +%= ks[s][i];
            }
        }

        for (0..8) |i| results[lane][i] = v[i] ^ pt[i];
    }

    for (0..8) |i| {
        state[i] = Vec4{ results[0][i], results[1][i], results[2][i], results[3][i] };
    }
}

pub fn skein512Avx2_4way(
    in0: []const u8, in1: []const u8,
    in2: []const u8, in3: []const u8,
    out0: []u8, out1: []u8,
    out2: []u8, out3: []u8,
) void {
    const IV512 = [8]u64{
        0x4903ADFF749C51CE, 0x0D95DE399746DF03,
        0x8FD1934127C79BCE, 0x9A255629FF352CB1,
        0x5DB62599DF6CA7B0, 0xEABE394CA9D5C3F4,
        0x991112C71A75B523, 0xAE18A40B660FCC33,
    };

    const ins  = [_][]const u8{ in0, in1, in2, in3 };
    const outs = [_][]u8{ out0, out1, out2, out3 };

    var state: [8]Vec4 = undefined;
    for (0..8) |i| state[i] = @as(Vec4, @splat(IV512[i]));

    // Block 1: bytes 0..63
    var blk: [8]Vec4 = undefined;
    for (0..8) |i| {
        var w: [4]u64 = undefined;
        for (0..4) |lane| w[lane] = std.mem.readInt(u64, ins[lane][i*8..][0..8], .little);
        blk[i] = Vec4{ w[0], w[1], w[2], w[3] };
    }
    var tw1 = [3]u64{ 64, (SKEIN_BLK_TYPE_MSG << 56) | SKEIN_T1_POS_FIRST, 0 };
    tw1[2] = tw1[0] ^ tw1[1];
    ubiProcessBlockAvx2(&state, blk, tw1);

    // Block 2: bytes 64..79 (padded)
    var blk2: [8]Vec4 = undefined;
    for (0..8) |i| {
        var w: [4]u64 = undefined;
        for (0..4) |lane| {
            w[lane] = if (i < 2) std.mem.readInt(u64, ins[lane][64 + i*8..][0..8], .little) else 0;
        }
        blk2[i] = Vec4{ w[0], w[1], w[2], w[3] };
    }
    var tw2 = [3]u64{ 80, (SKEIN_BLK_TYPE_MSG << 56) | SKEIN_T1_POS_FINAL, 0 };
    tw2[2] = tw2[0] ^ tw2[1];
    ubiProcessBlockAvx2(&state, blk2, tw2);

    // Output transform
    const oblk: [8]Vec4 = [_]Vec4{@as(Vec4, @splat(@as(u64, 0)))} ** 8;
    var tw3 = [3]u64{ 8, (SKEIN_BLK_TYPE_OUT << 56) | SKEIN_T1_POS_FIRST | SKEIN_T1_POS_FINAL, 0 };
    tw3[2] = tw3[0] ^ tw3[1];
    ubiProcessBlockAvx2(&state, oblk, tw3);

    for (0..8) |i| {
        const tmp = @as([4]u64, state[i]);
        for (0..4) |lane| std.mem.writeInt(u64, outs[lane][i*8..][0..8], tmp[lane], .little);
    }
}

pub fn hasAvx2() bool {
    return std.Target.x86.featureSetHas(
        std.Target.Cpu.Arch.x86_64.featureSet(),
        .avx2
    );
}
