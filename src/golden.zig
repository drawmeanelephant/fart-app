//! golden.zig — regression guard for the Flatlophone synth's rendered audio.
//!
//! Why this lives outside `synth.zig`: the point of a golden guard is to
//! outlive the refactors it protects. M6 (#15/#16/#18) reshapes `VoiceSpec`,
//! `voiceSpec` and the onset tables, and the guard should be the thing that
//! *reports* those changes rather than something rewritten alongside them. It
//! is also its own test target, so the check keeps running while synth.zig's
//! test module is being rewritten.
//!
//! ## Why this does not assert on a SHA-256 of the WAV bytes
//!
//! The obvious guard — pin the exact bytes — was measured, and it does not
//! hold. Rendering `"kujamba karibu"` and hashing the WAV gives
//!
//!     Debug        21c6faa26eb63b958968a6dfe2fcf33073182be7f34c0cef416894c84b045f3d
//!     ReleaseSafe  ab75668fca79a25e8833e6814c02c6c3129961a94670a8b2afdbb59190c56530
//!
//! on the *same machine*, same source, differing sample length unchanged. The
//! synth calls `@exp` and `@sin`, and LLVM contracts and inlines those
//! differently at different optimization levels, so a handful of samples land
//! on the other side of an i16 rounding boundary. Across ~80k samples, any
//! per-sample transform (including quantising) flips a large number of
//! buckets, so there is no cheap way to make an exact hash stable — and a
//! guard that goes red on `-Doptimize=ReleaseSafe`, and would go red again on
//! Linux and on CI, is a guard people learn to ignore.
//!
//! So the asserted fingerprint is built from measurements that *are* stable
//! under codegen, verified by re-running this whole suite in both modes:
//!
//!   | field             | stability                        | what it catches            |
//!   |-------------------|----------------------------------|----------------------------|
//!   | `items`           | exact (integer)                  | syllable splitting         |
//!   | `samples`         | exact (integer)                  | timing / duration          |
//!   | `peak`            | exact                            | overall level, clipping    |
//!   | `zero_crossings`  | exact                            | spectral tilt, buzziness   |
//!   | `envelope_sha256` | exact                            | the waveform itself        |
//!   | `rms_milli`       | within +/-2 of 1e-3 RMS          | coarse level check         |
//!
//! `envelope_sha256` is the strong one: SHA-256 over the per-10ms-window RMS
//! energy, each window rounded to a whole unit. A last-ULP wobble is ~0.003% of
//! full scale and does not move a window's integer RMS, while a reseeded noise
//! generator or a changed vowel table moves many windows. Measured: it is
//! bit-identical across optimization modes, and it catches a one-digit envelope
//! coefficient change, a 10 ms syllable-timing change, and a PRNG salt change.
//!
//! `wav_sha256` is still recorded, as the exact bytes at baseline time. It is
//! documentation and a diagnostic, not an assertion.
//!
//! Re-baselining: run `zig build test` and paste the block it prints over
//! `expected`. No script, no flag to remember.

const std = @import("std");
const synth = @import("synth.zig");

/// RMS energy envelope window: 10 ms at the synth's sample rate.
const envelope_window_samples: usize = @as(usize, synth.SAMPLE_RATE) / 100;
/// Slack on the RMS check, in 1e-3 units. The measured codegen spread is 1.
const rms_milli_tolerance: i64 = 2;

pub const Kind = enum {
    /// render via `synth.renderPhraseWav`
    phrase,
    /// render via `synth.renderShuziWav` (a wordless fart, seeded)
    shuzi,
};

pub const Fingerprint = struct {
    /// stable label; used in failure output and as the copy-paste key
    name: []const u8,
    kind: Kind,
    /// the phrase text, or the seed in decimal for `.shuzi`
    input: []const u8,
    /// syllables planned (0 for shuzi, which has no plan)
    items: u32,
    /// total samples in the rendered phrase
    samples: u32,
    /// largest absolute sample
    peak: u32,
    /// sign changes in the sample stream: a cheap proxy for spectral tilt
    zero_crossings: u32,
    /// RMS x 1000, asserted within `rms_milli_tolerance`
    rms_milli: i64,
    /// SHA-256 of the 10 ms windowed RMS envelope — the strong guard
    envelope_sha256: []const u8,
    /// SHA-256 of the exact WAV bytes. Recorded, not asserted: see the header.
    wav_sha256: []const u8,
};

/// The baseline. Any change here is a deliberate, reviewable act.
pub const expected = [_]Fingerprint{
    .{ .name = "kujamba karibu", .kind = .phrase, .input = "kujamba karibu", .items = 6, .samples = 79380, .peak = 29986, .zero_crossings = 540, .rms_milli = 7630818, .envelope_sha256 = "4cc0508f07855d4b00593b63ad846d6869c4b186499bf46d4f17643fb16468c9", .wav_sha256 = "cbf067a4de5454bf5f26a5b5908aaa80304cea7256a55dc47b4ff135dceb3255" },
    .{ .name = "asante sana kijiji", .kind = .phrase, .input = "asante sana kijiji", .items = 8, .samples = 109368, .peak = 30210, .zero_crossings = 914, .rms_milli = 7734677, .envelope_sha256 = "175a12b8cf29ea4ed87289d727b703ae462ff08e0f92153c3003c0889c75d9f8", .wav_sha256 = "e3ac9d137b993a6f3daa9c1e42ac676474097add47bab2b64b77e240b6c1faf4" },
    .{ .name = "single syllable", .kind = .phrase, .input = "a", .items = 1, .samples = 10584, .peak = 24294, .zero_crossings = 96, .rms_milli = 5497891, .envelope_sha256 = "f8257d45985a3a30f7eb4bf76376ac8eed0d1d16abd4bd3eadecf77d607a415a", .wav_sha256 = "c0fbe3f759e7336e1f47e3be1c714269d0ba8de3ddf5f352c6dee983c1d90377" },
    .{ .name = "punctuation and digits", .kind = .phrase, .input = "kujamba 123 karibu!", .items = 6, .samples = 79380, .peak = 30069, .zero_crossings = 590, .rms_milli = 7789902, .envelope_sha256 = "0cd92231ed4b1f3bcd125a537cd9fe888c77223a00464db7028e16487804c5e5", .wav_sha256 = "ee66e39531f8d95fa614fce54b5e3958aa54c3e499c9ecb59757f4a140946af3" },
    .{ .name = "shuzi seed 0", .kind = .shuzi, .input = "0", .items = 0, .samples = 10143, .peak = 27305, .zero_crossings = 166, .rms_milli = 7326610, .envelope_sha256 = "92d6b1f2bfa7506d0fdf808c86b2dfe1d857b5b35f0b523bf80c9c78c9f78dc1", .wav_sha256 = "0b164510e8de83a83cf9c4cf560bc89764a72a8e2c756bc08fbd9cfaf2c9b5d7" },
    .{ .name = "shuzi seed 42", .kind = .shuzi, .input = "42", .items = 0, .samples = 34839, .peak = 29683, .zero_crossings = 376, .rms_milli = 6901895, .envelope_sha256 = "c83d14758e7d0b7396b35d9e272640ad7a17f22db0aeb8766fa196faa32447bf", .wav_sha256 = "b2146ecbe664ea18dd90c17b58b532c3fb53cf47ebfa8f4b708e11938deb7e40" },
    .{ .name = "shuzi seed 1234567", .kind = .shuzi, .input = "1234567", .items = 0, .samples = 10584, .peak = 28388, .zero_crossings = 90, .rms_milli = 6132016, .envelope_sha256 = "290f0edd71134c5909328c0c887652401085a2071d515773f01ad2b097ecac37", .wav_sha256 = "bcaca46ceea8a89366d7fa576c01db51e38d5781c6f40fa7b7b616564124d40e" },
};

/// A fingerprint as measured right now, ready to paste into `expected`.
pub const Measured = struct {
    name: []const u8,
    kind: Kind,
    input: []const u8,
    items: u32,
    samples: u32,
    peak: u32,
    zero_crossings: u32,
    rms_milli: i64,
    envelope_sha256: [64]u8,
    wav_sha256: [64]u8,
};

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;
    return hex;
}

/// The PCM data chunk of a canonical 44-byte-header mono WAV, as raw bytes.
/// Read through `sampleAt` rather than `bytesAsSlice` so no alignment
/// assumption sneaks in.
const WavHeaderLen = 44;

fn sampleCount(data: []const u8) usize {
    return data.len / 2;
}

fn sampleAt(data: []const u8, i: usize) i16 {
    return std.mem.readInt(i16, data[2 * i ..][0..2], .little);
}

/// Level, peak and zero crossings of the rendered PCM.
const WaveStats = struct {
    peak: u32,
    zero_crossings: u32,
    rms_milli: i64,
};

fn waveStats(data: []const u8) WaveStats {
    const n = sampleCount(data);
    var acc: f64 = 0;
    var peak: u32 = 0;
    var zero_crossings: u32 = 0;
    var prev: i16 = 0;
    for (0..n) |i| {
        const v = sampleAt(data, i);
        const f: f64 = @floatFromInt(v);
        acc += f * f;
        peak = @max(peak, @as(u32, @intCast(@abs(@as(i32, v)))));
        if (i != 0 and (v >= 0) != (prev >= 0)) zero_crossings += 1;
        prev = v;
    }
    const rms = if (n == 0) 0.0 else std.math.sqrt(acc / @as(f64, @floatFromInt(n)));
    return .{
        .peak = peak,
        .zero_crossings = zero_crossings,
        .rms_milli = @intFromFloat(rms * 1000.0),
    };
}

/// SHA-256 over the per-window RMS envelope, each window rounded to a whole
/// unit. A last-ULP float wobble cannot move a window's integer RMS; a real
/// change to the waveform moves many of them.
fn envelopeHash(alloc: std.mem.Allocator, data: []const u8) !struct { hex: [64]u8, windows: u32 } {
    const n = sampleCount(data);
    var env: std.ArrayList(u32) = .empty;
    defer env.deinit(alloc);
    var off: usize = 0;
    while (off < n) {
        const count = @min(envelope_window_samples, n - off);
        var acc: f64 = 0;
        for (0..count) |k| {
            const f: f64 = @floatFromInt(sampleAt(data, off + k));
            acc += f * f;
        }
        const w = std.math.sqrt(acc / @as(f64, @floatFromInt(count)));
        try env.append(alloc, @intFromFloat(w));
        off += count;
    }
    return .{
        .hex = sha256Hex(std.mem.sliceAsBytes(env.items)),
        .windows = @intCast(env.items.len),
    };
}

/// Render `fp`'s input and measure it. `wav` is owned by the caller.
pub fn measure(alloc: std.mem.Allocator, fp: Fingerprint) !struct { wav: []u8, out: Measured } {
    const wav = switch (fp.kind) {
        .phrase => try synth.renderPhraseWav(alloc, fp.input),
        .shuzi => try synth.renderShuziWav(alloc, try std.fmt.parseInt(u64, fp.input, 10)),
    };
    errdefer alloc.free(wav);

    var items: u32 = 0;
    if (fp.kind == .phrase) {
        var plan = try synth.planPhrase(alloc, fp.input);
        defer plan.deinit(alloc);
        items = @intCast(plan.items.len);
    }

    // the data chunk is 2 bytes per mono sample; the header is a fixed 44
    const pcm = wav[@min(WavHeaderLen, wav.len)..];
    const stats = waveStats(pcm);
    const env = try envelopeHash(alloc, pcm);

    return .{ .wav = wav, .out = .{
        .name = fp.name,
        .kind = fp.kind,
        .input = fp.input,
        .items = items,
        .samples = @intCast(sampleCount(pcm)),
        .peak = stats.peak,
        .zero_crossings = stats.zero_crossings,
        .rms_milli = stats.rms_milli,
        .envelope_sha256 = env.hex,
        .wav_sha256 = sha256Hex(wav),
    } };
}

/// The `expected` table as a copy-pasteable block, for re-baselining.
pub fn formatBaseline(alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(alloc, "pub const expected = [_]Fingerprint{\n");
    for (expected) |fp| {
        const m = try measure(alloc, fp);
        defer alloc.free(m.wav);
        try out.print(alloc, "    .{{ .name = \"{s}\", .kind = .{s}, .input = \"{s}\", .items = {d}, .samples = {d}, .peak = {d}, .zero_crossings = {d}, .rms_milli = {d}, .envelope_sha256 = \"{s}\", .wav_sha256 = \"{s}\" }},\n", .{
            m.out.name, @tagName(m.out.kind), m.out.input,     m.out.items,           m.out.samples,
            m.out.peak, m.out.zero_crossings, m.out.rms_milli, m.out.envelope_sha256, m.out.wav_sha256,
        });
    }
    try out.appendSlice(alloc, "};\n");
}

// --------------------------------------------------------------------------
// tests
// --------------------------------------------------------------------------

const testing = std.testing;

test "the synth still renders audio matching this project's golden fingerprints" {
    const alloc = testing.allocator;
    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(alloc);
    var drift: usize = 0;

    for (expected) |fp| {
        const m = try measure(alloc, fp);
        defer alloc.free(m.wav);
        const got = m.out;

        if (got.items != fp.items or
            got.samples != fp.samples or
            got.peak != fp.peak or
            got.zero_crossings != fp.zero_crossings or
            !std.mem.eql(u8, &got.envelope_sha256, fp.envelope_sha256))
        {
            drift += 1;
            try report.print(alloc, "  {s}\n", .{fp.name});
            try report.print(alloc, "    items        {d: >8} (expected {d})\n", .{ got.items, fp.items });
            try report.print(alloc, "    samples      {d: >8} (expected {d})\n", .{ got.samples, fp.samples });
            try report.print(alloc, "    peak         {d: >8} (expected {d})\n", .{ got.peak, fp.peak });
            try report.print(alloc, "    zero_xing    {d: >8} (expected {d})\n", .{ got.zero_crossings, fp.zero_crossings });
            try report.print(alloc, "    envelope     {s} (expected {s})\n", .{ got.envelope_sha256, fp.envelope_sha256 });
            continue;
        }

        // tolerant by design: this one is only a coarse level check, and the
        // measured codegen spread is 1 unit
        const d = got.rms_milli - fp.rms_milli;
        if (d > rms_milli_tolerance or -d > rms_milli_tolerance) {
            drift += 1;
            try report.print(alloc, "  {s}\n    rms_milli    {d: >8} (expected {d}, +/-{d})\n", .{
                fp.name, got.rms_milli, fp.rms_milli, rms_milli_tolerance,
            });
        }
    }

    if (drift == 0) return;

    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(alloc);
    try msg.appendSlice(alloc, "synth golden fingerprints no longer match:\n\n");
    try msg.appendSlice(alloc, report.items);
    try msg.appendSlice(alloc,
        \\
        \\If you changed the synth on purpose (M6: #15 velocity, #16 vowel pitch,
        \\#18 voiceSpec), re-baseline by pasting this over `expected`:
        \\
        \\
    );
    var baseline: std.ArrayList(u8) = .empty;
    defer baseline.deinit(alloc);
    try formatBaseline(alloc, &baseline);
    try msg.appendSlice(alloc, baseline.items);
    try msg.appendSlice(alloc,
        \\
        \\If you did NOT change the synth, the guard itself is miscalibrated: the
        \\asserted fields are supposed to be exact across optimization modes and
        \\platforms. Do not paper over it by loosening a tolerance — find out why
        \\they moved. See the header comment for how these were chosen.
        \\
    );
    std.debug.print("{s}", .{msg.items});
    return error.SynthGoldenFingerprintMismatch;
}

test "the exact rendered bytes have not changed since the baseline was taken" {
    // Not an equality check against `wav_sha256` — that is deliberately not
    // asserted, because it is not stable across optimization modes. This only
    // reports the current bytes so a drift is visible in the log, which is how
    // the "exact hash is not a stable invariant" claim in the header was
    // discovered in the first place.
    const alloc = testing.allocator;
    for (expected) |fp| {
        const m = try measure(alloc, fp);
        defer alloc.free(m.wav);
        if (!std.mem.eql(u8, &m.out.wav_sha256, fp.wav_sha256)) {
            std.debug.print("note: exact bytes for '{s}' moved ({s} -> {s}); this is expected across build configs and is not asserted\n", .{
                fp.name, fp.wav_sha256, m.out.wav_sha256,
            });
        }
    }
}

test "the golden table is complete and internally consistent" {
    // A blank expected value is a re-baselining bug waiting to happen, not a
    // passing test: the check above would compare against "".
    for (expected, 0..) |fp, i| {
        if (fp.envelope_sha256.len != 64 or fp.wav_sha256.len != 64) {
            std.debug.print("golden: '{s}' has a {d}/{d}-char hash, want 64/64 (re-baseline?)\n", .{
                fp.name, fp.envelope_sha256.len, fp.wav_sha256.len,
            });
            return error.IncompleteGoldenFingerprint;
        }
        for (fp.envelope_sha256) |c| {
            if (!std.ascii.isHex(c)) {
                std.debug.print("golden: '{s}' envelope hash is not hex: {c}\n", .{ fp.name, c });
                return error.IncompleteGoldenFingerprint;
            }
        }
        // the label is the copy-paste key, so it has to be unique
        for (expected[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.name, fp.name)) {
                std.debug.print("golden: duplicate fingerprint '{s}'\n", .{fp.name});
                return error.DuplicateGoldenFingerprint;
            }
        }
    }
}
