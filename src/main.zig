const std = @import("std");
const skein = @import("skein.zig");

pub fn main() !void {
    std.debug.print("DigiByte Skein Miner (Zig port) - Scalar KAT Test\n\n", .{});

    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args.deinit();
    _ = args.skip();

    if (args.next()) |header_hex| {
        if (header_hex.len != 160) {
            std.debug.print("Error: Header must be exactly 160 hex characters (80 bytes)\n", .{});
            return;
        }

        var input: [80]u8 = undefined;
        for (0..80) |i| {
            const byte_str = header_hex[i*2 ..][0..2];
            input[i] = std.fmt.parseInt(u8, byte_str, 16) catch 0;
        }

        var output: [64]u8 = undefined;
        skein.skein512(&input, &output);

        std.debug.print("Input  (80 bytes): {s}\n", .{std.fmt.fmtSliceHexLower(&input)});
        std.debug.print("Output (64 bytes): {s}\n", .{std.fmt.fmtSliceHexLower(&output)});
    } else {
        std.debug.print("No header provided. Running KAT test...\n\n", .{});
        skein.runKAT();
        std.debug.print("\nUsage: rake <160-char-hex-header>\n", .{});
    }
}