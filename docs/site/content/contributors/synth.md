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

One syllable combines asymmetric valve pulses, a bass fundamental and a wet
subharmonic. Intestinal pressure empties exponentially: pitch follows
`f0 * register * (0.48 + 0.80 * exp(-decay * u))`, where `u` runs from 0 to 1
and the register depends on pressure and sphincter tension. A short stop
release adds a temporary pressure/pitch surge.

A seeded 250 Hz control stream drives irregular flutter and short noise
bursts. Low tension alternates valve pulses and adds subharmonic body; high
tension narrows pulses and adds rasp. Two parallel bandpass biquads supply
vowel formants, a third supplies the terminal tract's bass cavity. DC removal,
a cosine release tail and smooth saturation keep boundaries quiet and peaks
bounded. Filter state is local to each syllable, never shared between renders.

A small parser groups Swahili vowels,
digraphs, and consonant onsets; it is not a general linguistic model.

## Vowel pitch

| Vowel | Base frequency |
|---|---|
| a | 92 Hz |
| e | 110 Hz |
| i | 138 Hz |
| o | 86 Hz |
| u | 74 Hz |

These are reference pitches, not fixed output pitches. Pressure, tension,
exponential decay and per-syllable seeded variation shape the actual pitch.

| Vowel | First formant | Second formant |
|---|---|---|
| a | 520 Hz | 1150 Hz |
| e | 410 Hz | 1650 Hz |
| i | 290 Hz | 2150 Hz |
| o | 360 Hz | 820 Hz |
| u | 250 Hz | 600 Hz |

`resonance` blends these filters into the unfiltered bass source, raises their
Q, and slightly lowers cavity/formant frequencies. At zero the tract is dry;
formant frequencies do not transpose with `cents`.

`cents` multiplies these by `2^(cents/1200)`. The breath tail's 88 Hz carrier
follows that shift. Shuzi has randomly selected pitch keyed by its seed.

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
Plosives additionally release stored pressure: `p` has the strongest pop,
`k/t/ch` a sharp crack, and `b/d/g/j` a softer release. The scanner retains
onset classes, but the release lookup examines the whole cluster, so `mb`
also gets a pressure burst.

## Timing

Voiced syllables last 240 ms, except a word's voiced penultimate syllable,
which is stressed and lasts 280 ms. Gaps last 40 ms within a word and 120 ms
between words. A rare consonant-only tail uses a shorter 90 ms duration.
Do not extrapolate the normal syllable formula to every tail case.

## Determinism has a boundary

Phrase text seeds the synthesis noise; the instrument's `--seed` instead keys
upload GUIDs and Ogg serials. The same build and inputs reproduce exact
bytes. LLVM floating-point transformations can change synthesized bytes
between Debug and ReleaseSafe or across platforms.

`src/golden.zig` therefore pins bit-stable windowed-energy fingerprints,
plus syllable/sample/peak/zero-crossing measurements, rather than making
a false universal WAV-hash promise. The live demo separately compares exact
Ogg upload hashes from two equal-input runs in one configuration.

Phrase ends are already zero. The measured loop-crossfade experiment made
the wrap worse; tests preserve that result instead of adding fashionable DSP.
