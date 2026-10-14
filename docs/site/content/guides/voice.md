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
| `pressure` | Intestinal pressure: louder, higher onset pitch, harder plosive bursts, faster venting | `1` |
| `tension` | Sphincter tension: high is tight, squeaky and raspy; low is loose, flappy and sub-heavy | `1` |
| `resonance` | Terminal-tract resonance: how hard the vowel formants ring; 0 is a flat splat | `1` |
| `turbulence` | Sputtering noise bursts chopped by a slow random gate; 0 is a pure flutter tone | `1` |
| `wet` | Slow gurgle on amplitude and pitch plus a fatter hiss; 0 is dry | `1` |
| `drop` | Exponential pitch sag as pressure vents; 0 holds pitch, high dive-bombs | `1` |

Applied attack time is clamped to 0.5–200 ms; applied noise and wobble depth
are clamped to 0–1. Effort, pressure and tension are clamped to 0.25–4, pitch
to ±1200 cents, resonance/turbulence/wet to 0–3 and drop to 0–4.
These are effective synthesis bounds, not all bounds on the raw multipliers.
Silence and invalid floating-point audio are not useful presets.

`intensity=0.4` whispers; `intensity=2.5` shouts. Effort changes the penultimate
syllable's stress emphasis too. `cents=-1200` lowers vowels one octave but does
not transpose the randomly pitched, wordless shuzi rumble — the shuzi does get
a random physique per rumble, so `pressure`, `tension`, `wet` and friends
scale its range rather than pinning it.

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
