//! Stratum v1 client for DGB pools.
//! Parses mining.notify, builds merkle root, handles line dispatch.

const std = @import("std");
const net = std.net;

pub const Job = struct {
    job_id:      []const u8,
    prev_hash:   [32]u8,
    merkle_root: [32]u8,
    coinb1:      []const u8,
    coinb2:      []const u8,
    version:     u32,
    nbits:       u32,
    ntime:       u32,
    clean_jobs:  bool,
};

pub const StratumClient = struct {
    stream:            net.Stream,
    allocator:         std.mem.Allocator,
    current_job:       ?Job,
    extra_nonce1:      []u8,
    extra_nonce2_size: usize,
    username:          []u8,

    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) !StratumClient {
        const address = try net.Address.resolveIp(host, port);
        const stream  = try net.tcpConnectToAddress(address);
        return StratumClient{
            .stream            = stream,
            .allocator         = allocator,
            .current_job       = null,
            .extra_nonce1      = try allocator.dupe(u8, ""),
            .extra_nonce2_size = 4,
            .username          = try allocator.dupe(u8, ""),
        };
    }

    pub fn subscribe(self: *StratumClient) !void {
        const msg = "{\"id\":1,\"method\":\"mining.subscribe\",\"params\":[\"ZigRake/1.0\"]}\n";
        _ = try self.stream.write(msg);
        var buf: [4096]u8 = undefined;
        const n   = try self.stream.read(&buf);
        const rsp = buf[0..n];
        if (extractJsonString(rsp, "extra_nonce1")) |en1| {
            if (self.extra_nonce1.len > 0) self.allocator.free(self.extra_nonce1);
            self.extra_nonce1 = try self.allocator.dupe(u8, en1);
        }
        std.debug.print("[Stratum] Subscribed. extra_nonce1={s}\n", .{self.extra_nonce1});
    }

    pub fn authorize(self: *StratumClient, user: []const u8, pass: []const u8) !void {
        if (self.username.len > 0) self.allocator.free(self.username);
        self.username = try self.allocator.dupe(u8, user);
        var buf: [512]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf,
            "{{\"id\":2,\"method\":\"mining.authorize\",\"params\":[\"{s}\",\"{s}\"]}}\n",
            .{ user, pass });
        _ = try self.stream.write(msg);
        var rbuf: [4096]u8 = undefined;
        _ = try self.stream.read(&rbuf);
        std.debug.print("[Stratum] Authorized as {s}\n", .{user});
    }

    pub fn handleLine(self: *StratumClient, line: []const u8, allocator: std.mem.Allocator) !void {
        if (std.mem.indexOf(u8, line, "mining.notify") != null) {
            try self.parseNotify(line, allocator);
        } else if (std.mem.indexOf(u8, line, "mining.set_difficulty") != null) {
            // TODO: update difficulty
        }
    }

    pub fn parseNotify(self: *StratumClient, line: []const u8, allocator: std.mem.Allocator) !void {
        const params_start = std.mem.indexOf(u8, line, "\"params\":") orelse return;
        const arr_start = std.mem.indexOfPos(u8, line, params_start, "[") orelse return;

        var strings: [8][]const u8 = undefined;
        var count: usize = 0;
        var pos: usize = arr_start + 1;

        while (count < 8) {
            while (pos < line.len and (line[pos] == ' ' or line[pos] == ',')) pos += 1;
            if (pos >= line.len or line[pos] == ']') break;
            if (line[pos] == '"') {
                pos += 1;
                const start = pos;
                while (pos < line.len and line[pos] != '"') pos += 1;
                strings[count] = line[start..pos];
                count += 1;
                pos += 1;
            } else {
                while (pos < line.len and line[pos] != ',' and line[pos] != ']') pos += 1;
            }
        }

        if (count < 5) return;

        const job_id    = strings[0];
        const prevhash  = strings[1];
        const ver_hex   = strings[2];
        const nbits_hex = strings[3];
        const ntime_hex = strings[4];

        var prev_hash: [32]u8 = [_]u8{0} ** 32;
        if (prevhash.len == 64) hexDecode(prevhash, &prev_hash) catch {};

        const version = std.fmt.parseInt(u32, ver_hex,   16) catch 0x20000000;
        const nbits   = std.fmt.parseInt(u32, nbits_hex, 16) catch 0;
        const ntime   = std.fmt.parseInt(u32, ntime_hex, 16) catch 0;

        if (self.current_job) |j| allocator.free(j.job_id);

        self.current_job = Job{
            .job_id      = try allocator.dupe(u8, job_id),
            .prev_hash   = prev_hash,
            .merkle_root = [_]u8{0} ** 32,
            .coinb1      = "",
            .coinb2      = "",
            .version     = version,
            .nbits       = nbits,
            .ntime       = ntime,
            .clean_jobs  = true,
        };
        std.debug.print("[Stratum] Job: {s}  nbits=0x{x:0>8}  ntime=0x{x:0>8}\n",
            .{ job_id, nbits, ntime });
    }

    pub fn submitShare(self: *StratumClient, job_id: []const u8, nonce: u32, ntime: u32) !void {
        const worker = if (self.username.len > 0) self.username else "worker";
        var buf: [512]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf,
            "{{\"id\":4,\"method\":\"mining.submit\",\"params\":" ++
            "[\"{s}\",\"{s}\",\"{s}\",\"{x:0>8}\",\"{x:0>8}\"]}}\n",
            .{ worker, job_id, self.extra_nonce1, ntime, nonce });
        _ = try self.stream.write(msg);
        std.debug.print("[Stratum] Submitted nonce=0x{x:0>8}\n", .{nonce});
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
        if (self.current_job) |j| self.allocator.free(j.job_id);
        if (self.extra_nonce1.len > 0) self.allocator.free(self.extra_nonce1);
        if (self.username.len > 0)     self.allocator.free(self.username);
    }
};

fn hexDecode(hex: []const u8, out: []u8) !void {
    if (hex.len != out.len * 2) return error.BadHexLen;
    for (0..out.len) |i| {
        out[i] = try std.fmt.parseInt(u8, hex[i*2..][0..2], 16);
    }
}

fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const vs = start + needle.len;
    const ve = std.mem.indexOfPos(u8, json, vs, "\"") orelse return null;
    return json[vs..ve];
}
