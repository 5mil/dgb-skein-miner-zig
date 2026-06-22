//! Windows Stratum client -- Zig 0.16 std.net (NtDll-based, no ws2_32.dll dependency).
//! Mirrors stratum_linux.zig exactly; uses std.net.Stream instead of posix fd.
const std = @import("std");

pub const Job = struct {
    job_id:      []const u8,
    prev_hash:   [32]u8,
    merkle_root: [32]u8,
    version:     u32,
    nbits:       u32,
    ntime:       u32,
    clean_jobs:  bool,

    pub fn dupe(self: Job, allocator: std.mem.Allocator) !Job {
        return Job{
            .job_id      = try allocator.dupe(u8, self.job_id),
            .prev_hash   = self.prev_hash,
            .merkle_root = self.merkle_root,
            .version     = self.version,
            .nbits       = self.nbits,
            .ntime       = self.ntime,
            .clean_jobs  = self.clean_jobs,
        };
    }

    pub fn free(self: *Job, allocator: std.mem.Allocator) void {
        allocator.free(self.job_id);
    }
};

pub const StratumClient = struct {
    stream:            std.net.Stream,
    allocator:         std.mem.Allocator,
    current_job:       ?Job,
    job_mu:            std.Thread.RwLock,
    extra_nonce1:      []u8,
    extra_nonce2_size: usize,
    username:          []u8,

    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) !StratumClient {
        const stream = try std.net.tcpConnectToHost(allocator, host, port);
        return StratumClient{
            .stream            = stream,
            .allocator         = allocator,
            .current_job       = null,
            .job_mu            = .{},
            .extra_nonce1      = try allocator.dupe(u8, ""),
            .extra_nonce2_size = 4,
            .username          = try allocator.dupe(u8, ""),
        };
    }

    pub fn lockJob(self: *StratumClient) ?Job {
        self.job_mu.lockShared();
        defer self.job_mu.unlockShared();
        const j = self.current_job orelse return null;
        return j.dupe(self.allocator) catch null;
    }

    fn writeAll(self: *StratumClient, data: []const u8) !void {
        try self.stream.writeAll(data);
    }

    fn readByte(self: *StratumClient) !u8 {
        var b: [1]u8 = undefined;
        const n = try self.stream.read(&b);
        if (n == 0) return error.ConnectionClosed;
        return b[0];
    }

    pub fn subscribe(self: *StratumClient) !void {
        try self.writeAll("{\"id\":1,\"method\":\"mining.subscribe\",\"params\":[\"ZigRake/1.0\"]}\n");
        var buf: [4096]u8 = undefined;
        const n = try self.stream.read(&buf);
        if (extractJsonString(buf[0..n], "extra_nonce1")) |en1| {
            if (self.extra_nonce1.len > 0) self.allocator.free(self.extra_nonce1);
            self.extra_nonce1 = try self.allocator.dupe(u8, en1);
        }
        if (extractJsonString(buf[0..n], "extra_nonce2_size")) |s| {
            self.extra_nonce2_size = std.fmt.parseInt(usize, s, 10) catch 4;
        }
        std.debug.print("[Stratum] Subscribed extra_nonce1={s} en2_size={d}\n",
            .{ self.extra_nonce1, self.extra_nonce2_size });
    }

    pub fn authorize(self: *StratumClient, user: []const u8, pass: []const u8) !void {
        if (self.username.len > 0) self.allocator.free(self.username);
        self.username = try self.allocator.dupe(u8, user);
        var buf: [512]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf,
            "{{\"id\":2,\"method\":\"mining.authorize\",\"params\":[\"{s}\",\"{s}\"]}}\n",
            .{ user, pass });
        try self.writeAll(msg);
        var rbuf: [4096]u8 = undefined;
        _ = try self.stream.read(&rbuf);
        std.debug.print("[Stratum] Authorized as {s}\n", .{user});
    }

    pub fn handleLine(self: *StratumClient, line: []const u8) !void {
        if (std.mem.indexOf(u8, line, "mining.notify") != null)
            try self.parseNotify(line)
        else if (std.mem.indexOf(u8, line, "mining.set_difficulty") != null) {}
    }

    pub fn parseNotify(self: *StratumClient, line: []const u8) !void {
        const ps  = std.mem.indexOf(u8, line, "\"params\":") orelse return;
        const as_ = std.mem.indexOfPos(u8, line, ps, "[") orelse return;
        var strings: [16][]const u8 = undefined;
        var count: usize = 0;
        var pos: usize = as_ + 1;
        var depth: usize = 0;
        while (count < 16) {
            while (pos < line.len and (line[pos] == ' ' or line[pos] == ',')) pos += 1;
            if (pos >= line.len) break;
            if (line[pos] == '[') { depth += 1; pos += 1; continue; }
            if (line[pos] == ']') { if (depth == 0) break; depth -= 1; pos += 1; continue; }
            if (line[pos] == '"') {
                pos += 1;
                const start = pos;
                while (pos < line.len and line[pos] != '"') pos += 1;
                strings[count] = line[start..pos];
                count += 1; pos += 1;
            } else if (line[pos] == 't' or line[pos] == 'f') {
                const start = pos;
                while (pos < line.len and line[pos] != ',' and line[pos] != ']') pos += 1;
                strings[count] = line[start..pos];
                count += 1;
            } else {
                while (pos < line.len and line[pos] != ',' and line[pos] != ']') pos += 1;
            }
        }
        if (count < 8) return;
        const branch_count = count - 8;
        var prev_hash: [32]u8 = [_]u8{0} ** 32;
        if (strings[1].len == 64) hexDecode(strings[1], &prev_hash) catch {};
        const merkle_root = buildMerkleRoot(
            self.allocator,
            strings[2], strings[3],
            self.extra_nonce1, self.extra_nonce2_size,
            strings[4..][0..branch_count],
        ) catch [_]u8{0} ** 32;
        const clean_jobs = std.mem.eql(u8, strings[7 + branch_count], "true");
        const new_job = Job{
            .job_id      = try self.allocator.dupe(u8, strings[0]),
            .prev_hash   = prev_hash,
            .merkle_root = merkle_root,
            .version     = std.fmt.parseInt(u32, strings[4 + branch_count], 16) catch 0x20000000,
            .nbits       = std.fmt.parseInt(u32, strings[5 + branch_count], 16) catch 0,
            .ntime       = std.fmt.parseInt(u32, strings[6 + branch_count], 16) catch 0,
            .clean_jobs  = clean_jobs,
        };
        self.job_mu.lock();
        if (self.current_job) |*j| j.free(self.allocator);
        self.current_job = new_job;
        self.job_mu.unlock();
        std.debug.print("[Stratum] Job: {s} clean={} nbits={x}\n",
            .{ strings[0], clean_jobs, new_job.nbits });
    }

    pub fn submitShare(self: *StratumClient, job_id: []const u8, nonce: u32, ntime: u32, en2: u32) !void {
        const worker = if (self.username.len > 0) self.username else "worker";
        var buf: [640]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf,
            "{{\"id\":4,\"method\":\"mining.submit\",\"params\":" ++
            "[\"{s}\",\"{s}\",\"{s}\",\"{x:0>8}\",\"{x:0>8}\",\"{x:0>8}\"]}}\n",
            .{ worker, job_id, self.extra_nonce1, en2, ntime, nonce });
        try self.writeAll(msg);
        std.debug.print("[Stratum] Submitted nonce=0x{x:0>8} en2=0x{x:0>8}\n", .{ nonce, en2 });
    }

    pub fn readLine(self: *StratumClient, buf: []u8) !?[]const u8 {
        var i: usize = 0;
        while (i < buf.len) {
            const b = self.readByte() catch return null;
            if (b == '\n') return buf[0..i];
            buf[i] = b;
            i += 1;
        }
        return null;
    }

    pub fn deinit(self: *StratumClient) void {
        self.stream.close();
        if (self.current_job) |*j| j.free(self.allocator);
        if (self.extra_nonce1.len > 0) self.allocator.free(self.extra_nonce1);
        if (self.username.len > 0)     self.allocator.free(self.username);
    }
};

fn buildMerkleRoot(allocator: std.mem.Allocator, coinb1: []const u8, coinb2: []const u8,
    en1: []const u8, en2_size: usize, branch: []const []const u8) ![32]u8 {
    const cb1 = try hexAlloc(allocator, coinb1); defer allocator.free(cb1);
    const cb2 = try hexAlloc(allocator, coinb2); defer allocator.free(cb2);
    const e1  = try hexAlloc(allocator, en1);    defer allocator.free(e1);
    const coinbase = try allocator.alloc(u8, cb1.len + e1.len + en2_size + cb2.len);
    defer allocator.free(coinbase);
    var off: usize = 0;
    @memcpy(coinbase[off..off+cb1.len], cb1); off += cb1.len;
    @memcpy(coinbase[off..off+e1.len],  e1);  off += e1.len;
    @memset(coinbase[off..off+en2_size], 0);  off += en2_size;
    @memcpy(coinbase[off..off+cb2.len], cb2);
    var root: [32]u8 = undefined;
    sha256d(coinbase, &root);
    for (branch) |bh| {
        const bh_bytes = try hexAlloc(allocator, bh); defer allocator.free(bh_bytes);
        if (bh_bytes.len != 32) continue;
        var pair: [64]u8 = undefined;
        @memcpy(pair[0..32], &root); @memcpy(pair[32..64], bh_bytes);
        sha256d(&pair, &root);
    }
    return root;
}

fn sha256d(data: []const u8, out: *[32]u8) void {
    var tmp: [32]u8 = undefined;
    var h1 = std.crypto.hash.sha2.Sha256.init(.{});
    h1.update(data); h1.final(&tmp);
    var h2 = std.crypto.hash.sha2.Sha256.init(.{});
    h2.update(&tmp); h2.final(out);
}

fn hexAlloc(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.BadHexLen;
    const out = try allocator.alloc(u8, hex.len / 2);
    for (0..out.len) |i|
        out[i] = try std.fmt.parseInt(u8, hex[i*2..][0..2], 16);
    return out;
}

fn hexDecode(hex: []const u8, out: []u8) !void {
    if (hex.len != out.len * 2) return error.BadHexLen;
    for (0..out.len) |i|
        out[i] = try std.fmt.parseInt(u8, hex[i*2..][0..2], 16);
}

fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const vs = start + needle.len;
    const ve = std.mem.indexOfPos(u8, json, vs, "\"") orelse return null;
    return json[vs..ve];
}
