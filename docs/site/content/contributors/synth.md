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

One syllable combines a soft-clipped buzzy oscillator with a sub-octave belly,
a noisy attack splat, and a fluttering decay. The pitch sags *exponentially*
as the vent pressure collapses, and the flutter rate drifts slowly so it reads
as muscle rather than an LFO. A small parser groups Swahili vowels, digraphs,
and consonant onsets; it is not a general linguistic model.

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

## Tract formants

| Vowel | Formant 1 | Formant 2 |
|---|---|---|
| a | 380 Hz | 980 Hz |
| e | 340 Hz | 1500 Hz |
| i | 280 Hz | 1900 Hz |
| o | 340 Hz | 760 Hz |
| u | 260 Hz | 620 Hz |

Each vowel rings two resonant bandpasses (Chamberlin SVFs) on the dry mix —
the terminal tract. `resonance` scales their gain and sharpness; `0` removes
the coloration entirely. Breath tails get a neutral 300/900 Hz pair, and a
wordless shuzi picks a random vowel's tract per rumble. Per-syllable jitter
detunes each pair a few percent so repeats do not sound stamped.

## Onset character

| Class | Typical consonants | Attack | Noise mix | Wobble rate | Plosive |
|---|---|---|---|---|---|
| Voiceless stop | p t k ch | 4 ms | 0.40 | 32 Hz | 1.00 |
| Voiced stop | b d g j | 6 ms | 0.28 | 30 Hz | 0.75 |
| Fricative | s sh z f v th dh h gh | 10 ms | 0.50 | 29 Hz | 0 |
| Nasal | m n ng ny | 25 ms | 0.12 | 26 Hz | 0 |
| Liquid/glide | l r w y | 14 ms | 0.18 | 28 Hz | 0 |
| Bare vowel | none | 8 ms | 0.25 | 28 Hz | 0 |

Voice knobs scale those classes. Effort scales level/noise/stress; wobble
controls depth rather than rate. A stop onset seals the tract for ~7 ms
(a dip in the buzz), then releases a ~14 ms burst of click plus 62 Hz thump;
`pressure` makes that release hit harder. See [[guides/voice|the user-facing controls]].

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
