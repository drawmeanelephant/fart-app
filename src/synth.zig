//! synth.zig — Flatlophone v2: real fart synthesis + Swahili syllable engine.
//!
//! Pure Zig stdlib. Emits PCM WAV (RIFF), 44100 Hz, mono, 16-bit. No libc, no
//! file I/O: every render is a pure function of its input. The noise generator
//! is seeded from a hash of the input text with fixed constants everywhere
//! else, so the same phrase always produces byte-identical WAV bytes. Always.
//!
//! One fart "phoneme" (one Swahili syllable) is:
//!   * a low-frequency buzzy oscillator whose pitch falls 20% across the syllable
//!   * a filtered noise burst at the attack (the "splat") plus a quiet
//!     low-passed body hiss
//!   * an amplitude envelope with a fast attack and a ~24-34 Hz flutter wobble
//!
//! Swahili is nearly pure CV. `Scanner` splits a word into syllables: each
//! vowel picks the base pitch, the consonant onset picks the attack/decay
//! character, and the syllable count sets the total duration.
//! The full mapping tables live in README.md.
//!
//! Vocabulary note: kujamba = to fart, shuzi = a fart. Use them proudly.

const std = @import("std");

pub const SAMPLE_RATE: u32 = 44100;

// Timing policy. All values are multiples of 10 ms so every segment length is
// an exact integer number of samples (10 ms = 441 samples).
pub const SYLLABLE_MS: u32 = 240; // one syllable of speech
pub const GAP_MS: u32 = 40; // breath between syllables inside a word
pub const WORD_GAP_MS: u32 = 120; // breath between words
pub const BREATH_MS: u32 = 90; // consonant-only tail syllable (rare in Swahili)

const SYLLABLE_SAMPLES: usize = SYLLABLE_MS * SAMPLE_RATE / 1000; // 10584
const STRESSED_SYLLABLE_MS: u32 = 280; // penultimate syllable of a word: +40 ms
const STRESSED_SYLLABLE_SAMPLES: usize = STRESSED_SYLLABLE_MS * SAMPLE_RATE / 1000; // 12348
const STRESS_LEVEL_BOOST: f32 = 1.2; // the stressed syllable is also louder
const GAP_SAMPLES: usize = GAP_MS * SAMPLE_RATE / 1000; // 1764
const WORD_GAP_SAMPLES: usize = WORD_GAP_MS * SAMPLE_RATE / 1000; // 5292
const BREATH_SAMPLES: usize = BREATH_MS * SAMPLE_RATE / 1000; // 3969

const PITCH_DROP: f32 = 0.20; // pitch falls 20% across a syllable

// ---------------------------------------------------------------------
// Mapping tables (documented in README.md)
// ---------------------------------------------------------------------

/// Base frequency of the buzzy oscillator, chosen by the syllable's vowel.
pub fn vowelBaseFreq(v: u8) ?f32 {
    return switch (v) {
        'a' => 92.0,
        'e' => 110.0,
        'i' => 138.0,
        'o' => 86.0,
        'u' => 74.0,
        else => null,
    };
}

/// Onset character classes: consonants set the attack/decay character.
pub const VoiceClass = enum {
    none, // bare vowel onset
    stop_voiceless, // p t k ch
    stop_voiced, // b d g j
    fricative, // s sh z f v th dh h gh
    nasal, // m n ng ny
    liquid, // l r w y
};

pub const VoiceSpec = struct {
    attack_s: f32,
    noise_mix: f32,
    wobble_hz: f32,
    wobble_depth: f32,
    level: f32,
};

pub fn voiceSpec(cls: VoiceClass) VoiceSpec {
    return switch (cls) {
        .none => .{ .attack_s = 0.008, .noise_mix = 0.25, .wobble_hz = 28.0, .wobble_depth = 0.50, .level = 0.90 },
        .stop_voiceless => .{ .attack_s = 0.004, .noise_mix = 0.40, .wobble_hz = 32.0, .wobble_depth = 0.55, .level = 0.95 },
        .stop_voiced => .{ .attack_s = 0.006, .noise_mix = 0.28, .wobble_hz = 30.0, .wobble_depth = 0.50, .level = 1.00 },
        .fricative => .{ .attack_s = 0.010, .noise_mix = 0.50, .wobble_hz = 29.0, .wobble_depth = 0.45, .level = 0.90 },
        .nasal => .{ .attack_s = 0.025, .noise_mix = 0.12, .wobble_hz = 26.0, .wobble_depth = 0.35, .level = 0.85 },
        .liquid => .{ .attack_s = 0.014, .noise_mix = 0.18, .wobble_hz = 28.0, .wobble_depth = 0.45, .level = 0.90 },
    };
}

pub fn classify(onset: []const u8) VoiceClass {
    if (onset.len == 0) return .none;
    return switch (onset[0]) {
        'p', 't', 'k', 'c' => .stop_voiceless,
        'b', 'd', 'g', 'j' => .stop_voiced,
        's', 'z', 'f', 'v', 'h' => .fricative,
        'm', 'n' => .nasal,
        'l', 'r', 'w', 'y' => .liquid,
        else => .fricative,
    };
}

// ---------------------------------------------------------------------
// Sample rendering
// ---------------------------------------------------------------------

const VoiceParams = struct {
    f0: f32,
    attack_s: f32,
    noise_mix: f32,
    wobble_hz: f32,
    wobble_depth: f32,
    level: f32,
    glide: f32,
};

/// Renders one fart phoneme into `out` (mono i16). Deterministic: the only
/// randomness comes from `prng`, whose seed is fixed per render.
fn synthInto(out: []i16, p: VoiceParams, prng: *std.Random.DefaultPrng) void {
    const dt: f32 = 1.0 / @as(f32, SAMPLE_RATE);
    const tau: f32 = std.math.tau;
    var phase: f32 = 0;
    var lp_body: f32 = 0;
    var lp_burst: f32 = 0;
    const alpha_body: f32 = 1.0 - @exp(-tau * 700.0 * dt);
    const alpha_burst: f32 = 1.0 - @exp(-tau * 1900.0 * dt);
    const wobble_phase: f32 = prng.random().float(f32) * tau;
    const wobble_hz: f32 = p.wobble_hz * (0.9 + 0.2 * prng.random().float(f32));
    const n = out.len;
    for (0..n) |i| {
        const fi: f32 = @floatFromInt(i);
        const t = fi * dt;
        const u = fi / @as(f32, @floatFromInt(n));

        // Buzzy low-frequency oscillator, pitch gliding down ~20%.
        const f = p.f0 * (1.0 - p.glide * u);
        phase += tau * f * dt;
        if (phase >= tau) phase -= tau;
        const carrier = (@sin(phase) + 0.55 * @sin(2.0 * phase) + 0.30 * @sin(3.0 * phase) + 0.12 * @sin(4.0 * phase)) * 0.42;

        // Filtered noise: a decaying attack burst + a quiet body hiss.
        const wn_body = prng.random().float(f32) * 2.0 - 1.0;
        lp_body += alpha_body * (wn_body - lp_body);
        const wn_burst = prng.random().float(f32) * 2.0 - 1.0;
        lp_burst += alpha_burst * (wn_burst - lp_burst);
        const burst_env = @exp(-t / 0.045);
        const noise = lp_body * 0.35 + lp_burst * 0.9 * burst_env;

        // Envelope: fast attack, decay to zero, fluttering at ~24-34 Hz.
        const attack = @min(1.0, t / p.attack_s);
        const decay = std.math.pow(f32, 1.0 - u, 1.3);
        const env = attack * decay;
        const wob = 1.0 - p.wobble_depth * (0.5 + 0.5 * @sin(tau * wobble_hz * t + wobble_phase));

        var x = (carrier + p.noise_mix * noise) * env * wob * p.level;
        if (x > 0.95) x = 0.95;
        if (x < -0.95) x = -0.95;
        out[i] = @intFromFloat(@round(x * 32767.0));
    }
}

fn renderSyllableInto(out: []i16, syl: *const Syll, stressed: bool, prng: *std.Random.DefaultPrng) void {
    var p: VoiceParams = undefined;
    if (syl.vowel == 0) {
        // Consonant-only tail: a short whisper, not a buzz.
        p = .{ .f0 = 88.0, .attack_s = 0.006, .noise_mix = 0.85, .wobble_hz = 31.0, .wobble_depth = 0.30, .level = 0.65, .glide = 0.15 };
    } else {
        const spec = voiceSpec(classify(syl.onset()));
        p = .{
            .f0 = vowelBaseFreq(syl.vowel).?,
            .attack_s = spec.attack_s,
            .noise_mix = spec.noise_mix,
            .wobble_hz = spec.wobble_hz,
            .wobble_depth = spec.wobble_depth,
            .level = spec.level,
            .glide = PITCH_DROP,
        };
        // Swahili stresses the penultimate syllable of a word.
        if (stressed) p.level *= STRESS_LEVEL_BOOST;
    }
    // Per-syllable jitter, still a pure function of (phrase, syllable index).
    const r = prng.random();
    p.f0 *= 1.0 + (r.float(f32) - 0.5) * 0.06;
    p.wobble_hz += (r.float(f32) - 0.5) * 3.0;
    synthInto(out, p, prng);
}

// ---------------------------------------------------------------------
// Swahili syllable engine
// ---------------------------------------------------------------------

fn lowerAscii(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn isVowel(c: u8) bool {
    return c == 'a' or c == 'e' or c == 'i' or c == 'o' or c == 'u';
}

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '\'';
}

/// Two-letter onsets that stay together: digraphs (sh, ch, ny, ...),
/// prenasalized consonants (mb, nd, ng, nj, mp, nt, nk, nz, nv, mv) and
/// Cw/Cy glide clusters (kwa, bwana, mwa, ...).
const onset_pairs = [_][2]u8{
    .{ 's', 'h' }, .{ 'c', 'h' }, .{ 't', 'h' }, .{ 'd', 'h' }, .{ 'k', 'h' },
    .{ 'g', 'h' }, .{ 'p', 'h' }, .{ 'n', 'y' }, .{ 'm', 'b' }, .{ 'm', 'p' },
    .{ 'n', 'd' }, .{ 'n', 't' }, .{ 'n', 'g' }, .{ 'n', 'k' }, .{ 'n', 'j' },
    .{ 'n', 'z' }, .{ 'n', 'v' }, .{ 'm', 'v' }, .{ 'k', 'w' }, .{ 'g', 'w' },
    .{ 'b', 'w' }, .{ 'v', 'w' }, .{ 'm', 'w' }, .{ 'f', 'w' }, .{ 'b', 'y' },
    .{ 'f', 'y' }, .{ 'm', 'y' }, .{ 'p', 'y' },
};

fn canExtend(pending: []const u8, c: u8) bool {
    if (pending.len == 0) return true;
    if (c == '\'') return std.mem.eql(u8, pending, "ng"); // ng' is one consonant
    if (pending.len >= 7) return false;
    const last = pending[pending.len - 1];
    for (onset_pairs) |pair| {
        if (pair[0] == last and pair[1] == c) return true;
    }
    return false;
}

/// One syllable: a consonant onset, one vowel, and its spelling.
/// Buffers live inside the struct; valid until the Scanner's next() call.
pub const Syll = struct {
    text_buf: [24]u8 = undefined,
    text_len: u8 = 0,
    onset_len: u8 = 0,
    vowel: u8 = 0, // 0 for a consonant-only breath syllable

    pub fn text(self: *const Syll) []const u8 {
        return self.text_buf[0..self.text_len];
    }
    pub fn onset(self: *const Syll) []const u8 {
        return self.text_buf[0..self.onset_len];
    }
};

/// Single-pass, allocation-free syllable splitter for one word.
/// Swahili syllables are (C)V: consonants gather into an onset, the vowel
/// closes the syllable. A consonant that cannot join the pending onset
/// (e.g. the "m" of "mtu") becomes its own syllabic-nasal breath syllable.
pub const Scanner = struct {
    word: []const u8,
    idx: usize = 0,
    pending: [7]u8 = undefined,
    pending_len: usize = 0,

    pub fn init(word: []const u8) Scanner {
        return .{ .word = word };
    }

    pub fn next(self: *Scanner) ?Syll {
        if (self.idx >= self.word.len and self.pending_len == 0) return null;
        var syl = Syll{};
        while (self.idx < self.word.len) {
            const c = lowerAscii(self.word[self.idx]);
            if (isVowel(c)) {
                var tl: usize = 0;
                if (self.pending_len > 0) {
                    @memcpy(syl.text_buf[0..self.pending_len], self.pending[0..self.pending_len]);
                    tl = self.pending_len;
                    syl.onset_len = @intCast(self.pending_len);
                    self.pending_len = 0;
                }
                syl.text_buf[tl] = c;
                tl += 1;
                syl.vowel = c;
                syl.text_len = @intCast(tl);
                self.idx += 1;
                return syl;
            }
            if (canExtend(self.pending[0..self.pending_len], c)) {
                self.pending[self.pending_len] = c;
                self.pending_len += 1;
                self.idx += 1;
                continue;
            }
            // Consonant that cannot join the pending onset: the pending
            // consonant becomes a whispered breath syllable (like the "m"
            // in "mtu"), and this consonant starts the next onset.
            @memcpy(syl.text_buf[0..self.pending_len], self.pending[0..self.pending_len]);
            syl.text_len = @intCast(self.pending_len);
            syl.onset_len = syl.text_len;
            self.pending[0] = c;
            self.pending_len = 1;
            self.idx += 1;
            return syl;
        }
        // Word over with a stranded onset: whispered tail syllable.
        @memcpy(syl.text_buf[0..self.pending_len], self.pending[0..self.pending_len]);
        syl.text_len = @intCast(self.pending_len);
        syl.onset_len = syl.text_len;
        self.pending_len = 0;
        return syl;
    }
};

pub fn countSyllables(word: []const u8) usize {
    var scan = Scanner.init(word);
    var n: usize = 0;
    while (scan.next()) |_| n += 1;
    return n;
}

/// Allocates the syllable spellings of `word`. Caller frees the strings and
/// the returned slice.
pub fn splitSyllables(allocator: std.mem.Allocator, word: []const u8) ![][]const u8 {
    const out = try allocator.alloc([]const u8, countSyllables(word));
    errdefer allocator.free(out);
    var scan = Scanner.init(word);
    var i: usize = 0;
    while (scan.next()) |syl| {
        out[i] = try allocator.dupe(u8, syl.text());
        i += 1;
    }
    return out;
}

// ---------------------------------------------------------------------
// Phrase planning and rendering
// ---------------------------------------------------------------------

pub const PhraseItem = struct {
    syl: Syll,
    start: usize, // sample offset in the rendered phrase
    len: usize, // samples this syllable occupies
    stressed: bool = false, // penultimate syllable of its word
};

pub const Plan = struct {
    items: []PhraseItem = &.{},
    total_samples: usize = 0,
    buf: []PhraseItem = &.{},

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
    }
};

/// Splits `phrase` into words and syllables and lays out the sample timeline:
/// SYLLABLE_MS per syllable (STRESSED_SYLLABLE_MS for a word's penultimate
/// syllable), GAP_MS between syllables of one word, WORD_GAP_MS between words.
/// The plan is the single source of truth for both the renderer and the
/// duration math, so they cannot drift apart.
pub fn planPhrase(allocator: std.mem.Allocator, phrase: []const u8) !Plan {
    const lower = try allocator.alloc(u8, phrase.len);
    defer allocator.free(lower);
    for (phrase, 0..) |c, k| lower[k] = lowerAscii(c);

    const words = try allocator.alloc([]const u8, lower.len + 1);
    defer allocator.free(words);
    var nwords: usize = 0;
    var i: usize = 0;
    while (i < lower.len) {
        if (isWordChar(lower[i])) {
            const start = i;
            while (i < lower.len and isWordChar(lower[i])) i += 1;
            words[nwords] = lower[start..i];
            nwords += 1;
        } else {
            i += 1;
        }
    }

    const buf = try allocator.alloc(PhraseItem, lower.len + 1);
    errdefer allocator.free(buf);
    var nitems: usize = 0;
    var cursor: usize = 0;
    for (words[0..nwords], 0..) |w, wi| {
        const nsyl = countSyllables(w);
        var emitted: usize = 0;
        var scan = Scanner.init(w);
        while (scan.next()) |syl| {
            // Penultimate syllable of the word carries the stress — but only
            // if it is voiced; a breath-syllable penult stays a whisper.
            const stressed = nsyl >= 2 and emitted + 1 == nsyl - 1 and syl.vowel != 0;
            const len: usize = if (syl.vowel == 0) BREATH_SAMPLES else if (stressed) STRESSED_SYLLABLE_SAMPLES else SYLLABLE_SAMPLES;
            buf[nitems] = .{ .syl = syl, .start = cursor, .len = len, .stressed = stressed };
            nitems += 1;
            cursor += len;
            emitted += 1;
            if (emitted < nsyl) {
                cursor += GAP_SAMPLES;
            } else if (wi + 1 < nwords) {
                cursor += WORD_GAP_SAMPLES;
            }
        }
    }
    return .{ .items = buf[0..nitems], .total_samples = cursor, .buf = buf };
}

pub fn phraseDurationMs(allocator: std.mem.Allocator, phrase: []const u8) !f64 {
    var plan = try planPhrase(allocator, phrase);
    defer plan.deinit(allocator);
    return @as(f64, @floatFromInt(plan.total_samples)) * 1000.0 / @as(f64, SAMPLE_RATE);
}

/// Renders a whole phrase as interleaved i16 samples. Deterministic: the same
/// phrase yields byte-identical samples on every call, every run.
pub fn renderPhraseSamples(allocator: std.mem.Allocator, phrase: []const u8) ![]i16 {
    var plan = try planPhrase(allocator, phrase);
    defer plan.deinit(allocator);
    if (plan.items.len == 0) return error.NoSyllables;
    const samples = try allocator.alloc(i16, plan.total_samples);
    errdefer allocator.free(samples);
    @memset(samples, 0);
    var prng = std.Random.DefaultPrng.init(std.hash.Wyhash.hash(0x5EED_F00D, phrase));
    for (plan.items) |item| {
        renderSyllableInto(samples[item.start..][0..item.len], &item.syl, item.stressed, &prng);
    }
    return samples;
}

/// Renders a phrase straight to complete WAV bytes (44-byte header + data).
pub fn renderPhraseWav(allocator: std.mem.Allocator, phrase: []const u8) ![]u8 {
    const samples = try renderPhraseSamples(allocator, phrase);
    defer allocator.free(samples);
    return writeWavBytes(allocator, samples, SAMPLE_RATE);
}

/// A wordless shuzi (a fart): 1-3 rumble syllables with random-ish timing,
/// pitch and onset character. Deterministic per seed.
pub fn renderShuziWav(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const n_syl: usize = 1 + r.uintLessThan(usize, 3);
    const Seg = struct { params: VoiceParams, len: usize, gap_after: usize };
    var segs: [3]Seg = undefined;
    var total: usize = 0;
    var i: usize = 0;
    while (i < n_syl) : (i += 1) {
        const dur_ms: usize = (16 + r.uintLessThan(usize, 19)) * 10; // 160..340 ms
        const classes = [_]VoiceClass{ .stop_voiced, .stop_voiceless, .fricative, .nasal, .liquid };
        const spec = voiceSpec(classes[r.uintLessThan(usize, classes.len)]);
        const gap_ms: usize = if (i + 1 < n_syl) (3 + r.uintLessThan(usize, 5)) * 10 else 0; // 30..70 ms
        segs[i] = .{
            .params = .{
                .f0 = 70.0 + 40.0 * r.float(f32),
                .attack_s = spec.attack_s,
                .noise_mix = spec.noise_mix + 0.10,
                .wobble_hz = 24.0 + 10.0 * r.float(f32),
                .wobble_depth = 0.45 + 0.15 * r.float(f32),
                .level = 1.0,
                .glide = PITCH_DROP,
            },
            .len = dur_ms * SAMPLE_RATE / 1000,
            .gap_after = gap_ms * SAMPLE_RATE / 1000,
        };
        total += segs[i].len + segs[i].gap_after;
    }
    const samples = try allocator.alloc(i16, total);
    defer allocator.free(samples);
    @memset(samples, 0);
    var off: usize = 0;
    i = 0;
    while (i < n_syl) : (i += 1) {
        synthInto(samples[off..][0..segs[i].len], segs[i].params, &prng);
        off += segs[i].len + segs[i].gap_after;
    }
    return writeWavBytes(allocator, samples, SAMPLE_RATE);
}

// ---------------------------------------------------------------------
// WAV container
// ---------------------------------------------------------------------

const riff_tag = [4]u8{ 'R', 'I', 'F', 'F' };
const wave_tag = [4]u8{ 'W', 'A', 'V', 'E' };
const fmt_tag = [4]u8{ 'f', 'm', 't', ' ' };
const data_tag = [4]u8{ 'd', 'a', 't', 'a' };

/// Wraps mono i16 samples in a canonical 44-byte PCM WAV header.
pub fn writeWavBytes(allocator: std.mem.Allocator, samples: []const i16, sample_rate: u32) ![]u8 {
    const data_len: u32 = @intCast(samples.len * 2);
    const wav = try allocator.alloc(u8, 44 + data_len);
    errdefer allocator.free(wav);
    @memcpy(wav[0..4], &riff_tag);
    std.mem.writeInt(u32, wav[4..8], data_len + 36, .little);
    @memcpy(wav[8..12], &wave_tag);
    @memcpy(wav[12..16], &fmt_tag);
    std.mem.writeInt(u32, wav[16..20], 16, .little); // fmt chunk size
    std.mem.writeInt(u16, wav[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, wav[22..24], 1, .little); // mono
    std.mem.writeInt(u32, wav[24..28], sample_rate, .little);
    std.mem.writeInt(u32, wav[28..32], sample_rate * 2, .little); // byte rate
    std.mem.writeInt(u16, wav[32..34], 2, .little); // block align
    std.mem.writeInt(u16, wav[34..36], 16, .little); // bits per sample
    @memcpy(wav[36..40], &data_tag);
    std.mem.writeInt(u32, wav[40..44], data_len, .little);
    for (samples, 0..) |s, k| {
        std.mem.writeInt(i16, wav[44 + 2 * k ..][0..2], s, .little);
    }
    return wav;
}

/// Byte length of the WAV data chunk (2 bytes per mono sample).
pub fn wavDataByteLen(wav: []const u8) u32 {
    return std.mem.readInt(u32, wav[40..44], .little);
}

// ---------------------------------------------------------------------
// TESTING
// Every audio test below asserts non-silence, so replacing the synthesis
// with silence fails each one of them.
// ---------------------------------------------------------------------

const testing = std.testing;

fn expectNotSilence(wav: []const u8) !void {
    const data_len = wavDataByteLen(wav);
    const total: usize = data_len / 2;
    try testing.expect(total > 0);
    var peak: i32 = 0;
    var nonzero: usize = 0;
    var k: usize = 0;
    while (k < total) : (k += 1) {
        const s: i32 = std.mem.readInt(i16, wav[44 + 2 * k ..][0..2], .little);
        const a = if (s < 0) -s else s;
        if (a > peak) peak = a;
        if (s != 0) nonzero += 1;
    }
    try testing.expect(peak >= 3000); // at least ~9% of full scale somewhere
    try testing.expect(nonzero * 20 >= total); // >5% of samples are audible
}

test "wav header is valid RIFF PCM and not silent" {
    const allocator = testing.allocator;
    const wav = try renderPhraseWav(allocator, "habari yako");
    defer allocator.free(wav);
    try testing.expect(wav.len > 44);
    try testing.expectEqualStrings("RIFF", wav[0..4]);
    try testing.expectEqualStrings("WAVE", wav[8..12]);
    try testing.expectEqualStrings("fmt ", wav[12..16]);
    try testing.expectEqualStrings("data", wav[36..40]);
    try testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, wav[16..20], .little));
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, wav[20..22], .little)); // PCM
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, wav[22..24], .little)); // mono
    try testing.expectEqual(SAMPLE_RATE, std.mem.readInt(u32, wav[24..28], .little));
    try testing.expectEqual(SAMPLE_RATE * 2, std.mem.readInt(u32, wav[28..32], .little)); // byte rate
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, wav[32..34], .little)); // block align
    try testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, wav[34..36], .little)); // bits
    try testing.expectEqual(@as(u32, @intCast(wav.len - 44)), wavDataByteLen(wav));
    try testing.expectEqual(@as(u32, @intCast(wav.len - 8)), std.mem.readInt(u32, wav[4..8], .little));
    try expectNotSilence(wav);
}

test "sample count matches expected duration within 1ms" {
    const allocator = testing.allocator;
    const phrase = "karibu kujamba";
    const wav = try renderPhraseWav(allocator, phrase);
    defer allocator.free(wav);

    // Recompute the expected duration from the documented timing policy:
    // per word: nsyl * SYLLABLE_MS + (nsyl - 1) * GAP_MS + stress bonus
    // (40 ms when the penult is voiced, true for every word in this phrase),
    // plus (nwords - 1) * WORD_GAP_MS.
    var expected_ms: f64 = 0;
    var nwords: usize = 0;
    var it = std.mem.tokenizeAny(u8, phrase, " ");
    while (it.next()) |w| {
        nwords += 1;
        const nsyl = countSyllables(w);
        expected_ms += @floatFromInt(nsyl * SYLLABLE_MS + (nsyl - 1) * GAP_MS + (if (nsyl >= 2) GAP_MS else 0));
    }
    expected_ms += @floatFromInt((nwords - 1) * WORD_GAP_MS);
    const actual_ms: f64 = @as(f64, @floatFromInt(wavDataByteLen(wav) / 2)) * 1000.0 / @as(f64, SAMPLE_RATE);
    try testing.expect(@abs(actual_ms - expected_ms) < 1.0);
    try expectNotSilence(wav);
}

test "determinism: same phrase renders byte-identical wav" {
    const allocator = testing.allocator;
    const a = try renderPhraseWav(allocator, "kujamba shuzi");
    defer allocator.free(a);
    const b = try renderPhraseWav(allocator, "kujamba shuzi");
    defer allocator.free(b);
    try testing.expectEqualSlices(u8, a, b);
    try expectNotSilence(a);
}

test "syllable splitter handles real swahili words" {
    const allocator = testing.allocator;
    const TestCase = struct { word: []const u8, expected: []const []const u8 };
    const cases = [_]TestCase{
        .{ .word = "habari", .expected = &.{ "ha", "ba", "ri" } },
        .{ .word = "yako", .expected = &.{ "ya", "ko" } },
        .{ .word = "asante", .expected = &.{ "a", "sa", "nte" } },
        .{ .word = "karibu", .expected = &.{ "ka", "ri", "bu" } },
        .{ .word = "kujamba", .expected = &.{ "ku", "ja", "mba" } },
        .{ .word = "shuzi", .expected = &.{ "shu", "zi" } },
    };
    for (cases) |tc| {
        const got = try splitSyllables(allocator, tc.word);
        defer {
            for (got) |g| allocator.free(g);
            allocator.free(got);
        }
        try testing.expectEqual(tc.expected.len, got.len);
        for (tc.expected, got) |e, g| {
            try testing.expectEqualStrings(e, g);
        }
        // The word must also fart: rendered audio must not be silence.
        const wav = try renderPhraseWav(allocator, tc.word);
        defer allocator.free(wav);
        try expectNotSilence(wav);
    }
}

test "changing a vowel changes the output bytes" {
    const allocator = testing.allocator;
    const a = try renderPhraseWav(allocator, "kaka");
    defer allocator.free(a);
    const b = try renderPhraseWav(allocator, "kiki");
    defer allocator.free(b);
    try testing.expectEqual(a.len, b.len); // same syllable count -> same duration
    var differs = false;
    for (a, b) |x, y| {
        if (x != y) {
            differs = true;
            break;
        }
    }
    try testing.expect(differs);
    try expectNotSilence(a);
    try expectNotSilence(b);
}

test "synthesis is not silence" {
    const allocator = testing.allocator;
    const wav = try renderPhraseWav(allocator, "shuzi ya mtaa");
    defer allocator.free(wav);
    try expectNotSilence(wav);
    const shuzi = try renderShuziWav(allocator, 0xF4277D01);
    defer allocator.free(shuzi);
    try expectNotSilence(shuzi);
}

fn rmsOf(samples: []const i16) f64 {
    var acc: f64 = 0;
    for (samples) |s| {
        const x: f64 = @floatFromInt(s);
        acc += x * x;
    }
    return @sqrt(acc / @as(f64, @floatFromInt(samples.len)));
}

test "penultimate syllable is stressed: longer and louder" {
    const allocator = testing.allocator;
    // ka·ka: the first syllable is the penult -> stressed: 280 + 40 + 240 = 560 ms
    const wav = try renderPhraseWav(allocator, "kaka");
    defer allocator.free(wav);
    const actual_ms: f64 = @as(f64, @floatFromInt(wavDataByteLen(wav) / 2)) * 1000.0 / @as(f64, SAMPLE_RATE);
    try testing.expect(@abs(actual_ms - 560.0) < 1.0);

    // Same onset class, same vowel, same base pitch: the stressed syllable
    // must be measurably louder than the final one.
    const samples = try renderPhraseSamples(allocator, "kaka");
    defer allocator.free(samples);
    var plan = try planPhrase(allocator, "kaka");
    defer plan.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), plan.items.len);
    try testing.expect(plan.items[0].stressed);
    try testing.expect(!plan.items[1].stressed);
    const rms_stressed = rmsOf(samples[plan.items[0].start..][0..plan.items[0].len]);
    const rms_final = rmsOf(samples[plan.items[1].start..][0..plan.items[1].len]);
    try testing.expect(rms_stressed > 1.1 * rms_final);

    // A monosyllable carries no stress: "ha" is exactly 240 ms.
    const wav2 = try renderPhraseWav(allocator, "ha");
    defer allocator.free(wav2);
    const ms2: f64 = @as(f64, @floatFromInt(wavDataByteLen(wav2) / 2)) * 1000.0 / @as(f64, SAMPLE_RATE);
    try testing.expect(@abs(ms2 - 240.0) < 1.0);

    try expectNotSilence(wav);
}

test "breath syllable: mtu keeps its 90ms whisper unstressed" {
    const allocator = testing.allocator;
    const got = try splitSyllables(allocator, "mtu");
    defer {
        for (got) |g| allocator.free(g);
        allocator.free(got);
    }
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("m", got[0]);
    try testing.expectEqualStrings("tu", got[1]);

    // m (whisper, 90) + gap 40 + tu (240; the penult is a breath, so the
    // stress bonus does not apply) = 370 ms
    const wav = try renderPhraseWav(allocator, "mtu");
    defer allocator.free(wav);
    const actual_ms: f64 = @as(f64, @floatFromInt(wavDataByteLen(wav) / 2)) * 1000.0 / @as(f64, SAMPLE_RATE);
    try testing.expect(@abs(actual_ms - 370.0) < 1.0);
    try expectNotSilence(wav);
}

fn expectRoundTrip(allocator: std.mem.Allocator, word: []const u8) !void {
    const sylls = try splitSyllables(allocator, word);
    defer {
        for (sylls) |s| allocator.free(s);
        allocator.free(sylls);
    }
    var joined: [64]u8 = undefined;
    var n: usize = 0;
    for (sylls) |s| {
        try testing.expect(s.len > 0);
        try testing.expect(n + s.len <= joined.len);
        @memcpy(joined[n..][0..s.len], s);
        n += s.len;
    }
    // The scanner lowercases; round-trip must reproduce the lowercased word.
    var lower: [64]u8 = undefined;
    for (word, 0..) |c, k| lower[k] = lowerAscii(c);
    try testing.expectEqualSlices(u8, lower[0..word.len], joined[0..n]);
}

test "splitter round-trip: corpus and fuzzed bytes never lose a byte" {
    const allocator = testing.allocator;
    const corpus = [_][]const u8{
        "habari", "yako", "asante", "karibu", "kujamba", "shuzi",
        "ng'oma", "mtu",   "nyumba", "kwenda", "ndiyo",  "mbwa",
        "HaBaRI", "Ng'OMA",
    };
    for (corpus) |word| try expectRoundTrip(allocator, word);

    // Seeded fuzz over letters, apostrophes and the odd high byte —
    // deterministic, and it must never panic or lose a byte.
    var prng = std.Random.DefaultPrng.init(0xF00D_C0DE);
    const r = prng.random();
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'";
    var buf: [24]u8 = undefined;
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        const n = r.uintAtMost(usize, buf.len);
        for (buf[0..n]) |*c| {
            c.* = if (r.uintLessThan(usize, 10) == 0) 0xC3 else alphabet[r.uintLessThan(usize, alphabet.len)];
        }
        try expectRoundTrip(allocator, buf[0..n]);
    }

    // And the words still fart: this test fails against silence too.
    const wav = try renderPhraseWav(allocator, corpus[0]);
    defer allocator.free(wav);
    try expectNotSilence(wav);
}
