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

One syllable combines a low buzzy oscillator with falling pitch, a noisy
attack splat, and a fluttering decay. A small parser groups Swahili vowels,
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
