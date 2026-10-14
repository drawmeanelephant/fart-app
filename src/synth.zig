//! synth.zig — Flatlophone v2: real fart synthesis + Swahili syllable engine.
//!
//! Pure Zig stdlib. Emits PCM WAV (RIFF), 44100 Hz, mono, 16-bit. No libc, no
//! file I/O: every render is a pure function of its input. The noise generator
//! is seeded from a hash of the input text with fixed constants everywhere
//! else, so the same phrase always produces byte-identical WAV bytes. Always.
//!
//! One fart "phoneme" (one Swahili syllable) is:
//!   * a coupled physical reed-oscillator model driven by intestinal pressure,
//!     sphincter tension, and terminal tract acoustic resonance
//!   * a rich multi-harmonic + sub-bass relaxation pulse with exponential pitch
//!     decay as intestinal pressure drops across the syllable
//!   * a vowel-mapped dual formant resonator (F1/F2 vocal/intestinal tract
//!     cavities) plus terminal tract resonance (cheek/bowl reflection)
//!   * plosive onset pressure spikes (b, p, k, t, d, g, j, ch) and controllable
//!     modulated noise-burst turbulence for wet/dry/raspy/thunderous textures
//!   * an amplitude envelope with a fast attack, sphincter stick-slip micro-closures,
//!     and a ~24-34 Hz mucosal flutter wobble
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

const PITCH_DROP: f32 = 0.24; // pitch falls ~24% across a syllable via exponential decay
const PITCH_DECAY_RATE: f32 = 2.8; // exponential decay constant as pressure drops

// ---------------------------------------------------------------------
// Mapping tables (documented in README.md)
// ---------------------------------------------------------------------

/// Base frequency of the buzzy oscillator, chosen by the syllable's vowel.
pub fn vowelBaseFreq(v: u8) ?f32 {
    return switch (v) {
        'a' => 88.0,
        'e' => 104.0,
        'i' => 126.0,
        'o' => 76.0,
        'u' => 64.0,
        else => null,
    };
}

/// Resonant formant filter specification for a vowel: dual resonant peaks
/// (F1 lower cavity, F2 upper/cheek cavity) that shape the harmonic buzz and
/// turbulent noise into distinct vocal-like fart vowels.
pub const FormantSpec = struct {
    f1_hz: f32,
    f2_hz: f32,
    bw1_hz: f32,
    bw2_hz: f32,
    f1_gain: f32,
    f2_gain: f32,
};

/// Maps a Swahili vowel to its dual-formant resonant filter frequencies.
pub fn vowelFormants(v: u8) FormantSpec {
    return switch (v) {
        'a' => .{ .f1_hz = 680.0, .f2_hz = 1180.0, .bw1_hz = 130.0, .bw2_hz = 190.0, .f1_gain = 1.00, .f2_gain = 0.65 },
        'e' => .{ .f1_hz = 480.0, .f2_hz = 1680.0, .bw1_hz = 110.0, .bw2_hz = 210.0, .f1_gain = 0.90, .f2_gain = 0.70 },
        'i' => .{ .f1_hz = 310.0, .f2_hz = 2050.0, .bw1_hz = 95.0, .bw2_hz = 230.0, .f1_gain = 0.85, .f2_gain = 0.75 },
        'o' => .{ .f1_hz = 430.0, .f2_hz = 820.0, .bw1_hz = 105.0, .bw2_hz = 150.0, .f1_gain = 1.10, .f2_gain = 0.55 },
        'u' => .{ .f1_hz = 290.0, .f2_hz = 620.0, .bw1_hz = 90.0, .bw2_hz = 130.0, .f1_gain = 1.15, .f2_gain = 0.45 },
        else => .{ .f1_hz = 520.0, .f2_hz = 1100.0, .bw1_hz = 150.0, .bw2_hz = 220.0, .f1_gain = 0.80, .f2_gain = 0.50 },
    };
}

/// Plosive pressure-burst profile triggered by consonant onsets (especially p, b, k, t).
/// Models the build-up of intestinal gas behind a sealed sphincter and its sudden
/// explosive release (pitch upward spike, transient sub-thump, and high-velocity
/// turbulent noise jet).
pub const PlosiveSpec = struct {
    /// Amplitude of the sudden pressure-release impulse
    burst_amp: f32,
    /// Decay time constant (seconds) of the initial pressure spike
    decay_s: f32,
    /// Center frequency (Hz) of the plosive pop resonance
    pop_freq_hz: f32,
    /// Fractional upward pitch jump at t=0 from overpressure
    pitch_spike: f32,
};

/// Maps a consonant onset string (e.g. "k", "b", "p", "mb", "sh") to its
/// physical plosive burst profile. Bilabials (b, p) produce low, punchy cheek
/// pops; velars (k, g) produce sharp mid-range snaps; alveolars/affricates
/// (t, d, ch, j) produce crisp splats; prenasalized stops (mb, nd, ng, nj, mp, nk)
/// combine nasal buildup with a wet release pop.
pub fn onsetPlosiveSpec(onset: []const u8) PlosiveSpec {
    if (onset.len == 0) {
        return .{ .burst_amp = 0.12, .decay_s = 0.012, .pop_freq_hz = 160.0, .pitch_spike = 0.06 };
    }
    // Check prenasalized stops (mb, mp, nd, nt, ng, nk, nj) where the second char is the stop release
    const c0 = onset[0];
    const c_release = if (onset.len >= 2 and (c0 == 'm' or c0 == 'n') and onset[1] != 'y' and onset[1] != 'w')
        onset[1]
    else
        c0;
    const prenasal_scale: f32 = if (c_release != c0) 0.85 else 1.0;

    return switch (c_release) {
        'p' => .{ .burst_amp = 0.95 * prenasal_scale, .decay_s = 0.018, .pop_freq_hz = 135.0, .pitch_spike = 0.34 },
        'b' => .{ .burst_amp = 0.90 * prenasal_scale, .decay_s = 0.024, .pop_freq_hz = 110.0, .pitch_spike = 0.30 },
        'k' => .{ .burst_amp = 0.92 * prenasal_scale, .decay_s = 0.014, .pop_freq_hz = 260.0, .pitch_spike = 0.36 },
        'g' => .{ .burst_amp = 0.80 * prenasal_scale, .decay_s = 0.020, .pop_freq_hz = 195.0, .pitch_spike = 0.26 },
        't' => .{ .burst_amp = 0.82 * prenasal_scale, .decay_s = 0.013, .pop_freq_hz = 310.0, .pitch_spike = 0.28 },
        'd' => .{ .burst_amp = 0.76 * prenasal_scale, .decay_s = 0.019, .pop_freq_hz = 220.0, .pitch_spike = 0.24 },
        'c', 'j' => .{ .burst_amp = 0.78 * prenasal_scale, .decay_s = 0.022, .pop_freq_hz = 280.0, .pitch_spike = 0.25 },
        's', 'z', 'f', 'v', 'h' => .{ .burst_amp = 0.35, .decay_s = 0.032, .pop_freq_hz = 420.0, .pitch_spike = 0.12 },
        'm', 'n' => .{ .burst_amp = 0.18, .decay_s = 0.020, .pop_freq_hz = 130.0, .pitch_spike = 0.08 },
        else => .{ .burst_amp = 0.25, .decay_s = 0.016, .pop_freq_hz = 180.0, .pitch_spike = 0.10 },
    };
}

/// Onset character classes: consonants set the attack/decay character and
/// physical baseline parameters (pressure, tension, resonance, turbulence).
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
    /// Intestinal gas pressure (bar-like normalized units, ~0.2..3.0).
    /// Drives blow force, nonlinear wave steepening, sub-bass weight, and pitch drop.
    pressure: f32 = 1.0,
    /// Sphincter muscular tension (~0.2..3.0).
    /// Controls reed stiffness, harmonic sharpness (raspy vs flabby), and stick-slip gating.
    tension: f32 = 1.0,
    /// Terminal tract / gluteal acoustic resonance (~0.1..3.0).
    /// Controls resonant Q of the cavity filters and wet bubbly filter modulation.
    resonance: f32 = 1.0,
    /// Noise-burst turbulence (~0.0..3.0).
    /// Controls chaotic air-jet bursts modulated by the sphincter opening cycle.
    turbulence: f32 = 1.0,
};

pub fn voiceSpec(cls: VoiceClass) VoiceSpec {
    return switch (cls) {
        .none => .{
            .attack_s = 0.008,
            .noise_mix = 0.25,
            .wobble_hz = 28.0,
            .wobble_depth = 0.50,
            .level = 0.90,
            .pressure = 1.00,
            .tension = 0.95,
            .resonance = 1.05,
            .turbulence = 0.90,
        },
        .stop_voiceless => .{
            .attack_s = 0.004,
            .noise_mix = 0.40,
            .wobble_hz = 32.0,
            .wobble_depth = 0.55,
            .level = 0.95,
            .pressure = 1.35,
            .tension = 1.25,
            .resonance = 1.00,
            .turbulence = 1.30,
        },
        .stop_voiced => .{
            .attack_s = 0.006,
            .noise_mix = 0.28,
            .wobble_hz = 30.0,
            .wobble_depth = 0.50,
            .level = 1.00,
            .pressure = 1.40,
            .tension = 1.05,
            .resonance = 1.25,
            .turbulence = 1.15,
        },
        .fricative => .{
            .attack_s = 0.010,
            .noise_mix = 0.50,
            .wobble_hz = 29.0,
            .wobble_depth = 0.45,
            .level = 0.90,
            .pressure = 1.10,
            .tension = 1.15,
            .resonance = 0.95,
            .turbulence = 1.45,
        },
        .nasal => .{
            .attack_s = 0.025,
            .noise_mix = 0.12,
            .wobble_hz = 26.0,
            .wobble_depth = 0.35,
            .level = 0.85,
            .pressure = 0.95,
            .tension = 0.80,
            .resonance = 1.35,
            .turbulence = 0.75,
        },
        .liquid => .{
            .attack_s = 0.014,
            .noise_mix = 0.18,
            .wobble_hz = 28.0,
            .wobble_depth = 0.45,
            .level = 0.90,
            .pressure = 1.05,
            .tension = 0.88,
            .resonance = 1.30,
            .turbulence = 0.95,
        },
    };
}

/// Per-run tuning of the three onset characters the class table sets: attack,
/// noise mix and wobble depth. Multipliers rather than absolutes, so an onset
/// class keeps its character — `--voice wobble=2` doubles the wobble of every
/// class instead of flattening them all to one number.
///
/// Two more axes ride along and are applied by the renderer rather than by
/// `apply`, because neither belongs to the onset class: `intensity` (#15) is
/// vocal effort — it reaches the level, the noise mix and the stress emphasis,
/// which `apply` never sees — and `cents` (#16) transposes the vowel pitch
/// table, which is a property of the vowel, not of the consonant onset.
///
/// The default is 1.0 on every multiplier and 0 on `cents`, and `x * 1.0` is
/// exact in IEEE-754, so an untouched `VoiceKnobs` reproduces the class table
/// bit for bit. That is load-bearing, not decorative: the golden fingerprints
/// in `src/golden.zig` assert it, and all seven of them have to keep passing
/// unchanged.
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
    /// Scales `pressure` (intestinal gas pressure): controls blow force,
    /// sub-bass weight, nonlinear wave steepening, and exponential pitch decay depth.
    pressure: f32 = 1.0,
    /// Scales `tension` (sphincter muscular tension): controls reed stiffness,
    /// upper harmonic raspiness vs loose flabby rumble, and stick-slip gating.
    tension: f32 = 1.0,
    /// Scales `resonance` (terminal tract / gluteal cavity resonance): controls
    /// formant filter Q and wet bubbly resonance modulation.
    resonance: f32 = 1.0,
    /// Scales `turbulence` (chaotic noise-burst turbulence): controls sputtery
    /// air-jet bursts gated by the sphincter vibration cycle.
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
    /// Physical parameter bounds: prevent numerical instability in SVF resonators
    /// and pitch/saturation curves under extreme multiplier settings.
    pub const min_pressure: f32 = 0.20;
    pub const max_pressure: f32 = 3.00;
    pub const min_tension: f32 = 0.20;
    pub const max_tension: f32 = 3.00;
    pub const min_resonance: f32 = 0.10;
    pub const max_resonance: f32 = 3.00;
    pub const min_turbulence: f32 = 0.00;
    pub const max_turbulence: f32 = 3.00;

    /// `2^(cents/1200)` — the factor every base frequency is multiplied by,
    /// with `cents` clamped to one octave either way. The `cents == 0` branch
    /// is load-bearing: the untouched knobs must be a *bit-exact* identity
    /// (the golden fingerprints assert it), and `x * 1.0` is exact in IEEE-754
    /// in a way `pow` is only ever allowed to be, not guaranteed to be.
    pub fn pitchFactor(self: VoiceKnobs) f32 {
        if (self.cents == 0) return 1.0;
        const c = std.math.clamp(self.cents, -max_abs_cents, max_abs_cents);
        return std.math.pow(f32, 2.0, c / 1200.0);
    }

    /// The effort value the renderer actually applies: `intensity` clamped
    /// into its useful range, so a preset can never mute the instrument.
    pub fn effort(self: VoiceKnobs) f32 {
        return std.math.clamp(self.intensity, min_intensity, max_intensity);
    }

    /// The class table with the knobs applied. `wobble_hz` is deliberately
    /// untouched: the knob is on the depth of the flutter, and the rate is
    /// part of each class's character. `intensity` and `cents` are applied by
    /// the renderer (see above), not here.
    pub fn apply(self: VoiceKnobs, spec: VoiceSpec) VoiceSpec {
        return .{
            .attack_s = std.math.clamp(spec.attack_s * self.attack, min_attack_s, max_attack_s),
            .noise_mix = std.math.clamp(spec.noise_mix * self.noise, 0.0, max_noise_mix),
            .wobble_hz = spec.wobble_hz,
            .wobble_depth = std.math.clamp(spec.wobble_depth * self.wobble, 0.0, max_wobble_depth),
            .level = spec.level,
            .pressure = std.math.clamp(spec.pressure * self.pressure, min_pressure, max_pressure),
            .tension = std.math.clamp(spec.tension * self.tension, min_tension, max_tension),
            .resonance = std.math.clamp(spec.resonance * self.resonance, min_resonance, max_resonance),
            .turbulence = std.math.clamp(spec.turbulence * self.turbulence, min_turbulence, max_turbulence),
        };
    }
};

pub const KnobsError = error{ UnknownKnob, MalformedKnob, NotFinite, Negative };

/// Parse `attack=1.2,noise=0.8,wobble=2` into multipliers. Order is free and
/// whitespace around keys and values is ignored; an empty string is the
/// identity, which is what `--voice ""` and an omitted flag both mean.
/// `intensity` and `cents` (#15, #16) take the same spelling: `intensity` is
/// a multiplier (>= 0), `cents` an offset in cents and the one key a negative
/// value is meaningful for. Physical knobs (`pressure`, `tension`, `resonance`,
/// `turbulence`) also take non-negative multipliers.
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
    pressure: f32 = 1.0,
    tension: f32 = 1.0,
    resonance: f32 = 1.0,
    turbulence: f32 = 1.0,
    formants: FormantSpec = vowelFormants('a'),
    plosive: PlosiveSpec = onsetPlosiveSpec(""),
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
/// randomness comes from `prng`, whose seed is fixed per render.
///
/// Physical synthesis architecture:
///  1. Intestinal Pressure & Exponential Pitch Decay:
///     Gas pressure starts high (boosted by plosive onset build-up) and decays
///     exponentially across the syllable (`exp(-decay_rate * u)`), causing pitch
///     to drop naturally like a real decompressing bowel.
///  2. Sphincter Tension & Stick-Slip Reed Pulse:
///     Models the anal sphincter as a nonlinear mucosal reed. Higher tension
///     shifts pitch upward, sharpens upper harmonics (raspy/tight), and tightens
///     stick-slip micro-closures; lower tension yields a loose, flabby, sub-heavy
///     slap.
///  3. Plosive Pressure Bursts:
///     Stop consonants (b, p, k, t, g, d, j, ch) inject an explosive initial
///     pressure spike, pitch jump, and resonant cheek-pop thump.
///  4. Noise-Burst Turbulence:
///     Chaotic air-jet turbulence modulated by the instantaneous reed opening
///     (`max(0, sin(phase))`) and bubble/flutter micro-bursts.
///  5. Vowel Formant Filters & Terminal Tract Resonance:
///     A dual 2-pole Chamberlin state-variable bandpass resonator (F1/F2) tuned
///     to each Swahili vowel, coupled with a low-frequency terminal tract cavity
///     resonator whose cutoff wobbles with mucosal flutter for wet/bubbly or
///     thunderous acoustic character.
fn synthInto(out: []i16, p: VoiceParams, prng: *std.Random.DefaultPrng) void {
    const dt: f32 = 1.0 / @as(f32, SAMPLE_RATE);
    const tau: f32 = std.math.tau;
    var phase: f32 = 0;
    var sub_phase: f32 = 0;
    var pop_phase: f32 = 0;

    var lp_body: f32 = 0;
    var lp_burst: f32 = 0;
    var lp_turb: f32 = 0;
    var turb_grain: f32 = 0;

    // State-variable filter (SVF) states for F1, F2, and terminal tract resonance
    var f1_lp: f32 = 0;
    var f1_bp: f32 = 0;
    var f2_lp: f32 = 0;
    var f2_bp: f32 = 0;
    var tract_lp: f32 = 0;
    var tract_bp: f32 = 0;

    const wobble_phase: f32 = prng.random().float(f32) * tau;
    const wobble_hz: f32 = p.wobble_hz * (0.9 + 0.2 * prng.random().float(f32));
    const bubble_phase: f32 = prng.random().float(f32) * tau;
    const bubble_hz: f32 = wobble_hz * 2.35 + 7.0;

    const pressure = std.math.clamp(p.pressure, VoiceKnobs.min_pressure, VoiceKnobs.max_pressure);
    const tension = std.math.clamp(p.tension, VoiceKnobs.min_tension, VoiceKnobs.max_tension);
    const resonance = std.math.clamp(p.resonance, VoiceKnobs.min_resonance, VoiceKnobs.max_resonance);
    const turbulence = std.math.clamp(p.turbulence, VoiceKnobs.min_turbulence, VoiceKnobs.max_turbulence);

    const alpha_body: f32 = 1.0 - @exp(-tau * (580.0 + 220.0 * tension) * dt);
    const alpha_burst: f32 = 1.0 - @exp(-tau * (1700.0 + 500.0 * pressure) * dt);
    const alpha_turb: f32 = 1.0 - @exp(-tau * (1100.0 + 700.0 * tension) * dt);
    const alpha_grain: f32 = 1.0 - @exp(-tau * 85.0 * dt);

    // Tension scales base pitch slightly (tight sphincter = higher pitch, loose = lower)
    const tension_pitch_scale: f32 = 0.82 + 0.18 * tension;
    const base_f0: f32 = std.math.clamp(p.f0 * tension_pitch_scale, 28.0, 420.0);

    // Exponential pitch decay rate scales with pressure
    const exp_rate: f32 = PITCH_DECAY_RATE * (0.75 + 0.35 * pressure);
    const exp_norm: f32 = 1.0 / (1.0 - @exp(-exp_rate));
    const total_drop: f32 = std.math.clamp(p.glide * (0.85 + 0.30 * pressure), 0.05, 0.58);

    // Formant filter damping (inverse Q): higher resonance = narrower bandwidth (wetter/squelchier)
    const q_scale: f32 = std.math.clamp(0.65 + 0.55 * resonance, 0.35, 2.5);
    const damp1: f32 = std.math.clamp((p.formants.bw1_hz / @max(100.0, p.formants.f1_hz)) / q_scale, 0.08, 0.85);
    const damp2: f32 = std.math.clamp((p.formants.bw2_hz / @max(200.0, p.formants.f2_hz)) / q_scale, 0.08, 0.85);
    const tract_damp: f32 = std.math.clamp(0.42 / q_scale, 0.10, 0.90);

    const n = out.len;
    for (0..n) |i| {
        const fi: f32 = @floatFromInt(i);
        const t = fi * dt;
        const u = fi / @as(f32, @floatFromInt(n));

        // 1. Exponentially decaying intestinal pressure & pitch contour
        const exp_decay = (1.0 - @exp(-exp_rate * u)) * exp_norm;
        const plosive_env = @exp(-t / @max(0.002, p.plosive.decay_s));
        const pitch_burst = 1.0 + p.plosive.pitch_spike * plosive_env * (0.7 + 0.3 * pressure);

        // Instantaneous mucosal flutter modulation
        const wob_lfo = @sin(tau * wobble_hz * t + wobble_phase);
        const bubble_lfo = @sin(tau * bubble_hz * t + bubble_phase);
        const pitch_fm = 1.0 + 0.035 * p.wobble_depth * wob_lfo + 0.018 * resonance * bubble_lfo;

        const f = std.math.clamp(base_f0 * (1.0 - total_drop * exp_decay) * pitch_burst * pitch_fm, 24.0, 800.0);
        phase += tau * f * dt;
        if (phase >= tau) phase -= tau;
        sub_phase += tau * (0.5 * f) * dt;
        if (sub_phase >= tau) sub_phase -= tau;

        // 2. Nonlinear mucosal reed oscillator (harmonics + sub-harmonic + stick-slip pulse)
        const s1 = @sin(phase);
        const s2 = @sin(2.0 * phase + 0.35);
        const s3 = @sin(3.0 * phase + 0.70);
        const s4 = @sin(4.0 * phase + 1.05);
        const s5 = @sin(5.0 * phase + 1.40);
        const s6 = @sin(6.0 * phase + 1.75);
        const sub = @sin(sub_phase);

        // Reed sharpness: high tension boosts upper harmonics (3..6); low tension boosts sub & fundamental
        const hi_scale = std.math.clamp(0.55 + 0.45 * tension, 0.25, 1.8);
        const sub_scale = std.math.clamp(0.42 * pressure / (0.65 + 0.35 * tension), 0.10, 0.75);

        // Stick-slip reed opening pulse: models periodic seal-and-pop of the sphincter
        const reed_open = @max(0.0, s1);
        const reed_slap = reed_open * reed_open * (0.45 + 0.35 * pressure);

        const raw_osc = (s1 * 0.95 +
            sub * sub_scale +
            0.62 * s2 +
            (0.40 * s3 + 0.24 * s4 + 0.14 * s5 + 0.08 * s6) * hi_scale +
            reed_slap * (0.65 * s2 - 0.35 * s3)) * 0.3592;

        // Soft pressure saturation (waveshaping x / (1 + k|x|)) for warm brassy harmonics
        const drive = 1.0 + 0.55 * pressure * (1.0 - 0.45 * u);
        const driven = raw_osc * drive;
        const carrier = driven / (1.0 + 0.42 * @abs(driven));

        // 3. Plosive pressure-release pop & turbulent noise bursts
        const wn_body = prng.random().float(f32) * 2.0 - 1.0;
        lp_body += alpha_body * (wn_body - lp_body);
        const wn_burst = prng.random().float(f32) * 2.0 - 1.0;
        lp_burst += alpha_burst * (wn_burst - lp_burst);

        // Chaotic grain envelope for sputtery turbulence
        turb_grain += alpha_grain * (wn_burst * wn_body * 2.2 - turb_grain);
        lp_turb += alpha_turb * (wn_burst - lp_turb);

        // Plosive sub-pop oscillator (decays quickly after consonant release)
        const pop_f = p.plosive.pop_freq_hz * (0.65 + 0.35 * plosive_env);
        pop_phase += tau * pop_f * dt;
        if (pop_phase >= tau) pop_phase -= tau;
        const plosive_pop = (@sin(pop_phase) * 0.55 + lp_burst * 0.85) * p.plosive.burst_amp * plosive_env;

        // Turbulence is gated by reed opening (air jets through when sphincter parts)
        // plus stochastic micro-splats (`turb_grain`)
        const reed_gate = 0.25 + 0.75 * reed_open * (0.7 + 0.3 * @max(0.0, bubble_lfo));
        const burst_env = @exp(-t / 0.048);
        const turb_signal = lp_turb * reed_gate * (1.0 + 1.4 * @abs(turb_grain)) * turbulence * (0.42 + 0.45 * burst_env);
        const base_noise = lp_body * 0.32 + lp_burst * 0.75 * burst_env + turb_signal;

        // Excitation signal combining reed buzz, modulated noise, and plosive burst
        const excitation = carrier + p.noise_mix * base_noise + plosive_pop * (0.35 + 0.65 * p.noise_mix);

        // 4. Dual Vowel Formant Resonators (F1, F2) + Terminal Tract Cavity
        // Dynamic formant sweep: formants dip slightly as pressure drops and wobble with wet resonance
        const wet_mod = 1.0 + 0.14 * resonance * (0.6 * wob_lfo + 0.4 * bubble_lfo) - 0.12 * exp_decay;
        const f1_cut = std.math.clamp(p.formants.f1_hz * wet_mod, 140.0, 1400.0);
        const f2_cut = std.math.clamp(p.formants.f2_hz * wet_mod, 350.0, 2900.0);
        const tract_cut = std.math.clamp((155.0 + 55.0 * pressure) * (1.0 + 0.10 * wob_lfo), 85.0, 420.0);

        const svf_f1 = @min(0.45, 2.0 * @sin(std.math.pi * f1_cut * dt));
        const f1_hp = excitation - f1_lp - damp1 * f1_bp;
        f1_bp += svf_f1 * f1_hp;
        f1_lp += svf_f1 * f1_bp;

        const svf_f2 = @min(0.65, 2.0 * @sin(std.math.pi * f2_cut * dt));
        const f2_hp = excitation - f2_lp - damp2 * f2_bp;
        f2_bp += svf_f2 * f2_hp;
        f2_lp += svf_f2 * f2_bp;

        const svf_tract = @min(0.30, 2.0 * @sin(std.math.pi * tract_cut * dt));
        const tract_hp = excitation - tract_lp - tract_damp * tract_bp;
        tract_bp += svf_tract * tract_hp;
        tract_lp += svf_tract * tract_bp;

        const formant_out = (f1_bp * p.formants.f1_gain + f2_bp * p.formants.f2_gain) * 0.34 * (0.55 + 0.45 * resonance);
        const tract_out = (tract_lp * 0.48 + tract_bp * 0.42 * resonance) * (0.65 + 0.35 * pressure);
        const dry_mix = std.math.clamp(0.62 - 0.12 * resonance, 0.25, 0.75);

        const shaped = excitation * dry_mix + formant_out + tract_out;

        // 5. Amplitude Envelope & Sphincter Flutter Gating
        // Must be 0 at t=0 (i=0) and decay cleanly to 0 at u=1 so loop wraps stay click-free (#17).
        const attack = @min(1.0, t / p.attack_s);
        // Pressure sustains the body of the fart before a sputtering tail decay
        const sustain_shape = (1.0 - u) * std.math.pow(f32, 1.0 - u, 0.35 / std.math.clamp(0.75 + 0.25 * pressure, 0.65, 1.35));
        const env = attack * sustain_shape;

        // Flutter wobble with tension-controlled stick-slip gating
        const flutter_wave = 0.5 + 0.5 * wob_lfo;
        const shaped_flutter = if (tension > 1.0)
            flutter_wave * (0.75 + 0.25 * flutter_wave)
        else
            flutter_wave;
        const wob = 1.0 - p.wobble_depth * shaped_flutter;

        var x = shaped * env * wob * p.level;
        // Smooth soft-clipper near ceiling so high-pressure/shout farts stay fat without harsh digital brickwalling
        if (@abs(x) > 0.75) {
            const sign: f32 = if (x >= 0) 1.0 else -1.0;
            const excess = @abs(x) - 0.75;
            x = sign * (0.75 + 0.20 * (excess / (0.20 + excess)));
        }
        if (x > 0.95) x = 0.95;
        if (x < -0.95) x = -0.95;
        out[i] = @intFromFloat(@round(x * 32767.0));
    }
}

fn renderSyllableInto(out: []i16, syl: *const Syll, stressed: bool, prng: *std.Random.DefaultPrng, knobs: VoiceKnobs) void {
    const eff = knobs.effort();
    const pitch = knobs.pitchFactor();
    var p: VoiceParams = undefined;
    if (syl.vowel == 0) {
        // Consonant-only tail: a short whisper, not a buzz. The knobs reach this
        // literal too, so `--voice noise=0` means "no noise anywhere" rather
        // than "no noise except on the rare breath syllable".
        const spec = knobs.apply(.{
            .attack_s = 0.006,
            .noise_mix = 0.85,
            .wobble_hz = 31.0,
            .wobble_depth = 0.30,
            .level = 0.65,
            .pressure = 0.75,
            .tension = 0.85,
            .resonance = 0.80,
            .turbulence = 1.25,
        });
        p = .{
            .f0 = 84.0 * pitch,
            .attack_s = spec.attack_s,
            .noise_mix = spec.noise_mix,
            .wobble_hz = spec.wobble_hz,
            .wobble_depth = spec.wobble_depth,
            .level = spec.level,
            .glide = 0.18,
            .pressure = spec.pressure,
            .tension = spec.tension,
            .resonance = spec.resonance,
            .turbulence = spec.turbulence,
            .formants = vowelFormants(0),
            .plosive = onsetPlosiveSpec(syl.onset()),
        };
        applyEffort(&p, eff);
    } else {
        const onset_str = syl.onset();
        const spec = knobs.apply(voiceSpec(classify(onset_str)));
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
            .formants = vowelFormants(syl.vowel),
            .plosive = onsetPlosiveSpec(onset_str),
        };
        applyEffort(&p, eff);
        // Swahili stresses the penultimate syllable of a word. The emphasis
        // rides on effort (#15): a shout pushes it past the stock 1.2, and a
        // whisper flatlines it — a whispered word has no dynamic shape.
        if (stressed) {
            p.level *= stressBoost(eff);
            p.pressure = std.math.clamp(p.pressure * 1.12, VoiceKnobs.min_pressure, VoiceKnobs.max_pressure);
        }
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
/// `cents` does not apply — a shuzi has no vowels, its pitch is random.
pub fn renderShuziWavWith(allocator: std.mem.Allocator, seed: u64, knobs: VoiceKnobs) ![]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const n_syl: usize = 1 + r.uintLessThan(usize, 3);
    const Seg = struct { params: VoiceParams, len: usize, gap_after: usize };
    var segs: [3]Seg = undefined;
    var total: usize = 0;
    const eff = knobs.effort();
    var i: usize = 0;
    while (i < n_syl) : (i += 1) {
        const dur_ms: usize = (16 + r.uintLessThan(usize, 19)) * 10; // 160..340 ms
        const classes = [_]VoiceClass{ .stop_voiced, .stop_voiceless, .fricative, .nasal, .liquid };
        const cls = classes[r.uintLessThan(usize, classes.len)];
        const spec = knobs.apply(voiceSpec(cls));
        const gap_ms: usize = if (i + 1 < n_syl) (3 + r.uintLessThan(usize, 5)) * 10 else 0; // 30..70 ms
        const shuzi_vowels = [_]u8{ 'u', 'o', 'a', 'e', 'i' };
        const shuzi_onsets = [_][]const u8{ "b", "p", "sh", "mb", "r" };
        const cls_idx: usize = switch (cls) {
            .stop_voiced => 0,
            .stop_voiceless => 1,
            .fricative => 2,
            .nasal => 3,
            .liquid, .none => 4,
        };
        segs[i] = .{
            .params = .{
                .f0 = 64.0 + 42.0 * r.float(f32),
                .attack_s = spec.attack_s,
                // no clamp: this path's +0.10 already sits past the class
                // table's 1.0 cap, and clamping it now would move today's
                // bytes; effort multiplies what is there
                .noise_mix = (spec.noise_mix + 0.10) * eff,
                .wobble_hz = 24.0 + 10.0 * r.float(f32),
                .wobble_depth = 0.45 + 0.15 * r.float(f32),
                .level = 1.0 * eff,
                .glide = PITCH_DROP,
                .pressure = spec.pressure,
                .tension = spec.tension,
                .resonance = spec.resonance,
                .turbulence = spec.turbulence,
                .formants = vowelFormants(shuzi_vowels[cls_idx]),
                .plosive = onsetPlosiveSpec(shuzi_onsets[cls_idx]),
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
        .{ .attack = 1.0, .noise = 1.0, .wobble = 1.0, .intensity = 1.0, .cents = 0.0 },
    );
    defer alloc.free(explicit);
    try testing.expectEqualSlices(u8, plain, explicit);

    // and the empty string parses to the same identity
    const from_flag = try renderPhraseWavWith(alloc, "kujamba karibu", try parseKnobs(""));
    defer alloc.free(from_flag);
    try testing.expectEqualSlices(u8, plain, from_flag);
    const round_trip = try renderPhraseWavWith(alloc, "kujamba karibu", try parseKnobs("attack=1, noise=1 ,wobble=1,intensity=1,cents=0"));
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
        .{ .name = "pressure", .knobs = .{ .pressure = 1.8 } },
        .{ .name = "tension", .knobs = .{ .tension = 1.8 } },
        .{ .name = "resonance", .knobs = .{ .resonance = 1.8 } },
        .{ .name = "turbulence", .knobs = .{ .turbulence = 1.8 } },
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
    };
    for (wild) |knobs| {
        const out = try renderPhraseSamplesWith(alloc, "kujamba karibu", knobs);
        defer alloc.free(out);
        try testing.expect(out.len > 1000);
        try testing.expect(rmsOf(out) > 1.0); // still real audio, not silence
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

    // #15/#16: effort is a multiplier, cents an offset — the one key a
    // negative value is meaningful for
    const dyn = try parseKnobs("intensity=2, cents=-700");
    try testing.expectEqual(@as(f32, 2.0), dyn.intensity);
    try testing.expectEqual(@as(f32, -700.0), dyn.cents);
    try testing.expectError(error.Negative, parseKnobs("intensity=-1"));
    try testing.expectError(error.NotFinite, parseKnobs("cents=nan"));
    try testing.expectError(error.UnknownKnob, parseKnobs("pitch=2"));

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
    var p = VoiceParams{ .f0 = 100.0, .attack_s = 0.006, .noise_mix = 0.5, .wobble_hz = 30.0, .wobble_depth = 0.5, .level = 0.9, .glide = 0.2 };
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

test "physical parameters and phrase-to-synthesis mapping produce distinct deterministic textures" {
    const alloc = testing.allocator;

    // 1. Physical knobs parse and produce distinct audible textures (wet, dry, raspy, thunderous)
    const wet = try renderPhraseWavWith(alloc, "kujamba karibu", try parseKnobs("pressure=1.6,tension=0.6,resonance=2.2,turbulence=1.8"));
    defer alloc.free(wet);
    const dry_raspy = try renderPhraseWavWith(alloc, "kujamba karibu", try parseKnobs("pressure=1.1,tension=2.2,resonance=0.3,turbulence=0.4"));
    defer alloc.free(dry_raspy);
    const thunderous = try renderPhraseWavWith(alloc, "kujamba karibu", try parseKnobs("pressure=2.5,tension=0.5,resonance=1.8,turbulence=2.2,cents=-500"));
    defer alloc.free(thunderous);

    try testing.expect(!std.mem.eql(u8, wet, dry_raspy));
    try testing.expect(!std.mem.eql(u8, wet, thunderous));
    try testing.expect(!std.mem.eql(u8, dry_raspy, thunderous));
    try expectNotSilence(wet);
    try expectNotSilence(dry_raspy);
    try expectNotSilence(thunderous);

    // 2. Plosives (k, b, p) produce distinct pressure burst profiles
    const p_k = onsetPlosiveSpec("k");
    const p_b = onsetPlosiveSpec("b");
    const p_p = onsetPlosiveSpec("p");
    const p_m = onsetPlosiveSpec("m");
    try testing.expect(p_p.burst_amp > p_m.burst_amp);
    try testing.expect(p_b.burst_amp > p_m.burst_amp);
    try testing.expect(p_k.burst_amp > p_m.burst_amp);
    try testing.expect(p_k.pop_freq_hz != p_b.pop_freq_hz);

    // 3. Vowels map to distinct formant filter specs (F1/F2)
    const fa = vowelFormants('a');
    const fi = vowelFormants('i');
    const fu = vowelFormants('u');
    try testing.expect(fa.f1_hz > fi.f1_hz);
    try testing.expect(fi.f2_hz > fu.f2_hz);
}
