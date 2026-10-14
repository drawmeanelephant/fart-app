//! synth.zig — Flatlophone v2: real fart synthesis + Swahili syllable engine.
//!
//! Pure Zig stdlib. Emits PCM WAV (RIFF), 44100 Hz, mono, 16-bit. No libc, no
//! file I/O: every render is a pure function of its input. The noise generator
//! is seeded from a hash of the input text with fixed constants everywhere
//! else, so the same phrase always produces byte-identical WAV bytes. Always.
//! The render path uses no libm transcendentals — sine comes from a comptime
//! table, exp/log from short polynomials — so the bytes are identical across
//! optimization modes and platforms too, not just across runs.
//!
//! One fart "phoneme" (one Swahili syllable) is a small physical model:
//!   * intestinal pressure vents exponentially across the syllable, and the
//!     pitch falls with it — a real fart drops as the pressure drops
//!   * a buzzy harmonic stack (the source) tilted by sphincter tension, then
//!     colored by the terminal tract: two formant resonators tuned by the
//!     syllable's vowel, plus a half-rate sub flutter for weight
//!   * filtered noise: a splat at the attack, a quiet low-passed body hiss,
//!     and a train of short noise bursts (turbulence) for wet, sputtering
//!     texture — all of it through the sphincter aperture
//!   * plosive onsets (p t k ch, b d g j) add a sudden pressure burst: an
//!     amplitude punch and a pitch pop in the first ~16 ms
//!   * an amplitude envelope with a fast attack, a decay to exact silence,
//!     and a ~24-34 Hz flutter wobble
//!
//! Swahili is nearly pure CV. `Scanner` splits a word into syllables: each
//! vowel picks the base pitch and the tract formants, the consonant onset
//! picks the attack/decay character and the physical parameters, and the
//! syllable count sets the total duration. The full mapping tables live in
//! docs/site/content/contributors/synth.md.
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

/// The pressure-venting exponent across one syllable at `decay = 1`: the
/// pressure — and with it the pitch — falls to `exp(-2.5)` ~ 8% of its
/// starting value by the syllable's end. The drop is exponential (fast at
/// first, settling late), because the gut vents fast when the sphincter
/// lets go and then only seeps.
const VENT_EXPONENT: f32 = 2.5;

/// Harmonics in the buzz. Rich enough that the tract's formants have
/// something to bite on: a four-harmonic stack of a 74-138 Hz fundamental
/// tops out below ~600 Hz, under every F1 in the vowel table.
const HARMONICS: usize = 12;

/// Base harmonic amplitudes, a ~1/h^1.1 rolloff. Sphincter tension tilts
/// this table (see `synthInto`); the tilted sum is normalised per syllable
/// so tension changes the color, not the level.
const HARMONIC_AMPS = [HARMONICS]f32{
    1.00, 0.55, 0.34, 0.22, 0.15, 0.105, 0.075, 0.055, 0.040, 0.030, 0.022, 0.016,
};

// ---------------------------------------------------------------------
// Deterministic math
// ---------------------------------------------------------------------

// The render path must be bit-identical across optimization modes and
// platforms: the golden fingerprints hash the rendered samples, and CI
// runs the suite in Debug and ReleaseSafe alike. Zig's `@sin`/`@cos`/
// `@exp` lower to libm calls, and LLVM inlines those differently at
// different optimization levels, so a handful of samples can land on the
// other side of an i16 rounding boundary. The synth therefore uses its
// own pure-arithmetic versions: a comptime sine table and short
// polynomial `exp`/`log`. Every operation below is exact or correctly
// rounded IEEE arithmetic, so the bits are the same everywhere — and the
// render path never touches libm at all.

const PI: f32 = std.math.pi;
const HALF_PI: f32 = std.math.pi / 2.0;
const QUARTER_PI: f32 = std.math.pi / 4.0;
const LN2: f32 = 0.6931471805599453;
const LOG2E: f32 = 1.4426950408889634;

/// sin on [-pi/4, pi/4]: odd Taylor series, error under 2e-9.
fn sinCore(x: f32) f32 {
    const x2 = x * x;
    return x * (1.0 + x2 * (-1.0 / 6.0 + x2 * (1.0 / 120.0 + x2 * (-1.0 / 5040.0 + x2 * (1.0 / 362880.0)))));
}

/// cos on [-pi/4, pi/4]: even Taylor series, error under 3e-10.
fn cosCore(x: f32) f32 {
    const x2 = x * x;
    return 1.0 + x2 * (-0.5 + x2 * (1.0 / 24.0 + x2 * (-1.0 / 720.0 + x2 * (1.0 / 40320.0 + x2 * (-1.0 / 3628800.0)))));
}

/// Deterministic sin for any angle: range-reduce, then a core polynomial.
fn approxSin(angle: f32) f32 {
    var x = @mod(angle, std.math.tau); // [0, 2pi)
    if (x >= PI) x -= std.math.tau; // [-pi, pi)
    var sign: f32 = 1.0;
    if (x < 0.0) {
        sign = -1.0;
        x = -x;
    } // [0, pi]
    if (x > HALF_PI) x = PI - x; // [0, pi/2]
    const use_cos = x > QUARTER_PI; // sin(x) = cos(pi/2 - x) past pi/4
    if (use_cos) x = HALF_PI - x; // [0, pi/4]
    return sign * (if (use_cos) cosCore(x) else sinCore(x));
}

const SIN_TABLE_BITS = 12;
const SIN_TABLE_LEN = 1 << SIN_TABLE_BITS; // 4096 entries per period
const SIN_TABLE_SCALE: f32 = @as(f32, @floatFromInt(SIN_TABLE_LEN)) / std.math.tau;
const SIN_TABLE_STEP: f32 = std.math.tau / @as(f32, @floatFromInt(SIN_TABLE_LEN));

/// One period of sine, baked at comptime: the same bits in every build
/// mode and on every platform.
const SIN_TABLE: [SIN_TABLE_LEN]f32 = blk: {
    @setEvalBranchQuota(100000); // 4096 entries, a few branches each
    var t: [SIN_TABLE_LEN]f32 = undefined;
    for (&t, 0..) |*e, k| {
        e.* = approxSin(@as(f32, @floatFromInt(k)) * SIN_TABLE_STEP);
    }
    break :blk t;
};

/// Sine of any phase from the table: exact mod, one multiply, one lerp.
/// The interpolation error (~3e-7) is far below audibility.
fn tableSin(phase: f32) f32 {
    const x = @mod(phase, std.math.tau) * SIN_TABLE_SCALE;
    const i = @as(usize, @intFromFloat(x));
    const frac = x - @as(f32, @floatFromInt(i));
    const a = SIN_TABLE[i];
    const b = SIN_TABLE[(i + 1) % SIN_TABLE_LEN];
    return a + (b - a) * frac;
}

/// Cosine of any phase: a quarter period ahead of the sine.
fn tableCos(phase: f32) f32 {
    return tableSin(phase + HALF_PI);
}

/// Deterministic exp, exact enough for audio over [-80, 88]: 2^k times a
/// polynomial, the power of two built from exponent bits (exact for
/// k in [-126, 127]). Below -80 the result is below the f32 noise floor
/// for audio and reads as 0.
fn approxExp(x: f32) f32 {
    if (x < -80.0) return 0.0;
    const y = x * LOG2E; // exp(x) = 2^y
    const k: i32 = @intFromFloat(@floor(y));
    const u = (y - @as(f32, @floatFromInt(k))) * LN2; // [0, ln2)
    // e^u by Horner to u^9; error under 6e-10 relative
    const p = 1.0 + u * (1.0 + u * (0.5 + u * (1.0 / 6.0 + u * (1.0 / 24.0 + u * (1.0 / 120.0 + u * (1.0 / 720.0 + u * (1.0 / 5040.0 + u * (1.0 / 40320.0 + u * (1.0 / 362880.0)))))))));
    const two_k: f32 = @bitCast(@as(u32, @intCast(k + 127)) << 23);
    return p * two_k;
}

/// Deterministic log for x > 0 (x <= 0 reads as -100, which `approxExp`
/// clamps to 0 — the right limit at a closing envelope).
fn approxLog(x: f32) f32 {
    if (x <= 0.0) return -100.0;
    const bits: u32 = @bitCast(x);
    const e: i32 = @as(i32, @intCast((bits >> 23) & 0xFF)) - 127;
    const m: f32 = @bitCast((bits & 0x007FFFFF) | 0x3F800000); // [1, 2)
    // log(m) = 2*atanh(s) with s = (m-1)/(m+1) in [0, 1/3): a fast series
    const s = (m - 1.0) / (m + 1.0);
    const s2 = s * s;
    const atanh = s * (1.0 + s2 * (1.0 / 3.0 + s2 * (1.0 / 5.0 + s2 * (1.0 / 7.0 + s2 * (1.0 / 9.0 + s2 * (1.0 / 11.0 + s2 * (1.0 / 13.0 + s2 * (1.0 / 15.0))))))));
    return @as(f32, @floatFromInt(e)) * LN2 + 2.0 * atanh;
}

/// Deterministic x^y for x > 0: exp(y * log(x)).
fn approxPow(x: f32, y: f32) f32 {
    return approxExp(y * approxLog(x));
}

/// base^k by repeated multiplication — the harmonic tilt's integer power.
fn intPower(base: f32, k: usize) f32 {
    var p: f32 = 1.0;
    for (0..k) |_| p *= base;
    return p;
}

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

/// The terminal tract: two formant frequencies (Hz). Each vowel colors the
/// buzz differently — `a` is open and boomy, `i` is bright and pinched, `u`
/// is dark and hollow. A consonant-only breath syllable (vowel 0) gets the
/// neutral "uh" of a whisper through the same tract.
pub const Formants = struct { f1: f32, f2: f32 };

/// The tract's formant pair for a vowel (0 = the neutral breath tract).
pub fn vowelFormants(v: u8) Formants {
    return switch (v) {
        'a' => .{ .f1 = 700.0, .f2 = 1150.0 },
        'e' => .{ .f1 = 460.0, .f2 = 1500.0 },
        'i' => .{ .f1 = 310.0, .f2 = 1900.0 },
        'o' => .{ .f1 = 430.0, .f2 = 820.0 },
        'u' => .{ .f1 = 320.0, .f2 = 720.0 },
        else => .{ .f1 = 520.0, .f2 = 1300.0 },
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
    /// Intestinal pressure behind the syllable: scales the level, a small
    /// pitch lift, the turbulence and the plosive burst (the renderer applies
    /// it to `VoiceParams`). Stops push hardest; nasals barely.
    pressure: f32,
    /// Sphincter tension: the aperture cutoff on the noise (150 Hz loose
    /// and wet .. 2450 Hz tight and raspy) plus the brightness tilt on the
    /// buzz. Fricatives clamp down hardest; nasals stay loose.
    tension: f32,
    /// Terminal tract resonance: formant gain and ring (Q). 0 is dry — the
    /// buzz with no tract color at all.
    resonance: f32,
    /// Noise-burst turbulence: the sputter amount. 0 is one smooth fart.
    turbulence: f32,
    /// Plosive pressure-burst strength: 1 for the stop classes (p t k ch,
    /// b d g j), 0 for everything else. The burst itself is a sudden
    /// pressure spike in the first ~16 ms of the syllable.
    burst: f32,
};

/// The onset-class table: attack/noise/wobble character (as before) plus the
/// physical parameters. The story each class tells: a stop is a sudden
/// pressure burst (thunderous pop), a fricative is a tight, raspy hiss with
/// lots of turbulence, a nasal is a loose, wet, resonant bubble, a liquid is
/// in between, and a bare vowel is neutral.
pub fn voiceSpec(cls: VoiceClass) VoiceSpec {
    return switch (cls) {
        .none => .{ .attack_s = 0.008, .noise_mix = 0.25, .wobble_hz = 28.0, .wobble_depth = 0.50, .level = 0.90, .pressure = 1.00, .tension = 1.00, .resonance = 1.00, .turbulence = 0.30, .burst = 0.00 },
        .stop_voiceless => .{ .attack_s = 0.004, .noise_mix = 0.40, .wobble_hz = 32.0, .wobble_depth = 0.55, .level = 0.95, .pressure = 1.15, .tension = 1.25, .resonance = 0.90, .turbulence = 0.55, .burst = 1.00 },
        .stop_voiced => .{ .attack_s = 0.006, .noise_mix = 0.28, .wobble_hz = 30.0, .wobble_depth = 0.50, .level = 1.00, .pressure = 1.25, .tension = 1.10, .resonance = 0.85, .turbulence = 0.45, .burst = 1.00 },
        .fricative => .{ .attack_s = 0.010, .noise_mix = 0.50, .wobble_hz = 29.0, .wobble_depth = 0.45, .level = 0.90, .pressure = 0.90, .tension = 1.45, .resonance = 0.80, .turbulence = 0.70, .burst = 0.00 },
        .nasal => .{ .attack_s = 0.025, .noise_mix = 0.12, .wobble_hz = 26.0, .wobble_depth = 0.35, .level = 0.85, .pressure = 0.75, .tension = 0.70, .resonance = 1.10, .turbulence = 0.20, .burst = 0.00 },
        .liquid => .{ .attack_s = 0.014, .noise_mix = 0.18, .wobble_hz = 28.0, .wobble_depth = 0.45, .level = 0.90, .pressure = 0.95, .tension = 0.90, .resonance = 1.05, .turbulence = 0.35, .burst = 0.00 },
    };
}

/// Per-run tuning of the synthesis. Multipliers rather than absolutes, so an
/// onset class keeps its character — `--voice wobble=2` doubles the wobble of
/// every class instead of flattening them all to one number.
///
/// Three axes ride on the onset-class table (`attack`, `noise`, `wobble`);
/// `intensity` (#15) and `cents` (#16) are applied by the renderer, because
/// neither belongs to the onset class; and the five physical-model axes —
/// `pressure`, `tension`, `resonance`, `decay`, `turbulence` — tune the gut,
/// the sphincter and the tract that the class table sets up. `decay` is
/// applied by the renderer too (it is a rate, not a per-class character).
///
/// The default is 1.0 on every multiplier and 0 on `cents`, and `x * 1.0` is
/// exact in IEEE-754, so an untouched `VoiceKnobs` reproduces the class table
/// bit for bit. That is load-bearing, not decorative: the identity tests
/// below assert it at the byte level, and a preset that spells out every
/// default must not move a single sample.
pub const VoiceKnobs = struct {
    /// scales `attack_s`
    attack: f32 = 1.0,
    /// scales `noise_mix`
    noise: f32 = 1.0,
    /// scales `wobble_depth` — how deep the flutter is, not how fast
    wobble: f32 = 1.0,
    /// #15: vocal effort. Scales a syllable's level and noise mix together and
    /// rides on the stress emphasis, so one number moves a phrase from a
    /// whisper (quiet, clean, flat) to a shout (loud, splatty, spiky).
    /// Parsed values are clamped into `min_intensity..max_intensity` when
    /// applied, the same way `attack = 0` becomes `min_attack_s`.
    intensity: f32 = 1.0,
    /// #16: shifts every vowel's base frequency by cents (1200 = one octave
    /// up, -1200 down), so a preset can pick a different "instrument". An
    /// offset, not a multiplier — negative is meaningful, not an error.
    cents: f32 = 0.0,
    /// Intestinal pressure: thunder. Scales a syllable's level, its pitch
    /// lift, its turbulence and its plosive burst — a gut pushed harder is
    /// louder, sharper and sputterier. Clamped like effort.
    pressure: f32 = 1.0,
    /// Sphincter tension: the aperture cutoff on the noise (150 Hz loose and
    /// wet .. 2450 Hz tight and raspy) plus the buzz's brightness tilt.
    tension: f32 = 1.0,
    /// Terminal tract resonance: formant gain and ring. 0 is dry — the buzz
    /// with no tract color at all.
    resonance: f32 = 1.0,
    /// Pitch-decay rate: how fast the pitch falls as the pressure vents.
    /// 0 freezes the pitch flat; 1 is the stock exponential drop.
    decay: f32 = 1.0,
    /// Noise-burst turbulence: the sputter. 0 is one smooth, dry fart.
    turbulence: f32 = 1.0,

    /// Bounds on the *resulting* spec, not on the multipliers. Each one exists
    /// because the value feeds arithmetic that breaks outside its range.
    pub const min_attack_s: f32 = 0.0005; // 0.5ms; 0 makes sample 0 compute 0/0 -> NaN
    pub const max_attack_s: f32 = 0.200;
    pub const max_noise_mix: f32 = 1.0; // past 1 it is the same noise, just clipped
    /// past 2, `wob = 1 - depth * (...)` goes negative and flips the
    /// waveform's polarity — that is distortion, not chaos
    pub const max_wobble_depth: f32 = 1.0;
    /// #15: the effort range. Past 4 the shout is pinned at the 0.95 sample
    /// ceiling anyway; below 0.25 the phrase stops being audible at all, and
    /// 0 would make it exactly silent.
    pub const min_intensity: f32 = 0.25;
    pub const max_intensity: f32 = 4.0;
    /// #15: the stressed syllable's emphasis under effort. A whisper flattens
    /// the word's dynamics entirely (1.0 = no emphasis), a shout caps at twice
    /// the stock 1.2 — past that the syllable just clips.
    pub const min_stress_boost: f32 = 1.0;
    pub const max_stress_boost: f32 = 2.4;
    /// #16: one octave either way. Beyond that the buzzy oscillator leaves the
    /// instrument's register (at -1200 the lowest vowel is a 37 Hz rumble).
    pub const max_abs_cents: f32 = 1200.0;
    /// Pressure shares effort's range: past 4 the syllable is pinned at the
    /// 0.95 sample ceiling anyway; below 0.25 the phrase stops being audible.
    pub const min_pressure: f32 = 0.25;
    pub const max_pressure: f32 = 4.0;
    /// Tension is an aperture: 0 is wide open (wet), 2 is clamped tight
    /// (raspy). Past 2 the aperture is a hiss and the buzz is all brightness.
    pub const max_tension: f32 = 2.0;
    /// Resonance past 3 rings so hard the formants swallow the fundamental.
    pub const max_resonance: f32 = 3.0;
    /// Decay past 8 vents the whole syllable inside its first ~30 ms; 0
    /// freezes the pitch (no venting at all).
    pub const max_decay: f32 = 8.0;
    /// Turbulence past 4 is the same sputter, just clipped.
    pub const max_turbulence: f32 = 4.0;
    /// The plosive burst rides on pressure; past 4 the pop is a whole extra
    /// syllable of amplitude at the onset.
    pub const max_burst: f32 = 4.0;

    /// `2^(cents/1200)` — the factor every base frequency is multiplied by,
    /// with `cents` clamped to one octave either way. The `cents == 0` branch
    /// is load-bearing: the untouched knobs must be a *bit-exact* identity
    /// (the golden fingerprints assert it), and `x * 1.0` is exact in IEEE-754
    /// in a way `pow` is only ever allowed to be, not guaranteed to be.
    pub fn pitchFactor(self: VoiceKnobs) f32 {
        if (self.cents == 0) return 1.0;
        const c = std.math.clamp(self.cents, -max_abs_cents, max_abs_cents);
        return approxExp(c / 1200.0 * LN2); // 2^(c/1200) = e^(c*ln2/1200)
    }

    /// The effort value the renderer actually applies: `intensity` clamped
    /// into its useful range, so a preset can never mute the instrument.
    pub fn effort(self: VoiceKnobs) f32 {
        return std.math.clamp(self.intensity, min_intensity, max_intensity);
    }

    /// The pitch-decay rate the renderer actually applies: `decay` clamped
    /// into its useful range. 0 freezes the pitch (the pressure never vents),
    /// 1 is the stock exponential drop, past 8 the pitch hits its floor
    /// almost at the onset.
    pub fn pitchDecay(self: VoiceKnobs) f32 {
        return std.math.clamp(self.decay, 0.0, max_decay);
    }

    /// The class table with the knobs applied. `wobble_hz` is deliberately
    /// untouched: the knob is on the depth of the flutter, and the rate is
    /// part of each class's character. `intensity`, `cents` and `decay` are
    /// applied by the renderer (see above), not here. `burst` is mapped from
    /// the onset class, so no knob scales it directly — pressure does that at
    /// render time.
    pub fn apply(self: VoiceKnobs, spec: VoiceSpec) VoiceSpec {
        return .{
            .attack_s = std.math.clamp(spec.attack_s * self.attack, min_attack_s, max_attack_s),
            .noise_mix = std.math.clamp(spec.noise_mix * self.noise, 0.0, max_noise_mix),
            .wobble_hz = spec.wobble_hz,
            .wobble_depth = std.math.clamp(spec.wobble_depth * self.wobble, 0.0, max_wobble_depth),
            .level = spec.level,
            .pressure = std.math.clamp(spec.pressure * self.pressure, min_pressure, max_pressure),
            .tension = std.math.clamp(spec.tension * self.tension, 0.0, max_tension),
            .resonance = std.math.clamp(spec.resonance * self.resonance, 0.0, max_resonance),
            .turbulence = std.math.clamp(spec.turbulence * self.turbulence, 0.0, max_turbulence),
            .burst = spec.burst,
        };
    }
};

pub const KnobsError = error{ UnknownKnob, MalformedKnob, NotFinite, Negative };

/// Parse `attack=1.2,noise=0.8,wobble=2` into multipliers. Order is free and
/// whitespace around keys and values is ignored; an empty string is the
/// identity, which is what `--voice ""` and an omitted flag both mean.
/// `intensity` and `cents` (#15, #16) take the same spelling: `intensity` is
/// a multiplier (>= 0), `cents` an offset in cents and the one key a negative
/// value is meaningful for. The physical-model axes (`pressure`, `tension`,
/// `resonance`, `decay`, `turbulence`) are multipliers like `intensity`.
pub fn parseKnobs(s: []const u8) KnobsError!VoiceKnobs {
    var knobs = VoiceKnobs{};
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return error.MalformedKnob;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        const v = std.fmt.parseFloat(f32, std.mem.trim(u8, trimmed[eq + 1 ..], " \t")) catch
            return error.MalformedKnob;
        if (!std.math.isFinite(v)) return error.NotFinite;
        if (v < 0 and !std.mem.eql(u8, key, "cents")) return error.Negative;
        if (std.mem.eql(u8, key, "attack")) {
            knobs.attack = v;
        } else if (std.mem.eql(u8, key, "noise")) {
            knobs.noise = v;
        } else if (std.mem.eql(u8, key, "wobble")) {
            knobs.wobble = v;
        } else if (std.mem.eql(u8, key, "intensity")) {
            knobs.intensity = v;
        } else if (std.mem.eql(u8, key, "cents")) {
            knobs.cents = v;
        } else if (std.mem.eql(u8, key, "pressure")) {
            knobs.pressure = v;
        } else if (std.mem.eql(u8, key, "tension")) {
            knobs.tension = v;
        } else if (std.mem.eql(u8, key, "resonance")) {
            knobs.resonance = v;
        } else if (std.mem.eql(u8, key, "decay")) {
            knobs.decay = v;
        } else if (std.mem.eql(u8, key, "turbulence")) {
            knobs.turbulence = v;
        } else return error.UnknownKnob;
    }
    return knobs;
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
    /// Intestinal pressure (knob-scaled): level, pitch lift, turbulence and
    /// burst strength all ride on it.
    pressure: f32,
    /// Sphincter tension (knob-scaled): aperture cutoff + buzz brightness.
    tension: f32,
    /// Terminal tract resonance (knob-scaled): formant gain and ring.
    resonance: f32,
    /// Noise-burst turbulence (knob-scaled, pressure-scaled at render time).
    turbulence: f32,
    /// Plosive pressure-burst strength (0 = not a stop).
    burst: f32,
    /// Terminal tract formant 1 (Hz), from the syllable's vowel.
    f1: f32,
    /// Terminal tract formant 2 (Hz), from the syllable's vowel.
    f2: f32,
    /// Pitch-decay rate (the `decay` knob, clamped): 0 freezes the pitch,
    /// 1 is the stock exponential vent.
    decay: f32,
};

/// One formant resonator: an RBJ bandpass biquad with constant skirt gain,
/// so the peak gain is Q — a real resonance, not a 0 dB pass-through. Two
/// of these, tuned to the syllable's vowel, are the terminal tract. Pure
/// mul/add/sub state, driven by the table sine — bit-exact across
/// optimization modes and platforms.
const Formant = struct {
    b0: f32,
    b2: f32,
    a1: f32,
    a2: f32,
    x1: f32 = 0,
    x2: f32 = 0,
    y1: f32 = 0,
    y2: f32 = 0,

    fn init(freq: f32, q: f32) Formant {
        const w0: f32 = std.math.tau * freq / @as(f32, SAMPLE_RATE);
        const alpha: f32 = tableSin(w0) / (2.0 * q);
        const a0: f32 = 1.0 + alpha;
        // constant skirt gain, peak gain = Q: b0 = Q*alpha, b2 = -Q*alpha
        const b: f32 = q * alpha / a0;
        return .{
            .b0 = b,
            .b2 = -b,
            .a1 = -2.0 * tableCos(w0) / a0,
            .a2 = (1.0 - alpha) / a0,
        };
    }

    fn tick(f: *Formant, x: f32) f32 {
        const y = f.b0 * x + f.b2 * f.x2 - f.a1 * f.y1 - f.a2 * f.y2;
        f.x2 = f.x1;
        f.x1 = x;
        f.y2 = f.y1;
        f.y1 = y;
        return y;
    }
};

/// #15: one syllable's spec under vocal effort `eff`. Level and noise mix
/// scale together — a shout is louder *and* splattier, a whisper quiet and
/// clean — with the stress emphasis applied on top by the caller for the one
/// stressed syllable. The noise clamp matches the `noise` knob's: past 1 it
/// is the same noise, just clipped.
fn applyEffort(p: *VoiceParams, eff: f32) void {
    p.level *= eff;
    p.noise_mix = std.math.clamp(p.noise_mix * eff, 0.0, VoiceKnobs.max_noise_mix);
}

/// The stressed syllable's loudness emphasis under effort `eff`: the stock
/// 1.2 scales with intensity up to twice stock, and a whisper flattens the
/// word's dynamics to no emphasis at all.
fn stressBoost(eff: f32) f32 {
    return std.math.clamp(STRESS_LEVEL_BOOST * eff, VoiceKnobs.min_stress_boost, VoiceKnobs.max_stress_boost);
}

/// Renders one fart phoneme into `out` (mono i16). Deterministic: the only
/// randomness comes from `prng`, whose seed is fixed per render, and every
/// prng draw happens a fixed number of times per syllable. Every float
/// operation is exact or correctly rounded IEEE arithmetic — no libm —
/// so the samples are bit-identical across optimization modes as well.
fn synthInto(out: []i16, p: VoiceParams, prng: *std.Random.DefaultPrng) void {
    const dt: f32 = 1.0 / @as(f32, SAMPLE_RATE);
    const tau: f32 = std.math.tau;
    const n = out.len;
    if (n == 0) return;
    const dur: f32 = @as(f32, @floatFromInt(n)) * dt; // syllable length, seconds

    // Intestinal pressure vents exponentially across the syllable; `decay=0`
    // freezes it (and the pitch) flat. The pitch rides the pressure down to
    // `1 - glide` of its starting value, like a real fart losing steam.
    const vent: f32 = VENT_EXPONENT * p.decay;
    const floor: f32 = 1.0 - p.glide;

    // Sphincter aperture: a one-pole lowpass on the noise, 150 Hz (loose,
    // wet) to 2450 Hz (tight, raspy).
    const alpha_ap: f32 = 1.0 - approxExp(-tau * (150.0 + 1150.0 * p.tension) * dt);
    const alpha_body: f32 = 1.0 - approxExp(-tau * 700.0 * dt);
    const alpha_burst: f32 = 1.0 - approxExp(-tau * 1900.0 * dt);

    // Terminal tract: two formant resonators at the vowel's F1/F2, ringing
    // harder as resonance rises.
    var f1 = Formant.init(p.f1, 2.0 + 7.0 * p.resonance);
    var f2 = Formant.init(p.f2, 2.0 + 7.0 * p.resonance);

    // Buzz brightness: the harmonic tilt from tension (0.8 loose .. 1.7
    // tight). The tilted stack is normalised so tension colors, not levels.
    const tilt: f32 = 0.8 + 0.45 * p.tension;
    var amps: [HARMONICS]f32 = undefined;
    var amp_sum: f32 = 0;
    for (0..HARMONICS) |k| {
        const a = HARMONIC_AMPS[k] * intPower(tilt, k);
        amps[k] = a;
        amp_sum += a;
    }

    // Flutter wobble (seeded per syllable).
    const wobble_phase: f32 = prng.random().float(f32) * tau;
    const wobble_hz: f32 = p.wobble_hz * (0.9 + 0.2 * prng.random().float(f32));

    // Turbulence: a fixed train of short noise bursts, positions seeded per
    // syllable. `turbulence` scales their gain; 0 silences the sputter.
    const n_bursts = 8;
    var b_t0: [n_bursts]f32 = undefined;
    var b_len: [n_bursts]f32 = undefined;
    var b_gain: [n_bursts]f32 = undefined;
    for (0..n_bursts) |k| {
        const r = prng.random();
        b_t0[k] = (0.02 + 0.83 * r.float(f32)) * dur;
        b_len[k] = 0.004 + 0.026 * r.float(f32);
        b_gain[k] = 0.5 + 0.5 * r.float(f32);
    }

    var phase: f32 = 0;
    var lp_body: f32 = 0;
    var lp_burst: f32 = 0;
    var lp_ap: f32 = 0;
    for (0..n) |i| {
        const fi: f32 = @floatFromInt(i);
        const t = fi * dt;
        const u = fi / @as(f32, @floatFromInt(n));

        // Pressure venting + exponential pitch decay; the plosive's pressure
        // burst pops the pitch a little at the onset.
        const press = approxExp(-t * vent / dur);
        const pop = p.burst * approxExp(-t / 0.016);
        const f = p.f0 * (floor + (1.0 - floor) * press) * (1.0 + 0.05 * pop);
        phase += tau * f * dt;
        if (phase >= tau) phase -= tau;

        // The buzz: a harmonic stack, tilted by tension, plus a half-rate
        // sub flutter for weight.
        var buzz: f32 = 0;
        for (0..HARMONICS) |k| {
            buzz += amps[k] * tableSin(@as(f32, @floatFromInt(k + 1)) * phase);
        }
        buzz = buzz / amp_sum * 0.78;
        const sub = 0.28 * tableSin(0.5 * phase);

        // Noise: body hiss + attack splat + turbulence bursts, all through
        // the sphincter aperture.
        const wn_body = prng.random().float(f32) * 2.0 - 1.0;
        lp_body += alpha_body * (wn_body - lp_body);
        const wn_burst = prng.random().float(f32) * 2.0 - 1.0;
        lp_burst += alpha_burst * (wn_burst - lp_burst);
        const wn_turb = prng.random().float(f32) * 2.0 - 1.0;
        var turb: f32 = 0;
        for (0..n_bursts) |k| {
            if (t > b_t0[k]) turb += b_gain[k] * approxExp(-(t - b_t0[k]) / b_len[k]);
        }
        const splat = approxExp(-t / 0.045);
        const noise_in = lp_body * 0.35 +
            lp_burst * (0.9 * splat + 0.55 * pop) +
            wn_turb * (2.0 * p.turbulence * turb);
        lp_ap += alpha_ap * (noise_in - lp_ap);

        // The tract: formants color the buzz; a dry leak keeps the
        // fundamental's weight under them.
        const tract = p.resonance * (f1.tick(buzz) + 0.7 * f2.tick(buzz)) + 0.46 * buzz;

        // Envelope: fast attack, pressure-shaped decay to exact silence,
        // plosive punch, flutter wobble.
        const attack = @min(1.0, t / p.attack_s);
        const decay = approxPow(1.0 - u, 1.3);
        const env = attack * decay * (0.7 + 0.3 * press) * (1.0 + 0.45 * pop);
        const wob = 1.0 - p.wobble_depth * (0.5 + 0.5 * tableSin(tau * wobble_hz * t + wobble_phase));

        var x = (tract + sub + p.noise_mix * lp_ap) * env * wob * p.level;
        if (x > 0.95) x = 0.95;
        if (x < -0.95) x = -0.95;
        out[i] = @intFromFloat(@round(x * 32767.0));
    }
    // The syllable ends at exact silence: the resonators ring past the
    // envelope's reach, so pin the last sample to zero and keep loop wraps
    // click-free whatever the knobs are set to.
    out[n - 1] = 0;
}

fn renderSyllableInto(out: []i16, syl: *const Syll, stressed: bool, prng: *std.Random.DefaultPrng, knobs: VoiceKnobs) void {
    const eff = knobs.effort();
    const pitch = knobs.pitchFactor();
    const decay = knobs.pitchDecay();
    var p: VoiceParams = undefined;
    if (syl.vowel == 0) {
        // Consonant-only tail: a short whisper, not a buzz. The knobs reach this
        // literal too, so `--voice noise=0` means "no noise anywhere" rather
        // than "no noise except on the rare breath syllable".
        const spec = knobs.apply(.{ .attack_s = 0.006, .noise_mix = 0.85, .wobble_hz = 31.0, .wobble_depth = 0.30, .level = 0.65, .pressure = 0.60, .tension = 0.80, .resonance = 0.70, .turbulence = 0.50, .burst = 0.00 });
        const fm = vowelFormants(0); // the breath still passes a tract
        p = .{ .f0 = 88.0 * pitch, .attack_s = spec.attack_s, .noise_mix = spec.noise_mix, .wobble_hz = spec.wobble_hz, .wobble_depth = spec.wobble_depth, .level = spec.level, .glide = 0.15, .pressure = spec.pressure, .tension = spec.tension, .resonance = spec.resonance, .turbulence = spec.turbulence, .burst = spec.burst, .f1 = fm.f1, .f2 = fm.f2, .decay = decay };
        applyEffort(&p, eff);
    } else {
        const spec = knobs.apply(voiceSpec(classify(syl.onset())));
        const fm = vowelFormants(syl.vowel);
        p = .{
            .f0 = vowelBaseFreq(syl.vowel).? * pitch,
            .attack_s = spec.attack_s,
            .noise_mix = spec.noise_mix,
            .wobble_hz = spec.wobble_hz,
            .wobble_depth = spec.wobble_depth,
            .level = spec.level,
            .glide = PITCH_DROP,
            .pressure = spec.pressure,
            .tension = spec.tension,
            .resonance = spec.resonance,
            .turbulence = spec.turbulence,
            .burst = spec.burst,
            .f1 = fm.f1,
            .f2 = fm.f2,
            .decay = decay,
        };
        applyEffort(&p, eff);
        // Swahili stresses the penultimate syllable of a word. The emphasis
        // rides on effort (#15): a shout pushes it past the stock 1.2, and a
        // whisper flatlines it — a whispered word has no dynamic shape. The
        // stressed syllable is also pushed harder: more pressure, more thunder.
        if (stressed) {
            p.level *= stressBoost(eff);
            p.pressure *= 1.15;
        }
    }
    // Intestinal pressure: thunder is louder, sharper and sputterier. The
    // level rides it directly; turbulence and the plosive burst ride it too,
    // and the pitch lifts a little as the gut is squeezed.
    p.level *= p.pressure;
    p.turbulence = std.math.clamp(p.turbulence * p.pressure, 0.0, VoiceKnobs.max_turbulence);
    p.burst = std.math.clamp(p.burst * p.pressure, 0.0, VoiceKnobs.max_burst);
    // Per-syllable jitter, still a pure function of (phrase, syllable index).
    const r = prng.random();
    p.f0 *= 1.0 + (r.float(f32) - 0.5) * 0.06;
    p.f0 *= 1.0 + 0.10 * (p.pressure - 1.0);
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
    return renderPhraseSamplesWith(allocator, phrase, .{});
}

/// `renderPhraseSamples` with the voice knobs applied. The default `{}` is the
/// identity and is byte-identical to `renderPhraseSamples` — the golden
/// fingerprints in `src/golden.zig` depend on that and assert it.
pub fn renderPhraseSamplesWith(allocator: std.mem.Allocator, phrase: []const u8, knobs: VoiceKnobs) ![]i16 {
    var plan = try planPhrase(allocator, phrase);
    defer plan.deinit(allocator);
    if (plan.items.len == 0) return error.NoSyllables;
    const samples = try allocator.alloc(i16, plan.total_samples);
    errdefer allocator.free(samples);
    @memset(samples, 0);
    var prng = std.Random.DefaultPrng.init(std.hash.Wyhash.hash(0x5EED_F00D, phrase));
    for (plan.items) |item| {
        renderSyllableInto(samples[item.start..][0..item.len], &item.syl, item.stressed, &prng, knobs);
    }
    return samples;
}

/// Renders a phrase straight to complete WAV bytes (44-byte header + data).
pub fn renderPhraseWav(allocator: std.mem.Allocator, phrase: []const u8) ![]u8 {
    return renderPhraseWavWith(allocator, phrase, .{});
}

/// `renderPhraseWav` with the voice knobs applied. `{}` is byte-identical to
/// `renderPhraseWav`.
pub fn renderPhraseWavWith(allocator: std.mem.Allocator, phrase: []const u8, knobs: VoiceKnobs) ![]u8 {
    const samples = try renderPhraseSamplesWith(allocator, phrase, knobs);
    defer allocator.free(samples);
    return writeWavBytes(allocator, samples, SAMPLE_RATE);
}

/// A wordless shuzi (a fart): 1-3 rumble syllables with random-ish timing,
/// pitch and onset character. Deterministic per seed.
pub fn renderShuziWav(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    return renderShuziWavWith(allocator, seed, .{});
}

/// `renderShuziWav` with the voice knobs applied. `{}` is byte-identical to
/// `renderShuziWav`. Effort (#15) scales the rumble's level and noise mix;
/// `cents` does not apply — a shuzi has no vowels, its pitch is random. The
/// physical model does apply: every seed draws its own pressure, tension,
/// resonance, turbulence and tract, so every shuzi is a different rumble.
pub fn renderShuziWavWith(allocator: std.mem.Allocator, seed: u64, knobs: VoiceKnobs) ![]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const n_syl: usize = 1 + r.uintLessThan(usize, 3);
    const Seg = struct { params: VoiceParams, len: usize, gap_after: usize };
    var segs: [3]Seg = undefined;
    var total: usize = 0;
    const eff = knobs.effort();
    const decay = knobs.pitchDecay();
    var i: usize = 0;
    while (i < n_syl) : (i += 1) {
        const dur_ms: usize = (16 + r.uintLessThan(usize, 19)) * 10; // 160..340 ms
        const classes = [_]VoiceClass{ .stop_voiced, .stop_voiceless, .fricative, .nasal, .liquid };
        const spec = knobs.apply(voiceSpec(classes[r.uintLessThan(usize, classes.len)]));
        const gap_ms: usize = if (i + 1 < n_syl) (3 + r.uintLessThan(usize, 5)) * 10 else 0; // 30..70 ms
        // A shuzi has no vowels, so its tract is random too.
        const f1: f32 = 250.0 + 650.0 * r.float(f32);
        const f2: f32 = 700.0 + 1500.0 * r.float(f32);
        var p = VoiceParams{
            .f0 = 70.0 + 40.0 * r.float(f32),
            .attack_s = spec.attack_s,
            // no clamp: this path's +0.10 already sits past the class
            // table's 1.0 cap; effort multiplies what is there
            .noise_mix = (spec.noise_mix + 0.10) * eff,
            .wobble_hz = 24.0 + 10.0 * r.float(f32),
            .wobble_depth = 0.45 + 0.15 * r.float(f32),
            .level = 1.0 * eff,
            .glide = PITCH_DROP,
            .pressure = spec.pressure,
            .tension = spec.tension,
            .resonance = spec.resonance,
            .turbulence = spec.turbulence,
            .burst = spec.burst,
            .f1 = f1,
            .f2 = f2,
            .decay = decay,
        };
        // the same pressure arithmetic a sung syllable gets
        p.level *= p.pressure;
        p.turbulence = std.math.clamp(p.turbulence * p.pressure, 0.0, VoiceKnobs.max_turbulence);
        p.burst = std.math.clamp(p.burst * p.pressure, 0.0, VoiceKnobs.max_burst);
        segs[i] = .{
            .params = p,
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
/// RIFF sizes are u32, so a PCM payload too large for the `data` chunk (and
/// the RIFF size field, which is data_len + 36) fails with PcmTooLarge.
pub fn writeWavBytes(allocator: std.mem.Allocator, samples: []const i16, sample_rate: u32) ![]u8 {
    const data_bytes = std.math.mul(usize, samples.len, 2) catch return error.PcmTooLarge;
    if (data_bytes > std.math.maxInt(u32) - 36) return error.PcmTooLarge;
    const data_len: u32 = @intCast(data_bytes);
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

test "writeWavBytes returns PcmTooLarge instead of panicking past the RIFF limit" {
    // Fake slices are never dereferenced: the check fires before any read.
    const fake: [*]const i16 = @ptrFromInt(0x1000);
    // #78: samples.len * 2 alone does not fit the u32 data chunk size.
    const too_big = fake[0..(@as(usize, 1) << 31)];
    try testing.expectError(error.PcmTooLarge, writeWavBytes(testing.allocator, too_big, SAMPLE_RATE));
    // data_len fits u32 but the RIFF size field (data_len + 36) would not.
    const riff_overflow = fake[0 .. (std.math.maxInt(u32) - 36) / 2 + 1];
    try testing.expectError(error.PcmTooLarge, writeWavBytes(testing.allocator, riff_overflow, SAMPLE_RATE));
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
        "habari", "yako",   "asante", "karibu", "kujamba", "shuzi",
        "ng'oma", "mtu",    "nyumba", "kwenda", "ndiyo",   "mbwa",
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

// --------------------------------------------------------------------------
// voice knobs (#18)
// --------------------------------------------------------------------------

test "voice knobs: the default is the identity, byte for byte" {
    const alloc = testing.allocator;

    // The acceptance criterion for #18 is that defaults reproduce today's sound
    // exactly. Assert it at the byte level rather than trusting that `x * 1.0`
    // is a no-op, and cover all three public entry points.
    const plain = try renderPhraseSamples(alloc, "kujamba karibu");
    defer alloc.free(plain);
    const knobbed = try renderPhraseSamplesWith(alloc, "kujamba karibu", .{});
    defer alloc.free(knobbed);
    try testing.expectEqualSlices(i16, plain, knobbed);

    const plain_wav = try renderPhraseWav(alloc, "asante sana");
    defer alloc.free(plain_wav);
    const knobbed_wav = try renderPhraseWavWith(alloc, "asante sana", .{});
    defer alloc.free(knobbed_wav);
    try testing.expectEqualSlices(u8, plain_wav, knobbed_wav);

    const plain_shuzi = try renderShuziWav(alloc, 42);
    defer alloc.free(plain_shuzi);
    const knobbed_shuzi = try renderShuziWavWith(alloc, 42, .{});
    defer alloc.free(knobbed_shuzi);
    try testing.expectEqualSlices(u8, plain_shuzi, knobbed_shuzi);
}

test "voice knobs: spelling out 1,1,1 is still the identity" {
    const alloc = testing.allocator;
    // a preset that sets every knob explicitly to its default must not move a
    // single sample, or every saved preset becomes a silent audio change
    const plain = try renderPhraseWav(alloc, "kujamba karibu");
    defer alloc.free(plain);
    const explicit = try renderPhraseWavWith(
        alloc,
        "kujamba karibu",
        .{ .attack = 1.0, .noise = 1.0, .wobble = 1.0, .intensity = 1.0, .cents = 0.0, .pressure = 1.0, .tension = 1.0, .resonance = 1.0, .decay = 1.0, .turbulence = 1.0 },
    );
    defer alloc.free(explicit);
    try testing.expectEqualSlices(u8, plain, explicit);

    // and the empty string parses to the same identity
    const from_flag = try renderPhraseWavWith(alloc, "kujamba karibu", try parseKnobs(""));
    defer alloc.free(from_flag);
    try testing.expectEqualSlices(u8, plain, from_flag);
    const round_trip = try renderPhraseWavWith(alloc, "kujamba karibu", try parseKnobs("attack=1, noise=1 ,wobble=1,intensity=1,cents=0,pressure=1,tension=1,resonance=1,decay=1,turbulence=1"));
    defer alloc.free(round_trip);
    try testing.expectEqualSlices(u8, plain, round_trip);
}

test "voice knobs: each axis actually changes the audio" {
    const alloc = testing.allocator;
    const plain = try renderPhraseWav(alloc, "kujamba karibu");
    defer alloc.free(plain);

    const axes = [_]struct { name: []const u8, knobs: VoiceKnobs }{
        .{ .name = "attack", .knobs = .{ .attack = 2.0 } },
        .{ .name = "noise", .knobs = .{ .noise = 0.0 } },
        .{ .name = "noise up", .knobs = .{ .noise = 2.0 } },
        .{ .name = "wobble", .knobs = .{ .wobble = 0.0 } },
        .{ .name = "wobble up", .knobs = .{ .wobble = 2.0 } },
        .{ .name = "intensity", .knobs = .{ .intensity = 2.0 } },
        .{ .name = "cents up", .knobs = .{ .cents = 700 } },
        .{ .name = "cents down", .knobs = .{ .cents = -700 } },
        // the physical model
        .{ .name = "pressure", .knobs = .{ .pressure = 2.0 } },
        .{ .name = "pressure down", .knobs = .{ .pressure = 0.5 } },
        .{ .name = "tension", .knobs = .{ .tension = 1.8 } },
        .{ .name = "tension loose", .knobs = .{ .tension = 0.2 } },
        .{ .name = "resonance dry", .knobs = .{ .resonance = 0.0 } },
        .{ .name = "resonance ringy", .knobs = .{ .resonance = 2.5 } },
        .{ .name = "decay flat", .knobs = .{ .decay = 0.0 } },
        .{ .name = "decay fast", .knobs = .{ .decay = 4.0 } },
        .{ .name = "turbulence off", .knobs = .{ .turbulence = 0.0 } },
        .{ .name = "turbulence up", .knobs = .{ .turbulence = 2.5 } },
    };
    for (axes) |ax| {
        const out = try renderPhraseWavWith(alloc, "kujamba karibu", ax.knobs);
        defer alloc.free(out);
        try testing.expect(!std.mem.eql(u8, plain, out));
    }
}

test "voice knobs: extremes are clamped, never NaN and never inverted" {
    const alloc = testing.allocator;
    // attack=0 would make sample 0 compute 0/0, and `@intFromFloat(NaN)` is a
    // panic, so this test passing at all is the proof there is no NaN.
    // wobble=10 would drive `wob` negative and flip the waveform's polarity.
    const wild = [_]VoiceKnobs{
        .{ .attack = 0.0, .noise = 0.0, .wobble = 0.0 },
        .{ .attack = 0.0, .noise = 99.0, .wobble = 99.0 },
        .{ .attack = 1e9, .noise = 1e9, .wobble = 1e9 },
        .{ .intensity = 0.0, .cents = -1e9 },
        .{ .intensity = 1e9, .cents = 1e9, .noise = 1e9 },
        // the physical model: zeroed and absurd on every axis at once
        .{ .pressure = 0.0, .tension = 0.0, .resonance = 0.0, .decay = 0.0, .turbulence = 0.0 },
        .{ .pressure = 1e9, .tension = 1e9, .resonance = 1e9, .decay = 1e9, .turbulence = 1e9 },
    };
    for (wild) |knobs| {
        const out = try renderPhraseSamplesWith(alloc, "kujamba karibu", knobs);
        defer alloc.free(out);
        try testing.expect(out.len > 1000);
        try testing.expect(rmsOf(out) > 1.0); // still real audio, not silence
        // and the shuzi path takes the same wild knobs without NaN either
        const rumble = try renderShuziWavWith(alloc, 42, knobs);
        defer alloc.free(rumble);
        try testing.expect(rumble.len > 44);
    }

    // the bounds themselves, so a future edit to the clamps is visible
    const base = voiceSpec(.stop_voiceless); // attack 4ms, noise 0.40, wobble 0.55
    const zeroed = (VoiceKnobs{ .attack = 0, .noise = 0, .wobble = 0 }).apply(base);
    try testing.expectEqual(VoiceKnobs.min_attack_s, zeroed.attack_s);
    try testing.expectEqual(@as(f32, 0.0), zeroed.noise_mix);
    try testing.expectEqual(@as(f32, 0.0), zeroed.wobble_depth);

    const huge = (VoiceKnobs{ .attack = 1e6, .noise = 1e6, .wobble = 1e6 }).apply(base);
    try testing.expectEqual(VoiceKnobs.max_attack_s, huge.attack_s);
    try testing.expect(huge.noise_mix <= VoiceKnobs.max_noise_mix);
    try testing.expect(huge.wobble_depth <= VoiceKnobs.max_wobble_depth);

    // wobble_depth at the cap must keep `wob = 1 - depth * (...)` non-negative
    try testing.expectEqual(@as(f32, 0.0), 1.0 - huge.wobble_depth * 1.0);
    // and `wobble_hz` is the class's, never scaled
    try testing.expectEqual(base.wobble_hz, huge.wobble_hz);

    // the physical axes clamp where their bounds say
    const phys_zero = (VoiceKnobs{ .pressure = 0, .tension = 0, .resonance = 0, .decay = 0, .turbulence = 0 }).apply(base);
    try testing.expectEqual(VoiceKnobs.min_pressure, phys_zero.pressure);
    try testing.expectEqual(@as(f32, 0.0), phys_zero.tension);
    try testing.expectEqual(@as(f32, 0.0), phys_zero.resonance);
    try testing.expectEqual(@as(f32, 0.0), phys_zero.turbulence);
    // `burst` is mapped from the class, not scaled by a knob
    try testing.expectEqual(base.burst, phys_zero.burst);
    // and the decay rate is the identity at the default
    try testing.expectEqual(@as(f32, 1.0), (VoiceKnobs{}).pitchDecay());
    try testing.expectEqual(@as(f32, 0.0), (VoiceKnobs{ .decay = 0.0 }).pitchDecay());
    try testing.expectEqual(VoiceKnobs.max_decay, (VoiceKnobs{ .decay = 1e9 }).pitchDecay());

    const phys_huge = (VoiceKnobs{ .pressure = 1e6, .tension = 1e6, .resonance = 1e6, .decay = 1e6, .turbulence = 1e6 }).apply(base);
    try testing.expectEqual(VoiceKnobs.max_pressure, phys_huge.pressure);
    try testing.expectEqual(VoiceKnobs.max_tension, phys_huge.tension);
    try testing.expectEqual(VoiceKnobs.max_resonance, phys_huge.resonance);
    try testing.expectEqual(VoiceKnobs.max_turbulence, phys_huge.turbulence);
}

test "voice knobs reach the consonant-only breath syllable" {
    const alloc = testing.allocator;
    // A breath syllable has no vowel, so it renders from a literal spec rather
    // than from voiceSpec, and it is the one place the knobs could be missed.
    //
    // Rendering a whole word would NOT isolate it: "mtu" splits into the breath
    // "m" plus the vowel "tu", and "tu" responds to the knobs either way, so the
    // comparison passes even with the breath path hardcoded to ignore them.
    // That is a test that lies, so drive the syllable renderer directly.
    var syl = Syll{ .text_len = 1, .onset_len = 1, .vowel = 0 };
    @memcpy(syl.text_buf[0..1], "m");
    const n: usize = SAMPLE_RATE * 90 / 1000; // the breath syllable's length

    const plain = try alloc.alloc(i16, n);
    defer alloc.free(plain);
    var prng_a = std.Random.DefaultPrng.init(1);
    renderSyllableInto(plain, &syl, false, &prng_a, .{});

    const quiet = try alloc.alloc(i16, n);
    defer alloc.free(quiet);
    var prng_b = std.Random.DefaultPrng.init(1);
    // same seed, so the noise sequence matches and the only difference is the
    // knob: renderSyllableInto draws a fixed number of prng values regardless
    renderSyllableInto(quiet, &syl, false, &prng_b, .{ .noise = 0.0 });

    var diffs: usize = 0;
    for (plain, quiet) |a, b| {
        if (a != b) diffs += 1;
    }
    try testing.expect(diffs > n / 2); // a whisper is mostly noise, so most of it moves
}

test "voice knob parsing accepts order, whitespace and rejects nonsense" {
    try testing.expectEqual(
        @as(f32, 1.5),
        (try parseKnobs("attack=1.5")).attack,
    );
    const all = try parseKnobs("wobble=3, attack=0.5 ,noise=2");
    try testing.expectEqual(@as(f32, 0.5), all.attack);
    try testing.expectEqual(@as(f32, 2.0), all.noise);
    try testing.expectEqual(@as(f32, 3.0), all.wobble);

    // partial specs leave the other axes alone
    const partial = try parseKnobs("noise=0.25");
    try testing.expectEqual(@as(f32, 1.0), partial.attack);
    try testing.expectEqual(@as(f32, 0.25), partial.noise);
    try testing.expectEqual(@as(f32, 1.0), partial.wobble);
    try testing.expectEqual(@as(f32, 1.0), partial.intensity);
    try testing.expectEqual(@as(f32, 0.0), partial.cents);
    // ...including the physical-model axes
    try testing.expectEqual(@as(f32, 1.0), partial.pressure);
    try testing.expectEqual(@as(f32, 1.0), partial.tension);
    try testing.expectEqual(@as(f32, 1.0), partial.resonance);
    try testing.expectEqual(@as(f32, 1.0), partial.decay);
    try testing.expectEqual(@as(f32, 1.0), partial.turbulence);

    // #15/#16: effort is a multiplier, cents an offset — the one key a
    // negative value is meaningful for
    const dyn = try parseKnobs("intensity=2, cents=-700");
    try testing.expectEqual(@as(f32, 2.0), dyn.intensity);
    try testing.expectEqual(@as(f32, -700.0), dyn.cents);
    try testing.expectError(error.Negative, parseKnobs("intensity=-1"));
    try testing.expectError(error.NotFinite, parseKnobs("cents=nan"));
    try testing.expectError(error.UnknownKnob, parseKnobs("pitch=2"));

    // the physical model takes the same multiplier spelling
    const phys = try parseKnobs("pressure=2, tension=0.5, resonance=0, decay=0, turbulence=3");
    try testing.expectEqual(@as(f32, 2.0), phys.pressure);
    try testing.expectEqual(@as(f32, 0.5), phys.tension);
    try testing.expectEqual(@as(f32, 0.0), phys.resonance);
    try testing.expectEqual(@as(f32, 0.0), phys.decay);
    try testing.expectEqual(@as(f32, 3.0), phys.turbulence);
    try testing.expectError(error.Negative, parseKnobs("pressure=-1"));
    try testing.expectError(error.Negative, parseKnobs("turbulence=-0.5"));
    try testing.expectError(error.NotFinite, parseKnobs("tension=inf"));
    try testing.expectError(error.UnknownKnob, parseKnobs("gut=2"));

    try testing.expectError(error.MalformedKnob, parseKnobs("attack"));
    try testing.expectError(error.MalformedKnob, parseKnobs("attack="));
    try testing.expectError(error.MalformedKnob, parseKnobs("attack=abc"));
    try testing.expectError(error.Negative, parseKnobs("noise=-1"));
    try testing.expectError(error.NotFinite, parseKnobs("noise=nan"));
    try testing.expectError(error.NotFinite, parseKnobs("noise=inf"));
}

// --------------------------------------------------------------------------
// intensity (#15) and the vowel cents shift (#16)
// --------------------------------------------------------------------------

test "intensity: one number shouts or whispers the whole phrase" {
    const alloc = testing.allocator;
    const stock = try renderPhraseSamplesWith(alloc, "kujamba karibu", .{});
    defer alloc.free(stock);
    const shout = try renderPhraseSamplesWith(alloc, "kujamba karibu", .{ .intensity = 2.0 });
    defer alloc.free(shout);
    const whisper = try renderPhraseSamplesWith(alloc, "kujamba karibu", .{ .intensity = 0.5 });
    defer alloc.free(whisper);

    // same plan, so the same length: intensity only moves the samples
    try testing.expectEqual(stock.len, shout.len);
    try testing.expectEqual(stock.len, whisper.len);

    // louder / quieter overall (level scales), and deterministic: the same
    // intensity value renders byte-identical audio, which is the acceptance
    // criterion the phrase bank's render-once cache leans on
    try testing.expect(rmsOf(shout) > rmsOf(stock));
    try testing.expect(rmsOf(whisper) < rmsOf(stock));
    const shout_again = try renderPhraseSamplesWith(alloc, "kujamba karibu", .{ .intensity = 2.0 });
    defer alloc.free(shout_again);
    try testing.expectEqualSlices(i16, shout, shout_again);

    const shout_wav = try renderPhraseWavWith(alloc, "kujamba karibu", .{ .intensity = 2.0 });
    defer alloc.free(shout_wav);
    try expectNotSilence(shout_wav);
}

test "intensity: clamps, the stress emphasis curve, and the noise cap" {
    // effort is squeezed into its useful range: a preset can never mute the
    // instrument (0 would be exactly silent)
    try testing.expectEqual(VoiceKnobs.min_intensity, (VoiceKnobs{ .intensity = 0.0 }).effort());
    try testing.expectEqual(@as(f32, 1.0), (VoiceKnobs{ .intensity = 1.0 }).effort());
    try testing.expectEqual(VoiceKnobs.max_intensity, (VoiceKnobs{ .intensity = 99.0 }).effort());

    // the stress emphasis: stock at effort 1, flattened by a whisper, capped
    // at twice stock for a shout
    try testing.expectEqual(@as(f32, 1.0), stressBoost(VoiceKnobs.min_intensity));
    try testing.expectEqual(STRESS_LEVEL_BOOST, stressBoost(1.0));
    try testing.expectEqual(VoiceKnobs.max_stress_boost, stressBoost(VoiceKnobs.max_intensity));

    // a whispered word loses its dynamic shape: the stressed syllable is no
    // longer measurably louder than the final one (the phrase test below the
    // stress test asserts > 1.1x at stock, so drive that expectation here)
    const whisper_knobs = VoiceKnobs{ .intensity = 0.5 };
    try testing.expectEqual(VoiceKnobs.min_stress_boost, stressBoost(whisper_knobs.effort()));

    // the noise mix caps where the `noise` knob caps: past 1 it is the same
    // noise, just clipped
    var p = VoiceParams{ .f0 = 100.0, .attack_s = 0.006, .noise_mix = 0.5, .wobble_hz = 30.0, .wobble_depth = 0.5, .level = 0.9, .glide = 0.2, .pressure = 1.0, .tension = 1.0, .resonance = 1.0, .turbulence = 0.5, .burst = 0.0, .f1 = 500.0, .f2 = 1200.0, .decay = 1.0 };
    applyEffort(&p, 4.0);
    try testing.expectEqual(@as(f32, 0.9 * 4.0), p.level);
    try testing.expectEqual(VoiceKnobs.max_noise_mix, p.noise_mix);
    applyEffort(&p, VoiceKnobs.min_intensity);
    try testing.expectEqual(@as(f32, 0.9 * 4.0 * 0.25), p.level);

    // and intensity 0 at the sample level is still real audio, because the
    // clamp floors it at 0.25
    const alloc = testing.allocator;
    const out = try renderPhraseSamplesWith(alloc, "kujamba karibu", .{ .intensity = 0.0 });
    defer alloc.free(out);
    try testing.expect(rmsOf(out) > 1.0);
}

test "intensity reaches the consonant-only breath syllable" {
    const alloc = testing.allocator;
    // same direct-drive trick as the noise-knob breath test: a whole word
    // would pass even with the breath path hardcoded to ignore the knob
    var syl = Syll{ .text_len = 1, .onset_len = 1, .vowel = 0 };
    @memcpy(syl.text_buf[0..1], "m");
    const n: usize = SAMPLE_RATE * 90 / 1000;

    const plain = try alloc.alloc(i16, n);
    defer alloc.free(plain);
    var prng_a = std.Random.DefaultPrng.init(1);
    renderSyllableInto(plain, &syl, false, &prng_a, .{});

    const quiet = try alloc.alloc(i16, n);
    defer alloc.free(quiet);
    var prng_b = std.Random.DefaultPrng.init(1);
    renderSyllableInto(quiet, &syl, false, &prng_b, .{ .intensity = 0.25 });

    var diffs: usize = 0;
    for (plain, quiet) |a, b| {
        if (a != b) diffs += 1;
    }
    try testing.expect(diffs > n / 2);
}

test "cents: the vowel table transposes, deterministically" {
    // the factor itself: exact identity at zero, an octave at 1200, a
    // semitone at 100, and pinned at the one-octave clamp
    try testing.expectEqual(@as(f32, 1.0), (VoiceKnobs{}).pitchFactor());
    try testing.expectApproxEqAbs(@as(f32, 2.0), (VoiceKnobs{ .cents = 1200 }).pitchFactor(), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), (VoiceKnobs{ .cents = -1200 }).pitchFactor(), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.0594631), (VoiceKnobs{ .cents = 100 }).pitchFactor(), 1e-5);
    try testing.expectEqual(
        (VoiceKnobs{ .cents = 1200 }).pitchFactor(),
        (VoiceKnobs{ .cents = 9999 }).pitchFactor(),
    );
    try testing.expectEqual(
        (VoiceKnobs{ .cents = -1200 }).pitchFactor(),
        (VoiceKnobs{ .cents = -9999 }).pitchFactor(),
    );

    // end to end: the same phrase at +700, 0 and -700 cents is three different
    // renders, and the same value twice is byte-identical — the "part of the
    // render key" acceptance criterion, since the phrase bank renders once
    // with the config's knobs and never again
    const alloc = testing.allocator;
    const stock = try renderPhraseWavWith(alloc, "kujamba karibu", .{});
    defer alloc.free(stock);
    const up = try renderPhraseWavWith(alloc, "kujamba karibu", .{ .cents = 700 });
    defer alloc.free(up);
    const down = try renderPhraseWavWith(alloc, "kujamba karibu", .{ .cents = -700 });
    defer alloc.free(down);
    try testing.expect(!std.mem.eql(u8, stock, up));
    try testing.expect(!std.mem.eql(u8, stock, down));
    try testing.expect(!std.mem.eql(u8, up, down));
    const up_again = try renderPhraseWavWith(alloc, "kujamba karibu", .{ .cents = 700 });
    defer alloc.free(up_again);
    try testing.expectEqualSlices(u8, up, up_again);

    try expectNotSilence(up);
    try expectNotSilence(down);
}

test "cents reaches the consonant-only breath syllable too" {
    const alloc = testing.allocator;
    // the breath tail's 88 Hz carrier shifts with the same offset, or a
    // transposed instrument would leave one syllable behind
    var syl = Syll{ .text_len = 1, .onset_len = 1, .vowel = 0 };
    @memcpy(syl.text_buf[0..1], "m");
    const n: usize = SAMPLE_RATE * 90 / 1000;

    const plain = try alloc.alloc(i16, n);
    defer alloc.free(plain);
    var prng_a = std.Random.DefaultPrng.init(1);
    renderSyllableInto(plain, &syl, false, &prng_a, .{});

    const low = try alloc.alloc(i16, n);
    defer alloc.free(low);
    var prng_b = std.Random.DefaultPrng.init(1);
    renderSyllableInto(low, &syl, false, &prng_b, .{ .cents = -1200 });

    var diffs: usize = 0;
    for (plain, low) |a, b| {
        if (a != b) diffs += 1;
    }
    try testing.expect(diffs > n / 2);
}

// --------------------------------------------------------------------------
// the physical model: pressure, tension, tract resonance, pitch decay,
// turbulence and the plosive pressure burst
// --------------------------------------------------------------------------

test "the mapping tables: plosives burst, vowels resonate" {
    // plosives (p t k ch, b d g j) carry the pressure burst; nothing else does
    try testing.expectEqual(@as(f32, 1.0), voiceSpec(.stop_voiceless).burst);
    try testing.expectEqual(@as(f32, 1.0), voiceSpec(.stop_voiced).burst);
    try testing.expectEqual(@as(f32, 0.0), voiceSpec(.fricative).burst);
    try testing.expectEqual(@as(f32, 0.0), voiceSpec(.nasal).burst);
    try testing.expectEqual(@as(f32, 0.0), voiceSpec(.liquid).burst);
    try testing.expectEqual(@as(f32, 0.0), voiceSpec(.none).burst);
    // the physical parameters differ per class: stops push hardest, nasals
    // are loose and quiet, fricatives are tight and sputtery
    try testing.expect(voiceSpec(.stop_voiced).pressure > voiceSpec(.nasal).pressure);
    try testing.expect(voiceSpec(.fricative).tension > voiceSpec(.nasal).tension);
    try testing.expect(voiceSpec(.fricative).turbulence > voiceSpec(.nasal).turbulence);
    // every vowel has its own tract, F2 above F1, and every formant sits
    // above the buzz's fundamental (74-138 Hz) so the resonators color it
    var prev: Formants = .{ .f1 = 0.0, .f2 = 0.0 };
    for ("aeiou") |v| {
        const fm = vowelFormants(v);
        try testing.expect(fm.f1 > 250.0 and fm.f1 < 1000.0);
        try testing.expect(fm.f2 > fm.f1);
        try testing.expect(fm.f1 != prev.f1 or fm.f2 != prev.f2);
        prev = fm;
    }
    // the breath syllable gets the neutral tract
    const breath = vowelFormants(0);
    try testing.expect(breath.f1 > 0.0 and breath.f2 > breath.f1);
}

test "exponential pitch decay: the buzz falls as the pressure vents" {
    const alloc = testing.allocator;
    // `noise=0` isolates the buzz. The pitch proxy is total variation per
    // sample over the window's RMS: level-independent, so it tracks the
    // frequency and is not drowned by quantization noise in a quiet tail.
    // `decay=0` freezes the pressure vent, so the pitch stays flat; the
    // stock decay=1 drops it as the gut vents.
    const flat = try renderPhraseSamplesWith(alloc, "a", .{ .noise = 0.0, .decay = 0.0 });
    defer alloc.free(flat);
    const vented = try renderPhraseSamplesWith(alloc, "a", .{ .noise = 0.0 });
    defer alloc.free(vented);
    try testing.expectEqual(flat.len, vented.len);
    try testing.expect(flat.len > 1000);

    const tvRatio = struct {
        fn rate(samples: []const i16, from: usize, to: usize) f64 {
            var tv: f64 = 0;
            for (samples[from + 1 .. to], 0..) |s, k| {
                const a: f64 = @floatFromInt(s);
                const b: f64 = @floatFromInt(samples[from + k]);
                tv += @abs(a - b);
            }
            const r = rmsOf(samples[from..to]);
            if (r <= 0) return 0;
            return tv / (r * @as(f64, @floatFromInt(to - from - 1)));
        }
    }.rate;

    // the middle of the syllable: the vented buzz has fallen ~11% in pitch,
    // the frozen one has not moved at all
    const mid_from = flat.len / 2;
    const mid_to = flat.len * 5 / 8;
    try testing.expect(tvRatio(vented, mid_from, mid_to) < tvRatio(flat, mid_from, mid_to) * 0.93);

    // and the head barely differs: both start at the vowel's base pitch
    const head_from = flat.len / 16;
    const head_to = flat.len / 8;
    try testing.expect(tvRatio(vented, head_from, head_to) > tvRatio(flat, head_from, head_to) * 0.93);
}

test "plosive onsets get a pressure burst: stops pop harder than fricatives" {
    const alloc = testing.allocator;
    // 'p' is a voiceless stop (burst = 1), 'f' a fricative (burst = 0).
    // Same vowel, same syllable count: the stop's onset carries the punch
    // (the class's snappier attack rides with it).
    const pop = try renderPhraseSamplesWith(alloc, "pa", .{ .noise = 0.0 });
    defer alloc.free(pop);
    const hiss = try renderPhraseSamplesWith(alloc, "fa", .{ .noise = 0.0 });
    defer alloc.free(hiss);
    try testing.expectEqual(pop.len, hiss.len);
    const w = SAMPLE_RATE / 100; // the first 10 ms: the burst lives ~16 ms
    try testing.expect(rmsOf(pop[0..w]) > rmsOf(hiss[0..w]) * 1.3);
}

test "turbulence: noise bursts sputter through the body of the syllable" {
    const alloc = testing.allocator;
    const smooth = try renderPhraseSamplesWith(alloc, "ka", .{ .turbulence = 0.0 });
    defer alloc.free(smooth);
    const sputtery = try renderPhraseSamplesWith(alloc, "ka", .{ .turbulence = 3.0 });
    defer alloc.free(sputtery);
    try testing.expectEqual(smooth.len, sputtery.len);
    // the attack splat is over by the middle of the syllable; only the
    // turbulence train can add texture there. The proxy is total variation
    // per RMS (a frequency/energy proxy): broadband bursts nearly double it.
    const from = smooth.len / 2;
    const to = smooth.len * 3 / 4;
    const tvRatio = struct {
        fn rate(samples: []const i16) f64 {
            var tv: f64 = 0;
            for (samples[1..], 0..) |s, k| {
                const a: f64 = @floatFromInt(s);
                const b: f64 = @floatFromInt(samples[k]);
                tv += @abs(a - b);
            }
            const r = rmsOf(samples);
            if (r <= 0) return 0;
            return tv / (r * @as(f64, @floatFromInt(samples.len - 1)));
        }
    }.rate;
    try testing.expect(tvRatio(sputtery[from..to]) > tvRatio(smooth[from..to]) * 1.3);
}

test "physical knobs are part of the render: same knobs, same bytes" {
    const alloc = testing.allocator;
    const knobs = VoiceKnobs{ .pressure = 1.7, .tension = 0.6, .resonance = 1.4, .decay = 2.0, .turbulence = 1.5 };
    const a = try renderPhraseWavWith(alloc, "kujamba karibu", knobs);
    defer alloc.free(a);
    const b = try renderPhraseWavWith(alloc, "kujamba karibu", knobs);
    defer alloc.free(b);
    try testing.expectEqualSlices(u8, a, b);
    // one axis off and the render moves — the knobs are in the render key
    const c = try renderPhraseWavWith(alloc, "kujamba karibu", VoiceKnobs{ .pressure = 1.7, .tension = 0.6, .resonance = 1.4, .decay = 2.0, .turbulence = 1.6 });
    defer alloc.free(c);
    try testing.expect(!std.mem.eql(u8, a, c));
    // and the shuzi path is deterministic under the knobs too
    const s1 = try renderShuziWavWith(alloc, 42, knobs);
    defer alloc.free(s1);
    const s2 = try renderShuziWavWith(alloc, 42, knobs);
    defer alloc.free(s2);
    try testing.expectEqualSlices(u8, s1, s2);
}

test "physical knobs reach the consonant-only breath syllable" {
    const alloc = testing.allocator;
    // same direct-drive trick as the noise-knob breath test: a whole word
    // would pass even with the breath path hardcoded to ignore the knob
    var syl = Syll{ .text_len = 1, .onset_len = 1, .vowel = 0 };
    @memcpy(syl.text_buf[0..1], "m");
    const n: usize = SAMPLE_RATE * 90 / 1000;

    const plain = try alloc.alloc(i16, n);
    defer alloc.free(plain);
    var prng_a = std.Random.DefaultPrng.init(1);
    renderSyllableInto(plain, &syl, false, &prng_a, .{});

    const wild = try alloc.alloc(i16, n);
    defer alloc.free(wild);
    var prng_b = std.Random.DefaultPrng.init(1);
    // same seed, so the noise sequence matches and the only difference is
    // the knobs: no sputter, twice the pressure
    renderSyllableInto(wild, &syl, false, &prng_b, .{ .turbulence = 0.0, .pressure = 2.0 });

    var diffs: usize = 0;
    for (plain, wild) |a, b| {
        if (a != b) diffs += 1;
    }
    try testing.expect(diffs > n / 2);
}

test "shuzi seeds are varied rumbles, each deterministic" {
    const alloc = testing.allocator;
    const a = try renderShuziWav(alloc, 0);
    defer alloc.free(a);
    const b = try renderShuziWav(alloc, 42);
    defer alloc.free(b);
    const c = try renderShuziWav(alloc, 1234567);
    defer alloc.free(c);
    // the physical model draws per seed, so different seeds are different
    // rumbles — not the same fart with a new noise sequence
    try testing.expect(!std.mem.eql(u8, a, b));
    try testing.expect(!std.mem.eql(u8, b, c));
    try testing.expect(!std.mem.eql(u8, a, c));
    // and each one is still a pure function of its seed
    const again = try renderShuziWav(alloc, 42);
    defer alloc.free(again);
    try testing.expectEqualSlices(u8, b, again);
    try expectNotSilence(a);
    try expectNotSilence(b);
    try expectNotSilence(c);
}
