---
title: Synth internals
parent: contributors/index
status: published
summary: Syllables, oscillator/noise envelopes, timing, and measured determinism.
---

# Anatomy of a toot

`src/synth.zig` is pure Zig stdlib: no libc, file I/O, or device access.
It renders mono 44.1 kHz PCM; WAV output is 16-bit. The instrument converts
that synthesis into float samples for its shared phrase-to-bar path.

One syllable combines a low buzzy oscillator whose pitch sags exponentially
with a decaying pressure envelope, a sub-harmonic thump, a noisy attack
splat, turbulence grains, and a fluttering decay, all colored by vowel
formant resonators. A small parser groups Swahili vowels, digraphs, and
consonant onsets; it is not a general linguistic model.

## Gut physics (#23)

Every syllable carries its own physical body (randomized per render from the
fixed seed), and four voice knobs multiply it:

| Axis | Knob | Range | What it does |
|---|---|---|---|
| Intestinal pressure | `pressure` | 0–4 | Level, burst strength, sub thump; slows the pitch sag |
| Sphincter tension | `tension` | 0.25–4 | Wet/flappy (loose) vs dry/raspy (tight); drives flutter rate |
| Terminal tract resonance | `tract` | 0–2 | Formant resonator mix: bare buzz to nasal honk |
| Noise-burst turbulence | `turbulence` | 0–4 | Grainy pop train over the body; also gates the buzz |

The pitch rides the pressure envelope down exponentially
(`f0 * (floor + (1-floor) * exp(-t/tau_p))`, `tau_p` growing with pressure),
so a fart starts at pitch and sags as the tank empties. The flutter rate
scales as `sqrt(pressure / tension)` — a tight, well-pressured opening
flutters faster (Berea-style). Tension also sets the noise-band cutoffs:
loose bodies boom (low flap band), tight ones hiss (bright splat band).

Turbulence is five seeded decaying grain pops per syllable (fixed prng draw
count whatever the knobs) through a noise band; the grain envelope also
roughens the carrier, so high turbulence reads as grit, not just hiss.

## Vowel pitch

| Vowel | Base frequency |
|---|---|
| a | 92 Hz |
| e | 110 Hz |
| i | 138 Hz |
| o | 86 Hz |
| u | 74 Hz |

`cents` multiplies these by `2^(cents/1200)`. The breath tail's 88 Hz carrier
follows that shift. Shuzi has randomly selected pitch keyed by its seed.

## Vowel formants and plosive bursts

Each vowel also gets classic adult-male formant targets (F1/F2/F3):

| Vowel | F1 | F2 | F3 |
|---|---|---|---|
| a | 730 | 1090 | 2440 |
| e | 530 | 1840 | 2480 |
| i | 270 | 2290 | 3010 |
| o | 570 | 840 | 2410 |
| u | 300 | 870 | 2240 |

Three constant-peak-gain bandpass biquads at those targets color the source;
the `tract` knob crossfades between the raw and resonated signal. This is
what makes an `a` and an `i` sound like different shapes of the same gas.

Plosive onsets release a sudden pressure burst (a fast-attack, pressure-
scaled decaying noise pop): labials p/b pop dark (800 Hz corner), dentals
t/d click mid (2400 Hz), velars k/g/ch/j crack bright (3200 Hz), fricatives
hiss rather than pop (small burst). The burst rides inside `noise`, so
`noise=0` is noise-free everywhere.

## Onset character

| Class | Typical consonants | Attack | Noise mix | Wobble rate |
|---|---|---|---|---|
| Voiceless stop | p t k ch | 4 ms | 0.40 | 32 Hz |
| Voiced stop | b d g j | 6 ms | 0.28 | 30 Hz |
| Fricative | s sh z f v th dh h gh | 10 ms | 0.50 | 29 Hz |
| Nasal | m n ng ny | 25 ms | 0.12 | 26 Hz |
| Liquid/glide | l r w y | 14 ms | 0.18 | 28 Hz |
| Bare vowel | none | 8 ms | 0.25 | 28 Hz |

Voice knobs scale those classes. Effort scales level/noise/stress; wobble
controls depth rather than rate. See [[guides/voice|the user-facing controls]].

## Timing

Voiced syllables last 240 ms, except a word's voiced penultimate syllable,
which is stressed and lasts 280 ms. Gaps last 40 ms within a word and 120 ms
between words. A rare consonant-only tail uses a shorter 90 ms duration.
Do not extrapolate the normal syllable formula to every tail case.

## Determinism has a boundary

Phrase text seeds the synthesis noise; the instrument's `--seed` instead keys
upload GUIDs and Ogg serials. The same build and inputs reproduce exact
bytes. The signal path is f64 precisely so last-ULP codegen differences
(Debug vs ReleaseSafe) cannot flip the i16 rounding: the two modes now
produce identical bytes on tested platforms. Cross-platform identity is
still not promised — pin fingerprints, not universal WAV hashes.

`src/golden.zig` therefore pins bit-stable windowed-energy fingerprints,
plus syllable/sample/peak/zero-crossing measurements, rather than making
a false universal WAV-hash promise. The live demo separately compares exact
Ogg upload hashes from two equal-input runs in one configuration.

Phrase ends are already zero. The measured loop-crossfade experiment made
the wrap worse; tests preserve that result instead of adding fashionable DSP.
