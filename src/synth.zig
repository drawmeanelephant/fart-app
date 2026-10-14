//! synth.zig — Flatlophone v2: real fart synthesis + Swahili syllable engine.
//!
//! Pure Zig stdlib. Emits PCM WAV (RIFF), 44100 Hz, mono, 16-bit. No libc, no
//! file I/O: every render is a pure function of its input. The noise generator
//! is seeded from a hash of the input text with fixed constants everywhere
//! else, so the same phrase always produces byte-identical WAV bytes. Always.
//!
//! One fart "phoneme" (one Swahili syllable) is:
//!   * a low-frequency buzzy oscillator with a sub-octave belly, soft-clipped
//!     for fatness, whose pitch sags *exponentially* as the vent pressure
//!     collapses (fast drop early, settling late — real deflation)
//!   * a sphincter flutter that wobbles amplitude *and* pitch at ~24-34 Hz
//!     with a slowly drifting rate, so it reads as muscle rather than LFO
//!   * filtered noise: a decaying attack burst (the "splat"), a quiet
//!     low-passed body hiss, a turbulence layer chopped into sputtering
//!     bursts by a slow random gate, and a raspy high edge under tension
//!   * a plosive layer for stop consonants (k, p, t, b, d, g): a ~7 ms
//!     pressure-hold dip, then a release burst of click + low thump
//!   * two resonant formant bandpasses tuned per vowel — the terminal tract
//!   * an amplitude envelope with a fast attack, pressure-coupled decay and
//!     a hard taper to exact zero (the loop-wrap invariant depends on it)
//!
//! Six physical knobs (`pressure`, `tension`, `resonance`, `turbulence`,
//! `wet`, `drop`) shape the instrument; see `VoiceKnobs` for what each does
//! to the sound.
//!
//! Swahili is nearly pure CV. `Scanner` splits a word into syllables: each
//! vowel picks the base pitch and the formant pair, the consonant onset
//! picks the attack/decay character and the plosive strength, and the
//! syllable count sets the total duration.
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

/// Per-run tuning of the three onset characters the class table sets: attack,
/// noise mix and wobble depth. Multipliers rather than absolutes, so an onset
/// class keeps its character — `--voice wobble=2` doubles the wobble of every
/// class instead of flattening them all to one number.
///
/// More axes ride along and are applied by the renderer rather than by
/// `apply`, because none belongs to the onset class: `intensity` (#15) is
/// vocal effort — it reaches the level, the noise mix and the stress emphasis,
/// which `apply` never sees — and `cents` (#16) transposes the vowel pitch
/// table, which is a property of the vowel, not of the consonant onset. The
/// physical layer is the same: `pressure`, `tension`, `resonance`,
/// `turbulence`, `wet` and `drop` describe the instrument, not the onset.
///
/// The default is 1.0 on every multiplier and 0 on `cents`, and `x * 1.0` is
/// exact in IEEE-754, so an untouched `VoiceKnobs` reproduces the class table
/// bit for bit. That is load-bearing, not decorative: the golden fingerprints
/// in `src/golden.zig` assert the default voice, so any deliberate change to
/// the stock sound means re-baselining them — as the physical-layer knobs did
/// when they made the default fart richer.
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
    /// Intestinal pressure, a multiplier. Higher pressure starts the pitch
    /// higher, hits louder, drives stronger plosive bursts and vents faster
    /// (the tail collapses sooner). Low pressure is a weak, straining wheeze.
    pressure: f32 = 1.0,
    /// Sphincter tension, a multiplier. Higher tension raises the pitch,
    /// speeds up and shallows the flutter, thins the sub-octave belly and adds
    /// a raspy ~3.4 kHz edge — dry and squeaky. Lower is loose, slow, flappy
    /// and sub-heavy — thunderous.
    tension: f32 = 1.0,
    /// Terminal-tract resonance. Scales the gain and sharpness of the vowel
    /// formant resonators: 0 is a flat wideband splat, high values ring and
    /// honk and make the vowel color unmistakable.
    resonance: f32 = 1.0,
    /// Noise-burst turbulence: a slow random gate that chops the breath noise
    /// into sputtering bursts across the whole syllable, not just the attack.
    /// 0 is a pure flutter tone; high values splutter and splatter.
    turbulence: f32 = 1.0,
    /// Wetness. Slow random gurgle modulates the buzz's amplitude and pitch
    /// and fattens the body hiss — bubbly and goopy at high values, dry at 0.
    wet: f32 = 1.0,
    /// Exponential pitch-drop rate: how hard the pitch sags as the vent
    /// pressure collapses. 0 holds pitch steady, 1 is a natural sag, high
    /// values dive-bomb.
    drop: f32 = 1.0,

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
    /// The physical layer's useful ranges. Pressure and tension floor above 0
    /// for the same reason intensity does: they multiply pitch and level, and
    /// 0 would be silence or a DC flatline. Resonance, turbulence, wet and
    /// drop are texture amounts — 0 is a legitimate dry/clean/steady sound.
    pub const min_pressure: f32 = 0.25;
    pub const max_pressure: f32 = 4.0;
    pub const min_tension: f32 = 0.25;
    pub const max_tension: f32 = 4.0;
    pub const max_resonance: f32 = 3.0;
    pub const max_turbulence: f32 = 3.0;
    pub const max_wet: f32 = 3.0;
    pub const max_drop: f32 = 4.0;

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

    /// `pressure` clamped into its useful range — it multiplies pitch and
    /// level, so like `intensity` it can never reach 0 and mute the fart.
    pub fn pressureEff(self: VoiceKnobs) f32 {
        return std.math.clamp(self.pressure, min_pressure, max_pressure);
    }

    /// `tension` clamped: it scales pitch and flutter rate.
    pub fn tensionEff(self: VoiceKnobs) f32 {
        return std.math.clamp(self.tension, min_tension, max_tension);
    }

    /// `resonance` clamped; 0 (flat tract, no ring) is a real sound.
    pub fn resonanceEff(self: VoiceKnobs) f32 {
        return std.math.clamp(self.resonance, 0.0, max_resonance);
    }

    /// `turbulence` clamped; 0 (no sputter) is a real sound.
    pub fn turbulenceEff(self: VoiceKnobs) f32 {
        return std.math.clamp(self.turbulence, 0.0, max_turbulence);
    }

    /// `wet` clamped; 0 (dry) is a real sound.
    pub fn wetEff(self: VoiceKnobs) f32 {
        return std.math.clamp(self.wet, 0.0, max_wet);
    }

    /// `drop` clamped; 0 holds the pitch steady for the whole syllable.
    pub fn dropEff(self: VoiceKnobs) f32 {
        return std.math.clamp(self.drop, 0.0, max_drop);
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
        };
    }
};

pub const KnobsError = error{ UnknownKnob, MalformedKnob, NotFinite, Negative };

/// Parse `attack=1.2,noise=0.8,wobble=2` into multipliers. Order is free and
/// whitespace around keys and values is ignored; an empty string is the
/// identity, which is what `--voice ""` and an omitted flag both mean.
/// `intensity` and `cents` (#15, #16) take the same spelling: `intensity` is
/// a multiplier (>= 0), `cents` an offset in cents and the one key a negative
/// value is meaningful for. The physical layer — `pressure`, `tension`,
/// `resonance`, `turbulence`, `wet`, `drop` — are all multipliers too.
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
        } else if (std.mem.eql(u8, key, "wet")) {
            knobs.wet = v;
        } else if (std.mem.eql(u8, key, "drop")) {
            knobs.drop = v;
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

/// The terminal-tract formants a vowel rings at: two resonant bandpasses,
/// tuned a fourth or so below speech formants — this tract is not a mouth.
/// The breath syllable (vowel 0) gets a wide, low midrange pair.
pub fn vowelFormants(v: u8) [2]f32 {
    return switch (v) {
        'a' => .{ 380.0, 980.0 }, // open: bright, broad
        'e' => .{ 340.0, 1500.0 }, // fronted: a higher edge
        'i' => .{ 280.0, 1900.0 }, // tight: buzzy, nasal ring
        'o' => .{ 340.0, 760.0 }, // rounded: dark honk
        'u' => .{ 260.0, 620.0 }, // closed: tubby, throaty
        else => .{ 300.0, 900.0 }, // breath syllable: neutral tract
    };
}

const VoiceParams = struct {
    f0: f32,
    attack_s: f32,
    noise_mix: f32,
    wobble_hz: f32,
    wobble_depth: f32,
    level: f32,
    glide: f32,
    // Physical layer, already knob-resolved by the caller. Defaults are the
    // stock tract so a VoiceParams literal that names only the old fields
    // still describes the default instrument.
    pressure: f32 = 1.0, // intestinal pressure multiplier
    tension: f32 = 1.0, // sphincter tension multiplier
    resonance: f32 = 1.0, // formant resonator amount/sharpness
    turbulence: f32 = 1.0, // stochastic noise-burst sputter amount
    wet: f32 = 1.0, // gurgle depth
    drop: f32 = 1.0, // exponential pitch-sag rate multiplier
    plosive: f32 = 0.0, // stop-onset release burst strength (0 = no closure)
    f1: f32 = 300.0, // tract formant 1, Hz
    f2: f32 = 900.0, // tract formant 2, Hz
};

/// Cubic soft clipper: `x(27+x²)/(27+9x²)` tracks tanh within a percent but
/// needs no libcall. Saturation adds the odd harmonics that make the buzz
/// fat instead of flute-like, and gently squashes the loudest peaks.
fn softClip(x: f32) f32 {
    const x2 = x * x;
    return x * (27.0 + x2) / (27.0 + 9.0 * x2);
}

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
/// The model, roughly: intestinal pressure pushes air through a fluttering
/// aperture (the carrier, amplitude-modulated by the flap) and the turbulent
/// jet makes noise; the terminal tract's two formants ring on top. Pressure
/// vents exponentially, so pitch and amplitude sag with it.
fn synthInto(out: []i16, p: VoiceParams, prng: *std.Random.DefaultPrng) void {
    const dt: f32 = 1.0 / @as(f32, SAMPLE_RATE);
    const tau: f32 = std.math.tau;
    var phase: f32 = 0;
    var sub_phase: f32 = 0;
    var lp_body: f32 = 0;
    var lp_burst: f32 = 0;
    var lp_sput: f32 = 0; // sputter texture band, ~2.4 kHz
    var lp_edge: f32 = 0; // raspy edge band for high tension, ~3.4 kHz
    const alpha_body: f32 = 1.0 - @exp(-tau * 700.0 * dt);
    const alpha_burst: f32 = 1.0 - @exp(-tau * 1900.0 * dt);
    const alpha_sput: f32 = 1.0 - @exp(-tau * 2400.0 * dt);
    const alpha_edge: f32 = 1.0 - @exp(-tau * 3400.0 * dt);
    const r = prng.random();
    const wobble_phase: f32 = r.float(f32) * tau;
    const drift_phase: f32 = r.float(f32) * tau;
    const wobble_hz: f32 = p.wobble_hz * (0.9 + 0.2 * r.float(f32));

    // Slow modulators. A one-pole LP at ~6 Hz would squash white noise to a
    // wiggle of a few percent, so the gurgle and the turbulence gate are sums
    // of incommensurate sinusoids with per-syllable random phases instead —
    // smooth pseudo-random wander with real depth, still deterministic.
    const gurgle_ph = [2]f32{ r.float(f32) * tau, r.float(f32) * tau };
    const gurgle_hz = [2]f32{ 6.0 + 2.5 * r.float(f32), 11.0 + 4.0 * r.float(f32) };
    const sput_ph = [3]f32{ r.float(f32) * tau, r.float(f32) * tau, r.float(f32) * tau };
    const sput_hz = [3]f32{ 3.5 + 1.5 * r.float(f32), 6.5 + 2.5 * r.float(f32), 9.5 + 3.0 * r.float(f32) };

    // Terminal tract: two Chamberlin SVF bandpasses, one per vowel formant.
    // `damp` falls as `resonance` rises, so the knob both sharpens the ring
    // and (through the `damp` gain compensation below) leaves its loudness to
    // `res_gain` alone.
    const f1c = std.math.clamp(p.f1, 60.0, 3000.0);
    const f2c = std.math.clamp(p.f2, 60.0, 4000.0);
    const g1 = 2.0 * @sin(std.math.pi * f1c * dt);
    const g2 = 2.0 * @sin(std.math.pi * f2c * dt);
    const damp = std.math.clamp(0.55 - 0.15 * p.resonance, 0.08, 0.55);
    const res_gain = p.resonance * 0.6;
    var f1_low: f32 = 0;
    var f1_band: f32 = 0;
    var f2_low: f32 = 0;
    var f2_band: f32 = 0;

    // Exponential pitch decay: pitch sags as the vent pressure collapses,
    // normalized so the total drop across the syllable is `drop_amt` —
    // `glide * drop` — with most of the fall early, like real deflation.
    const drop_amt = std.math.clamp(p.glide * p.drop, 0.0, 0.85);
    const vent_tau: f32 = 0.30; // pressure vents over ~30% of the syllable
    const drop_norm = 1.0 - @exp(-1.0 / vent_tau);

    // Higher pressure hits harder and vents sooner.
    const press_rate = std.math.clamp(0.8 + 0.5 * (p.pressure - 1.0), 0.3, 2.5);
    const decay_pow = 1.3 * (0.75 + 0.25 * p.pressure);
    // Tension trades belly for rasp: low tension keeps a fat sub-octave,
    // high tension grows a 3.4 kHz scratch band.
    const sub_gain = 0.42 * std.math.clamp(1.6 - 0.6 * p.tension, 0.0, 1.3);
    const edge_gain = std.math.clamp(p.tension - 1.0, 0.0, 2.0) * 0.16;
    // Plosive geometry: a ~7 ms closure dip in the carrier, then a ~14 ms
    // release burst of click + low thump. Zero plosive skips both.
    const hold_n: usize = @intFromFloat(0.007 * @as(f32, SAMPLE_RATE));
    const plosive_n: usize = @intFromFloat(0.014 * @as(f32, SAMPLE_RATE));
    const plosive_gain = p.plosive * (0.6 + 0.4 * p.pressure);
    // Everything the envelope does must still land on exact zero at the last
    // sample (the loop-mode wrap test asserts it), so the last 64 samples get
    // a hard linear taper on top of the natural decay.
    const n = out.len;
    const nf: f32 = @floatFromInt(n);
    for (0..n) |i| {
        const fi: f32 = @floatFromInt(i);
        const t = fi * dt;
        const u = fi / nf;

        const press_env = @exp(-u * press_rate);

        // Wetness: a slow pseudo-random gurgle rides the buzz's amplitude and
        // pitch — two beating low sinusoids per syllable, so it wanders like
        // liquid rather than buzzing like an LFO.
        const gurgle = 0.6 * @sin(tau * gurgle_hz[0] * t + gurgle_ph[0]) +
            0.4 * @sin(tau * gurgle_hz[1] * t + gurgle_ph[1]);
        const gurgle_am = 1.0 + p.wet * 0.40 * gurgle;
        const gurgle_fm = 1.0 + p.wet * 0.05 * gurgle;

        // The flap rate drifts slowly so the flutter reads as muscle, not LFO.
        const wob_rate = wobble_hz * (1.0 + 0.14 * @sin(tau * 0.9 * t + drift_phase));
        const flap = @sin(tau * wob_rate * t + wobble_phase);
        const wob = 1.0 - p.wobble_depth * (0.5 + 0.5 * flap);

        // Pitch: exponential sag + flutter FM (the aperture's flutter beats
        // the stream too) + gurgle wander.
        const sag = 1.0 - drop_amt * (1.0 - @exp(-u / vent_tau)) / drop_norm;
        const f = p.f0 * sag * gurgle_fm * (1.0 + 0.05 * p.tension * flap * p.wobble_depth);
        phase += tau * f * dt;
        if (phase >= tau) phase -= tau;
        sub_phase += tau * f * 0.5 * dt;
        if (sub_phase >= tau) sub_phase -= tau;
        var carrier = @sin(phase) + 0.55 * @sin(2.0 * phase) + 0.30 * @sin(3.0 * phase) + 0.12 * @sin(4.0 * phase);
        carrier = softClip((carrier + sub_gain * @sin(sub_phase)) * (0.42 + 0.10 * p.pressure));
        // A stop holds the pressure for a beat before releasing it.
        if (i < hold_n and p.plosive > 0) {
            const h = fi / @as(f32, @floatFromInt(hold_n));
            carrier *= 0.25 + 0.75 * h * h;
        }

        // Plosive release: a click plus a low thump, in the first ~14 ms.
        var plos: f32 = 0;
        if (i < plosive_n and p.plosive > 0) {
            const pc = prng.random().float(f32) * 2.0 - 1.0;
            plos = plosive_gain * (0.65 * pc * @exp(-t / 0.004) + 0.9 * @sin(tau * 62.0 * t) * @exp(-t / 0.022));
        }

        // Turbulence: the breath band chopped into sputtering bursts by a
        // slow pseudo-random gate — irregular splatter rather than a steady
        // hiss. The gate spends real time near zero, so bursts cluster.
        const sput_lfo = 0.5 * @sin(tau * sput_hz[0] * t + sput_ph[0]) +
            0.35 * @sin(tau * sput_hz[1] * t + sput_ph[1]) +
            0.30 * @sin(tau * sput_hz[2] * t + sput_ph[2]);
        const sput_gate = std.math.clamp(1.7 * (sput_lfo - 0.10), 0.0, 1.0);
        const wn_sp = prng.random().float(f32) * 2.0 - 1.0;
        lp_sput += alpha_sput * (wn_sp - lp_sput);
        const sputter = lp_sput * sput_gate * p.turbulence * 0.85;

        // Filtered noise: a decaying attack burst + a quiet body hiss + the
        // sputter layer + the tension edge.
        const wn_body = prng.random().float(f32) * 2.0 - 1.0;
        lp_body += alpha_body * (wn_body - lp_body);
        const wn_burst = prng.random().float(f32) * 2.0 - 1.0;
        lp_burst += alpha_burst * (wn_burst - lp_burst);
        const wn_edge = prng.random().float(f32) * 2.0 - 1.0;
        lp_edge += alpha_edge * (wn_edge - lp_edge);
        const burst_env = @exp(-t / 0.045);
        const noise = lp_body * (0.30 + 0.15 * p.wet) + lp_burst * 0.9 * burst_env + sputter + lp_edge * edge_gain;

        const dry = carrier * gurgle_am + p.noise_mix * noise + plos;

        // The tract rings on the dry mix: two resonant bandpasses whose band
        // output peaks near input level once damp-normalized.
        f1_low += g1 * f1_band;
        const f1_high = dry - f1_low - damp * f1_band;
        f1_band += g1 * f1_high;
        f2_low += g2 * f2_band;
        const f2_high = dry - f2_low - damp * f2_band;
        f2_band += g2 * f2_high;
        const formant = res_gain * damp * (f1_band + 0.7 * f2_band);

        // Envelope: fast attack, decay to zero, venting with the pressure,
        // fluttering at ~24-34 Hz.
        const attack = @min(1.0, t / p.attack_s);
        const decay = std.math.pow(f32, 1.0 - u, decay_pow);
        const vent = 0.35 + 0.65 * press_env;
        const tail = @min(1.0, (nf - fi) / 64.0);
        const env = attack * decay * vent * tail;

        // Master trim: the added layers (sub, saturation, formants, plosives)
        // run the pre-clip signal hot, and hot is good — but only at the
        // transient. 0.62 keeps the steady state under the rail so level
        // differences (stress, effort, pressure) stay audible instead of
        // being squashed flat against the clip.
        var x = (dry + formant) * env * wob * p.level * 0.62;
        if (x > 0.95) x = 0.95;
        if (x < -0.95) x = -0.95;
        out[i] = @intFromFloat(@round(x * 32767.0));
    }
}

fn renderSyllableInto(out: []i16, syl: *const Syll, stressed: bool, prng: *std.Random.DefaultPrng, knobs: VoiceKnobs) void {
    const eff = knobs.effort();
    const pitch = knobs.pitchFactor();
    // A stressed syllable is *pushed*, not just louder: the loudness emphasis
    // lands on `level` below, and here the same accent adds a little pressure
    // — brighter pitch, harder onset, faster vent. The bump tracks how much
    // emphasis effort left intact, so a whisper still has no dynamic shape.
    const boost = if (syl.vowel != 0 and stressed) stressBoost(eff) else 1.0;
    const pressure = std.math.clamp(
        knobs.pressureEff() * (1.0 + (boost - 1.0) * 0.9),
        VoiceKnobs.min_pressure,
        VoiceKnobs.max_pressure,
    );
    const tension = knobs.tensionEff();
    var p: VoiceParams = undefined;
    if (syl.vowel == 0) {
        // Consonant-only tail: a short whisper, not a buzz. The knobs reach this
        // literal too, so `--voice noise=0` means "no noise anywhere" rather
        // than "no noise except on the rare breath syllable".
        const spec = knobs.apply(.{ .attack_s = 0.006, .noise_mix = 0.85, .wobble_hz = 31.0, .wobble_depth = 0.30, .level = 0.65 });
        p = .{ .f0 = 88.0 * pitch, .attack_s = spec.attack_s, .noise_mix = spec.noise_mix, .wobble_hz = spec.wobble_hz, .wobble_depth = spec.wobble_depth, .level = spec.level, .glide = 0.15 };
        applyEffort(&p, eff);
    } else {
        const cls = classify(syl.onset());
        const spec = knobs.apply(voiceSpec(cls));
        const fm = vowelFormants(syl.vowel);
        p = .{
            .f0 = vowelBaseFreq(syl.vowel).? * pitch,
            .attack_s = spec.attack_s,
            .noise_mix = spec.noise_mix,
            .wobble_hz = spec.wobble_hz,
            .wobble_depth = spec.wobble_depth,
            .level = spec.level,
            .glide = PITCH_DROP,
            // Stops are closures: the tract seals, pressure builds, then lets
            // go in a burst. Voiceless stops snap hardest; voiced ones thump.
            .plosive = switch (cls) {
                .stop_voiceless => 1.0,
                .stop_voiced => 0.75,
                else => 0.0,
            },
            .f1 = fm[0],
            .f2 = fm[1],
        };
        applyEffort(&p, eff);
        // Swahili stresses the penultimate syllable of a word. The emphasis
        // rides on effort (#15): a shout pushes it past the stock 1.2, and a
        // whisper flatlines it — a whispered word has no dynamic shape.
        p.level *= boost;
    }
    // The physical layer: the knobs resolve once per syllable and ride the
    // same paths a body would — pressure pushes pitch and level up and vents
    // faster; tension raises pitch and flutter rate while loosening the flap.
    p.pressure = pressure;
    p.tension = tension;
    p.resonance = knobs.resonanceEff();
    p.turbulence = knobs.turbulenceEff();
    p.wet = knobs.wetEff();
    p.drop = knobs.dropEff();
    p.f0 *= std.math.pow(f32, tension, 0.5) * std.math.pow(f32, pressure, 0.30);
    p.level *= @sqrt(pressure);
    p.wobble_hz = std.math.clamp(p.wobble_hz * std.math.pow(f32, tension, 0.8), 8.0, 90.0);
    p.wobble_depth = std.math.clamp(p.wobble_depth / @sqrt(tension), 0.0, VoiceKnobs.max_wobble_depth);
    // Per-syllable jitter, still a pure function of (phrase, syllable index):
    // each syllable gets its own pitch, flap rate and tract texture so the
    // phrase does not sound like a looped sample.
    const r = prng.random();
    p.f0 *= 1.0 + (r.float(f32) - 0.5) * 0.06;
    p.wobble_hz += (r.float(f32) - 0.5) * 3.0;
    p.wet = std.math.clamp(p.wet * (0.85 + 0.3 * r.float(f32)), 0.0, VoiceKnobs.max_wet);
    p.turbulence = std.math.clamp(p.turbulence * (0.85 + 0.3 * r.float(f32)), 0.0, VoiceKnobs.max_turbulence);
    p.f1 *= 1.0 + (r.float(f32) - 0.5) * 0.12;
    p.f2 *= 1.0 + (r.float(f32) - 0.5) * 0.12;
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
        // A wordless fart still has a tract: pick a random vowel-shaped
        // formant pair and a random physique per segment, then let the knobs
        // scale them. That is where the variety between seeds comes from.
        const fm = vowelFormants("aeiou"[r.uintLessThan(usize, 5)]);
        const pressure = (0.7 + 0.9 * r.float(f32)) * knobs.pressureEff();
        const tension = (0.5 + 1.0 * r.float(f32)) * knobs.tensionEff();
        segs[i] = .{
            .params = .{
                .f0 = (70.0 + 40.0 * r.float(f32)) * std.math.pow(f32, tension, 0.5) * std.math.pow(f32, pressure, 0.30),
                .attack_s = spec.attack_s,
                // no clamp: this path's +0.10 already sits past the class
                // table's 1.0 cap, and clamping it now would move today's
                // bytes; effort multiplies what is there
                .noise_mix = (spec.noise_mix + 0.10) * eff,
                .wobble_hz = std.math.clamp((24.0 + 10.0 * r.float(f32)) * std.math.pow(f32, tension, 0.8), 8.0, 90.0),
                .wobble_depth = 0.45 + 0.15 * r.float(f32),
                .level = 1.0 * eff * @sqrt(pressure),
                .glide = PITCH_DROP,
                .pressure = pressure,
                .tension = tension,
                .resonance = (0.5 + 1.0 * r.float(f32)) * knobs.resonanceEff(),
                .turbulence = (0.5 + 1.2 * r.float(f32)) * knobs.turbulenceEff(),
                .wet = (0.3 + 1.2 * r.float(f32)) * knobs.wetEff(),
                .drop = (0.6 + 1.2 * r.float(f32)) * knobs.dropEff(),
                .plosive = switch (cls) {
                    .stop_voiceless => 1.0,
                    .stop_voiced => 0.75,
                    else => 0.0,
                },
                .f1 = fm[0],
                .f2 = fm[1],
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
        // the physical layer: each of these has to actually reach the DSP
        .{ .name = "pressure", .knobs = .{ .pressure = 2.0 } },
        .{ .name = "tension", .knobs = .{ .tension = 2.0 } },
        .{ .name = "resonance", .knobs = .{ .resonance = 0.0 } },
        .{ .name = "turbulence", .knobs = .{ .turbulence = 0.0 } },
        .{ .name = "wet", .knobs = .{ .wet = 0.0 } },
        .{ .name = "drop", .knobs = .{ .drop = 0.0 } },
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
        // the physical layer at every rail at once: resonance 0 removes the
        // formants entirely, drop 1e9 pins the pitch at its floor — neither
        // may produce a NaN or silence
        .{ .pressure = 1e9, .tension = 1e9, .resonance = 1e9, .turbulence = 1e9, .wet = 1e9, .drop = 1e9 },
        .{ .pressure = 0.0, .tension = 0.0, .resonance = 0.0, .turbulence = 0.0, .wet = 0.0, .drop = 0.0 },
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

    // the physical layer parses like every other multiplier
    const phys = try parseKnobs("pressure=1.8,tension=0.6, resonance=2, turbulence=1.5,wet=0.7, drop=3");
    try testing.expectEqual(@as(f32, 1.8), phys.pressure);
    try testing.expectEqual(@as(f32, 0.6), phys.tension);
    try testing.expectEqual(@as(f32, 2.0), phys.resonance);
    try testing.expectEqual(@as(f32, 1.5), phys.turbulence);
    try testing.expectEqual(@as(f32, 0.7), phys.wet);
    try testing.expectEqual(@as(f32, 3.0), phys.drop);
    try testing.expectError(error.Negative, parseKnobs("pressure=-1"));
    try testing.expectError(error.Negative, parseKnobs("drop=-1"));
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
