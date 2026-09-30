//! TCP transport with NINJAM message framing (docs/PROTOCOL.md §1, §2).
//! Frame = 1 type byte + uint32 LE size (<= 16384) + payload.
//! Built directly on std.posix to stay stable across zig std churn.

const std = @import("std");
const bufmod = @import("buf.zig");
const clock = @import("clock.zig");

pub const max_payload: u32 = 16384;

pub const Message = struct {
    mtype: u8,
    payload: []const u8,
};

pub const Error = error{
    BadFrame,
    EndOfStream,
    ConnectionClosed,
} || std.posix.ReadError || std.posix.PollError || std.posix.UnexpectedError || std.mem.Allocator.Error;

pub const Conn = struct {
    io: std.Io = undefined,
    fd: std.posix.socket_t = -1,

    rbuf: [65536]u8 = undefined,
    rhead: usize = 0,
    rtail: usize = 0,

    last_recv_ms: i64 = 0,
    last_send_ms: i64 = 0,

    pub fn connect(io: std.Io, host: []const u8, port: u16) !Conn {
        // fast path: dotted-quad IPv4 literal
        if (std.Io.net.Ip4Address.parse(host, port)) |ip4| {
            const sa = sockaddrIn(ip4);
            return connectSockaddr(io, &sa);
        } else |_| {}

        // hostname: getaddrinfo (libc)
        const host_z = std.heap.page_allocator.dupeZ(u8, host) catch return error.SystemResources;
        defer std.heap.page_allocator.free(host_z);
        var port_buf: [16]u8 = undefined;
        const port_str = std.fmt.bufPrintZ(&port_buf, "{d}", .{port}) catch return error.UnknownHost;

        const hints: std.posix.addrinfo = .{
            .flags = .{},
            .family = std.posix.AF.INET,
            .socktype = std.posix.SOCK.STREAM,
            .protocol = std.posix.IPPROTO.TCP,
            .addrlen = 0,
            .canonname = null,
            .addr = null,
            .next = null,
        };
        var res: ?*std.posix.addrinfo = null;
        const rc = std.posix.system.getaddrinfo(host_z.ptr, port_str.ptr, &hints, &res);
        if (rc != @as(std.posix.system.EAI, @enumFromInt(0)) or res == null) return error.UnknownHost;
        defer if (res) |some| std.posix.system.freeaddrinfo(some);

        var it: ?*std.posix.addrinfo = res;
        while (it) |ai| : (it = ai.next) {
            if (ai.addrlen == 0 or ai.addr == null) continue;
            const fd = openStreamSocket() catch continue;
            std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, 1, &std.mem.toBytes(@as(c_int, 1))) catch {};
            switch (std.posix.errno(std.posix.system.connect(fd, @ptrCast(@alignCast(ai.addr.?)), @intCast(ai.addrlen)))) {
                .SUCCESS, .INTR, .INPROGRESS, .ISCONN => {},
                else => {
                    closeFd(fd);
                    continue;
                },
            }
            setNonblocking(fd);
            return connected(io, fd);
        }
        return error.UnknownHost;
    }

    fn openStreamSocket() !std.posix.socket_t {
        const rc = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
        if (std.posix.errno(rc) != .SUCCESS) return error.SocketOpen;
        return @intCast(rc);
    }

    fn closeFd(fd: std.posix.socket_t) void {
        _ = std.posix.errno(std.posix.system.close(fd));
    }

    fn setNonblocking(fd: std.posix.socket_t) void {
        const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
        _ = std.c.fcntl(fd, std.c.F.SETFL, flags | 0o4000);
    }

    fn sockaddrIn(ip4: std.Io.net.Ip4Address) std.posix.sockaddr.in {
        const In = std.posix.sockaddr.in;
        var sa: In = std.mem.zeroes(In);
        if (@hasField(In, "len")) sa.len = @sizeOf(In);
        sa.family = std.posix.AF.INET;
        sa.port = std.mem.nativeToBig(u16, ip4.port);
        // sockaddr stores network-order bytes in memory; bytes are already
        // in network order, so a native-endian reinterpretation is correct.
        sa.addr = @bitCast(ip4.bytes);
        return sa;
    }

    fn connectSockaddr(io: std.Io, sa: *const std.posix.sockaddr.in) !Conn {
        const fd = try openStreamSocket();
        errdefer closeFd(fd);
        // latency-sensitive protocol: TCP_NODELAY
        std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, 1, &std.mem.toBytes(@as(c_int, 1))) catch {};
        // blocking connect (like the reference client's jnetlib), then go async
        switch (std.posix.errno(std.posix.system.connect(fd, @ptrCast(sa), @sizeOf(std.posix.sockaddr.in)))) {
            .SUCCESS, .INTR, .INPROGRESS => {},
            .ISCONN => {},
            else => |e| {
                std.debug.print("connect errno: {any}\n", .{e});
                return error.ConnectionRefused;
            },
        }
        setNonblocking(fd);
        return connected(io, fd);
    }

    fn connected(io: std.Io, fd: std.posix.socket_t) Conn {
        return .{
            .io = io,
            .fd = fd,
            .last_recv_ms = clock.nowMs(io),
            .last_send_ms = clock.nowMs(io),
        };
    }

    pub fn close(self: *Conn) void {
        closeFd(self.fd);
        self.fd = -1;
    }

    pub fn isConnected(self: *const Conn) bool {
        return self.fd >= 0;
    }

    /// Wait until the socket is readable or timeout_ms elapses. Returns true
    /// if readable.
    pub fn pollReadable(self: *Conn, timeout_ms: i32) !bool {
        if (self.fd < 0) return error.ConnectionClosed;
        var fds = [_]std.posix.pollfd{.{
            .fd = self.fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const n = try std.posix.poll(&fds, timeout_ms);
        return n > 0 and fds[0].revents != 0;
    }

    fn fillMore(self: *Conn) Error!void {
        if (self.fd < 0) return error.ConnectionClosed;
        // compact if full
        if (self.rtail == self.rbuf.len) {
            if (self.rhead > 0) {
                const live = self.rtail - self.rhead;
                std.mem.copyForwards(u8, self.rbuf[0..live], self.rbuf[self.rhead..self.rtail]);
                self.rhead = 0;
                self.rtail = live;
            } else {
                return error.BadFrame; // >64KiB buffered and still no full frame
            }
        }
        const n = std.posix.read(self.fd, self.rbuf[self.rtail..]) catch |e| switch (e) {
            error.WouldBlock => return,
            else => return e,
        };
        if (n == 0) return error.EndOfStream;
        self.rtail += n;
        self.last_recv_ms = clock.nowMs(self.io);
    }

    fn ensureBuffered(self: *Conn, n: usize) Error!void {
        while (self.rtail - self.rhead < n) {
            const before = self.rtail - self.rhead;
            try self.fillMore();
            if (self.rtail - self.rhead == before) {
                // no progress; wait for readability (bounded by poll timeout)
                if (self.fd < 0) return error.ConnectionClosed;
                var fds = [_]std.posix.pollfd{.{
                    .fd = self.fd,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                _ = try std.posix.poll(&fds, 100);
            }
        }
    }

    /// Read one framed message. `payload` receives a copy of the payload
    /// bytes; the returned Message points into it.
    pub fn readMessage(self: *Conn, payload: *bufmod.Buf) Error!Message {
        try self.ensureBuffered(5);
        const t = self.rbuf[self.rhead];
        var size_bytes: [4]u8 = undefined;
        @memcpy(&size_bytes, self.rbuf[self.rhead + 1 ..][0..4]);
        const size = std.mem.readInt(u32, &size_bytes, .little);
        if (t == 0xFF or size > max_payload) return error.BadFrame;
        try self.ensureBuffered(5 + @as(usize, size));
        payload.clear();
        try payload.add(self.rbuf[self.rhead + 5 ..][0..size]);
        self.rhead += 5 + @as(usize, size);
        return .{ .mtype = t, .payload = payload.items() };
    }

    fn writeAllRaw(self: *Conn, data: []const u8) Error!void {
        if (self.fd < 0) return error.ConnectionClosed;
        var off: usize = 0;
        while (off < data.len) {
            const rc = std.posix.system.write(self.fd, data[off..].ptr, data[off..].len);
            switch (std.posix.errno(rc)) {
                .SUCCESS => off += @intCast(rc),
                .AGAIN => {
                    var fds = [_]std.posix.pollfd{.{
                        .fd = self.fd,
                        .events = std.posix.POLL.OUT,
                        .revents = 0,
                    }};
                    _ = try std.posix.poll(&fds, 1000);
                },
                .INTR => {},
                else => return error.ConnectionClosed,
            }
        }
        self.last_send_ms = clock.nowMs(self.io);
    }

    pub fn sendMessage(self: *Conn, mtype: u8, payload: []const u8) Error!void {
        if (payload.len > max_payload) return error.BadFrame;
        var hdr: [5]u8 = undefined;
        hdr[0] = mtype;
        std.mem.writeInt(u32, hdr[1..5], @intCast(payload.len), .little);
        try self.writeAllRaw(&hdr);
        if (payload.len > 0) try self.writeAllRaw(payload);
    }

    /// Send `data`, giving the socket at most `budget_ms` **in total** to accept
    /// it. Returns false if the bytes did not all go out within the budget.
    ///
    /// This exists because `writeAllRaw` cannot be used by the audio clock. The
    /// socket is non-blocking (`setNonblocking` runs right after connect), so a
    /// peer that stops reading turns `write` into EAGAIN — and `writeAllRaw`'s
    /// answer is to `poll(POLLOUT, 1000)` **in a loop, discarding the return
    /// value**. It therefore does not wait "up to a second"; it waits a second,
    /// wakes, tries again, waits another second, and so on, *forever*, until
    /// the peer reads or the connection dies. `finalizeInterval` calls `send()`
    /// inline on the interval-generation path, so that unbounded wait is a
    /// direct stall of the audio clock — measured at >5 s and still not
    /// returning, for a single 16 KiB upload against a socket with an 8 KiB
    /// buffer (see `src/kujamba_timing.zig`, #14).
    ///
    /// A partial write is deliberately reported as a plain `false` rather than an
    /// error: some of the bytes went out and some did not, so the frame is
    /// incomplete. That is benign — both ends frame by the declared length, so
    /// the server simply never completes that guid — whereas failing the session
    /// over a peer that is briefly slow would turn a recoverable stall into a
    /// dead performance.
    fn writeAllBounded(self: *Conn, data: []const u8, budget_ms: i32) Error!bool {
        if (self.fd < 0) return error.ConnectionClosed;
        if (data.len == 0) return true;
        // a deadline, not a per-attempt timeout: three brief stalls inside one
        // budget must not add up to three budgets
        const deadline_ms = clock.nowMs(self.io) + budget_ms;
        var off: usize = 0;
        while (off < data.len) {
            const rc = std.posix.system.write(self.fd, data[off..].ptr, data[off..].len);
            switch (std.posix.errno(rc)) {
                .SUCCESS => off += @intCast(rc),
                .AGAIN => {
                    const left = deadline_ms - clock.nowMs(self.io);
                    if (left <= 0) return false;
                    var fds = [_]std.posix.pollfd{.{
                        .fd = self.fd,
                        .events = std.posix.POLL.OUT,
                        .revents = 0,
                    }};
                    _ = try std.posix.poll(&fds, @intCast(left));
                },
                .INTR => {},
                else => return error.ConnectionClosed,
            }
        }
        self.last_send_ms = clock.nowMs(self.io);
        return true;
    }

    /// `sendMessage` with a hard bound on how long it may wait for the peer.
    ///
    /// Returns false when the message did not go out within `budget_ms`. The
    /// only caller that has to care is the upload path (#14), where giving up on
    /// a bar is strictly better than stalling the audio clock behind it; every
    /// other message can keep using `sendMessage`.
    ///
    /// `budget_ms = 0` never waits at all, which is what an upload wants: it
    /// asks the socket "can you take this?" and acts on the answer instead of
    /// discovering the answer a second later.
    pub fn sendMessageBounded(self: *Conn, mtype: u8, payload: []const u8, budget_ms: i32) Error!bool {
        if (payload.len > max_payload) return error.BadFrame;
        var hdr: [5]u8 = undefined;
        hdr[0] = mtype;
        std.mem.writeInt(u32, hdr[1..5], @intCast(payload.len), .little);
        if (!try self.writeAllBounded(&hdr, budget_ms)) return false;
        if (payload.len == 0) return true;
        return self.writeAllBounded(payload, budget_ms);
    }

    /// Would the socket accept a write right now?
    ///
    /// A zero-timeout `poll`, i.e. the question "is the peer keeping up" asked
    /// without paying to find out. #14 uses it to drop a bar *before* spending
    /// any of the bar's time on a write that cannot succeed, rather than after.
    pub fn writable(self: *Conn) bool {
        if (self.fd < 0) return false;
        var fds = [_]std.posix.pollfd{.{
            .fd = self.fd,
            .events = std.posix.POLL.OUT,
            .revents = 0,
        }};
        const n = std.posix.poll(&fds, 0) catch return false;
        return n > 0 and (fds[0].revents & std.posix.POLL.OUT) != 0;
    }
};

test "framing constants" {
    try std.testing.expectEqual(@as(u32, 16384), max_payload);
}
