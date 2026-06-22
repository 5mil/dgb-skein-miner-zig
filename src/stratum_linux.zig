//! Stratum v1 client -- Linux (x86_64-linux-musl, aarch64-linux-musl)
//! DNS via std.c.getaddrinfo -- musl is libc, so std.c symbols are available.
const std   = @import("std");
const posix = std.posix;
const c     = std.c;

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
    fd:                posix.socket_t,
    allocator:         std.mem.Allocator,
    current_job:       ?Job,
    extra_nonce1:      []u8,
    extra_nonce2_size: usize,
    username:          []u8,

    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) !StratumClient {
        var port_buf: [6]u8 = undefined;
        // bufPrintZ renamed to bufPrintSentinel in Zig 0.16
        const port_str = try std.fmt.bufPrintSentinel(&port_buf, 0, "{d}", .{port});
        const host_z   = try allocator.dupeZ(u8, host);
        defer allocator.free(host_z);

        // std.c.addrinfo / getaddrinfo / freeaddrinfo -- available when linking musl.
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
        if (c.getaddrinfo(host_z.ptr, port_str.ptr, &hints, &res) != 0)
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
                .extra_nonce1      = try allocator.dupe(u8, ""),
                .extra_nonce2_size = 4,
                .username          = try allocator.dupe(u8, ""),
            };
        }
        return error.ConnectionFailed;
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
        std.debug.print("[Stratum] Subscribed extra_nonce1={s}\n", .{self.extra_nonce1});
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

    pub fn handleLine(self: *StratumClient, line: []const u8, allocator: std.mem.Allocator) !void {
        if (std.mem.indexOf(u8, line, "mining.notify") != null)
            try self.parseNotify(line, allocator)
        else if (std.mem.indexOf(u8, line, "mining.set_difficulty") != null) {}
    }

    pub fn parseNotify(self: *StratumClient, line: []const u8, allocator: std.mem.Allocator) !void {
        const ps  = std.mem.indexOf(u8, line, "\"params\":") orelse return;
        const as_ = std.mem.indexOfPos(u8, line, ps, "[") orelse return;
        var strings: [8][]const u8 = undefined;
        var count: usize = 0;
        var pos: usize = as_ + 1;
        while (count < 8) {
            while (pos < line.len and (line[pos] == ' ' or line[pos] == ',')) pos += 1;
            if (pos >= line.len or line[pos] == ']') break;
            if (line[pos] == '"') {
                pos += 1;
                const start = pos;
                while (pos < line.len and line[pos] != '"') pos += 1;
                strings[count] = line[start..pos];
                count += 1; pos += 1;
            } else {
                while (pos < line.len and line[pos] != ',' and line[pos] != ']') pos += 1;
            }
        }
        if (count < 5) return;
        var prev_hash: [32]u8 = [_]u8{0} ** 32;
        if (strings[1].len == 64) hexDecode(strings[1], &prev_hash) catch {};
        if (self.current_job) |j| allocator.free(j.job_id);
        self.current_job = Job{
            .job_id      = try allocator.dupe(u8, strings[0]),
            .prev_hash   = prev_hash,
            .merkle_root = [_]u8{0} ** 32,
            .coinb1 = "", .coinb2 = "",
            .version     = std.fmt.parseInt(u32, strings[2], 16) catch 0x20000000,
            .nbits       = std.fmt.parseInt(u32, strings[3], 16) catch 0,
            .ntime       = std.fmt.parseInt(u32, strings[4], 16) catch 0,
            .clean_jobs  = true,
        };
        std.debug.print("[Stratum] Job: {s}\n", .{strings[0]});
    }

    pub fn submitShare(self: *StratumClient, job_id: []const u8, nonce: u32, ntime: u32) !void {
        const worker = if (self.username.len > 0) self.username else "worker";
        var buf: [512]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf,
            "{{\"id\":4,\"method\":\"mining.submit\",\"params\":" ++
            "[\"{s}\",\"{s}\",\"{s}\",\"{x:0>8}\",\"{x:0>8}\"]}}\n",
            .{ worker, job_id, self.extra_nonce1, ntime, nonce });
        try self.writeAll(msg);
        std.debug.print("[Stratum] Submitted nonce=0x{x:0>8}\n", .{nonce});
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
        if (self.current_job) |j| self.allocator.free(j.job_id);
        if (self.extra_nonce1.len > 0) self.allocator.free(self.extra_nonce1);
        if (self.username.len > 0)     self.allocator.free(self.username);
    }
};

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
