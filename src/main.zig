const std = @import("std");
const skein = @import("skein.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("DigiByte Skein Miner (Zig) - KAT + Hash Test\n\n", .{});
        _ = skein.runKAT();
        std.debug.print("\nUsage: rake <160-char hex header>\n", .{});
        return;
    }

    const header_hex = args[1];

    if (header_hex.len != 160) {
        std.debug.print("Error: Header must be exactly 160 hex characters\n", .{});
        return;
    }

    var input: [80]u8 = undefined;
    for (0..80) |i| {
        const byte_str = header_hex[i*2..][0..2];
        input[i] = std.fmt.parseInt(u8, byte_str, 16) catch {
            std.debug.print("Invalid hex at position {}\n", .{i});
            return;
        };
    }

    var output: [64]u8 = undefined;
    skein.skein512(&input, &output);

    std.debug.print("Input : {s}\n", .{std.fmt.fmtSliceHexLower(&input)});
    std.debug.print("Output: {s}\n", .{std.fmt.fmtSliceHexLower(&output)});
}