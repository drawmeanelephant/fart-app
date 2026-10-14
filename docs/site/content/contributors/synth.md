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

One syllable is a small physical model of the gut. Intestinal pressure vents
exponentially across the syllable and the pitch falls with it; a harmonic
buzz, tilted by sphincter tension, is colored by the terminal tract — two
formant resonators tuned by the vowel — plus a half-rate sub flutter for
weight. Filtered noise adds the attack splat, a quiet body hiss, and a train
of short noise bursts (turbulence) for wet, sputtering texture, all of it
through the sphincter aperture. Plosive onsets (p t k ch, b d g j) add a
sudden pressure burst: an amplitude punch and a pitch pop in the first
~16 ms. A small parser groups Swahili vowels, digraphs, and consonant onsets;
it is not a general linguistic model.

## Vowel pitch and tract

| Vowel | Base frequency | F1 | F2 |
|---|---|---|---|
| a | 92 Hz | 700 Hz | 1150 Hz |
| e | 110 Hz | 460 Hz | 1500 Hz |
| i | 138 Hz | 310 Hz | 1900 Hz |
| o | 86 Hz | 430 Hz | 820 Hz |
| u | 74 Hz | 320 Hz | 720 Hz |

`cents` multiplies the base frequencies by `2^(cents/1200)`. The breath tail's
88 Hz carrier follows that shift. Shuzi has randomly selected pitch keyed by
its seed. The formant pair is the vowel's terminal tract; the `resonance`
knob rings both resonators harder (higher Q).

## Onset character

| Class | Typical consonants | Attack | Noise mix | Wobble rate | Pressure | Tension | Resonance | Turbulence | Burst |
|---|---|---|---|---|---|---|---|---|---|
| Voiceless stop | p t k ch | 4 ms | 0.40 | 32 Hz | 1.15 | 1.25 | 0.90 | 0.55 | 1.0 |
| Voiced stop | b d g j | 6 ms | 0.28 | 30 Hz | 1.25 | 1.10 | 0.85 | 0.45 | 1.0 |
| Fricative | s sh z f v th dh h gh | 10 ms | 0.50 | 29 Hz | 0.90 | 1.45 | 0.80 | 0.70 | 0 |
| Nasal | m n ng ny | 25 ms | 0.12 | 26 Hz | 0.75 | 0.70 | 1.10 | 0.20 | 0 |
| Liquid/glide | l r w y | 14 ms | 0.18 | 28 Hz | 0.95 | 0.90 | 1.05 | 0.35 | 0 |
| Bare vowel | none | 8 ms | 0.25 | 28 Hz | 1.00 | 1.00 | 1.00 | 0.30 | 0 |

Voice knobs scale those classes: `pressure` multiplies the pressure column
(and with it the level, the turbulence and the burst), `tension` the tension
column, and so on. Effort scales level/noise/stress; wobble controls depth
rather than rate. See [[guides/voice|the user-facing controls]].

## Timing

Voiced syllables last 240 ms, except a word's voiced penultimate syllable,
which is stressed and lasts 280 ms. Gaps last 40 ms within a word and 120 ms
between words. A rare consonant-only tail uses a shorter 90 ms duration.
Do not extrapolate the normal syllable formula to every tail case.

## Determinism has a boundary

Phrase text seeds the synthesis noise; the instrument's `--seed` instead keys
upload GUIDs and Ogg serials. The same build and inputs reproduce exact
bytes.

The render path itself is pure IEEE arithmetic: sine comes from a comptime
table, `exp`/`log` from short polynomials, and every other operation is
exact or correctly rounded — no libm transcendentals, whose libm calls LLVM
inlines differently at different optimization levels. Synthesized bytes are
therefore bit-identical between Debug and ReleaseSafe on a given build, not
merely close.

`src/golden.zig` still pins bit-stable windowed-energy fingerprints, plus
syllable/sample/peak/zero-crossing measurements, as the guard against a
reseeded noise generator, a changed vowel table, or a moved envelope — and
as the cross-platform check, since the fingerprints are chosen to be exact
across optimization modes. The live demo separately compares exact Ogg
upload hashes from two equal-input runs in one configuration.

Phrase ends are already zero. The measured loop-crossfade experiment made
the wrap worse; tests preserve that result instead of adding fashionable DSP.
