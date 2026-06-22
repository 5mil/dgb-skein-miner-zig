const std    = @import("std");
const skein   = @import("skein.zig");
const yescrypt = @import("yescrypt.zig");
const stratum  = @import("stratum.zig");
const miner    = @import("miner.zig");
const cpu      = @import("cpu.zig");

const DEFAULT_HOST = "americas.mining-dutch.nl";
const DEFAULT_PORT: u16 = 9994;

fn printUsage() void {
    std.debug.print(
        \\ZigRake -- DGB Skein / YescryptR16 miner
        \\
        \\Usage:
        \\  rake                                         Run self-tests
        \\  rake <160-hex>                               Hash single header (Skein)
        \\  rake --mine <wallet> [options]
        \\
        \\Options:
        \\  --host <host>           Pool host  (default: americas.mining-dutch.nl)
        \\  --port <port>           Pool port  (default: 9994)
        \\  --algo skein|yescrypt  Algorithm  (default: skein)
        \\  --threads <n>           Worker threads (default: 4)
        \\
        \\Example:
        \\  rake --mine DGB1yourwalletaddress --algo skein --threads 8
        \\
    , .{});
}

/// Strip stratum+tcp:// or stratum:// prefix if present.
fn stripStratumPrefix(s: []const u8) []const u8 {
    if (std.mem.startsWith(u8, s, "stratum+tcp://")) return s["stratum+tcp://".len..];
    if (std.mem.startsWith(u8, s, "stratum://"))     return s["stratum://".len..];
    return s;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        std.debug.print("=== Self-tests ===\n", .{});
        const sk_ok = skein.runKAT();
        const ye_ok = yescrypt.selftest(allocator) catch false;
        std.debug.print("\n=== Available ===\n", .{});
        if (sk_ok) std.debug.print("  skein    [READY]\n", .{});
        if (ye_ok) std.debug.print("  yescrypt [READY]\n", .{});
        if (!sk_ok and !ye_ok) std.process.exit(1);
        return;
    }

    // Single-header debug hash
    if (args[1].len == 160) {
        var input: [80]u8 = undefined;
        for (0..80) |i| input[i] = std.fmt.parseInt(u8, args[1][i*2..][0..2], 16) catch 0;
        var output: [64]u8 = undefined;
        skein.skein512(&input, &output);
        std.debug.print("Skein-512: {s}\n", .{std.fmt.fmtSliceHexLower(&output)});
        return;
    }

    if (!std.mem.eql(u8, args[1], "--mine")) { printUsage(); std.process.exit(1); }
    if (args.len < 3) { printUsage(); std.process.exit(1); }

    const wallet = args[2];

    // Parse optional flags
    var host: []const u8    = DEFAULT_HOST;
    var port: u16           = DEFAULT_PORT;
    var algo: miner.Algo    = .skein;
    var threads: usize      = 4;

    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--host") and i+1 < args.len) {
            i += 1; host = stripStratumPrefix(args[i]);
        } else if (std.mem.eql(u8, a, "--port") and i+1 < args.len) {
            i += 1; port = std.fmt.parseInt(u16, args[i], 10) catch DEFAULT_PORT;
        } else if (std.mem.eql(u8, a, "--algo") and i+1 < args.len) {
            i += 1;
            if (std.mem.eql(u8, args[i], "yescrypt"))     algo = .yescrypt
            else if (std.mem.eql(u8, args[i], "skein"))   algo = .skein
            else { std.debug.print("Unknown algo: {s}\n", .{args[i]}); std.process.exit(1); };
        } else if (std.mem.eql(u8, a, "--threads") and i+1 < args.len) {
            i += 1; threads = std.fmt.parseInt(usize, args[i], 10) catch 4;
        }
    }

    // Self-test for chosen algo
    std.debug.print("=== Self-test [{s}] ===\n", .{@tagName(algo)});
    const ok: bool = switch (algo) {
        .skein    => skein.runKAT(),
        .yescrypt => yescrypt.selftest(allocator) catch false,
    };
    if (!ok) {
        std.debug.print("[FATAL] Self-test failed. Aborting.\n", .{});
        std.process.exit(1);
    }

    if (algo == .skein) {
        if (cpu.hasAvx2()) std.debug.print("[CPU] AVX2 active\n", .{})
        else               std.debug.print("[CPU] Scalar path\n", .{});
    }

    std.debug.print("=== Connecting {s}:{d} | wallet={s} | threads={d} ===\n",
        .{ host, port, wallet, threads });

    var client = try stratum.StratumClient.connect(allocator, host, port);
    defer client.deinit();

    try client.subscribe();
    try client.authorize(wallet, "x");
    try miner.runMiner(allocator, &client, wallet, threads, algo);
}
