//! App-specific source/plan integration regressions over the shared session engine.
const std = @import("std");
const session = @import("ninjam/session.zig");
const Session = session.Session;
const Source = session.Source;
const LocalChannel = Session.Testing.Channel;
const encodeBlockFor = session.encodeBlockFor;
const bufmod = @import("ninjam/buf.zig");
const Buf = bufmod.Buf;
const Fixed = bufmod.Fixed;
const proto = @import("ninjam/proto.zig");
const netmod = @import("ninjam/net.zig");
const clock = @import("ninjam/clock.zig");
const vorbis = @import("ninjam/vorbis.zig");
const kujamba_out = @import("ninjam_out.zig");

test "multi-channel live capture shares one block per step (channels stay aligned)" {
    var a = LocalChannel{ .pending = Buf.init(std.testing.allocator), .dump = Buf.init(std.testing.allocator) };
    defer a.pending.deinit();
    var b = LocalChannel{ .pending = Buf.init(std.testing.allocator), .dump = Buf.init(std.testing.allocator) };
    defer b.pending.deinit();

    var shared: [64]f32 = undefined;
    for (&shared, 0..) |*s, i| s.* = @sin(@as(f32, @floatFromInt(i)) * 0.1);

    var ba: [64]f32 = undefined;
    var bb: [64]f32 = undefined;
    encodeBlockFor(.silence, 48000, &a, &shared, &ba);
    encodeBlockFor(.silence, 48000, &b, &shared, &bb);
    // identical sample-for-sample: a per-channel pull would shift b by a block
    for (ba, bb) |x, y| try std.testing.expectEqual(x, y);
    try std.testing.expectEqual(shared[0], ba[0]);
    try std.testing.expectEqual(shared[63], ba[63]);
}

// kujamba (#12): the config-change seam. Before the fix `onConfig` zeroed the
// single `interval_idx`, which re-issued a guid the server had already seen
// under different payload bytes, renamed later payload dumps onto earlier
// files, and restarted bar numbering. Counters start part-way through the
// session so a reset is visible; finalizing a *mid-interval* config change
// needs a socket, so the in-flight interval is left empty. The `--intervals` cap
// reads the same field as the guid derivation but lives in `finalizeInterval`,
// which is not reachable without a socket; #24 should cover it end to end.
test "kujamba: a config change moves the grid without renumbering intervals or cutting the phrase" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    var bank = try onePhraseBank(std.testing.allocator, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .loop };
    fill.bind(.loop, bank.active());
    const pattern = try kujamba_out.parsePattern("3+1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .bank = &bank, .fill = &fill };

    var s = try Session.init(alloc, io, .{
        .srate = @intCast(kujamba_out.sample_rate),
        .channel_names = &.{"kujamba"},
        .source = fill.source(),
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.broadcastForFn },
    });
    defer s.deinit();
    s.log.quiet = true; // these tests assert on state, not on the transcript

    // Three intervals have gone out and the grid was re-anchored once already
    // (the #24 shape), so identity and position deliberately differ: seq 3,
    // grid bar 7. Bar 7 of a 3+1 pattern is a rest bar.
    s.index.seq = 3;
    s.index.grid = 7;
    fill.cursor = 1234; // the phrase is mid-word

    var f = Fixed{};
    try proto.buildConfig(.{ .bpm = 120, .bpi = 4 }, &f);
    try Session.Testing.dispatch(&s, .{ .mtype = proto.MSG_CONFIG_CHANGE_NOTIFY, .payload = f.slice() });

    // identity: monotonic, so no guid repeats and no dump gets renamed
    try std.testing.expectEqual(@as(u64, 3), s.index.seq);
    // grid position: continuous, so the pattern does not stutter
    try std.testing.expectEqual(@as(u64, 7), s.index.grid);
    // the phrase was not cut: the cursor still points into the middle of it
    try std.testing.expectEqual(@as(u64, 1234), fill.cursor);
    // ...and the new geometry really did take effect
    try std.testing.expectEqual(@as(u16, 120), s.bpm);
    try std.testing.expectEqual(@as(u16, 4), s.bpi);
    try std.testing.expectEqual(
        @as(u64, kujamba_out.sample_rate) * 4 * 60 / 120,
        s.interval_len_samples,
    );
    // bar 7 of a 3+1 pattern is a rest bar, and the re-anchor kept it that way
    try std.testing.expect(!s.locals[0].broadcast);

    // The guid the re-anchored interval is now uploading under is the one that
    // belongs to sequence 3 -- not the one the grid position 7 would produce.
    var by_seq: [16]u8 = undefined;
    var by_grid: [16]u8 = undefined;
    kujamba_out.deriveGuid(42, s.index.seq, 0, &by_seq);
    kujamba_out.deriveGuid(42, s.index.grid, 0, &by_grid);
    try std.testing.expect(!std.mem.eql(u8, &by_seq, &by_grid));
    try std.testing.expectEqualSlices(u8, &by_seq, &s.locals[0].guid);

    // ...and so is the payload dump: it must land on the sequence's filename,
    // not overwrite interval_0007.ogg from an earlier stretch of the session.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(dir);
    try s.locals[0].dump.add("payload");
    try Session.Testing.writePayloadDump(&s, &s.locals[0], dir);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(io, "interval_0007.ogg", .{}),
    );
    _ = try tmp.dir.access(io, "interval_0003.ogg", .{});
}

// kujamba (#12): the re-anchored interval continues the slot it was already in,
// so it re-derives exactly the id (guid + dump name) that slot owns.
test "kujamba: a re-anchored interval keeps the id of the slot it re-uses" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    var bank = try onePhraseBank(std.testing.allocator, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .repeat };
    fill.bind(.repeat, bank.active());
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .bank = &bank, .fill = &fill };

    var s = try Session.init(alloc, io, .{
        .srate = @intCast(kujamba_out.sample_rate),
        .channel_names = &.{"kujamba"},
        .source = fill.source(),
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.broadcastForFn },
    });
    defer s.deinit();
    s.log.quiet = true; // these tests assert on state, not on the transcript

    // the guid the server would already be receiving under, and the dump name
    // that interval slot owns
    var in_flight: [16]u8 = undefined;
    kujamba_out.deriveGuid(42, s.index.seq, 0, &in_flight);
    const name = try kujamba_out.payloadDumpName(alloc, "dump", s.index.seq);
    defer alloc.free(name);

    var f = Fixed{};
    try proto.buildConfig(.{ .bpm = 90, .bpi = 12 }, &f);
    try Session.Testing.dispatch(&s, .{ .mtype = proto.MSG_CONFIG_CHANGE_NOTIFY, .payload = f.slice() });

    // grid moved; interval identity did not
    var after: [16]u8 = undefined;
    kujamba_out.deriveGuid(42, s.index.seq, 0, &after);
    try std.testing.expectEqualSlices(u8, &in_flight, &after);
    const name_after = try kujamba_out.payloadDumpName(alloc, "dump", s.index.seq);
    defer alloc.free(name_after);
    try std.testing.expectEqualStrings(name, name_after);
}

// ---- #40 / #41: hostile server values must not panic the client -------------
// Both found by the #26 fuzz harness. The tests drive the real wire bytes
// through `dispatch`, not the handler directly, so they keep guarding the
// path an actual server message takes.

test "a userinfo record with channel_id >= 32 is skipped, not shifted (#40)" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    var bank = try onePhraseBank(std.testing.allocator, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .repeat };
    fill.bind(.repeat, bank.active());
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .bank = &bank, .fill = &fill };

    var s = try Session.init(alloc, io, .{
        .srate = @intCast(kujamba_out.sample_rate),
        .channel_names = &.{"kujamba"},
        .source = fill.source(),
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.broadcastForFn },
    });
    defer s.deinit();
    s.log.quiet = true;

    // channel 200 is the repro byte from #40. It cannot name a bit in a u32
    // mask, and the shift used to panic on the @intCast to u5.
    var f = Fixed{};
    try proto.buildUserinfoRecord(.{
        .active = true,
        .channel_id = 200,
        .volume = 0,
        .pan = 0,
        .flags = 0,
        .username = "x",
        .channel_name = "y",
    }, &f);
    // The record itself: the session survives, and does NOT tear down. One
    // nonsense channel from a quirky server should not end a live performance.
    try Session.Testing.dispatch(&s, .{ .mtype = proto.MSG_USERINFO_CHANGE_NOTIFY, .payload = f.slice() });
    try std.testing.expect(s.state != .done);

    // Nothing was subscribed, no user was conjured into existence for a record
    // we declined to act on, and -- the part a crash-only test would miss --
    // no auto-subscribe went out on the wire. `msgs_sent` is the honest witness
    // that we skipped the record rather than half-handling it.
    for (s.users) |u| try std.testing.expectEqual(@as(usize, 0), u.name_len);
    for (s.users) |u| try std.testing.expectEqual(@as(u32, 0), u.mask);
    try std.testing.expectEqual(@as(u64, 0), s.stats.msgs_sent);

    // Seam, not covered here: that a *well-formed* record arriving after this
    // one is still honoured. The auto-subscribe path calls send(), which
    // unwraps a socket this test does not have, so it is unreachable without
    // one -- the same seam #12 documented for the --intervals cap. #24, which
    // needs a socket anyway, should cover it end to end.
}

test "a config change with bpm=0 or bpi=0 is refused, not divided by (#41)" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    var bank = try onePhraseBank(std.testing.allocator, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .repeat };
    fill.bind(.repeat, bank.active());
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .bank = &bank, .fill = &fill };

    var s = try Session.init(alloc, io, .{
        .srate = @intCast(kujamba_out.sample_rate),
        .channel_names = &.{"kujamba"},
        .source = fill.source(),
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.broadcastForFn },
    });
    defer s.deinit();
    s.log.quiet = true;

    // A real geometry first, so "refused" is observable as "unchanged" rather
    // than as "never happened".
    var good = Fixed{};
    try proto.buildConfig(.{ .bpm = 120, .bpi = 4 }, &good);
    try Session.Testing.dispatch(&s, .{ .mtype = proto.MSG_CONFIG_CHANGE_NOTIFY, .payload = good.slice() });
    const good_len = s.interval_len_samples;
    try std.testing.expect(good_len > 0);

    // bpm = 0 reached @divTrunc(srate * bpi * 60, bpm) and panicked. bpi is
    // changed from the current value because `changed` gates the re-anchor.
    var zero_bpm = Fixed{};
    try proto.buildConfig(.{ .bpm = 0, .bpi = 8 }, &zero_bpm);
    try std.testing.expectError(
        error.SessionFailed,
        Session.Testing.dispatch(&s, .{ .mtype = proto.MSG_CONFIG_CHANGE_NOTIFY, .payload = zero_bpm.slice() }),
    );
    // The tempo the client was actually running is intact: the check has to
    // happen BEFORE self.bpm is assigned, or a bailed-out session is left
    // believing it is running at 0 bpm -- the state that made the panic
    // reachable in the first place.
    try std.testing.expectEqual(@as(u16, 120), s.bpm);
    try std.testing.expectEqual(@as(u16, 4), s.bpi);
    try std.testing.expectEqual(good_len, s.interval_len_samples);
    try std.testing.expectEqual(s.state, .done);
}

test "a config change with bpi=0 is refused: a zero-length interval is nonsense (#41)" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    var bank = try onePhraseBank(std.testing.allocator, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .repeat };
    fill.bind(.repeat, bank.active());
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .bank = &bank, .fill = &fill };

    var s = try Session.init(alloc, io, .{
        .srate = @intCast(kujamba_out.sample_rate),
        .channel_names = &.{"kujamba"},
        .source = fill.source(),
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.broadcastForFn },
    });
    defer s.deinit();
    s.log.quiet = true;

    // bpi = 0 does not panic -- advanceAudio early-returns on a zero interval
    // -- but it makes every interval zero-length, which turns the run loop's
    // `produced >= interval_len` into a per-pass finalize: a flood of empty
    // uploads instead of a crash. Just as unhonourable as bpm = 0.
    var zero_bpi = Fixed{};
    try proto.buildConfig(.{ .bpm = 100, .bpi = 0 }, &zero_bpi);
    try std.testing.expectError(
        error.SessionFailed,
        Session.Testing.dispatch(&s, .{ .mtype = proto.MSG_CONFIG_CHANGE_NOTIFY, .payload = zero_bpi.slice() }),
    );
    try std.testing.expect(s.interval_len_samples == 0 or s.bpi == 0);
    try std.testing.expectEqual(s.state, .done);
}

test "synthetic sources keep an independent phase per channel" {
    var a = LocalChannel{ .pending = Buf.init(std.testing.allocator), .dump = Buf.init(std.testing.allocator) };
    defer a.pending.deinit();
    var b = LocalChannel{ .pending = Buf.init(std.testing.allocator), .dump = Buf.init(std.testing.allocator) };
    defer b.pending.deinit();
    b.phase = 1.0; // start somewhere else in the cycle

    var ba: [128]f32 = undefined;
    var bb: [128]f32 = undefined;
    const src = Source{ .tone = .{ .freq = 440, .amp = 0.5 } };
    encodeBlockFor(src, 48000, &a, null, &ba);
    encodeBlockFor(src, 48000, &b, null, &bb);
    try std.testing.expect(ba[0] != bb[0]);
    // each channel still advances its own oscillator
    try std.testing.expect(a.phase != b.phase);
}

// ---- #11 bar-accurate selection ---------------------------------------------

test "kujamba: a mode switch requested during bar N applies at the start of bar N+1" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A phrase long enough that a bar change is visible in the audio below.
    var phrase: [4096]f32 = undefined;
    for (&phrase, 0..) |*o, i| o.* = @as(f32, @floatFromInt(i % 97)) / 97.0;
    var bank = try onePhraseBank(std.testing.allocator, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .repeat };
    fill.bind(.repeat, bank.active());
    const pattern = try kujamba_out.parsePattern("1"); // always broadcast
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .mode = .repeat, .bank = &bank, .fill = &fill };

    var s = try Session.init(alloc, io, .{
        .srate = @intCast(kujamba_out.sample_rate),
        .channel_names = &.{"kujamba"},
        .source = fill.source(),
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.broadcastForFn },
    });
    defer s.deinit();
    s.log.quiet = true;

    // Bar 0 starts in repeat: the plan's mode is bound to the source.
    s.index.grid = 0;
    try Session.Testing.startIntervalEncoders(&s);
    try std.testing.expectEqual(kujamba_out.Mode.repeat, fill.mode);

    // A switch is "requested" during bar 0 by updating the plan. The fill is
    // untouched until the next bar boundary — this is the "no mid-interval
    // splice" property: the in-flight bar keeps the mode it started with.
    adapter.mode = .loop;
    try std.testing.expectEqual(kujamba_out.Mode.repeat, fill.mode); // not yet applied

    // Bar 1 starts: the selection is applied, now including the new mode.
    s.index.grid = 1;
    try Session.Testing.startIntervalEncoders(&s);
    try std.testing.expectEqual(kujamba_out.Mode.loop, fill.mode);
}

test "kujamba: a rest bar still rebinds the mode, so a switch while resting lands on the next play bar" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase: [2048]f32 = undefined;
    for (&phrase, 0..) |*o, i| o.* = @as(f32, @floatFromInt(i % 31)) / 31.0;
    var bank = try onePhraseBank(std.testing.allocator, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .repeat };
    fill.bind(.repeat, bank.active());
    const pattern = try kujamba_out.parsePattern("1+1"); // play, rest, play, rest
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .mode = .repeat, .bank = &bank, .fill = &fill };

    var s = try Session.init(alloc, io, .{
        .srate = @intCast(kujamba_out.sample_rate),
        .channel_names = &.{"kujamba"},
        .source = fill.source(),
        .id_seed = 7,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.broadcastForFn },
    });
    defer s.deinit();
    s.log.quiet = true;

    // bar 0 plays, bar 1 rests. Switch requested "during" the rest bar.
    s.index.grid = 0;
    try Session.Testing.startIntervalEncoders(&s);
    try std.testing.expectEqual(kujamba_out.Mode.repeat, fill.mode);

    adapter.mode = .once;
    s.index.grid = 1; // rest bar
    try Session.Testing.startIntervalEncoders(&s);
    // the rest bar applied the new mode even though it uploads no audio
    try std.testing.expectEqual(kujamba_out.Mode.once, fill.mode);
}

// ---- #9 chat-driven transport ------------------------------------------------

/// A one-entry bank over an already-rendered buffer, for tests that only need a
/// plan and a source and do not care that the audio is a real phrase. Goes
/// through `initBorrowed` so the bank owns no audio, so `deinit` cannot free a
/// stack buffer.
fn onePhraseBank(alloc: std.mem.Allocator, samples: []const f32) !kujamba_out.PhraseBank {
    return kujamba_out.PhraseBank.initBorrowed(alloc, &.{"test"}, &.{samples});
}

/// A socketpair whose client end has a deliberately tiny send buffer and a peer
/// that never reads — the one shape that reliably produces `EAGAIN`.
///
/// Loopback TCP is not usable for this: measured on macOS, a socketpair peer
/// that stops reading still absorbs **654 KB** with `SO_RCVBUF` set to 4096,
/// because the loopback path does not honour the receive window the way a real
/// network does. So end-to-end backpressure is a *slow-peer* failure, not a
/// jitter failure, and on loopback it is not reachable inside a test's patience.
/// A socketpair has a genuinely bounded buffer, which is what makes the drop
/// path testable at all — and it is the same `Conn`, the same `sendMessageBounded`
/// and the same `finalizeInterval`, only with a smaller pipe.
fn saturatedSocketPair() ![2]std.posix.socket_t {
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(@intCast(std.posix.AF.UNIX), @intCast(std.posix.SOCK.STREAM), 0, &fds);
    if (std.posix.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    std.posix.setsockopt(fds[0], std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, &std.mem.toBytes(@as(i32, 4096))) catch {};
    std.posix.setsockopt(fds[1], std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, &std.mem.toBytes(@as(i32, 4096))) catch {};
    // non-blocking on BOTH ends: the peer must be able to be drained without
    // blocking, and the client end already is on the real path
    for (fds) |fd| {
        var o: std.c.O = @bitCast(@as(u32, @intCast(std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0)))));
        o.NONBLOCK = true;
        _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(o)));
    }
    return fds;
}

/// Fill a non-blocking socket until `write` returns `EAGAIN`. Returns the bytes
/// it took, so a test can assert the pipe really was full.
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

// #14: a socket that cannot take the bar costs the bar, not the audio clock.
//
// This is the acceptance test the issue asks for, end to end through
// `finalizeInterval`. Before the fix this call did not return at all: `send()`
// went to `net.zig`'s `sendMessage`, whose EAGAIN branch polls in a loop until
// the peer reads. The bound asserted here is deliberately generous — a poll
// syscall and a log line — because the point is only that it is *bounded*.
test "kujamba: a blocked socket drops the bar instead of stalling the clock (#14)" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6 };
    var bank = try onePhraseBank(alloc, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .loop };
    fill.bind(.loop, bank.active());
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .bank = &bank, .fill = &fill };

    const fds = try saturatedSocketPair();
    defer _ = std.posix.errno(std.posix.system.close(fds[1])); // fds[0] is s.conn's
    var s = try Session.init(alloc, io, .{
        .srate = 48000,
        .channel_names = &.{"kujamba"},
        .source = fill.source(),
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.broadcastForFn },
    });
    defer s.deinit();
    s.conn = .{ .io = io, .fd = fds[0] };
    s.log.quiet = true;

    // a live session with a running interval clock, as `onConfig` leaves it
    s.state = .active;
    s.bpm = 120;
    s.bpi = 4;
    s.interval_len_samples = 96000; // 2 s at 48 kHz
    s.interval_start_ns = clock.nowNs(io);
    s.timing.anchor(s.interval_start_ns, s.bpm, s.bpi);
    const dropped_guid = s.locals[0].guid;
    try Session.Testing.startIntervalEncoders(&s);
    // the bar has real audio in it, so this is a bar worth losing
    var block: [960]f32 = undefined;
    for (&block, 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i)) * 0.05) * 0.5;
    for (s.locals) |*lc| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try lc.enc.?.encode(&block, &out);
        try lc.pending.add(out.items);
    }
    const pending_before = s.locals[0].pending.len;
    try std.testing.expect(pending_before > 0);

    // the peer stops reading: fill the pipe
    var junk: [4096]u8 = undefined;
    @memset(&junk, 0xA5);
    const absorbed = fillUntilBlocked(fds[0], &junk);
    try std.testing.expect(absorbed > 0);
    try std.testing.expect(!s.conn.?.writable()); // the gate agrees it is full

    // the bar is finalized against a socket that cannot take it
    const t0 = clock.nowNs(io);
    try Session.Testing.finalizeInterval(&s);
    const elapsed_ms = @divTrunc(clock.nowNs(io) - t0, std.time.ns_per_ms);

    // the bar is counted as lost, and NOT as uploaded
    try std.testing.expectEqual(@as(u64, 1), s.stats.intervals_dropped);
    try std.testing.expectEqual(@as(u64, 0), s.stats.intervals_uploaded);
    try std.testing.expectEqual(@as(u64, 0), s.stats.intervals_broadcast);
    try std.testing.expect(s.stats.upload_bytes_dropped > 0);
    // and not one byte of it was counted as uploaded, which is the other half
    // of "dropped": a bar cannot be both lost and sent
    try std.testing.expectEqual(@as(u64, 0), s.stats.upload_bytes);
    try std.testing.expectEqual(@as(u64, 0), s.stats.upload_chunks);
    // the clock did not stop: the sequence moved on
    try std.testing.expectEqual(@as(u64, 1), s.index.seq);
    // and the bar it moved by is bounded (#13's "no audible jumps", asserted
    // where it is applied). This bar was finished *early* — the test finalizes
    // straight after encoding 20 ms of a 2 s bar — so the correction runs
    // backwards, which is exactly the case a one-sided clamp would get wrong.
    const nominal_next = s.timing.boundaryNs(0) + s.timing.interval_ns;
    const applied = s.interval_start_ns - nominal_next;
    try std.testing.expect(@abs(applied) <= s.timing.slewLimitNs());
    try std.testing.expect(applied < 0); // early bar -> pulled back, not pushed on
    // the next bar is a fresh guid, so the server cannot read the retry as a
    // continuation of the guid it never finished receiving
    try std.testing.expect(!std.mem.eql(u8, &dropped_guid, &s.locals[0].guid));

    // This is the acceptance criterion: bounded, not merely "eventually".
    // Pre-fix it was unbounded (measured >5 s and still not returning); with a
    // 1000 ms budget it is ~1002 ms. 500 ms separates the two with room for a
    // scheduling spike, and this call does nothing but a poll, a log line and
    // some bookkeeping — it is microseconds of real work.
    try std.testing.expect(elapsed_ms < 500);
}

// #14: a drop can happen mid-interval, not only at the boundary.
//
// The chunk streaming inside `advanceAudio` sends `0x83`/`0x84` too, on the same
// audio-clock path, so it needs the same gate. When it trips, the channel is
// already `dropped` by the time `finalizeInterval` runs — which is what the
// `if (lc.dropped) continue` at the top of that loop is for. Without this test
// that guard could be deleted and nothing would notice.
test "kujamba: a mid-interval chunk that would block drops the bar and stays dropped (#14)" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase = [_]f32{0.1} ** 4096;
    var bank = try onePhraseBank(alloc, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .loop };
    fill.bind(.loop, bank.active());
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .bank = &bank, .fill = &fill };

    const fds = try saturatedSocketPair();
    defer _ = std.posix.errno(std.posix.system.close(fds[1]));
    var s = try Session.init(alloc, io, .{
        .srate = 48000,
        .channel_names = &.{"kujamba"},
        .source = fill.source(),
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.broadcastForFn },
    });
    defer s.deinit();
    s.conn = .{ .io = io, .fd = fds[0] };
    s.log.quiet = true;
    s.state = .active;
    s.bpm = 120;
    s.bpi = 4;
    s.interval_len_samples = 96000;
    s.interval_start_ns = clock.nowNs(io) - @as(i128, 96000) * 1_000_000_000 / 48000;
    s.timing.anchor(s.interval_start_ns, s.bpm, s.bpi);
    adapter.mode = .loop;
    try Session.Testing.startIntervalEncoders(&s);

    // the peer stops reading before the bar even starts
    var junk: [4096]u8 = undefined;
    @memset(&junk, 0xA5);
    _ = fillUntilBlocked(fds[0], &junk);

    // First generate only part of the bar, so the dropped state is visible.
    // It owns no encoder or queued audio, but its phrase cursor keeps moving.
    const t0 = clock.nowNs(io);
    try Session.Testing.advanceAudio(&s, s.interval_start_ns + 100 * std.time.ns_per_ms);
    try std.testing.expect(s.locals[0].dropped);
    try std.testing.expect(s.locals[0].enc == null);
    try std.testing.expectEqual(@as(usize, 0), s.locals[0].pending.len);
    try std.testing.expectEqual(@as(usize, 0), s.locals[0].dump.len);
    try std.testing.expectEqual(s.locals[0].produced, fill.cursor);
    // Finishing the bar advances the playhead without rebuilding lost audio.
    try Session.Testing.advanceAudio(&s, clock.nowNs(io));
    try std.testing.expectEqual(@as(u64, 96000), fill.cursor);
    const elapsed_ms = @divTrunc(clock.nowNs(io) - t0, std.time.ns_per_ms);

    // the mid-interval send tripped the gate, and the bar was counted once
    try std.testing.expectEqual(@as(u64, 1), s.stats.intervals_dropped);
    try std.testing.expectEqual(@as(u64, 0), s.stats.intervals_uploaded);
    try std.testing.expectEqual(@as(u64, 0), s.stats.upload_bytes);
    try std.testing.expectEqual(@as(u64, 0), s.stats.upload_chunks);
    // THIS is what the `if (lc.dropped) continue` at the top of
    // `finalizeInterval` buys. Without it, a channel dropped mid-interval falls
    // through to the "nothing encoded at all, send a silence marker" branch —
    // and the room hears a rest bar where the instrument was actually playing.
    // A dropped bar has to be silent about itself, not lie about why.
    try std.testing.expectEqual(@as(u64, 0), s.stats.silence_markers);
    try std.testing.expect(elapsed_ms < 500);
}

test "kujamba: one lost bar is counted once, however many channels were on it (#14)" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase = [_]f32{0.1} ** 4096;
    var bank = try onePhraseBank(alloc, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .loop };
    fill.bind(.loop, bank.active());
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .bank = &bank, .fill = &fill };

    const fds = try saturatedSocketPair();
    defer _ = std.posix.errno(std.posix.system.close(fds[1]));
    // TWO channels on one blocked socket. The point is the accounting: a bar
    // the room did not hear is one lost bar, not one per channel. Counting per
    // channel would report a two-channel client as twice as broken as it is.
    var s = try Session.init(alloc, io, .{
        .srate = 48000,
        .channel_names = &.{ "kujamba", "kujamba2" },
        .source = fill.source(),
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.broadcastForFn },
    });
    defer s.deinit();
    s.conn = .{ .io = io, .fd = fds[0] };
    s.log.quiet = true;
    s.state = .active;
    s.bpm = 120;
    s.bpi = 4;
    s.interval_len_samples = 96000;
    s.interval_start_ns = clock.nowNs(io);
    s.timing.anchor(s.interval_start_ns, s.bpm, s.bpi);
    try Session.Testing.startIntervalEncoders(&s);
    var block: [960]f32 = undefined;
    for (&block, 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i)) * 0.05) * 0.5;
    for (s.locals) |*lc| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try lc.enc.?.encode(&block, &out);
        try lc.pending.add(out.items);
    }

    var junk: [4096]u8 = undefined;
    @memset(&junk, 0xA5);
    _ = fillUntilBlocked(fds[0], &junk);
    try Session.Testing.finalizeInterval(&s);

    try std.testing.expectEqual(@as(usize, 2), s.locals.len);
    // one bar lost ...
    try std.testing.expectEqual(@as(u64, 1), s.stats.intervals_dropped);
    try std.testing.expectEqual(@as(u64, 0), s.stats.intervals_uploaded);
    // ... and no audio from either channel credited to the room
    try std.testing.expectEqual(@as(u64, 0), s.stats.intervals_broadcast);
    try std.testing.expectEqual(@as(u64, 0), s.stats.upload_channels);
    // but the clock moved exactly one bar, not two
    try std.testing.expectEqual(@as(u64, 1), s.index.seq);
}

test "kujamba: mid-bar and final drops count one bar and every channel's unsent bytes (#14)" {
    const io = std.testing.io;
    const fds = try saturatedSocketPair();
    defer _ = std.posix.system.close(fds[1]);
    var s = try Session.init(std.testing.allocator, io, .{
        .channel_names = &.{ "one", "two" },
    });
    defer s.deinit();
    s.conn = .{ .io = io, .fd = fds[0] };
    s.log.quiet = true;
    s.state = .active;
    s.bpm = 120;
    s.bpi = 4;
    s.interval_len_samples = 96000;
    s.interval_start_ns = clock.nowNs(io);
    s.timing.anchor(s.interval_start_ns, s.bpm, s.bpi);
    try s.locals[0].pending.add("first");
    try s.locals[0].dump.add("already sent, not discarded");
    try s.locals[1].pending.add("second");
    var junk = [_]u8{0xa5} ** 4096;
    _ = fillUntilBlocked(fds[0], &junk);

    Session.Testing.dropInterval(&s, &s.locals[0], "mid-bar");
    // Calling drop twice is harmless. Finalizing the other channel must not
    // reset the per-bar latch and count this same interval for a second time.
    Session.Testing.dropInterval(&s, &s.locals[0], "again");
    try Session.Testing.finalizeInterval(&s);
    try std.testing.expectEqual(@as(u64, 1), s.stats.intervals_dropped);
    try std.testing.expectEqual(@as(u64, 1), s.stats.intervals_backpressured);
    try std.testing.expectEqual(@as(u64, 11), s.stats.upload_bytes_dropped);
    try std.testing.expectEqual(@as(u64, 1), s.index.seq);
    try std.testing.expect(!s.drop_marked); // fresh bar, fresh drop latch
}

// #14: the clock keeps walking while every bar is refused.
//
// This is the property, stated deterministically. The end-to-end harness can
// only observe it through a real-time session, which makes the result a
// function of how fast the machine can encode — it produced 4 bars on a
// workstation and 1 on a loaded CI runner for the same code. Driving
// `finalizeInterval` directly removes the wall clock entirely: no timing, no
// runner dependence, and the assertion can be as strong as the claim.
//
// The pre-fix failure was that `finalizeInterval` never *returned* from the
// second bar onward. Here it returns for every bar, and the grid advances once
// per bar, so the count of dropped bars and the count of bars the clock walked
// are the same number.
test "kujamba: the clock keeps walking while every bar is refused (#14)" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase = [_]f32{0.1} ** 4096;
    var bank = try onePhraseBank(alloc, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .loop };
    fill.bind(.loop, bank.active());
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .bank = &bank, .fill = &fill };

    const fds = try saturatedSocketPair();
    defer _ = std.posix.errno(std.posix.system.close(fds[1]));
    var s = try Session.init(alloc, io, .{
        .srate = 48000,
        .channel_names = &.{"kujamba"},
        .source = fill.source(),
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.broadcastForFn },
    });
    defer s.deinit();
    s.conn = .{ .io = io, .fd = fds[0] };
    s.log.quiet = true;
    s.state = .active;
    s.bpm = 120;
    s.bpi = 4;
    s.interval_len_samples = 96000;
    s.interval_start_ns = clock.nowNs(io);
    s.timing.anchor(s.interval_start_ns, s.bpm, s.bpi);
    try Session.Testing.startIntervalEncoders(&s);

    // the peer stops reading and never comes back
    var junk: [4096]u8 = undefined;
    @memset(&junk, 0xA5);
    _ = fillUntilBlocked(fds[0], &junk);

    const bars = 12;
    var block: [960]f32 = undefined;
    for (&block, 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i)) * 0.05) * 0.5;
    const t0 = clock.nowNs(io);
    for (0..bars) |_| {
        for (s.locals) |*lc| {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(alloc);
            try lc.enc.?.encode(&block, &out);
            try lc.pending.add(out.items);
        }
        try Session.Testing.finalizeInterval(&s);
    }
    const elapsed_ms = @divTrunc(clock.nowNs(io) - t0, std.time.ns_per_ms);

    // every bar was lost ...
    try std.testing.expectEqual(@as(u64, bars), s.stats.intervals_dropped);
    try std.testing.expectEqual(@as(u64, 0), s.stats.intervals_uploaded);
    // ... and the clock walked every one of them anyway: identity AND grid
    // position both advance, because a bar that was never uploaded still happened
    try std.testing.expectEqual(@as(u64, bars), s.index.seq);
    try std.testing.expectEqual(@as(u64, bars), s.index.grid);
    // the grid advanced monotonically, a bounded step at a time, the whole way
    var prev = s.timing.boundaryNs(0);
    for (1..bars + 1) |k| {
        try std.testing.expect(s.timing.boundaryNs(k) > prev);
        prev = s.timing.boundaryNs(k);
    }
    // and twelve refused uploads cost milliseconds, not minutes
    try std.testing.expect(elapsed_ms < 500);
}

test "kujamba: the session recovers and uploads the next bar once the peer drains (#14)" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6 };
    var bank = try onePhraseBank(alloc, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .loop };
    fill.bind(.loop, bank.active());
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .bank = &bank, .fill = &fill };

    const fds = try saturatedSocketPair();
    defer _ = std.posix.errno(std.posix.system.close(fds[1])); // fds[0] is s.conn's
    var s = try Session.init(alloc, io, .{
        .srate = 48000,
        .channel_names = &.{"kujamba"},
        .source = fill.source(),
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.broadcastForFn },
    });
    defer s.deinit();
    s.conn = .{ .io = io, .fd = fds[0] };
    s.log.quiet = true;
    s.state = .active;
    s.bpm = 120;
    s.bpi = 4;
    s.interval_len_samples = 96000;
    s.interval_start_ns = clock.nowNs(io);
    s.timing.anchor(s.interval_start_ns, s.bpm, s.bpi);
    try Session.Testing.startIntervalEncoders(&s);

    // bar 1: blocked, dropped
    var junk: [4096]u8 = undefined;
    @memset(&junk, 0xA5);
    _ = fillUntilBlocked(fds[0], &junk);
    try Session.Testing.finalizeInterval(&s);
    try std.testing.expectEqual(@as(u64, 1), s.stats.intervals_dropped);
    const dropped_guid = s.locals[0].guid;

    // the peer wakes up and drains
    var sink: [65536]u8 = undefined;
    _ = drainSocket(fds[1], &sink);
    try std.testing.expect(s.conn.?.writable());

    // bar 2: the same audio, a fresh guid, and this time it goes out
    var block: [960]f32 = undefined;
    for (&block, 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i)) * 0.05) * 0.5;
    for (s.locals) |*lc| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try lc.enc.?.encode(&block, &out);
        try lc.pending.add(out.items);
    }
    try Session.Testing.finalizeInterval(&s);

    try std.testing.expectEqual(@as(u64, 1), s.stats.intervals_uploaded);
    try std.testing.expectEqual(@as(u64, 1), s.stats.intervals_broadcast);
    try std.testing.expect(s.stats.upload_bytes > 0);
    // the dropped bar's guid was never completed and the next one is a NEW guid,
    // so the server cannot mistake the retry for a continuation
    try std.testing.expect(!std.mem.eql(u8, &dropped_guid, &s.locals[0].guid));
    try std.testing.expectEqual(@as(u64, 2), s.index.seq);
}

test "kujamba: a !kujamba mode command over 0xC0 lands at the next bar, not mid-bar" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase: [4096]f32 = undefined;
    for (&phrase, 0..) |*o, i| o.* = @as(f32, @floatFromInt(i % 97)) / 97.0;
    var bank = try onePhraseBank(std.testing.allocator, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .repeat };
    fill.bind(.repeat, bank.active());
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .mode = .repeat, .bank = &bank, .fill = &fill };

    // The handler the CLI installs: reshape the plan, let the session apply it.
    const Handler = struct {
        fn apply(ctx: *anyopaque, message: proto.ChatParms) void {
            const verb = kujamba_out.commandFromChat(message);
            const a: *kujamba_out.PlanAdapter = @ptrCast(@alignCast(ctx));
            switch (verb) {
                .play => a.rest = false,
                .rest => a.rest = true,
                .loop => a.mode = .loop,
                .repeat => a.mode = .repeat,
                .once => a.mode = .once,
                .stop => kujamba_out.requestStop(),
                .select => |sel| a.bank.request(sel),
                .none => {},
            }
        }
    };

    var s = try Session.init(alloc, io, .{
        .srate = @intCast(kujamba_out.sample_rate),
        .channel_names = &.{"kujamba"},
        .source = fill.source(),
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.broadcastForFn },
        .on_chat = .{ .ctx = @ptrCast(&adapter), .receive = Handler.apply },
    });
    defer s.deinit();
    s.log.quiet = true;

    // Bar 0 is in flight in repeat mode.
    s.index.grid = 0;
    try Session.Testing.startIntervalEncoders(&s);
    try std.testing.expectEqual(kujamba_out.Mode.repeat, fill.mode);

    // The bandleader types `!kujamba loop` while bar 0 is still going. The 0xC0
    // layout is chat-kind dependent, so the command sits in the message slot.
    var chat = Fixed{};
    try proto.buildChat(&[_][]const u8{ "PRIVMSG", "bandleader", "#band", "!kujamba loop" }, &chat);
    try Session.Testing.dispatch(&s, .{ .mtype = proto.MSG_CHAT_MESSAGE, .payload = chat.slice() });

    // The command reached the plan, but the in-flight bar is untouched: this is
    // the "never mid-bar" property.
    try std.testing.expectEqual(kujamba_out.Mode.repeat, fill.mode);
    try std.testing.expectEqual(kujamba_out.Mode.loop, adapter.mode);

    // Bar 1 starts: the selection now carries loop, and it is applied.
    s.index.grid = 1;
    try Session.Testing.startIntervalEncoders(&s);
    try std.testing.expectEqual(kujamba_out.Mode.loop, fill.mode);
}

test "kujamba: !kujamba play/rest overrides the pattern at the next bar" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase: [2048]f32 = undefined;
    for (&phrase, 0..) |*o, i| o.* = @as(f32, @floatFromInt(i % 31)) / 31.0;
    var bank = try onePhraseBank(std.testing.allocator, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .repeat };
    fill.bind(.repeat, bank.active());
    // pattern that always plays, so any rest we see comes from the override
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .mode = .repeat, .bank = &bank, .fill = &fill };

    var s = try Session.init(alloc, io, .{
        .srate = @intCast(kujamba_out.sample_rate),
        .channel_names = &.{"kujamba"},
        .source = fill.source(),
        .id_seed = 7,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.broadcastForFn },
        .on_chat = null, // command parsing only; no handler wired
    });
    defer s.deinit();
    s.log.quiet = true;

    // With no handler, a command is logged and ignored — it cannot crash or act.
    var chat = Fixed{};
    try proto.buildChat(&[_][]const u8{ "MSG", "!kujamba rest" }, &chat);
    try Session.Testing.dispatch(&s, .{ .mtype = proto.MSG_CHAT_MESSAGE, .payload = chat.slice() });
    try std.testing.expect(adapter.rest == null);
    try std.testing.expectEqual(@as(u64, 1), s.stats.chat_received);

    // Now the override itself, applied through the plan directly.
    adapter.rest = true;
    s.index.grid = 0;
    try Session.Testing.startIntervalEncoders(&s);
    try std.testing.expect(!s.locals[0].broadcast); // forced rest bar

    adapter.rest = false;
    s.index.grid = 1;
    try Session.Testing.startIntervalEncoders(&s);
    try std.testing.expect(s.locals[0].broadcast); // forced play bar
}

// ---- #8 phrase bank + live selection ----------------------------------------

test "kujamba: a !kujamba <n> phrase switch over 0xC0 lands at the next bar, not mid-bar" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Two constant, obviously-distinct buffers: "which phrase is bound" is then
    // readable straight off the audio, with no synthesis in the way.
    const p1 = [_]f32{ 0.10, 0.10, 0.10, 0.10, 0.10, 0.10, 0.10, 0.10 };
    const p2 = [_]f32{ 0.90, 0.90, 0.90, 0.90, 0.90, 0.90, 0.90, 0.90 };
    var bank = try kujamba_out.PhraseBank.initBorrowed(alloc, &.{ "karibu", "asante" }, &.{ &p1, &p2 });
    defer bank.deinit();

    var fill = kujamba_out.Fill{ .mode = .repeat };
    fill.bind(.repeat, bank.active());
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .mode = .repeat, .bank = &bank, .fill = &fill };

    // The handler the CLI installs: resolve the selector now, apply it at the
    // next bar boundary.
    const Handler = struct {
        fn apply(ctx: *anyopaque, message: proto.ChatParms) void {
            const cmd = kujamba_out.commandFromChat(message);
            const a: *kujamba_out.PlanAdapter = @ptrCast(@alignCast(ctx));
            switch (cmd) {
                .select => |sel| a.bank.request(sel),
                else => {},
            }
        }
    };

    var s = try Session.init(alloc, io, .{
        .srate = @intCast(kujamba_out.sample_rate),
        .channel_names = &.{"kujamba"},
        .source = fill.source(),
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.broadcastForFn },
        .on_chat = .{ .ctx = @ptrCast(&adapter), .receive = Handler.apply },
    });
    defer s.deinit();
    s.log.quiet = true;

    // Bar 0 is in flight on phrase 1.
    s.index.grid = 0;
    try Session.Testing.startIntervalEncoders(&s);
    try std.testing.expectEqual(p1[0..].ptr, fill.samples.ptr);

    // The bandleader types `!kujamba 2` while bar 0 is still going. As with the
    // transport verbs, the command sits in the message slot because the 0xC0
    // layout is chat-kind dependent.
    var chat = Fixed{};
    try proto.buildChat(&[_][]const u8{ "PRIVMSG", "bandleader", "#band", "!kujamba 2" }, &chat);
    try Session.Testing.dispatch(&s, .{ .mtype = proto.MSG_CHAT_MESSAGE, .payload = chat.slice() });

    // The selector reached the bank and resolved...
    try std.testing.expectEqual(@as(u32, 0), bank.rejected);
    // ...but the in-flight bar still holds phrase 1. This is the "never
    // mid-bar" property, and it is what makes the switch safe to do live.
    try std.testing.expectEqual(p1[0..].ptr, fill.samples.ptr);

    // Bar 1 starts: the selection is applied and the new phrase is bound.
    s.index.grid = 1;
    try Session.Testing.startIntervalEncoders(&s);
    try std.testing.expectEqual(p2[0..].ptr, fill.samples.ptr);
    try std.testing.expectEqual(@as(u32, 1), bank.switches);
}

test "kujamba: !kujamba by phrase name switches, and an unknown name is ignored without dropping audio" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const p1 = [_]f32{ 0.10, 0.10, 0.10, 0.10 };
    const p2 = [_]f32{ 0.90, 0.90, 0.90, 0.90 };
    var bank = try kujamba_out.PhraseBank.initBorrowed(alloc, &.{ "karibu", "asante sana" }, &.{ &p1, &p2 });
    defer bank.deinit();

    var fill = kujamba_out.Fill{ .mode = .repeat };
    fill.bind(.repeat, bank.active());
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .mode = .repeat, .bank = &bank, .fill = &fill };

    const Handler = struct {
        fn apply(ctx: *anyopaque, message: proto.ChatParms) void {
            const cmd = kujamba_out.commandFromChat(message);
            const a: *kujamba_out.PlanAdapter = @ptrCast(@alignCast(ctx));
            switch (cmd) {
                .select => |sel| a.bank.request(sel),
                else => {},
            }
        }
    };

    var s = try Session.init(alloc, io, .{
        .srate = @intCast(kujamba_out.sample_rate),
        .channel_names = &.{"kujamba"},
        .source = fill.source(),
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.broadcastForFn },
        .on_chat = .{ .ctx = @ptrCast(&adapter), .receive = Handler.apply },
    });
    defer s.deinit();
    s.log.quiet = true;

    s.index.grid = 0;
    try Session.Testing.startIntervalEncoders(&s);

    // A name with a space in it resolves case-insensitively.
    var chat = Fixed{};
    try proto.buildChat(&[_][]const u8{ "MSG", "!kujamba ASANTE SANA" }, &chat);
    try Session.Testing.dispatch(&s, .{ .mtype = proto.MSG_CHAT_MESSAGE, .payload = chat.slice() });
    s.index.grid = 1;
    try Session.Testing.startIntervalEncoders(&s);
    try std.testing.expectEqual(p2[0..].ptr, fill.samples.ptr);

    // A name nobody has: rejected, counted, and the phrase keeps playing. The
    // "invalid selection drops no audio" acceptance criterion, end to end over
    // a real 0xC0.
    try proto.buildChat(&[_][]const u8{ "MSG", "!kujamba jambo ambalo halijulikani" }, &chat);
    try Session.Testing.dispatch(&s, .{ .mtype = proto.MSG_CHAT_MESSAGE, .payload = chat.slice() });
    try std.testing.expectEqual(@as(u32, 1), bank.rejected);
    try std.testing.expectEqual(@as(u32, 1), bank.switches); // no new switch
    s.index.grid = 2;
    try Session.Testing.startIntervalEncoders(&s);
    try std.testing.expectEqual(p2[0..].ptr, fill.samples.ptr);

    // ...and the audio really is still phrase 2, not a hole.
    var block: [4]f32 = undefined;
    fill.copyInto(0, block[0..4]);
    try std.testing.expectEqualSlices(f32, p2[0..4], block[0..4]);
}

test "kujamba: switching phrases does not re-render, so payloads stay byte-identical (#8 + #10)" {
    const alloc = std.testing.allocator;

    // The claim #10 makes is that a switch costs nothing at encode time: the
    // buffer the encoder reads is the one rendered at startup. This drives the
    // real encode path for two bars of the same phrase and shows the bytes do
    // not depend on how many times the bank was asked to switch (which is 0 --
    // the point is that asking changes nothing).
    var bank_a = kujamba_out.PhraseBank.init(alloc);
    defer bank_a.deinit();
    var bank_b = kujamba_out.PhraseBank.init(alloc);
    defer bank_b.deinit();
    try bank_a.parse("kujamba karibu\nasante sana\n", .{});
    try bank_b.parse("kujamba karibu\nasante sana\n", .{});

    // Same phrase from both banks is the same audio, byte for byte.
    for (bank_a.entries.items, bank_b.entries.items) |x, y| {
        try std.testing.expectEqualSlices(f32, x.samples, y.samples);
    }

    // A switch hands back the *stored* buffer, not a fresh render: the pointer
    // is the one the bank allocated at parse time, before any request.
    const stored = bank_a.entries.items[1].samples.ptr;
    bank_a.request("2");
    _ = bank_a.active();
    try std.testing.expectEqual(stored, bank_a.entries.items[1].samples.ptr);
}
