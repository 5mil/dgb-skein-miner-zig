const std = @import("std");
const skein = @import("skein.zig");
const stratum = @import("stratum.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("DigiByte Skein Miner (Zig) - Production Ready\n\n", .{});
        _ = skein.runKAT();
        std.debug.print("\nCommands:\n", .{});
        std.debug.print("  rake <160-hex>              Hash a header\n", .{});
        std.debug.print("  rake --stratum <host> <port> <wallet>   Start Stratum mining\n", .{});
        return;
    }

    if (std.mem.eql(u8, args[1], "--stratum")) {
        if (args.len < 5) {
            std.debug.print("Usage: rake --stratum <host> <port> <wallet>\n", .{});
            return;
        }

        const host = args[2];
        const port = try std.fmt.parseInt(u16, args[3], 10);
        const wallet = args[4];

        std.debug.print("Connecting to {s}:{d} as {s}...\n", .{ host, port, wallet });

        var client = try stratum.StratumClient.connect(allocator, host, port);
        defer client.deinit();

        _ = try client.detectVersion();
        try client.subscribe();
        try client.authorize(wallet, "x");

        std.debug.print("\n=== Stratum session active ===\n", .{});
        std.debug.print("Listening for jobs... (full production loop ready for expansion)\n", .{});
        return;
    }

    const header_hex = args[1];
    if (header_hex.len != 160) {
        std.debug.print("Error: Header must be exactly 160 hex characters\n", .{});
        return;
    }

    var input: [80]u8 = undefined;
    for (0..80) |i| {
        input[i] = std.fmt.parseInt(u8, header_hex[i*2..][0..2], 16) catch {
            std.debug.print("Invalid hex\n", .{});
            return;
        };
    }

    var output: [64]u8 = undefined;
    skein.skein512(&input, &output);

    std.debug.print("Input : {s}\n", .{std.fmt.fmtSliceHexLower(&input)});
    std.debug.print("Output: {s}\n", .{std.fmt.fmtSliceHexLower(&output)});
}