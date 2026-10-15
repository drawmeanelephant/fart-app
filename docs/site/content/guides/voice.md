---
title: Voice and phrasing
parent: guides/index
status: published
summary: Tune the voice, choose a bar pattern, and keep rests honest.
---

# Find your inner bassoon

The voice is a buzzy oscillator, an attack splat, and a fluttering decay.
Knobs scale the existing onset classes rather than replacing their character.

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
| `noise` | Multiplier on attack noise mix | `1` |
| `wobble` | Multiplier on flutter depth, not its rate | `1` |
| `intensity` | Effort: level, noise, and stress emphasis | `1` |
| `cents` | Vowel pitch offset; 100 cents is one semitone | `0` |
| `pressure` | Intestinal pressure, 0..1. High is thunderous (fatter body, harder plosive); low is a thin leak | `0.72` |
| `tension` | Sphincter tension, 0..1. Low is a loose flutter; high is a raspy chatter | `0.55` |
| `resonance` | Terminal-tract resonance, 0..1. 0 bypasses the vowel cavity; 1 rings /a/ /i/ /u/ as different tubes | `0.62` |
| `turbulence` | Noise-burst turbulence, 0..1. Extra filtered bursts while pressure holds. 0 is a clean tone | `0.48` |
| `wetness` | Wet gurgle vs dry hiss, 0..1. Wet sits under 400 Hz; dry is a paper rasp | `0.40` |
| `decay` | Exponential pitch sag, 0..1. 0 keeps the old 20% linear glide; 1 drops about an octave as the tank empties | `0.62` |

Applied attack time is clamped to 0.5–200 ms; applied noise and wobble depth
are clamped to 0–1. Effort is clamped to 0.25–4 and pitch to ±1200 cents.
`pressure`, `tension`, `resonance`, `turbulence`, `wetness` and `decay` are
clamped to 0–1. They are amounts, not multipliers: spelling one of them does
not reset the others, and a value past 1 is the same gesture pinned at the rail.
These are effective synthesis bounds, not all bounds on the raw multipliers.
Silence and invalid floating-point audio are not useful presets.

`intensity=0.4` whispers; `intensity=2.5` shouts. Effort changes the penultimate
syllable's stress emphasis too. `cents=-1200` lowers vowels one octave but does
not transpose the randomly pitched, wordless shuzi rumble.

Defaults are an identity. A preset spelling out every default reproduces the
untuned voice in the same build.

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
