//! synth.zig — Flatlophone v2: real fart synthesis + Swahili syllable engine.
//!
//! Pure Zig stdlib. Emits PCM WAV (RIFF), 44100 Hz, mono, 16-bit. No libc, no
//! file I/O: every render is a pure function of its input. The noise generator
//! is seeded from a hash of the input text with fixed constants everywhere
//! else, so the same phrase always produces byte-identical WAV bytes. Always.
//!
//! One fart "phoneme" (one Swahili syllable) is a small physical model:
//!   * a gas reservoir at `pressure`, draining exponentially across the
//!     syllable; everything below rides on it
//!   * a sphincter: a flap oscillator (Rosenberg pulse) whose rate follows the
//!     pressure, so the pitch decays exponentially as the reservoir empties;
//!     `tension` sets how high and how narrow (bright) the flaps are, and how
//!     ragged they get as the pressure sags (period jitter, flap dropouts)
//!   * turbulence: band-passed noise gated by the flap opening, so the hiss
//!     sprays in bursts with every flap; `turbulence` sets how much
//!   * a terminal tract: two formant resonators set by the vowel, scaled by
//!     `resonance` (bigger tract = lower, longer ring), over a fat low body
//!   * a soft saturator that glues it, then the amplitude envelope: fast
//!     attack, the pressure's own decay, a ~24-34 Hz flutter wobble, and a
//!     tail that reaches exactly zero
//!
//! Swahili is nearly pure CV. `Scanner` splits a word into syllables: each
//! vowel picks the base pitch and the tract formants, the consonant onset picks
//! the attack character (plosives burst, fricatives spray, nasals hum in, "r"
//! rolls), and the syllable count sets the total duration. A phrase shares one
//! reservoir: it drains a little with each syllable and takes a breath between
//! words. The mapping tables are the `vowel*`/`voiceSpec`/`onsetSpec`
//! functions below; the knobs are documented on `VoiceKnobs`.
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

/// Stock depth of the exponential pitch decay: the fraction of the starting
/// pitch the flap rate would lose if the reservoir drained completely. It
/// follows the pressure curve, so most of the drop happens early and the
/// tail flattens out — a real fart sags, it does not slide.
const PITCH_DROP: f32 = 0.40;

// ---------------------------------------------------------------------
// Mapping tables
// ---------------------------------------------------------------------

/// Base rate of the sphincter flap oscillator, chosen by the syllable's vowel.
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

/// The two resonances of the terminal tract, in Hz.
pub const Formants = struct { f1: f32, f2: f32 };

/// Tract formants chosen by the syllable's vowel, so "a" and "i" are told
/// apart by ear and not only by pitch. Human vowel formants pulled ~10% down
/// for a tract that is more rectum than mouth. The breath syllable (no vowel)
/// gets a neutral tract.
pub fn vowelFormants(v: u8) Formants {
    return switch (v) {
        'a' => .{ .f1 = 700.0, .f2 = 1150.0 },
        'e' => .{ .f1 = 500.0, .f2 = 1750.0 },
        'i' => .{ .f1 = 300.0, .f2 = 2200.0 },
        'o' => .{ .f1 = 480.0, .f2 = 820.0 },
        'u' => .{ .f1 = 330.0, .f2 = 760.0 },
        else => .{ .f1 = 450.0, .f2 = 1400.0 },
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
    /// Plosive pressure burst: how far above the sustained pressure the onset
    /// overshoots (0.9 = nearly double). It kicks the level, the pitch and the
    /// attack splat together, which is what a "k" or "p" is: a sudden release.
    burst: f32 = 0.0,
    /// How fast the burst bleeds back down to the sustained pressure (s).
    burst_s: f32 = 0.03,
    /// The onset's own sphincter tension, as a multiplier on the knob: a stop
    /// is squeezed tight (higher, brighter), a nasal hums in loose.
    tension: f32 = 1.0,
    /// The onset's own turbulence, as a multiplier on the knob: a fricative
    /// sprays, a nasal barely hisses.
    turbulence: f32 = 1.0,
    /// Onset roll: the depth of a ~26 Hz flutter over the first ~80 ms. Only a
    /// trilled "r" has one.
    trill: f32 = 0.0,
};

pub fn voiceSpec(cls: VoiceClass) VoiceSpec {
    return switch (cls) {
        .none => .{ .attack_s = 0.008, .noise_mix = 0.25, .wobble_hz = 28.0, .wobble_depth = 0.50, .level = 0.90, .burst = 0.15, .burst_s = 0.040, .tension = 1.00, .turbulence = 1.0 },
        .stop_voiceless => .{ .attack_s = 0.003, .noise_mix = 0.40, .wobble_hz = 32.0, .wobble_depth = 0.55, .level = 0.95, .burst = 0.90, .burst_s = 0.022, .tension = 1.15, .turbulence = 1.3 },
        .stop_voiced => .{ .attack_s = 0.005, .noise_mix = 0.28, .wobble_hz = 30.0, .wobble_depth = 0.50, .level = 1.00, .burst = 0.60, .burst_s = 0.035, .tension = 1.05, .turbulence = 0.9 },
        .fricative => .{ .attack_s = 0.012, .noise_mix = 0.50, .wobble_hz = 29.0, .wobble_depth = 0.45, .level = 0.90, .burst = 0.25, .burst_s = 0.070, .tension = 0.95, .turbulence = 1.7 },
        .nasal => .{ .attack_s = 0.025, .noise_mix = 0.12, .wobble_hz = 26.0, .wobble_depth = 0.35, .level = 0.85, .burst = 0.00, .burst_s = 0.030, .tension = 0.80, .turbulence = 0.5 },
        .liquid => .{ .attack_s = 0.014, .noise_mix = 0.18, .wobble_hz = 28.0, .wobble_depth = 0.45, .level = 0.90, .burst = 0.10, .burst_s = 0.050, .tension = 0.90, .turbulence = 0.8 },
    };
}

/// Letters that make the second half of a prenasalized onset (mb, nd, ng, nj,
/// nz, mv, ...): the cluster hums in on the nasal and then releases on this.
fn isPrenasalizedRelease(c: u8) bool {
    return switch (c) {
        'b', 'd', 'g', 'j', 'p', 't', 'k', 'z', 'v' => true,
        else => false,
    };
}

/// The onset's spec: the class table, refined by what the cluster spells.
///   * prenasalized stops ("mba" in kujamba, "nde", "ngo"): the nasal's slow
///     hum-in, then the stop's burst — `ng'` (the velar nasal) is left alone
///   * a trilled "r" rolls its first 80 ms
///   * "sh" sprays darker and wetter than "s"; "h" is nearly all breath
pub fn onsetSpec(onset: []const u8) VoiceSpec {
    var spec = voiceSpec(classify(onset));
    if (onset.len == 0) return spec;
    if (onset.len >= 2 and (onset[0] == 'm' or onset[0] == 'n') and isPrenasalizedRelease(onset[1]) and
        std.mem.indexOfScalar(u8, onset, '\'') == null)
    {
        const release = voiceSpec(classify(onset[1..]));
        spec.attack_s = 0.018;
        spec.burst = release.burst * 0.8;
        spec.burst_s = release.burst_s;
        spec.noise_mix = (spec.noise_mix + release.noise_mix) * 0.5;
        spec.tension = (spec.tension + release.tension) * 0.5;
        spec.turbulence = release.turbulence;
        spec.level = release.level;
    }
    switch (onset[0]) {
        'r' => spec.trill = 0.7,
        's' => if (onset.len >= 2 and onset[1] == 'h') {
            spec.tension = 0.85;
            spec.turbulence = 2.0;
        },
        'h' => {
            spec.noise_mix = 0.65;
            spec.burst = 0.10;
            spec.turbulence = 2.0;
        },
        else => {},
    }
    return spec;
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
/// The physical parameters — `pressure`, `tension`, `resonance`, `turbulence`
/// and `glide` — are multipliers on the model's stock values and are applied by
/// the renderer too, on top of what the onset class and the vowel set. Each one
/// is clamped into its documented range when applied.
///
/// The default is 1.0 on every multiplier and 0 on `cents`, and `x * 1.0` is
/// exact in IEEE-754, so an untouched `VoiceKnobs` reproduces the stock sound
/// bit for bit. That is load-bearing, not decorative: the golden fingerprints
/// in `src/golden.zig` assert it, and all seven of them have to keep passing
/// unchanged.
pub const VoiceKnobs = struct {
    /// scales `attack_s`
    attack: f32 = 1.0,
    /// scales `noise_mix`: the master amount of every noisy component (attack
    /// splat, body hiss and the turbulence spray). 0 is a clean buzz.
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
    /// Intestinal pressure: how much gas is behind the sphincter. More
    /// pressure is louder (into the saturator, so fatter rather than just
    /// bigger), pitched higher, sprays more turbulence and takes longer to run
    /// out; low pressure is a weak, low, quickly-sputtering leak. 0.25..4.
    pressure: f32 = 1.0,
    /// Sphincter tension: how hard the orifice is squeezed. Tight (>1) is
    /// higher-pitched with narrow flaps — bright, buzzy, raspy, a clean squeak
    /// to the end. Loose (<1) is lower with wide round flaps — tubby, wet,
    /// flabby, with ragged timing and flaps dropping out as the pressure sags.
    /// Also steers the turbulence band: tight sprays bright, loose bubbles
    /// dark. 0.25..4.
    tension: f32 = 1.0,
    /// Terminal tract resonance: the size and ring of the cavity the fart
    /// leaves through. Bigger (>1) pulls the vowel formants down, lets them
    /// ring longer and louder — cavernous, thunderous. Smaller (<1) is thin,
    /// dry and papery. 0.25..4.
    resonance: f32 = 1.0,
    /// Turbulence: the amount of noise sprayed in bursts with every flap of
    /// the sphincter, on top of the onset splat. 0 is a dry, pure buzz; 2 is
    /// wet and sputtery. 0..4.
    turbulence: f32 = 1.0,
    /// Pitch decay depth: scales how far the flap rate falls as the pressure
    /// drains. 0 holds the pitch flat; 2 sags to roughly a third. 0..2.
    glide: f32 = 1.0,

    /// Bounds on the *resulting* spec, not on the multipliers. Each one exists
    /// because the value feeds arithmetic that breaks outside its range.
    pub const min_attack_s: f32 = 0.0005; // 0.5ms; 0 makes sample 0 compute 0/0 -> NaN
    pub const max_attack_s: f32 = 0.200;
    pub const max_noise_mix: f32 = 1.0; // past 1 it is the same noise, just clipped
    /// past 2, `wob = 1 - depth * (...)` goes negative and flips the
    /// waveform's polarity — that is distortion, not chaos
    pub const max_wobble_depth: f32 = 1.0;
    /// The physical ranges. Below a quarter the flap oscillator stalls (the
    /// pitch leaves the audible band or every flap drops out); past four it is
    /// pinned at the saturator and the clip anyway.
    pub const min_pressure: f32 = 0.25;
    pub const max_pressure: f32 = 4.0;
    pub const min_tension: f32 = 0.25;
    pub const max_tension: f32 = 4.0;
    pub const min_resonance: f32 = 0.25;
    pub const max_resonance: f32 = 4.0;
    /// 0 is meaningful (a dry buzz); past 4 the spray is all there is.
    pub const max_turbulence: f32 = 4.0;
    /// At 2 the stock 40% drop becomes 80%, a sag to a fifth of the starting
    /// pitch. Deeper than that the oscillator leaves the audible band.
    pub const max_glide: f32 = 2.0;
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

    /// `2^(cents/1200)` — the factor every base frequency is multiplied by,
    /// with `cents` clamped to one octave either way. The `cents == 0` branch
    /// is load-bearing: the untouched knobs must be a *bit-exact* identity
    /// (the golden fingerprints assert it), and `x * 1.0` is exact in IEEE-754
    /// in a way a polynomial 2^x is only ever allowed to be, not guaranteed
    /// to be. `exp2F` rather than `std.math.pow` so a tuned voice renders the
    /// same bits in every build mode too.
    pub fn pitchFactor(self: VoiceKnobs) f32 {
        if (self.cents == 0) return 1.0;
        const c = std.math.clamp(self.cents, -max_abs_cents, max_abs_cents);
        return exp2F(c / 1200.0);
    }

    /// The effort value the renderer actually applies: `intensity` clamped
    /// into its useful range, so a preset can never mute the instrument.
    pub fn effort(self: VoiceKnobs) f32 {
        return std.math.clamp(self.intensity, min_intensity, max_intensity);
    }

    /// The physical knobs clamped into their ranges, as the renderer applies
    /// them. Kept separate from `apply` because they are not properties of
    /// the onset class: they multiply the whole model.
    pub fn physical(self: VoiceKnobs) Physical {
        return .{
            .pressure = std.math.clamp(self.pressure, min_pressure, max_pressure),
            .tension = std.math.clamp(self.tension, min_tension, max_tension),
            .resonance = std.math.clamp(self.resonance, min_resonance, max_resonance),
            .turbulence = std.math.clamp(self.turbulence, 0.0, max_turbulence),
            .glide = std.math.clamp(self.glide, 0.0, max_glide),
        };
    }

    pub const Physical = struct {
        pressure: f32,
        tension: f32,
        resonance: f32,
        turbulence: f32,
        glide: f32,
    };

    /// The class table with the knobs applied. `wobble_hz` is deliberately
    /// untouched: the knob is on the depth of the flutter, and the rate is
    /// part of each class's character. `intensity`, `cents` and the physical
    /// knobs are applied by the renderer (see above), not here; the onset's
    /// own burst/tension/turbulence/trill pass through.
    pub fn apply(self: VoiceKnobs, spec: VoiceSpec) VoiceSpec {
        return .{
            .attack_s = std.math.clamp(spec.attack_s * self.attack, min_attack_s, max_attack_s),
            .noise_mix = std.math.clamp(spec.noise_mix * self.noise, 0.0, max_noise_mix),
            .wobble_hz = spec.wobble_hz,
            .wobble_depth = std.math.clamp(spec.wobble_depth * self.wobble, 0.0, max_wobble_depth),
            .level = spec.level,
            .burst = spec.burst,
            .burst_s = spec.burst_s,
            .tension = spec.tension,
            .turbulence = spec.turbulence,
            .trill = spec.trill,
        };
    }
};

pub const KnobsError = error{ UnknownKnob, MalformedKnob, NotFinite, Negative };

/// Parse `attack=1.2,noise=0.8,wobble=2` into multipliers. Order is free and
/// whitespace around keys and values is ignored; an empty string is the
/// identity, which is what `--voice ""` and an omitted flag both mean.
/// `intensity` and `cents` (#15, #16) take the same spelling: `intensity` is
/// a multiplier (>= 0), `cents` an offset in cents and the one key a negative
/// value is meaningful for. The physical knobs — `pressure`, `tension`,
/// `resonance`, `turbulence`, `glide` — are multipliers too.
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
        } else if (std.mem.eql(u8, key, "glide")) {
            knobs.glide = v;
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

/// Everything one rendered phoneme needs. The first seven are the historical
/// voice; the rest is the physical model, defaulted so a bare literal still
/// means "stock fart".
const VoiceParams = struct {
    /// base flap rate before pressure and tension move it (Hz)
    f0: f32,
    attack_s: f32,
    noise_mix: f32,
    wobble_hz: f32,
    wobble_depth: f32,
    level: f32,
    /// depth of the exponential pitch decay: the fraction of `f0` lost if the
    /// reservoir drained completely
    glide: f32,
    pressure: f32 = 1.0,
    tension: f32 = 1.0,
    resonance: f32 = 1.0,
    turbulence: f32 = 1.0,
    /// plosive pressure overshoot at the onset, see `VoiceSpec.burst`
    burst: f32 = 0.0,
    burst_s: f32 = 0.03,
    trill: f32 = 0.0,
    formants: Formants = .{ .f1 = 450.0, .f2 = 1400.0 },
};

// ---------------------------------------------------------------------
// Deterministic math
//
// `@sin`, `@cos`, `@exp` and `std.math.pow` do not produce the same bits in
// Debug and ReleaseSafe (measured on aarch64-macos: LLVM lowers them
// differently per optimization level), which is what made the old synth's
// exact WAV hash unstable across build modes. Plain IEEE arithmetic, @sqrt,
// @floor, bit casts and `std.math.tanh` do, under Zig's default strict float
// mode. So the synth uses these instead: a Cephes-style sin/cos and a 2^x
// built from an exponent bit shift plus a short series, accurate to about
// 1e-6 — far below one i16 step — and bit-identical in every build mode.
// ---------------------------------------------------------------------

const SinCos = struct { s: f32, c: f32 };

/// sin and cos of `x` (radians; |x| stays well under 1e4 everywhere the
/// synth calls this), reduced to |r| <= pi/4 by quadrant and evaluated with
/// the Cephes single-precision polynomials.
fn sinCos(x: f32) SinCos {
    const j = @floor(x * (2.0 / std.math.pi) + 0.5);
    // pi/2 in three parts, so the reduction keeps its precision
    const r = ((x - j * 1.5703125) - j * 4.837512969970703125e-4) - j * 7.549789948768648e-8;
    const q: u32 = @bitCast(@as(i32, @intFromFloat(j)) & 3);
    const r2 = r * r;
    const sp = ((-1.9515295891e-4 * r2 + 8.3321608736e-3) * r2 - 1.6666654611e-1) * r2 * r + r;
    const cp = ((2.443315711809948e-5 * r2 - 1.388731625493765e-3) * r2 + 4.166664568298827e-2) * r2 * r2 - 0.5 * r2 + 1.0;
    return switch (q) {
        0 => .{ .s = sp, .c = cp },
        1 => .{ .s = cp, .c = -sp },
        2 => .{ .s = -sp, .c = -cp },
        else => .{ .s = -cp, .c = sp },
    };
}

fn sinF(x: f32) f32 {
    return sinCos(x).s;
}

/// 2^x: the integer part by bit shift (exact), the fraction by a degree-7
/// series (relative error ~1e-6). Below 2^-125 it is 0; above 2^127 pinned.
fn exp2F(x: f32) f32 {
    if (x < -125.0) return 0.0;
    const xc = @min(x, 127.0);
    const n = @floor(xc);
    const f = xc - n;
    const p = 1.0 + f * (0.69314718056 + f * (0.24022650695 + f * (0.05550410866 + f * (0.00961812911 + f * (0.00133335581 + f * (1.54035304e-4 + f * 1.52527338e-5))))));
    const bits: u32 = @as(u32, @intCast(@as(i32, @intFromFloat(n)) + 127)) << 23;
    return p * @as(f32, @bitCast(bits));
}

/// e^x, via `exp2F`.
fn expF(x: f32) f32 {
    return exp2F(x * 1.4426950408889634);
}

/// log2 of a positive, finite, normal `x`: the exponent from the bits, the
/// mantissa by the atanh series (z <= 1/3, relative error ~1e-7).
fn log2F(x: f32) f32 {
    const bits: u32 = @bitCast(x);
    const e: f32 = @floatFromInt(@as(i32, @intCast(bits >> 23)) - 127);
    const m: f32 = @bitCast((bits & 0x007FFFFF) | 0x3F800000);
    const z = (m - 1.0) / (m + 1.0);
    const z2 = z * z;
    const ln_m = 2.0 * z * (1.0 + z2 * (1.0 / 3.0 + z2 * (1.0 / 5.0 + z2 * (1.0 / 7.0 + z2 * (1.0 / 9.0 + z2 * (1.0 / 11.0))))));
    return e + ln_m * 1.4426950408889634;
}

/// x^y for a positive `x`.
fn powF(x: f32, y: f32) f32 {
    return exp2F(y * log2F(x));
}

/// One-pole lowpass coefficient for a cutoff of `hz`.
fn onePole(hz: f32) f32 {
    return 1.0 - expF(-std.math.tau * hz * (1.0 / @as(f32, SAMPLE_RATE)));
}

/// A tract formant: two-pole resonator (the RBJ constant-peak-gain bandpass),
/// unity gain at `hz`, `q` sets how long it rings.
const Resonator = struct {
    b0: f32,
    a1: f32,
    a2: f32,
    x1: f32 = 0,
    x2: f32 = 0,
    y1: f32 = 0,
    y2: f32 = 0,

    fn init(hz: f32, q: f32) Resonator {
        const w = std.math.tau * hz / @as(f32, SAMPLE_RATE);
        const sc = sinCos(w);
        const alpha = sc.s / (2.0 * q);
        const a0 = 1.0 + alpha;
        return .{ .b0 = alpha / a0, .a1 = -2.0 * sc.c / a0, .a2 = (1.0 - alpha) / a0 };
    }

    fn run(self: *Resonator, x: f32) f32 {
        const y = self.b0 * (x - self.x2) - self.a1 * self.y1 - self.a2 * self.y2;
        self.x2 = self.x1;
        self.x1 = x;
        self.y2 = self.y1;
        self.y1 = y;
        return y;
    }
};

/// One flap of the sphincter at phase `ph` (0..1 of the cycle): the Rosenberg
/// glottal pulse. `oq` is the open quotient, the fraction of the cycle the
/// orifice is open; it opens over 62% of that and snaps shut over the other
/// 38%, and the asymmetry is where the bright snap at closure comes from.
/// `flow` is the gas flow (0..1), `dflow` its derivative — what actually
/// radiates as sound — scaled by `oq` so a narrow flap is thinner, not louder.
const Flap = struct { flow: f32, dflow: f32 };

fn flap(ph: f32, oq: f32) Flap {
    const pi: f32 = std.math.pi;
    const tp = oq * 0.62;
    const tn = oq - tp;
    if (ph < tp) {
        const sc = sinCos(pi * ph / tp);
        return .{ .flow = 0.5 * (1.0 - sc.c), .dflow = (pi / (2.0 * tp)) * sc.s * oq };
    } else if (ph < oq) {
        const sc = sinCos(pi * (ph - tp) / (2.0 * tn));
        return .{ .flow = sc.c, .dflow = -(pi / (2.0 * tn)) * sc.s * oq };
    }
    return .{ .flow = 0, .dflow = 0 };
}

/// Mean of the flap's flow over one cycle, per unit of `oq`: the DC the
/// low-body path subtracts before it integrates.
const FLAP_MEAN_PER_OQ: f32 = 0.5 * 0.62 + 0.38 * (2.0 / std.math.pi);

/// The fraction of the phoneme over which the tail is faded to exactly zero.
/// Applied after every filter, so no resonator ring survives the last sample
/// (the loop seam depends on sample 0 and sample n-1 both rounding to 0).
const TAIL_FADE: f32 = 0.22;

/// How fast the reservoir drains, per unit of the phoneme: more gas drains
/// slower. 2.2 at stock pressure, so a syllable ends at ~11% of its starting
/// pressure.
pub fn drainRate(pressure: f32) f32 {
    return 2.2 / (0.55 + 0.45 * @sqrt(pressure));
}

/// Reservoir pressure left at `u` (0..1 through the phoneme) as a fraction of
/// the start: a plain exponential.
pub fn reservoirAt(pressure: f32, u: f32) f32 {
    return expF(-drainRate(pressure) * u);
}

/// The flap rate's factor for a reservoir at `drain` of its start, with a
/// decay depth of `glide`: the pitch falls with the pressure, exponentially
/// because the pressure does. `glide = 0` is exactly 1.
pub fn pitchSag(glide: f32, drain: f32) f32 {
    return 1.0 - glide * (1.0 - drain);
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
/// randomness comes from `prng`, whose seed is fixed per render, and it draws
/// a fixed four values per sample whatever the parameters say.
///
/// Signal flow, per sample:
///
///   reservoir  P(u) = exp(-k u), k from `pressure`; a plosive `burst` rides
///              on top and bleeds off in `burst_s`
///   sphincter  flap rate f = f0 * sqrt(tension) * pressure^0.3, sagging with
///              P (the exponential pitch decay) and kicked up by the burst;
///              each new flap gets period jitter, amplitude shimmer and, once
///              P has sagged, a chance of dropping out (the sputter) — all of
///              it worse when loose, cleaner when tight
///   excitation the flap's radiated derivative (bright) + the integrated flow
///              low-passed at 400 Hz (the fat body)
///   turbulence band-passed noise gated open by the flap, band set by tension
///   tract      F1/F2 resonators from the vowel, scaled by `resonance`
///   output     DC block -> tanh saturator -> attack gate * tail fade *
///              flutter wobble * trill * level -> clip at 0.95
fn synthInto(out: []i16, p: VoiceParams, prng: *std.Random.DefaultPrng) void {
    const dt: f32 = 1.0 / @as(f32, SAMPLE_RATE);
    const tau: f32 = std.math.tau;
    const n = out.len;
    const inv_n: f32 = 1.0 / @as(f32, @floatFromInt(n));
    const r = prng.random();

    // The physical knobs reach here already multiplied by the onset's own
    // factors and the per-syllable jitter, so clamp the *result*.
    const pressure = std.math.clamp(p.pressure, VoiceKnobs.min_pressure, VoiceKnobs.max_pressure);
    const tension = std.math.clamp(p.tension, VoiceKnobs.min_tension, VoiceKnobs.max_tension);
    const resonance = std.math.clamp(p.resonance, VoiceKnobs.min_resonance, VoiceKnobs.max_resonance);
    const turbulence = std.math.clamp(p.turbulence, 0.0, VoiceKnobs.max_turbulence);
    const burst = std.math.clamp(p.burst, 0.0, 2.0);
    const burst_s = @max(p.burst_s, 0.005);
    const glide = std.math.clamp(p.glide, 0.0, PITCH_DROP * VoiceKnobs.max_glide);
    const trill_depth = std.math.clamp(p.trill, 0.0, 1.0);

    const drain_k = drainRate(pressure);

    // Sphincter: tight = high and narrow, loose = low, wide and ragged.
    const oq = std.math.clamp(0.5 / @sqrt(tension), 0.15, 0.85);
    const looseness = std.math.clamp(1.0 / tension, 0.5, 2.0);
    const pitch_mul = @sqrt(tension) * powF(pressure, 0.3);
    const flow_mean = FLAP_MEAN_PER_OQ * oq;

    // Tract: a bigger cavity has lower formants that ring longer and louder.
    const fscale = 1.0 / @sqrt(resonance);
    const qscale = @sqrt(resonance);
    var res1 = Resonator.init(std.math.clamp(p.formants.f1 * fscale, 120.0, 8000.0), 6.0 * qscale);
    var res2 = Resonator.init(std.math.clamp(p.formants.f2 * fscale, 120.0, 8000.0), 8.0 * qscale);
    const g1 = 1.4 * resonance;
    const g2 = 0.9 * resonance;

    // Noise paths. The turbulence band follows tension: a tight orifice sprays
    // bright, a loose one bubbles dark.
    const turb_lo_hz = std.math.clamp(900.0 * powF(tension, 0.8), 250.0, 2500.0);
    const a_turb_lo = onePole(turb_lo_hz);
    const a_turb_hi = onePole(@min(3.5 * turb_lo_hz, 9000.0));
    const a_hiss = onePole(700.0);
    const a_splat = onePole(1900.0);
    const a_low = onePole(400.0);
    const splat_level = 0.9 * (1.0 + 1.5 * burst);
    const turb_level = 2.2 * turbulence * p.noise_mix;
    const hiss_level = 0.30 * p.noise_mix;

    const wobble_phase: f32 = r.float(f32) * tau;
    const wobble_hz: f32 = p.wobble_hz * (0.9 + 0.2 * r.float(f32));

    // f64 phase: a pulse train is a discrete thing, and a last-ULP wobble in
    // f32 could move a flap by a sample between optimization modes.
    var phase: f64 = 0;
    var rate_mul: f32 = 1.0;
    var cycle_amp: f32 = 1.0;
    var lp_low: f32 = 0;
    var lp_hiss: f32 = 0;
    var lp_splat: f32 = 0;
    var lp_turb_lo: f32 = 0;
    var lp_turb_hi: f32 = 0;
    var dc_x1: f32 = 0;
    var dc_y1: f32 = 0;

    for (0..n) |i| {
        const fi: f32 = @floatFromInt(i);
        const t = fi * dt;
        const u = fi * inv_n;
        const wn_a = r.float(f32) * 2.0 - 1.0;
        const wn_b = r.float(f32) * 2.0 - 1.0;
        const rj = r.float(f32);
        const rk = r.float(f32);

        // Reservoir pressure, the plosive burst on top, and how far past
        // "running out" the flap has sagged.
        const drain = expF(-drain_k * u);
        const sag = std.math.clamp((0.45 - drain) / 0.45, 0.0, 1.0);
        const burst_env = burst * expF(-t / burst_s);
        const ramp = @min(1.0, t / p.attack_s);
        const p_amp = @sqrt(pressure) * powF(drain, 0.65) * (1.0 + burst_env) * ramp;
        const p_turb = powF(pressure, 0.8) * powF(drain, 0.9) * (1.0 + 0.6 * burst_env) * ramp;

        // Flutter wobble (amplitude and a little pitch) and the onset trill.
        const wob_s = sinF(tau * wobble_hz * t + wobble_phase);
        const wob = 1.0 - p.wobble_depth * 0.6 * (0.5 + 0.5 * wob_s);
        const trill = 1.0 - trill_depth * expF(-t / 0.08) * (0.5 + 0.5 * sinF(tau * 26.0 * t));

        // Flap rate: exponential pitch decay following the reservoir, kicked
        // by the burst, warbled by the wobble.
        const f = @max(18.0, p.f0 * pitch_mul * pitchSag(glide, drain) * (1.0 + 0.3 * burst_env) * (1.0 + 0.04 * p.wobble_depth * wob_s));
        phase += @as(f64, f * rate_mul * dt);
        if (phase >= 1.0) {
            phase -= 1.0;
            // A new flap: its period and height wander more the looser the
            // sphincter and the emptier the reservoir, and once the pressure
            // sags the flap may fail to open at all.
            const jitter_amt = 0.03 * looseness + 0.22 * sag;
            rate_mul = 1.0 + jitter_amt * (rj * 2.0 - 1.0);
            const shimmer_amt = 0.08 * looseness + 0.5 * sag;
            cycle_amp = 1.0 + shimmer_amt * (rk * 2.0 - 1.0);
            const p_drop = 0.55 * sag * looseness;
            if (rj < p_drop) cycle_amp *= 0.12;
        }
        const fl = flap(@floatCast(phase), oq);

        // Excitation: the bright radiated derivative over the fat low body.
        lp_low += a_low * ((fl.flow - flow_mean) - lp_low);
        const exc = (0.5 * fl.dflow + 1.0 * lp_low) * p_amp * cycle_amp;

        // Turbulence: noise sprayed through the open flap.
        lp_turb_lo += a_turb_lo * (wn_a - lp_turb_lo);
        lp_turb_hi += a_turb_hi * ((wn_a - lp_turb_lo) - lp_turb_hi);
        const gate = 0.25 + 0.75 * fl.flow;
        const turb = lp_turb_hi * gate * turb_level * p_turb * (0.5 + 0.5 * cycle_amp);

        // The onset splat and the soft body hiss.
        lp_hiss += a_hiss * (wn_a - lp_hiss);
        lp_splat += a_splat * (wn_b - lp_splat);
        const hiss = lp_hiss * hiss_level * p_turb;
        const splat = lp_splat * splat_level * p.noise_mix * expF(-t / 0.045) * ramp;

        // Tract: the excitation and most of the turbulence pass through the
        // two formants; the splat and hiss are already past the orifice.
        const tract_in = exc + 0.6 * turb;
        const mix = tract_in + g1 * res1.run(tract_in) + g2 * res2.run(tract_in) + 0.4 * turb + hiss + splat;

        // DC block, then the saturator that glues it: unity at small signals,
        // a soft ceiling above. The mix is padded down first so only the
        // loud flaps and the plosive bursts lean on it — a fart should be
        // fat, not flat.
        const dc = mix - dc_x1 + 0.995 * dc_y1;
        dc_x1 = mix;
        dc_y1 = dc;
        const drive: f32 = 1.4;
        const sat = std.math.tanh(dc * 0.7 * drive) / drive;

        // Output gate: the attack reaches exactly 0 at sample 0 and the tail
        // reaches exactly 0 at the last sample, both after the filters.
        const gate_att = @min(1.0, t / (0.5 * p.attack_s));
        const tail = @min(1.0, (1.0 - u) / TAIL_FADE);
        var x = sat * gate_att * tail * tail * wob * trill * p.level;
        if (x > 0.95) x = 0.95;
        if (x < -0.95) x = -0.95;
        out[i] = @intFromFloat(@round(x * 32767.0));
    }
}

/// One syllable's `VoiceParams` from its onset spec, base pitch, reservoir
/// pressure and tract. The spec's onset factors land on the physical fields;
/// the knobs multiply them afterwards in `renderSyllableWithReservoir`.
fn paramsFromSpec(spec: VoiceSpec, f0: f32, pressure: f32, formants: Formants) VoiceParams {
    return .{
        .f0 = f0,
        .attack_s = spec.attack_s,
        .noise_mix = spec.noise_mix,
        .wobble_hz = spec.wobble_hz,
        .wobble_depth = spec.wobble_depth,
        .level = spec.level,
        .glide = PITCH_DROP,
        .pressure = pressure,
        .tension = spec.tension,
        .turbulence = spec.turbulence,
        .burst = spec.burst,
        .burst_s = spec.burst_s,
        .trill = spec.trill,
        .formants = formants,
    };
}

/// The phrase's shared gas reservoir. Every syllable drains it a little, a
/// word gap is a breath that tops it back up, and it never runs lower than
/// `floor` so a long sentence still ends audibly.
const RESERVOIR_DRAIN: f32 = 0.92;
const RESERVOIR_FLOOR: f32 = 0.70;
const RESERVOIR_BREATH: f32 = 0.15;
/// The stressed syllable pushes harder as well as louder.
const STRESS_PRESSURE_BOOST: f32 = 1.12;

fn renderSyllableInto(out: []i16, syl: *const Syll, stressed: bool, prng: *std.Random.DefaultPrng, knobs: VoiceKnobs) void {
    renderSyllableWithReservoir(out, syl, stressed, prng, knobs, 1.0);
}

/// `reservoir` is the phrase-level pressure left for this syllable (1.0 for a
/// full tank); it multiplies the `pressure` knob.
fn renderSyllableWithReservoir(out: []i16, syl: *const Syll, stressed: bool, prng: *std.Random.DefaultPrng, knobs: VoiceKnobs, reservoir: f32) void {
    const eff = knobs.effort();
    const pitch = knobs.pitchFactor();
    const phys = knobs.physical();
    var p: VoiceParams = undefined;
    if (syl.vowel == 0) {
        // Consonant-only tail: a short, weak leak through a neutral tract — a
        // "pff", not a buzz. The knobs reach this literal too, so `--voice
        // noise=0` means "no noise anywhere" rather than "no noise except on
        // the rare breath syllable".
        const spec = knobs.apply(.{ .attack_s = 0.006, .noise_mix = 0.85, .wobble_hz = 31.0, .wobble_depth = 0.30, .level = 0.65, .burst = 0.3, .burst_s = 0.02, .tension = 0.8, .turbulence = 1.8 });
        p = paramsFromSpec(spec, 88.0 * pitch, 0.55, vowelFormants(0));
        applyEffort(&p, eff);
    } else {
        const spec = knobs.apply(onsetSpec(syl.onset()));
        p = paramsFromSpec(spec, vowelBaseFreq(syl.vowel).? * pitch, 1.0, vowelFormants(syl.vowel));
        applyEffort(&p, eff);
        // Swahili stresses the penultimate syllable of a word. The emphasis
        // rides on effort (#15): a shout pushes it past the stock 1.2, and a
        // whisper flatlines it — a whispered word has no dynamic shape. It
        // also pushes harder, so the stressed syllable sits a little higher
        // and sprays a little more.
        if (stressed) {
            p.level *= stressBoost(eff);
            p.pressure *= STRESS_PRESSURE_BOOST;
        }
    }
    p.pressure *= phys.pressure * reservoir;
    p.tension *= phys.tension;
    p.resonance *= phys.resonance;
    p.turbulence *= phys.turbulence;
    p.glide *= phys.glide;
    // Per-syllable jitter, still a pure function of (phrase, syllable index):
    // no two syllables are the same fart.
    const r = prng.random();
    p.f0 *= 1.0 + (r.float(f32) - 0.5) * 0.06;
    p.wobble_hz += (r.float(f32) - 0.5) * 3.0;
    p.tension *= 1.0 + (r.float(f32) - 0.5) * 0.24;
    p.pressure *= 1.0 + (r.float(f32) - 0.5) * 0.20;
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
    first_in_word: bool = false, // the reservoir takes a breath before it
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
            buf[nitems] = .{ .syl = syl, .start = cursor, .len = len, .stressed = stressed, .first_in_word = emitted == 0 };
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
    // One tank of gas for the whole phrase: the first syllable gets the
    // biggest blast, each one after it a little less, and a word gap is a
    // breath that tops it back up.
    var reservoir: f32 = 1.0;
    for (plan.items, 0..) |item, k| {
        if (k != 0 and item.first_in_word) reservoir = @min(1.0, reservoir + RESERVOIR_BREATH);
        renderSyllableWithReservoir(samples[item.start..][0..item.len], &item.syl, item.stressed, &prng, knobs, reservoir);
        reservoir = @max(RESERVOIR_FLOOR, reservoir * RESERVOIR_DRAIN);
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
/// physical knobs multiply a per-segment random physique (a different gut,
/// sphincter and tract for every seed), so one seed is a tight dry squeak and
/// the next a loose wet rumble.
pub fn renderShuziWavWith(allocator: std.mem.Allocator, seed: u64, knobs: VoiceKnobs) ![]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const n_syl: usize = 1 + r.uintLessThan(usize, 3);
    const Seg = struct { params: VoiceParams, len: usize, gap_after: usize };
    var segs: [3]Seg = undefined;
    var total: usize = 0;
    const eff = knobs.effort();
    const phys = knobs.physical();
    // First pass draws the structure — timing, class, base pitch, wobble —
    // in the order it always has, so a seed keeps the rhythm and register a
    // `[map] noteN = shuzi:<seed>` binding was chosen for. The physique is
    // drawn afterwards.
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
                // the shuzi is splattier than a spoken syllable of the same
                // class; the clamp is the class table's
                .noise_mix = std.math.clamp((spec.noise_mix + 0.10) * eff, 0.0, VoiceKnobs.max_noise_mix),
                .wobble_hz = 24.0 + 10.0 * r.float(f32),
                .wobble_depth = 0.45 + 0.15 * r.float(f32),
                .level = 1.0 * eff,
                .glide = PITCH_DROP * phys.glide,
                .tension = spec.tension,
                .turbulence = spec.turbulence,
                .burst = spec.burst,
                .burst_s = spec.burst_s,
            },
            .len = dur_ms * SAMPLE_RATE / 1000,
            .gap_after = gap_ms * SAMPLE_RATE / 1000,
        };
        total += segs[i].len + segs[i].gap_after;
    }
    // One body per shuzi — gut, sphincter and tract — with each segment
    // varying around it.
    const body_tension = 0.6 + 0.9 * r.float(f32);
    const body_resonance = 0.7 + 0.9 * r.float(f32);
    const f1 = 300.0 + 450.0 * r.float(f32);
    const f2 = f1 * (1.6 + 1.0 * r.float(f32));
    for (segs[0..n_syl]) |*seg| {
        seg.params.pressure = (0.7 + 0.8 * r.float(f32)) * phys.pressure;
        seg.params.tension *= body_tension * (0.9 + 0.2 * r.float(f32)) * phys.tension;
        seg.params.resonance = body_resonance * phys.resonance;
        seg.params.turbulence *= (0.6 + 1.0 * r.float(f32)) * phys.turbulence;
        seg.params.burst *= 0.5 + 1.0 * r.float(f32);
        seg.params.trill = if (r.uintLessThan(usize, 4) == 0) 0.6 else 0.0;
        seg.params.formants = .{ .f1 = f1, .f2 = f2 };
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
// the physical model: pressure, tension, resonance, turbulence, glide
// --------------------------------------------------------------------------

test "physical knobs parse, default to the identity and clamp into range" {
    const all = try parseKnobs("pressure=2, tension=0.5, resonance=3, turbulence=0, glide=1.5");
    try testing.expectEqual(@as(f32, 2.0), all.pressure);
    try testing.expectEqual(@as(f32, 0.5), all.tension);
    try testing.expectEqual(@as(f32, 3.0), all.resonance);
    try testing.expectEqual(@as(f32, 0.0), all.turbulence);
    try testing.expectEqual(@as(f32, 1.5), all.glide);
    // the historical axes are untouched by a physical spec
    try testing.expectEqual(@as(f32, 1.0), all.attack);
    try testing.expectEqual(@as(f32, 0.0), all.cents);

    const partial = try parseKnobs("noise=0.5");
    try testing.expectEqual(@as(f32, 1.0), partial.pressure);
    try testing.expectEqual(@as(f32, 1.0), partial.tension);
    try testing.expectEqual(@as(f32, 1.0), partial.resonance);
    try testing.expectEqual(@as(f32, 1.0), partial.turbulence);
    try testing.expectEqual(@as(f32, 1.0), partial.glide);

    try testing.expectError(error.Negative, parseKnobs("pressure=-1"));
    try testing.expectError(error.NotFinite, parseKnobs("tension=inf"));

    // the ranges the renderer applies
    const wild = (VoiceKnobs{ .pressure = 0, .tension = 1e9, .resonance = 0, .turbulence = 1e9, .glide = 99 }).physical();
    try testing.expectEqual(VoiceKnobs.min_pressure, wild.pressure);
    try testing.expectEqual(VoiceKnobs.max_tension, wild.tension);
    try testing.expectEqual(VoiceKnobs.min_resonance, wild.resonance);
    try testing.expectEqual(VoiceKnobs.max_turbulence, wild.turbulence);
    try testing.expectEqual(VoiceKnobs.max_glide, wild.glide);
    // 0 turbulence and 0 glide are meaningful, not clamped away
    const zero = (VoiceKnobs{ .turbulence = 0, .glide = 0 }).physical();
    try testing.expectEqual(@as(f32, 0.0), zero.turbulence);
    try testing.expectEqual(@as(f32, 0.0), zero.glide);
}

test "physical knobs: each axis changes the audio, both ways, and never NaNs" {
    const alloc = testing.allocator;
    const plain = try renderPhraseWav(alloc, "kujamba karibu");
    defer alloc.free(plain);

    const axes = [_]VoiceKnobs{
        .{ .pressure = 0.4 },    .{ .pressure = 3.0 },
        .{ .tension = 0.5 },     .{ .tension = 2.5 },
        .{ .resonance = 0.4 },   .{ .resonance = 3.0 },
        .{ .turbulence = 0.0 },  .{ .turbulence = 3.0 },
        .{ .glide = 0.0 },       .{ .glide = 2.0 },
        // the extremes together: the clamps keep it audio
        .{ .pressure = 1e9, .tension = 1e9, .resonance = 1e9, .turbulence = 1e9, .glide = 1e9 },
        .{ .pressure = 0, .tension = 0, .resonance = 0, .turbulence = 0, .glide = 0 },
    };
    for (axes) |knobs| {
        const out = try renderPhraseWavWith(alloc, "kujamba karibu", knobs);
        defer alloc.free(out);
        try testing.expectEqual(plain.len, out.len); // the plan does not move
        try testing.expect(!std.mem.eql(u8, plain, out));
        try expectNotSilence(out);
        // the same knobs twice are the same bytes
        const again = try renderPhraseWavWith(alloc, "kujamba karibu", knobs);
        defer alloc.free(again);
        try testing.expectEqualSlices(u8, out, again);
    }

    // and the shuzi path hears them too
    const shuzi = try renderShuziWav(alloc, 42);
    defer alloc.free(shuzi);
    const loose = try renderShuziWavWith(alloc, 42, .{ .tension = 0.5 });
    defer alloc.free(loose);
    try testing.expectEqual(shuzi.len, loose.len);
    try testing.expect(!std.mem.eql(u8, shuzi, loose));
    try expectNotSilence(loose);
}

test "the reservoir drains exponentially and the pitch sags with it" {
    // the defining property of an exponential: equal steps in u multiply the
    // pressure by the same factor
    const p: f32 = 1.0;
    const r0 = reservoirAt(p, 0.0);
    const r1 = reservoirAt(p, 0.25);
    const r2 = reservoirAt(p, 0.5);
    const r3 = reservoirAt(p, 1.0);
    try testing.expectEqual(@as(f32, 1.0), r0);
    try testing.expectApproxEqRel(r1 / r0, r2 / r1, 1e-5);
    try testing.expectApproxEqRel(r2 * r2, r3 * r0, 1e-5);
    // stock: ~11% left at the end; more gas drains slower, less faster
    try testing.expectApproxEqAbs(@as(f32, 0.111), r3, 0.002);
    try testing.expect(reservoirAt(4.0, 1.0) > r3);
    try testing.expect(reservoirAt(0.25, 1.0) < r3);

    // the pitch rides the pressure: glide=0 is an exact identity, the stock
    // 0.4 loses 40% of the drop the reservoir takes, and it is front-loaded —
    // the first quarter of the syllable carries more of the pitch drop than
    // the last half does, which a linear glide never would
    try testing.expectEqual(@as(f32, 1.0), pitchSag(0.0, r2));
    try testing.expectApproxEqAbs(@as(f32, 1.0 - 0.4 * (1.0 - 0.111)), pitchSag(0.4, r3), 0.002);
    const first_quarter = pitchSag(0.4, r0) - pitchSag(0.4, r1);
    const last_half = pitchSag(0.4, r2) - pitchSag(0.4, r3);
    try testing.expect(first_quarter > last_half);
}

/// Median interval between flap closures (the deep negative spikes) within
/// `samples`, in samples. The threshold is relative to this window's own
/// peak, because the flaps are much quieter late in a syllable than early.
fn medianFlapPeriod(samples: []const i16) f64 {
    var peak: i32 = 0;
    for (samples) |v| peak = @max(peak, @as(i32, v) * @as(i32, if (v < 0) -1 else 1));
    const thr: i32 = -@divTrunc(peak * 45, 100);
    var spikes: [64]usize = undefined;
    var n: usize = 0;
    var armed = true;
    for (samples, 0..) |v, i| {
        if (armed and v < thr) {
            if (n < spikes.len) {
                spikes[n] = i;
                n += 1;
            }
            armed = false;
        } else if (v > @divTrunc(thr, 3)) armed = true;
    }
    if (n < 2) return 0;
    var iv: [63]f64 = undefined;
    for (spikes[1..n], spikes[0 .. n - 1], 0..) |b, a, k| iv[k] = @floatFromInt(b - a);
    std.mem.sort(f64, iv[0 .. n - 1], {}, std.sort.asc(f64));
    return iv[(n - 1) / 2];
}

test "rendered flaps slow down as the syllable drains, and glide=0 holds them" {
    const alloc = testing.allocator;
    // a clean render (no noise, no wobble) so the closures stand out; the
    // last third is left alone, that is where the sputter lives
    const clean = VoiceKnobs{ .noise = 0, .wobble = 0, .turbulence = 0 };
    const sagging = try renderPhraseSamplesWith(alloc, "a", clean);
    defer alloc.free(sagging);
    var flat_knobs = clean;
    flat_knobs.glide = 0;
    const flat = try renderPhraseSamplesWith(alloc, "a", flat_knobs);
    defer alloc.free(flat);

    const n = sagging.len;
    const sag_first = medianFlapPeriod(sagging[0 .. n / 3]);
    const sag_second = medianFlapPeriod(sagging[n / 3 .. 2 * n / 3]);
    const flat_first = medianFlapPeriod(flat[0 .. n / 3]);
    const flat_second = medianFlapPeriod(flat[n / 3 .. 2 * n / 3]);
    try testing.expect(sag_first > 0 and sag_second > 0 and flat_first > 0 and flat_second > 0);

    // stock: the mid-syllable flaps are well over 10% further apart
    try testing.expect(sag_second > sag_first * 1.10);
    // glide=0: within the per-flap jitter either way
    try testing.expect(flat_second < flat_first * 1.08);
    try testing.expect(flat_first < flat_second * 1.08);
}

fn zeroCrossings(samples: []const i16) usize {
    var zc: usize = 0;
    for (samples[1..], samples[0 .. samples.len - 1]) |a, b| {
        if ((a >= 0) != (b >= 0)) zc += 1;
    }
    return zc;
}

test "tension and turbulence move the texture where the ear expects" {
    const alloc = testing.allocator;
    const stock = try renderPhraseSamplesWith(alloc, "kujamba karibu", .{});
    defer alloc.free(stock);
    // tight = narrow bright flaps and a high spray band: far more zero
    // crossings; loose = wide round flaps and dark bubbling: far fewer
    const tight = try renderPhraseSamplesWith(alloc, "kujamba karibu", .{ .tension = 2.5 });
    defer alloc.free(tight);
    const loose = try renderPhraseSamplesWith(alloc, "kujamba karibu", .{ .tension = 0.5 });
    defer alloc.free(loose);
    try testing.expect(zeroCrossings(tight) > zeroCrossings(stock) * 5 / 4);
    try testing.expect(zeroCrossings(loose) * 5 / 4 < zeroCrossings(stock));

    // turbulence is noise: it is the only thing that adds zero crossings
    // without touching the flap rate
    const dry = try renderPhraseSamplesWith(alloc, "kujamba karibu", .{ .turbulence = 0 });
    defer alloc.free(dry);
    const wet = try renderPhraseSamplesWith(alloc, "kujamba karibu", .{ .turbulence = 3 });
    defer alloc.free(wet);
    try testing.expect(zeroCrossings(dry) < zeroCrossings(stock));
    try testing.expect(zeroCrossings(wet) > zeroCrossings(stock) * 3 / 2);

    // pressure is level first: a leak is quieter than a blast
    const leak = try renderPhraseSamplesWith(alloc, "kujamba karibu", .{ .pressure = 0.4 });
    defer alloc.free(leak);
    const blast = try renderPhraseSamplesWith(alloc, "kujamba karibu", .{ .pressure = 3.0 });
    defer alloc.free(blast);
    try testing.expect(rmsOf(leak) < rmsOf(stock));
    try testing.expect(rmsOf(blast) > rmsOf(stock));
}

/// The onset's prominence: RMS of the first 15 ms over RMS of the 50-100 ms
/// body. A pressure burst stands tall here; a slow hum-in does not.
fn onsetProminence(alloc: std.mem.Allocator, syllable: []const u8) !f64 {
    const s = try renderPhraseSamplesWith(alloc, syllable, .{ .noise = 0, .wobble = 0 });
    defer alloc.free(s);
    const head = rmsOf(s[0 .. SAMPLE_RATE * 15 / 1000]);
    const body = rmsOf(s[SAMPLE_RATE * 50 / 1000 .. SAMPLE_RATE * 100 / 1000]);
    return head / body;
}

test "plosives are sudden pressure bursts: stops stand tall over their body" {
    const alloc = testing.allocator;
    // same vowel, same pitch, same length; only the onset differs
    const ka = try onsetProminence(alloc, "ka");
    const pa = try onsetProminence(alloc, "pa");
    const ba = try onsetProminence(alloc, "ba");
    const a = try onsetProminence(alloc, "a");
    const ma = try onsetProminence(alloc, "ma");
    const la = try onsetProminence(alloc, "la");
    // voiceless stops burst hardest, voiced stops next, and both beat the
    // bare vowel's small release; a nasal hums in and a liquid slides in
    try testing.expect(ka > 1.3 and pa > 1.3);
    try testing.expect(ka > ba and pa > ba);
    try testing.expect(ba > a * 1.05);
    try testing.expect(a > la);
    try testing.expect(ka > ma * 2.0);
    try testing.expect(ka > la * 1.3);
    // the table says the same thing the audio does
    try testing.expect(voiceSpec(.stop_voiceless).burst > voiceSpec(.stop_voiced).burst);
    try testing.expect(voiceSpec(.stop_voiced).burst > voiceSpec(.none).burst);
    try testing.expectEqual(@as(f32, 0.0), voiceSpec(.nasal).burst);
}

test "vowels pick different tracts: same onset, same pitch knob, different formants" {
    // the table itself
    try testing.expect(vowelFormants('i').f2 > vowelFormants('u').f2 * 2);
    try testing.expect(vowelFormants('a').f1 > vowelFormants('i').f1 * 2);
    // and at the byte level the tract alone separates two vowels pinned to the
    // same base pitch: transpose "u" (74 Hz) up to "i" (138 Hz) with cents and
    // the renders still differ, because the formants did not move with them
    const alloc = testing.allocator;
    const cents_u_to_i: f32 = 1200.0 * @log2(138.0 / 74.0);
    const u_as_i = try renderPhraseSamplesWith(alloc, "u", .{ .cents = cents_u_to_i, .noise = 0 });
    defer alloc.free(u_as_i);
    const i_plain = try renderPhraseSamplesWith(alloc, "i", .{ .noise = 0 });
    defer alloc.free(i_plain);
    try testing.expectEqual(u_as_i.len, i_plain.len);
    // "i" has the high F2: more zero crossings than the transposed "u"
    try testing.expect(zeroCrossings(i_plain) > zeroCrossings(u_as_i));
}

test "the phrase shares one reservoir: later syllables start with less gas" {
    const alloc = testing.allocator;
    // four identical unstressed syllables in four words: no stress, same
    // onset, same vowel — only the reservoir differs. The first word's
    // syllable is rendered from a full tank; the last from a drained one
    // topped up by breaths, which still sits below full.
    const samples = try renderPhraseSamplesWith(alloc, "ka ka ka ka", .{ .noise = 0, .wobble = 0 });
    defer alloc.free(samples);
    var plan = try planPhrase(alloc, "ka ka ka ka");
    defer plan.deinit(alloc);
    try testing.expectEqual(@as(usize, 4), plan.items.len);
    for (plan.items) |item| try testing.expect(item.first_in_word);
    const first = rmsOf(samples[plan.items[0].start..][0..plan.items[0].len]);
    const last = rmsOf(samples[plan.items[3].start..][0..plan.items[3].len]);
    try testing.expect(first > last);
}

test "onsetSpec: prenasalized stops burst, r rolls, ng' stays a nasal" {
    const mba = onsetSpec("mb");
    try testing.expect(mba.burst > 0);
    try testing.expect(mba.attack_s > voiceSpec(.stop_voiced).attack_s); // hums in first
    try testing.expectEqual(@as(f32, 0.0), onsetSpec("m").burst);
    try testing.expectEqual(@as(f32, 0.0), onsetSpec("ng'").burst);
    try testing.expectEqual(@as(f32, 0.0), onsetSpec("ny").burst);
    try testing.expect(onsetSpec("r").trill > 0);
    try testing.expectEqual(@as(f32, 0.0), onsetSpec("l").trill);
    try testing.expect(onsetSpec("sh").turbulence > onsetSpec("s").turbulence);
    try testing.expectEqual(voiceSpec(.none), onsetSpec(""));
}

test "every phoneme starts and ends on an exact zero, after the filters" {
    const alloc = testing.allocator;
    // the loop seam in ninjam_out depends on it, and the resonators ring past
    // their input, so the gate has to sit after them. Check it on the voiced
    // syllable, the 90 ms breath, a shuzi, and under knobs that ring longest.
    const phrases = [_][]const u8{ "a", "mtu", "ng'oma", "kujamba karibu" };
    for (phrases) |p| {
        const s = try renderPhraseSamplesWith(alloc, p, .{ .resonance = 4.0, .pressure = 4.0 });
        defer alloc.free(s);
        try testing.expectEqual(@as(i16, 0), s[0]);
        try testing.expectEqual(@as(i16, 0), s[s.len - 1]);
        var plan = try planPhrase(alloc, p);
        defer plan.deinit(alloc);
        for (plan.items) |item| {
            try testing.expectEqual(@as(i16, 0), s[item.start]);
            try testing.expectEqual(@as(i16, 0), s[item.start + item.len - 1]);
        }
    }
    const shuzi = try renderShuziWavWith(alloc, 7, .{ .resonance = 4.0, .intensity = 4.0 });
    defer alloc.free(shuzi);
    try testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, shuzi[44..46], .little));
    try testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, shuzi[shuzi.len - 2 ..][0..2], .little));
}
