---
title: Voice and phrasing
parent: guides/index
status: published
summary: Tune the voice, choose a bar pattern, and keep rests honest.
---

# Find your inner bassoon

The voice is a pressure-driven valve, an attack splat, and a fluttering decay,
colored by vowel-shaped cavities. Onset knobs preserve the consonant classes;
physical controls move the sound from dry rasp to loose, wet thunder.

## Tune the voice

```bash
./zig-out/bin/kujamba render --phrase "kujamba karibu" --out shout.wav \
  --voice "intensity=2.5"
./zig-out/bin/kujamba render --phrase "kujamba karibu" --out low.wav \
  --voice "cents=-1200,noise=0.4,wobble=0.5"
```

| Knob | What it changes | Default |
|---|---|---|
| `attack` | Multiplier on each onset's attack time | `1` |
| `noise` | Master multiplier on air noise, including turbulence | `1` |
| `wobble` | Multiplier on flutter depth, not its rate | `1` |
| `intensity` | Effort: level, noise, and stress emphasis | `1` |
| `cents` | Vowel pitch offset; 100 cents is one semitone | `0` |
| `pressure` | Intestinal pressure, 0.25–3: fuller, harder release and higher initial pitch | `1` |
| `tension` | Sphincter tension, 0–1: loose, low flutter to tight, bright rasp | `0.5` |
| `resonance` | Terminal tract resonance, 0–1: dry/direct to hollow, wet vowel squelch | `0.65` |
| `turbulence` | Clustered noise bursts, 0–2: smooth air to sputtering crackle | `0.55` |
| `decay` | Pressure loss, 0–6 exponential time constants per syllable: sustained to diving pitch | `2.4` |

Applied attack time is clamped to 0.5–200 ms; applied noise and wobble depth
are clamped to 0–1. Effort is clamped to 0.25–4 and pitch to ±1200 cents.
These are effective synthesis bounds, not all bounds on the raw multipliers.
Silence and invalid floating-point audio are not useful presets.

`intensity=0.4` whispers; `intensity=2.5` shouts. Effort changes the penultimate
syllable's stress emphasis too. `cents=-1200` lowers vowels one octave but does
not transpose the randomly pitched, wordless shuzi rumble.

Defaults are an identity. A preset spelling out every default reproduces the
untuned voice in the same build.

All controls work in `--voice` and in a preset's `[voice]` table, for offline
rendering and headless NINJAM. Physical controls clamp to the ranges above;
negative or non-finite values are rejected. `turbulence=0` removes the extra
spits but keeps the consonant's attack noise; `noise=0` removes all air noise.
`resonance=0` removes the vowel cavities, leaving a dry source with bass body.
`decay=0` holds reservoir pressure, but plosive releases still decay quickly
and the amplitude still fades to silence at the end of each syllable.

```bash
# Loose, resonant, sputtering thunder
./zig-out/bin/kujamba render --phrase "pumba kubwa shuzi" --out thunder.wav \
  --voice "pressure=2.1,tension=0.18,resonance=0.9,turbulence=1.25,decay=3,cents=-350"
# Tight, dry rasp
./zig-out/bin/kujamba render --phrase "kiki paka" --out rasp.wav \
  --voice "pressure=1.3,tension=0.95,resonance=0.1,turbulence=0.7"
```

## Map a phrase onto bars

| Mode | On a play bar |
|---|---|
| `repeat` | Start at sample zero again |
| `loop` | Continue the cursor, wrapping at phrase end |
| `once` | Continue one pass, then output silence |

Rest bars freeze the cursor. `--pattern N` plays continuously in a pattern
of N play bars; `--pattern N+M` adds M rest bars. `3+1` is the room default;
offline render/play default to `1`.

```bash
./zig-out/bin/kujamba render --phrase "habari yako" --out pattern.wav \
  --play loop --pattern 3+1 --bars 4 --bar-ms 500
```

In an offline file, silence takes up the rest bar's duration. In a room, a
rest uses a NINJAM silence marker. Neither silently removes time.

The synth already reaches zero at both phrase ends. Do not add a loop
crossfade merely because another instrument has one: the measured blend
made this loop less seamless, and regression tests preserve that finding.

For the actual synthesis tables, see [[contributors/synth|Synth internals]].
