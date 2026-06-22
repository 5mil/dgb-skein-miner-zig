const std = @import("std");
const skein    = @import("skein.zig");
const yescrypt = @import("yescrypt.zig");
const stratum  = @import("stratum.zig");
const miner    = @import("miner.zig");
const cpu      = @import("cpu.zig");

fn printUsage() void {
    std.debug.print(
        \\ZigRake -- DGB Skein / YescryptR16 miner
        \\
        \\Usage:
        \\  rake                              Run self-tests
        \\  rake --mine <host> <port> <wallet> [--algo skein|yescrypt]
        \\
        \\Defaults to skein if --algo is omitted.
        \\
    , .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // ----------------------------------------------------------------
    // No args: run self-tests and report available algorithms
    // ----------------------------------------------------------------
    if (args.len < 2) {
        printUsage();
        var skein_ok    = false;
        var yescrypt_ok = false;

        std.debug.print("\n=== Self-tests ===\n", .{});
        skein_ok = skein.runKAT();
        yescrypt_ok = yescrypt.selftest(allocator) catch false;

        std.debug.print("\n=== Available algorithms ===\n", .{});
        if (skein_ok)    std.debug.print("  skein      [READY]\n", .{});
        if (yescrypt_ok) std.debug.print("  yescrypt   [READY]\n", .{});
        if (!skein_ok and !yescrypt_ok) {
            std.debug.print("  ALL FAIL -- cannot mine\n", .{});
            std.process.exit(1);
        }
        return;
    }

    // ----------------------------------------------------------------
    // --mine path
    // ----------------------------------------------------------------
    if (!std.mem.eql(u8, args[1], "--mine")) {
        // Single-header hash (debug mode)
        const header_hex = args[1];
        if (header_hex.len != 160) {
            std.debug.print("Error: header must be 160 hex chars (80 bytes)\n", .{});
            std.process.exit(1);
        }
        var input: [80]u8 = undefined;
        for (0..80) |i| input[i] = std.fmt.parseInt(u8, header_hex[i*2..][0..2], 16) catch 0;
        var output: [64]u8 = undefined;
        skein.skein512(&input, &output);
        std.debug.print("Skein-512: {s}\n", .{std.fmt.fmtSliceHexLower(&output)});
        return;
    }

    if (args.len < 5) { printUsage(); std.process.exit(1); }

    const host   = args[2];
    const port   = try std.fmt.parseInt(u16, args[3], 10);
    const wallet = args[4];

    // Parse optional --algo flag
    var algo: miner.Algo = .skein;
    var threads: usize = 4;
    var i: usize = 5;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--algo") and i + 1 < args.len) {
            i += 1;
            if (std.mem.eql(u8, args[i], "yescrypt")) algo = .yescrypt
            else if (std.mem.eql(u8, args[i], "skein"))    algo = .skein
            else { std.debug.print("Unknown algo: {s}\n", .{args[i]}); std.process.exit(1); };
        } else if (std.mem.eql(u8, args[i], "--threads") and i + 1 < args.len) {
            i += 1;
            threads = std.fmt.parseInt(usize, args[i], 10) catch 4;
        }
    }

    // ----------------------------------------------------------------
    // Self-test before mining -- must pass chosen algo
    // ----------------------------------------------------------------
    std.debug.print("=== Self-test [{s}] ===\n", .{@tagName(algo)});
    const algo_ok: bool = switch (algo) {
        .skein    => skein.runKAT(),
        .yescrypt => yescrypt.selftest(allocator) catch false,
    };
    if (!algo_ok) {
        std.debug.print("[FATAL] Self-test failed for {s}. Aborting.\n", .{@tagName(algo)});
        std.process.exit(1);
    }

    if (algo == .skein) {
        if (cpu.hasAvx2()) {
            std.debug.print("[CPU] AVX2 detected -- 4-way Skein path active\n", .{});
        } else {
            std.debug.print("[CPU] Scalar Skein path\n", .{});
        }
    }

    // ----------------------------------------------------------------
    // Connect and mine
    // ----------------------------------------------------------------
    std.debug.print("=== Connecting to {s}:{d} as {s} ===\n", .{ host, port, wallet });
    var client = try stratum.StratumClient.connect(allocator, host, port);
    defer client.deinit();

    try client.subscribe();
    try client.authorize(wallet, "x");

    try miner.runMiner(allocator, &client, wallet, threads, algo);
}
