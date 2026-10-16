---
title: Fart-Off DSP & Acoustic Analysis
parent: contributors/fart-off
status: published
summary: Acoustic telemetry, DSP architecture breakdown, and tier ratings for all twelve Fart-Off synth engines.
---

<p class="eyebrow">Milestone M9 · <a href="https://github.com/drawmeanelephant/fart-app/issues/95">#95</a></p>

# Fart-Off DSP & Acoustic Analysis

Every entry in [[contributors/fart-off|The Great Fart-Off]] ships in the binary
under `src/engines/<slug>.zig` and is pinned by the regression guard in
`src/golden.zig`. This page breaks down the measured acoustic telemetry and
internal synthesis architectures across all twelve contestants.

## Acoustic & spectral telemetry

From the `src/golden.zig` fingerprints on **Baseline 1** (`"kujamba karibu"`)
and **Shuzi Seed 42**, each engine's default "house sound" separates into
distinct acoustic regimes (`zero_crossings` acts as a direct proxy for spectral
brightness/rasp vs. sub-bass weight, `peak` out of `32767` shows limiter
ceiling drive, and `rms_milli` measures overall acoustic fatness):

| Engine | Model | Peak (i16) | RMS (`rms_milli`) | Zero Crossings (`kujamba karibu`) | Zero Crossings (`shuzi 42`) | Acoustic Profile |
|---|---|---:|---:|---:|---:|---|
| `stock` | *(Pre-Fart-Off v2)* | 22,007 | 4,173,837 | 720 | 486 | Polite 4-harmonic buzz + linear 20% pitch drop |
| `sonnet` | Claude Sonnet 5.5 | 30,931 | 7,433,186 | 3,882 | 2,212 | Torn, wet, hyper-raspy dual-lip sputter (13.38M shuzi RMS) |
| `fable` | Claude Fable 5.1 | 27,573 | 6,350,278 | 3,670 | 3,336 | Crisp Rosenberg glottal-flap snap + shared phrase reservoir |
| `opus` | Claude Opus 5.5 | 28,183 | 6,529,839 | 992 | 596 | Biomechanical valve with stick-slip & Minnaert bubbles |
| `grok47` | Grok 4.7 | 27,751 | 4,715,630 | 2,294 | 1,094 | Dual-inharmonic sphincter chatter + slit friction |
| `mistral4` | Mistral Large 4 | 31,129 | 5,243,722 | 1,756 | 1,338 | 12-harmonic brassy trombone + 8-burst sputter train |
| `argon4` | Gemini 4 Argon | 29,986 | 7,630,818 | 540 | 376 | Heavy mucosal reed slap + dynamic wobbling SVF formants |
| `sol61` | GPT-6.1 Sol | 26,029 | 8,097,826 | 480 | 296 | Loudest baseline RMS; asymmetric power-valve + alternating sub-flaps |
| `astra` | GPT-6 Astra | 28,353 | 8,022,657 | 360 | 150 | Deepest chesty sub-thunder; cycle-triggered crackle spits |
| `kimi3` | Kimi K3 | 31,129 | 6,432,694 | 588 | 332 | Hard-clipping rectal pressure collapse + 11 Hz noise gate |
| `gutphysics` | MiMo Pro 2.6 (Codebuff) | 30,363 | 5,986,684 | 506 | 244 | Berea flutter physics (`sqrt(P/T)`) + 5 seeded grain pops |
| `swe2` | SWE-2 | 24,150 | 3,476,000 | 762 | 780 | Sub-heavy wallop (92% showcase energy < 100 Hz) + beating-sine gurgle |
| `gemini38` | Gemini 3.8 Flash | 18,975 | 2,568,370 | 796 | 648 | Quiet, polite baseline; wakes up when showcase knobs are cranked |

## Tier ratings & DSP breakdown

### S-Tier: Biomechanical physical models

#### 1. `opus` · Claude Opus 5.5 — 9.7 / 10 (Best Overall & Best Physical Model)

Opus wrote a full biomechanical valve simulation (`v3`) while keeping the
original `v2` engine bit-for-bit accessible behind `--voice classic=1`.

- **Phrase-level declination (`SylContext`):** Tracks where a syllable sits in
  its word and phrase (`stressed`, `word_final`, `phrase_final`, `position`), so
  the gas reservoir naturally depletes across a phrase and sputters out on the
  final syllable.
- **Stick-slip valve & phonation threshold (`p_th`):** The sphincter is a
  pulse-train valve that checks `p_now / p_th` on every flap. As pressure falls
  near threshold, cycles randomly misfire (`fire_p`). When `wet` is high, the
  valve sticks shut (`span = 1.3 + 1.0 * d1[2]`), piles up pressure, and
  releases with an extra-loud `boost` and a `NoiseBurst` splat.
- **Minnaert bubbles:** Spawns four concurrent `Bubble` voices whose sine
  frequency chirps upward as the bubble radius shrinks (`self.freq += self.rise`).
- **Full phonetic timeline:** Models prenasalized murmurs (`mb`, `nd`, `ng`),
  voiced-stop closure bars, place-of-articulation formant transitions, and a
  trousers low-pass filter (`a_lp`), all in bit-identical polynomial math.

#### 2. `sonnet` · Claude Sonnet 5.5 — 9.5 / 10 (Best Texture, Wetness & Showcase)

`sonnet` produces the most ragged, wet, biologically unstable sound in the
field (`3,882` zero crossings on baseline1 and `13.38M` RMS on `shuzi seed 42`).

- **Dual detuned sphincter lips (`Flapper`):** Models two separate sphincter
  lips (`fa` and `fb`, detuned by `1.0 + 0.017 + 0.012 * tension`) beating
  against each other. Every cycle draws Gaussian period jitter, amplitude
  shimmer, odd-cycle period-doubling (`sub`), and tail misfires (`drop_prob`).
- **Zero-delay-feedback (ZDF) SVFs:** Implements TPT/ZDF state-variable filters
  (`svfCoef` with `detTan`) updated every 16 samples (`CONTROL_PERIOD`), plus a
  6 dB/oct pre-emphasis differentiator (`FORMANT_EMPHASIS`) so F2/F3 vowel
  formants cut through clearly.
- **Six-voice bubble pool & voiced "bwomp" thump:** Spawns up to six upward-chirping
  bubbles and adds a saturated sub-bass pitch-dropping thump (`40 + 80 * e_thump` Hz)
  on voiced plosives (`b`, `d`, `g`).

#### 3. `fable` · Claude Fable 5.1 — 9.3 / 10 (Best Glottal Pulse & Shared Reservoir)

`fable` replaces the additive sine wave with a **Rosenberg glottal pulse**
(`flap(ph, oq)`) and separates the integrated flow (`fl.flow`, low-passed at
400 Hz for the fat low body) from the radiated flow derivative (`fl.dflow`,
which creates the sharp acoustic snap when the sphincter closes at 62%/38%
asymmetry).

- **Shared phrase gas reservoir:** A phrase shares one reservoir that drains
  across syllables inside a word and takes a partial breath between words.
- **Prenasalized & trilled onsets:** Parses Swahili prenasalized stops (`mba`,
  `nde`, `ngo` vs. velar `ng'`) so they hum in on the nasal and burst on the
  release, and gives `r` a 26 Hz onset trill over the first 80 ms.
- **Cephes deterministic math:** Uses quadrant-reduced Cephes polynomials
  (`sinCos`, `exp2F`, `log2F`) and `f64` phase accumulation for bit-identical
  renders across build modes.

### A-Tier: Heavyweight contenders & specialists

#### 4. `sol61` · GPT-6.1 Sol — 8.9 / 10 (Best "Chesty Thunder" Baseline)

`sol61` posts the highest baseline RMS in the competition (`8,097,826`),
delivering room-filling low-end weight with no flags required.

- **Power-shaped valve + alternating double-pulses:** Shapes the valve opening
  as `opening^(1.6 + 4.5 * tension)` multiplied by an alternating subharmonic
  (`1.0 - 0.48 * wet * (0.5 + 0.5 * sin(subphase))`), creating a wet
  double-slap on every other cycle.
- **250 Hz control-stream splat trigger:** Steps a seeded control stream at
  250 Hz that fires smoothed turbulence jets (`splat_smooth`) and irregular
  flutter modulation.

#### 5. `argon4` · Gemini 4 Argon — 8.8 / 10 (Best Dynamic Formant Squelch & Plosive Pops)

`argon4` models the terminal tract as a moving, wet cavity rather than a static
filter bank.

- **Wobbling SVF formants:** Modulates the F1, F2, and low-tract SVF cutoffs at
  audio rate using both the mucosal flutter LFO and a 2.35x faster `bubble_lfo`
  (`wet_mod`), producing a squelchy vowel filter sweep as pressure drops.
- **Dedicated plosive pop oscillator:** Maps every consonant (including
  prenasalized releases `mb`, `mp`, `nd`, `ng`, `nj`) to a `PlosiveSpec` with
  its own resonant `pop_freq_hz` (110 Hz for `b`, 135 Hz for `p`, 260 Hz for
  `k`, 310 Hz for `t`) and upward pitch spike.

#### 6. `astra` · GPT-6 Astra — 8.6 / 10 (Deepest Sub-Bass Rumble)

With only `360` zero crossings on baseline1 and `8.02M` RMS, `astra` is the
sub-bass specialist of the default baselines.

- **Half-sine duty-cycle valve:** Uses a tension-controlled open duty cycle
  (`open_width = 0.48 - 0.25 * tension`) where the valve follows
  `sin^2(pi * pos / w) - 0.5 * w` while open and seals shut otherwise.
- **Per-cycle crackle spits:** At each phase wrap (`phase >= tau`), rolls the
  PRNG for `cycle_jitter`, `cycle_level`, and a 58% chance to fire a decaying
  `crackle` cluster gated by the valve opening.

#### 7. `grok47` · Grok 4.7 — 8.5 / 10 (Best Slit Friction & Showcase Comedy)

Grok 4.7 pairs the funniest showcase phrase (`--phrase "po po po"`) with a
clever model of high-tension raspiness.

- **Dual-inharmonic chatter & slit friction:** Adds two inharmonic chatter
  oscillators (`chatter_hz` at 18–88 Hz and `chatter_hz2` at ~2.5x). When
  tension closes the aperture (`openness == 0`), high-frequency dry noise
  forces through the closed slit (`slit = tension * (1.0 - openness) * |c2|`).
- **Normalized 0..1 knobs:** Uses `0..1` amounts rather than `1.0`-centered
  multipliers (`pressure=0.72, tension=0.55` default).

### B-Tier: Punchy & musical, simpler source models

#### 8. `mistral4` · Mistral Large 4 — 8.1 / 10 (Best Brassy "Disappointed Trombone")

Expands the additive oscillator to **12 harmonics** tilted by
`intPower(0.8 + 0.45 * tension, k)` through constant-skirt-gain biquad formants
(`peak gain = Q`) and an 8-burst exponential turbulence train, all using a
4096-entry comptime sine table for cross-mode bit-exactness. Reads more like a
brassy bass-trombone raspberry than a chaotic biological valve.

#### 9. `gutphysics` · MiMo Pro 2.6 (Codebuff) — 7.8 / 10 (Cleanest Classic Extension)

Absorbed from PR #99, `gutphysics` runs an all-`f64` signal path, scales
flutter rate by Berea physics (`sqrt(pressure / tension)`), passes the source
through three parallel RBJ formant biquads (F1/F2/F3), and schedules five
discrete turbulence grain pops per syllable.

#### 10. `swe2` · SWE-2 — 7.6 / 10 (Sub-Octave Specialist, Quiet Baseline)

Uses sums of incommensurate low-frequency sinusoids (`gurgle_hz` at ~7 & ~13 Hz,
`sput_hz` at ~4, ~7.5 & ~11 Hz) for deterministic liquid gurgle AM/FM and
sputter gating, plus a 7 ms closure dip before a 14 ms 62 Hz plosive thump. A
`* 0.62` master trim keeps its baseline polite (`3.47M` RMS), though its
freestyle showcase puts 92% of its energy below 100 Hz.

#### 11. `kimi3` · Kimi K3 — 7.4 / 10 (Punchy Clipper, Minimalist Tract)

Features an effective 11 Hz one-pole stochastic sputter gate
(`clamp(lp_gate * 30.0 - 0.15, 0.0, 1.0)`) and drives a pressure-dependent soft
clipper into the `0.95` ceiling (`31,129` peak across all golden tests), but
models only a single formant frequency per vowel (`vowelFormantHz`) plus one
low SVF boom filter applied post-envelope.

#### 12. `gemini38` · Gemini 3.8 Flash — 6.8 / 10 (Polite Baseline, Strong Showcase)

Combines six harmonics, a sub-flap, quadratic/cubic waveshaping, and random
900–1500 Hz wet bubble pops (`wet_pop`). However, multiplying `turb_signal`,
`wet_pop`, and the final output by the decaying pressure envelope on top of the
main amplitude envelope double-attenuates the default voice (`peak = 18,975`,
`rms_milli = 2,568,370`), making its un-flagged baseline quieter than `stock`
until showcase knobs (`pressure=2.0, wetness=2.2, intensity=1.5`) are applied.

## Summary ballot (#95)

- **Baseline winner:** **`opus`** (or **`sonnet`** for a wetter, raspier
  default; **`sol61`** for pure chest-thumping loudness).
- **Showcase winner:** **`sonnet`**
  (`pressure=1.5,tension=0.7,boom=1.8,decay=1.2,wetness=1.8,rasp=1.4,turbulence=1.2`),
  with **`fable`** and **`grok47`** (`po po po`) as runners-up.
