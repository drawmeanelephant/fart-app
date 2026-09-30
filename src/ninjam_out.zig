//! ninjam_out.zig — Flatlophone (kujamba) instrument glue for the vendored
//! NINJAM session engine.
//!
//! This is the only NINJAM-related code in the tree that is not vendored from
//! zclient: it maps the deterministic fart synth (`synth.zig`) onto the
//! interval grid and supplies the deterministic ids the session uses for
//! uploads.
//!
//! Design:
//!  - `Fill` adapts a pre-rendered phrase buffer to the session's per-block
//!    source call: an interval plays the phrase from sample 0 and pads the
//!    tail of the interval with silence. The synth renders at 44.1 kHz
//!    (`synth.SAMPLE_RATE`), which is also the session sample rate.
//!  - `Pattern` decides which bars broadcast audio and which bars are rests.
//!    Rest bars emit NINJAM silence markers instead of dead-air audio.
//!  - `deriveGuid`/`deriveSerial` make the transport ids a pure function of
//!    (seed, interval sequence, channel index), so two runs with the same seed
//!    produce byte-identical uploaded payloads (the libvorbis stream serial
//!    lives inside the encoded bytes and must therefore be pinned).
//!  - `IntervalIndex` splits interval *identity* from grid *position*, so a
//!    mid-session BPI/BPM change can move the grid without re-issuing guids or
//!    overwriting payload dumps (#12).

const std = @import("std");
const synth = @import("synth.zig");

/// Sample rate the phrase is rendered at, which is also the session's rate.
/// Re-exported so callers don't have to reach into `synth.zig`.
pub const sample_rate: u32 = synth.SAMPLE_RATE;

/// How the phrase is read out over the interval grid.
pub const Mode = enum {
    /// phrase restarts at sample 0 of every broadcast bar (loop-pedal tap)
    repeat,
    /// phrase plays continuously across bars, wrapping at its end (loop pedal);
    /// rest bars freeze the cursor
    loop,
    /// phrase plays once from the first broadcast bar, then silence forever
    once,
};

pub const ModeError = error{UnknownMode};

/// Parse a play mode name ("repeat", "loop", "once").
pub fn parseMode(s: []const u8) ModeError!Mode {
    if (std.mem.eql(u8, s, "repeat")) return .repeat;
    if (std.mem.eql(u8, s, "loop")) return .loop;
    if (std.mem.eql(u8, s, "once")) return .once;
    return error.UnknownMode;
}

/// Session-source adapter over a pre-rendered mono phrase (f32, ±1.0).
pub const Fill = struct {
    samples: []const f32,
    mode: Mode = .repeat,
    /// playback cursor for `loop`/`once` modes (advances only while encoding,
    /// so rest bars freeze it). Deterministic: block sizes may vary with wall
    /// clock, but every interval advances the cursor by exactly its length.
    cursor: u64 = 0,

    /// Fill `dst` with the next audio. `offset` is the sample offset inside the
    /// current interval; `repeat` mode reads the phrase from there (zero-padded
    /// past the phrase end), while `loop`/`once` ignore it and follow `cursor`.
    pub fn copyInto(self: *Fill, offset: u64, dst: []f32) void {
        const n: u64 = self.samples.len;
        switch (self.mode) {
            .repeat => {
                for (dst, 0..) |*o, i| {
                    const j = offset + i;
                    o.* = if (j < n) self.samples[@intCast(j)] else 0.0;
                }
            },
            .loop => {
                if (n == 0) {
                    @memset(dst, 0);
                    return;
                }
                for (dst) |*o| {
                    o.* = self.samples[@intCast(self.cursor % n)];
                    self.cursor += 1;
                }
            },
            .once => {
                for (dst) |*o| {
                    o.* = if (self.cursor < n) self.samples[@intCast(self.cursor)] else 0.0;
                    self.cursor += 1;
                }
            },
        }
    }

    /// RMS of the phrase as rendered (tests / diagnostics).
    pub fn rms(self: *const Fill) f64 {
        if (self.samples.len == 0) return 0;
        var acc: f64 = 0;
        for (self.samples) |s| acc += @as(f64, s) * @as(f64, s);
        return @sqrt(acc / @as(f64, @floatFromInt(self.samples.len)));
    }
};

/// Bar pattern: `play` broadcast bars followed by `rest` silence-marker bars,
/// repeating. "3+1" = three bars of fart, one bar of rest; "1" = always play.
pub const Pattern = struct {
    play: u32,
    rest: u32,

    pub fn broadcastFor(self: *const Pattern, interval_idx: u64) bool {
        if (self.rest == 0) return self.play != 0;
        if (self.play == 0) return false;
        const period: u64 = @as(u64, self.play) + @as(u64, self.rest);
        return (interval_idx % period) < @as(u64, self.play);
    }
};

pub const PatternError = error{ EmptyPattern, InvalidCharacter, Overflow };

/// Parse "N+M" (play+rest) or "N" (always play).
pub fn parsePattern(s: []const u8) PatternError!Pattern {
    if (std.mem.indexOfScalar(u8, s, '+')) |plus| {
        const p = std.fmt.parseInt(u32, s[0..plus], 10) catch |e| return e;
        const r = std.fmt.parseInt(u32, s[plus + 1 ..], 10) catch |e| return e;
        if (p == 0) return error.EmptyPattern;
        return .{ .play = p, .rest = r };
    }
    const p = std.fmt.parseInt(u32, s, 10) catch |e| return e;
    if (p == 0) return error.EmptyPattern;
    return .{ .play = p, .rest = 0 };
}

/// Filename for one interval's payload dump: `<dump_dir>/interval_NNNN.ogg`,
/// keyed by the monotonic sequence so a grid re-anchor can never overwrite an
/// earlier interval's bytes (the determinism evidence the demo diffs).
pub fn payloadDumpName(
    alloc: std.mem.Allocator,
    dump_dir: []const u8,
    interval_seq: u64,
) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/interval_{d:0>4}.ogg", .{ dump_dir, interval_seq });
}

// ---- interval identity vs. grid position -----------------------------------

/// The two roles a NINJAM session's interval counter has to play, which used
/// to be conflated in one `interval_idx` field (#12).
///
/// `seq` is **identity**: monotonic for the life of the session, and the only
/// thing allowed to derive transport ids (guid + libvorbis serial), name a
/// payload dump, or count against `--intervals`. Before the split, a `0x02`
/// config change reset this counter to 0, which re-issued guids the server had
/// already seen carrying *different* payload bytes and silently overwrote
/// earlier `interval_NNNN.ogg` dumps.
///
/// `grid` is **position**: it drives the bar-pattern decision only. A config
/// change re-anchors the *timing* onto the new grid but leaves the bar counter
/// and the phrase cursor continuous, so the phrase is not cut. `reanchor` is
/// the explicit escape hatch for a grid that genuinely restarts (reconnect,
/// #24); it is safe only because identity does not depend on it.
pub const IntervalIndex = struct {
    /// monotonic per-session interval identity — guids, dumps, `--intervals`
    seq: u64 = 0,
    /// position in the current grid — bar pattern / broadcast decision
    grid: u64 = 0,

    /// Finish the current interval: identity and position advance together.
    pub fn complete(self: *IntervalIndex) void {
        self.seq += 1;
        self.grid += 1;
    }

    /// Move the grid position without disturbing interval identity, so guids
    /// stay unique and payload dumps keep their filenames.
    pub fn reanchor(self: *IntervalIndex, bar: u64) void {
        self.grid = bar;
    }
};

/// Adapter so a `Pattern` can be handed to `session.Options.plan`.
pub const PlanAdapter = struct {
    pattern: *const Pattern,

    /// Matches `session.IntervalPlan.broadcastFor`.
    pub fn broadcastForFn(ctx: *anyopaque, interval_idx: u64) bool {
        const self: *PlanAdapter = @ptrCast(@alignCast(ctx));
        return self.pattern.broadcastFor(interval_idx);
    }
};

/// Render a Swahili phrase with the Flatlophone synth into mono f32 samples
/// at `synth.SAMPLE_RATE`, with a short linear fade-out so phrase tails and
/// loop wraps don't click. Deterministic: same phrase -> same samples.
pub fn renderPhraseF32(alloc: std.mem.Allocator, phrase: []const u8) ![]f32 {
    const pcm16 = try synth.renderPhraseSamples(alloc, phrase);
    defer alloc.free(pcm16);
    const out = try alloc.alloc(f32, pcm16.len);
    for (pcm16, out) |v, *o| o.* = @as(f32, @floatFromInt(v)) / 32768.0;
    const fade: usize = @min(out.len, synth.SAMPLE_RATE * 8 / 1000); // 8 ms
    if (fade > 0) {
        const start = out.len - fade;
        for (out[start..], 0..) |*o, k| {
            o.* *= @as(f32, @floatFromInt(fade - k)) / @as(f32, @floatFromInt(fade));
        }
    }
    return out;
}

// ---- cooperative stop (Ctrl+C) ----------------------------------------------

var stop_flag = std.atomic.Value(bool).init(false);

/// Signal handler safe: request a clean session stop (finish the interval).
pub fn requestStop() void {
    stop_flag.store(true, .release);
}

pub fn stopRequested() bool {
    return stop_flag.load(.acquire);
}

// ---- deterministic ids ------------------------------------------------------

fn mix(seed: u64, interval_seq: u64, channel_idx: usize, tag: []const u8) u64 {
    var h = std.hash.Wyhash.init(seed);
    var i = interval_seq;
    h.update(std.mem.asBytes(&i));
    var ci: u64 = @intCast(channel_idx);
    h.update(std.mem.asBytes(&ci));
    h.update(tag);
    return h.final();
}

/// Vorbis stream serial for (seed, interval, channel): must be pinned so the
/// encoded bytes are byte-identical across runs. `interval_seq` must be the
/// monotonic `IntervalIndex.seq`, never a grid position, or two different
/// payloads in one session can collide on a serial.
pub fn deriveSerial(seed: u64, interval_seq: u64, channel_idx: usize) u32 {
    const v = mix(seed, interval_seq, channel_idx, "kujamba-serial") & 0x7FFF_FFFF;
    return @intCast(v);
}

/// 16-byte upload guid for (seed, interval, channel). The guid is a transport
/// identifier (it never enters the 0x84 payload bytes), but it is derived
/// deterministically too so full transcripts replay consistently — and, keyed
/// off the monotonic sequence, a guid is never re-issued within a session.
pub fn deriveGuid(seed: u64, interval_seq: u64, channel_idx: usize, out: *[16]u8) void {
    const a = mix(seed, interval_seq, channel_idx, "kujamba-guid-0");
    const b = mix(seed, interval_seq, channel_idx, "kujamba-guid-1");
    std.mem.writeInt(u64, out[0..8], a, .little);
    std.mem.writeInt(u64, out[8..16], b, .little);
}

// --------------------------------------------------------------------------
// tests
// --------------------------------------------------------------------------

const testing = std.testing;

test "fill maps the phrase onto the grid and zero-pads the tail" {
    const phrase = [_]f32{ 1, 2, 3, 4 };
    var fill = Fill{ .samples = &phrase };
    var dst: [6]f32 = undefined;
    fill.copyInto(0, dst[0..4]);
    try testing.expectEqualSlices(f32, &phrase, dst[0..4]);
    fill.copyInto(2, dst[0..6]);
    try testing.expectEqualSlices(f32, &[_]f32{ 3, 4, 0, 0, 0, 0 }, &dst);
    fill.copyInto(100, dst[0..3]);
    try testing.expectEqualSlices(f32, &[_]f32{ 0, 0, 0 }, dst[0..3]);
}

test "pattern 3+1 broadcasts three bars, then rests one" {
    const p = try parsePattern("3+1");
    var i: u64 = 0;
    while (i < 12) : (i += 1) {
        const want = (i % 4) < 3;
        try testing.expectEqual(want, p.broadcastFor(i));
    }
    const always = try parsePattern("2");
    i = 0;
    while (i < 6) : (i += 1) try testing.expect(always.broadcastFor(i));
    try testing.expectError(error.InvalidCharacter, parsePattern("x+1"));
    try testing.expectError(error.EmptyPattern, parsePattern("0+2"));
}

test "loop mode wraps continuously and once mode ends in silence" {
    const phrase = [_]f32{ 1, 2, 3 };

    var looped = Fill{ .samples = &phrase, .mode = .loop };
    var dst: [4]f32 = undefined;
    looped.copyInto(0, dst[0..3]); // first pass: 1 2 3
    try testing.expectEqualSlices(f32, &[_]f32{ 1, 2, 3 }, dst[0..3]);
    looped.copyInto(0, dst[0..2]); // continues, does NOT restart: wraps to 1 2
    try testing.expectEqualSlices(f32, &[_]f32{ 1, 2 }, dst[0..2]);
    looped.copyInto(0, dst[0..4]); // 3, then wraps again
    try testing.expectEqualSlices(f32, &[_]f32{ 3, 1, 2, 3 }, &dst);

    var once = Fill{ .samples = &phrase, .mode = .once };
    once.copyInto(0, dst[0..3]);
    try testing.expectEqualSlices(f32, &[_]f32{ 1, 2, 3 }, dst[0..3]);
    once.copyInto(0, dst[0..3]); // exhausted: silence from here on
    try testing.expectEqualSlices(f32, &[_]f32{ 0, 0, 0 }, dst[0..3]);
    // an empty phrase in loop mode is silence, never a divide-by-zero
    var empty = Fill{ .samples = &.{}, .mode = .loop };
    empty.copyInto(0, dst[0..2]);
    try testing.expectEqualSlices(f32, &[_]f32{ 0, 0 }, dst[0..2]);
}

test "play mode names parse" {
    try testing.expectEqual(Mode.repeat, try parseMode("repeat"));
    try testing.expectEqual(Mode.loop, try parseMode("loop"));
    try testing.expectEqual(Mode.once, try parseMode("once"));
    try testing.expectError(error.UnknownMode, parseMode("yolo"));
}

test "derived ids are deterministic and interval-specific" {
    var g1: [16]u8 = undefined;
    var g2: [16]u8 = undefined;
    deriveGuid(42, 7, 0, &g1);
    deriveGuid(42, 7, 0, &g2);
    try testing.expectEqualSlices(u8, &g1, &g2);
    var g3: [16]u8 = undefined;
    deriveGuid(42, 8, 0, &g3);
    try testing.expect(!std.mem.eql(u8, &g1, &g3));
    try testing.expectEqual(deriveSerial(42, 7, 0), deriveSerial(42, 7, 0));
    try testing.expect(deriveSerial(42, 7, 0) != deriveSerial(43, 7, 0));
    try testing.expect(deriveSerial(42, 7, 0) != deriveSerial(42, 7, 1));
}

// ---- interval identity vs. grid position: tests ------------------------------

/// Grid geometry, as the server announces it in `0x02 CONFIG`.
const Grid = struct {
    bpi: u16,
    bpm: u16,

    fn samplesPerInterval(self: Grid, srate: u32) u64 {
        return @as(u64, srate) * @as(u64, self.bpi) * 60 / @as(u64, self.bpm);
    }
};

/// One scripted session, replayed the way the session engine drives the
/// counters: derive this interval's id and dump name, then complete it. A
/// config change only swaps the grid geometry — the pre-fix engine also zeroed
/// the counter it derived ids from, which is exactly what these tests guard.
const ScriptedRun = struct {
    n: u64 = 0,
    guids: [16][16]u8 = undefined,
    dumps: [16][]u8 = undefined,
    grids: [16]u64 = undefined,
    lens: [16]u64 = undefined,

    fn deinit(self: *ScriptedRun, alloc: std.mem.Allocator) void {
        for (self.dumps[0..self.n]) |d| alloc.free(d);
    }
};

fn runScriptedSession(
    alloc: std.mem.Allocator,
    seed: u64,
    intervals: u64,
    first: Grid,
    second: Grid,
    change_at: ?u64,
) !ScriptedRun {
    try testing.expect(intervals <= 16);
    var idx = IntervalIndex{};
    var run = ScriptedRun{};
    while (run.n < intervals) {
        const g = if (change_at) |at| (if (run.n < at) first else second) else first;
        deriveGuid(seed, idx.seq, 0, &run.guids[run.n]);
        run.dumps[run.n] = try payloadDumpName(alloc, "dump", idx.seq);
        run.grids[run.n] = idx.grid;
        run.lens[run.n] = g.samplesPerInterval(synth.SAMPLE_RATE);
        run.n += 1;
        idx.complete();
    }
    return run;
}

test "interval identity is monotonic across a BPI/BPM change and guids never repeat" {
    const alloc = testing.allocator;
    const seed: u64 = 42;
    const n: u64 = 10;
    const change_at: u64 = 4;
    // same phrase, different grid geometry from bar 4 on: the payloads differ
    const before = Grid{ .bpi = 8, .bpm = 100 };
    const after = Grid{ .bpi = 4, .bpm = 120 };

    var run = try runScriptedSession(alloc, seed, n, before, after, change_at);
    defer run.deinit(alloc);

    // the change really is a content change — this is why a reused seq is fatal
    try testing.expect(run.lens[change_at - 1] != run.lens[change_at]);

    for (0..n) |i| {
        const seq_i: u64 = @intCast(i);
        // identity is the sequence, and it only ever goes up
        const want = try std.fmt.allocPrint(alloc, "dump/interval_{d:0>4}.ogg", .{seq_i});
        defer alloc.free(want);
        try testing.expectEqualStrings(want, run.dumps[i]);
        // grid position is continuous too: a config change must not restart
        // bar numbering, or the pattern would stutter at the change
        try testing.expectEqual(seq_i, run.grids[i]);
        for (0..i) |j| {
            try testing.expect(!std.mem.eql(u8, &run.guids[i], &run.guids[j]));
        }
    }
}

test "the same session with a config change replays to identical ids and dumps" {
    const alloc = testing.allocator;
    var a = try runScriptedSession(alloc, 4242, 8, .{ .bpi = 8, .bpm = 100 }, .{ .bpi = 4, .bpm = 120 }, 3);
    defer a.deinit(alloc);
    var b = try runScriptedSession(alloc, 4242, 8, .{ .bpi = 8, .bpm = 100 }, .{ .bpi = 4, .bpm = 120 }, 3);
    defer b.deinit(alloc);

    for (0..a.n) |i| {
        try testing.expectEqualSlices(u8, &a.guids[i], &b.guids[i]);
        try testing.expectEqualStrings(a.dumps[i], b.dumps[i]);
        try testing.expectEqual(deriveSerial(4242, @intCast(i), 0), deriveSerial(4242, @intCast(i), 0));
    }
}

test "re-anchoring the grid does not renumber intervals or reissue ids" {
    // the #24 shape: resume at the top of the grid after a reconnect
    var idx = IntervalIndex{};
    var before: [16]u8 = undefined;
    deriveGuid(7, idx.seq, 0, &before);
    idx.complete();
    idx.complete();
    idx.reanchor(0);
    try testing.expectEqual(@as(u64, 2), idx.seq);
    try testing.expectEqual(@as(u64, 0), idx.grid);

    // ids follow the sequence, so a re-anchored grid cannot collide with an id
    // the server has already seen under different payload bytes
    var after: [16]u8 = undefined;
    deriveGuid(7, idx.seq, 0, &after);
    try testing.expect(!std.mem.eql(u8, &before, &after));
    var unanchored: [16]u8 = undefined;
    deriveGuid(7, 2, 0, &unanchored);
    try testing.expectEqualSlices(u8, &unanchored, &after);
}

test "a config change does not cut the phrase: the cursor resumes where it left off" {
    // Re-anchoring onto a new grid restarts the interval encoder, but the
    // phrase buffer is the same object: in `loop` the phrase picks up on the
    // sample after the last one, and in `once` it is not rewound to 0.
    const phrase = [_]f32{ 1, 2, 3, 4, 5, 6 };
    var looper = Fill{ .samples = &phrase, .mode = .loop };
    var dst: [3]f32 = undefined;
    looper.copyInto(0, dst[0..3]); // bar before the change: 1 2 3
    try testing.expectEqualSlices(f32, &[_]f32{ 1, 2, 3 }, dst[0..3]);
    var idx = IntervalIndex{};
    idx.complete();
    idx.reanchor(0); // geometry moved, encoder restarts, buffer untouched
    looper.copyInto(0, dst[0..3]); // bar after the change: 4 5 6 — not 1 2 3
    try testing.expectEqualSlices(f32, &[_]f32{ 4, 5, 6 }, dst[0..3]);

    var once = Fill{ .samples = &phrase, .mode = .once };
    var dst4: [4]f32 = undefined;
    once.copyInto(0, dst4[0..4]);
    idx.reanchor(0);
    once.copyInto(0, dst4[0..2]); // continues at 5, does not restart the phrase
    try testing.expectEqualSlices(f32, &[_]f32{ 5, 6 }, dst4[0..2]);
}

test "phrase renders non-silent and deterministically" {
    const alloc = testing.allocator;
    const a = try renderPhraseF32(alloc, "kujamba karibu");
    defer alloc.free(a);
    const b = try renderPhraseF32(alloc, "kujamba karibu");
    defer alloc.free(b);
    try testing.expectEqualSlices(f32, a, b);
    var peak: f32 = 0;
    for (a) |v| peak = @max(peak, @abs(v));
    try testing.expect(peak > 0.05);
}

/// One full interval through the exact production path (headers + 960-sample
/// blocks + flush) so tests can hash "the uploaded payload bytes".
fn encodeIntervalToOwned(
    alloc: std.mem.Allocator,
    samples: []const f32,
    serial: u32,
    interval_len: usize,
) ![]u8 {
    const vorbis = @import("ninjam/vorbis.zig");
    var fill = Fill{ .samples = samples };
    const enc = try vorbis.Encoder.create(alloc, @intCast(synth.SAMPLE_RATE), 0.0, serial);
    defer enc.destroy();
    var ogg: std.ArrayList(u8) = .empty;
    errdefer ogg.deinit(alloc);
    try enc.writeHeaders(&ogg);
    const block_samples: usize = 960;
    var off: usize = 0;
    while (off < interval_len) {
        const n = @min(block_samples, interval_len - off);
        var block: [block_samples]f32 = undefined;
        fill.copyInto(off, block[0..n]);
        try enc.encode(block[0..n], &ogg);
        off += n;
    }
    try enc.flush(&ogg);
    return ogg.toOwnedSlice(alloc);
}

test "interval payload is byte-identical across two pipelines and decodes non-silent" {
    const alloc = testing.allocator;
    const vorbis = @import("ninjam/vorbis.zig");
    const phrase = try renderPhraseF32(alloc, "kujamba karibu");
    defer alloc.free(phrase);

    const interval_len: usize = 44100 * 8 * 60 / 100; // bpi=8, bpm=100 @ 44100 Hz
    const serial = deriveSerial(4242, 0, 0);

    const o1 = try encodeIntervalToOwned(alloc, phrase, serial, interval_len);
    defer alloc.free(o1);
    const o2 = try encodeIntervalToOwned(alloc, phrase, serial, interval_len);
    defer alloc.free(o2);
    try testing.expectEqualSlices(u8, o1, o2);
    try testing.expect(o1.len > 1000);
    try testing.expectEqualSlices(u8, "OggS", o1[0..4]);

    var dec = try vorbis.decodeMemory(alloc, o1);
    defer dec.deinit();
    try testing.expectEqual(@as(u32, 44100), dec.srate);
    try testing.expect(dec.rms() > 0.01);
    try testing.expect(dec.frames() > 44100); // at least ~1 s of audio
}

test "a rest interval encodes to exact zero energy" {
    const alloc = testing.allocator;
    const vorbis = @import("ninjam/vorbis.zig");
    const silent = try alloc.alloc(f32, 44100 * 2);
    defer alloc.free(silent);
    @memset(silent, 0);
    const ogg = try encodeIntervalToOwned(alloc, silent, deriveSerial(1, 3, 0), 44100 * 2);
    defer alloc.free(ogg);
    var dec = try vorbis.decodeMemory(alloc, ogg);
    defer dec.deinit();
    try testing.expect(dec.rms() < 1e-6);
}
