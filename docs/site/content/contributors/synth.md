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

One syllable combines an uneven valve pulse with falling pitch, a noisy
pressure release, and a fluttering decay. A small parser groups Swahili vowels,
digraphs, and consonant onsets; it is not a general linguistic model.

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

## Pressure, valve and terminal tract

Reservoir pressure is `pressure * exp(-decay * normalized_time)`. Pitch follows
its square root towards a low floor, with tension setting the register.
Plosives add a separate 24 ms exponential pressure release: `p` is explosive,
`k/t/ch` sharp, `b` rounder, and `d/g/j` softer. Clusters such as `mb`, `mp`,
`nk` and `kw` retain the stop; fricative digraphs do not become plosives.

Each valve cycle has seeded timing/amplitude variation. Loose tension broadens
the pulse and adds subharmonic body; tight tension narrows it into a rasp.
Seeded, valve-gated noise clusters decay in 2.5–7.5 ms, rather than producing
a continuous white-noise wash. The existing noise knob controls every air layer.

Two constant-peak bandpass filters model vowel cavities, in parallel with a
115–180 Hz body resonance and the direct source:

| Vowel | First formant | Second formant |
|---|---|---|
| a | 620 Hz | 1120 Hz |
| e | 430 Hz | 1450 Hz |
| i | 290 Hz | 1850 Hz |
| o | 390 Hz | 760 Hz |
| u | 260 Hz | 570 Hz |

Tension scales these formants by `0.82 + 0.30 * tension`. Resonance increases
their prominence and ringing, without removing the low-end source. A DC
blocker and smooth saturation round the pressure slap. A quadratic final
release guarantees exact zero endpoints and preserves all phrase timing.
All filter state and randomness are local to the render, with no new allocation
in the sample loop, dependencies, I/O or libc.

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
bytes. LLVM floating-point transformations can change synthesized bytes
between Debug and ReleaseSafe or across platforms.

`src/golden.zig` therefore pins bit-stable windowed-energy fingerprints,
plus syllable/sample/peak/zero-crossing measurements, rather than making
a false universal WAV-hash promise. The live demo separately compares exact
Ogg upload hashes from two equal-input runs in one configuration.

Phrase ends are already zero. The measured loop-crossfade experiment made
the wrap worse; tests preserve that result instead of adding fashionable DSP.
