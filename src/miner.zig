//! Real mining loop for DGB-Skein and DGB-YescryptR16.
const std = @import("std");
const skein    = @import("skein.zig");
const yescrypt = @import("yescrypt.zig");
const stratum  = @import("stratum.zig");

pub const Algo = enum { skein, yescrypt };

fn buildHeader(
    out: *[80]u8,
    version: u32,
    prev_hash: *const [32]u8,
    merkle_root: *const [32]u8,
    ntime: u32,
    nbits: u32,
    nonce: u32,
) void {
    std.mem.writeInt(u32, out[0..4],   version,     .little);
    @memcpy(out[4..36],  prev_hash);
    @memcpy(out[36..68], merkle_root);
    std.mem.writeInt(u32, out[68..72], ntime,       .little);
    std.mem.writeInt(u32, out[72..76], nbits,       .little);
    std.mem.writeInt(u32, out[76..80], nonce,       .little);
}

fn meetsTarget(digest: *const [32]u8, target: *const [32]u8) bool {
    var i: usize = 32;
    while (i > 0) {
        i -= 1;
        if (digest[i] < target[i]) return true;
        if (digest[i] > target[i]) return false;
    }
    return true;
}

fn decodeTarget(nbits: u32, out: *[32]u8) void {
    @memset(out, 0);
    const exp: u8   = @as(u8, @truncate(nbits >> 24));
    const mant: u32 = nbits & 0x00ff_ffff;
    if (exp < 3 or exp > 32) return;
    const byte_pos: usize = @as(usize, exp) - 3;
    if (byte_pos + 2 < 32) out[byte_pos + 2] = @as(u8, @truncate(mant >> 16));
    if (byte_pos + 1 < 32) out[byte_pos + 1] = @as(u8, @truncate(mant >>  8));
    if (byte_pos     < 32) out[byte_pos    ] = @as(u8, @truncate(mant      ));
}

const WorkerCtx = struct {
    client:      *stratum.StratumClient,
    algo:        Algo,
    allocator:   std.mem.Allocator,
    nonce_start: u32,
    nonce_step:  u32,
    found:       std.atomic.Value(bool),
    found_nonce: std.atomic.Value(u32),
};

fn workerFn(ctx: *WorkerCtx) void {
    const job = ctx.client.current_job orelse return;

    var target: [32]u8 = undefined;
    decodeTarget(job.nbits, &target);

    var header: [80]u8 = undefined;
    var digest: [64]u8 = undefined;

    var nonce: u32 = ctx.nonce_start;
    while (!ctx.found.load(.acquire)) {
        buildHeader(&header, job.version, &job.prev_hash, &job.merkle_root,
                    job.ntime, job.nbits, nonce);

        switch (ctx.algo) {
            .skein => {
                skein.skein512(&header, &digest);
                if (meetsTarget(digest[0..32], &target)) {
                    ctx.found_nonce.store(nonce, .release);
                    ctx.found.store(true, .release);
                    return;
                }
            },
            .yescrypt => {
                var out32: [32]u8 = undefined;
                yescrypt.yescryptR16(&header, &out32, ctx.allocator) catch return;
                if (meetsTarget(&out32, &target)) {
                    ctx.found_nonce.store(nonce, .release);
                    ctx.found.store(true, .release);
                    return;
                }
            },
        }

        nonce +%= ctx.nonce_step;
        if (nonce == ctx.nonce_start) break;
    }
}

pub fn runMiner(
    allocator: std.mem.Allocator,
    client: *stratum.StratumClient,
    _wallet: []const u8,
    threads: usize,
    algo: Algo,
) !void {
    _ = _wallet;
    std.debug.print("[Miner] Starting | algo={s} threads={d}\n",
        .{ @tagName(algo), threads });

    var line_buf: [8192]u8 = undefined;

    while (true) {
        const line = client.readLine(&line_buf) catch |err| {
            std.debug.print("[Miner] Read error: {}\n", .{err});
            break;
        } orelse break;

        try client.handleLine(line, allocator);

        const job = client.current_job orelse continue;
        _ = job;

        var ctxs = try allocator.alloc(WorkerCtx, threads);
        defer allocator.free(ctxs);
        var thread_handles = try allocator.alloc(std.Thread, threads);
        defer allocator.free(thread_handles);

        for (0..threads) |t| {
            ctxs[t] = WorkerCtx{
                .client      = client,
                .algo        = algo,
                .allocator   = allocator,
                .nonce_start = @as(u32, @truncate(t)),
                .nonce_step  = @as(u32, @truncate(threads)),
                .found       = std.atomic.Value(bool).init(false),
                .found_nonce = std.atomic.Value(u32).init(0),
            };
            thread_handles[t] = try std.Thread.spawn(.{}, workerFn, .{&ctxs[t]});
        }

        for (thread_handles) |h| h.join();

        for (ctxs) |*c| {
            if (c.found.load(.acquire)) {
                const nonce = c.found_nonce.load(.acquire);
                const j = client.current_job.?;
                std.debug.print("[Miner] Share found! nonce=0x{x:0>8}\n", .{nonce});
                try client.submitShare(j.job_id, nonce, j.ntime);
                break;
            }
        }
    }
}
