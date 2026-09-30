//! Fuzz harness for the NINJAM protocol and buffer parsing path (#26).
//!
//! `proto.zig`/`buf.zig` are length-checked with `catch`, so the parsers alone
//! are the *less* likely crash site — the likelier one is a downstream consumer
//! doing arithmetic on wire-controlled values (an unchecked shift, a division by
//! a hostile `bpm`). This harness therefore fuzzes a **full dispatch step**: the
//! fuzz input is the raw server-side byte stream of a real session, driven
//! through
//!
//!     net.zig framing (readMessage) -> session.zig dispatch -> every handler
//!
//! exactly as bytes from a (hostile or broken) server would arrive. Any panic
//! — or any memory leak, via the test allocator — fails the test.
//!
//! **This file deliberately lives OUTSIDE `src/ninjam/`.** That directory is
//! vendored (see `vendor/README.md` and the file ledger in ISSUES.md); keeping
//! the harness here means the fuzzing work adds nothing to the vendoring debt
//! batched into #29.
//!
//! How it works: `Session.run()` is the only public door into `dispatch`, so
//! the harness listens on a loopback port, runs a real `Session` against it,
//! and a helper thread plays the server: it accepts, writes the fuzz input as
//! raw TCP bytes, half-closes (so the session sees EOF after draining), and
//! then drains until the client goes away. Every exec terminates fast — a
//! failed session ends on EOF/BadFrame, and `duration_ms` caps the live ones.
//!
//! Mode wiring:
//!  * `zig build test` runs the corpus below through the same path, plus a
//!    bounded seeded-random fuzzer — deterministic regression coverage on
//!    every CI run.
//!  * `zig build test --fuzz` would coverage-guide the same callback, but it
//!    is currently unusable for this test binary due to two zig 0.16.0
//!    upstream bugs (the Debug fuzz runner fails to compile, and a binary that
//!    links C misses the sanitizer-coverage runtime in ReleaseSafe). The
//!    harness keeps its `std.testing.fuzz` shape, so coverage-guided fuzzing
//!    lights up the moment a zig upgrade fixes those; until then the seeded
//!    random execs are the random-input signal in CI.
//!
//! The corpus used to deliberately avoid the two wire-triggered panics the
//! harness had found in the vendored dispatcher (`onUserinfo` shifting by
//! `channel_id >= 32`, and `onConfig` dividing by a hostile `bpm = 0`), with a
//! scrubber that masked both shapes out of every generated stream so
//! `zig build test` stayed green while they were filed.
//!
//! Both are fixed (#40, #41): the scrubber is gone and their minimal repros
//! are corpus entries 13 and 14. That is the point of the arrangement — the
//! random generator can rediscover those shapes on its own now, and the corpus
//! pins them whether or not it does.

const std = @import("std");
const builtin = @import("builtin");
const session = @import("ninjam/session.zig");
const proto = @import("ninjam/proto.zig");

// ---- fuzz target ------------------------------------------------------------

/// One Smith input == one server-side byte stream. 16 KiB matches the largest
/// single framed payload the wire allows (`net.zig` max_payload).
const max_stream_len = 16384;
/// Stable per-call-site id the fuzzer keys its inputs on.
const dispatch_hash = 0x26_f1_00;

test "fuzz the NINJAM dispatch: framing -> parse -> handlers on arbitrary server bytes" {
    // the corpus buffer lives in this frame: its entries are slices into it,
    // so it must outlive the std.testing.fuzz call below
    var c = CorpusBuf{};
    fillCorpus(&c);
    try std.testing.fuzz({}, fuzzDispatchStep, .{ .corpus = c.done() });
}

fn fuzzDispatchStep(_: void, smith: *std.testing.Smith) anyerror!void {
    var stream_buf: [max_stream_len]u8 = undefined;
    const n = smith.sliceWithHash(&stream_buf, dispatch_hash);
    try runDispatchStep(stream_buf[0..n]);
}

// ---- one dispatch step --------------------------------------------------------

/// Out_dir for the fuzz sessions. Relative on purpose: `Session.run` creates it
/// via `Dir.cwd()`, and `zig-cache/` is already gitignored. Decoded peer WAVs
/// would land here; random bytes never decode as Ogg, so in practice only the
/// directory itself is created.
const fuzz_out_dir = "zig-cache/fuzz-out";

fn runDispatchStep(stream: []const u8) !void {
    const alloc = std.testing.allocator;
    const io = harnessIo();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = Listener.init(try std.Io.net.IpAddress.listen(&addr, io, .{}), io);
    defer listener.close();

    const srv = try std.Thread.spawn(.{}, fakeServer, .{ &listener, stream });
    // Every exit from here joins the thread. Ordering matters: the session's
    // socket must close before the join, so the server's read sees EOF (or the
    // stop flag fires) and the thread can exit.
    var s = session.Session.init(alloc, io, fuzzOptions(listener.port())) catch |e| {
        listener.close(); // sets the stop flag; the accept loop gives up
        srv.join();
        return e;
    };
    defer {
        s.deinit(); // closes the session socket -> server read gets EOF -> exits
        srv.join();
    }
    s.log.quiet = true; // transcript off, stderr off: the fuzzer owns the console

    // Graceful protocol errors are the parsers doing their job (failSession +
    // non-zero stats) — not harness failures. Panics, OOB and leaks are.
    _ = s.run() catch {};
}

fn fuzzOptions(port: u16) session.Options {
    return .{
        .host = "127.0.0.1",
        .port = port,
        .user = "fuzzer",
        .pass = "fuzz",
        .srate = 48000,
        .channel_names = &.{"fuzz"},
        .source = .silence,
        .out_dir = fuzz_out_dir,
        .transcript_path = null,
        // caps the sessions that go live (challenge + success reply): they end
        // by deadline instead of EOF, so this bounds the worst-case exec
        .duration_ms = 60,
    };
}

/// `std.testing.io` is wired up by the test runner for normal test runs, but
/// the `--fuzz` runner (compiler/test_runner.zig, start_fuzzing) never touches
/// `testing.io_instance` — so the harness carries its own io in fuzz mode.
var fuzz_io: ?std.Io.Threaded = null;

fn harnessIo() std.Io {
    if (builtin.fuzz) {
        if (fuzz_io == null) fuzz_io = .init(std.heap.page_allocator, .{});
        return fuzz_io.?.io();
    }
    return std.testing.io;
}

// ---- the fake server ----------------------------------------------------------

/// The loopback listener, wrapped so it can be closed exactly once no matter
/// which exit path gets there first, and so the accept can be interrupted:
/// macOS does NOT wake a thread blocked in `accept` when the fd is closed, so
/// without the stop flag a session that never connects deadlocks the join.
const Listener = struct {
    server: std.Io.net.Server,
    io: std.Io,
    closed: bool = false,
    stop: std.atomic.Value(bool) = .init(false),

    fn init(server: std.Io.net.Server, io: std.Io) Listener {
        const l = Listener{ .server = server, .io = io };
        // non-blocking listener: accept() then polls the stop flag instead of
        // blocking forever (EAGAIN surfaces as error.WouldBlock). Note
        // std.c.O is a packed struct, and net.zig's own setNonblocking helper
        // hardcodes Linux's 0o4000 — a silent no-op on macOS — so set the
        // named bit through the struct instead.
        const fd = server.socket.handle;
        var o: std.c.O = @bitCast(@as(u32, @intCast(std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0)))));
        o.NONBLOCK = true;
        _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(o)));
        return l;
    }

    fn port(self: *const Listener) u16 {
        return self.server.socket.address.getPort();
    }

    fn close(self: *Listener) void {
        if (self.closed) return;
        self.closed = true;
        self.stop.store(true, .release);
        self.server.deinit(self.io);
    }
};

/// Plays the hostile server for one exec: accept, write the fuzz stream,
/// half-close so the session sees EOF after draining, then drain until the
/// client closes (its uploads must never block the session).
///
/// Raw posix (net.zig's own style) rather than `Io.Threaded`: Threaded asserts
/// accept-EAGAIN is a zig bug ("errnoBug"), so a non-blocking listener must
/// not accept through the io vtable. Everything here is poll-gated instead, so
/// the stop flag and the deadline can always interrupt it.
const accept_deadline_waits: u32 = 2000; // ~2 s of 1 ms polls; a live session connects in well under a millisecond

fn fakeServer(listener: *Listener, stream: []const u8) void {
    const lfd = listener.server.socket.handle;

    const cfd: std.posix.socket_t = cfd: {
        var waits: u32 = 0;
        while (true) {
            if (listener.stop.load(.acquire)) return;
            var fds = [_]std.posix.pollfd{.{ .fd = lfd, .events = std.posix.POLL.IN, .revents = 0 }};
            const n = std.posix.poll(&fds, 1) catch return;
            if (n == 0) {
                waits += 1;
                if (waits > accept_deadline_waits) return; // no client ever came; bounded, not hung
                continue;
            }
            const rc = std.posix.system.accept(lfd, null, null);
            switch (std.posix.errno(rc)) {
                .SUCCESS => break :cfd @intCast(rc),
                .INTR, .AGAIN => continue,
                else => return,
            }
        }
    };
    defer _ = std.posix.errno(std.posix.system.close(cfd));

    // Abort the connection on close (RST instead of FIN): the server sends the
    // first FIN, so a clean close would park this port in TIME_WAIT for ~15-30s
    // — a long fuzz run exhausts the ephemeral range and every later connect
    // fails (that is what the first deep-hunt hang actually was). An RST leaves
    // no TIME_WAIT state; the session has already hit EOF by then.
    const li = std.posix.linger{ .onoff = 1, .linger = 0 };
    std.posix.setsockopt(cfd, std.posix.SOL.SOCKET, std.posix.SO.LINGER, &std.mem.toBytes(li)) catch {};

    // Zig does not ignore SIGPIPE for us; a write against a session that hit
    // its duration cap mid-drain must not kill the test binary.
    if (builtin.os.tag == .macos) {
        std.posix.setsockopt(cfd, std.posix.SOL.SOCKET, std.posix.SO.NOSIGPIPE, &std.mem.toBytes(@as(c_int, 1))) catch {};
    }

    var off: usize = 0;
    while (off < stream.len) {
        const n = rawSend(cfd, stream[off..]) orelse return;
        if (n == 0) return;
        off += n;
    }
    // half-close: the session drains what we wrote, then reads EOF and fails
    // the session; we keep reading so its outbound bytes never block it
    _ = std.posix.errno(std.posix.system.shutdown(cfd, std.posix.SHUT.WR));

    var scratch: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(cfd, &scratch) catch return;
        if (n == 0) return;
    }
}

/// One write that cannot raise SIGPIPE (macOS via the socket option set above,
/// everything else via MSG_NOSIGNAL). Returns null on a dead connection.
fn rawSend(fd: std.posix.socket_t, bytes: []const u8) ?usize {
    const rc = switch (builtin.os.tag) {
        .macos => std.posix.system.write(fd, bytes.ptr, bytes.len),
        else => std.posix.system.send(fd, bytes.ptr, bytes.len, std.posix.MSG.NOSIGNAL),
    };
    switch (std.posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .INTR, .AGAIN => return 0,
        else => return null,
    }
}

// ---- seeded random execs (runs in every `zig build test`) ----------------------

/// Deterministic random execs through the same dispatch path. Zig 0.16.0's
/// `--fuzz` mode cannot link this test binary (two upstream bugs: the Debug
/// fuzz runner fails to compile, and C-linked binaries miss the
/// sanitizer-coverage runtime in ReleaseSafe — see the README), so the harness
/// carries its own bounded random fuzzer for CI. Bump `random_execs` /
/// `random_seed` to explore; a crash found here becomes a fixed corpus entry —
/// or a filed issue, if it turns out to live in vendored code.
const random_execs = 256;
const random_seed = 0x26_f1_00;

test "random server bytes through the dispatch (seeded, bounded)" {
    var prng = std.Random.DefaultPrng.init(random_seed);
    const rand = prng.random();
    var buf: [1024]u8 = undefined;
    for (0..random_execs) |_| {
        const len = rand.uintAtMost(usize, buf.len);
        rand.bytes(buf[0..len]);
        try runDispatchStep(buf[0..len]);
    }
}

// ---- corpus ---------------------------------------------------------------------

/// A server-side byte stream under construction.
const StreamBuf = struct {
    bytes: [1024]u8 = undefined,
    len: usize = 0,

    fn msg(self: *StreamBuf, mtype: u8, payload: []const u8) !void {
        if (self.len + 5 + payload.len > self.bytes.len) return error.Overflow;
        self.bytes[self.len] = mtype;
        std.mem.writeInt(u32, self.bytes[self.len + 1 ..][0..4], @intCast(payload.len), .little);
        @memcpy(self.bytes[self.len + 5 ..][0..payload.len], payload);
        self.len += 5 + payload.len;
    }

    fn stream(self: *const StreamBuf) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// The corpus: one entry per scenario, each a whole server-side byte stream.
/// Smith's slice protocol wants a u32 LE length prefix in front of the bytes.
/// Every entry here must be panic-free (see the module doc comment for the
/// known crashes these entries deliberately avoid).
fn fillCorpus(c: *CorpusBuf) void {
    // 1. the server connects and says nothing, then closes
    c.entry(&.{});

    // 2. a well-formed 0x00 challenge (keepalive caps = 3s, current version):
    //    the only message that moves the session forward; the client replies
    //
    //    KNOWN GAP (found while pinning #40/#41): the session reads the
    //    challenge, sends 0x80 AUTH_USER, and then never reaches 0x01 AUTH_OK
    //    — the handshake stalls, so entries 2, 3 and 4 below are silently
    //    no-ops and nothing in this corpus exercises the live-session paths
    //    (interval clock, config re-anchor, finalize). Their comments describe
    //    what they *intend* to cover. Entries that need no auth (5-14) do run,
    //    which is why the #40/#41 repros are written without one. Worth its
    //    own issue: until it is fixed, treat "goes live" as untested here.
    var ch = StreamBuf{};
    ch.msg(proto.MSG_AUTH_CHALLENGE, &challengePayload(0x00000300, proto.PROTO_VER_CUR)) catch unreachable;
    c.entry(ch.stream());

    // 3. challenge + success 0x01 reply: INTENDED to go live and run to the
    //    duration cap (no config yet, so the interval clock never starts) —
    //    but see the known gap above; this stops at the challenge today.
    var live = StreamBuf{};
    live.msg(proto.MSG_AUTH_CHALLENGE, &challengePayload(0x00000300, proto.PROTO_VER_CUR)) catch unreachable;
    live.msg(proto.MSG_AUTH_REPLY, &authReplyPayload(true, "fuzzer", 8)) catch unreachable;
    c.entry(live.stream());

    // 4. INTENDED to be live + a 0x02 config change: re-anchor, interval clock
    //    starts, silence encodes for the remainder of the cap. Blocked on the
    //    same handshake gap as entry 3.
    var clocked = StreamBuf{};
    clocked.msg(proto.MSG_AUTH_CHALLENGE, &challengePayload(0x00000300, proto.PROTO_VER_CUR)) catch unreachable;
    clocked.msg(proto.MSG_AUTH_REPLY, &authReplyPayload(true, "fuzzer", 8)) catch unreachable;
    clocked.msg(proto.MSG_CONFIG_CHANGE_NOTIFY, &configPayload(100, 8)) catch unreachable;
    c.entry(clocked.stream());

    // 5. 0x03 userinfo: find-or-add user + the auto-subscribe reply
    var users = StreamBuf{};
    var rec: [64]u8 = undefined;
    users.msg(proto.MSG_USERINFO_CHANGE_NOTIFY, userinfoRecord(&rec, true, 0, -100, 0, 0, "bob", "guitar")) catch unreachable;
    users.msg(proto.MSG_USERINFO_CHANGE_NOTIFY, userinfoRecord(&rec, true, 0, 0, 0, 0, "bob", "guitar")) catch unreachable;
    users.msg(proto.MSG_USERINFO_CHANGE_NOTIFY, userinfoRecord(&rec, false, 1, 0, 0, 0, "gone", "piano")) catch unreachable;
    c.entry(users.stream());

    // 6. 0xC0 chat: the five-slot parse + log
    var chat = StreamBuf{};
    chat.msg(proto.MSG_CHAT_MESSAGE, "MSG\x00alice\x00hello room\x00\x00\x00") catch unreachable;
    c.entry(chat.stream());

    // 7. 0x04/0x05 download: begin a transfer, stream a chunk, finalize with
    //    garbage bytes -> decode fails, session tolerates it
    var dl = StreamBuf{};
    dl.msg(proto.MSG_DOWNLOAD_INTERVAL_BEGIN, &intervalBeginPayload([_]u8{0xA1} ++ [_]u8{0} ** 15, proto.FOURCC_OGGV, 1, "carol")) catch unreachable;
    dl.msg(proto.MSG_DOWNLOAD_INTERVAL_WRITE, &intervalWritePayload([_]u8{0xA1} ++ [_]u8{0} ** 15, 0, "not really ogg")) catch unreachable;
    dl.msg(proto.MSG_DOWNLOAD_INTERVAL_WRITE, &intervalWritePayload([_]u8{0xA1} ++ [_]u8{0} ** 15, 1, "")) catch unreachable;
    c.entry(dl.stream());

    // 8. 0x04 silence marker: zero guid + fourcc 0
    var marker = StreamBuf{};
    marker.msg(proto.MSG_DOWNLOAD_INTERVAL_BEGIN, &intervalBeginPayload([_]u8{0} ** 16, 0, 0, "")) catch unreachable;
    c.entry(marker.stream());

    // 9. unknown types: must be ignored, not fatal
    var unk = StreamBuf{};
    unk.msg(0x77, "whatever") catch unreachable;
    unk.msg(0xFE, "") catch unreachable;
    c.entry(unk.stream());

    // 10. keepalive
    var ka = StreamBuf{};
    ka.msg(proto.MSG_KEEPALIVE, "") catch unreachable;
    c.entry(ka.stream());

    // 11. framing: declared size over the 16 KiB wire cap -> BadFrame, session
    //     fails fast
    var oversize = StreamBuf{};
    oversize.bytes[oversize.len] = proto.MSG_CHAT_MESSAGE;
    std.mem.writeInt(u32, oversize.bytes[oversize.len + 1 ..][0..4], 0x7FFF_FFFF, .little);
    oversize.len += 5;
    c.entry(oversize.stream());

    // 12. framing: the length promises more bytes than the stream ever sends
    //     -> EOF mid-frame, session fails fast
    var truncated = StreamBuf{};
    truncated.bytes[truncated.len] = proto.MSG_CHAT_MESSAGE;
    std.mem.writeInt(u32, truncated.bytes[truncated.len + 1 ..][0..4], 64, .little);
    truncated.len += 5;
    @memcpy(truncated.bytes[truncated.len..][0..4], "half");
    truncated.len += 4;
    c.entry(truncated.stream());

    // 13. #40's repro, now pinned: a userinfo record with channel_id = 200.
    //     Used to panic on `@as(u32, 1) << @intCast(rec.channel_id)`. It is a
    //     corpus entry rather than only an issue body so the regression stays
    //     fixed even though the bug lived in vendored code. Like entry 14 this
    //     needs no auth in front of it.
    var badchan = StreamBuf{};
    badchan.msg(proto.MSG_USERINFO_CHANGE_NOTIFY, userinfoRecord(&rec, true, 200, 0, 0, 0, "x", "y")) catch unreachable;
    c.entry(badchan.stream());

    // 14. #41's repro, now pinned: a 0x02 with bpm = 0 as the *first* message
    //     on the wire. Used to panic on @divTrunc(srate * bpi * 60, bpm).
    //     No auth handshake in front of it, which is both the real threat
    //     model (dispatch does not gate on session state, so the first thing a
    //     hostile server sends can be this) and the only shape that works
    //     today: see the note on entry 15.
    var zerobpm = StreamBuf{};
    zerobpm.msg(proto.MSG_CONFIG_CHANGE_NOTIFY, &configPayload(0, 8)) catch unreachable;
    c.entry(zerobpm.stream());
}

const CorpusBuf = struct {
    const max_entries = 16;

    data: [8192]u8 = undefined,
    used: usize = 0,
    entries: [max_entries][]const u8 = undefined,
    n: usize = 0,

    /// Register one entry: u32 LE length prefix + stream bytes.
    fn entry(self: *CorpusBuf, stream: []const u8) void {
        const total = 4 + stream.len;
        if (self.n == self.entries.len or self.used + total > self.data.len)
            @panic("fuzz corpus overflow: raise CorpusBuf sizes");
        std.mem.writeInt(u32, self.data[self.used..][0..4], @intCast(stream.len), .little);
        @memcpy(self.data[self.used + 4 ..][0..stream.len], stream);
        self.entries[self.n] = self.data[self.used..][0..total];
        self.used += total;
        self.n += 1;
    }

    fn done(self: *CorpusBuf) []const []const u8 {
        return self.entries[0..self.n];
    }
};

// ---- payload builders -------------------------------------------------------------
// Hand-rolled LE appends (not buf.zig's Fixed) so the corpus cannot share a bug
// with the code under test.

fn challengePayload(server_caps: u32, protocol_version: u32) [16]u8 {
    var out: [16]u8 = undefined;
    @memcpy(out[0..8], "\x01\x23\x45\x67\x89\xAB\xCD\xEF");
    std.mem.writeInt(u32, out[8..12], server_caps, .little);
    std.mem.writeInt(u32, out[12..16], protocol_version, .little);
    return out;
}

/// `ok=false` makes `text` the error message, `ok=true` the effective username.
fn authReplyPayload(ok: bool, text: []const u8, maxchan: u8) [64]u8 {
    var out = std.mem.zeroes([64]u8);
    out[0] = if (ok) 1 else 0;
    const used = 1 + appendNulstr(out[1..], text);
    out[used] = maxchan;
    return out;
}

fn configPayload(bpm: u16, bpi: u16) [4]u8 {
    var out: [4]u8 = undefined;
    std.mem.writeInt(u16, out[0..2], bpm, .little);
    std.mem.writeInt(u16, out[2..4], bpi, .little);
    return out;
}

/// active | channel_id | volume (i16le) | pan (i8) | flags | username NUL | channel NUL
///
/// Sized to content (returns the used prefix of `buf`) because the userinfo
/// parser LOOPS over its payload: trailing zeros would parse as more records
/// and eventually truncate the parse, which changes which handler paths run.
///
/// `channel_id` may be any byte: `onUserinfo` rejects >= 32 itself (#40), and
/// entry 13 above pins that.
fn userinfoRecord(
    buf: []u8,
    active: bool,
    channel_id: u8,
    volume: i16,
    pan: i8,
    flags: u8,
    username: []const u8,
    channel_name: []const u8,
) []const u8 {
    std.debug.assert(buf.len >= 8 + username.len + channel_name.len);
    buf[0] = if (active) 1 else 0;
    buf[1] = channel_id;
    std.mem.writeInt(i16, buf[2..4], volume, .little);
    buf[4] = @bitCast(pan);
    buf[5] = flags;
    var used = 6 + appendNulstr(buf[6..], username);
    used += appendNulstr(buf[used..], channel_name);
    return buf[0..used];
}

/// guid | estsize (u32le) | fourcc (u32le) | chidx | username NUL
fn intervalBeginPayload(guid: [16]u8, fourcc: u32, chidx: u8, username: []const u8) [64]u8 {
    var out = std.mem.zeroes([64]u8);
    @memcpy(out[0..16], &guid);
    std.mem.writeInt(u32, out[16..20], 0, .little); // estsize
    std.mem.writeInt(u32, out[20..24], fourcc, .little);
    out[24] = chidx;
    _ = appendNulstr(out[25..], username);
    return out;
}

/// guid | flags | data
fn intervalWritePayload(guid: [16]u8, flags: u8, data: []const u8) [256]u8 {
    var out = std.mem.zeroes([256]u8);
    @memcpy(out[0..16], &guid);
    out[16] = flags;
    @memcpy(out[17..][0..data.len], data);
    return out;
}

fn appendNulstr(dst: []u8, src: []const u8) usize {
    const n = @min(src.len, dst.len - 1);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
    return n + 1;
}

// ---- corpus sanity ---------------------------------------------------------------

test "corpus entries are well-formed framed streams" {
    // not the fuzz path — just pin the corpus itself, so a corpus typo can
    // never mask a real regression by silently skipping a scenario. Normal
    // entries must walk cleanly as frames; the two framing-violation entries
    // (oversize, truncated) must violate *exactly once and at the start*,
    // which is the whole scenario they encode.
    var c = CorpusBuf{};
    fillCorpus(&c);
    for (c.done()) |entry| {
        try std.testing.expect(entry.len >= 4);
        const stream_len = std.mem.readInt(u32, entry[0..4], .little);
        const stream = entry[4..];
        try std.testing.expectEqual(stream.len, stream_len);

        var pos: usize = 0;
        var frames: usize = 0;
        var violated = false;
        while (pos < stream.len) {
            if (stream.len - pos < 5) {
                violated = true; // truncated header
                break;
            }
            const size = std.mem.readInt(u32, stream[pos + 1 ..][0..4], .little);
            if (size > 16384 or stream.len - pos - 5 < size) {
                // the BadFrame / EOF-mid-frame scenario: it must be the whole
                // point of the entry, not corruption before or after
                violated = true;
                try std.testing.expectEqual(@as(usize, 0), frames);
                try std.testing.expectEqual(stream.len, pos + 5 + @min(size, stream.len - pos - 5));
                break;
            }
            pos += 5 + size;
            frames += 1;
        }
        // the empty entry (server says nothing) has zero frames, and the
        // framing-violation entries end before their first frame completes —
        // everything else must carry at least one whole frame
        if (stream.len > 0 and !violated) try std.testing.expect(frames >= 1);
    }
}

// ---- findings ---------------------------------------------------------------------
// What fuzzing this dispatch path has found so far. Both live in VENDORED code
// (src/ninjam/), which the file ledger in ISSUES.md says #26 must not edit, so
// #26 filed them rather than fixing them in place:
//
// 1. onUserinfo: `@as(u32, 1) << @intCast(rec.channel_id)` — the channel id is a
//    raw wire byte; >= 32 truncates the cast to the u5 shift amount and panics.
//    FILED: #40. FIXED: the record is now skipped with a log line, because a
//    channel outside 0..31 cannot name a bit in a u32 mask. Pinned as entry 13.
// 2. onConfig: a 0x02 with bpm = 0 (and anything else changed) reaches
//    `@divTrunc(srate * bpi * 60, bpm)` -> division by zero panic. FILED: #41.
//    FIXED: bpm and bpi are both validated as non-zero *before* the session's
//    own copy is written, so a refused config leaves no poisoned state. bpi = 0
//    never panicked but made every interval zero-length, which turns the run
//    loop's `produced >= interval_len` into a per-pass finalize — a flood of
//    empty uploads — so it is refused too. Pinned as entry 14.
//
// The scrubber that used to mask both shapes out of the random stream is gone.
// New findings here should be filed the same way, and their repros moved into
// fillCorpus once fixed so the regression is pinned rather than remembered.
