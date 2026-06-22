const std = @import("std");
const net = std.net;
const json = std.json;

pub const StratumVersion = enum { v1, v2 };

pub const Job = struct {
    job_id: []const u8,
    prev_hash: [32]u8,
    coinb1: []const u8,
    coinb2: []const u8,
    merkle_branches: [][]const u8,
    version: u32,
    nbits: u32,
    ntime: u32,
    clean_jobs: bool,
};

pub const StratumClient = struct {
    stream: net.Stream,
    allocator: std.mem.Allocator,
    current_job: ?Job,
    stratum_version: StratumVersion,
    extra_nonce1: []const u8,
    extra_nonce2_size: usize,

    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) !StratumClient {
        const address = try net.Address.parseIp(host, port);
        const stream = try net.tcpConnectToAddress(address);

        return StratumClient{
            .stream = stream,
            .allocator = allocator,
            .current_job = null,
            .stratum_version = .v1,
            .extra_nonce1 = &[_]u8{},
            .extra_nonce2_size = 4,
        };
    }

    pub fn detectVersion(self: *StratumClient) !StratumVersion {
        self.stratum_version = .v1;
        return .v1;
    }

    pub fn subscribe(self: *StratumClient) !void {
        if (self.stratum_version == .v1) {
            const msg = "{\"id\":1,\"method\":\"mining.subscribe\",\"params\":[\"ZigRake/1.0\"]}\n";
            _ = try self.stream.write(msg);

            var buf: [4096]u8 = undefined;
            const n = try self.stream.read(&buf);
            const response = buf[0..n];

            if (std.mem.indexOf(u8, response, "mining.notify") != null) {
                std.debug.print("[Stratum v1] Subscribed successfully\n", .{});
            }
        } else {
            std.debug.print("[Stratum v2] Subscription (advanced - WIP)\n", .{});
        }
    }

    pub fn authorize(self: *StratumClient, user: []const u8, pass: []const u8) !void {
        if (self.stratum_version == .v1) {
            var buf: [512]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf,
                "{{\"id\":2,\"method\":\"mining.authorize\",\"params\":[\"{s}\",\"{s}\"]}}\n",
                .{ user, pass }
            );
            _ = try self.stream.write(msg);

            var response: [4096]u8 = undefined;
            const n = try self.stream.read(&response);
            std.debug.print("[Stratum] Authorize completed\n", .{});
        }
    }

    pub fn parseNotify(self: *StratumClient, line: []const u8) !void {
        std.debug.print("[Stratum] Received mining.notify\n", .{});
        if (self.current_job == null) {
            self.current_job = Job{
                .job_id = try self.allocator.dupe(u8, "job"),
                .prev_hash = [_]u8{0} ** 32,
                .coinb1 = &[_]u8{},
                .coinb2 = &[_]u8{},
                .merkle_branches = &[_][]const u8{},
                .version = 0x20000000,
                .nbits = 0,
                .ntime = 0,
                .clean_jobs = true,
            };
        }
    }

    pub fn submitShare(self: *StratumClient, job_id: []const u8, nonce: u64, ntime: u32) !void {
        if (self.stratum_version == .v1) {
            var buf: [512]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf,
                "{{\"id\":4,\"method\":\"mining.submit\",\"params\":[\"worker\",\"{s}\",\"{x}\",\"{x}\"]}}\n",
                .{ job_id, nonce, ntime }
            );
            _ = try self.stream.write(msg);
            std.debug.print("[Stratum] Share submitted nonce={x}\n", .{nonce});
        }
    }

    pub fn readLine(self: *StratumClient, buf: []u8) !?[]const u8 {
        var i: usize = 0;
        while (i < buf.len) {
            const n = try self.stream.read(buf[i..][0..1]);
            if (n == 0) return null;
            if (buf[i] == '\n') return buf[0..i];
            i += 1;
        }
        return null;
    }

    pub fn deinit(self: *StratumClient) void {
        self.stream.close();
    }
}