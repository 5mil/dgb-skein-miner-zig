const std = @import("std");
const skein = @import("skein.zig");
const stratum = @import("stratum.zig");
const miner = @import("miner.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("DigiByte Skein Miner (Zig) - Fully Integrated\n\n", .{});
        _ = skein.runKAT();
        std.debug.print("\nCommands:\n", .{});
        std.debug.print("  rake <160-hex>                           Hash single header\n", .{});
        std.debug.print("  rake --mine <host> <port> <wallet>       Full Stratum miner\n", .{});
        return;
    }

    if (std.mem.eql(u8, args[1], "--mine")) {
        if (args.len < 5) {
            std.debug.print("Usage: rake --mine <host> <port> <wallet>\n", .{});
            return;
        }

        const host = args[2];
        const port = try std.fmt.parseInt(u16, args[3], 10);
        const wallet = args[4];

        std.debug.print("=== Starting Production Miner ===\n", .{});
        std.debug.print("Pool: {s}:{d}\n", .{ host, port });
        std.debug.print("Wallet: {s}\n\n", .{ wallet });

        var client = try stratum.StratumClient.connect(allocator, host, port);
        defer client.deinit();

        _ = try client.detectVersion();
        try client.subscribe();
        try client.authorize(wallet, "x");

        try miner.runMiner(allocator, &client, wallet, 4);
        return;
    }

    const header_hex = args[1];
    if (header_hex.len != 160) {
        std.debug.print("Error: Header must be 160 hex chars\n", .{});
        return;
    }

    var input: [80]u8 = undefined;
    for (0..80) |i| {
        input[i] = std.fmt.parseInt(u8, header_hex[i*2..][0..2], 16) catch 0;
    }

    var output: [64]u8 = undefined;
    skein.skein512(&input, &output);

    std.debug.print("Input : {s}\n", .{std.fmt.fmtSliceHexLower(&input)});
    std.debug.print("Output: {s}\n", .{std.fmt.fmtSliceHexLower(&output)});
}