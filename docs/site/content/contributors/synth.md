---
title: Synth internals
parent: contributors/index
status: published
summary: Syllables, the physical fart model, timing, and measured determinism.
---

# Anatomy of a toot

`src/synth.zig` is pure Zig stdlib: no libc, file I/O, or device access.
It renders mono 44.1 kHz PCM; WAV output is 16-bit. The instrument converts
that synthesis into float samples for its shared phrase-to-bar path.

One syllable is one fart "phoneme", rendered by a small physical model (v3).
A small parser groups Swahili vowels, digraphs, and consonant onsets; it is
not a general linguistic model. The previous engine (v2: a buzzy additive
oscillator, an attack splat, and a fluttering decay) is still there, bit for
bit, behind `--voice classic=1`.

## The model

| Stage | What it does |
|---|---|
| Pressure reservoir | Opens at the release with a plosive spike, then decays exponentially. How much is left at the end depends on context: 34% for a stressed syllable, 26% normally, 14% word-final, 7% at the end of the phrase. |
| Sphincter valve | A pulse train, not a sine. Each cycle is decided at the flap: pitch is `f0 · P^(0.3·droop)`, so it falls exponentially with the gas. Below a tension-dependent threshold pressure the valve misses flaps (the sputter). |
| Valve texture | Wet valves stick shut and let go with a bigger flap and a splat (stick-slip), and burst bubbles. Tight valves under pressure alternate strong and weak flaps (period-doubling rasp). Turbulence adds flow-gated noise and random spitting bursts. |
| Terminal tract | Two vowel formants, a buttock "body" resonance near the 2nd–3rd harmonic, then the trousers' two-pole low-pass. |
| Output | DC block, a rational-tanh soft clip (loud flaps squash instead of clipping hard), 1 ms fade-in and 6 ms fade-out. |

"Thunder" is not a knob of its own. It emerges when pressure is high
relative to tension: it lowers the formants and the trousers' cutoff,
strengthens the body resonance, and deepens the gut's slow squeeze.

## Vowels

| Vowel | Base pitch | F1 / F2 | Valve |
|---|---|---|---|
| a | 92 Hz | 760 / 1250 Hz | open: more gas |
| e | 110 Hz | 500 / 1750 Hz | neutral |
| i | 138 Hz | 300 / 2200 Hz | tight: squeakier |
| o | 86 Hz | 520 / 880 Hz | loose, a little wet |
| u | 74 Hz | 330 / 760 Hz | loosest, wettest |

The formants are scaled down by 0.75 into the butt register. `cents`
multiplies the base pitch by `2^(cents/1200)`; consonant tension tunes it
further like a string (`√tension`). The breath tail uses an 88 Hz carrier and
a neutral cavity. A shuzi draws a random onset, vowel, and pitch from its seed.

## Consonant onsets

| Manner | Consonants | How the valve opens |
|---|---|---|
| Stop | p t k b d g | Closure, then a pressure spike, a band-passed pop, and a low thump. Voiceless stops get aspiration; voiced ones hum through the closure. |
| Affricate | ch j | A burst straight into a short hiss. |
| Fricative | f v s z sh th dh gh kh h | Hiss that the buzz grows out of. Voiceless fricatives hiss before the valve buzzes. |
| Nasal | m n ny ng' | Muffled hum, then the tract opens. |
| Trill | r | 27 Hz amplitude trill over the first 85 ms. |
| Lateral, glide | l, w y | A formant glide into the vowel. |

Place of articulation picks the noise band (labial low and wide, alveolar high
and narrow) and the formant transition. Prenasal clusters (mb nd ng nj nz)
add a hummed murmur. A trailing w or y (kwa, mbwa, mya) adds a closing glide.
Each onset also carries its own tension, pressure, wetness, and rasp; "b"
and "j" are juicy, "s" and "t" are dry. The v2 onset-class table (attack,
noise mix, wobble rate, level) still feeds the model, so the old knobs keep
their meaning. See [[guides/voice|the user-facing controls]].

## Timing

Voiced syllables last 240 ms, except a word's voiced penultimate syllable,
which is stressed and lasts 280 ms. Gaps last 40 ms within a word and 120 ms
between words. A rare consonant-only tail uses a shorter 90 ms duration.
Do not extrapolate the normal syllable formula to every tail case.

## Determinism

Phrase text seeds the synthesis noise; the instrument's `--seed` instead keys
upload GUIDs and Ogg serials. The same build and inputs reproduce exact
bytes. Every per-cycle and per-sample random draw happens whether it is used
or not, so a decision never shifts the random stream.

`@sin`, `@exp`, `@log`, and `std.math.pow` return different bits in Debug and
Release builds. v2 uses them, so its bytes move between optimization modes.
v3 uses its own polynomials built from exact IEEE operations instead, and its
WAV bytes were measured identical in Debug, ReleaseSafe, and ReleaseFast.

`src/golden.zig` still pins bit-stable windowed-energy fingerprints, plus
syllable/sample/peak/zero-crossing measurements, rather than making a
universal WAV-hash promise. It keeps two sets: the v3 default, and the
original v2 baseline rendered with `classic=1`. The live demo separately
compares exact Ogg upload hashes from two equal-input runs in one
configuration.

Phrase ends are already zero. The measured loop-crossfade experiment made
the wrap worse; tests preserve that result instead of adding fashionable DSP.
