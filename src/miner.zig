//! Mining loop -- Skein-512 (scalar + AVX2 4-way) and YescryptR16.
const std      = @import("std");
const builtin  = @import("builtin");
const skein    = @import("skein.zig");
const avx2     = @import("skein_avx2.zig");
const yescrypt = @import("yescrypt.zig");
const stratum  = @import("stratum.zig");
const cpu      = @import("cpu.zig");

pub const Algo = enum { skein, yescrypt };

pub var g_stop = std.atomic.Value(bool).init(false);

fn buildHeader(
    out: *[80]u8,
    version: u32, prev_hash: *const [32]u8, merkle_root: *const [32]u8,
    ntime: u32, nbits: u32, nonce: u32,
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
    while (i > 0) { i -= 1;
        if (digest[i] < target[i]) return true;
        if (digest[i] > target[i]) return false;
    }
    return true;
}

fn decodeTarget(nbits: u32, out: *[32]u8) void {
    @memset(out, 0);
    const exp: usize = @as(u8, @truncate(nbits >> 24));
    const mant: u32  = nbits & 0x00ff_ffff;
    if (exp < 3 or exp > 32) return;
    const bp = exp - 3;
    if (bp + 2 < 32) out[bp + 2] = @truncate(mant >> 16);
    if (bp + 1 < 32) out[bp + 1] = @truncate(mant >>  8);
    if (bp     < 32) out[bp    ] = @truncate(mant      );
}

const WorkerCtx = struct {
    client:      *stratum.StratumClient,
    algo:        Algo,
    allocator:   std.mem.Allocator,
    nonce_start: u32,
    nonce_step:  u32,
    en2:         u32,
    found:       std.atomic.Value(bool),
    found_nonce: std.atomic.Value(u32),
    use_avx2:    bool,
};

fn workerFn(ctx: *WorkerCtx) void {
    var job = ctx.client.lockJob() orelse return;
    defer job.free(ctx.allocator);

    var target: [32]u8 = undefined;
    decodeTarget(job.nbits, &target);

    var scratch: ?yescrypt.ScratchBuf = if (ctx.algo == .yescrypt)
        yescrypt.ScratchBuf.init(ctx.allocator) catch return
    else null;
    defer if (scratch) |*s| s.deinit();

    var nonce: u32 = ctx.nonce_start;

    if (ctx.use_avx2 and ctx.algo == .skein) {
        while (!ctx.found.load(.acquire) and !g_stop.load(.acquire)) {
            var h0: [80]u8 = undefined; var h1: [80]u8 = undefined;
            var h2: [80]u8 = undefined; var h3: [80]u8 = undefined;
            var o0: [64]u8 = undefined; var o1: [64]u8 = undefined;
            var o2: [64]u8 = undefined; var o3: [64]u8 = undefined;
            buildHeader(&h0, job.version, &job.prev_hash, &job.merkle_root, job.ntime, job.nbits, nonce);
            buildHeader(&h1, job.version, &job.prev_hash, &job.merkle_root, job.ntime, job.nbits, nonce +% ctx.nonce_step);
            buildHeader(&h2, job.version, &job.prev_hash, &job.merkle_root, job.ntime, job.nbits, nonce +% ctx.nonce_step *% 2);
            buildHeader(&h3, job.version, &job.prev_hash, &job.merkle_root, job.ntime, job.nbits, nonce +% ctx.nonce_step *% 3);
            avx2.skein512Avx2_4way(&h0, &h1, &h2, &h3, &o0, &o1, &o2, &o3);
            inline for (.{ .{ o0, nonce }, .{ o1, nonce +% ctx.nonce_step },
                            .{ o2, nonce +% ctx.nonce_step *% 2 },
                            .{ o3, nonce +% ctx.nonce_step *% 3 } }) |pair| {
                if (meetsTarget(pair[0][0..32], &target)) {
                    ctx.found_nonce.store(pair[1], .release);
                    ctx.found.store(true, .release);
                    return;
                }
            }
            nonce +%= ctx.nonce_step *% 4;
            if (nonce == ctx.nonce_start) break;
        }
    } else {
        while (!ctx.found.load(.acquire) and !g_stop.load(.acquire)) {
            var header: [80]u8 = undefined;
            buildHeader(&header, job.version, &job.prev_hash, &job.merkle_root,
                        job.ntime, job.nbits, nonce);
            switch (ctx.algo) {
                .skein => {
                    var digest: [64]u8 = undefined;
                    skein.skein512(&header, &digest);
                    if (meetsTarget(digest[0..32], &target)) {
                        ctx.found_nonce.store(nonce, .release);
                        ctx.found.store(true, .release);
                        return;
                    }
                },
                .yescrypt => {
                    var out32: [32]u8 = undefined;
                    yescrypt.yescryptR16Scratch(&header, &out32, &scratch.?);
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
}

fn handleSigint(_: std.os.linux.SIG) callconv(.c) void {
    g_stop.store(true, .release);
}

pub fn runMiner(
    allocator: std.mem.Allocator,
    host:      []const u8,
    port:      u16,
    wallet:    []const u8,
    threads:   usize,
    algo:      Algo,
) !void {
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const sa = std.posix.Sigaction{
            .handler = .{ .handler = handleSigint },
            .mask    = std.os.linux.empty_sigset,  // Zig 0.16: moved from std.posix
            .flags   = 0,
        };
        try std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    }

    const use_avx2 = (algo == .skein) and cpu.hasAvx2();
    if (use_avx2)
        std.debug.print("[Miner] AVX2 4-way Skein enabled\n", .{})
    else
        std.debug.print("[Miner] Scalar path | algo={s}\n", .{@tagName(algo)});

    var reconnect_delay: u64 = 2;
    while (!g_stop.load(.acquire)) {
        std.debug.print("[Miner] Connecting {s}:{d}...\n", .{ host, port });
        var client = stratum.StratumClient.connect(allocator, host, port) catch |err| {
            std.debug.print("[Miner] Connect failed: {} -- retry in {d}s\n", .{ err, reconnect_delay });
            std.time.sleep(reconnect_delay * std.time.ns_per_s);
            reconnect_delay = @min(reconnect_delay * 2, 60);
            continue;
        };
        defer client.deinit();
        reconnect_delay = 2;

        client.subscribe() catch |err| {
            std.debug.print("[Miner] Subscribe failed: {}\n", .{err});
            continue;
        };
        client.authorize(wallet, "x") catch |err| {
            std.debug.print("[Miner] Authorize failed: {}\n", .{err});
            continue;
        };

        std.debug.print("[Miner] Mining | threads={d}\n", .{threads});
        var line_buf: [8192]u8 = undefined;

        mineLoop: while (!g_stop.load(.acquire)) {
            const line = client.readLine(&line_buf) catch |err| {
                std.debug.print("[Miner] Read error: {}\n", .{err});
                break :mineLoop;
            } orelse break :mineLoop;

            client.handleLine(line) catch {};

            const job = client.lockJob() orelse continue;

            var ctxs    = allocator.alloc(WorkerCtx, threads) catch break :mineLoop;
            defer allocator.free(ctxs);
            var handles = allocator.alloc(std.Thread, threads) catch break :mineLoop;
            defer allocator.free(handles);

            for (0..threads) |t| {
                ctxs[t] = WorkerCtx{
                    .client      = &client,
                    .algo        = algo,
                    .allocator   = allocator,
                    .nonce_start = @truncate(t),
                    .nonce_step  = @truncate(threads),
                    .en2         = @truncate(t),
                    .found       = std.atomic.Value(bool).init(false),
                    .found_nonce = std.atomic.Value(u32).init(0),
                    .use_avx2    = use_avx2,
                };
            }
            var j = job; j.free(allocator);

            for (0..threads) |t|
                handles[t] = std.Thread.spawn(.{}, workerFn, .{&ctxs[t]}) catch break :mineLoop;
            for (handles) |h| h.join();

            for (ctxs) |*ctx| {
                if (ctx.found.load(.acquire)) {
                    const nonce = ctx.found_nonce.load(.acquire);
                    const found_job = client.lockJob() orelse break;
                    defer { var fj = found_job; fj.free(allocator); }
                    std.debug.print("[Miner] Share! nonce=0x{x:0>8}\n", .{nonce});
                    client.submitShare(found_job.job_id, nonce, found_job.ntime, ctx.en2) catch {};
                    break;
                }
            }
        }
        std.debug.print("[Miner] Disconnected -- reconnecting...\n", .{});
    }
    std.debug.print("[Miner] Stopped.\n", .{});
}
