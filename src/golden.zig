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
//! ## Two engines, two kinds of stability
//!
//! The default voice is the physical-model engine (`synthFart`). It evaluates
//! its own exp/sin/tan from plain IEEE arithmetic, so its WAV bytes are
//! identical in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall: the
//! `wav_sha256` of the default-engine rows below is exact everywhere, and the
//! "bytes moved" note stays silent for them. The `(legacy)` rows run the
//! original engine (`--voice legacy=1`), kept verbatim, `@exp`/`@sin` and all,
//! so *they* show the codegen wobble described above, which is why the
//! asserted fields are the stable ones.
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
    /// `phrase`, through the pre-physics synth (`legacy=1`)
    phrase_legacy,
    /// `shuzi`, through the pre-physics synth (`legacy=1`)
    shuzi_legacy,
};

/// `--voice legacy=1`: the original synth, bit for bit.
const legacy_knobs = synth.VoiceKnobs{ .legacy = 1 };

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
    // the phrase the demo, the docs and the readme all use
    .{ .name = "kujamba karibu", .kind = .phrase, .input = "kujamba karibu", .items = 6, .samples = 79380, .peak = 30931, .zero_crossings = 3882, .rms_milli = 7433186, .envelope_sha256 = "0403eb7a29001dcc2c165c154583e54a8430cd084e2a3247cbd660780630fc7b", .wav_sha256 = "4835e1d7be92bdbd706487b3e34efa5130f8ab944b749d7edfa06163bda67442" },
    // longer, so the fingerprint covers stress placement across several words
    .{ .name = "asante sana kijiji", .kind = .phrase, .input = "asante sana kijiji", .items = 8, .samples = 109368, .peak = 31107, .zero_crossings = 8078, .rms_milli = 7004470, .envelope_sha256 = "c8d060c354b778b329b477d8e78f8c2aa3f5a6b5cc103f1a5af30c971358e5af", .wav_sha256 = "c26a7f655bec00b73c5d9bb352d33d8d48b2629e0a2e75b3e0615ef94bf19241" },
    // one syllable: the shortest render that still has an onset
    .{ .name = "single syllable", .kind = .phrase, .input = "a", .items = 1, .samples = 10584, .peak = 30040, .zero_crossings = 622, .rms_milli = 7194811, .envelope_sha256 = "e11322102a6019d12cb58ed02b1ea588b4fee084720e2fc0649107e788bc46b5", .wav_sha256 = "ddc798b152da85bd76ece014767c00ce25707428df40144af69a6f9c41ac4395" },
    // digits and punctuation are not word characters, so the word splitter
    // has to skip them and still place the syllables correctly
    .{ .name = "punctuation and digits", .kind = .phrase, .input = "kujamba 123 karibu!", .items = 6, .samples = 79380, .peak = 31128, .zero_crossings = 3846, .rms_milli = 7177126, .envelope_sha256 = "04a7e5d13e342225eb80dc3ca6ad4c969372cf4247a98be20dd0da6eeb1b513b", .wav_sha256 = "7ea9f9dff4f8a4adeef1b3843389ad259260735c34f0684caf41a3c8d077f274" },
    // wordless farts: no plan, and the archetype/noise/wobble path
    .{ .name = "shuzi seed 0", .kind = .shuzi, .input = "0", .items = 0, .samples = 10143, .peak = 30900, .zero_crossings = 640, .rms_milli = 11064764, .envelope_sha256 = "adc2f23b83ebc07303c9133432b33278ff268882220a6807895310f6e8b00ca6", .wav_sha256 = "e1542d0c8e53356e1d4164e2b7e3d23a425cd230a7754ac9ce497f62ec75ae37" },
    .{ .name = "shuzi seed 42", .kind = .shuzi, .input = "42", .items = 0, .samples = 34839, .peak = 31129, .zero_crossings = 2212, .rms_milli = 13382513, .envelope_sha256 = "659a4dae47980eb6e70219210c75c2eabb77eef50a51769becde27dbb1213c97", .wav_sha256 = "983053678233f8cb87e6637cd89e22b5b7dbb44d1c4591075a5af9a7e4c098af" },
    .{ .name = "shuzi seed 1234567", .kind = .shuzi, .input = "1234567", .items = 0, .samples = 10584, .peak = 20491, .zero_crossings = 550, .rms_milli = 4629417, .envelope_sha256 = "66d3d9c1e559effda2f1d221b0579ce207cf5a4fade5f75db79f891e0e5c5f18", .wav_sha256 = "ac5f70a4d0383fc50dfcedcc462cf6c61cd7c2d63149f072a170fbb0d0714f8a" },
    // the pre-physics synth, kept bit for bit behind `--voice legacy=1`:
    // the same inputs again, so the old sound stays pinned next to the new default
    .{ .name = "kujamba karibu (legacy)", .kind = .phrase_legacy, .input = "kujamba karibu", .items = 6, .samples = 79380, .peak = 22007, .zero_crossings = 720, .rms_milli = 4173837, .envelope_sha256 = "b689f1368324e2b7abe414e01bdb121730f0bb6e7ffd0bd9a9defcb752f234d1", .wav_sha256 = "21c6faa26eb63b958968a6dfe2fcf33073182be7f34c0cef416894c84b045f3d" },
    .{ .name = "asante sana kijiji (legacy)", .kind = .phrase_legacy, .input = "asante sana kijiji", .items = 8, .samples = 109368, .peak = 25998, .zero_crossings = 1134, .rms_milli = 4164752, .envelope_sha256 = "a6b896d1bc43543a6827465d36223fa91cf49cefe4b44460fe7a0272efa55a13", .wav_sha256 = "5973bbb55e662d2d47fdef82c2d4ee4b2ba059aa3d760e7801060e1af1d80c07" },
    .{ .name = "single syllable (legacy)", .kind = .phrase_legacy, .input = "a", .items = 1, .samples = 10584, .peak = 15986, .zero_crossings = 114, .rms_milli = 3958198, .envelope_sha256 = "3c5018bab5a904216360d5629d715d4a23098c8197d13f4331cb7f0a5580b8fe", .wav_sha256 = "a62ad430e53741188447d842344e26e4fdc72bf86793fb5b84143ab0421f80f9" },
    .{ .name = "punctuation and digits (legacy)", .kind = .phrase_legacy, .input = "kujamba 123 karibu!", .items = 6, .samples = 79380, .peak = 21565, .zero_crossings = 766, .rms_milli = 4192678, .envelope_sha256 = "46981dc90e5a44a07254e7e492b90d2c99a0675eac67a0c5efcb7177c7a7c245", .wav_sha256 = "ca7703195aa4a5e34da7c7eae0eb1bdfa0b096e206d1f489ec96074077172093" },
    .{ .name = "shuzi seed 0 (legacy)", .kind = .shuzi_legacy, .input = "0", .items = 0, .samples = 10143, .peak = 18461, .zero_crossings = 180, .rms_milli = 4662515, .envelope_sha256 = "ff3acaee614295f74be4eec9ae8f1ced7e0d9542a5bfb90cf79c18e5e9068f4c", .wav_sha256 = "7e763663eadf675a0c5a26b05f460af57cb89566d68df11fd10b57796556fa8a" },
    .{ .name = "shuzi seed 42 (legacy)", .kind = .shuzi_legacy, .input = "42", .items = 0, .samples = 34839, .peak = 21395, .zero_crossings = 486, .rms_milli = 4081417, .envelope_sha256 = "effa4312bb20886b185c43f4cada609baebbba77b539af351f7d839e71f38a17", .wav_sha256 = "4c0500f416ca522f8bda17db9a1bb3a11f107be23fda353d6e66268d3e44c46a" },
    .{ .name = "shuzi seed 1234567 (legacy)", .kind = .shuzi_legacy, .input = "1234567", .items = 0, .samples = 10584, .peak = 19089, .zero_crossings = 104, .rms_milli = 4564000, .envelope_sha256 = "369cd4bd42022e93224eb9fb93ba0c0eac937e9f78dfd29a8e6e269498d343eb", .wav_sha256 = "fccfb948356d4697f6bf941a6b5f9dc59fcf712d3438f92919804de9724c20da" },
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
        .phrase_legacy => try synth.renderPhraseWavWith(alloc, fp.input, legacy_knobs),
        .shuzi_legacy => try synth.renderShuziWavWith(alloc, try std.fmt.parseInt(u64, fp.input, 10), legacy_knobs),
    };
    errdefer alloc.free(wav);

    var items: u32 = 0;
    if (fp.kind == .phrase or fp.kind == .phrase_legacy) {
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
