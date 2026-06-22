//! Stratum v1 client -- Linux (x86_64-linux-musl, aarch64-linux-musl)
//! DNS via std.c.getaddrinfo -- musl is libc, so std.c symbols are available.
const std   = @import("std");
const posix = std.posix;
const c     = std.c;

pub const Job = struct {
    job_id:      []const u8,   // heap-owned by Job
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
    fd:                posix.socket_t,
    allocator:         std.mem.Allocator,
    /// Protected by job_mu. Workers take a snapshot via lockJob().
    current_job:       ?Job,
    job_mu:            std.Thread.RwLock,
    extra_nonce1:      []u8,
    extra_nonce2_size: usize,
    username:          []u8,

    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) !StratumClient {
        var port_buf: [6]u8 = undefined;
        const port_slice = try std.fmt.bufPrint(&port_buf, "{d}", .{port});
        const port_z = try allocator.dupeZ(u8, port_slice);
        defer allocator.free(port_z);
        const host_z = try allocator.dupeZ(u8, host);
        defer allocator.free(host_z);

        const hints = c.addrinfo{
            .flags     = 0,
            .family    = posix.AF.UNSPEC,
            .socktype  = posix.SOCK.STREAM,
            .protocol  = 0,
            .addrlen   = 0,
            .addr      = null,
            .canonname = null,
            .next      = null,
        };
        var res: ?*c.addrinfo = null;
        if (c.getaddrinfo(host_z.ptr, port_z.ptr, &hints, &res) != 0)
            return error.HostNotFound;
        defer c.freeaddrinfo(res);

        var it: ?*c.addrinfo = res;
        while (it) |ai| : (it = ai.next) {
            const fd = posix.socket(
                @intCast(ai.family),
                posix.SOCK.STREAM,
                posix.IPPROTO.TCP,
            ) catch continue;
            posix.connect(fd, ai.addr.?, @intCast(ai.addrlen)) catch {
                posix.close(fd);
                continue;
            };
            return StratumClient{
                .fd                = fd,
                .allocator         = allocator,
                .current_job       = null,
                .job_mu            = .{},
                .extra_nonce1      = try allocator.dupe(u8, ""),
                .extra_nonce2_size = 4,
                .username          = try allocator.dupe(u8, ""),
            };
        }
        return error.ConnectionFailed;
    }

    /// Return a heap-owned snapshot of the current job (caller must call job.free()).
    pub fn lockJob(self: *StratumClient) ?Job {
        self.job_mu.lockShared();
        defer self.job_mu.unlockShared();
        const j = self.current_job orelse return null;
        return j.dupe(self.allocator) catch null;
    }

    fn writeAll(self: *StratumClient, data: []const u8) !void {
        var sent: usize = 0;
        while (sent < data.len)
            sent += try posix.send(self.fd, data[sent..], 0);
    }

    fn readByte(self: *StratumClient) !u8 {
        var b: [1]u8 = undefined;
        if (try posix.recv(self.fd, &b, 0) == 0) return error.ConnectionClosed;
        return b[0];
    }

    pub fn subscribe(self: *StratumClient) !void {
        try self.writeAll("{\"id\":1,\"method\":\"mining.subscribe\",\"params\":[\"ZigRake/1.0\"]}\n");
        var buf: [4096]u8 = undefined;
        const n = try posix.recv(self.fd, &buf, 0);
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
        _ = try posix.recv(self.fd, &rbuf, 0);
        std.debug.print("[Stratum] Authorized as {s}\n", .{user});
    }

    pub fn handleLine(self: *StratumClient, line: []const u8) !void {
        if (std.mem.indexOf(u8, line, "mining.notify") != null)
            try self.parseNotify(line)
        else if (std.mem.indexOf(u8, line, "mining.set_difficulty") != null) {}
    }

    pub fn parseNotify(self: *StratumClient, line: []const u8) !void {
        // params: [job_id, prevhash, coinb1, coinb2, merkle_branch[], version, nbits, ntime, clean_jobs]
        const ps  = std.mem.indexOf(u8, line, "\"params\":") orelse return;
        const as_ = std.mem.indexOfPos(u8, line, ps, "[") orelse return;

        // Collect up to 16 quoted string tokens
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
                // boolean: true/false -- capture as string for clean_jobs
                const start = pos;
                while (pos < line.len and line[pos] != ',' and line[pos] != ']') pos += 1;
                strings[count] = line[start..pos];
                count += 1;
            } else {
                while (pos < line.len and line[pos] != ',' and line[pos] != ']') pos += 1;
            }
        }
        // Minimum: job_id, prevhash, coinb1, coinb2, version, nbits, ntime, clean_jobs = 8
        if (count < 8) return;

        // strings[0] = job_id
        // strings[1] = prevhash (64 hex)
        // strings[2] = coinb1
        // strings[3] = coinb2
        // strings[4..count-5] = merkle branch hashes (0 or more)
        // strings[count-4] = version
        // strings[count-3] = nbits
        // strings[count-2] = ntime
        // strings[count-1] = clean_jobs ("true"/"false")
        const job_id    = strings[0];
        const prevhash  = strings[1];
        const coinb1    = strings[2];
        const coinb2    = strings[3];
        const branch_count = if (count >= 8) count - 8 else 0;
        const version_s    = strings[4 + branch_count];
        const nbits_s      = strings[5 + branch_count];
        const ntime_s      = strings[6 + branch_count];
        const clean_s      = strings[7 + branch_count];

        var prev_hash: [32]u8 = [_]u8{0} ** 32;
        if (prevhash.len == 64) hexDecode(prevhash, &prev_hash) catch {};

        // Build coinbase = coinb1 + extra_nonce1 + zero-padded extra_nonce2 + coinb2
        // Then merkle_root = buildMerkleRoot(sha256d(coinbase), branch[])
        const merkle_root = buildMerkleRoot(
            self.allocator,
            coinb1, coinb2,
            self.extra_nonce1, self.extra_nonce2_size,
            strings[4..][0..branch_count],
        ) catch [_]u8{0} ** 32;

        const clean_jobs = std.mem.eql(u8, clean_s, "true");

        const new_job = Job{
            .job_id      = try self.allocator.dupe(u8, job_id),
            .prev_hash   = prev_hash,
            .merkle_root = merkle_root,
            .version     = std.fmt.parseInt(u32, version_s, 16) catch 0x20000000,
            .nbits       = std.fmt.parseInt(u32, nbits_s,   16) catch 0,
            .ntime       = std.fmt.parseInt(u32, ntime_s,   16) catch 0,
            .clean_jobs  = clean_jobs,
        };

        self.job_mu.lock();
        if (self.current_job) |*j| j.free(self.allocator);
        self.current_job = new_job;
        self.job_mu.unlock();

        std.debug.print("[Stratum] Job: {s} clean={} nbits={x}\n",
            .{ job_id, clean_jobs, new_job.nbits });
    }

    pub fn submitShare(
        self:   *StratumClient,
        job_id: []const u8,
        nonce:  u32,
        ntime:  u32,
        en2:    u32,
    ) !void {
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
        posix.close(self.fd);
        if (self.current_job) |*j| j.free(self.allocator);
        if (self.extra_nonce1.len > 0) self.allocator.free(self.extra_nonce1);
        if (self.username.len > 0)     self.allocator.free(self.username);
    }
};

/// Build the merkle root from coinbase + branch hashes.
/// coinbase = hex(coinb1) ++ hex(extra_nonce1) ++ 00..00(en2_size bytes) ++ hex(coinb2)
/// root starts as sha256d(coinbase), then for each branch: sha256d(root ++ branch)
fn buildMerkleRoot(
    allocator:   std.mem.Allocator,
    coinb1:      []const u8,   // hex string
    coinb2:      []const u8,   // hex string
    en1:         []const u8,   // hex string
    en2_size:    usize,
    branch:      []const []const u8,  // hex strings
) ![32]u8 {
    // Decode hex strings into bytes
    const cb1_bytes = try hexAlloc(allocator, coinb1);
    defer allocator.free(cb1_bytes);
    const cb2_bytes = try hexAlloc(allocator, coinb2);
    defer allocator.free(cb2_bytes);
    const en1_bytes = try hexAlloc(allocator, en1);
    defer allocator.free(en1_bytes);

    // coinbase = cb1 ++ en1 ++ en2(zeros) ++ cb2
    const cb_len = cb1_bytes.len + en1_bytes.len + en2_size + cb2_bytes.len;
    const coinbase = try allocator.alloc(u8, cb_len);
    defer allocator.free(coinbase);
    var off: usize = 0;
    @memcpy(coinbase[off .. off + cb1_bytes.len], cb1_bytes); off += cb1_bytes.len;
    @memcpy(coinbase[off .. off + en1_bytes.len], en1_bytes); off += en1_bytes.len;
    @memset(coinbase[off .. off + en2_size], 0);              off += en2_size;
    @memcpy(coinbase[off .. off + cb2_bytes.len], cb2_bytes);

    // sha256d(coinbase)
    var root: [32]u8 = undefined;
    sha256d(coinbase, &root);

    // Fold in each branch hash: root = sha256d(root ++ branch)
    for (branch) |bh| {
        const bh_bytes = try hexAlloc(allocator, bh);
        defer allocator.free(bh_bytes);
        if (bh_bytes.len != 32) continue;
        var pair: [64]u8 = undefined;
        @memcpy(pair[0..32], &root);
        @memcpy(pair[32..64], bh_bytes);
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
