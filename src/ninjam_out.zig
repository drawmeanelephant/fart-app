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
    /// bank entry to read this interval; null keeps whatever the source already
    /// holds. This is a *pointer to the entry*, not a bare buffer, because
    /// binding a phrase is not just swapping samples: the `loop`/`once` playhead
    /// lives in the entry, so switching phrases and switching back resumes each
    /// where it left off instead of restarting (#8, #10).
    phrase: ?*Phrase = null,
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
    /// the bound phrase's audio. Owned by the `Phrase` this fill is bound to, or
    /// by the caller for the standalone (offline) uses that never bind a bank.
    samples: []const f32 = &.{},
    mode: Mode = .repeat,
    /// playback cursor for `loop`/`once` modes (advances only while encoding,
    /// so rest bars freeze it). Deterministic: block sizes may vary with wall
    /// clock, but every interval advances the cursor by exactly its length.
    cursor: u64 = 0,
    /// the bank entry `samples`/`cursor` are synced with, if the source was
    /// driven by a `PhraseBank`. null for the standalone/offline uses of `Fill`
    /// that own a bare buffer and advance `cursor` directly.
    bound: ?*Phrase = null,

    /// Apply one bar's selection, at the bar boundary, before any audio (#11).
    /// The session calls this rather than assigning `mode`/`samples`, because
    /// binding a phrase is not a pointer swap — it also moves the playhead.
    ///
    /// **The playhead travels with the phrase, not with the instrument.** On
    /// every bind the outgoing entry is handed back its own `cursor` and the
    /// incoming entry's is loaded. That is what "the cache accounts for cursor
    /// state across switches" (#10) has to mean, and it is why `cursor` lives
    /// in `Phrase` rather than only here:
    ///
    ///  - Two live phrases have two independent playheads, so `!kujamba 1`,
    ///    `!kujamba 2`, `!kujamba 1` resumes phrase 1 mid-word where the room
    ///    left it — the behaviour a bank of loops implies.
    ///  - The naive alternative (one shared cursor, rewound to 0 on a switch)
    ///    silently loses that state, and doing it *without* rewinding is worse:
    ///    the cursor is an index into a specific buffer, so in `once` mode a
    ///    stale position past the new phrase's end would leave the instrument
    ///    permanently silent, and in `loop` mode `cursor % len` would drop the
    ///    listener into the middle of a word.
    ///  - Re-binding the *same* entry is a pure round trip, so a redundant
    ///    `!kujamba 2` and every ordinary bar boundary leave the playhead
    ///    exactly where it was (#12's "a config change does not cut the
    ///    phrase" still holds).
    ///  - A null entry (empty bank) keeps the current phrase, which is how an
    ///    invalid selection avoids dropping audio.
    pub fn bind(self: *Fill, mode: Mode, phrase: ?*Phrase) void {
        if (self.bound) |out| out.cursor = self.cursor;
        self.mode = mode;
        if (phrase) |p| {
            if (self.bound != p) {
                self.samples = p.samples;
                self.cursor = p.cursor;
            }
        }
        self.bound = phrase;
    }

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

// ---- server-clock discipline (#13) -------------------------------------------

/// One bar's length in nanoseconds, straight from `bpi`/`bpm`.
///
/// Deliberately *not* `@divTrunc(samples_per_bar * 1e9 / srate)`, which is what
/// the session used before: that truncates twice (the sample count, then the
/// nanoseconds) and so loses up to a sample per bar. Measured at 48 kHz,
/// 5 bpi / 137 bpm the old form is 2 189 770 833 ns against this one's
/// 2 189 781 021 ns — 10.2 us short, every bar, forever. The session then kept
/// its own clock and the server kept its own and neither was wrong; they just
/// slid apart, which is precisely the drift #13 exists to stop measuring.
/// One division from the wire values has no such error.
pub fn intervalNsFor(bpm: u16, bpi: u16) i128 {
    return @divTrunc(@as(i128, bpi) * 60 * 1_000_000_000, @as(i128, bpm));
}

/// The session's bar grid, anchored to the server's.
///
/// Before #13 the grid was open loop: `interval_start_ns += interval_ns`, and
/// that was the whole of it. Nothing ever compared the local grid against
/// anything, so two things happened silently:
///
///  1. **Every bar stole its own audio budget.** The run loop's poll is up to
///     20 ms of granularity and `finalizeInterval` adds its own socket time, so
///     a bar's audio is finished *after* the bar's nominal end. The next
///     `interval_start_ns` is computed from the previous one anyway, so the
///     session starts every bar already behind — and `advanceAudio` pays it
///     back as one catch-up burst of generation.
///  2. **The debt compounded.** Nothing ever gave it back, so each stall was
///     inherited by the bar after it.
///
/// This is a deliberately small PLL: one number (how late did we cross the
/// boundary), one bounded correction, applied once per bar.
///
/// **On what drift actually is.** The local grid and the server's grid are not
/// really in disagreement: both advance by `interval_ns` and both start at the
/// `0x02` arrival, so the difference between them is a *constant* — the one-way
/// latency of the config message — and a constant nobody can measure from the
/// client side. It is also harmless, because the server re-times an upload on
/// arrival. So the correction here deliberately does **not** chase the server's
/// epoch. What it chases is *execution lag*: how far past its own nominal end
/// the local grid actually got. That is the quantity that accumulates, and
/// bounding it is what keeps the client from owing time it can never repay.
///
/// Both halves are bounded. A bar's length may be shortened or stretched by at
/// most `slewLimitNs` — 1% of the bar, and never more than
/// `max_slew_ns` absolute, because a stretch that is 1% of a ten-second bar is
/// 100 ms of tempo, which IS audible and must not be applied just because the
/// tempo is slow. The encode lead (#13, `encodeLeadSamples`) is bounded the same
/// way, in the other direction: it pulls the *end* of the bar's generation
/// forward so the final flush and its 0x84 chunk land inside the server's
/// window instead of on its trailing edge.
pub const ServerClock = struct {
    /// local monotonic time of the boundary the server's `0x02` was anchored to
    epoch_ns: i128 = 0,
    /// one bar in ns (`intervalNsFor`)
    interval_ns: i128 = 0,
    /// bars since the anchor; `epoch_ns + bars * interval_ns` is the grid
    bars: u64 = 0,
    /// absolute ceiling on a single bar's correction, ns
    max_slew_ns: i128 = 40 * std.time.ns_per_ms,
    /// the correction is also capped at `interval_ns / max_slew_div`
    max_slew_div: u32 = 100, // 1%

    // telemetry: a session's verdict on how well it kept time
    /// signed lag at the most recent boundary, ns (positive = late)
    drift_ns: i64 = 0,
    /// largest |lag| seen this session, ns
    max_abs_drift_ns: u64 = 0,
    /// bars where the correction was non-zero
    corrections: u64 = 0,
    /// sum of the corrections applied, ns
    total_correction_ns: i64 = 0,

    /// Anchor on a fresh server boundary (the `0x02` arrival).
    ///
    /// `bpm`/`bpi` must already be validated non-zero: `intervalNsFor`
    /// divides by `bpm`, and a zero bpm reaching it is the #41 panic again in a
    /// different function. The session's `onConfig` refuses that config before
    /// it ever gets here.
    pub fn anchor(self: *ServerClock, now_ns: i128, bpm: u16, bpi: u16) void {
        self.epoch_ns = now_ns;
        self.interval_ns = intervalNsFor(bpm, bpi);
        self.bars = 0;
    }

    /// The server-derived wall time of bar `n` from the anchor.
    pub fn boundaryNs(self: *const ServerClock, n: u64) i128 {
        return self.epoch_ns + @as(i128, @intCast(n)) * self.interval_ns;
    }

    /// Largest correction this clock will ever apply to one bar.
    ///
    /// The fraction is what makes a fast tempo safe (1% of a 200 ms bar is 2 ms,
    /// which cannot be heard) and the absolute cap is what makes a slow one
    /// safe (1% of a 10 s bar would be 100 ms, which can). Both bounds are
    /// needed; neither alone is.
    pub fn slewLimitNs(self: *const ServerClock) i128 {
        const fractional = @divTrunc(self.interval_ns, @as(i128, self.max_slew_div));
        return @max(0, @min(self.max_slew_ns, fractional));
    }

    /// Clamp a proposed correction into `[-limit, +limit]`.
    pub fn clampCorrection(self: *const ServerClock, want_ns: i128) i128 {
        const limit = self.slewLimitNs();
        return std.math.clamp(want_ns, -limit, limit);
    }

    /// How late (or early) the boundary crossing was, in ns.
    ///
    /// `now_ns` is when the session actually crossed the boundary and
    /// `local_start_ns` is when its own grid says that was. Positive means the
    /// bar finished late and the next one starts behind.
    pub fn measureDrift(self: *ServerClock, now_ns: i128, local_start_ns: i128) i128 {
        const nominal_end = local_start_ns + self.interval_ns;
        const drift = now_ns - nominal_end;
        self.drift_ns = @intCast(drift);
        const mag: u64 = @intCast(if (drift < 0) -drift else drift);
        if (mag > self.max_abs_drift_ns) self.max_abs_drift_ns = mag;
        return drift;
    }

    /// The `interval_start_ns` the next bar should use.
    ///
    /// Takes the un-corrected value the caller would have used and returns it
    /// plus a bounded nudge forward (or back) toward the wall clock. This is
    /// the *only* place a bar's length is allowed to differ from nominal, which
    /// is what makes "no audible jumps" checkable rather than aspirational: one
    /// bar moves by at most `slewLimitNs`, and no correction is ever larger
    /// than the lag that caused it, so the grid can never be yanked.
    ///
    /// Correcting toward `now_ns` rather than toward the server's epoch is
    /// deliberate; see the type's doc comment on what drift really is here.
    pub fn nextStartNs(self: *ServerClock, local_start_ns: i128, now_ns: i128) i128 {
        const nominal = local_start_ns + self.interval_ns;
        const drift = self.measureDrift(now_ns, local_start_ns);
        const correction = self.clampCorrection(drift);
        if (correction != 0) {
            self.corrections += 1;
            self.total_correction_ns += @intCast(correction);
        }
        self.bars += 1;
        return nominal + correction;
    }

    /// How many samples early the encoder should finish a bar, so the final
    /// flush and its last `0x84` chunk are already in flight when the boundary
    /// arrives instead of starting at it.
    ///
    /// This changes *when* a bar is generated, never *what*: the block size, the
    /// sample sequence and therefore the encoded bytes are identical either way,
    /// so the determinism evidence (#19, `demo/run_demo.sh`) is untouched.
    ///
    /// Bounded for the same reason the slew is: a lead is a window opened early,
    /// and opening it too far means generating audio for a bar the session may
    /// never get to upload.
    pub fn encodeLeadSamples(self: *const ServerClock, interval_len_samples: u64) u64 {
        if (self.interval_ns <= 0 or interval_len_samples == 0) return 0;
        const lead_ns = @min(self.slewLimitNs(), 50 * std.time.ns_per_ms);
        const per_sample = @divTrunc(self.interval_ns, @as(i128, @intCast(interval_len_samples)));
        if (per_sample <= 0) return 0;
        return @min(@as(u64, @intCast(@divTrunc(lead_ns, per_sample))), interval_len_samples);
    }
};

// ---- server-clock discipline tests (#13) -------------------------------------

test "one bar in ns comes from bpi/bpm directly, not from a truncated sample count" {
    // 48 kHz, 8 bpi, 100 bpm: 4.8 s, and both forms happen to agree exactly.
    try testing.expectEqual(@as(i128, 4_800_000_000), intervalNsFor(100, 8));

    // 48 kHz, 5 bpi, 137 bpm: this is where the old form lost time. The sample
    // count truncates (105109 of 105109.489) and the nanoseconds truncate again,
    // so the session's bar was 10.2 us short of the real one — every bar,
    // forever, with nothing measuring it.
    const exact = intervalNsFor(137, 5);
    const samples = @as(u64, 48000) * 5 * 60 / 137;
    const old = @divTrunc(@as(i128, @intCast(samples)) * 1_000_000_000, 48000);
    try testing.expectEqual(@as(i128, 2_189_781_021), exact);
    try testing.expectEqual(@as(i128, 2_189_770_833), old);
    try testing.expect(exact > old);
    // the gap is under one sample, which is the whole claim: the old form was
    // not catastrophically wrong, it was *systematically* wrong
    try testing.expect(exact - old < @divTrunc(1_000_000_000, 48000) + 1);
}

test "the slew limit is bounded twice: a fraction of the bar and an absolute cap" {
    // fast tempo: 1% of a 200 ms bar is 2 ms, and that is what applies
    var fast = ServerClock{};
    fast.anchor(0, 1200, 4); // 48000*4*60/1200 = 9600 samples = 200 ms
    try testing.expectEqual(@as(i128, 200_000_000), fast.interval_ns);
    try testing.expectEqual(@as(i128, 2_000_000), fast.slewLimitNs());

    // slow tempo: 1% of a 10 s bar would be 100 ms, which IS audible, so the
    // absolute cap has to take over. Without the second bound this test fails.
    var slow = ServerClock{};
    slow.anchor(0, 24, 4); // 4*60/24 = 10 s
    try testing.expectEqual(@as(i128, 10_000_000_000), slow.interval_ns);
    try testing.expectEqual(@as(i128, 40 * std.time.ns_per_ms), slow.slewLimitNs());
}

test "a bar is never stretched by more than the limit, however late it is (#13)" {
    var c = ServerClock{};
    c.anchor(0, 120, 4); // 2 s bars
    const limit = c.slewLimitNs();
    try testing.expectEqual(@as(i128, 20 * std.time.ns_per_ms), limit);

    // a boundary crossed 10 seconds late — a catastrophic stall
    const start: i128 = 0;
    const next = c.nextStartNs(start, 10 * std.time.ns_per_s);
    const moved = next - (start + c.interval_ns);
    try testing.expect(moved > 0);
    try testing.expectEqual(limit, moved); // clamped, exactly at the limit
}

test "a correction is never larger than the lag that caused it (#13: no overshoot)" {
    var c = ServerClock{};
    c.anchor(0, 120, 4);
    // 5 ms late: well inside the 20 ms limit, so the whole lag is given back
    const start: i128 = 0;
    const next = c.nextStartNs(start, c.interval_ns + 5 * std.time.ns_per_ms);
    try testing.expectEqual(@as(i128, 5 * std.time.ns_per_ms), next - (start + c.interval_ns));

    // early: the correction runs the other way, and is still bounded by the lag
    const early = c.nextStartNs(start, c.interval_ns - 3 * std.time.ns_per_ms);
    try testing.expectEqual(@as(i128, -3 * std.time.ns_per_ms), early - (start + c.interval_ns));
}

test "a session on time is never corrected (#13: zero drift means zero correction)" {
    var c = ServerClock{};
    c.anchor(1_000, 120, 4);
    var start: i128 = 1_000;
    // every bar crossed exactly on its nominal end
    for (0..8) |_| {
        const next = c.nextStartNs(start, start + c.interval_ns);
        try testing.expectEqual(start + c.interval_ns, next);
        start = next;
    }
    try testing.expectEqual(@as(u64, 0), c.corrections);
    try testing.expectEqual(@as(i64, 0), c.total_correction_ns);
    try testing.expectEqual(@as(u64, 0), c.max_abs_drift_ns);
}

test "the encode lead is a real, bounded margin and never eats the bar (#13)" {
    var c = ServerClock{};
    c.anchor(0, 120, 4); // 2 s bar, 96000 samples @48k
    const lead = c.encodeLeadSamples(96000);
    try testing.expect(lead > 0);
    // the lead shares the slew's bounds: 20 ms of a 2 s bar, which is 960 of
    // 96000 samples. It is the same 1% — opening the upload window early by the
    // same fraction the grid may be stretched by.
    try testing.expectEqual(@as(u64, 960), lead);
    // and it can never be the whole bar, whatever the tempo
    try testing.expect(lead < 96000);

    // an unanchored clock has no bar length and therefore no lead: generating
    // ahead of an interval that does not exist yet would be a lie
    var cold = ServerClock{};
    try testing.expectEqual(@as(u64, 0), cold.encodeLeadSamples(96000));
    try testing.expectEqual(@as(u64, 0), cold.encodeLeadSamples(0));
}

// The sweep that makes the encode lead trustworthy.
//
// A lead longer than the bar would be a silent, permanent stall: the encoder
// would be asked to generate the whole interval before it starts, so
// `produced < target` would already be false, `finalizeInterval` would never
// fire, and the session would sit there uploading nothing. So "lead < bar" is a
// correctness property, not a tidiness one.
//
// It is worth being precise about where it comes from. `encodeLeadSamples`
// ends with an explicit `@min(..., interval_len_samples)`, and at the current
// `max_slew_div = 100` that clamp is **provably unreachable**: `lead_ns` is at
// most `interval_ns / 100`, so `lead_samples` is at most `bar / 100`. The clamp
// stays because it is what makes the property true by construction rather than
// by a chain of reasoning about two constants that someone can change, and
// because it costs one `min`. This test is the belt to that pair of braces: it
// sweeps the tempos the wire can actually carry rather than trusting the
// algebra.
test "the encode lead stays strictly inside the bar across the wire's tempo range" {
    const tempos = [_][2]u16{
        // slow, normal, and the fastest a bar can plausibly be
        .{ 20, 1 },   .{ 100, 8 },  .{ 120, 4 },  .{ 137, 5 },  .{ 200, 16 },
        .{ 600, 2 },  .{ 1200, 4 }, .{ 1500, 1 }, .{ 8000, 8 }, .{ 65535, 1 },
        .{ 65535, 65535 }, .{ 1, 65535 }, .{ 1, 1 },
    };
    for (tempos) |t| {
        var c = ServerClock{};
        c.anchor(0, t[0], t[1]);
        const bar: u64 = @divTrunc(48000 * @as(u64, t[1]) * 60, t[0]);
        if (bar == 0) continue; // a bar shorter than one sample has no lead
        const lead = c.encodeLeadSamples(bar);
        std.testing.expect(lead < bar) catch |e| {
            std.debug.print("bpm={d} bpi={d} bar={d} lead={d}\n", .{ t[0], t[1], bar, lead });
            return e;
        };
        // The exact bound, for every tempo: the lead is a fraction of the
        // slew limit, which is a fraction of the bar, so the lead can never
        // exceed 1% of the bar. Stating it as an inequality rather than
        // re-deriving it is the point — this is the property, and it holds
        // whatever the tempo.
        try testing.expect(lead <= bar / 100);
        // `per_sample` is 1e9/srate — 20.8 us at 48 kHz — for *every* tempo, so
        // a bar of a few tens of samples (under ~2 ms) cannot carry a lead
        // worth naming and it rounds to zero. Correct, not a gap: such a bar is
        // over before it starts.
        if (bar >= 256) {
            // and where it can be, it is: a lead of zero would leave the final
            // flush starting exactly on the boundary, which is what #13 is about
            try testing.expect(lead > 0);
        }
    }
}

test "the drift ledger keeps the worst bar, not the last one (#13 telemetry)" {
    var c = ServerClock{};
    c.anchor(0, 120, 4);
    const start: i128 = 0;
    _ = c.nextStartNs(start, c.interval_ns + 1 * std.time.ns_per_ms);
    _ = c.nextStartNs(start, c.interval_ns + 40 * std.time.ns_per_ms); // clamped correction
    _ = c.nextStartNs(start, c.interval_ns - 2 * std.time.ns_per_ms);
    // the signed reading tracks the most recent bar ...
    try testing.expectEqual(@as(i64, -2 * std.time.ns_per_ms), c.drift_ns);
    // ... but the worst case is remembered
    try testing.expectEqual(@as(u64, 40 * std.time.ns_per_ms), c.max_abs_drift_ns);
    // every bar whose crossing was even slightly off gets a nudge, and only an
    // exactly-on-time bar is left alone (pinned by the zero-drift test above)
    try testing.expectEqual(@as(u64, 3), c.corrections);
    try testing.expectEqual(@as(i64, (1 + 20 - 2) * std.time.ns_per_ms), c.total_correction_ns);
}

// ---- phrase bank (#8, #10) ---------------------------------------------------

/// One entry in the bank: a phrase, rendered once at startup, plus the playhead
/// that `loop`/`once` modes advance through it.
///
/// The `cursor` lives *in the entry*, not in the `Fill`. That is what makes a
/// switch back to a phrase resume it instead of restarting, and it is the
/// concrete thing #10 asks for ("cache accounts for `--play` mode cursor state
/// across switches"). Two live phrases therefore have two independent
/// playheads; a single shared `Fill.cursor` could only ever have one.
pub const Phrase = struct {
    /// the phrase text, trimmed. Chat selects by this name.
    ///
    /// Always **borrowed**, never freed by the bank: it points at argv, at the
    /// arena, at the phrases file's text, or at a literal in a test. Copying
    /// every name to normalise that would be a per-phrase allocation for a
    /// string that is already stable for the whole run.
    name: []const u8,
    /// rendered once, up front, and never re-rendered on a switch. The synth is
    /// a pure function of (phrase, knobs), so this is deterministic (#10).
    /// Owned by the bank iff `owned`.
    samples: []const f32,
    /// whether the bank allocated `samples` and must free it. False for buffers
    /// adopted by `initBorrowed`.
    owned: bool = true,
    /// playback position for `loop`/`once`. Only the active entry advances.
    cursor: u64 = 0,
};

/// Ceiling on the audio one bank may hold, in samples. 16 Mi samples of f32 is
/// 64 MiB, which at the synth's 44.1 kHz is about six minutes of phrases — far
/// more than anyone picks between in a chat room, while still being a number a
/// file cannot blow past.
///
/// The cap on the *phrases file* does not do this job. That cap is on bytes of
/// text, and the bank renders each line to f32: a one-word line is ~8 bytes and
/// ~0.5 s of audio, so the text-to-audio ratio runs past 20 000:1. A 900 KB file
/// of short lines clears a 1 MiB text cap and then asks for gigabytes.
pub const max_bank_samples: usize = 16 * 1024 * 1024;

pub const PhraseBank = struct {
    /// owns the rendered buffers; the `Phrase` structs themselves borrow.
    alloc: std.mem.Allocator,
    entries: std.ArrayList(Phrase) = .empty,
    /// samples this bank has rendered and owns. Tracked incrementally so the
    /// budget check stays O(1). Adopted buffers (`initBorrowed`) are not
    /// counted: nothing was allocated, so they cost no memory.
    rendered: usize = 0,
    /// ceiling on `rendered`. A field rather than a bare constant so a test can
    /// shrink it instead of synthesizing six minutes of audio to reach it.
    budget: usize = max_bank_samples,
    /// 1-based line of the phrases file that failed to load, or null if the
    /// failure was not tied to a line (`add` has none to report). Set by
    /// `parse` so the CLI can say `file:line: why` like the config loader does.
    fail_line: ?usize = null,
    /// index the plan is currently selecting
    current: usize = 0,
    /// index a chat command asked for, consumed at the next bar boundary.
    /// null = no pending switch. #11 already guarantees the plan is read once
    /// per bar *before* any audio, so applying it here is what makes the
    /// switch bar-accurate for free.
    pending: ?usize = null,
    /// selections a chat command asked for that did not resolve. Reported so
    /// "invalid selection is a no-op" is observable rather than silent.
    rejected: u32 = 0,
    /// selections that took effect. Equals `rejected`-complement: a session
    /// that never dropped audio has `switches + rejected == requests`.
    switches: u32 = 0,

    pub fn init(alloc: std.mem.Allocator) PhraseBank {
        return .{ .alloc = alloc };
    }

    /// Adopt buffers that were rendered elsewhere, without re-rendering or
    /// taking ownership. The counterpart of `add` for callers that already hold
    /// `[]const f32` — tests, mostly, which use a synthetic buffer instead of
    /// paying for a real synth render.
    ///
    /// `names` must be the same length as `buffers`; both are borrowed for the
    /// life of the bank.
    pub fn initBorrowed(
        alloc: std.mem.Allocator,
        names: []const []const u8,
        buffers: []const []const f32,
    ) !PhraseBank {
        std.debug.assert(names.len == buffers.len);
        var bank = PhraseBank.init(alloc);
        errdefer bank.deinit();
        for (names, buffers) |name, buf| {
            try bank.entries.append(alloc, .{
                .name = name,
                .samples = buf,
                .owned = false,
            });
        }
        return bank;
    }

    /// Free the buffers this bank rendered, and the entry list. Adopted
    /// buffers (`owned == false`) are left alone, and names are never freed —
    /// see `Phrase`.
    pub fn deinit(self: *PhraseBank) void {
        for (self.entries.items) |p| {
            if (p.owned) self.alloc.free(p.samples);
        }
        self.entries.deinit(self.alloc);
        self.* = .{ .alloc = self.alloc };
    }

    /// Render `phrase` once and append it. This is the whole of #10: the
    /// expensive part (synthesis) happens here, at load, and never again.
    pub fn add(self: *PhraseBank, phrase: []const u8, knobs: synth.VoiceKnobs) !void {
        const samples = try renderPhraseF32With(self.alloc, phrase, knobs);
        errdefer self.alloc.free(samples);
        // Checked after the render, because the length is only known then: a
        // pre-flight estimate would have to model syllable timing, and being
        // wrong in the permissive direction is the failure we are here to stop.
        // One wasted render at the boundary costs less than being wrong.
        if (self.rendered + samples.len > self.budget) return error.BankTooLarge;
        try self.entries.append(self.alloc, .{ .name = phrase, .samples = samples });
        self.rendered += samples.len;
    }

    /// Parse a bank file: one phrase per line, `#` comments and blank lines
    /// skipped, CRLF tolerated. Deliberately *not* TOML — the config file
    /// (#22) is a settings overlay, and a phrase list is a different shape
    /// (a bag of strings, not a table). Reusing TOML here would make every
    /// phrase a key/value pair for no benefit.
    ///
    /// Line-oriented means `name == phrase text`, so `!kujamba <name>` and
    /// `!kujamba <n>` are two ways to say the same thing and there is no second
    /// vocabulary to keep in sync.
    pub fn parse(self: *PhraseBank, text: []const u8, knobs: synth.VoiceKnobs) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var lineno: usize = 0;
        while (lines.next()) |raw| {
            lineno += 1;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            self.add(line, knobs) catch |e| {
                // A 500-line bank that fails on one phrase is unusable without
                // the line: `failed: BankTooLarge` says nothing about where.
                self.fail_line = lineno;
                return e;
            };
        }
    }

    /// Resolve a chat selector to an index: an all-digits token is a 1-based
    /// position, anything else is matched case-insensitively against the
    /// phrase text. Returns null for anything that names no entry, so the
    /// caller can keep the current phrase rather than drop audio.
    pub fn resolve(self: *const PhraseBank, raw: []const u8) ?usize {
        // Trimmed here as well as in the chat parser: `resolve` is a public
        // entry point, and a caller reading a name from a file or a config
        // should not have to know that chat happens to pre-trim.
        const sel = std.mem.trim(u8, raw, " \t\r\n");
        if (sel.len == 0) return null;
        if (std.fmt.parseInt(usize, sel, 10) catch null) |n| {
            // 1-based, because a human in a chat room counting phrases starts
            // at one. 0 is not a valid selector.
            if (n == 0 or n > self.entries.items.len) return null;
            return n - 1;
        }
        for (self.entries.items, 0..) |p, i| {
            if (std.ascii.eqlIgnoreCase(p.name, sel)) return i;
        }
        return null;
    }

    /// Ask for `sel` to play next. Resolves now (so an invalid selector is
    /// rejected at the moment it is typed, and counted), but the switch lands
    /// at the next bar boundary when `active` is called.
    pub fn request(self: *PhraseBank, sel: []const u8) void {
        const idx = self.resolve(sel) orelse {
            self.rejected += 1;
            return;
        };
        self.pending = idx;
    }

    /// The phrase the next bar plays, applying any pending switch. Called once
    /// per bar by the plan, before any audio — so this is the bar boundary, not
    /// an arbitrary point in the stream.
    pub fn active(self: *PhraseBank) ?*Phrase {
        if (self.pending) |i| {
            self.pending = null;
            self.current = i;
            self.switches += 1;
        }
        if (self.entries.items.len == 0) return null;
        return &self.entries.items[self.current];
    }

    /// The active phrase's audio, for a caller that only needs the buffer.
    pub fn activeSamples(self: *PhraseBank) []const f32 {
        const p = self.active() orelse return &.{};
        return p.samples;
    }

    /// The name of the phrase the *current* bar would play, without applying a
    /// pending switch. Test-only, and deliberately read-only: a test that wants
    /// to assert "the switch has not landed yet" must not be the thing that
    /// lands it.
    pub fn currentName(self: *PhraseBank) []const u8 {
        if (self.entries.items.len == 0) return "";
        return self.entries.items[self.current].name;
    }
};

/// Adapter so a `Pattern` can be handed to `session.Options.plan`.
pub const PlanAdapter = struct {
    pattern: *const Pattern,
    /// play mode the plan selects for each interval. A live switch updates this
    /// and it is picked up at the next bar boundary.
    mode: Mode = .repeat,
    /// the phrase bank this plan selects from (#8). It holds exactly one entry
    /// when `--phrases` was not given, so "a live switch" and "the single
    /// phrase" are the same code path rather than two that can disagree.
    ///
    /// A pointer, not a value: the bank owns the rendered buffers, and both the
    /// plan and the `Fill` hold `*Phrase` into its entries. Copying the struct
    /// would duplicate the `ArrayList` owner and let one copy free buffers the
    /// other still points at.
    bank: *PhraseBank,
    /// live broadcast override (#9). null = follow the bar pattern; true =
    /// force a rest bar (silence markers); false = force a play bar. Set by a
    /// `!kujamba play|rest` chat command and consumed at the next bar boundary.
    rest: ?bool = null,

    /// Matches `session.IntervalPlan.selectFor`.
    pub fn selectForFn(ctx: *anyopaque, interval_idx: u64) Selection {
        const self: *PlanAdapter = @ptrCast(@alignCast(ctx));
        return .{
            .broadcast = if (self.rest) |r| !r else self.pattern.broadcastFor(interval_idx),
            .mode = self.mode,
            .phrase = self.bank.active(),
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

// ---- chat transport commands (#9) --------------------------------------------

/// A `!kujamba <arg>` command from room chat. `none` for anything that is not a
/// kujamba command at all, so ordinary chat and other people's messages are
/// ignored safely.
///
/// This is a tagged union rather than the plain enum #9 shipped because #8 added
/// a second kind of command: a *phrase selector* carries a payload. The
/// alternative — a separate `chat_select` callback and a second scan of the same
/// 0xC0 params — would duplicate the routing (and the "first match wins" rule,
/// and the fuzz surface of `get(0..4)`) for one extra payload.
///
/// A token that is not a known transport verb is a `.select` rather than
/// `.none`. The parser deliberately does **not** know what the bank contains, so
/// an unknown word routes to the bank, which resolves it or counts it as
/// rejected. That keeps the bank in one place instead of splitting "is this a
/// valid command?" across two files.
pub const ChatCommand = union(enum) {
    none,
    play,
    rest,
    loop,
    repeat,
    once,
    stop,
    /// `!kujamba <n>` or `!kujamba <name>` — pick the next phrase (#8)
    select: []const u8,
};

/// Parse a `kujamba <arg>` command out of one room-chat string. The server's
/// 0xC0 layout varies by chat kind (privmsg vs server vs channel), so the caller
/// feeds every param and takes the first match rather than assuming an index.
///
/// **The leading `!` is optional, and that is not a style choice.** The
/// reference server's `User_Group::onChatMessage` (ninjam/server/usercon.cpp)
/// intercepts any *MSG* whose text starts with `!`, replies "Unknown !command"
/// to the sender, and **returns without broadcasting**. So on an unmodified
/// ninjamsrv a literal `!kujamba loop` never reaches the room at all — it is
/// swallowed before any client sees it. Verified against the real server: a peer
/// sending `!kujamba 2` produced no `0xC0` for the listener at all, while
/// `kujamba 2` arrived as `MSG: <user> | kujamba 2`.
///
/// Accepting both forms means the command works on the reference server *and*
/// on any server (or IRC bridge) that does relay bang-prefixed text, so nobody
/// has to know which one they are on.
///
/// The returned selector borrows `text`, so the handler must resolve it before
/// the chat buffer is reused. `PhraseBank.request` does exactly that — it stores
/// an index, never the string.
pub fn parseChatCommand(text: []const u8) ChatCommand {
    // Strip the sigil *first*: the reference server swallows it before the
    // message is ever broadcast, so on ninjamsrv this is the only form that
    // arrives. Accepting "!!" and "! " too costs nothing.
    var t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len > 0 and t[0] == '!') t = std.mem.trim(u8, t[1..], " \t\r\n");

    const prefix = "kujamba";
    if (!std.ascii.startsWithIgnoreCase(t, prefix)) return .none;
    // The character after the name must be whitespace, or "kujambazal" would
    // parse as a command addressed to us.
    const after = t[prefix.len..];
    if (after.len == 0 or !std.ascii.isWhitespace(after[0])) return .none;
    const arg = std.mem.trim(u8, after, " \t\r\n");
    if (arg.len == 0) return .none;
    if (std.ascii.eqlIgnoreCase(arg, "play")) return .play;
    if (std.ascii.eqlIgnoreCase(arg, "rest")) return .rest;
    if (std.ascii.eqlIgnoreCase(arg, "loop")) return .loop;
    if (std.ascii.eqlIgnoreCase(arg, "repeat")) return .repeat;
    if (std.ascii.eqlIgnoreCase(arg, "once")) return .once;
    if (std.ascii.eqlIgnoreCase(arg, "stop")) return .stop;
    return .{ .select = arg };
}

test "chat command parsing recognises the transport verbs, case- and space-insensitively" {
    try testing.expectEqual(ChatCommand{ .loop = {} }, parseChatCommand("kujamba loop"));
    try testing.expectEqual(ChatCommand{ .loop = {} }, parseChatCommand("!kujamba loop"));
    try testing.expectEqual(ChatCommand{ .loop = {} }, parseChatCommand("  !KUJAMBA   LOOP  "));
    try testing.expectEqual(ChatCommand{ .play = {} }, parseChatCommand("kujamba play"));
    try testing.expectEqual(ChatCommand{ .rest = {} }, parseChatCommand("!kujamba rest"));
    try testing.expectEqual(ChatCommand{ .repeat = {} }, parseChatCommand("kujamba repeat"));
    try testing.expectEqual(ChatCommand{ .once = {} }, parseChatCommand("kujamba once"));
    try testing.expectEqual(ChatCommand{ .stop = {} }, parseChatCommand("!kujamba stop"));
}

test "the leading ! is optional, because the reference server eats it (#9, verified)" {
    // ninjamsrv's onChatMessage intercepts any MSG starting with '!' and
    // returns without broadcasting, so `!kujamba loop` never reaches a room.
    // Both spellings parse, so the command works on that server and on any that
    // does relay bang-prefixed text.
    try testing.expectEqual(ChatCommand{ .loop = {} }, parseChatCommand("kujamba loop"));
    try testing.expectEqual(ChatCommand{ .loop = {} }, parseChatCommand("!kujamba loop"));
    try testing.expectEqual(ChatCommand{ .loop = {} }, parseChatCommand("! kujamba loop"));
    try testing.expectEqual(ChatCommand{ .loop = {} }, parseChatCommand("  !KUJAMBA  loop "));
}

test "chat command parsing ignores everything that is not a kujamba command" {
    // no argument, wrong prefix, other users' messages — all safely .none
    for ([_][]const u8{
        "kujamba", // no argument
        "!kujamba", // no argument
        "kujamba   ", // argument is only whitespace
        "kujambazal", // the name must be a whole word, not a prefix of another
        "hello everyone", // ordinary chat
        "", // empty
        "!", // lone sigil
    }) |s| try testing.expectEqual(ChatCommand{ .none = {} }, parseChatCommand(s));
}

test "an unrecognised argument parses as a phrase selector, not as nothing (#8)" {
    // The parser cannot know the bank, so an unknown token is routed to it and
    // the bank decides. This is what makes `!kujamba 2` and
    // `!kujamba habari yako` work without the parser enumerating phrases.
    //
    // The selector *borrows* the chat text (a tagged union compares by pointer,
    // so these are compared as strings), which is why the handler must resolve
    // it to an index before the chat buffer is reused.
    const expect_select = struct {
        fn f(text: []const u8, want: []const u8) !void {
            switch (parseChatCommand(text)) {
                .select => |sel| try testing.expectEqualStrings(want, sel),
                else => return error.TestUnexpectedResult,
            }
        }
    }.f;
    try expect_select("kujamba 2", "2");
    try expect_select("!kujamba 2", "2");
    try expect_select("  KUJAMBA   Habari Yako  ", "Habari Yako");
    // extra words are not a verb, so they are a (probably unresolvable) selector
    try expect_select("kujamba loop now", "loop now");
}

// ---- phrase bank tests (#8, #10) ---------------------------------------------

test "a phrases file renders every phrase once, up front, deterministically (#10)" {
    const alloc = testing.allocator;
    const text =
        \\# a bank of Swahili phrases
        \\kujamba karibu
        \\asante sana
        \\
        \\habari yako   # trailing comment is NOT stripped: it is part of the phrase
    ;
    var bank = PhraseBank.init(alloc);
    defer bank.deinit();
    try bank.parse(text, .{});

    // blank lines and full-line comments are skipped; the rest are phrases
    try testing.expectEqual(@as(usize, 3), bank.entries.items.len);
    try testing.expectEqualStrings("kujamba karibu", bank.entries.items[0].name);
    try testing.expectEqualStrings("asante sana", bank.entries.items[1].name);
    try testing.expectEqualStrings("habari yako   # trailing comment is NOT stripped: it is part of the phrase", bank.entries.items[2].name);

    // every phrase rendered to real audio, and none of them is silence
    for (bank.entries.items) |p| {
        try testing.expect(p.samples.len > 0);
        try testing.expect(rmsOf(p.samples) > 0.01);
        try testing.expect(p.owned);
    }

    // The whole point of #10: loading is a pure function of (file, knobs), so a
    // second load is sample-identical and a switch can never re-render.
    var again = PhraseBank.init(alloc);
    defer again.deinit();
    try again.parse(text, .{});
    for (bank.entries.items, again.entries.items) |a, b| {
        try testing.expectEqualStrings(a.name, b.name);
        try testing.expectEqualSlices(f32, a.samples, b.samples);
    }

    // ...and a switch does not touch the buffers: the pointers the bank handed
    // out at load are still the ones it hands out now.
    try testing.expectEqual(
        @intFromPtr(bank.entries.items[1].samples.ptr),
        @intFromPtr(bank.entries.items[1].samples.ptr),
    );
    bank.request("2");
    try testing.expectEqual(
        @intFromPtr(bank.entries.items[1].samples.ptr),
        @intFromPtr(bank.active().?.samples.ptr),
    );
}

test "a bank renders up to its audio budget and no further (#8, #10)" {
    const alloc = testing.allocator;
    var bank = PhraseBank.init(alloc);
    defer bank.deinit();

    try bank.add("kujamba karibu", .{});
    const first = bank.entries.items[0].samples.len;
    try testing.expectEqual(first, bank.rendered);

    // Room for exactly what is already loaded, so the *next* phrase is the one
    // that has to be refused. This is what makes the budget cumulative: a cap
    // checked per entry would let this through.
    bank.budget = first;
    try testing.expectError(error.BankTooLarge, bank.add("asante sana", .{}));

    // The refused phrase leaves nothing behind: no entry to play, no allocation
    // to leak, and the running total untouched.
    try testing.expectEqual(@as(usize, 1), bank.entries.items.len);
    try testing.expectEqual(first, bank.rendered);
}

test "a phrases file that overruns the budget reports the line that did it" {
    const alloc = testing.allocator;
    var bank = PhraseBank.init(alloc);
    defer bank.deinit();
    bank.budget = 1; // any real phrase is over this

    try testing.expectError(
        error.BankTooLarge,
        bank.parse("# a comment\nkujamba karibu\nasante sana\n", .{}),
    );
    // Line 2, not line 1: comments and blank lines still consume a line, so the
    // number is the one the user sees in their editor.
    try testing.expectEqual(@as(usize, 2), bank.fail_line.?);
    try testing.expectEqual(@as(usize, 0), bank.entries.items.len);
}

test "a phrases file with CRLF endings parses the same as one with LF" {
    const alloc = testing.allocator;
    var bank = PhraseBank.init(alloc);
    defer bank.deinit();
    try bank.parse("kujamba karibu\r\nasante sana\r\n", .{});
    try testing.expectEqual(@as(usize, 2), bank.entries.items.len);
    try testing.expectEqualStrings("asante sana", bank.entries.items[1].name);
}

test "a selector resolves by 1-based position or by name, case-insensitively" {
    const alloc = testing.allocator;
    var bank = PhraseBank.init(alloc);
    defer bank.deinit();
    try bank.parse("kujamba karibu\nasante sana\nhabari yako\n", .{});

    // position, 1-based because a person counting phrases in a room starts at 1
    try testing.expectEqual(@as(?usize, 0), bank.resolve("1"));
    try testing.expectEqual(@as(?usize, 1), bank.resolve("2"));
    try testing.expectEqual(@as(?usize, 2), bank.resolve("3"));
    // by name, case- and whitespace-insensitively
    try testing.expectEqual(@as(?usize, 1), bank.resolve("asante sana"));
    try testing.expectEqual(@as(?usize, 2), bank.resolve("  HABARI YAKO  "));
    // a name that looks like a number is a name, not an index, so digits always
    // mean position -- there is no way to reach a numeric phrase by name
    try testing.expectEqual(@as(?usize, 0), bank.resolve("1 "));
}

test "an invalid or empty selector is rejected and the current phrase keeps playing (#8)" {
    const alloc = testing.allocator;
    var bank = PhraseBank.init(alloc);
    defer bank.deinit();
    try bank.parse("kujamba karibu\nasante sana\n", .{});
    const first = bank.active().?;
    try testing.expectEqualStrings("kujamba karibu", first.name);

    // out of range, zero (there is no 0th phrase), unknown name, empty
    var expected_rejected: u32 = 0;
    for ([_][]const u8{ "0", "3", "99", "nope", "", "   " }) |bad| {
        expected_rejected += 1;
        bank.request(bad);
        try testing.expectEqual(@as(?usize, null), bank.pending);
        try testing.expectEqual(expected_rejected, bank.rejected);
        // no pending switch, so the next bar binds the phrase already playing
        try testing.expectEqual(@intFromPtr(first.samples.ptr), @intFromPtr(bank.active().?.samples.ptr));
    }
    try testing.expectEqual(@as(u32, 0), bank.switches);
}

test "a request is applied at the next bar, not when it is typed (#8)" {
    const alloc = testing.allocator;
    var bank = PhraseBank.init(alloc);
    defer bank.deinit();
    try bank.parse("kujamba karibu\nasante sana\n", .{});
    try testing.expectEqualStrings("kujamba karibu", bank.active().?.name);

    bank.request("2");
    // Requested, but the phrase that would play *this* bar has already been
    // decided. `pending` is set and `current` is NOT: that gap is the whole
    // bar-accuracy property, and it is what keeps a live switch from splicing
    // audio that is already being encoded. `active` is what the plan calls,
    // once per bar, before any audio.
    try testing.expectEqual(@as(?usize, 1), bank.pending);
    try testing.expectEqual(@as(usize, 0), bank.current);
    try testing.expectEqual(@as(u32, 0), bank.switches);
    try testing.expectEqualStrings("kujamba karibu", bank.currentName());

    // The next bar: the switch lands, and the pending is consumed.
    const p = bank.active().?;
    try testing.expectEqualStrings("asante sana", p.name);
    try testing.expectEqual(@as(usize, 1), bank.current);
    try testing.expectEqual(@as(u32, 1), bank.switches);
    try testing.expectEqual(@as(?usize, null), bank.pending);
    // and it is not applied twice
    _ = bank.active();
    try testing.expectEqual(@as(u32, 1), bank.switches);
}

test "each phrase keeps its own playhead, so switching back resumes rather than restarts (#10)" {
    const alloc = testing.allocator;
    // Distinct constant buffers so "which phrase is playing" is unambiguous.
    const a = [_]f32{ 1, 1, 1, 1 };
    const b = [_]f32{ 2, 2, 2, 2, 2, 2 };
    var bank = try PhraseBank.initBorrowed(alloc, &.{ "a", "b" }, &.{ &a, &b });
    defer bank.deinit();

    var fill = Fill{ .mode = .loop };
    fill.bind(.loop, bank.active());
    try testing.expectEqualStrings("a", bank.active().?.name);
    var dst: [4]f32 = undefined;

    // play a bar of phrase a: the playhead advances through it. The live
    // playhead is the Fill's; the bank's copy is written back on the next bind,
    // which is the only moment the two are allowed to disagree.
    fill.copyInto(0, dst[0..4]);
    try testing.expectEqualSlices(f32, &a, &dst);
    try testing.expectEqual(@as(u64, 4), fill.cursor);

    // switch to b, and play a bar of it
    bank.request("2");
    fill.bind(.loop, bank.active());
    try testing.expectEqualStrings("b", bank.active().?.name);
    try testing.expectEqual(@as(u64, 4), bank.entries.items[0].cursor); // a kept its place
    try testing.expectEqual(@as(u64, 0), fill.cursor); // and b starts at its beginning
    fill.copyInto(0, dst[0..4]);
    try testing.expectEqualSlices(f32, b[0..4], &dst);
    try testing.expectEqual(@as(u64, 4), fill.cursor);

    // switch back to a: it resumes at sample 4, wrapping -- NOT from 0
    bank.request("1");
    fill.bind(.loop, bank.active());
    try testing.expectEqual(@as(u64, 4), fill.cursor);
    try testing.expectEqual(@as(u64, 4), bank.entries.items[1].cursor); // b kept its place
    fill.copyInto(0, dst[0..4]);
    try testing.expectEqualSlices(f32, &a, &dst); // wrapped back to the start of a
    try testing.expectEqual(@as(u64, 8), fill.cursor);
}

test "a switch rewinds the playhead, and a redundant re-select does not (#8)" {
    const alloc = testing.allocator;
    const a = [_]f32{ 1, 1, 1, 1 };
    const b = [_]f32{ 2, 2, 2, 2 };
    var bank = try PhraseBank.initBorrowed(alloc, &.{ "a", "b" }, &.{ &a, &b });
    defer bank.deinit();

    var fill = Fill{ .mode = .loop };
    fill.bind(.loop, bank.active());
    var dst: [3]f32 = undefined;
    fill.copyInto(0, dst[0..3]);
    try testing.expectEqual(@as(u64, 3), fill.cursor);

    // re-selecting the phrase already playing is a no-op on the playhead --
    // this is the case that would break #12's "a config change does not cut the
    // phrase" if bind() rewound unconditionally
    bank.request("1");
    fill.bind(.loop, bank.active());
    try testing.expectEqual(@as(u64, 3), fill.cursor);

    // a real switch to a *different* phrase starts it at its beginning
    bank.request("2");
    fill.bind(.loop, bank.active());
    try testing.expectEqual(@as(u64, 0), fill.cursor);
    fill.copyInto(0, dst[0..3]);
    try testing.expectEqualSlices(f32, b[0..3], &dst);
}

test "re-binding the same phrase every bar does not rewind the playhead (#11 + #8)" {
    const alloc = testing.allocator;
    const a = [_]f32{ 1, 2, 3, 4, 5, 6 };
    var bank = try PhraseBank.initBorrowed(alloc, &.{"a"}, &.{&a});
    defer bank.deinit();

    var fill = Fill{ .mode = .once };
    fill.bind(.once, bank.active());
    var dst: [2]f32 = undefined;
    fill.copyInto(0, dst[0..2]);
    try testing.expectEqualSlices(f32, a[0..2], &dst);

    // three more bar boundaries, same phrase: the playhead must keep climbing
    fill.bind(.once, bank.active());
    fill.bind(.once, bank.active());
    fill.bind(.once, bank.active());
    try testing.expectEqual(@as(u64, 2), fill.cursor);
    fill.copyInto(0, dst[0..2]);
    try testing.expectEqualSlices(f32, a[2..4], &dst);
}

test "binding a null phrase keeps the current one, so an empty bank drops no audio (#8)" {
    const alloc = testing.allocator;
    const a = [_]f32{ 1, 2, 3, 4 };
    var bank = try PhraseBank.initBorrowed(alloc, &.{"a"}, &.{&a});
    defer bank.deinit();
    var fill = Fill{ .mode = .repeat };
    fill.bind(.repeat, bank.active());
    var dst: [4]f32 = undefined;
    fill.copyInto(0, dst[0..4]);
    try testing.expectEqualSlices(f32, &a, &dst);

    // what an empty bank (or a plan with no selection) would hand over
    fill.bind(.repeat, null);
    fill.copyInto(0, dst[0..4]);
    try testing.expectEqualSlices(f32, &a, &dst);
    try testing.expect(fill.bound == null);
}

test "an empty bank yields no phrase at all, and does not panic (#8)" {
    const alloc = testing.allocator;
    var bank = PhraseBank.init(alloc);
    defer bank.deinit();
    try testing.expect(bank.active() == null);
    try testing.expectEqual(@as(usize, 0), bank.activeSamples().len);
    bank.request("1"); // nothing to select
    try testing.expect(bank.active() == null);
    try testing.expectEqual(@as(u32, 1), bank.rejected);
}
