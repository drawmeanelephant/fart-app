//! synth.zig — Flatlophone v2: physical fart synthesis + Swahili syllable engine.
//!
//! Pure Zig stdlib. Emits PCM WAV (RIFF), 44100 Hz, mono, 16-bit. No libc, no
//! file I/O: every render is a pure function of its input. The noise generator
//! is seeded from a hash of the input text with fixed constants everywhere
//! else, so the same phrase always produces byte-identical WAV bytes. Always.
//! The physical model even evaluates its own exp/sin/tan from plain IEEE
//! arithmetic (`detExp`, `detSin`, `detTan`), so those bytes do not change
//! between Debug and Release builds or between platforms either.
//!
//! One fart "phoneme" (one Swahili syllable) is a small physical model:
//!   * INTESTINAL PRESSURE drains exponentially over the syllable. Pitch and
//!     loudness both follow it, so the pitch falls on an exponential curve
//!     (fast, then settling) the way a real fart's does.
//!   * Two SPHINCTER lips (detuned flow-pulse oscillators) flap at that pitch.
//!     Every cycle draws its own period and strength: jitter, shimmer and,
//!     as the pressure runs out, period-doubling and dropped cycles — the
//!     "putt-putt" sputter of a tail. TENSION sets the pitch, how sharp each
//!     pulse is and how much air leaks past.
//!   * TURBULENCE: noise gated by each flow pulse, plus a steady leak.
//!   * The flow rings the TERMINAL TRACT: three formant filters chosen by the
//!     syllable's vowel (RESONANCE mixes them in), plus a low "boom" cavity.
//!   * WET bubbles chirp and pop at random.
//!   * The consonant sets the onset: plosives (p t k b d g j ch) are sudden
//!     pressure bursts (noise crack, pitch spike, a "bwomp" thump when
//!     voiced), fricatives are sustained hiss, nasals a muffled closure,
//!     w/y glide the formants in, r rolls, l bubbles. See `onsetShape`.
//!   * A rational soft limiter rounds the peaks into a fat saturated top.
//! `VoiceKnobs` documents every physical axis and what it does to the sound.
//! The pre-physics synth is still here, bit for bit, behind `legacy=1`.
//!
//! Swahili is nearly pure CV. `Scanner` splits a word into syllables: each
//! vowel picks the base pitch and the formants, the consonant onset picks the
//! burst/hiss/closure character, and the syllable count sets the total
//! duration. The full mapping tables live in README.md.
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

/// Per-run tuning of the voice. Every field is a multiplier (identity 1.0)
/// on the value the phrase itself implies, except `cents` and `seed`, which
/// are offsets, and `legacy`, which is a switch. The first three axes
/// reshape the *onset class table*: attack, noise mix and wobble depth.
/// `--voice wobble=2` doubles the wobble of every class instead of flattening
/// them all to one number.
///
/// Two more axes ride along and are applied by the renderer rather than by
/// `apply`, because neither belongs to the onset class: `intensity` (#15) is
/// vocal effort — it reaches the level, the noise mix and the stress emphasis,
/// which `apply` never sees — and `cents` (#16) transposes the vowel pitch
/// table, which is a property of the vowel, not of the consonant onset.
///
/// ## The physical model
///
/// The next nine axes drive the fart model itself: a pressurised gas pocket
/// forcing a flexible sphincter (a pair of lips) into pulsing oscillation,
/// whose flow rings a terminal cavity. The *phrase* decides each syllable's
/// physical state (a `k` is a high-pressure crack, a `b` a wet low thump, an
/// `s` a tight hissing leak, an `r` a rolled raspberry, a vowel picks the
/// cavity's formants); these knobs scale that state for the whole phrase.
/// Recipes that sound like something:
///
///   wet        `wetness=2.5,tension=0.8`
///   dry        `wetness=0,rasp=0.4,turbulence=0.5,resonance=0.7`
///   raspy      `rasp=2.5,turbulence=1.6,tension=1.2`
///   thunderous `pressure=1.6,tension=0.6,boom=2.2,decay=0.7`
///   squeaker   `tension=2,pressure=0.7,decay=1.5,boom=0.3`
///
/// The default is 1.0 on every multiplier, 0 on `cents`/`seed`/`legacy`: that
/// is the new house sound. `legacy=1` renders the pre-physics synth bit for
/// bit (the golden fingerprints in `src/golden.zig` guard both).
pub const VoiceKnobs = struct {
    /// scales `attack_s`
    attack: f32 = 1.0,
    /// scales `noise_mix` and every noise source in the physical model
    /// (onset cracks, fricative hiss, sphincter leak). 0 is a clean, tonal fart.
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

    /// INTESTINAL PRESSURE: how hard the gas is driven. More pressure is
    /// louder, starts higher in pitch, stays stable (clean, thunderous) for
    /// longer before it sputters, and hits the soft limiter harder, so it
    /// also thickens the sound. Low pressure is a timid, quickly-chaotic
    /// squeak-and-putter.
    pressure: f32 = 1.0,
    /// SPHINCTER TENSION: how tightly the lips are clenched. Tight raises the
    /// pitch, narrows each flow pulse (a sharper, buzzier, more nasal tone),
    /// leaks hiss and raises the cavity's formants: squeaky and raspy. Slack
    /// lowers the pitch and rounds the pulses into a deep, loose flap.
    tension: f32 = 1.0,
    /// TERMINAL TRACT RESONANCE: how much of the sound is shaped by the
    /// cavity at the end of the line. The vowel of the syllable selects three
    /// formant filters (a = open "aah", i = pinched "eee", u/o = hollow
    /// "ooo"); this knob is their mix against the raw dry buzz. 0 is a dry,
    /// bare buzz; 1 is a clearly vowel-coloured fart; 3 is a ringing, hollow
    /// one.
    resonance: f32 = 1.0,
    /// NOISE-BURST TURBULENCE: turbulent air noise gated by each flow pulse,
    /// plus a steady leak. Gives the sound grit and "air". Rises as the
    /// pressure runs out, so tails get hissier. 0 is a pure pulse train.
    turbulence: f32 = 1.0,
    /// WETNESS: the rate of bubbles — short exponentially-decaying chirps in
    /// the 150-1000 Hz range — and of pulse dropouts in the tail. Low is dry
    /// and crisp, high is a gurgling, spluttering, soggy fart.
    wetness: f32 = 1.0,
    /// RASP: cycle-to-cycle instability of the sphincter — period jitter,
    /// amplitude shimmer, period-doubling "putt-putt" as pressure falls, and
    /// pitch wander. 0 is a steady, synthetic buzz; high is torn and ragged.
    rasp: f32 = 1.0,
    /// EXPONENTIAL PITCH DECAY: how far and how fast the pitch (and loudness)
    /// falls as the pressure drains. 1 drops the pitch about 38% on an
    /// exponential curve (fast at first, then slowly settling); 0 holds
    /// pitch flat; 2 is a sagging trombone.
    decay: f32 = 1.0,
    /// PLOSIVE BURST: the strength of the sudden pressure release on
    /// p/t/k/b/d/g/j/ch: the noise crack, the pitch/pressure spike, and the
    /// low "bwomp" thump of the voiced ones. 0 turns every plosive into a
    /// soft onset.
    burst: f32 = 1.0,
    /// BOOM: the cavity's low resonance (~100-150 Hz, sagging as pressure
    /// falls). Adds chest-thumping weight and saturation harmonics so it
    /// reads on small speakers too. 0 is thin; 3 is a subwoofer test.
    boom: f32 = 1.0,
    /// Re-rolls the fart's random fingerprint (period jitter, bubbles,
    /// noise) without changing anything else: the same phrase with a different
    /// `seed` is a different fart. 0 (the default) is the phrase's own.
    /// An integer in 0..16777216; deterministic like everything else.
    seed: f32 = 0.0,
    /// Any value above 0 renders the original pre-physics synth, bit for bit
    /// (a buzzy oscillator, a 20% linear glide, a splat). The old golden
    /// fingerprints still guard it.
    legacy: f32 = 0.0,

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

    /// The physical axes' ranges. The floors keep the sphincter oscillator
    /// alive (pressure 0 would be silence, decay 0 an endless drone); the caps
    /// are where more of the same stops being audible as anything new.
    pub const min_pressure: f32 = 0.1;
    pub const max_pressure: f32 = 3.0;
    pub const max_tension: f32 = 3.0;
    pub const max_resonance: f32 = 3.0;
    pub const max_turbulence: f32 = 4.0;
    pub const max_wetness: f32 = 4.0;
    pub const max_rasp: f32 = 4.0;
    pub const max_decay: f32 = 3.0;
    pub const max_burst: f32 = 4.0;
    pub const max_boom: f32 = 4.0;
    /// exactly representable in f32, so `seed` round-trips through the config
    pub const max_seed: f32 = 16777216.0;

    /// `2^(cents/1200)` — the factor every base frequency is multiplied by,
    /// with `cents` clamped to one octave either way. The `cents == 0` branch
    /// is load-bearing: the untouched knobs must be a *bit-exact* identity
    /// (the golden fingerprints assert it), and `x * 1.0` is exact in IEEE-754
    /// in a way `pow` is only ever allowed to be, not guaranteed to be.
    pub fn pitchFactor(self: VoiceKnobs) f32 {
        if (self.cents == 0) return 1.0;
        const c = std.math.clamp(self.cents, -max_abs_cents, max_abs_cents);
        if (self.isLegacy()) return std.math.pow(f32, 2.0, c / 1200.0);
        return detExp(@floatCast(@as(f64, c) * LN2 / 1200.0));
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

    /// True when the pre-physics synth was asked for.
    pub fn isLegacy(self: VoiceKnobs) bool {
        return self.legacy > 0;
    }

    /// The `seed` knob as the integer the renderer mixes into its PRNG;
    /// 0 means "the phrase's own fingerprint" and must not touch the hash.
    pub fn seedSalt(self: VoiceKnobs) u64 {
        const s = std.math.clamp(self.seed, 0.0, max_seed);
        return @as(u64, @intFromFloat(@floor(s)));
    }
};

pub const KnobsError = error{ UnknownKnob, MalformedKnob, NotFinite, Negative };

/// Every spelling `--voice` and the `[voice]` config table accept, in a fixed
/// order: a knob's index is its duplicate-detection slot in the config parser.
pub const knob_names = [_][]const u8{
    "attack",    "noise",      "wobble",  "intensity", "cents", "pressure", "tension",
    "resonance", "turbulence", "wetness", "rasp",      "decay", "burst",    "boom",
    "seed",      "legacy",
};

/// The slot of `key` in `knob_names`, or null for a key that is not a knob.
pub fn knobSlot(key: []const u8) ?usize {
    for (knob_names, 0..) |name, slot| {
        if (std.mem.eql(u8, key, name)) return slot;
    }
    return null;
}

/// Sets the knob called `key` and returns its slot; null (and nothing set)
/// for an unknown key.
pub fn setKnobByName(knobs: *VoiceKnobs, key: []const u8, v: f32) ?usize {
    inline for (knob_names, 0..) |name, slot| {
        if (std.mem.eql(u8, key, name)) {
            @field(knobs, name) = v;
            return slot;
        }
    }
    return null;
}

/// Parse `attack=1.2,noise=0.8,wobble=2` into multipliers. Order is free and
/// whitespace around keys and values is ignored; an empty string is the
/// identity, which is what `--voice ""` and an omitted flag both mean.
/// `intensity` and `cents` (#15, #16) take the same spelling: `intensity` is
/// a multiplier (>= 0), `cents` an offset in cents and the one key a negative
/// value is meaningful for. The physical axes (`pressure`, `tension`,
/// `resonance`, `turbulence`, `wetness`, `rasp`, `decay`, `burst`, `boom`),
/// `seed` and `legacy` are documented on `VoiceKnobs`.
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
        _ = setKnobByName(&knobs, key, v) orelse return error.UnknownKnob;
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
// Phrase -> physics: onsets and vowels
// ---------------------------------------------------------------------

/// What an onset (the consonants before a syllable's vowel) does to the gas
/// pocket. The class table (`VoiceSpec`) only knows six broad classes; this
/// is the per-consonant detail underneath it. Every field is a plain
/// number so the whole table is auditable at a glance in `onsetShape`.
pub const OnsetShape = struct {
    /// seconds the lips stay shut before the release: a muffled, low-passed
    /// pressure build-up (the voice bar of b/d/g, the murmur of m/n and of
    /// prenasalized mb/nd/ng). 0 = no closure, the syllable just starts.
    closure_s: f32 = 0.0,
    /// loudness of the muffled build-up, 0..1 (voiceless stops are near-silent)
    closure_gain: f32 = 1.0,
    /// PLOSIVE: strength of the release crack — a decaying noise burst plus a
    /// brief pressure/pitch spike. 0 for everything that is not a stop.
    burst: f32 = 0.0,
    /// centre of the crack's noise: low for lips (p, b), mid for the velum
    /// (k, g), high for the tongue tip (t, d)
    burst_hz: f32 = 1500.0,
    burst_q: f32 = 1.0,
    /// decay time constant of the crack, seconds
    burst_s: f32 = 0.012,
    /// the voiced "bwomp": a sub-bass thump that falls in pitch on release
    thump: f32 = 0.0,
    /// FRICATIVE: level of the sustained turbulent hiss (s, sh, f, h, z, v...)
    hiss: f32 = 0.0,
    hiss_hz: f32 = 3000.0,
    /// the hiss dies away with this time constant, seconds
    hiss_s: f32 = 0.09,
    /// how much of the pulsing source is present at the start: voiceless
    /// fricatives begin as pure air (low) and the buzz fades in
    voicing: f32 = 1.0,
    voicing_s: f32 = 0.06,
    /// glides (w, y, l): the formants start on this vowel and slide to the
    /// syllable's own over `glide_s`. 0 = no glide.
    glide_from: u8 = 0,
    glide_s: f32 = 0.05,
    /// rolled r / l: depth and rate (Hz) of an extra pressure flutter
    trill: f32 = 0.0,
    trill_hz: f32 = 30.0,
    /// per-onset multipliers on the physical state (see `VoiceKnobs`)
    pressure: f32 = 1.0,
    tension: f32 = 1.0,
    wet: f32 = 1.0,
    rasp: f32 = 1.0,
    turbulence: f32 = 1.0,
};

fn stopShape(c: u8) OnsetShape {
    return switch (c) {
        // lips: a low, wide pop with a bit of thump behind it
        'p' => .{ .closure_s = 0.010, .closure_gain = 0.05, .burst = 1.0, .burst_hz = 700, .burst_q = 0.9, .burst_s = 0.014, .thump = 0.35, .tension = 0.9 },
        // tongue tip: a small hard tick
        't' => .{ .closure_s = 0.008, .closure_gain = 0.05, .burst = 0.85, .burst_hz = 3400, .burst_q = 1.4, .burst_s = 0.008, .tension = 1.25, .pressure = 0.95 },
        // velum: the big crack
        'k' => .{ .closure_s = 0.012, .closure_gain = 0.05, .burst = 1.15, .burst_hz = 1700, .burst_q = 1.0, .burst_s = 0.020, .thump = 0.15, .pressure = 1.15 },
        // affricate: a tick that leaks into hiss
        'c' => .{ .closure_s = 0.008, .closure_gain = 0.05, .burst = 0.8, .burst_hz = 2600, .burst_q = 1.2, .burst_s = 0.010, .hiss = 0.55, .hiss_hz = 3600, .hiss_s = 0.06, .voicing = 0.3, .voicing_s = 0.05 },
        // voiced lips: the wet, low bwomp
        'b' => .{ .closure_s = 0.014, .closure_gain = 0.22, .burst = 0.7, .burst_hz = 420, .burst_q = 0.8, .burst_s = 0.016, .thump = 1.0, .pressure = 1.15, .wet = 1.5 },
        'd' => .{ .closure_s = 0.010, .closure_gain = 0.20, .burst = 0.6, .burst_hz = 2300, .burst_q = 1.2, .burst_s = 0.010, .thump = 0.5 },
        'g' => .{ .closure_s = 0.014, .closure_gain = 0.20, .burst = 0.85, .burst_hz = 950, .burst_q = 0.9, .burst_s = 0.018, .thump = 0.7, .pressure = 1.1, .rasp = 1.2 },
        'j' => .{ .closure_s = 0.010, .closure_gain = 0.20, .burst = 0.6, .burst_hz = 2500, .burst_q = 1.2, .burst_s = 0.010, .thump = 0.3, .hiss = 0.4, .hiss_hz = 3000, .hiss_s = 0.05, .voicing = 0.6 },
        else => .{},
    };
}

fn isStopLetter(c: u8) bool {
    return c == 'p' or c == 't' or c == 'k' or c == 'c' or c == 'b' or c == 'd' or c == 'g' or c == 'j';
}

/// The physics of one onset, by spelling. Plosives (p t k b d g j ch) are
/// sudden pressure bursts; fricatives (s sh z f v h th dh gh) are sustained
/// turbulent hiss; nasals (m n ny ng') are a muffled closure; prenasalized
/// stops (mb nd ng nj ...) are a murmur that ends in a burst; w/y glide the
/// formants in from u/i; r rolls and l bubbles. The empty onset (a bare
/// vowel) is the neutral shape.
pub fn onsetShape(onset: []const u8) OnsetShape {
    if (onset.len == 0) return .{};
    const c0 = onset[0];
    const c1: u8 = if (onset.len > 1) onset[1] else 0;

    // ng' — the velar nasal, one consonant despite the g
    if (onset.len >= 3 and c0 == 'n' and c1 == 'g' and onset[2] == '\'') {
        return .{ .closure_s = 0.040, .closure_gain = 0.5, .tension = 0.8, .turbulence = 0.7 };
    }
    // mb nd ng nj nz nt nk mp nv mv: a nasal murmur that ends in the stop's burst
    if ((c0 == 'm' or c0 == 'n') and c1 != 0 and std.mem.indexOfScalar(u8, "bdgjzvptk", c1) != null) {
        var s = if (isStopLetter(c1)) stopShape(c1) else OnsetShape{ .hiss = 0.5, .hiss_hz = 3800, .hiss_s = 0.07, .voicing = 0.7 };
        s.closure_s = 0.034;
        s.closure_gain = 0.5;
        s.burst *= 0.7;
        s.thump *= 0.8;
        s.turbulence = 0.8;
        return s;
    }

    var s: OnsetShape = switch (c0) {
        'p', 't', 'k', 'c', 'b', 'd', 'g', 'j' => stopShape(c0),
        's' => .{ .hiss = 1.0, .hiss_hz = 5200, .hiss_s = 0.12, .voicing = 0.15, .voicing_s = 0.09, .tension = 1.35, .turbulence = 1.5 },
        'z' => .{ .hiss = 0.6, .hiss_hz = 4300, .hiss_s = 0.10, .voicing = 0.65, .voicing_s = 0.06, .tension = 1.25, .turbulence = 1.3 },
        'f' => .{ .hiss = 0.75, .hiss_hz = 2400, .hiss_s = 0.10, .voicing = 0.2, .voicing_s = 0.08, .pressure = 1.1, .turbulence = 1.3 },
        'v' => .{ .hiss = 0.5, .hiss_hz = 2000, .hiss_s = 0.09, .voicing = 0.6, .turbulence = 1.2 },
        'h' => .{ .hiss = 0.7, .hiss_hz = 1500, .hiss_s = 0.12, .voicing = 0.35, .voicing_s = 0.08, .rasp = 1.4, .turbulence = 1.3 },
        'm' => .{ .closure_s = 0.045, .closure_gain = 0.5, .pressure = 0.9, .tension = 0.85, .turbulence = 0.7, .wet = 1.2 },
        'n' => .{ .closure_s = 0.035, .closure_gain = 0.45, .pressure = 0.9, .tension = 0.95, .turbulence = 0.7 },
        'l' => .{ .glide_from = 'o', .glide_s = 0.05, .trill = 0.3, .trill_hz = 42, .pressure = 0.9, .wet = 1.6 },
        'r' => .{ .trill = 0.6, .trill_hz = 27, .rasp = 1.6, .turbulence = 1.2, .tension = 1.1 },
        'w' => .{ .glide_from = 'u', .glide_s = 0.07, .pressure = 0.95 },
        'y' => .{ .glide_from = 'i', .glide_s = 0.05 },
        else => .{ .hiss = 0.5, .hiss_hz = 2500, .hiss_s = 0.09, .voicing = 0.5 },
    };

    // digraphs: the second letter bends the first
    if (c1 == 'h') {
        switch (c0) {
            's' => { // sh
                s.hiss_hz = 3200;
                s.tension = 1.2;
                s.turbulence = 1.4;
            },
            'c' => { // ch — already the affricate
            },
            't' => s = .{ .hiss = 0.55, .hiss_hz = 4000, .hiss_s = 0.08, .voicing = 0.25 }, // th
            'd' => s = .{ .hiss = 0.4, .hiss_hz = 3600, .hiss_s = 0.08, .voicing = 0.65 }, // dh
            'g' => s = .{ .hiss = 0.6, .hiss_hz = 1100, .hiss_s = 0.10, .voicing = 0.5, .rasp = 1.6, .wet = 1.3 }, // gh: a gargle
            'k' => { // kh: a velar crack that fizzles
                s.burst *= 0.8;
                s.hiss = 0.5;
                s.hiss_hz = 1300;
                s.hiss_s = 0.08;
                s.voicing = 0.4;
            },
            'p' => { // ph
                s.burst *= 0.8;
                s.hiss = 0.6;
                s.hiss_hz = 1800;
                s.hiss_s = 0.08;
                s.voicing = 0.4;
            },
            else => {},
        }
    } else if (c1 == 'w') {
        s.glide_from = 'u';
        s.glide_s = 0.06;
    } else if (c1 == 'y') {
        s.glide_from = 'i';
        s.glide_s = 0.05;
    }
    return s;
}

/// The three formants (Hz) a vowel puts on the terminal cavity. Speech-like
/// values: a fart is a pulsing source through a resonant tube, and the
/// tube does not care whose it is. a = open "aah" (680/1150), e = "eh"
/// (480/1750), i = pinched "eee" (290/2100), o = round (440/780), u = hollow
/// "ooo" (310/700).
pub fn vowelFormants(v: u8) [3]f32 {
    return switch (v) {
        'a' => .{ 680, 1150, 2500 },
        'e' => .{ 480, 1750, 2500 },
        'i' => .{ 290, 2100, 2900 },
        'o' => .{ 440, 780, 2400 },
        'u' => .{ 310, 700, 2300 },
        else => .{ 500, 1300, 2500 },
    };
}

/// Loudness balance between the vowels: through the same formant bank "a"
/// and "u" come out several dB under "e", "i" and "o", so each is trimmed to
/// sit at the same level at the default knobs.
fn vowelGain(v: u8) f32 {
    return switch (v) {
        'a' => 1.0,
        'e' => 1.0,
        'i' => 1.0,
        'o' => 1.0,
        'u' => 1.0,
        else => 1.0,
    };
}

/// How much of the cavity's low (~140 Hz) resonance a vowel keeps: round
/// vowels thunder, the pinched "i" does not.
fn vowelBoom(v: u8) f32 {
    return switch (v) {
        'u', 'o' => 1.25,
        'a' => 1.0,
        'e' => 0.9,
        'i' => 0.7,
        else => 1.0,
    };
}

// ---------------------------------------------------------------------
// Sample rendering
// ---------------------------------------------------------------------

/// The physical state of one syllable, resolved from the knobs, the onset
/// and the stress. See `VoiceKnobs` for what each axis does to the sound.
const Phys = struct {
    pressure: f32 = 1.0,
    tension: f32 = 1.0,
    resonance: f32 = 1.0,
    turbulence: f32 = 1.0,
    wetness: f32 = 1.0,
    rasp: f32 = 1.0,
    decay: f32 = 1.0,
    burst: f32 = 1.0,
    boom: f32 = 1.0,
};

const VoiceParams = struct {
    f0: f32,
    attack_s: f32,
    noise_mix: f32,
    wobble_hz: f32,
    wobble_depth: f32,
    level: f32,
    glide: f32,
    /// render with the pre-physics synth (`synthLegacyInto`); the fields
    /// below are ignored then
    legacy: bool = false,
    vowel: u8 = 'a',
    onset: OnsetShape = .{},
    phys: Phys = .{},
    /// `noise` knob x effort, for the noise sources that are not `noise_mix`
    noise_k: f32 = 1.0,
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

fn bound(x: f32, lo: f32, hi: f32) f32 {
    return std.math.clamp(x, lo, hi);
}

/// `1 +/- amt`, from one PRNG draw.
fn jitter(r: std.Random, amt: f32) f32 {
    return 1.0 + (r.float(f32) * 2.0 - 1.0) * amt;
}

/// knobs x onset x stress x a little per-syllable chance. Always draws five
/// values from `r`, whatever the knobs say, so the stream stays aligned.
fn resolvePhys(knobs: VoiceKnobs, os: OnsetShape, stressed: bool, r: std.Random) Phys {
    const stress_p: f32 = if (stressed) 1.12 else 1.0;
    const j_press = jitter(r, 0.10);
    const j_tens = jitter(r, 0.12);
    const j_wet = jitter(r, 0.30);
    const j_rasp = jitter(r, 0.25);
    const j_turb = jitter(r, 0.15);
    return .{
        .pressure = bound(bound(knobs.pressure, VoiceKnobs.min_pressure, VoiceKnobs.max_pressure) * os.pressure * stress_p * j_press, 0.05, 4.0),
        .tension = bound(bound(knobs.tension, 0.0, VoiceKnobs.max_tension) * os.tension * j_tens, 0.0, 4.0),
        .resonance = bound(knobs.resonance, 0.0, VoiceKnobs.max_resonance),
        .turbulence = bound(bound(knobs.turbulence, 0.0, VoiceKnobs.max_turbulence) * os.turbulence * j_turb, 0.0, 6.0),
        .wetness = bound(bound(knobs.wetness, 0.0, VoiceKnobs.max_wetness) * os.wet * j_wet, 0.0, 6.0),
        .rasp = bound(bound(knobs.rasp, 0.0, VoiceKnobs.max_rasp) * os.rasp * j_rasp, 0.0, 6.0),
        .decay = bound(knobs.decay, 0.0, VoiceKnobs.max_decay),
        .burst = bound(knobs.burst, 0.0, VoiceKnobs.max_burst),
        .boom = bound(knobs.boom, 0.0, VoiceKnobs.max_boom),
    };
}

// ---- small DSP parts: pure IEEE arithmetic, no libm ----
//
// `@exp`/`@sin`/`@tan` lower to different code at different optimisation
// levels (and to a different libm per platform), and that alone moved ~0.5%
// of the output samples by one LSB between Debug and ReleaseSafe. The physical
// model therefore evaluates its transcendentals with the three functions
// below: only `+ - * /`, `@round` and a bit cast, in f64, so the WAV is
// bit-identical in every build mode and on every target.

const LN2: f64 = 0.6931471805599453;
const TWO_PI: f64 = 6.283185307179586;

/// e^x for the range the synth uses; clamped so the result is a normal f32.
fn detExp(x: f32) f32 {
    const xd: f64 = std.math.clamp(@as(f64, x), -87.0, 87.0);
    const k = @round(xd * 1.4426950408889634);
    const r = xd - k * LN2; // |r| <= 0.3466
    var s: f64 = 1.0 / 479001600.0; // 1/12!
    s = s * r + 1.0 / 39916800.0;
    s = s * r + 1.0 / 3628800.0;
    s = s * r + 1.0 / 362880.0;
    s = s * r + 1.0 / 40320.0;
    s = s * r + 1.0 / 5040.0;
    s = s * r + 1.0 / 720.0;
    s = s * r + 1.0 / 120.0;
    s = s * r + 1.0 / 24.0;
    s = s * r + 1.0 / 6.0;
    s = s * r + 0.5;
    s = s * r + 1.0;
    s = s * r + 1.0;
    const bits: u64 = @intCast(@as(i64, @intFromFloat(k)) + 1023);
    return @floatCast(s * @as(f64, @bitCast(bits << 52)));
}

fn detSin64(x: f64) f64 {
    var r = x - @round(x * (1.0 / TWO_PI)) * TWO_PI; // [-pi, pi]
    if (r > 0.5 * std.math.pi) r = std.math.pi - r;
    if (r < -0.5 * std.math.pi) r = -std.math.pi - r;
    const r2 = r * r;
    // sin r = r * (1 - r^2/3! + r^4/5! - ... + r^16/17!), |r| <= pi/2
    var s: f64 = 1.0 / 355687428096000.0; // 1/17!
    s = s * r2 - 1.0 / 1307674368000.0; // 1/15!
    s = s * r2 + 1.0 / 6227020800.0; // 1/13!
    s = s * r2 - 1.0 / 39916800.0; // 1/11!
    s = s * r2 + 1.0 / 362880.0; // 1/9!
    s = s * r2 - 1.0 / 5040.0;
    s = s * r2 + 1.0 / 120.0;
    s = s * r2 - 1.0 / 6.0;
    s = s * r2 + 1.0;
    return r * s;
}

fn detSin(x: f32) f32 {
    return @floatCast(detSin64(@as(f64, x)));
}

/// tan(x) for 0 < x < pi/2, as sin/cos.
fn detTan(x: f32) f32 {
    const xd: f64 = x;
    return @floatCast(detSin64(xd) / detSin64(xd + 0.5 * std.math.pi));
}

const CONTROL_PERIOD: usize = 16; // samples between filter-coefficient updates

fn smooth01(x: f32) f32 {
    const c = std.math.clamp(x, 0.0, 1.0);
    return c * c * (3.0 - 2.0 * c);
}

/// Odd-symmetric soft limiter, linear near 0 and exactly 1 at |x| = 3
/// (a rational tanh): loud peaks round off into a fat, saturated top instead
/// of a hard clip, and quiet material passes untouched.
fn softClip(x: f32) f32 {
    const c = std.math.clamp(x, -3.0, 3.0);
    return c * (27.0 + c * c) / (27.0 + 9.0 * c * c);
}

const SvfCoef = struct { a1: f32, a2: f32, a3: f32, k: f32 };

/// Coefficients for a zero-delay-feedback state-variable filter. Stable at
/// any frequency and Q, which a Chamberlin SVF is not at 100 Hz / 44.1 kHz.
fn svfCoef(fc: f32, q: f32) SvfCoef {
    const f = std.math.clamp(fc, 20.0, 0.45 * @as(f32, SAMPLE_RATE));
    const g = detTan(std.math.pi * f / @as(f32, SAMPLE_RATE));
    const k = 1.0 / q;
    const a1 = 1.0 / (1.0 + g * (g + k));
    return .{ .a1 = a1, .a2 = g * a1, .a3 = g * g * a1, .k = k };
}

const Svf = struct {
    ic1: f32 = 0.0,
    ic2: f32 = 0.0,

    const Out = struct { lp: f32, bp: f32 };

    /// `bp` is the raw band output; multiply by `c.k` for unity peak gain.
    fn run(self: *Svf, c: SvfCoef, x: f32) Out {
        const v3 = x - self.ic2;
        const v1 = c.a1 * self.ic1 + c.a2 * v3;
        const v2 = self.ic2 + c.a2 * self.ic1 + c.a3 * v3;
        self.ic1 = 2.0 * v1 - self.ic1;
        self.ic2 = 2.0 * v2 - self.ic2;
        return .{ .lp = v2, .bp = v1 };
    }
};

/// One flow pulse of the sphincter, `phase` in 0..1: a smooth opening, then
/// a closing that is as sharp as `sharp` says (0 = soft, 1 = a hard snap).
/// The sharp end is what makes it buzz rather than hum.
fn lipPulse(phase: f32, oq: f32, sharp: f32) f32 {
    if (phase >= oq) return 0.0;
    const x = phase / oq;
    const peak: f32 = 0.30;
    if (x < peak) {
        const a = x / peak;
        return a * a * (3.0 - 2.0 * a);
    }
    const d = 1.0 - (x - peak) / (1.0 - peak);
    return d * (sharp + (1.0 - sharp) * d);
}

/// Roughly Gaussian, sigma 0.5, from three draws.
fn gauss(r: std.Random) f32 {
    return r.float(f32) + r.float(f32) + r.float(f32) - 1.5;
}

/// One lip of the sphincter: a phase oscillator whose every cycle draws its
/// own period and strength. The cycle-to-cycle chance is where raspiness
/// lives: a perfect oscillator is a synth, a fart is a *nearly* periodic mess.
const Flapper = struct {
    phase: f32,
    detune: f32,
    period_mult: f32 = 1.0,
    amp: f32 = 1.0,
    cycle: u32 = 0,

    const Ctl = struct {
        /// period jitter, fraction of a period
        jitter: f32,
        /// amplitude shimmer, fraction
        shimmer: f32,
        /// every second cycle is this much weaker (period doubling)
        sub: f32,
        /// chance a whole cycle fails to fire
        drop_prob: f32,
    };

    fn tick(self: *Flapper, f_hz: f32, oq: f32, sharp: f32, ctl: Ctl, r: std.Random) f32 {
        self.phase += f_hz * self.detune * self.period_mult * (1.0 / @as(f32, SAMPLE_RATE));
        if (self.phase >= 1.0) {
            self.phase -= 1.0;
            self.newCycle(ctl, r);
        }
        return self.amp * lipPulse(self.phase, oq, sharp);
    }

    fn newCycle(self: *Flapper, ctl: Ctl, r: std.Random) void {
        self.cycle +%= 1;
        self.period_mult = std.math.clamp(1.0 + ctl.jitter * gauss(r) * 2.0, 0.55, 1.6);
        var a = 1.0 + ctl.shimmer * (r.float(f32) * 2.0 - 1.0);
        if (self.cycle & 1 == 1) a *= 1.0 - ctl.sub;
        const misfire = r.float(f32);
        const misfire_amp = r.float(f32);
        if (misfire < ctl.drop_prob) a *= 0.12 * misfire_amp;
        self.amp = @max(a, 0.0);
    }
};

/// A gas bubble: a short, exponentially decaying sine that chirps upward as
/// it pops. The wet in "wet fart".
const Bubble = struct {
    phase: f32 = 0.0,
    freq: f32 = 0.0,
    target: f32 = 0.0,
    amp: f32 = 0.0,
    decay: f32 = 1.0,
};

const BUBBLE_VOICES = 6;

// Output gain staging of the physical model, tuned by ear-proxy (RMS and
// spectra of the rendered phrases) so the default lands near -12 dBFS.
const PITCH_START: f32 = 1.35; // start pitch over the vowel table's mean pitch
const FORMANT_Q = [3]f32{ 2.4, 3.2, 4.2 };
const FORMANT_GAIN = [3]f32{ 0.8, 0.9, 0.8 };
const FORMANT_EMPHASIS: f32 = 6.0; // first-difference boost into the bank: tilts it toward F2/F3
const FORMANT_MIX: f32 = 1.5;
const SOURCE_GAIN: f32 = 0.8;
const BOOM_GAIN: f32 = 0.45;
const BURST_GAIN: f32 = 1.6;
const HISS_GAIN: f32 = 0.9;
const THUMP_GAIN: f32 = 0.55;
const OUTPUT_GAIN: f32 = 1.2; // before the soft limiter; sets the default loudness

/// The fart: a pair of sphincter lips (flappers) driven by a draining
/// pressure, their flow differentiated and pushed through three vowel
/// formants plus a low cavity resonance, with turbulence, bubbles and the
/// onset's burst/hiss/thump layered in. Deterministic: the only randomness is
/// `prng`, whose seed is fixed per render.
fn synthFart(out: []i16, p: VoiceParams, prng: *std.Random.DefaultPrng) void {
    const r = prng.random();
    const fs: f32 = @floatFromInt(SAMPLE_RATE);
    const dt: f32 = 1.0 / fs;
    const tau: f32 = std.math.tau;
    const n = out.len;
    const nf: f32 = @floatFromInt(n);
    const ph = p.phys;
    const os = p.onset;

    const wobble_phase = r.float(f32) * tau;
    const wobble_hz = p.wobble_hz * (0.9 + 0.2 * r.float(f32));
    const trill_phase = r.float(f32) * tau;

    // --- constants of this syllable
    const tension = ph.tension;
    const k_p: f32 = 1.7 * ph.decay; // pressure e-folds over the syllable
    const k_a: f32 = 0.75 * ph.decay; // and so does the loudness
    const drop = std.math.clamp(0.38 * ph.decay, 0.0, 0.8); // total pitch fall
    const shape_k: f32 = 3.2; // fast-then-slow exponential fall of the pitch
    const inv_shape = 1.0 / (1.0 - detExp(-shape_k));
    const pitch_k = std.math.clamp(1.0 + 0.30 * (tension - 1.0), 0.45, 2.2) *
        std.math.clamp(1.0 + 0.18 * (ph.pressure - 1.0), 0.6, 1.8);
    const f_base = p.f0 * PITCH_START * pitch_k;
    const oq = std.math.clamp(0.42 - 0.16 * (tension - 1.0), 0.14, 0.85);
    const sharp = std.math.clamp(0.75 + 0.25 * (tension - 1.0), 0.10, 0.98);
    const form_k = std.math.clamp(1.0 + 0.10 * (tension - 1.0), 0.8, 1.35);
    const leak_amt = 0.045 * tension * tension * ph.turbulence * p.noise_k;
    const turb_amt = p.noise_mix * ph.turbulence * 2.2;
    const rm = std.math.clamp(0.55 * ph.resonance, 0.0, 1.3);
    const dry_w = 1.0 - 0.45 * @min(rm, 1.0);
    const boom_amt = ph.boom * BOOM_GAIN * vowelBoom(p.vowel);
    const vf = vowelFormants(p.vowel);
    const vg = if (os.glide_from != 0) vowelFormants(os.glide_from) else vf;
    const has_closure = os.closure_s > 0.0;
    const cg: f32 = if (has_closure) os.closure_gain else 0.0;
    const rel_i: usize = @min(@as(usize, @intFromFloat(@round(os.closure_s * fs))), n);

    const d_burst = detExp(-dt / os.burst_s);
    const d_thump = detExp(-dt / 0.045);
    const d_spike = detExp(-dt / 0.020);
    const d_hiss = detExp(-dt / os.hiss_s);
    const burst_c = svfCoef(os.burst_hz, os.burst_q);
    const hiss_c = svfCoef(os.hiss_hz, 0.9);
    const leak_c = svfCoef(2700.0, 0.8);

    // --- state
    var fa = Flapper{ .phase = r.float(f32), .detune = 1.0 };
    var fb = Flapper{ .phase = r.float(f32), .detune = 1.0 + 0.017 + 0.012 * tension };
    var form = [3]Svf{ .{}, .{}, .{} };
    var form_c: [3]SvfCoef = undefined;
    var boom_f = Svf{};
    var boom_c: SvfCoef = svfCoef(140.0, 2.2);
    var burst_f = Svf{};
    var hiss_f = Svf{};
    var leak_f = Svf{};
    var mouth = Svf{};
    var mouth_c: SvfCoef = svfCoef(220.0, 0.9);
    var bubbles: [BUBBLE_VOICES]Bubble = @splat(.{});
    var lp_turb: f32 = 0.0;
    var turb_a: f32 = 0.1;
    var wander: f32 = 0.0;
    var surge: f32 = 0.0;
    var wander_gain: f32 = 0.0;
    var dc_x: f32 = 0.0;
    var dc_y: f32 = 0.0;
    var g_prev: f32 = 0.0;
    var fin_prev: f32 = 0.0;
    var th_phase: f32 = 0.0;
    var e_burst: f32 = 0.0;
    var e_thump: f32 = 0.0;
    var e_spike: f32 = 0.0;
    var e_hiss: f32 = 0.0;
    var f_now: f32 = f_base;
    var pn: f32 = ph.pressure;
    var depl: f32 = 0.0;
    var ctl = Flapper.Ctl{ .jitter = 0.0, .shimmer = 0.0, .sub = 0.0, .drop_prob = 0.0 };
    var wet_rate: f32 = 0.0;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const t = fi * dt;
        const u = fi / nf;
        if (i == rel_i) {
            e_burst = 1.0;
            e_thump = 1.0;
            e_spike = 1.0;
            e_hiss = 1.0;
        } else if (i > rel_i) {
            e_burst *= d_burst;
            e_thump *= d_thump;
            e_spike *= d_spike;
            e_hiss *= d_hiss;
        }
        const tr = t - os.closure_s;
        const released = i >= rel_i;
        const spike = os.burst * ph.burst * e_spike;

        if (i % CONTROL_PERIOD == 0) {
            const shp = (1.0 - detExp(-shape_k * u)) * inv_shape;
            pn = ph.pressure * detExp(-k_p * u) + 0.5 * spike;
            depl = std.math.clamp(1.0 - pn, 0.0, 1.0);
            f_now = f_base * (1.0 - drop * shp) * (1.0 + 0.28 * spike);
            ctl = .{
                .jitter = ph.rasp * 0.035 * (1.0 + 2.0 * depl),
                .shimmer = ph.rasp * 0.18 * (1.0 + depl),
                .sub = std.math.clamp(0.6 * ph.rasp * depl * depl, 0.0, 0.85),
                .drop_prob = (0.16 * ph.wetness + 0.10 * ph.rasp) * depl * depl,
            };
            wander_gain = 1.6 * ph.rasp * (1.0 + depl);
            wet_rate = 15.0 * ph.wetness * (0.5 + depl);
            const gl: f32 = if (os.glide_from != 0) smooth01(tr / os.glide_s) else 1.0;
            const sag = 1.0 - 0.10 * shp + 0.10 * spike;
            for (0..3) |k| {
                const ff = (vg[k] + (vf[k] - vg[k]) * gl) * sag * form_k;
                form_c[k] = svfCoef(ff, FORMANT_Q[k]);
            }
            boom_c = svfCoef(140.0 * (1.0 - 0.30 * shp) * form_k, 2.2);
            const cut = (500.0 + 1800.0 * std.math.clamp(pn, 0.0, 1.5)) * form_k;
            turb_a = 1.0 - detExp(-tau * cut * dt);
            if (has_closure and tr < 0.06) {
                mouth_c = svfCoef(220.0 * detExp(4.2 * smooth01(tr / 0.030)), 0.9);
            }
        }

        // ---- the sphincter
        const wob_s = detSin(tau * wobble_hz * t + wobble_phase);
        const w_n = r.float(f32) * 2.0 - 1.0;
        wander += 0.0015 * (w_n - wander);
        // slow random swells of pressure (~4 Hz): no two syllables share a contour
        const w_s = r.float(f32) * 2.0 - 1.0;
        surge += 0.0004 * (w_s - surge);
        const surge_mod = std.math.clamp(surge * 22.0 * @min(ph.rasp, 2.5), -0.45, 0.45);
        const f_inst = std.math.clamp(
            f_now * (1.0 + 0.025 * p.wobble_depth * wob_s) * (1.0 + wander_gain * wander) * (1.0 + 0.35 * surge_mod),
            20.0,
            450.0,
        );
        const ga = fa.tick(f_inst, oq, sharp, ctl, r);
        const gb = fb.tick(f_inst, oq, sharp, ctl, r);
        const g = ga + 0.55 * gb;
        dc_y = g - dc_x + 0.997 * dc_y;
        dc_x = g;
        const dgn = (g - g_prev) * (fs / f_inst) * 0.2;
        g_prev = g;

        const voicing = os.voicing + (1.0 - os.voicing) * smooth01(tr / os.voicing_s);
        const src = dc_y * voicing;
        const srcd = dgn * voicing;

        // ---- turbulence: noise gated by the pulses, plus the steady leak
        const wn_t = r.float(f32) * 2.0 - 1.0;
        lp_turb += turb_a * (wn_t - lp_turb);
        const gate = std.math.clamp(g, 0.0, 1.2);
        const turb = lp_turb * (0.25 + 0.9 * gate) * turb_amt * (0.7 + 0.9 * depl);
        const wn_l = r.float(f32) * 2.0 - 1.0;
        const leak = leak_f.run(leak_c, wn_l).bp * leak_c.k * leak_amt;

        // ---- the tract
        const fin_raw = srcd + (turb + leak) * 0.6;
        const fin = fin_raw + FORMANT_EMPHASIS * (fin_raw - fin_prev);
        fin_prev = fin_raw;
        var yb: f32 = 0.0;
        for (0..3) |k| {
            const o = form[k].run(form_c[k], fin);
            yb += FORMANT_GAIN[k] * form_c[k].k * o.bp;
        }
        const bo = boom_f.run(boom_c, src).bp * boom_c.k;

        // ---- bubbles
        var bub: f32 = 0.0;
        const spawn = r.float(f32);
        if (spawn < wet_rate * dt) {
            for (&bubbles) |*b| {
                if (b.amp < 1.0e-4) {
                    const q0 = r.float(f32);
                    const q1 = r.float(f32);
                    const q2 = r.float(f32);
                    b.freq = 160.0 + 700.0 * q0 * q0;
                    b.target = b.freq * (1.25 + 0.5 * q1);
                    b.amp = (0.08 + 0.28 * q2) * std.math.clamp(pn, 0.2, 1.5);
                    b.decay = detExp(-dt / (0.004 + 0.012 * q1));
                    b.phase = 0.0;
                    break;
                }
            }
        }
        for (&bubbles) |*b| {
            if (b.amp < 1.0e-4) {
                b.amp = 0.0;
                continue;
            }
            b.phase += tau * b.freq * dt;
            if (b.phase > tau) b.phase -= tau;
            b.freq += (b.target - b.freq) * 0.004;
            b.amp *= b.decay;
            bub += b.amp * detSin(b.phase);
        }

        // ---- the voiced body
        var y = src * SOURCE_GAIN * dry_w + yb * rm * FORMANT_MIX + bo * boom_amt + turb + leak + bub;
        if (has_closure and tr < 0.06) y = mouth.run(mouth_c, y).lp;

        const gate_on: f32 = if (!released)
            cg * smooth01(t / 0.004)
        else
            cg + (1.0 - cg) * smooth01(tr / p.attack_s);
        const trl = 1.0 - os.trill * (0.5 + 0.5 * detSin(tau * os.trill_hz * t + trill_phase));
        const wob = 1.0 - 0.7 * p.wobble_depth * (0.5 + 0.5 * wob_s);
        const amp_env = detExp(-k_a * u);
        y *= gate_on * amp_env * wob * trl * ph.pressure * (1.0 + surge_mod);

        // ---- the onset: burst crack, thump, hiss
        const wn_b = r.float(f32) * 2.0 - 1.0;
        const wn_h = r.float(f32) * 2.0 - 1.0;
        var trans: f32 = 0.0;
        if (released) {
            const bn = burst_f.run(burst_c, wn_b).bp * burst_c.k;
            trans += bn * os.burst * ph.burst * p.noise_k * e_burst * BURST_GAIN;
            th_phase += tau * (40.0 + 80.0 * e_thump) * dt;
            if (th_phase > tau) th_phase -= tau;
            trans += softClip(1.8 * detSin(th_phase)) * os.thump * ph.burst * e_thump * THUMP_GAIN;
            const hn = hiss_f.run(hiss_c, wn_h).bp * hiss_c.k;
            trans += hn * os.hiss * p.noise_k * e_hiss * HISS_GAIN * smooth01(tr / 0.003);
        }

        const taper = smooth01((1.0 - u) / 0.10);
        const x = 0.95 * softClip((y + trans) * p.level * taper * OUTPUT_GAIN * vowelGain(p.vowel) / 0.95);
        out[i] = @intFromFloat(@round(x * 32767.0));
    }
}

/// The original synth, preserved bit for bit behind `legacy=1`: a buzzy
/// oscillator gliding down 20% (linearly), a splat of filtered noise at the
/// attack, a flutter on the envelope. The golden fingerprints guard it.
fn synthLegacyInto(out: []i16, p: VoiceParams, prng: *std.Random.DefaultPrng) void {
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

/// Renders one fart phoneme into `out` (mono i16). Deterministic: the only
/// randomness comes from `prng`, whose seed is fixed per render.
fn synthInto(out: []i16, p: VoiceParams, prng: *std.Random.DefaultPrng) void {
    if (p.legacy) return synthLegacyInto(out, p, prng);
    synthFart(out, p, prng);
}

fn renderSyllableInto(out: []i16, syl: *const Syll, stressed: bool, prng: *std.Random.DefaultPrng, knobs: VoiceKnobs) void {
    const eff = knobs.effort();
    const pitch = knobs.pitchFactor();
    const legacy = knobs.isLegacy();
    const noise_k = std.math.clamp(knobs.noise * eff, 0.0, 4.0);
    var p: VoiceParams = undefined;
    if (syl.vowel == 0) {
        // Consonant-only tail: a short whisper, not a buzz. The knobs reach this
        // literal too, so `--voice noise=0` means "no noise anywhere" rather
        // than "no noise except on the rare breath syllable".
        const spec = knobs.apply(.{ .attack_s = 0.006, .noise_mix = 0.85, .wobble_hz = 31.0, .wobble_depth = 0.30, .level = 0.65 });
        // a breath is the onset's sound with little pressure behind it: airy,
        // ragged and unvoiced
        var os = onsetShape(syl.onset());
        os.pressure *= 0.6;
        os.turbulence *= 1.8;
        os.rasp *= 1.5;
        p = .{
            .f0 = 88.0 * pitch,
            .attack_s = spec.attack_s,
            .noise_mix = spec.noise_mix,
            .wobble_hz = spec.wobble_hz,
            .wobble_depth = spec.wobble_depth,
            .level = spec.level,
            .glide = 0.15,
            .legacy = legacy,
            .vowel = 'u',
            .onset = os,
            .noise_k = noise_k,
        };
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
            .legacy = legacy,
            .vowel = syl.vowel,
            .onset = onsetShape(syl.onset()),
            .noise_k = noise_k,
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
    if (!legacy) p.phys = resolvePhys(knobs, p.onset, stressed and syl.vowel != 0, r);
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
    // `seed` re-rolls the fart: 0 leaves the hash (and every golden byte) alone
    const salt = knobs.seedSalt();
    const hash_seed: u64 = if (salt != 0) 0x5EED_F00D ^ (salt *% 0x9E37_79B9_7F4A_7C15) else 0x5EED_F00D;
    var prng = std.Random.DefaultPrng.init(std.hash.Wyhash.hash(hash_seed, phrase));
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
///
/// A shuzi is also where the physical model gets to be random: each one draws
/// an archetype (thunder, squeak, wet, raspy or dry), a vowel and a body
/// plan per syllable from a PRNG stream of its own, so the timeline draws
/// (and with them every duration and gap) are unchanged from the pre-physics
/// synth, and the same seed is still the same fart.
pub fn renderShuziWavWith(allocator: std.mem.Allocator, seed: u64, knobs: VoiceKnobs) ![]u8 {
    const salt = knobs.seedSalt();
    const seed_eff = if (salt != 0) seed ^ (salt *% 0x9E37_79B9_7F4A_7C15) else seed;
    var prng = std.Random.DefaultPrng.init(seed_eff);
    var char_prng = std.Random.DefaultPrng.init(seed_eff ^ 0xC4A2_AC7E_5EED_0001);
    const cr = char_prng.random();
    const r = prng.random();
    const n_syl: usize = 1 + r.uintLessThan(usize, 3);
    const Seg = struct { params: VoiceParams, len: usize, gap_after: usize };
    var segs: [3]Seg = undefined;
    var total: usize = 0;
    const eff = knobs.effort();
    const legacy = knobs.isLegacy();
    const arch = archetypes[cr.uintLessThan(usize, archetypes.len)];
    const reps = [_][]const u8{ "b", "k", "s", "m", "r" }; // one onset per class, same order as `classes`
    var i: usize = 0;
    while (i < n_syl) : (i += 1) {
        const dur_ms: usize = (16 + r.uintLessThan(usize, 19)) * 10; // 160..340 ms
        const classes = [_]VoiceClass{ .stop_voiced, .stop_voiceless, .fricative, .nasal, .liquid };
        const class_idx = r.uintLessThan(usize, classes.len);
        const spec = knobs.apply(voiceSpec(classes[class_idx]));
        const gap_ms: usize = if (i + 1 < n_syl) (3 + r.uintLessThan(usize, 5)) * 10 else 0; // 30..70 ms
        const vowel = "aeiou"[cr.uintLessThan(usize, 5)];
        const os = onsetShape(reps[class_idx]);
        var phys = resolvePhys(knobs, os, false, cr);
        phys.pressure = bound(phys.pressure * arch.pressure, 0.05, 4.0);
        phys.tension = bound(phys.tension * arch.tension, 0.0, 4.0);
        phys.turbulence = bound(phys.turbulence * arch.turbulence, 0.0, 6.0);
        phys.wetness = bound(phys.wetness * arch.wetness, 0.0, 6.0);
        phys.rasp = bound(phys.rasp * arch.rasp, 0.0, 6.0);
        phys.decay = bound(phys.decay * arch.decay, 0.0, VoiceKnobs.max_decay);
        phys.boom = bound(phys.boom * arch.boom, 0.0, VoiceKnobs.max_boom);
        phys.resonance = bound(phys.resonance * arch.resonance, 0.0, VoiceKnobs.max_resonance);
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
                .legacy = legacy,
                .vowel = vowel,
                .onset = os,
                .phys = phys,
                .noise_k = std.math.clamp(knobs.noise * eff, 0.0, 4.0),
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

/// A shuzi's body plan: multipliers on the resolved physical state, drawn
/// once per fart. Together they span the textures the brief names.
const Archetype = struct {
    pressure: f32 = 1.0,
    tension: f32 = 1.0,
    turbulence: f32 = 1.0,
    wetness: f32 = 1.0,
    rasp: f32 = 1.0,
    decay: f32 = 1.0,
    boom: f32 = 1.0,
    resonance: f32 = 1.0,
};

const archetypes = [_]Archetype{
    // thunderous: high pressure, slack sphincter, chest-rattling low end
    .{ .pressure = 1.5, .tension = 0.6, .turbulence = 0.8, .wetness = 0.8, .rasp = 0.9, .decay = 0.8, .boom = 1.8, .resonance = 1.1 },
    // squeaker: low pressure, tight sphincter, hissy and falling fast
    .{ .pressure = 0.8, .tension = 1.8, .turbulence = 1.5, .rasp = 1.2, .decay = 1.3, .boom = 0.4, .resonance = 0.8 },
    // wet: bubbling and spluttering
    .{ .wetness = 2.4, .rasp = 1.3 },
    // raspy: torn and gritty
    .{ .tension = 1.2, .turbulence = 1.4, .rasp = 2.2 },
    // dry: crisp, clean, hardly a bubble
    .{ .turbulence = 0.6, .wetness = 0.0, .rasp = 0.5, .boom = 1.2, .resonance = 0.7 },
};

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
// the physical model: pressure, tension, resonance, turbulence, wetness,
// rasp, decay, burst, boom — and the phrase -> physics mapping
// --------------------------------------------------------------------------

/// Knobs that leave only the bare sphincter buzz: no cavity, no air, no
/// bubbles, no chance. What is left is a pulse train whose pitch the
/// pressure and tension knobs set, so the tests can count its cycles.
const dry_buzz = VoiceKnobs{ .resonance = 0, .boom = 0, .turbulence = 0, .wetness = 0, .rasp = 0, .noise = 0 };

fn zeroCrossings(samples: []const i16) usize {
    var n: usize = 0;
    for (samples[1..], 0..) |s, k| {
        if ((s >= 0) != (samples[k] >= 0)) n += 1;
    }
    return n;
}

/// Energy of `samples` at `hz`, by the Goertzel recurrence.
fn goertzel(samples: []const i16, hz: f64) f64 {
    const w = 2.0 * std.math.pi * hz / @as(f64, SAMPLE_RATE);
    const coeff = 2.0 * @cos(w);
    var s1: f64 = 0;
    var s2: f64 = 0;
    for (samples) |v| {
        const s0 = @as(f64, @floatFromInt(v)) + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    return (s1 * s1 + s2 * s2 - coeff * s1 * s2) / @as(f64, @floatFromInt(samples.len));
}

/// Summed Goertzel energy over `lo..hi` in `step` Hz bins.
fn bandEnergy(samples: []const i16, lo: f64, hi: f64, step: f64) f64 {
    var acc: f64 = 0;
    var hz = lo;
    while (hz <= hi) : (hz += step) acc += goertzel(samples, hz);
    return acc;
}

fn peakOf(samples: []const i16) i32 {
    var p: i32 = 0;
    for (samples) |s| p = @max(p, @as(i32, @intCast(@abs(@as(i32, s)))));
    return p;
}

/// Fundamental of a pulse train in `samples`, by autocorrelation over the
/// 40-300 Hz lag range. Zero crossings are a poor pitch meter for a two-lip
/// buzz (the beating adds crossings); this is the honest one.
fn pitchHz(alloc: std.mem.Allocator, samples: []const i16) !f64 {
    const x = try alloc.alloc(f64, samples.len);
    defer alloc.free(x);
    var mean: f64 = 0;
    for (samples) |v| mean += @as(f64, @floatFromInt(v));
    mean /= @as(f64, @floatFromInt(samples.len));
    for (samples, x) |v, *o| o.* = @as(f64, @floatFromInt(v)) - mean;
    const min_lag: usize = SAMPLE_RATE / 300;
    const max_lag: usize = SAMPLE_RATE / 40;
    var best_lag = min_lag;
    var best: f64 = -std.math.inf(f64);
    var lag = min_lag;
    while (lag <= max_lag) : (lag += 1) {
        var acc: f64 = 0;
        for (0..x.len - lag) |k| acc += x[k] * x[k + lag];
        // normalise by overlap so a long lag is not penalised for being long
        acc /= @as(f64, @floatFromInt(x.len - lag));
        if (acc > best) {
            best = acc;
            best_lag = lag;
        }
    }
    return @as(f64, SAMPLE_RATE) / @as(f64, @floatFromInt(best_lag));
}

/// How much more energy `lo..hi` gets with the cavity open (`resonance=3`)
/// than with it shut, for one vowel through the same bare sphincter buzz.
fn cavityBoost(alloc: std.mem.Allocator, vowel: []const u8, lo: f64, hi: f64) !f64 {
    const bare = VoiceKnobs{ .turbulence = 0, .wetness = 0, .boom = 0, .rasp = 0, .noise = 0 };
    var open = bare;
    open.resonance = 3.0;
    var shut = bare;
    shut.resonance = 0.0;
    const a = try renderPhraseSamplesWith(alloc, vowel, open);
    defer alloc.free(a);
    const b = try renderPhraseSamplesWith(alloc, vowel, shut);
    defer alloc.free(b);
    return bandEnergy(a, lo, hi, 10) / bandEnergy(b, lo, hi, 10);
}

test "physical knobs: each axis changes the audio, deterministically and audibly" {
    const alloc = testing.allocator;
    const plain = try renderPhraseWav(alloc, "kujamba karibu");
    defer alloc.free(plain);

    // every axis, pushed both ways (0 is a legal value for all but pressure,
    // which floors at min_pressure)
    const axes = [_]struct { name: []const u8, lo: VoiceKnobs, hi: VoiceKnobs }{
        .{ .name = "pressure", .lo = .{ .pressure = 0.3 }, .hi = .{ .pressure = 2.0 } },
        .{ .name = "tension", .lo = .{ .tension = 0.2 }, .hi = .{ .tension = 2.0 } },
        .{ .name = "resonance", .lo = .{ .resonance = 0.0 }, .hi = .{ .resonance = 2.5 } },
        .{ .name = "turbulence", .lo = .{ .turbulence = 0.0 }, .hi = .{ .turbulence = 3.0 } },
        .{ .name = "wetness", .lo = .{ .wetness = 0.0 }, .hi = .{ .wetness = 3.0 } },
        .{ .name = "rasp", .lo = .{ .rasp = 0.0 }, .hi = .{ .rasp = 3.0 } },
        .{ .name = "decay", .lo = .{ .decay = 0.0 }, .hi = .{ .decay = 2.0 } },
        .{ .name = "burst", .lo = .{ .burst = 0.0 }, .hi = .{ .burst = 3.0 } },
        .{ .name = "boom", .lo = .{ .boom = 0.0 }, .hi = .{ .boom = 3.0 } },
        .{ .name = "seed", .lo = .{ .seed = 1.0 }, .hi = .{ .seed = 99.0 } },
    };
    for (axes) |ax| {
        for ([_]VoiceKnobs{ ax.lo, ax.hi }) |knobs| {
            const out = try renderPhraseWavWith(alloc, "kujamba karibu", knobs);
            defer alloc.free(out);
            testing.expect(!std.mem.eql(u8, plain, out)) catch |e| {
                std.debug.print("knob '{s}' did not change the audio\n", .{ax.name});
                return e;
            };
            try expectNotSilence(out);
            const again = try renderPhraseWavWith(alloc, "kujamba karibu", knobs);
            defer alloc.free(again);
            try testing.expectEqualSlices(u8, out, again);
        }
    }
}

test "physical knobs: spelling every default out is still the default" {
    const alloc = testing.allocator;
    const plain = try renderPhraseWav(alloc, "karibu sana");
    defer alloc.free(plain);
    const spelled = try renderPhraseWavWith(alloc, "karibu sana", try parseKnobs(
        "pressure=1,tension=1,resonance=1,turbulence=1,wetness=1,rasp=1,decay=1,burst=1,boom=1,seed=0,legacy=0",
    ));
    defer alloc.free(spelled);
    try testing.expectEqualSlices(u8, plain, spelled);
}

test "physical knobs: extremes are clamped — finite, audible, under the ceiling" {
    const alloc = testing.allocator;
    const wild = [_]VoiceKnobs{
        .{ .pressure = 0, .tension = 0, .resonance = 0, .turbulence = 0, .wetness = 0, .rasp = 0, .decay = 0, .burst = 0, .boom = 0 },
        .{ .pressure = 1e9, .tension = 1e9, .resonance = 1e9, .turbulence = 1e9, .wetness = 1e9, .rasp = 1e9, .decay = 1e9, .burst = 1e9, .boom = 1e9 },
        .{ .pressure = 1e9, .tension = 0, .boom = 1e9, .decay = 0, .intensity = 1e9 },
        .{ .pressure = 0, .tension = 1e9, .decay = 1e9, .intensity = 0, .seed = 1e30 },
        .{ .seed = 16777216, .cents = -1e9, .attack = 0, .noise = 1e9 },
    };
    for (wild) |knobs| {
        const out = try renderPhraseSamplesWith(alloc, "ng'ombe mbwa kwenda shuzi hh", knobs);
        defer alloc.free(out);
        try testing.expect(out.len > 1000);
        try testing.expect(rmsOf(out) > 1.0); // real audio, never a NaN panic or silence
        try testing.expect(peakOf(out) <= 31130); // 0.95 of full scale
    }
    // and a wordless shuzi under the same abuse
    for (wild) |knobs| {
        const wav = try renderShuziWavWith(alloc, 7, knobs);
        defer alloc.free(wav);
        // pressure 0 at effort 0 is deliberately timid, so "audible" here is
        // an RMS floor, not expectNotSilence's 9% peak
        const pcm = try alloc.alloc(i16, (wav.len - 44) / 2);
        defer alloc.free(pcm);
        for (pcm, 0..) |*v, k| v.* = std.mem.readInt(i16, wav[44 + 2 * k ..][0..2], .little);
        try testing.expect(rmsOf(pcm) > 1.0);
        try testing.expect(peakOf(pcm) <= 31130);
    }
}

test "physical knobs: parse, slots and names agree" {
    const k = try parseKnobs("pressure=1.5, tension=0.6 ,resonance=2,turbulence=0,wetness=3,rasp=2,decay=0.5,burst=2,boom=1.5,seed=7,legacy=1");
    try testing.expectEqual(@as(f32, 1.5), k.pressure);
    try testing.expectEqual(@as(f32, 0.6), k.tension);
    try testing.expectEqual(@as(f32, 2.0), k.resonance);
    try testing.expectEqual(@as(f32, 0.0), k.turbulence);
    try testing.expectEqual(@as(f32, 3.0), k.wetness);
    try testing.expectEqual(@as(f32, 2.0), k.rasp);
    try testing.expectEqual(@as(f32, 0.5), k.decay);
    try testing.expectEqual(@as(f32, 2.0), k.burst);
    try testing.expectEqual(@as(f32, 1.5), k.boom);
    try testing.expectEqual(@as(u64, 7), k.seedSalt());
    try testing.expect(k.isLegacy());
    // untouched axes keep their identity
    try testing.expectEqual(@as(f32, 1.0), k.attack);
    try testing.expect(!(VoiceKnobs{}).isLegacy());
    try testing.expectEqual(@as(u64, 0), (VoiceKnobs{}).seedSalt());

    // only cents may be negative; the new knobs are multipliers
    try testing.expectError(error.Negative, parseKnobs("pressure=-1"));
    try testing.expectError(error.Negative, parseKnobs("seed=-3"));
    try testing.expectError(error.NotFinite, parseKnobs("wetness=inf"));
    try testing.expectError(error.UnknownKnob, parseKnobs("stink=2"));

    // every name is reachable through the slot table, once, in order
    for (knob_names, 0..) |name, slot| {
        try testing.expectEqual(@as(?usize, slot), knobSlot(name));
        var probe = VoiceKnobs{};
        try testing.expectEqual(@as(?usize, slot), setKnobByName(&probe, name, 0.5));
    }
    try testing.expectEqual(@as(?usize, null), knobSlot("pitch"));
}

test "pressure drains: the pitch falls exponentially, and decay=0 holds it flat" {
    const alloc = testing.allocator;
    // a bare pulse train, so the autocorrelation finds the sphincter's rate
    var falling = dry_buzz;
    falling.decay = 1.0;
    var flat = dry_buzz;
    flat.decay = 0.0;
    const fall = try renderPhraseSamplesWith(alloc, "a", falling);
    defer alloc.free(fall);
    const hold = try renderPhraseSamplesWith(alloc, "a", flat);
    defer alloc.free(hold);

    const n = fall.len;
    const early_f = try pitchHz(alloc, fall[n / 20 .. n * 3 / 10]);
    const late_f = try pitchHz(alloc, fall[n * 6 / 10 .. n * 85 / 100]);
    const early_h = try pitchHz(alloc, hold[n / 20 .. n * 3 / 10]);
    const late_h = try pitchHz(alloc, hold[n * 6 / 10 .. n * 85 / 100]);
    // the fall is about 30% between those windows; flat is flat
    try testing.expect(early_f > 1.15 * late_f);
    try testing.expect(@abs(early_h / late_h - 1.0) < 0.1);
}

test "the pitch fall is exponential: fast first, then settling" {
    const alloc = testing.allocator;
    var k = dry_buzz;
    k.decay = 1.5;
    const s = try renderPhraseSamplesWith(alloc, "a", k);
    defer alloc.free(s);
    const n = s.len;
    // three equal windows in the body: the first step down is bigger than the second
    const p1 = try pitchHz(alloc, s[n * 5 / 100 .. n * 25 / 100]);
    const p2 = try pitchHz(alloc, s[n * 30 / 100 .. n * 50 / 100]);
    const p3 = try pitchHz(alloc, s[n * 55 / 100 .. n * 75 / 100]);
    try testing.expect(p1 > p2 and p2 > p3);
    try testing.expect(p1 - p2 > p2 - p3);
}

test "sphincter tension raises the pitch" {
    const alloc = testing.allocator;
    var slack = dry_buzz;
    slack.tension = 0.5;
    var tight = dry_buzz;
    tight.tension = 2.0;
    const lo = try renderPhraseSamplesWith(alloc, "a", slack);
    defer alloc.free(lo);
    const hi = try renderPhraseSamplesWith(alloc, "a", tight);
    defer alloc.free(hi);
    const n = lo.len;
    const p_lo = try pitchHz(alloc, lo[n / 20 .. n * 3 / 10]);
    const p_hi = try pitchHz(alloc, hi[n / 20 .. n * 3 / 10]);
    try testing.expect(p_hi > 1.3 * p_lo);
}

test "turbulence adds air: more high-band energy, none at zero" {
    const alloc = testing.allocator;
    const clean = try renderPhraseSamplesWith(alloc, "a", .{ .turbulence = 0.0, .wetness = 0.0 });
    defer alloc.free(clean);
    const gritty = try renderPhraseSamplesWith(alloc, "a", .{ .turbulence = 3.0, .wetness = 0.0 });
    defer alloc.free(gritty);
    const hf_clean = bandEnergy(clean, 3000, 7000, 250);
    const hf_gritty = bandEnergy(gritty, 3000, 7000, 250);
    try testing.expect(hf_gritty > 3.0 * hf_clean);
}

test "resonance: the vowel selects the formants" {
    const alloc = testing.allocator;
    // Opening the cavity boosts exactly where the vowel's formants are. Through
    // the same buzz, "a" (F1 680) and "u" (F2 700) light up 600-900 Hz while
    // "i" (F2 2100) lights up 1.8-2.4 kHz and leaves 600-900 Hz alone.
    const mid_i = try cavityBoost(alloc, "i", 600, 900);
    const hi_i = try cavityBoost(alloc, "i", 1800, 2400);
    const mid_a = try cavityBoost(alloc, "a", 600, 900);
    const hi_a = try cavityBoost(alloc, "a", 1800, 2400);
    const mid_u = try cavityBoost(alloc, "u", 600, 900);
    const hi_u = try cavityBoost(alloc, "u", 1800, 2400);
    // "i": the high band gains far more than the middle one; a and u the reverse
    try testing.expect(hi_i / mid_i > 100.0 * (hi_a / mid_a));
    try testing.expect(hi_i / mid_i > 100.0 * (hi_u / mid_u));
    try testing.expect(mid_a > 50.0);
    try testing.expect(mid_u > 50.0);
    try testing.expect(hi_i > 50.0);
}

test "plosives are pressure bursts: k cracks, a bare vowel does not" {
    const alloc = testing.allocator;
    const crack = try renderPhraseSamplesWith(alloc, "ka", .{ .burst = 3.0 });
    defer alloc.free(crack);
    const soft = try renderPhraseSamplesWith(alloc, "ka", .{ .burst = 0.0 });
    defer alloc.free(soft);
    // the release lands right after the 12 ms closure: the 12-40 ms window
    // must be much hotter with the burst than without
    const a = SAMPLE_RATE * 12 / 1000;
    const b = SAMPLE_RATE * 40 / 1000;
    try testing.expect(rmsOf(crack[a..b]) > 1.5 * rmsOf(soft[a..b]));
    // a voiceless stop's closure is nearly silent, then the crack arrives
    const closure = SAMPLE_RATE * 8 / 1000;
    try testing.expect(rmsOf(crack[0..closure]) < 0.25 * rmsOf(crack[a..b]));

    // a bare vowel has no burst to turn off: the knob cannot touch its bytes
    // beyond the (burst-free) voiced path
    const v1 = try renderPhraseSamplesWith(alloc, "a", .{ .burst = 3.0 });
    defer alloc.free(v1);
    const v0 = try renderPhraseSamplesWith(alloc, "a", .{ .burst = 0.0 });
    defer alloc.free(v0);
    try testing.expectEqualSlices(i16, v1, v0);
}

test "onsets map to physics: stops burst, fricatives hiss, nasals close" {
    // plosives -> sudden pressure bursts
    for ("pkt") |c| {
        const s = onsetShape(&[_]u8{c});
        try testing.expect(s.burst > 0.5);
        try testing.expect(s.closure_s > 0);
        try testing.expect(s.closure_gain < 0.1); // voiceless: shut tight
    }
    for ("bdg") |c| {
        const s = onsetShape(&[_]u8{c});
        try testing.expect(s.burst > 0.5);
        try testing.expect(s.thump > 0); // voiced: the bwomp
        try testing.expect(s.closure_gain > 0.1); // with a voice bar
    }
    // lips are low, the velum is mid, the tongue tip is high
    try testing.expect(onsetShape("p").burst_hz < onsetShape("k").burst_hz);
    try testing.expect(onsetShape("k").burst_hz < onsetShape("t").burst_hz);
    // fricatives -> sustained hiss, voiceless ones begin as pure air
    for ([_][]const u8{ "s", "sh", "z", "f", "v", "h", "th", "dh", "gh" }) |o| {
        try testing.expect(onsetShape(o).hiss > 0);
        try testing.expectEqual(@as(f32, 0.0), onsetShape(o).burst);
    }
    try testing.expect(onsetShape("s").voicing < 0.3);
    try testing.expect(onsetShape("s").hiss_hz > onsetShape("sh").hiss_hz);
    // nasals -> a muffled closure; prenasalized stops add the burst after it
    try testing.expect(onsetShape("m").closure_s > 0.03);
    try testing.expectEqual(@as(f32, 0.0), onsetShape("m").burst);
    try testing.expect(onsetShape("mb").closure_s > 0.03);
    try testing.expect(onsetShape("mb").burst > 0.0);
    try testing.expect(onsetShape("nd").thump > 0.0);
    try testing.expectEqual(@as(f32, 0.0), onsetShape("ng'").burst);
    // glides bring the formants in from u / i; r rolls
    try testing.expectEqual(@as(u8, 'u'), onsetShape("w").glide_from);
    try testing.expectEqual(@as(u8, 'i'), onsetShape("y").glide_from);
    try testing.expectEqual(@as(u8, 'u'), onsetShape("kw").glide_from);
    try testing.expect(onsetShape("r").trill > 0.3);
    // the bare vowel is the neutral shape
    try testing.expectEqual(OnsetShape{}, onsetShape(""));
    // every onset the scanner can produce maps without surprises
    var scan = Scanner.init("ng'ombe mbwa nyumba kwenda shuzi chai dhahabu ghali khamsini phone");
    while (scan.next()) |syl| {
        const s = onsetShape(syl.onset());
        try testing.expect(std.math.isFinite(s.burst_hz) and s.burst_s > 0 and s.hiss_s > 0);
    }
}

test "vowels keep the vowel table's formants distinct and ordered" {
    // F1 rises a-ward, F2 rises front-ward: i > e > a > o > u at F2
    try testing.expect(vowelFormants('i')[1] > vowelFormants('e')[1]);
    try testing.expect(vowelFormants('e')[1] > vowelFormants('a')[1]);
    try testing.expect(vowelFormants('a')[1] > vowelFormants('o')[1]);
    try testing.expect(vowelFormants('o')[1] > vowelFormants('u')[1]);
    try testing.expect(vowelFormants('a')[0] > vowelFormants('i')[0]);
    for ("aeiou") |v| {
        const f = vowelFormants(v);
        try testing.expect(f[0] < f[1] and f[1] < f[2]);
    }
}

test "legacy=1 is the old synth: different from the new default, and deterministic" {
    const alloc = testing.allocator;
    const new = try renderPhraseWav(alloc, "kujamba karibu");
    defer alloc.free(new);
    const old = try renderPhraseWavWith(alloc, "kujamba karibu", .{ .legacy = 1 });
    defer alloc.free(old);
    const old2 = try renderPhraseWavWith(alloc, "kujamba karibu", try parseKnobs("legacy=1"));
    defer alloc.free(old2);
    try testing.expect(!std.mem.eql(u8, new, old));
    try testing.expectEqualSlices(u8, old, old2);
    try testing.expectEqual(new.len, old.len); // same timeline, different sound
    try expectNotSilence(old);

    // the physical knobs have nothing to say to the legacy path
    const old_pressed = try renderPhraseWavWith(alloc, "kujamba karibu", .{ .legacy = 1, .pressure = 2.5, .wetness = 3, .tension = 2 });
    defer alloc.free(old_pressed);
    try testing.expectEqualSlices(u8, old, old_pressed);
}

test "seed re-rolls the fart: same seed same bytes, a new seed a new fart" {
    const alloc = testing.allocator;
    const base = try renderPhraseWav(alloc, "shuzi kubwa");
    defer alloc.free(base);
    const zero = try renderPhraseWavWith(alloc, "shuzi kubwa", .{ .seed = 0 });
    defer alloc.free(zero);
    const s7 = try renderPhraseWavWith(alloc, "shuzi kubwa", .{ .seed = 7 });
    defer alloc.free(s7);
    const s7b = try renderPhraseWavWith(alloc, "shuzi kubwa", .{ .seed = 7 });
    defer alloc.free(s7b);
    const s8 = try renderPhraseWavWith(alloc, "shuzi kubwa", .{ .seed = 8 });
    defer alloc.free(s8);
    try testing.expectEqualSlices(u8, base, zero);
    try testing.expectEqualSlices(u8, s7, s7b);
    try testing.expect(!std.mem.eql(u8, base, s7));
    try testing.expect(!std.mem.eql(u8, s7, s8));
    try testing.expectEqual(base.len, s7.len);
}

test "the default fart is loud, dense and under the ceiling" {
    const alloc = testing.allocator;
    const phrases = [_][]const u8{ "kujamba karibu", "shuzi kubwa sana", "habari yako", "mtu ng'ombe" };
    for (phrases) |phrase| {
        const out = try renderPhraseSamples(alloc, phrase);
        defer alloc.free(out);
        const db = 20.0 * std.math.log10(rmsOf(out) / 32768.0);
        // louder than the pre-physics synth's -18 dBFS, never a wall of clipping
        try testing.expect(db > -17.0 and db < -7.0);
        try testing.expect(peakOf(out) <= 31130);
        // every syllable ends at silence, so a phrase boundary never clicks
        var plan = try planPhrase(alloc, phrase);
        defer plan.deinit(alloc);
        for (plan.items) |item| {
            const end = item.start + item.len;
            try testing.expect(@abs(@as(i32, out[end - 1])) < 200);
        }
    }
}

test "wordless shuzi: archetypes vary the texture, the timeline stays put" {
    const alloc = testing.allocator;
    var centroid_min: f64 = 1e9;
    var centroid_max: f64 = 0;
    var seed: u64 = 1;
    while (seed <= 24) : (seed += 1) {
        const a = try renderShuziWav(alloc, seed);
        defer alloc.free(a);
        const b = try renderShuziWav(alloc, seed);
        defer alloc.free(b);
        try testing.expectEqualSlices(u8, a, b);
        try expectNotSilence(a);
        const legacy = try renderShuziWavWith(alloc, seed, .{ .legacy = 1 });
        defer alloc.free(legacy);
        // physics changed the sound, not the length
        try testing.expectEqual(a.len, legacy.len);
        try testing.expect(!std.mem.eql(u8, a, legacy));
        const pcm = try alloc.alloc(i16, (a.len - 44) / 2);
        defer alloc.free(pcm);
        for (pcm, 0..) |*s, k| s.* = std.mem.readInt(i16, a[44 + 2 * k ..][0..2], .little);
        // cheap spectral centroid proxy: zero crossings per second
        const zc = @as(f64, @floatFromInt(zeroCrossings(pcm))) * @as(f64, SAMPLE_RATE) / @as(f64, @floatFromInt(pcm.len));
        centroid_min = @min(centroid_min, zc);
        centroid_max = @max(centroid_max, zc);
    }
    // thunder and squeaks and rasps: the brightest is clearly not the dullest
    try testing.expect(centroid_max > 1.5 * centroid_min);
}

test "the libm-free exp/sin/tan track the real ones to f32 precision" {
    var x: f32 = -60.0;
    while (x <= 60.0) : (x += 0.0371) {
        const want = @exp(x);
        try testing.expect(@abs(detExp(x) - want) <= 4e-7 * want + 1e-37);
    }
    // phases the oscillators actually reach: tens to hundreds of radians
    x = -700.0;
    while (x <= 700.0) : (x += 0.0173) {
        try testing.expect(@abs(detSin(x) - @sin(x)) < 2e-6);
    }
    x = 0.01;
    while (x < 1.4) : (x += 0.0029) {
        const want = @tan(x);
        try testing.expect(@abs(detTan(x) - want) <= 2e-6 * want);
    }
    try testing.expectEqual(@as(f32, 1.0), detExp(0.0));
    try testing.expectEqual(@as(f32, 0.0), detSin(0.0));
}
