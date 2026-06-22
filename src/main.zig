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
        std.debug.print("DigiByte Skein Miner (Zig) with Stratum\n\n", .{});
        _ = skein.runKAT();

        std.debug.print("\nUsage examples:\n", .{});
        std.debug.print("  rake <header>                    # Hash a header\n", .{});
        std.debug.print("  rake --stratum <pool> <port>     # Connect to Stratum (WIP)\n", .{});
        return;
    }

    if (std.mem.eql(u8, args[1], "--stratum")) {
        if (args.len < 4) {
            std.debug.print("Usage: rake --stratum <host> <port>\n", .{});
            return;
        }

        const host = args[2];
        const port = try std.fmt.parseInt(u16, args[3], 10);

        std.debug.print("Connecting to {s}:{d}...\n", .{ host, port });

        var client = try stratum.StratumClient.connect(allocator, host, port);
        defer client.deinit();

        try client.subscribe();
        try client.authorize("DGexample", "x");

        std.debug.print("Stratum connection established (basic).\n", .{});
        std.debug.print("Full job handling + mining loop coming next.\n", .{});
        return;
    }

    // Normal header hashing mode
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