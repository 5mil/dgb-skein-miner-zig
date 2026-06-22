const std     = @import("std");
const skein    = @import("skein.zig");
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
        \\  rake                                        Run self-tests
        \\  rake <160-hex>                              Hash single header (Skein)
        \\  rake --mine <wallet> [options]
        \\
        \\Options:
        \\  --host <host>           Pool host  (default: americas.mining-dutch.nl)
        \\  --port <port>           Pool port  (default: 9994)
        \\  --algo skein|yescrypt   Algorithm  (default: skein)
        \\  --threads <n>           Worker threads (default: 4)
        \\
        \\Example:
        \\  rake --mine 5mil.worker55 --algo skein --threads 4
        \\  rake --mine 5mil.worker55 --algo skein --threads 8 --host pool.example.com --port 3333
        \\
    , .{});
}

fn stripStratumPrefix(s: []const u8) []const u8 {
    if (std.mem.startsWith(u8, s, "stratum+tcp://")) return s["stratum+tcp://".len..];
    if (std.mem.startsWith(u8, s, "stratum://"))     return s["stratum://".len..];
    return s;
}

pub fn main(init: std.process.Init) !void {
    const gpa  = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    if (argv.len < 2 or std.mem.eql(u8, argv[1], "--help") or std.mem.eql(u8, argv[1], "-h")) {
        printUsage();
        if (argv.len < 2) {
            std.debug.print("=== Self-tests ===\n", .{});
            const sk_ok = skein.runKAT();
            const ye_ok = yescrypt.selftest(gpa) catch false;
            std.debug.print("\n=== Available ===\n", .{});
            if (sk_ok) std.debug.print("  skein    [READY]\n", .{});
            if (ye_ok) std.debug.print("  yescrypt [READY]\n", .{});
            if (!sk_ok and !ye_ok) std.process.exit(1);
        }
        return;
    }

    if (argv[1].len == 160) {
        var input: [80]u8 = undefined;
        for (0..80) |i| input[i] = std.fmt.parseInt(u8, argv[1][i*2..][0..2], 16) catch 0;
        var output: [64]u8 = undefined;
        skein.skein512(&input, &output);
        std.debug.print("Skein-512: {s}\n", .{std.fmt.bytesToHex(&output, .lower)});
        return;
    }

    if (!std.mem.eql(u8, argv[1], "--mine")) { printUsage(); std.process.exit(1); }
    if (argv.len < 3) { printUsage(); std.process.exit(1); }

    const wallet          = argv[2];
    var host: []const u8  = DEFAULT_HOST;
    var port: u16         = DEFAULT_PORT;
    var algo: miner.Algo  = .skein;
    var threads: usize    = 4;

    var i: usize = 3;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--host") and i + 1 < argv.len) {
            i += 1; host = stripStratumPrefix(argv[i]);
        } else if (std.mem.eql(u8, a, "--port") and i + 1 < argv.len) {
            i += 1; port = std.fmt.parseInt(u16, argv[i], 10) catch DEFAULT_PORT;
        } else if (std.mem.eql(u8, a, "--algo") and i + 1 < argv.len) {
            i += 1;
            if      (std.mem.eql(u8, argv[i], "yescrypt")) algo = .yescrypt
            else if (std.mem.eql(u8, argv[i], "skein"))    algo = .skein
            else {
                std.debug.print("Unknown algo: {s}\n", .{argv[i]});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, a, "--threads") and i + 1 < argv.len) {
            i += 1; threads = std.fmt.parseInt(usize, argv[i], 10) catch 4;
        }
    }

    std.debug.print("=== Self-test [{s}] ===\n", .{@tagName(algo)});
    const ok: bool = switch (algo) {
        .skein    => skein.runKAT(),
        .yescrypt => yescrypt.selftest(gpa) catch false,
    };
    if (!ok) {
        std.debug.print("[FATAL] Self-test failed. Aborting.\n", .{});
        std.process.exit(1);
    }

    if (algo == .skein) {
        if (cpu.hasAvx2()) std.debug.print("[CPU] AVX2 4-way active\n", .{})
        else               std.debug.print("[CPU] Scalar path\n", .{});
    }

    std.debug.print("=== Connecting {s}:{d} | wallet={s} | threads={d} ===\n",
        .{ host, port, wallet, threads });

    try miner.runMiner(gpa, host, port, wallet, threads, algo);
}
