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

One syllable is one small physical model of a fart (`synthFart`). A small
parser groups Swahili vowels, digraphs, and consonant onsets; it is not a
general linguistic model. The pre-physics synth (a buzzy oscillator with a
linear 20% glide, a noisy attack splat, a fluttering decay) is still here as
`synthLegacyInto`, verbatim, behind `--voice legacy=1`.

## The physical model

Signal flow, per sample:

1. **Pressure.** `pn = pressure * exp(-1.7 * decay * u)` drains over the
   syllable (`u` is 0..1). Pitch follows a fast-then-slow exponential,
   `f = f_base * (1 - drop * shape(u))` with `shape = (1 - e^(-3.2u)) / (1 -
   e^-3.2)`, and `drop = 0.38 * decay`. Loudness falls as `exp(-0.75 * decay * u)`.
2. **Sphincter.** Two detuned `Flapper` lips emit `lipPulse` flow pulses
   (smooth opening, a closing as sharp as `tension` says). Each *cycle* draws
   its own period and strength (`jitter`, `shimmer`, odd-cycle weakening for
   period doubling, and a chance to drop the cycle) scaled by `rasp` and by how
   depleted the pressure is. Slow random "surges" and a pitch wander keep two
   syllables from sharing a contour.
3. **Turbulence.** White noise low-passed by the pressure, gated by the flow
   pulses, plus a steady band-passed leak that grows with `tension^2`.
4. **Tract.** The differentiated flow (plus turbulence), pre-emphasised, drives
   three zero-delay-feedback state-variable band-passes at the vowel's formants
   (`vowelFormants`) plus a ~140 Hz "boom" cavity (`vowelBoom`). `resonance`
   mixes the formants against the dry source.
5. **Wet.** Six `Bubble` voices: decaying sines that chirp up as they pop,
   spawned at a rate set by `wetness` and by depletion.
6. **Onset.** `onsetShape` maps the consonant to an `OnsetShape`: closure
   length, a noise crack through a band-pass (`burst`), a low "bwomp" thump
   (`thump`), a sustained hiss (`hiss`) and voicing fade-in, a trill, or a
   formant glide from `w`/`y`/`l`. Plosives are pressure bursts: the pressure
   spikes, the pitch jumps, and the crack and thump decay over a few tens of
   milliseconds.
7. **Output.** DC blocker, a rational soft limiter (`softClip`, 1 at |x| = 3),
   and `OUTPUT_GAIN`. The default phrase lands near -12 dBFS with peaks under
   the 31130 ceiling the tests assert.

`resolvePhys` turns the knobs, the onset and the stress into the `Phys` the
engine reads. Every knob is documented on `VoiceKnobs`; `knob_names` is the
single table behind `--voice` parsing and the `[voice]` config table.

Wordless shuzi farts pick an archetype (`archetypes`: thunderous, squeaker,
wet, raspy, dry), a vowel and an onset per syllable from a separate PRNG
stream, so the timeline draws stay as they were.

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
upload GUIDs and Ogg serials. The `seed` voice knob salts the phrase hash to
re-roll a fart. The same build and inputs reproduce exact bytes.

The physical model evaluates its own exp, sin and tan (`detExp`, `detSin`,
`detTan`) from `+ - * /`, `@round` and a bit cast, in f64. Those are IEEE-exact,
so its bytes are identical in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall.
The verbatim legacy engine still calls `@exp` and `@sin`, and LLVM
floating-point transformations can change *its* bytes between Debug and
ReleaseSafe or across platforms. Do not add a bare `@exp`/`@sin`/`@tan`/`pow`
to `synthFart`.

`src/golden.zig` therefore pins bit-stable windowed-energy fingerprints,
plus syllable/sample/peak/zero-crossing measurements, rather than making
a false universal WAV-hash promise. It carries the same inputs twice: the
default engine, and `(legacy)` rows for `legacy=1`. The live demo separately
compares exact Ogg upload hashes from two equal-input runs in one configuration.

Phrase ends are already zero. The measured loop-crossfade experiment made
the wrap worse; tests preserve that result instead of adding fashionable DSP.
