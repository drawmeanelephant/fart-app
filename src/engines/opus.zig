//! synth.zig — Flatlophone v2: real fart synthesis + Swahili syllable engine.
//!
//! Pure Zig stdlib. Emits PCM WAV (RIFF), 44100 Hz, mono, 16-bit. No libc, no
//! file I/O: every render is a pure function of its input. The noise generator
//! is seeded from a hash of the input text with fixed constants everywhere
//! else, so the same phrase always produces byte-identical WAV bytes. Always.
//!
//! One fart "phoneme" (one Swahili syllable) is a small physical model (v3):
//!   * an intestinal pressure reservoir that bursts open and then decays
//!     exponentially; the sphincter's pitch rides on that pressure, so pitch
//!     falls exponentially as the gas runs out
//!   * a sphincter that opens and slaps shut once per cycle (a pulse-train
//!     valve, not a sine): its tension sets the pitch, how long it stays open,
//!     and the pressure below which it stops buzzing and sputters
//!   * flow-gated turbulence and random noise bursts, wet stick-slip splats
//!     and bubbles, and plosive pressure spikes
//!   * the terminal tract: vowel formants, a buttock "body" resonance, and
//!     the trousers' low-pass
//! The previous engine (v2: buzzy additive oscillator, attack splat, flutter)
//! is kept byte for byte behind `--voice classic=1`.
//!
//! Swahili is nearly pure CV. `Scanner` splits a word into syllables: each
//! vowel picks the base pitch and the formants, the consonant onset picks the
//! attack character and how the valve opens (burst, hiss, hum, trill, glide),
//! and the syllable count sets the total duration. The mapping tables live in
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
/// Two more axes ride along and are applied by the renderer rather than by
/// `apply`, because neither belongs to the onset class: `intensity` (#15) is
/// vocal effort — it reaches the level, the noise mix and the stress emphasis,
/// which `apply` never sees — and `cents` (#16) transposes the vowel pitch
/// table, which is a property of the vowel, not of the consonant onset.
///
/// The default is 1.0 on every multiplier and 0 on `cents`, and `x * 1.0` is
/// exact in IEEE-754, so an untouched `VoiceKnobs` reproduces the class table
/// bit for bit. That is load-bearing, not decorative: with `classic = 1` the
/// v2 golden fingerprints in `src/golden.zig` still assert the old sound
/// unchanged, and the v3 fingerprints pin the default physical model.
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

    // The v3 physical axes. Each multiplies what the phrase already asks for
    // (a "b" is looser and wetter than an "s" at any setting), so 1 is the
    // phrase's own sound and the knob moves the whole phrase in one direction.

    /// Intestinal pressure: how hard the gas pushes. Up: louder, slightly
    /// higher, longer before it runs out, harder plosive bursts, and past ~2
    /// (with low tension) thunderous. Down: weak, breathy, and it drops below
    /// the sphincter's threshold early, so the syllables sputter out.
    pressure: f32 = 1.0,
    /// Sphincter tension. Pitch follows sqrt(tension) like a string. Up: tight,
    /// squeaky, reedy, short open phase, dry, and a higher threshold pressure
    /// (tight + low pressure = a squeaker that sputters). Down: loose, flabby,
    /// low and wide open — wetter, slappier, and with pressure, thunder.
    tension: f32 = 1.0,
    /// Terminal tract resonance: how strongly the rectum/buttock cavity rings.
    /// 0 is the raw valve buzz with no vowel colour or body (dry, thin, raspy);
    /// 1 is stock; up to 4 sharpens the formants into a honking, boomy,
    /// trumpet-like fart.
    tract: f32 = 1.0,
    /// Noise-burst turbulence. 0 is a clean, perfectly periodic toy buzz. Up:
    /// more flow-gated rasp in every pulse, random spitting noise bursts, and
    /// more cycle-to-cycle jitter — raspy, crackly, ragged.
    turbulence: f32 = 1.0,
    /// Wetness, on top of what the phonemes bring ("b", "j", "ny", "u" are
    /// juicy; "s", "t", "i" are dry). Drives stick-slip (the valve sticks
    /// shut, then lets go with a splat), gurgling bubbles, and sloppy
    /// cycle-to-cycle irregularity. 0 is bone dry.
    wetness: f32 = 1.0,
    /// Depth of the exponential pitch decay (pitch ~ pressure^(0.3*droop)).
    /// 0 holds the pitch flat while the pressure still drains; 2 sags hard,
    /// like a deflating balloon.
    droop: f32 = 1.0,
    /// 1 selects the previous (v2) engine, bit for bit; the v3 axes above are
    /// ignored there. 0 (the default) is the physical model.
    classic: f32 = 0.0,

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
    /// v3: two octaves of physical range either way. Below 1/4 pressure the
    /// valve never reaches its threshold; past 4 tension the pitch leaves the
    /// register and the open phase is a click.
    pub const min_pressure: f32 = 0.25;
    pub const max_pressure: f32 = 4.0;
    pub const min_tension: f32 = 0.25;
    pub const max_tension: f32 = 4.0;
    /// tract, turbulence, wetness and droop go to 0 (the effect is off) and
    /// up to 4x stock; past that the resonators whistle and the noise drowns
    /// the valve.
    pub const max_physical: f32 = 4.0;

    /// The physical axes, clamped into their useful ranges.
    pub fn physical(self: VoiceKnobs) struct { pressure: f32, tension: f32, tract: f32, turbulence: f32, wetness: f32, droop: f32 } {
        return .{
            .pressure = std.math.clamp(self.pressure, min_pressure, max_pressure),
            .tension = std.math.clamp(self.tension, min_tension, max_tension),
            .tract = std.math.clamp(self.tract, 0.0, max_physical),
            .turbulence = std.math.clamp(self.turbulence, 0.0, max_physical),
            .wetness = std.math.clamp(self.wetness, 0.0, max_physical),
            .droop = std.math.clamp(self.droop, 0.0, max_physical),
        };
    }

    /// `classic >= 0.5` selects the v2 engine.
    pub fn isClassic(self: VoiceKnobs) bool {
        return self.classic >= 0.5;
    }

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
        };
    }
};

pub const KnobsError = error{ UnknownKnob, MalformedKnob, NotFinite, Negative };

/// Parse `attack=1.2,noise=0.8,wobble=2` into multipliers. Order is free and
/// whitespace around keys and values is ignored; an empty string is the
/// identity, which is what `--voice ""` and an omitted flag both mean.
/// `intensity` and `cents` (#15, #16) take the same spelling: `intensity` is
/// a multiplier (>= 0), `cents` an offset in cents and the one key a negative
/// value is meaningful for. The v3 axes (`pressure`, `tension`, `tract`,
/// `turbulence`, `wetness`, `droop`) are multipliers too, and `classic=1`
/// selects the v2 engine.
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
        } else if (std.mem.eql(u8, key, "tract")) {
            knobs.tract = v;
        } else if (std.mem.eql(u8, key, "turbulence")) {
            knobs.turbulence = v;
        } else if (std.mem.eql(u8, key, "wetness")) {
            knobs.wetness = v;
        } else if (std.mem.eql(u8, key, "droop")) {
            knobs.droop = v;
        } else if (std.mem.eql(u8, key, "classic")) {
            knobs.classic = v;
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

/// One syllable with no phrase context (not word-final), in whichever engine
/// the knobs select.
fn renderSyllableInto(out: []i16, syl: *const Syll, stressed: bool, prng: *std.Random.DefaultPrng, knobs: VoiceKnobs) void {
    if (knobs.isClassic()) return renderSyllableClassic(out, syl, stressed, prng, knobs);
    renderSyllableV3(out, syl, .{ .stressed = stressed }, prng, knobs);
}

/// The v2 syllable renderer, untouched: `classic=1` and its golden
/// fingerprints depend on every prng draw happening in this order.
fn renderSyllableClassic(out: []i16, syl: *const Syll, stressed: bool, prng: *std.Random.DefaultPrng, knobs: VoiceKnobs) void {
    const eff = knobs.effort();
    const pitch = knobs.pitchFactor();
    var p: VoiceParams = undefined;
    if (syl.vowel == 0) {
        // Consonant-only tail: a short whisper, not a buzz. The knobs reach this
        // literal too, so `--voice noise=0` means "no noise anywhere" rather
        // than "no noise except on the rare breath syllable".
        const spec = knobs.apply(.{ .attack_s = 0.006, .noise_mix = 0.85, .wobble_hz = 31.0, .wobble_depth = 0.30, .level = 0.65 });
        p = .{ .f0 = 88.0 * pitch, .attack_s = spec.attack_s, .noise_mix = spec.noise_mix, .wobble_hz = spec.wobble_hz, .wobble_depth = spec.wobble_depth, .level = spec.level, .glide = 0.15 };
        applyEffort(&p, eff);
    } else {
        const spec = knobs.apply(voiceSpec(classify(syl.onset())));
        p = .{
            .f0 = vowelBaseFreq(syl.vowel).? * pitch,
            .attack_s = spec.attack_s,
            .noise_mix = spec.noise_mix,
            .wobble_hz = spec.wobble_hz,
            .wobble_depth = spec.wobble_depth,
            .level = spec.level,
            .glide = PITCH_DROP,
        };
        applyEffort(&p, eff);
        // Swahili stresses the penultimate syllable of a word. The emphasis
        // rides on effort (#15): a shout pushes it past the stock 1.2, and a
        // whisper flatlines it — a whispered word has no dynamic shape.
        if (stressed) p.level *= stressBoost(eff);
    }
    // Per-syllable jitter, still a pure function of (phrase, syllable index).
    const r = prng.random();
    p.f0 *= 1.0 + (r.float(f32) - 0.5) * 0.06;
    p.wobble_hz += (r.float(f32) - 0.5) * 3.0;
    synthInto(out, p, prng);
}

// ---------------------------------------------------------------------
// v3: the physical model
// ---------------------------------------------------------------------

// Bit-stable math. `@sin`, `@cos`, `@exp`, `@log`, `@log2` and
// `std.math.pow` do not return the same bits in Debug and Release builds
// (measured on this toolchain: all six move, and `@sin` even differs between
// ReleaseSafe and ReleaseFast), while + - * / and `@sqrt` are exact IEEE and
// do not. So the physical model does its transcendental maths with these
// polynomials, built only from exact operations: v3 renders the same bytes in
// every optimization mode. Accurate to ~1e-6, far below one i16 step.

/// 2^x, x clamped to the normal f32 range.
fn exp2D(x: f32) f32 {
    const xc = std.math.clamp(x, -126.0, 126.0);
    const fl = @floor(xc);
    const f = xc - fl;
    // Taylor series of e^(f ln 2) on [0, 1): 8 terms, error < 2e-7
    const p = 1.0 + f * (0.6931472 + f * (0.2402265 + f * (0.05550411 + f * (0.009618129 + f * (0.001333356 + f * (1.540353e-4 + f * (1.525273e-5 + f * 1.321549e-6)))))));
    const e: i32 = @intFromFloat(fl);
    const scale: f32 = @bitCast(@as(u32, @intCast(e + 127)) << 23);
    return p * scale;
}

fn expD(x: f32) f32 {
    return exp2D(x * 1.442695);
}

/// log2(x) for x > 0 (anything smaller is treated as 1e-30).
fn log2D(x: f32) f32 {
    const bits: u32 = @bitCast(@max(x, 1e-30));
    const e: i32 = @as(i32, @intCast(bits >> 23)) - 127;
    const m: f32 = @bitCast((bits & 0x007F_FFFF) | 0x3F80_0000);
    // ln(m) = 2 atanh(s), s = (m - 1) / (m + 1) in [0, 1/3): error < 1e-7
    const s = (m - 1.0) / (m + 1.0);
    const s2 = s * s;
    const ln_m = 2.0 * s * (1.0 + s2 * (1.0 / 3.0 + s2 * (1.0 / 5.0 + s2 * (1.0 / 7.0 + s2 * (1.0 / 9.0 + s2 * (1.0 / 11.0 + s2 / 13.0))))));
    return @as(f32, @floatFromInt(e)) + ln_m * 1.442695;
}

fn lnD(x: f32) f32 {
    return log2D(x) * 0.6931472;
}

/// x^y for x > 0; 0 for x <= 0.
fn powD(x: f32, y: f32) f32 {
    if (x <= 0) return 0;
    return exp2D(y * log2D(x));
}

fn sinD(x: f32) f32 {
    const tau: f32 = std.math.tau;
    const half_pi: f32 = std.math.pi / 2.0;
    var r = x - @round(x / tau) * tau;
    if (r > half_pi) r = std.math.pi - r else if (r < -half_pi) r = -std.math.pi - r;
    const r2 = r * r;
    // Taylor series to r^13 on [-pi/2, pi/2]: error < 1e-8
    return r * (1.0 + r2 * (-1.0 / 6.0 + r2 * (1.0 / 120.0 + r2 * (-1.0 / 5040.0 + r2 * (1.0 / 362880.0 + r2 * (-1.0 / 39916800.0 + r2 / 6227020800.0))))));
}

fn cosD(x: f32) f32 {
    return sinD(x + std.math.pi / 2.0);
}

/// `VoiceKnobs.pitchFactor` in bit-stable maths, for the v3 path.
fn pitchFactorD(knobs: VoiceKnobs) f32 {
    if (knobs.cents == 0) return 1.0;
    return exp2D(std.math.clamp(knobs.cents, -VoiceKnobs.max_abs_cents, VoiceKnobs.max_abs_cents) / 1200.0);
}

/// Where a syllable sits in its phrase. The pressure reservoir is shaped by
/// it: a stressed syllable pushes harder and sustains, a word-final one runs
/// low and sputters, and the phrase's last one sputters out completely.
pub const SylContext = struct {
    stressed: bool = false,
    word_final: bool = false,
    phrase_final: bool = false,
    /// 0 at the phrase's first syllable, 1 at its last: pressure and pitch
    /// both sag a little across a phrase, like speech declination
    position: f32 = 0,
};

/// How a consonant is made, which decides how the valve opens.
pub const Manner = enum { vowel, stop, affricate, fricative, nasal, trill, lateral, glide };

/// Where a consonant is made: picks the burst/hiss noise band and the
/// formant transition into the vowel.
pub const Place = enum { labial, dental, alveolar, palatal, velar, glottal };

/// A consonant onset as the physical model sees it: how the valve opens,
/// plus the pressure/tension/wetness/rasp tendencies the consonant brings.
pub const Articulation = struct {
    manner: Manner = .vowel,
    place: Place = .glottal,
    voiced: bool = true,
    /// mb, nd, ng, nj, nz, ...: a hummed murmur before the consonant proper
    prenasal: bool = false,
    /// 'w' or 'y' for a glide onset or a closing glide (kwa, bwana, mya)
    glide: u8 = 0,
    /// multiplier on sphincter tension (and, as sqrt, on pitch)
    tension: f32 = 1.0,
    /// multiplier on intestinal pressure
    pressure: f32 = 1.0,
    /// wetness this onset brings, before the vowel's and the knob's
    wet: f32 = 0.2,
    /// roughness: period doubling (alternating strong/weak flaps) and jitter
    rasp: f32 = 0.0,
};

fn mkArt(manner: Manner, place: Place, voiced: bool, tension: f32, pressure: f32, wet: f32, rasp: f32) Articulation {
    return .{ .manner = manner, .place = place, .voiced = voiced, .tension = tension, .pressure = pressure, .wet = wet, .rasp = rasp };
}

/// Reads a Swahili onset (the consonants before the vowel) as a physical
/// articulation. Stops (p t k b d g) become closure + pressure burst,
/// affricates (ch j) a burst into hiss, fricatives (f v s z sh th dh gh kh h)
/// a hiss the buzz grows out of, nasals a muffled hum, r a trill, w/y a
/// formant glide. Prenasal clusters (mb, nd, ng, nj, nz) keep their hum.
pub fn articulate(onset: []const u8) Articulation {
    if (onset.len == 0) return .{};
    var core = onset;
    var glide: u8 = 0;
    if (core.len >= 2) {
        const tail = core[core.len - 1];
        if (tail == 'w' or (tail == 'y' and !std.mem.eql(u8, core, "ny"))) {
            glide = tail;
            core = core[0 .. core.len - 1];
        }
    }
    var prenasal = false;
    if (core.len >= 2 and (core[0] == 'm' or core[0] == 'n') and core[1] != 'y' and !std.mem.startsWith(u8, core, "ng'")) {
        prenasal = true;
        core = core[1..];
    }
    const c0 = core[0];
    const c1: u8 = if (core.len > 1) core[1] else 0;
    //                       manner      place      voiced tension pressure wet  rasp
    var a: Articulation = switch (c0) {
        'p' => mkArt(.stop, .labial, false, 1.10, 1.15, 0.10, 0.05),
        'b' => mkArt(.stop, .labial, true, 0.85, 1.10, 0.45, 0.05),
        't' => if (c1 == 'h')
            mkArt(.fricative, .dental, false, 1.10, 0.90, 0.10, 0.10)
        else
            mkArt(.stop, .alveolar, false, 1.25, 1.05, 0.05, 0.10),
        'd' => if (c1 == 'h')
            mkArt(.fricative, .dental, true, 1.05, 0.90, 0.15, 0.15)
        else
            mkArt(.stop, .alveolar, true, 1.00, 1.00, 0.30, 0.05),
        'k', 'q' => if (c1 == 'h')
            mkArt(.fricative, .velar, false, 1.05, 1.00, 0.15, 0.55)
        else
            mkArt(.stop, .velar, false, 1.10, 1.10, 0.12, 0.25),
        'g' => if (c1 == 'h')
            mkArt(.fricative, .velar, true, 0.95, 1.00, 0.35, 0.60)
        else
            mkArt(.stop, .velar, true, 0.90, 1.05, 0.40, 0.20),
        'c' => mkArt(.affricate, .palatal, false, 1.20, 1.05, 0.10, 0.15),
        'j' => mkArt(.affricate, .palatal, true, 0.95, 1.10, 0.60, 0.10),
        'f' => mkArt(.fricative, .labial, false, 1.15, 0.85, 0.05, 0.10),
        'v' => mkArt(.fricative, .labial, true, 1.00, 0.95, 0.15, 0.35),
        's' => if (c1 == 'h')
            mkArt(.fricative, .palatal, false, 1.30, 0.85, 0.05, 0.10)
        else
            mkArt(.fricative, .alveolar, false, 1.55, 0.80, 0.00, 0.05),
        'z' => mkArt(.fricative, .alveolar, true, 1.35, 0.90, 0.10, 0.40),
        'x' => mkArt(.fricative, .velar, false, 1.05, 1.00, 0.15, 0.55),
        'h' => mkArt(.fricative, .glottal, false, 0.90, 0.75, 0.10, 0.00),
        'm' => mkArt(.nasal, .labial, true, 0.75, 0.90, 0.35, 0.00),
        'n' => if (c1 == 'y')
            mkArt(.nasal, .palatal, true, 0.90, 0.95, 0.50, 0.00)
        else if (c1 == 'g')
            mkArt(.nasal, .velar, true, 0.80, 0.95, 0.35, 0.00)
        else
            mkArt(.nasal, .alveolar, true, 0.85, 0.90, 0.25, 0.00),
        'r' => mkArt(.trill, .alveolar, true, 1.05, 1.05, 0.15, 0.35),
        'l' => mkArt(.lateral, .alveolar, true, 0.90, 0.95, 0.30, 0.00),
        'w' => mkArt(.glide, .labial, true, 0.80, 1.10, 0.30, 0.00),
        'y' => mkArt(.glide, .palatal, true, 1.10, 1.00, 0.20, 0.00),
        else => mkArt(.fricative, .glottal, false, 0.90, 0.75, 0.10, 0.00),
    };
    if (prenasal) {
        a.prenasal = true;
        a.wet += 0.20;
        a.pressure *= 1.05;
    }
    switch (glide) {
        'w' => {
            a.tension *= 0.92;
            a.wet += 0.08;
        },
        'y' => a.tension *= 1.06,
        else => {},
    }
    a.glide = if (a.manner == .glide) c0 else glide;
    return a;
}

const VowelPhys = struct { f1: f32, f2: f32, tension: f32, pressure: f32, wet: f32 };

/// Vowel formants (an adult voice's F1/F2; the tract scales them down into
/// the butt register) and what each vowel does to the valve: open "a" pushes
/// more gas, close "i" tightens into a squeak, round "o"/"u" loosen and wet.
fn vowelPhys(v: u8) VowelPhys {
    return switch (v) {
        'a' => .{ .f1 = 760, .f2 = 1250, .tension = 0.95, .pressure = 1.10, .wet = 0.00 },
        'e' => .{ .f1 = 500, .f2 = 1750, .tension = 1.05, .pressure = 1.00, .wet = 0.00 },
        'i' => .{ .f1 = 300, .f2 = 2200, .tension = 1.30, .pressure = 0.95, .wet = -0.05 },
        'o' => .{ .f1 = 520, .f2 = 880, .tension = 0.88, .pressure = 1.05, .wet = 0.10 },
        'u' => .{ .f1 = 330, .f2 = 760, .tension = 0.80, .pressure = 1.00, .wet = 0.15 },
        // no vowel (a breath syllable): a neutral schwa cavity
        else => .{ .f1 = 450, .f2 = 1100, .tension = 1.00, .pressure = 0.90, .wet = 0.00 },
    };
}

/// Centre and Q of the burst/hiss noise for a place of articulation: "pff"
/// is low and wide, "sss" high and narrow, "shh" in between.
fn placeBand(p: Place) [2]f32 {
    return switch (p) {
        .labial => .{ 1300, 0.7 },
        .dental => .{ 2600, 0.8 },
        .alveolar => .{ 4200, 1.3 },
        .palatal => .{ 3000, 1.5 },
        .velar => .{ 1700, 1.8 },
        .glottal => .{ 1100, 0.6 },
    };
}

/// One syllable's fully resolved physical parameters.
const FartParams = struct {
    /// starting sphincter pitch, Hz (at full reservoir pressure)
    f0: f32,
    /// P0, intestinal pressure (1 = stock)
    pressure: f32,
    /// effective sphincter tension (1 = stock)
    tension: f32,
    /// terminal tract resonance amount (0 = none, 1 = stock)
    tract: f32,
    turbulence: f32,
    /// 0 = bone dry, 1.5 = sloppy
    wet: f32,
    /// 0..1 period doubling and jitter
    rasp: f32,
    droop: f32,
    /// 0..1: high pressure through a loose valve, emergent from the above
    thunder: f32,
    /// reservoir pressure left at the end of the syllable, as a fraction of P0
    end_ratio: f32,
    attack_s: f32,
    noise_mix: f32,
    wobble_hz: f32,
    wobble_depth: f32,
    level: f32,
    f1: f32,
    f2: f32,
    art: Articulation,
    /// a consonant-only syllable: a hum or a puff, not a full flap
    breath: bool,
};

/// Resolves one syllable from the onset and vowel tables, its phrase context,
/// and the knobs. `f0` arrives with the cents shift applied. The class table
/// still owns attack, noise mix, wobble and level, so every v2 knob keeps its
/// meaning here.
fn buildFart(onset: []const u8, vowel: u8, f0: f32, ctx: SylContext, knobs: VoiceKnobs) FartParams {
    const eff = knobs.effort();
    const k = knobs.physical();
    const a = articulate(onset);
    const vp = vowelPhys(vowel);
    const breath = vowel == 0;
    const spec = if (breath)
        knobs.apply(.{ .attack_s = 0.006, .noise_mix = 0.85, .wobble_hz = 31.0, .wobble_depth = 0.30, .level = 0.65 })
    else
        knobs.apply(voiceSpec(classify(onset)));

    // #15 effort: level and noise as in v2, and it pushes a little harder too
    var level = spec.level * eff;
    if (ctx.stressed) level *= stressBoost(eff);
    const noise_mix = std.math.clamp(spec.noise_mix * eff, 0.0, VoiceKnobs.max_noise_mix);

    const pos = std.math.clamp(ctx.position, 0.0, 1.0);
    const stress_push: f32 = if (ctx.stressed) 1.25 else 1.0;
    const pressure = k.pressure * a.pressure * vp.pressure * powD(eff, 0.35) * stress_push * (1.0 - 0.12 * pos);
    const tension = k.tension * a.tension * vp.tension;
    const lt = log2D(tension);
    const lp = log2D(pressure);
    const thunder = std.math.clamp(0.5 * (lp - lt) - 0.1, 0.0, 1.0);
    const wet = std.math.clamp(k.wetness * @max(0.0, a.wet + vp.wet) * (1.0 + 0.6 * @max(0.0, -lt)) * (0.75 + 0.25 * @min(pressure, 2.0)), 0.0, 1.5);
    const rasp = std.math.clamp(a.rasp + 0.3 * @max(0.0, lt) * @min(pressure, 2.0) + 0.08 * k.turbulence, 0.0, 1.0);
    const reservoir: f32 = if (ctx.phrase_final) 0.07 else if (ctx.word_final) 0.14 else if (ctx.stressed) 0.34 else 0.26;
    const end_ratio = std.math.clamp(reservoir * powD(k.pressure, 0.4), 0.03, 0.75);
    // Pitch: the vowel owns the base, and the consonant's and the knob's
    // tension tune it like a string, sqrt(T). The vowel's own tension shapes
    // the valve, not the pitch, so the vowel table stays the pitch table.
    const stress_lift: f32 = if (ctx.stressed) 1.04 else 1.0;
    const pitch = f0 * @sqrt(k.tension * a.tension) * powD(k.pressure, 0.1) * stress_lift * (1.0 - 0.06 * pos);
    return .{
        .f0 = pitch,
        .pressure = pressure,
        .tension = tension,
        .tract = k.tract,
        .turbulence = k.turbulence,
        .wet = wet,
        .rasp = rasp,
        .droop = k.droop,
        .thunder = thunder,
        .end_ratio = end_ratio,
        .attack_s = spec.attack_s,
        .noise_mix = noise_mix,
        .wobble_hz = spec.wobble_hz,
        .wobble_depth = spec.wobble_depth,
        .level = level,
        .f1 = vp.f1,
        .f2 = vp.f2,
        .art = a,
        .breath = breath,
    };
}

/// When things happen inside one syllable, in seconds from its start.
const Timeline = struct {
    /// the sphincter opens and the reservoir starts to drain
    release: f32 = 0,
    /// nasal murmur: the tract is muffled until here
    murmur_end: f32 = 0,
    /// voicing during a prenasal murmur
    murmur_voice: f32 = 0,
    /// voicing during a stop's closure (a voiced stop's "voice bar")
    bar_voice: f32 = 0,
    fric_start: f32 = 0,
    fric_end: f32 = 0,
    fric_gain: f32 = 0,
    /// how much buzz sits under the hiss while it lasts
    fric_voicing: f32 = 1,
    /// voiceless release: noise-only time before the buzz grows in
    aspiration: f32 = 0,
    /// plosive pressure spike at release, as a multiple of P0
    spike: f32 = 0,
    pop_noise: f32 = 0,
    pop_tau: f32 = 0.008,
    /// a voiced stop's low thud
    thump: f32 = 0,
    trill_end: f32 = 0,
};

fn buildTimeline(a: Articulation, dur: f32, breath: bool) Timeline {
    // onsets are timed for a 240 ms syllable and shrink with shorter ones
    const ts: f32 = @min(1.0, dur / 0.24);
    var tl = Timeline{};
    if (breath) {
        if (a.manner == .nasal) {
            tl.murmur_end = dur; // a syllabic "m": a hum through closed cheeks
        } else {
            tl.fric_end = dur * 0.8; // a puff with a little buzz under it
            tl.fric_gain = 0.9;
            tl.fric_voicing = 0.35;
        }
        return tl;
    }
    if (a.prenasal) {
        tl.murmur_end = 0.045 * ts;
        tl.murmur_voice = 0.6;
    }
    switch (a.manner) {
        .vowel, .lateral, .glide => {},
        .nasal => tl.murmur_end = 0.050 * ts,
        .trill => tl.trill_end = 0.085 * ts,
        .stop => {
            const closure: f32 = if (a.voiced) 0.010 else 0.018;
            tl.release = tl.murmur_end + closure * ts;
            tl.bar_voice = if (a.voiced) 0.12 else 0.0;
            tl.spike = if (a.voiced) 0.55 else 0.95;
            tl.pop_noise = if (a.voiced) 0.45 else 1.0;
            tl.aspiration = if (a.voiced) 0.0 else 0.022 * ts;
            tl.thump = if (a.voiced) 0.55 else 0.25;
            if (a.place == .labial) tl.thump *= 1.4;
        },
        .affricate => {
            tl.release = tl.murmur_end + 0.012 * ts;
            tl.bar_voice = if (a.voiced) 0.10 else 0.0;
            tl.spike = 0.6;
            tl.pop_noise = 0.8;
            tl.pop_tau = 0.020;
            const hiss: f32 = if (a.voiced) 0.030 else 0.045;
            tl.fric_start = tl.release;
            tl.fric_end = tl.release + hiss * ts;
            tl.fric_gain = 0.8;
            tl.aspiration = if (a.voiced) 0.0 else 0.015 * ts;
            tl.thump = if (a.voiced) 0.3 else 0.1;
        },
        .fricative => {
            const hiss: f32 = if (a.voiced) 0.045 else 0.065;
            tl.fric_start = tl.murmur_end;
            tl.fric_end = tl.murmur_end + hiss * ts;
            tl.fric_gain = 1.0;
            if (a.voiced) {
                tl.release = tl.fric_start;
                tl.fric_voicing = 0.6;
            } else {
                // the gas hisses through a valve that has not started to buzz
                tl.release = tl.fric_start + 0.6 * (tl.fric_end - tl.fric_start);
                tl.aspiration = 0.02 * ts;
            }
        },
    }
    return tl;
}

fn smoothStep(e0: f32, e1: f32, x: f32) f32 {
    const s = std.math.clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return s * s * (3.0 - 2.0 * s);
}

/// Rational tanh: round, warm saturation that never exceeds +-1. This is the
/// "fat" — loud flaps squash into the cheeks instead of hard-clipping.
fn softClip(x: f32) f32 {
    if (x >= 3.0) return 1.0;
    if (x <= -3.0) return -1.0;
    const x2 = x * x;
    return x * (27.0 + x2) / (27.0 + 9.0 * x2);
}

/// One prng draw split into three uniform [0, 1) dice of 21 bits each.
fn diceTriple(r: std.Random) [3]f32 {
    const v = r.int(u64);
    const s: f32 = 1.0 / 2097152.0;
    return .{
        @as(f32, @floatFromInt(v & 0x1F_FFFF)) * s,
        @as(f32, @floatFromInt((v >> 21) & 0x1F_FFFF)) * s,
        @as(f32, @floatFromInt((v >> 42) & 0x1F_FFFF)) * s,
    };
}

/// One-pole low-pass coefficient for cutoff `fc`. `w / (1 + w)` rather than
/// `1 - exp(-w)`: close enough for a tone control, and no transcendental
/// call in the per-block loop.
fn onePoleCoef(fc: f32) f32 {
    const w = std.math.tau * fc / @as(f32, @floatFromInt(SAMPLE_RATE));
    return w / (1.0 + w);
}

/// RBJ band-pass with 0 dB peak gain, transposed direct form II: sharpening
/// Q colours the sound without adding level at the centre.
const Biquad = struct {
    b0: f32 = 0,
    b2: f32 = 0,
    a1: f32 = 0,
    a2: f32 = 0,
    z1: f32 = 0,
    z2: f32 = 0,

    fn bandpass(fc: f32, q: f32) Biquad {
        var bq = Biquad{};
        bq.tune(fc, q);
        return bq;
    }

    fn tune(self: *Biquad, fc: f32, q: f32) void {
        const sr: f32 = @floatFromInt(SAMPLE_RATE);
        const w0 = std.math.tau * std.math.clamp(fc, 20.0, 0.45 * sr) / sr;
        const alpha = sinD(w0) / (2.0 * @max(q, 0.1));
        const a0 = 1.0 + alpha;
        self.b0 = alpha / a0;
        self.b2 = -alpha / a0;
        self.a1 = -2.0 * cosD(w0) / a0;
        self.a2 = (1.0 - alpha) / a0;
    }

    fn step(self: *Biquad, x: f32) f32 {
        const y = self.b0 * x + self.z1;
        self.z1 = self.z2 - self.a1 * y;
        self.z2 = self.b2 * x - self.a2 * y;
        return y;
    }
};

/// A gas bubble bursting in the wet: a damped sine that chirps upward as it
/// shrinks (the Minnaert resonance rises with a falling radius).
const Bubble = struct {
    phase: f32 = 0,
    freq: f32 = 0,
    rise: f32 = 0,
    env: f32 = 0,
    mul: f32 = 0,

    fn step(self: *Bubble) f32 {
        if (self.env < 1e-4) return 0;
        const y = self.env * sinD(self.phase);
        self.phase += std.math.tau * self.freq / @as(f32, @floatFromInt(SAMPLE_RATE));
        if (self.phase >= std.math.tau) self.phase -= std.math.tau;
        self.freq += self.rise;
        self.env *= self.mul;
        return y;
    }
};

fn spawnBubble(pool: *[4]Bubble, d_freq: f32, d_amp: f32, gain: f32, tension: f32) void {
    var slot: usize = 0;
    for (pool.*, 0..) |bub, j| {
        if (bub.env < pool[slot].env) slot = j;
    }
    const sr: f32 = @floatFromInt(SAMPLE_RATE);
    // mostly big, low bubbles; a tight valve squeezes out smaller ones
    const f = std.math.clamp((150.0 + 650.0 * d_freq * d_freq) * powD(tension, 0.3), 100.0, 2000.0);
    const life = std.math.clamp(3.0 / f, 0.002, 0.02);
    pool[slot] = .{
        .freq = f,
        .rise = f * 0.25 / (life * sr),
        .env = gain * (0.12 + 0.25 * d_amp),
        .mul = expD(-1.0 / (life * sr)),
    };
}

/// A band-passed noise burst with an exponential tail: turbulence spits and
/// wet splats.
const NoiseBurst = struct {
    env: f32 = 0,
    mul: f32 = 0,
    bp: Biquad = .{},

    fn fire(self: *NoiseBurst, gain: f32, decay_s: f32, fc: f32, q: f32) void {
        self.env = gain;
        self.mul = expD(-1.0 / (decay_s * @as(f32, @floatFromInt(SAMPLE_RATE))));
        self.bp.tune(fc, q);
    }

    fn step(self: *NoiseBurst, white: f32) f32 {
        if (self.env < 1e-4) return 0;
        const y = self.bp.step(white) * self.env;
        self.env *= self.mul;
        return y;
    }
};

/// Renders one physical-model fart phoneme into `out` (mono i16).
///
/// Per sample: the reservoir pressure decays exponentially from the release
/// (plus a plosive spike), the sphincter runs a pulse-train valve whose cycle
/// is re-decided at every flap — pitch from pressure^(0.3*droop), fire or
/// sputter from pressure vs the tension's threshold, stick-slip, bubbles,
/// noise bursts — and the flow goes through the terminal tract (formants and
/// a body resonance), the trousers' low-pass, and a soft clip.
///
/// Deterministic: the only randomness comes from `prng`, and every per-cycle
/// and per-sample draw happens whatever was decided, so a decision can never
/// shift the stream under the rest of the syllable.
fn fartInto(out: []i16, fp: FartParams, prng: *std.Random.DefaultPrng) void {
    const n = out.len;
    if (n == 0) return;
    const r = prng.random();
    const sr: f32 = @floatFromInt(SAMPLE_RATE);
    const dt: f32 = 1.0 / sr;
    const tau: f32 = std.math.tau;
    const pi: f32 = std.math.pi;
    const dur: f32 = @as(f32, @floatFromInt(n)) * dt;
    const a = fp.art;
    const tl = buildTimeline(a, dur, fp.breath);

    // fixed per-syllable draws
    const wob_phase = r.float(f32) * tau;
    const wob_hz = fp.wobble_hz * (0.9 + 0.2 * r.float(f32));
    const sq1_phase = r.float(f32) * tau;
    const sq1_hz = 2.0 + 3.5 * r.float(f32);
    const sq2_phase = r.float(f32) * tau;
    const sq2_hz = 6.0 + 5.0 * r.float(f32);

    // the valve
    const lt = log2D(fp.tension);
    // phonation threshold: below it the sphincter cannot sustain a buzz
    const p_th = 0.13 * powD(fp.tension, 0.9);
    // open quotient: a loose valve hangs open (round, flabby), a tight one
    // flicks open and slaps shut (buzzy, squeaky)
    const oq_base = std.math.clamp(0.60 - 0.16 * lt, 0.28, 0.80);
    const skew = std.math.clamp(0.62 + 0.08 * lt, 0.52, 0.80);
    const bright = std.math.clamp(0.32 + 0.20 * lt + 0.10 * log2D(fp.pressure) + 0.15 * fp.rasp, 0.06, 0.95);
    const gamma = 0.30 * fp.droop;
    const turb = fp.turbulence;
    const jitter = std.math.clamp(0.008 + 0.018 * turb + 0.04 * fp.wet + 0.03 * fp.rasp, 0.0, 0.25);
    const shimmer = std.math.clamp(0.05 + 0.08 * turb + 0.15 * fp.wet, 0.0, 0.6);
    const q_burst = std.math.clamp(0.025 + 0.06 * turb, 0.0, 0.5);
    const nm = fp.noise_mix;
    const asp_gain = nm * (0.3 + 0.7 * @min(turb, 3.0));
    const wd = fp.wobble_depth * 0.65;

    // the reservoir: P falls from 1 to end_ratio across the voiced part
    const active = @max(dur - tl.release, 0.01);
    const tau_p = active / -lnD(std.math.clamp(fp.end_ratio, 0.02, 0.95));
    const decay_mul = expD(-dt / tau_p);
    const spike_mul = expD(-dt / 0.018);
    const ts: f32 = @min(1.0, dur / 0.24);
    const close_len = @max(0.022 * ts, 0.004);

    // the tract
    const fscale = 0.75 * (1.0 - 0.15 * fp.thunder);
    const f1t = fp.f1 * fscale;
    const f2t = fp.f2 * fscale;
    var f1s = f1t;
    var f2s = f2t;
    if (a.manner != .vowel) {
        switch (a.place) {
            .labial => f2s = f2t * 0.8,
            .alveolar, .dental => f2s = 0.5 * f2t + 0.5 * 1800.0 * fscale,
            .palatal => f2s = 0.5 * f2t + 0.5 * 2200.0 * fscale,
            .velar => {
                f1s = f1t * 0.85;
                f2s = f2t * 1.12;
            },
            .glottal => {},
        }
    }
    if (a.glide == 'w') {
        f1s = 330.0 * fscale;
        f2s = 760.0 * fscale;
    } else if (a.glide == 'y') {
        f1s = 300.0 * fscale;
        f2s = 2200.0 * fscale;
    }
    const n1 = 260.0 * fscale; // nasal murmur: one low resonance, closed off
    const n2 = 1000.0 * fscale;
    const mix = std.math.clamp(0.72 * @sqrt(fp.tract), 0.0, 0.95);
    const qs = 0.6 + 0.4 * fp.tract;
    // the cheeks ring around the 2nd-3rd harmonic: that is where a fart's
    // "fat" lives on real speakers, which cannot reproduce a 60 Hz fundamental
    const body_f = std.math.clamp(170.0 * powD(fp.tension, 0.25) * (1.0 - 0.25 * fp.thunder), 90.0, 300.0);
    const body_g = 0.25 + 0.15 * fp.tract + 0.8 * fp.thunder;
    var bp1 = Biquad.bandpass(f1s, 3.0 * qs);
    var bp2 = Biquad.bandpass(f2s, 4.5 * qs);
    var bpb = Biquad.bandpass(body_f, 1.3 * qs);
    const lp_base = std.math.clamp(3200.0 * powD(fp.tension, 0.35) * (1.0 - 0.4 * fp.thunder), 350.0, 8000.0);
    const band = placeBand(a.place);
    var bp_asp = Biquad.bandpass(1500.0 + 1000.0 * bright, 0.8);
    var bp_fric = Biquad.bandpass(band[0], band[1]);
    var bp_pop = Biquad.bandpass(band[0] * 1.15, band[1] * 0.8);
    const a_hiss = onePoleCoef(900.0);
    const a_dc = onePoleCoef(35.0);
    // thunder is already loud through the valve and the body resonance; the
    // drive only leans it a little further into the soft clip
    const drive = 1.0 + 0.1 * fp.thunder + 0.1 * @max(0.0, log2D(fp.pressure));
    const sq1_depth = 0.07 + 0.10 * fp.thunder;
    const sq2_depth = 0.04 + 0.06 * fp.thunder;
    const th_f = std.math.clamp(2.0 * fp.f0, 90.0, 260.0);
    const th_mul = expD(-dt / 0.014);
    const pop_len: f32 = if (a.place == .labial) 0.0022 else 0.0012;
    const pop_mul = expD(-dt / tl.pop_tau);
    const trans_block = expD(-32.0 * dt / 0.035);
    const muffle_block = expD(-32.0 * dt / 0.025);
    const fric_mul = expD(-dt / 0.02);
    // the hiss leads the flap by ~10 dB: gas leaking past the valve, not a
    // spoken "s"
    const fric_amp = 0.7 * @sqrt(fp.pressure);
    const pop_amp = 1.2 * @sqrt(fp.pressure);
    // a fricative keeps leaking a little hiss under the buzz; an affricate's
    // hiss is gone once the valve is buzzing
    const fric_floor: f32 = if (a.manner == .fricative) 0.05 else 0.0;
    const fade_in: f32 = 0.001 * sr;
    const fade_out: f32 = 0.006 * sr;

    var x: f32 = 1.0; // position in the current cycle, in cycles
    var span: f32 = 1.0; // cycle length in cycles (> 1 while the valve sticks)
    var inc: f32 = fp.f0 / sr;
    var amp: f32 = 0;
    var oq: f32 = oq_base;
    var odd = false;
    var boost: f32 = 1.0;
    var splat_due = false;
    var u_prev: f32 = 0;
    var u_lp: f32 = 0;
    var decay: f32 = 1.0;
    var spike_env: f32 = 1.0;
    var trans: f32 = 1.0;
    var muffle: f32 = if (tl.murmur_end > 0) 1.0 else 0.0;
    var fric_tail: f32 = 1.0;
    var pop_env: f32 = tl.pop_noise;
    var th_env: f32 = tl.thump;
    var th_ph: f32 = 0;
    var hiss_lp: f32 = 0;
    var lp1: f32 = 0;
    var lp2: f32 = 0;
    var a_lp = onePoleCoef(lp_base);
    var dc_x: f32 = 0;
    var dc_y: f32 = 0;
    var bubbles: [4]Bubble = @splat(.{});
    var turb_ev = NoiseBurst{};
    var splat = NoiseBurst{};

    for (0..n) |i| {
        const fi: f32 = @floatFromInt(i);
        const t = fi * dt;
        const after = t >= tl.release;

        // block rate: formant transitions and the nasal murmur opening up
        if (i % 32 == 0) {
            if (t >= tl.murmur_end) muffle *= muffle_block;
            if (after) trans *= trans_block;
            const f1 = (f1t + (f1s - f1t) * trans) * (1.0 - muffle) + n1 * muffle;
            const f2 = (f2t + (f2s - f2t) * trans) * (1.0 - muffle) + n2 * muffle;
            bp1.tune(f1, 3.0 * qs);
            bp2.tune(f2, 4.5 * qs);
            a_lp = onePoleCoef(lp_base * (1.0 - 0.7 * muffle));
        }

        // intestinal pressure: the reservoir (sets pitch) and the pressure at
        // the valve (sets amplitude), which also has the attack and the final
        // closing of the sphincter in it
        const close = smoothStep(0.0, close_len, dur - t);
        var res_p: f32 = 0.8;
        var p_now: f32 = 0;
        if (after) {
            const te = t - tl.release;
            const rise = @min(1.0, te / fp.attack_s);
            // the gut squeezes unevenly; a big loose fart rolls with it
            const squeeze = 1.0 + sq1_depth * sinD(tau * sq1_hz * t + sq1_phase) + sq2_depth * sinD(tau * sq2_hz * t + sq2_phase);
            res_p = decay * squeeze + tl.spike * spike_env;
            p_now = fp.pressure * (rise * decay * squeeze + tl.spike * spike_env) * close;
            decay *= decay_mul;
            spike_env *= spike_mul;
        } else {
            p_now = fp.pressure * 0.6 * @min(1.0, t / 0.012) * close;
        }

        // a new flap: decide everything about this cycle at once
        if (x >= span) {
            x -= span;
            const d0 = diceTriple(r);
            const d1 = diceTriple(r);
            const d2 = diceTriple(r);
            const d3 = diceTriple(r);
            const d4 = diceTriple(r);
            odd = !odd;
            // exponential pitch decay: pitch rides the draining reservoir
            const ratio = std.math.clamp(res_p, 0.05, 3.0);
            const f = std.math.clamp(fp.f0 * powD(ratio, gamma) * (1.0 + jitter * (2.0 * d0[0] - 1.0)), 16.0, 1500.0);
            inc = f / sr;
            var fire_p: f32 = 1.0;
            var a_t: f32 = 0;
            if (after) {
                // near the threshold the valve misses flaps: the sputter
                // never quite zero: even a valve too tight for its pressure
                // squeaks out the odd weak flap, so no preset is silent
                fire_p = 0.12 + 0.88 * smoothStep(0.55, 1.45, p_now / p_th);
                a_t = @sqrt(@max(p_now - 0.5 * p_th, 0.25 * p_now));
            } else {
                const v_pre = if (t < tl.murmur_end) tl.murmur_voice else tl.bar_voice;
                a_t = @sqrt(p_now) * v_pre;
            }
            const fire = d0[1] < fire_p;
            amp = if (fire) a_t * (1.0 + shimmer * (2.0 * d0[2] - 1.0)) * boost else 0.0;
            boost = 1.0;
            oq = oq_base * (1.0 + 0.12 * (2.0 * d1[0] - 1.0));
            if (odd) {
                // rasp: every other flap is weaker and floppier
                amp *= 1.0 - 0.6 * fp.rasp;
                oq *= 1.0 + 0.25 * fp.rasp;
            }
            oq = std.math.clamp(oq, 0.2, 0.95);
            span = 1.0;
            if (splat_due) {
                splat.fire(fp.wet * @max(amp, 0.2) * 0.9, 0.004 + 0.008 * d4[1], 700.0 + 800.0 * d4[2], 0.9);
                splat_due = false;
            }
            if (fire and after) {
                if (d1[1] < fp.wet * 0.30) {
                    // stick-slip: the wet valve sticks shut, pressure piles up
                    // behind it, and it lets go with a bigger flap and a splat
                    span = 1.3 + 1.0 * d1[2];
                    boost = 1.2 + 0.35 * d1[2];
                    splat_due = true;
                }
                if (d2[0] < fp.wet * 0.5) spawnBubble(&bubbles, d2[1], d2[2], fp.wet * @max(amp, 0.3), fp.tension);
                if (d3[0] < q_burst) {
                    turb_ev.fire(nm * turb * (0.35 + 0.65 * d3[1]) * @max(amp, 0.3), 0.003 + 0.014 * d3[2], 600.0 + 2000.0 * d4[0], 1.2);
                }
            }
        }

        // the flap: a pulse of flow while the valve is open, nothing while shut
        var g: f32 = 0;
        if (x < oq) {
            const y = x / oq;
            g = if (y < skew) 0.5 - 0.5 * cosD(pi * y / skew) else cosD(0.5 * pi * (y - skew) / (1.0 - skew));
        }
        const flow = amp * g;
        // radiated sound is the flow's slope; normalised so the slap at
        // closure peaks near `amp` at any pitch or open quotient
        const slope = (flow - u_prev) * (oq * (1.0 - skew) / inc) * 0.6366;
        u_prev = flow;
        u_lp += a_dc * (flow - u_lp);
        const flow_hp = flow - u_lp;

        var v: f32 = 1.0;
        if (after and tl.aspiration > 0) v = smoothStep(tl.release, tl.release + tl.aspiration, t);
        if (t < tl.fric_end) v *= tl.fric_voicing;
        var wob = 1.0 - wd * (0.5 + 0.5 * sinD(tau * wob_hz * t + wob_phase));
        if (a.manner == .trill) {
            const gate = 1.0 - smoothStep(tl.trill_end, tl.trill_end + 0.02, t);
            wob *= 1.0 - 0.85 * gate * (0.5 + 0.5 * sinD(tau * 27.0 * t));
        }
        const src = (0.32 * flow_hp + (0.6 + 0.9 * bright) * slope) * v * wob;

        // every sample draws the same noise, used or not
        const na = diceTriple(r);
        const nb = diceTriple(r);
        // turbulence rides the flow: it only hisses while the valve is open
        const asp = bp_asp.step((2.0 * na[0] - 1.0) * flow) * asp_gain * 1.6;
        hiss_lp += a_hiss * ((2.0 * na[1] - 1.0) - hiss_lp);
        const hiss = hiss_lp * (p_now + 0.04 * fp.pressure * close) * nm * 0.35;

        // the plosive pop: a short pressure pulse at release
        var pop: f32 = 0;
        if (tl.spike > 0 and after) {
            const te = t - tl.release;
            if (te < pop_len) pop = tl.spike * fp.pressure * 0.9 * sinD(pi * te / pop_len);
        }

        // the terminal tract: formants + body resonance over a dry share
        const tin = src + asp + pop;
        const res = 1.3 * bp1.step(tin) + 0.8 * bp2.step(tin) + body_g * bpb.step(tin);
        var y = (1.0 - mix) * tin + mix * 1.8 * res;
        for (&bubbles) |*bub| y += bub.step();
        y += splat.step(2.0 * na[2] - 1.0) + turb_ev.step(2.0 * nb[0] - 1.0) + hiss;

        // the trousers
        lp1 += a_lp * (y - lp1);
        lp2 += a_lp * (lp1 - lp2);
        y = lp2;

        // frication and the release burst sit above the trousers' cutoff
        if (tl.fric_gain > 0 and t >= tl.fric_start) {
            if (t >= tl.fric_end) fric_tail *= fric_mul;
            const fe = smoothStep(tl.fric_start, tl.fric_start + 0.006, t) * (fric_floor + (1.0 - fric_floor) * fric_tail);
            y += bp_fric.step(2.0 * nb[1] - 1.0) * fe * tl.fric_gain * nm * fric_amp;
        }
        if (tl.pop_noise > 0 and after) {
            y += bp_pop.step(2.0 * nb[2] - 1.0) * pop_env * nm * pop_amp;
            pop_env *= pop_mul;
        }
        if (after and th_env > 1e-4) {
            y += th_env * sinD(th_ph) * 0.5 * fp.pressure;
            th_ph += tau * th_f * dt;
            if (th_ph >= tau) th_ph -= tau;
            th_env *= th_mul;
        }

        // DC block, level, and the fat soft clip
        const dc = y - dc_x + 0.9957 * dc_y;
        dc_x = y;
        dc_y = dc;
        var o = softClip(dc * fp.level * drive) * 0.94;
        o *= @min(1.0, fi / fade_in) * @min(1.0, @as(f32, @floatFromInt(n - 1 - i)) / fade_out);
        if (!std.math.isFinite(o)) o = 0;
        out[i] = @intFromFloat(@round(o * 32767.0));
        x += inc;
    }
}

/// One v3 syllable in its phrase context.
fn renderSyllableV3(out: []i16, syl: *const Syll, ctx: SylContext, prng: *std.Random.DefaultPrng, knobs: VoiceKnobs) void {
    const base: f32 = if (syl.vowel == 0) 88.0 else vowelBaseFreq(syl.vowel).?;
    var fp = buildFart(syl.onset(), syl.vowel, base * pitchFactorD(knobs), ctx, knobs);
    // per-syllable jitter, a pure function of (phrase, syllable index)
    const r = prng.random();
    fp.f0 *= 1.0 + (r.float(f32) - 0.5) * 0.06;
    fp.wobble_hz += (r.float(f32) - 0.5) * 3.0;
    fartInto(out, fp, prng);
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
    word_final: bool = false, // last syllable of its word: v3 lets it run out of gas
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
            buf[nitems] = .{ .syl = syl, .start = cursor, .len = len, .stressed = stressed, .word_final = emitted + 1 == nsyl };
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
    if (knobs.isClassic()) {
        for (plan.items) |item| {
            renderSyllableClassic(samples[item.start..][0..item.len], &item.syl, item.stressed, &prng, knobs);
        }
        return samples;
    }
    const last = plan.items.len - 1;
    for (plan.items, 0..) |item, idx| {
        const ctx = SylContext{
            .stressed = item.stressed,
            .word_final = item.word_final,
            .phrase_final = idx == last,
            .position = if (last == 0) 0 else @as(f32, @floatFromInt(idx)) / @as(f32, @floatFromInt(last)),
        };
        renderSyllableV3(samples[item.start..][0..item.len], &item.syl, ctx, &prng, knobs);
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
/// `cents` does not apply — a shuzi has no words, its pitch is random. In v3
/// each rumble also draws a random onset and vowel colour, and the physical
/// knobs apply as they do to a phrase.
pub fn renderShuziWavWith(allocator: std.mem.Allocator, seed: u64, knobs: VoiceKnobs) ![]u8 {
    if (knobs.isClassic()) return renderShuziClassic(allocator, seed, knobs);
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const n_syl: usize = 1 + r.uintLessThan(usize, 3);
    const onsets = [_][]const u8{ "", "b", "p", "bw", "mb", "ph", "g", "r", "gh", "v", "f", "ny", "pw", "d" };
    const vowels = "aeiou";
    const Seg = struct { fp: FartParams, len: usize, gap_after: usize };
    var segs: [3]Seg = undefined;
    var total: usize = 0;
    for (0..n_syl) |i| {
        const dur_ms: usize = (16 + r.uintLessThan(usize, 19)) * 10; // 160..340 ms
        const gap_ms: usize = if (i + 1 < n_syl) (3 + r.uintLessThan(usize, 5)) * 10 else 0; // 30..70 ms
        const onset = onsets[r.uintLessThan(usize, onsets.len)];
        const vowel = vowels[r.uintLessThan(usize, vowels.len)];
        const f0 = 60.0 + 50.0 * r.float(f32);
        const ctx = SylContext{
            .stressed = n_syl > 1 and i == 0,
            .word_final = i + 1 == n_syl,
            .phrase_final = i + 1 == n_syl,
            .position = if (n_syl == 1) 0 else @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n_syl - 1)),
        };
        var fp = buildFart(onset, vowel, f0, ctx, knobs);
        fp.wobble_hz = 24.0 + 10.0 * r.float(f32);
        segs[i] = .{
            .fp = fp,
            .len = dur_ms * SAMPLE_RATE / 1000,
            .gap_after = gap_ms * SAMPLE_RATE / 1000,
        };
        total += segs[i].len + segs[i].gap_after;
    }
    const samples = try allocator.alloc(i16, total);
    defer allocator.free(samples);
    @memset(samples, 0);
    var off: usize = 0;
    for (segs[0..n_syl]) |seg| {
        fartInto(samples[off..][0..seg.len], seg.fp, &prng);
        off += seg.len + seg.gap_after;
    }
    return writeWavBytes(allocator, samples, SAMPLE_RATE);
}

/// The v2 shuzi, untouched, for `classic=1` and its golden fingerprints.
fn renderShuziClassic(allocator: std.mem.Allocator, seed: u64, knobs: VoiceKnobs) ![]u8 {
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
        const spec = knobs.apply(voiceSpec(classes[r.uintLessThan(usize, classes.len)]));
        const gap_ms: usize = if (i + 1 < n_syl) (3 + r.uintLessThan(usize, 5)) * 10 else 0; // 30..70 ms
        segs[i] = .{
            .params = .{
                .f0 = 70.0 + 40.0 * r.float(f32),
                .attack_s = spec.attack_s,
                // no clamp: this path's +0.10 already sits past the class
                // table's 1.0 cap, and clamping it now would move today's
                // bytes; effort multiplies what is there
                .noise_mix = (spec.noise_mix + 0.10) * eff,
                .wobble_hz = 24.0 + 10.0 * r.float(f32),
                .wobble_depth = 0.45 + 0.15 * r.float(f32),
                .level = 1.0 * eff,
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

// --------------------------------------------------------------------------
// v3: the physical model
// --------------------------------------------------------------------------

fn testSyll(spelling: []const u8, onset_len: u8) Syll {
    var syl = Syll{ .text_len = @intCast(spelling.len), .onset_len = onset_len };
    @memcpy(syl.text_buf[0..spelling.len], spelling);
    syl.vowel = if (onset_len < spelling.len) spelling[onset_len] else 0;
    return syl;
}

/// One v3 syllable, rendered on its own with a fixed seed.
fn renderTestSyllable(alloc: std.mem.Allocator, spelling: []const u8, onset_len: u8, ctx: SylContext, knobs: VoiceKnobs) ![]i16 {
    const out = try alloc.alloc(i16, SYLLABLE_SAMPLES);
    const syl = testSyll(spelling, onset_len);
    var prng = std.Random.DefaultPrng.init(7);
    renderSyllableV3(out, &syl, ctx, &prng, knobs);
    return out;
}

/// Autocorrelation pitch over 40..400 Hz of a 2048-sample window centred at
/// `centre_s` seconds. The window is low-passed first so the cheeks' strong
/// 2nd harmonic cannot win, and the shortest lag within 85% of the best one
/// is taken, so the rasp's period doubling does not read as an octave down.
fn pitchAt(x: []const i16, centre_s: f32) f32 {
    const len: usize = 2048;
    const lo: usize = SAMPLE_RATE / 400;
    const hi: usize = SAMPLE_RATE / 40;
    const c: usize = @intFromFloat(centre_s * @as(f32, @floatFromInt(SAMPLE_RATE)));
    var w: [len]f64 = undefined;
    const k: f64 = onePoleCoef(150.0);
    var l1: f64 = 0;
    var l2: f64 = 0;
    // run the filter in from up to 20 ms earlier so it has settled
    for ((c - len / 2) -| (SAMPLE_RATE / 50)..c + len / 2) |i| {
        l1 += k * (@as(f64, @floatFromInt(x[i])) - l1);
        l2 += k * (l1 - l2);
        if (i >= c - len / 2) w[i - (c - len / 2)] = l2;
    }
    var ac: [hi + 2]f64 = undefined;
    var best: f64 = -std.math.inf(f64);
    for (lo - 1..hi + 2) |lag| {
        var acc: f64 = 0;
        for (0..len - lag) |i| acc += w[i] * w[i + lag];
        ac[lag] = acc / @as(f64, @floatFromInt(len - lag));
        if (lag >= lo and lag <= hi) best = @max(best, ac[lag]);
    }
    for (lo..hi + 1) |lag| {
        if (ac[lag] >= 0.85 * best and ac[lag] >= ac[lag - 1] and ac[lag] >= ac[lag + 1])
            return @as(f32, @floatFromInt(SAMPLE_RATE)) / @as(f32, @floatFromInt(lag));
    }
    return 0;
}

fn zeroCrossings(x: []const i16) usize {
    var n: usize = 0;
    for (x[1..], x[0 .. x.len - 1]) |b, a| {
        if ((a >= 0) != (b >= 0)) n += 1;
    }
    return n;
}

test "v3: classic=1 is the v2 engine and ignores the physical axes" {
    const alloc = testing.allocator;
    const v3 = try renderPhraseSamples(alloc, "kujamba karibu");
    defer alloc.free(v3);
    const classic = try renderPhraseSamplesWith(alloc, "kujamba karibu", .{ .classic = 1 });
    defer alloc.free(classic);
    try testing.expectEqual(v3.len, classic.len);
    try testing.expect(!std.mem.eql(i16, v3, classic));

    // the v3 axes do not exist in v2, so they must not move a sample there
    const classic_knobbed = try renderPhraseSamplesWith(alloc, "kujamba karibu", .{ .classic = 1, .pressure = 3, .tension = 0.3, .tract = 0, .turbulence = 4, .wetness = 4, .droop = 0 });
    defer alloc.free(classic_knobbed);
    try testing.expectEqualSlices(i16, classic, classic_knobbed);

    const shuzi = try renderShuziWavWith(alloc, 42, .{ .classic = 1 });
    defer alloc.free(shuzi);
    const shuzi_knobbed = try renderShuziWavWith(alloc, 42, .{ .classic = 1, .pressure = 3, .wetness = 0 });
    defer alloc.free(shuzi_knobbed);
    try testing.expectEqualSlices(u8, shuzi, shuzi_knobbed);

    const parsed = try parseKnobs("classic=1");
    try testing.expect(parsed.isClassic());
    try testing.expect(!(VoiceKnobs{}).isClassic());
}

test "v3: spelling out every physical default is still the identity" {
    const alloc = testing.allocator;
    const plain = try renderPhraseWav(alloc, "shuzi kubwa sana");
    defer alloc.free(plain);
    const explicit = try renderPhraseWavWith(alloc, "shuzi kubwa sana", try parseKnobs("pressure=1,tension=1,tract=1,turbulence=1,wetness=1,droop=1,classic=0"));
    defer alloc.free(explicit);
    try testing.expectEqualSlices(u8, plain, explicit);
}

test "v3: each physical axis changes the audio, deterministically" {
    const alloc = testing.allocator;
    const plain = try renderPhraseWav(alloc, "kujamba karibu");
    defer alloc.free(plain);
    const axes = [_]VoiceKnobs{
        .{ .pressure = 2.5 }, .{ .pressure = 0.5 },
        .{ .tension = 2.0 },  .{ .tension = 0.5 },
        .{ .tract = 0.0 },    .{ .tract = 3.0 },
        .{ .turbulence = 0 }, .{ .turbulence = 3.0 },
        .{ .wetness = 0 },    .{ .wetness = 3.0 },
        .{ .droop = 0 },      .{ .droop = 2.5 },
    };
    for (axes) |k| {
        const out = try renderPhraseWavWith(alloc, "kujamba karibu", k);
        defer alloc.free(out);
        try testing.expectEqual(plain.len, out.len);
        try testing.expect(!std.mem.eql(u8, plain, out));
        const again = try renderPhraseWavWith(alloc, "kujamba karibu", k);
        defer alloc.free(again);
        try testing.expectEqualSlices(u8, out, again);
    }
}

test "v3: physical extremes are clamped, never NaN, never silent" {
    const alloc = testing.allocator;
    const wild = [_]VoiceKnobs{
        .{ .pressure = 0, .tension = 0, .tract = 0, .turbulence = 0, .wetness = 0, .droop = 0 },
        .{ .pressure = 1e9, .tension = 1e9, .tract = 1e9, .turbulence = 1e9, .wetness = 1e9, .droop = 1e9 },
        .{ .pressure = 1e9, .tension = 0, .wetness = 1e9 },
        .{ .pressure = 0, .tension = 1e9, .turbulence = 1e9 },
        .{ .pressure = 4, .tension = 0.25, .intensity = 4, .noise = 1e9, .attack = 0 },
        .{ .pressure = 0.25, .tension = 4, .intensity = 0.25, .cents = 1200 },
        .{ .cents = -1200, .tension = 0.25, .droop = 4 },
    };
    for (wild) |k| {
        const out = try renderPhraseSamplesWith(alloc, "kujamba mbwa nyuki ng'ombe mtu", k);
        defer alloc.free(out);
        try testing.expect(rmsOf(out) > 1.0);
        const shuzi = try renderShuziWavWith(alloc, 3, k);
        defer alloc.free(shuzi);
        // a whisper through the tightest valve on the weakest push is meant
        // to be quiet, so this asks for audio, not for loudness
        var acc: f64 = 0;
        const n = wavDataByteLen(shuzi) / 2;
        for (0..n) |j| {
            const v: f64 = @floatFromInt(std.mem.readInt(i16, shuzi[44 + 2 * j ..][0..2], .little));
            acc += v * v;
        }
        try testing.expect(@sqrt(acc / @as(f64, @floatFromInt(n))) > 1.0);
    }
    const lo = (VoiceKnobs{ .pressure = 0, .tension = 0, .tract = -1, .turbulence = -1, .wetness = -1, .droop = -1 }).physical();
    try testing.expectEqual(VoiceKnobs.min_pressure, lo.pressure);
    try testing.expectEqual(VoiceKnobs.min_tension, lo.tension);
    try testing.expectEqual(@as(f32, 0), lo.tract);
    try testing.expectEqual(@as(f32, 0), lo.droop);
    const hi = (VoiceKnobs{ .pressure = 99, .tension = 99, .tract = 99, .turbulence = 99, .wetness = 99, .droop = 99 }).physical();
    try testing.expectEqual(VoiceKnobs.max_pressure, hi.pressure);
    try testing.expectEqual(VoiceKnobs.max_tension, hi.tension);
    try testing.expectEqual(VoiceKnobs.max_physical, hi.wetness);
}

test "v3: pitch rides the draining reservoir, and droop sets the depth" {
    const alloc = testing.allocator;
    // a clean valve (no jitter sources but the stock minimum) so the pitch
    // tracker sees the pitch, not the rasp
    const clean = VoiceKnobs{ .turbulence = 0, .wetness = 0 };
    const stock = try renderTestSyllable(alloc, "a", 0, .{}, clean);
    defer alloc.free(stock);
    const p0 = pitchAt(stock, 0.04);
    const p1 = pitchAt(stock, 0.12);
    const p2 = pitchAt(stock, 0.20);
    try testing.expect(p0 > 70 and p0 < 130);
    try testing.expect(p1 < p0 and p2 < p1);
    try testing.expect(p2 < 0.88 * p0);

    // pitch = f0 * P^(0.3 * droop) with P decaying exponentially, so the
    // log-pitch drop is proportional to droop: none at 0, double at 2
    const drop = @log(p2 / p0);
    var flat_knobs = clean;
    flat_knobs.droop = 0;
    const flat = try renderTestSyllable(alloc, "a", 0, .{}, flat_knobs);
    defer alloc.free(flat);
    try testing.expect(@abs(@log(pitchAt(flat, 0.20) / pitchAt(flat, 0.04))) < 0.05);

    var sag_knobs = clean;
    sag_knobs.droop = 2;
    const sag = try renderTestSyllable(alloc, "a", 0, .{}, sag_knobs);
    defer alloc.free(sag);
    const sag_drop = @log(pitchAt(sag, 0.20) / pitchAt(sag, 0.04));
    try testing.expect(sag_drop / drop > 1.5 and sag_drop / drop < 2.5);
}

test "v3: tension tunes the valve like a string, pressure pushes the level" {
    const alloc = testing.allocator;
    const clean = VoiceKnobs{ .turbulence = 0, .wetness = 0 };
    var tight_k = clean;
    tight_k.tension = 2.0;
    var loose_k = clean;
    loose_k.tension = 0.5;
    const tight = try renderTestSyllable(alloc, "a", 0, .{}, tight_k);
    defer alloc.free(tight);
    const loose = try renderTestSyllable(alloc, "a", 0, .{}, loose_k);
    defer alloc.free(loose);
    // sqrt(2 / 0.5) = 2x the pitch
    try testing.expect(pitchAt(tight, 0.05) > 1.6 * pitchAt(loose, 0.05));

    const stock = try renderTestSyllable(alloc, "ba", 1, .{}, .{});
    defer alloc.free(stock);
    const hard = try renderTestSyllable(alloc, "ba", 1, .{}, .{ .pressure = 2.5 });
    defer alloc.free(hard);
    const weak = try renderTestSyllable(alloc, "ba", 1, .{}, .{ .pressure = 0.4 });
    defer alloc.free(weak);
    try testing.expect(rmsOf(hard) > 1.2 * rmsOf(stock));
    try testing.expect(rmsOf(weak) < 0.75 * rmsOf(stock));
}

test "v3: the phrase's last syllable runs out of gas" {
    const alloc = testing.allocator;
    const mid = try renderTestSyllable(alloc, "na", 1, .{}, .{});
    defer alloc.free(mid);
    const last = try renderTestSyllable(alloc, "na", 1, .{ .word_final = true, .phrase_final = true, .position = 1 }, .{});
    defer alloc.free(last);
    const q = SYLLABLE_SAMPLES / 4;
    try testing.expect(rmsOf(last[3 * q ..]) < 0.8 * rmsOf(mid[3 * q ..]));
    // and it fades from a strong start, not from the outset
    try testing.expect(rmsOf(last[3 * q ..]) < 0.6 * rmsOf(last[0..q]));
}

test "v3: a plosive bursts, a nasal hums in" {
    const alloc = testing.allocator;
    const pa = try renderTestSyllable(alloc, "pa", 1, .{}, .{});
    defer alloc.free(pa);
    const ma = try renderTestSyllable(alloc, "ma", 1, .{}, .{});
    defer alloc.free(ma);
    const head: usize = SAMPLE_RATE * 30 / 1000;
    try testing.expect(rmsOf(pa[0..head]) > 1.3 * rmsOf(ma[0..head]));
}

test "v3: turbulence roughens, tract=0 strips the colour" {
    const alloc = testing.allocator;
    const smooth = try renderTestSyllable(alloc, "ka", 1, .{}, .{ .turbulence = 0 });
    defer alloc.free(smooth);
    const rough = try renderTestSyllable(alloc, "ka", 1, .{}, .{ .turbulence = 4 });
    defer alloc.free(rough);
    try testing.expect(zeroCrossings(rough) > zeroCrossings(smooth));

    // different vowels sound different through the tract, the same without it
    const a = try renderTestSyllable(alloc, "ba", 1, .{}, .{ .tract = 2 });
    defer alloc.free(a);
    const i = try renderTestSyllable(alloc, "bi", 1, .{}, .{ .tract = 2 });
    defer alloc.free(i);
    try testing.expect(!std.mem.eql(i16, a, i));
}

test "v3: the shuzi is deterministic per seed and varies across seeds" {
    const alloc = testing.allocator;
    const a = try renderShuziWav(alloc, 42);
    defer alloc.free(a);
    const b = try renderShuziWav(alloc, 42);
    defer alloc.free(b);
    try testing.expectEqualSlices(u8, a, b);
    const c = try renderShuziWav(alloc, 43);
    defer alloc.free(c);
    try testing.expect(!std.mem.eql(u8, a, c));
    try expectNotSilence(a);
}

test "v3: articulation reads Swahili onsets" {
    try testing.expectEqual(Manner.vowel, articulate("").manner);
    try testing.expectEqual(Manner.stop, articulate("k").manner);
    try testing.expectEqual(Manner.affricate, articulate("ch").manner);
    try testing.expectEqual(Manner.fricative, articulate("sh").manner);
    try testing.expectEqual(Place.palatal, articulate("sh").place);
    try testing.expectEqual(Manner.fricative, articulate("th").manner);
    try testing.expectEqual(Manner.fricative, articulate("gh").manner);
    try testing.expectEqual(Manner.nasal, articulate("ny").manner);
    try testing.expectEqual(Manner.nasal, articulate("ng'").manner);
    try testing.expectEqual(Manner.trill, articulate("r").manner);
    try testing.expectEqual(Manner.glide, articulate("w").manner);

    const mb = articulate("mb");
    try testing.expect(mb.prenasal);
    try testing.expectEqual(Manner.stop, mb.manner);
    try testing.expectEqual(Place.labial, mb.place);
    const kw = articulate("kw");
    try testing.expectEqual(Manner.stop, kw.manner);
    try testing.expectEqual(@as(u8, 'w'), kw.glide);
    const mbw = articulate("mbw");
    try testing.expect(mbw.prenasal);
    try testing.expectEqual(@as(u8, 'w'), mbw.glide);
    // voiced stops are wetter and looser than voiceless ones
    try testing.expect(articulate("b").wet > articulate("p").wet);
    try testing.expect(articulate("b").tension < articulate("p").tension);
}
