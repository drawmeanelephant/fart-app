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
//!    (seed, interval index, channel index), so two runs with the same seed
//!    produce byte-identical uploaded payloads (the libvorbis stream serial
//!    lives inside the encoded bytes and must therefore be pinned).

const std = @import("std");
const synth = @import("synth.zig");

/// Session-source adapter over a pre-rendered mono phrase (f32, ±1.0).
pub const Fill = struct {
    samples: []const f32,

    /// Copy the slice [offset, offset+dst.len) of the phrase into `dst`,
    /// zero-padding past the end of the phrase (the tail of the interval).
    pub fn copyInto(self: *const Fill, offset: u64, dst: []f32) void {
        const n: u64 = self.samples.len;
        for (dst, 0..) |*o, i| {
            const j = offset + i;
            o.* = if (j < n) self.samples[@intCast(j)] else 0.0;
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
/// at `synth.SAMPLE_RATE`. Deterministic: same phrase -> same samples.
pub fn renderPhraseF32(alloc: std.mem.Allocator, phrase: []const u8) ![]f32 {
    const pcm16 = try synth.renderPhraseSamples(alloc, phrase);
    defer alloc.free(pcm16);
    const out = try alloc.alloc(f32, pcm16.len);
    for (pcm16, out) |v, *o| o.* = @as(f32, @floatFromInt(v)) / 32768.0;
    return out;
}

// ---- deterministic ids ------------------------------------------------------

fn mix(seed: u64, interval_idx: u64, channel_idx: usize, tag: []const u8) u64 {
    var h = std.hash.Wyhash.init(seed);
    var i = interval_idx;
    h.update(std.mem.asBytes(&i));
    var ci: u64 = @intCast(channel_idx);
    h.update(std.mem.asBytes(&ci));
    h.update(tag);
    return h.final();
}

/// Vorbis stream serial for (seed, interval, channel): must be pinned so the
/// encoded bytes are byte-identical across runs.
pub fn deriveSerial(seed: u64, interval_idx: u64, channel_idx: usize) u32 {
    const v = mix(seed, interval_idx, channel_idx, "kujamba-serial") & 0x7FFF_FFFF;
    return @intCast(v);
}

/// 16-byte upload guid for (seed, interval, channel). The guid is a transport
/// identifier (it never enters the 0x84 payload bytes), but it is derived
/// deterministically too so full transcripts replay consistently.
pub fn deriveGuid(seed: u64, interval_idx: u64, channel_idx: usize, out: *[16]u8) void {
    const a = mix(seed, interval_idx, channel_idx, "kujamba-guid-0");
    const b = mix(seed, interval_idx, channel_idx, "kujamba-guid-1");
    std.mem.writeInt(u64, out[0..8], a, .little);
    std.mem.writeInt(u64, out[8..16], b, .little);
}

// --------------------------------------------------------------------------
// tests
// --------------------------------------------------------------------------

const testing = std.testing;

test "fill maps the phrase onto the grid and zero-pads the tail" {
    const phrase = [_]f32{ 1, 2, 3, 4 };
    const fill = Fill{ .samples = &phrase };
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
    const fill = Fill{ .samples = samples };
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
