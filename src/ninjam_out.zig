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

/// What the plan selects for one interval.
///
/// The session consults the plan once per interval, *before* it generates any
/// audio, and applies this selection at that bar boundary. That ordering is
/// what makes "a switch requested during bar N takes effect at the start of
/// bar N+1" true by construction rather than by a latch: by the time a block is
/// encoded, the whole bar's mode and phrase are already decided. #11.
pub const Selection = struct {
    /// false makes the interval a silence-marker bar — no audio is uploaded
    broadcast: bool,
    /// play mode for the interval
    mode: Mode,
    /// phrase buffer to read this interval; null keeps whatever the source
    /// already holds. Carried ahead of #8's bank so the hook is reshaped once.
    samples: ?[]const f32 = null,
};

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
    /// play mode the plan selects for each interval. A live switch updates this
    /// and it is picked up at the next bar boundary.
    mode: Mode = .repeat,
    /// the phrase buffer this plan currently selects. One buffer today; #8
    /// resolves an index into a bank here.
    samples: []const f32 = &.{},

    /// Matches `session.IntervalPlan.selectFor`.
    pub fn selectForFn(ctx: *anyopaque, interval_idx: u64) Selection {
        const self: *PlanAdapter = @ptrCast(@alignCast(ctx));
        return .{
            .broadcast = self.pattern.broadcastFor(interval_idx),
            .mode = self.mode,
            .samples = self.samples,
        };
    }
};

/// Render a Swahili phrase with the Flatlophone synth into mono f32 samples
/// at `synth.SAMPLE_RATE`, with a short linear fade-out so phrase tails and
/// loop wraps don't click. Deterministic: same phrase -> same samples.
pub fn renderPhraseF32(alloc: std.mem.Allocator, phrase: []const u8) ![]f32 {
    return renderPhraseF32With(alloc, phrase, .{});
}

/// `renderPhraseF32` with the synth's voice knobs applied (#18). The default
/// `{}` is the identity and byte-identical to `renderPhraseF32`.
pub fn renderPhraseF32With(
    alloc: std.mem.Allocator,
    phrase: []const u8,
    knobs: synth.VoiceKnobs,
) ![]f32 {
    const pcm16 = try synth.renderPhraseSamplesWith(alloc, phrase, knobs);
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

// ---- offline render ----------------------------------------------------------

/// How `renderOfflineF32` lays one phrase over the bar grid. Mirrors the flags
/// `join` already takes, so an offline file is shaped like the session.
pub const OfflineOpts = struct {
    mode: Mode = .repeat,
    pattern: Pattern = .{ .play = 1, .rest = 0 },
    /// how many bars to render, each `bar_samples` long
    bars: u32 = 1,
    /// samples per bar. 0 means "one bar exactly as long as the phrase", so the
    /// defaults render the phrase untouched rather than truncating it at 1s.
    bar_samples: u64 = 0,
    /// voice tuning for the synth (#18); the default is the identity
    knobs: synth.VoiceKnobs = .{},
};

/// Render a phrase to the bar-shaped audio `join` would upload, with no server.
///
/// This is the same three pieces the session uses — `renderPhraseF32`, the bar
/// `Pattern`, and `Fill` — driven bar by bar instead of block by block, so the
/// offline file is what a listener would have heard.
///
/// **Rest bars are exact silence, not skipped bars.** In a session a rest bar
/// uploads a NINJAM silence marker rather than audio, so the room hears nothing
/// for that bar and the phrase cursor does not advance. Emitting silence
/// preserves both: the output timeline matches the live one sample for sample,
/// and `--pattern 3+1` means "3 bars of fart, 1 bar of nothing" rather than
/// "3 bars of fart with the gap removed". Skipping the bars would make the file
/// disagree with the room it is meant to preview.
pub fn renderOfflineF32(
    alloc: std.mem.Allocator,
    phrase: []const u8,
    opts: OfflineOpts,
) ![]f32 {
    const samples = try renderPhraseF32With(alloc, phrase, opts.knobs);
    defer alloc.free(samples);

    const bar: u64 = if (opts.bar_samples != 0) opts.bar_samples else @max(1, samples.len);
    const bars: u64 = @max(1, opts.bars);
    const bar_usize: usize = @intCast(bar);
    const out = try alloc.alloc(f32, @intCast(bar * bars));
    errdefer alloc.free(out);
    @memset(out, 0); // rest bars stay exactly zero

    var fill = Fill{ .samples = samples, .mode = opts.mode };
    var b: u64 = 0;
    while (b < bars) : (b += 1) {
        // A rest bar is skipped entirely: no copyInto call, so in loop/once the
        // cursor freezes just as it does in the session.
        if (!opts.pattern.broadcastFor(b)) continue;
        const start: usize = @intCast(b * bar);
        fill.copyInto(0, out[start..][0..bar_usize]);
    }
    return out;
}

/// f32 -> i16 using the same scaling synth itself uses, clamped so a shaped
/// buffer cannot wrap around on an out-of-range sample.
pub fn f32ToI16(x: f32) i16 {
    const scaled: f64 = @round(@as(f64, @floatCast(x)) * 32767.0);
    return @intFromFloat(std.math.clamp(scaled, -32768.0, 32767.0));
}

/// Offline render straight to WAV bytes (44-byte header + data).
pub fn renderOfflineWav(
    alloc: std.mem.Allocator,
    phrase: []const u8,
    opts: OfflineOpts,
) ![]u8 {
    const pcm = try renderOfflineF32(alloc, phrase, opts);
    defer alloc.free(pcm);
    const pcm16 = try alloc.alloc(i16, pcm.len);
    defer alloc.free(pcm16);
    for (pcm, pcm16) |x, *o| o.* = f32ToI16(x);
    return synth.writeWavBytes(alloc, pcm16, sample_rate);
}

/// Offline render straight to Ogg Vorbis bytes, through the same 960-sample
/// block size the session uploads intervals with, so the file is a real
/// interval payload rather than something only a decoder would accept.
pub fn renderOfflineOgg(
    alloc: std.mem.Allocator,
    phrase: []const u8,
    opts: OfflineOpts,
    serial: u32,
) ![]u8 {
    const pcm = try renderOfflineF32(alloc, phrase, opts);
    defer alloc.free(pcm);
    const vorbis = @import("ninjam/vorbis.zig");
    const enc = try vorbis.Encoder.create(alloc, @intCast(sample_rate), 0.0, serial);
    defer enc.destroy();
    var ogg: std.ArrayList(u8) = .empty;
    errdefer ogg.deinit(alloc);
    try enc.writeHeaders(&ogg);
    const block: usize = 960;
    var off: usize = 0;
    while (off < pcm.len) {
        const n = @min(block, pcm.len - off);
        try enc.encode(pcm[off..][0..n], &ogg);
        off += n;
    }
    try enc.flush(&ogg);
    return ogg.toOwnedSlice(alloc);
}

/// RMS of a finished buffer, for CLI reporting and tests.
pub fn rmsOf(samples: []const f32) f64 {
    if (samples.len == 0) return 0;
    var acc: f64 = 0;
    for (samples) |s| acc += @as(f64, s) * @as(f64, s);
    return @sqrt(acc / @as(f64, @floatFromInt(samples.len)));
}

/// Peak absolute sample value of a finished buffer.
pub fn peakOf(samples: []const f32) f64 {
    var peak: f64 = 0;
    for (samples) |s| peak = @max(peak, @abs(@as(f64, @floatCast(s))));
    return peak;
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

// ---- offline render tests ----------------------------------------------------

test "offline render with defaults is the phrase itself: nothing truncated, nothing padded" {
    const alloc = testing.allocator;
    const phrase = try renderPhraseF32(alloc, "kujamba karibu");
    defer alloc.free(phrase);
    const out = try renderOfflineF32(alloc, "kujamba karibu", .{});
    defer alloc.free(out);
    // the default bar is exactly the phrase, so the file is the phrase
    try testing.expectEqualSlices(f32, phrase, out);
}

test "a rest bar is exact silence and freezes the phrase cursor (loop mode)" {
    const alloc = testing.allocator;
    const phrase = try renderPhraseF32(alloc, "kujamba karibu");
    defer alloc.free(phrase);
    const bar = @divExact(phrase.len, 2);
    const out = try renderOfflineF32(alloc, "kujamba karibu", .{
        .mode = .loop,
        .pattern = .{ .play = 1, .rest = 1 },
        .bars = 4,
        .bar_samples = bar,
    });
    defer alloc.free(out);
    try testing.expectEqual(@as(usize, bar * 4), out.len);

    const b0 = out[0..bar];
    const b1 = out[bar..][0..bar];
    const b2 = out[bar * 2 ..][0..bar];
    const b3 = out[bar * 3 ..][0..bar];

    // bars 1 and 3 rest: exact zeros, and the bar is not skipped, so the
    // offline timeline still matches the live one
    for (b1) |s| try testing.expectEqual(0.0, s);
    for (b3) |s| try testing.expectEqual(0.0, s);

    // bar 0 reads the first half...
    try testing.expectEqualSlices(f32, phrase[0..bar], b0);
    // ...and bar 2 continues into the second half, which is only true if the
    // rest bar froze the cursor instead of restarting the phrase
    try testing.expectEqualSlices(f32, phrase[bar..], b2);
}

test "offline shaping is deterministic and rest bars carry no energy" {
    const alloc = testing.allocator;
    const opts = OfflineOpts{
        .mode = .once,
        .pattern = .{ .play = 3, .rest = 1 },
        .bars = 4,
        .bar_samples = 44100 / 2,
    };
    const a = try renderOfflineF32(alloc, "kujamba tena", opts);
    defer alloc.free(a);
    const b = try renderOfflineF32(alloc, "kujamba tena", opts);
    defer alloc.free(b);
    try testing.expectEqualSlices(f32, a, b);

    try testing.expect(rmsOf(a) > 0.01);
    const last_bar = a[44100 * 3 / 2 ..][0 .. 44100 / 2];
    for (last_bar) |s| try testing.expectEqual(0.0, s);
}

test "offline WAV is a valid non-silent PCM file with a correct data length" {
    const alloc = testing.allocator;
    const wav = try renderOfflineWav(alloc, "kujamba karibu", .{});
    defer alloc.free(wav);

    try testing.expectEqualSlices(u8, "RIFF", wav[0..4]);
    try testing.expectEqualSlices(u8, "WAVE", wav[8..12]);
    try testing.expectEqualSlices(u8, "data", wav[36..40]);
    try testing.expectEqual(
        @as(u32, synth.SAMPLE_RATE),
        std.mem.readInt(u32, wav[24..28], .little),
    );
    try testing.expectEqual(
        @as(usize, wav.len - 44),
        @as(usize, synth.wavDataByteLen(wav)),
    );

    // non-silent: the phrase survived the f32 -> i16 roundtrip
    const nsamples = (wav.len - 44) / 2;
    var acc: f64 = 0;
    for (0..nsamples) |k| {
        const s: f64 = @floatFromInt(std.mem.readInt(i16, wav[44 + 2 * k ..][0..2], .little));
        acc += s * s;
    }
    const rms = @sqrt(acc / @as(f64, @floatFromInt(nsamples)));
    try testing.expect(rms > 100.0);
}

test "offline OGG decodes non-silent and preserves the rest bar as silence" {
    const alloc = testing.allocator;
    const vorbis = @import("ninjam/vorbis.zig");
    const ogg = try renderOfflineOgg(alloc, "kujamba karibu", .{
        .pattern = .{ .play = 1, .rest = 1 },
        .bars = 2,
        .bar_samples = 44100,
    }, deriveSerial(7, 0, 0));
    defer alloc.free(ogg);
    try testing.expectEqualSlices(u8, "OggS", ogg[0..4]);

    var dec = try vorbis.decodeMemory(alloc, ogg);
    defer dec.deinit();
    try testing.expectEqual(@as(u32, 44100), dec.srate);
    try testing.expect(dec.rms() > 0.001);

    // Exactly two bars of frames, so the bar boundary lands where it should.
    try testing.expectEqual(@as(usize, 44100 * 2), dec.frames());

    // The second bar was a rest bar. Vorbis is lossy and rings a little into
    // the silence, so this asserts the bar is at least 20 dB below the play
    // bar rather than exactly zero (measured ~39 dB down, so there is margin).
    // The bit-exact zero is asserted on the shaped f32 buffer above, before
    // any codec sees it.
    const half = dec.pcm.len / 2;
    var play_acc: f64 = 0;
    var rest_acc: f64 = 0;
    for (dec.pcm, 0..) |s, k| {
        const sq = @as(f64, @floatCast(s)) * @as(f64, @floatCast(s));
        if (k < half) play_acc += sq else rest_acc += sq;
    }
    const play_rms = @sqrt(play_acc / @as(f64, @floatFromInt(half)));
    const rest_rms = @sqrt(rest_acc / @as(f64, @floatFromInt(half)));
    try testing.expect(play_rms > 0.01);
    try testing.expect(rest_rms * 10.0 < play_rms); // >20 dB down
}

test "f32ToI16 clamps instead of wrapping around" {
    // in-range: the same symmetric x*32767 scaling synth itself uses
    try testing.expectEqual(@as(i16, 32767), f32ToI16(1.0));
    try testing.expectEqual(@as(i16, -32767), f32ToI16(-1.0));
    try testing.expectEqual(@as(i16, 0), f32ToI16(0.0));
    // out of range: clamped, not wrapped (a wrap would turn a loud bar into
    // a loud click of the opposite sign)
    try testing.expectEqual(@as(i16, 32767), f32ToI16(4.0));
    try testing.expectEqual(@as(i16, -32768), f32ToI16(-4.0));
}

test "offline WAV is the synth WAV plus the session's fade-out, and nothing else" {
    const alloc = testing.allocator;
    const offline = try renderOfflineWav(alloc, "kujamba karibu", .{});
    defer alloc.free(offline);
    const direct = try synth.renderPhraseWav(alloc, "kujamba karibu");
    defer alloc.free(direct);
    try testing.expectEqual(direct.len, offline.len);

    const n = (offline.len - 44) / 2;
    const fade: usize = synth.SAMPLE_RATE * 8 / 1000; // the tail renderPhraseF32 fades
    const at = comptime std.mem.readInt;

    // Outside the fade tail the two are the same signal to within the f32
    // round-trip's 1 LSB. Anything larger would mean the offline path is
    // re-shaping audio rather than carrying it.
    for (0..n - fade) |k| {
        const x: i32 = at(i16, offline[44 + 2 * k ..][0..2], .little);
        const y: i32 = at(i16, direct[44 + 2 * k ..][0..2], .little);
        try testing.expect(@abs(x - y) <= 1);
    }

    // The tail is where they are meant to differ: renderPhraseF32 fades the
    // last 8 ms so loop wraps and interval tails do not click, and the synth's
    // own WAV has no fade.
    const last: i32 = at(i16, offline[offline.len - 2 ..][0..2], .little);
    try testing.expectEqual(0, last); // the fade reaches silence

    // How much quieter depends on where the phrase's energy sits inside the
    // fade window — mean magnitude is dominated by its loudest part, which for
    // this phrase lands where the ramp has barely started (measured 0.80). So
    // this asserts the fade is unambiguously there rather than pinning a number
    // that would move with any change to the voice tables.
    var offline_tail: i64 = 0;
    var direct_tail: i64 = 0;
    for (n - fade..n) |k| {
        offline_tail += @abs(at(i16, offline[44 + 2 * k ..][0..2], .little));
        direct_tail += @abs(at(i16, direct[44 + 2 * k ..][0..2], .little));
    }
    try testing.expect(offline_tail * 10 < direct_tail * 9);
}

// ---- loop seam (#17) ---------------------------------------------------------

test "loop mode wraps through zero: the seam is click-free with no crossfade (#17)" {
    const alloc = testing.allocator;
    // Why this test exists. #17 asked for a crossfade at the loop wrap. Measured,
    // the wrap is *already* perfectly click-free, because the phrase is zero at
    // *both* ends. That is the synth's own envelopes, not any crossfade: the
    // attack term `min(1, t/attack_s)` is 0 at t=0, and the decay term
    // `pow(1-u, 1.3)` is 0 at u=1, so the first and last i16 samples round to 0.
    // (I first assumed the 8 ms end fade in `renderPhraseF32` was what zeroed
    // the tail; mutating it away proved otherwise — removing that fade leaves
    // the tail at 0 regardless, because the synth has already zeroed it. The
    // render fade is belt-and-braces on top.) So the wrap is the one point in
    // the signal that is continuous through zero.
    //
    // A crossfade does not help — it makes it worse. It blends the (already
    // zero) tail into the head, so the loop ends mid-head and then jumps back to
    // head[0]: measured wrap step goes 0.000 (none) -> 0.080 (5 ms) -> 0.250
    // (2 ms), the last being larger than the biggest natural step in the file
    // (0.091). So this locks in the property instead of adding a feature that
    // would reintroduce the click #17 was meant to remove.
    //
    // This catches a broken attack envelope (the head stops starting at 0). It
    // does NOT catch removal of the 8 ms render fade, because the synth's decay
    // envelope keeps the tail at 0 either way — that case is covered by the
    // #19 test comparing the offline WAV against the direct synth WAV.
    //
    // It matters going forward: this invariant is the *only* reason `loop` mode
    // is seamless, and M6 (#15/#16/#17/#18) is about to reshape exactly the
    // voice tables and fades that create it. If one of those changes breaks the
    // zero-termination, this turns red instead of the seam going clicky in a
    // room where nobody is looking at a waveform.
    const phrases = [_][]const u8{ "kujamba karibu", "a", "mtu", "asante sana kijiji", "habari yako", "ng'oma" };
    for (phrases) |p| {
        const phrase = try renderPhraseF32(alloc, p);
        defer alloc.free(phrase);
        try testing.expect(phrase.len > 0);

        // the tail is faded to silence and the head starts from silence
        try testing.expectEqual(@as(f32, 0.0), phrase[phrase.len - 1]);
        try testing.expect(@abs(phrase[0]) < 1e-6);

        // ...which is exactly what makes the wrap step zero through `Fill`
        var fill = Fill{ .samples = phrase, .mode = .loop };
        const total = phrase.len * 2 + 1;
        const out = try alloc.alloc(f32, total);
        defer alloc.free(out);
        fill.copyInto(0, out);
        const wrap_step = @abs(out[phrase.len] - out[phrase.len - 1]);
        try testing.expect(wrap_step == 0.0);
    }
}
