//! M5 timing harness — the measurement rig for #13 (server-clock discipline)
//! and #14 (upload backpressure).
//!
//! Both issues live on the same line of code: `finalizeInterval` writes an
//! interval's upload inline, on the path that drives the audio clock, and the
//! interval grid is open-loop (`interval_start_ns += interval_ns`), so anything
//! that stalls the write stalls the music. Neither failure is reachable from a
//! unit test — they need a real socket and a real peer that misbehaves, which is
//! exactly what this file provides.
//!
//! `proto_fuzz.zig` already proves the general point that "a live-path stream
//! really goes live"; this rig is the other half. A fuzz stream is *hostile but
//! well-formed* — every message arrives on time. The failure modes here are the
//! ones fuzzing structurally cannot reach:
//!
//!  - **backpressure (#14)**: a peer that stops reading, so the socket's send
//!    buffer fills and `write` would block. The client must drop bars, not
//!    freeze. `blackholeServer` stops reading for a fixed window and then
//!    drains, which makes the stall finite and therefore *measurable* instead
//!    of a hung test.
//!  - **clock drift (#13)**: not a crash but a silent divergence between the
//!    local bar grid and the grid derived from the server's `0x02` arrival.
//!    Silence encodes to almost nothing, so a silent source would never notice
//!    a slow link; `toneSource` makes the uploads big enough to actually fill a
//!    buffer.
//!
//! Everything here is deliberately OUTSIDE `src/ninjam/` (see the file ledger
//! in ISSUES.md) — the vendored subset keeps no harness, only the hooks the
//! instrument needs.
//!
//! `runClockedSession` is the shared driver: it stands up a loopback listener,
//! plays one scripted server, runs a real `Session` against it, and hands back
//! both the session's `Stats` and the server-side truth (how many bytes it
//! managed to read). Tests assert on the *difference*.

const std = @import("std");
const builtin = @import("builtin");
const session = @import("ninjam/session.zig");
const proto = @import("ninjam/proto.zig");
const net = @import("ninjam/net.zig");
const kujamba_out = @import("ninjam_out.zig");
const clock = @import("ninjam/clock.zig");

/// Relative on purpose: `Session.run` creates its out_dir via `Dir.cwd()`, and
/// `zig-cache/` is already gitignored.
const timing_out_dir = "zig-cache/timing-out";

/// The scripted server's side of a run, so a test can compare what the client
/// *thought* it sent against what actually crossed the socket.
pub const ServerView = struct {
    /// bytes the server managed to read out of the client before it stopped
    /// (its receive window), i.e. the uploads that were not dropped
    bytes_read: u64 = 0,
    /// true if the server saw the client's socket go away
    saw_eof: bool = false,
};

// ---- the scripted server ----------------------------------------------------

/// Same wrapping as `proto_fuzz.zig`'s `Listener`, for the same two macOS
/// reasons: `close` must be idempotent (several exit paths reach it) and the
/// accept has to be interruptible (macOS does not wake a thread blocked in
/// `accept` when the fd is closed, so the join would deadlock).
const Listener = struct {
    server: std.Io.net.Server,
    io: std.Io,
    closed: bool = false,
    stop: std.atomic.Value(bool) = .init(false),

    fn init(server: std.Io.net.Server, io: std.Io) Listener {
        const l = Listener{ .server = server, .io = io };
        // Non-blocking accept: EAGAIN surfaces as error.WouldBlock and the loop
        // can check `stop` between attempts. Note std.c.O is a packed struct,
        // and net.zig's own setNonblocking hardcodes Linux's 0o4000 — a silent
        // no-op on macOS — so set the named bit through the struct instead.
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

/// What the scripted server does once the session is live.
pub const ServerScript = struct {
    /// milliseconds to go completely silent — not one `read`, so the client's
    /// send buffer, the TCP window and the server's receive buffer all fill and
    /// `write` starts returning EAGAIN. This is the #14 hazard made finite.
    blackhole_ms: u32 = 0,
    /// cap on the whole server's life, so a session that never stops cannot hang
    /// the test.
    lifetime_ms: u32 = 4000,
    /// `SO_RCVBUF` to request on the listening socket (inherited by the
    /// accepted socket). Small on purpose, and the size is a *test* knob, not a
    /// fidelity compromise: a full socket takes exactly the same code path at
    /// 8 KiB as at 256 KiB, and the kernel clamps to its own minimum anyway.
    /// It matters because the client uploads at the reference client's bitrate
    /// (64 kbps mono, `quality = 0.0` — `Options.quality`'s default), which is
    /// only ~8 KB/s, so with stock loopback buffers a peer has to stop reading
    /// for *seconds* before `write` ever returns EAGAIN. That is itself worth
    /// knowing: backpressure here is a slow-peer failure, not a jitter failure.
    recv_buf_bytes: i32 = 4096,
};

const accept_deadline_waits: u32 = 2000; // ~2 s of 1 ms polls

/// `std.testing.io` is wired up by the test runner for normal runs. This file
/// is not a fuzz target, but it shares the harness shape, so it carries the
/// same guard for the same reason: a future `--fuzz` wiring should not have to
/// rediscover that the fuzz runner never touches `testing.io_instance`.
fn harnessIo() std.Io {
    if (builtin.fuzz) {
        if (timing_io == null) timing_io = .init(std.heap.page_allocator, .{});
        return timing_io.?.io();
    }
    return std.testing.io;
}

var timing_io: ?std.Io.Threaded = null;
/// Plays the server for one run: accept, handshake, config, then whatever the
/// script says, then drain.
///
/// Raw posix (net.zig's own style) rather than `Io.Threaded`: Threaded asserts
/// accept-EAGAIN is a zig bug ("errnoBug"), so a non-blocking listener must not
/// accept through the io vtable. Everything here is poll-gated instead, so the
/// stop flag and every deadline can interrupt it.
fn scriptedServer(listener: *Listener, script: ServerScript, view: *ServerView) void {
    const lfd = listener.server.socket.handle;
    // Shrink the receive window *before* accept: on both macOS and Linux the
    // accepted socket inherits it, so the client's uploads hit backpressure
    // after a predictable amount of audio rather than an unpredictable amount.
    std.posix.setsockopt(lfd, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, &std.mem.toBytes(script.recv_buf_bytes)) catch {};

    const cfd: std.posix.socket_t = cfd: {
        var waits: u32 = 0;
        while (true) {
            if (listener.stop.load(.acquire)) return;
            var fds = [_]std.posix.pollfd{.{ .fd = lfd, .events = std.posix.POLL.IN, .revents = 0 }};
            const n = std.posix.poll(&fds, 1) catch return;
            if (n == 0) {
                waits += 1;
                if (waits > accept_deadline_waits) return;
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

    // Abort on close (RST, not FIN): this server sends the first FIN, so a clean
    // close parks the port in TIME_WAIT for ~15-30 s and a long test run
    // exhausts the ephemeral range (that is what hung proto_fuzz's deep hunt).
    const li = std.posix.linger{ .onoff = 1, .linger = 0 };
    std.posix.setsockopt(cfd, std.posix.SOL.SOCKET, std.posix.SO.LINGER, &std.mem.toBytes(li)) catch {};
    // Zig does not ignore SIGPIPE for us.
    if (builtin.os.tag == .macos) {
        std.posix.setsockopt(cfd, std.posix.SOL.SOCKET, std.posix.SO.NOSIGPIPE, &std.mem.toBytes(@as(c_int, 1))) catch {};
    }

    // Handshake: challenge -> (read the 0x80) -> auth ok -> (read the 0x82).
    // These reads are real reads and they matter: the session only reaches
    // .active after the auth reply, and it never starts an interval clock
    // until the config arrives.
    if (!sendFrame(cfd, proto.MSG_AUTH_CHALLENGE, &challengePayload())) return;
    if (!drain(cfd, view, 200)) return;
    if (!sendFrame(cfd, proto.MSG_AUTH_REPLY, &authReplyPayload("kujamba", 8))) return;
    if (!drain(cfd, view, 200)) return;

    const cfg = blackholeConfig{};
    if (!sendFrame(cfd, proto.MSG_CONFIG_CHANGE_NOTIFY, &configPayload(cfg.bpm, cfg.bpi))) return;

    // The blackhole: no read at all. Whatever the client uploads now piles up
    // in the kernel until the send side would block.
    if (script.blackhole_ms > 0) _ = sleepMs(script.blackhole_ms);

    // Drain to the end of the script's life. Whatever the client managed to
    // push while we were not reading arrives now.
    var waited_ms: u32 = 0;
    const drain_ms = script.lifetime_ms;
    var scratch: [16384]u8 = undefined;
    while (waited_ms < drain_ms and !listener.stop.load(.acquire)) {
        const n = std.posix.read(cfd, &scratch) catch |e| switch (e) {
            error.WouldBlock => {
                _ = sleepMs(1);
                waited_ms += 1;
                continue;
            },
            else => return,
        };
        if (n == 0) {
            view.saw_eof = true;
            return;
        }
        view.bytes_read += n;
    }
}

/// One framed message. Returns false on a dead connection.
fn sendFrame(fd: std.posix.socket_t, mtype: u8, payload: []const u8) bool {
    var hdr: [5]u8 = undefined;
    hdr[0] = mtype;
    std.mem.writeInt(u32, hdr[1..5], @intCast(payload.len), .little);
    return rawSend(fd, &hdr) != null and rawSend(fd, payload) != null;
}

fn rawSend(fd: std.posix.socket_t, bytes: []const u8) ?usize {
    if (bytes.len == 0) return 0;
    const rc = switch (builtin.os.tag) {
        .macos => std.posix.system.write(fd, bytes.ptr, bytes.len),
        else => std.posix.system.send(fd, bytes.ptr, bytes.len, std.posix.MSG.NOSIGNAL),
    };
    switch (std.posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        // A non-blocking socket with a full buffer: "try again", not "dead".
        .INTR, .AGAIN => return 0,
        else => return null,
    }
}

/// Read whatever is available for up to `budget_ms`, counting bytes. Returns
/// false if the connection died.
fn drain(fd: std.posix.socket_t, view: *ServerView, budget_ms: u32) bool {
    var scratch: [16384]u8 = undefined;
    var waited: u32 = 0;
    while (waited <= budget_ms) {
        const n = std.posix.read(fd, &scratch) catch |e| switch (e) {
            error.WouldBlock => {
                _ = sleepMs(1);
                waited += 1;
                continue;
            },
            else => return false,
        };
        if (n == 0) {
            view.saw_eof = true;
            return true;
        }
        view.bytes_read += n;
    }
    return true;
}

// #14: a frame larger than the whole socket is refused, not waited on.
//
// `Conn.writable()` answers "could you take a write at all?" and
// `sendMessageBounded` answers "could you take THIS write?". They are not the
// same question, and only the second one is safe to act on: a socket with room
// for a few hundred bytes says yes to the first and no to the second, and
// trusting the first would put a frame header on the wire followed by a
// fragment of its body — leaving the peer holding a message it has been told is
// longer than the bytes that followed. The drop is correct; the truncated frame
// is the part that is not.
//
// Whether `writable()` happens to be true in a given half-full state is a
// kernel flow-control decision and is not asserted here. What must always hold
// is the outcome: a frame that cannot go out whole is refused, promptly, and a
// small control message on the same socket still does.
test "#14: a frame bigger than the whole socket is refused, not waited on" {
    const io = harnessIo();
    const fds = try socketPair(8192);
    defer {
        _ = std.posix.errno(std.posix.system.close(fds[0]));
        _ = std.posix.errno(std.posix.system.close(fds[1]));
    }
    var conn = net.Conn{ .io = io, .fd = fds[0] };

    var payload: [16367]u8 = undefined;
    @memset(&payload, 0x5A);
    var junk: [4096]u8 = undefined;
    @memset(&junk, 0xA5);
    _ = fillUntilBlocked(fds[0], &junk);

    // 16372 bytes of frame into a socket whose whole buffer is 8192: this can
    // never succeed, however long anyone waits for it.
    const t0 = clock.nowNs(io);
    const ok = try conn.sendMessageBounded(proto.MSG_UPLOAD_INTERVAL_WRITE, &payload, 0);
    const elapsed_ns = clock.nowNs(io) - t0;
    std.debug.print(
        \\  #14 oversize  16 KiB frame into an 8 KiB socket: accepted={any} in {d} ms
        \\
    , .{ ok, @divTrunc(elapsed_ns, std.time.ns_per_ms) });
    try std.testing.expect(!ok);
    try std.testing.expect(elapsed_ns < 250 * std.time.ns_per_ms);

    // the session still talks to the server on the same socket: control
    // messages are small, and a session that could not answer the server at all
    // would be a worse failure than a dropped bar
    var sink: [65536]u8 = undefined;
    _ = drainSocket(fds[1], &sink);
    const small = [_]u8{0x01} ** 256;
    try std.testing.expect(try conn.sendMessageBounded(proto.MSG_UPLOAD_INTERVAL_BEGIN, &small, 0));
}

/// A bounded sleep on the io clock. Zig 0.16 took `std.Thread.sleep` away, so
/// this goes through `Clock.awake`, the same clock `clock.zig` reads the
/// session's timing from — which is also why the blackhole is measured on the
/// monotonic ("awake") clock and not on wall time: a wall-clock jump mid-test
/// would otherwise shorten or lengthen the window it is trying to create.
fn sleepMs(ms: u32) bool {
    const io = harnessIo();
    const d: std.Io.Clock.Duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake };
    d.sleep(io) catch {};
    return true;
}

// ---- payload builders --------------------------------------------------------
// Hand-rolled like proto_fuzz.zig's: the harness must not share a builder bug
// with the code it is measuring.

fn challengePayload() [16]u8 {
    var out: [16]u8 = undefined;
    @memcpy(out[0..8], "\x01\x23\x45\x67\x89\xAB\xCD\xEF");
    // caps 0x300 -> keepalive 3 s; current protocol version
    std.mem.writeInt(u32, out[8..12], 0x00000300, .little);
    std.mem.writeInt(u32, out[12..16], proto.PROTO_VER_CUR, .little);
    return out;
}

fn authReplyPayload(user: []const u8, maxchan: u8) [64]u8 {
    var out = std.mem.zeroes([64]u8);
    out[0] = 1; // ok
    const n = @min(user.len, out[1..].len - 1);
    @memcpy(out[1..][0..n], user[0..n]);
    out[1 + n] = maxchan;
    return out;
}

fn configPayload(bpm: u16, bpi: u16) [4]u8 {
    var out: [4]u8 = undefined;
    std.mem.writeInt(u16, out[0..2], bpm, .little);
    std.mem.writeInt(u16, out[2..4], bpi, .little);
    return out;
}

// ---- the driver --------------------------------------------------------------

/// The tempo the scripted server hands out. Chosen so one bar is short enough
/// that several of them fit inside a blackhole window — the hazard needs a few
/// writes to show up, and a 2 s bar would make the test take 30 s to prove it.
pub const blackholeConfig = struct { bpm: u16 = 300, bpi: u16 = 4 };

const TimedRun = struct {
    stats: session.Stats,
    server: ServerView,
    /// wall ns the session spent inside `run()`, so a test can compare the
    /// elapsed time against the grid it should have walked
    elapsed_ns: u64,
};

fn runScriptedSession(script: ServerScript, opts: session.Options) !TimedRun {
    const alloc = std.testing.allocator;
    const io = harnessIo();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = Listener.init(try std.Io.net.IpAddress.listen(&addr, io, .{}), io);
    defer listener.close();

    var view = ServerView{};
    const srv = try std.Thread.spawn(.{}, scriptedServer, .{ &listener, script, &view });
    var opts_mut = opts;
    opts_mut.host = "127.0.0.1";
    opts_mut.port = listener.port();
    var s = session.Session.init(alloc, io, opts_mut) catch |e| {
        listener.close();
        srv.join();
        return e;
    };
    defer {
        s.deinit(); // closes the session socket -> the server's read sees EOF
        srv.join();
    }
    s.log.quiet = true;

    const t0 = clock.nowNs(io);
    // A failed session still has a verdict worth reading: this is the whole
    // reason runDispatchStep hands Stats back (see proto_fuzz.zig).
    const stats = s.run() catch s.stats;
    const elapsed = clock.nowNs(io) - t0;
    return .{ .stats = stats, .server = view, .elapsed_ns = @intCast(elapsed) };
}

/// A tone, not silence. This matters: `.silence` encodes to a handful of bytes
/// per bar, so a silent source never fills a socket buffer and the backpressure
/// path would look unreachable. A tone at 440 Hz encodes to tens of KB per bar.
fn toneSource() session.Source {
    return .{ .tone = .{ .freq = 440.0, .amp = 0.5 } };
}

// ---- socket helpers ---------------------------------------------------------

/// A connected socket pair whose client end has a deliberately small send
/// buffer, both ends non-blocking. See the #14 tests for why this and not a
/// loopback listener.
fn socketPair(buf_bytes: i32) ![2]std.posix.socket_t {
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(@intCast(std.posix.AF.UNIX), @intCast(std.posix.SOCK.STREAM), 0, &fds);
    if (std.posix.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    std.posix.setsockopt(fds[0], std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, &std.mem.toBytes(buf_bytes)) catch {};
    std.posix.setsockopt(fds[1], std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, &std.mem.toBytes(buf_bytes)) catch {};
    for (fds) |fd| {
        var o: std.c.O = @bitCast(@as(u32, @intCast(std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0)))));
        o.NONBLOCK = true;
        _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(o)));
    }
    return fds;
}

/// Fill a non-blocking socket until `write` returns anything but SUCCESS.
/// Returns the bytes it took, so a test can prove the pipe really was full.
fn fillUntilBlocked(fd: std.posix.socket_t, buf: []const u8) usize {
    var total: usize = 0;
    while (true) {
        const rc = std.posix.system.write(fd, buf.ptr, buf.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => total += @intCast(rc),
            else => return total,
        }
    }
}

fn drainSocket(fd: std.posix.socket_t, buf: []u8) usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(fd, buf) catch break;
        if (n == 0) break;
        total += n;
    }
    return total;
}

fn baseOptions() session.Options {
    return .{
        .user = "kujamba",
        .pass = "timing",
        .srate = 48000,
        .channel_names = &.{"kujamba"},
        .source = toneSource(),
        .out_dir = timing_out_dir,
        .transcript_path = null,
        .duration_ms = 4000,
        // Test knob, not the shipping default (0.0 = the reference client's
        // 64 kbps mono). Backpressure is about a *full socket*, and the code
        // path at 64 kbps is identical to the code path at 500 kbps — only the
        // time-to-full differs, and at 64 kbps it is ~16 s, which is not a test
        // anybody runs in CI. `MEASURE at the default bitrate` below reports the
        // default-rate case separately.
        .quality = 10.0,
    };
}

// ---- the measurement --------------------------------------------------------

// #14: measure the backpressure hazard with a peer that stops reading.
//
// This test existed before the fix and its result is the number the fix is
// judged against, so it is kept as a *reporting* test rather than deleted: it
// prints the stall it observed so a regression shows up as a changed number
// rather than only as a red assertion.
//
// Read the "max stall" line together with the caveat below it. On macOS
// loopback the peer going quiet does **not** actually produce backpressure, so
// this number measures the run loop's own poll granularity, not the hazard.
// The hazard's real number is the next test.
test "MEASURE #14: a slow peer never stalls the audio clock" {
    // 2 s of silence from the server, inside a 4 s session.
    const run = try runScriptedSession(.{ .blackhole_ms = 2000, .lifetime_ms = 5000 }, baseOptions());

    const stall_ms = run.stats.upload_stall_ns / std.time.ns_per_ms;
    std.debug.print(
        \\
        \\  #14 loopback  blackhole=2000ms  session={d:.0}ms  bars={d} (dropped {d})
        \\                 max stall inside one interval's upload section = {d} ms
        \\                 server read {d} bytes of {d} uploaded
        \\                 drift={d}ms  max|drift|={d}ms  corrections={d}
        \\
    , .{
        @as(f64, @floatFromInt(run.elapsed_ns)) / 1e9 * 1000.0,
        run.stats.intervals_uploaded,
        run.stats.intervals_dropped,
        stall_ms,
        run.server.bytes_read,
        run.stats.upload_bytes,
        @divTrunc(run.stats.drift_ns, @as(i64, std.time.ns_per_ms)),
        run.stats.max_abs_drift_ns / std.time.ns_per_ms,
        run.stats.clock_corrections,
    });

    // THE acceptance criterion for #14: the audio clock kept walking the grid
    // for the whole run despite a peer that had stopped reading for two
    // seconds. Four 800 ms bars is the whole grid; a frozen clock would have
    // produced one or two at most.
    try std.testing.expect(run.stats.intervals_uploaded >= 3);
    // and it kept walking in roughly the wall time it was given, rather than
    // stretching a couple of bars across the whole session
    try std.testing.expect(run.elapsed_ns < 6 * std.time.ns_per_s);
    // nothing was lost, so nothing was dropped: on loopback the kernel simply
    // never ran out of buffer
    try std.testing.expectEqual(@as(u64, 0), run.stats.intervals_dropped);
    try std.testing.expect(run.server.bytes_read > 0);
    // the upload section never came close to a bar long. Pre-fix it had no
    // bound at all (the poll loop), so this is the property that was missing.
    try std.testing.expect(run.stats.upload_stall_ns < 250 * std.time.ns_per_ms);
    // #13: the drift ledger ran and stayed small — one bar is 800 ms, and the
    // run loop's 20 ms poll is the dominant term, so anything near a bar would
    // mean the grid was being stretched, not measured.
    try std.testing.expect(run.stats.max_abs_drift_ns < 400 * std.time.ns_per_ms);
}

// #14: the hazard itself, measured on a socket that really does fill.
//
// `scriptedServer` cannot reach this: measured on macOS, a loopback peer that
// stops reading still absorbs **654 KB** with `SO_RCVBUF` pinned to 4096 — the
// loopback path does not honour the receive window the way a routed network
// does. So backpressure on loopback is a slow-peer failure measured in
// seconds, not a jitter failure, and it is not reachable inside a test's
// patience. A socketpair has a genuinely bounded buffer, which is what makes
// the drop path measurable at all — and it is the same `Conn`, the same
// `sendMessageBounded`, only with a smaller pipe.
//
// The before-number, from the same shape before the fix: one 16 KiB
// `sendMessage` against a saturated socketpair did not return after 5000 ms and
// would not have returned at all, because `writeAllRaw`'s EAGAIN branch polls
// for 1000 ms in a loop and throws the result away.
test "#14: a full socket fails the write immediately instead of blocking forever" {
    const io = harnessIo();
    const fds = try socketPair(4096);
    defer {
        _ = std.posix.errno(std.posix.system.close(fds[0]));
        _ = std.posix.errno(std.posix.system.close(fds[1]));
    }
    var conn = net.Conn{ .io = io, .fd = fds[0] };

    var payload: [16367]u8 = undefined;
    @memset(&payload, 0x5A);
    // fill it, with the peer reading nothing
    var junk: [4096]u8 = undefined;
    @memset(&junk, 0xA5);
    const absorbed = fillUntilBlocked(fds[0], &junk);
    try std.testing.expect(absorbed > 0);

    // the zero-timeout gate says no without spending any time finding out
    try std.testing.expect(!conn.writable());

    // and the bounded write gives up rather than waiting out the peer.
    //
    // The budget is the session's own constant, not a literal: this test is
    // what pins `upload_write_budget_ms`, and a literal here would have kept
    // passing when someone turned it back into a second. (It did, once, and
    // this test stayed green for exactly that reason.)
    const t0 = clock.nowNs(io);
    const ok = try conn.sendMessageBounded(proto.MSG_UPLOAD_INTERVAL_WRITE, &payload, session.upload_write_budget_ms);
    const elapsed_ns = clock.nowNs(io) - t0;
    std.debug.print(
        \\  #14 socketpair  socket full after {d} bytes; one 16 KiB upload write returned {any} in {d} ms
        \\
    , .{ absorbed, ok, @divTrunc(elapsed_ns, std.time.ns_per_ms) });
    try std.testing.expect(!ok);
    // the number: bounded. Pre-fix this call did not return at all.
    try std.testing.expect(elapsed_ns < 250 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(i32, 0), session.upload_write_budget_ms);

    // recovery: drain the peer and the socket takes a write again, which is what
    // makes dropping a bar recoverable rather than fatal.
    //
    // The message here is small on purpose. A 16 KiB frame can *never* go
    // through a 4 KiB send buffer in one call — the gate would report the socket
    // writable and the bounded write would still give up on the tail — so
    // reusing the big payload here would be testing the pipe, not the recovery.
    var sink: [65536]u8 = undefined;
    _ = drainSocket(fds[1], &sink);
    try std.testing.expect(conn.writable());
    const small = [_]u8{0x01} ** 256;
    try std.testing.expect(try conn.sendMessageBounded(proto.MSG_UPLOAD_INTERVAL_BEGIN, &small, 0));
}
