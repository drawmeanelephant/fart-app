---
title: Voice and phrasing
parent: guides/index
status: published
summary: Tune the voice, choose a bar pattern, and keep rests honest.
---

# Find your inner bassoon

The voice is a small physical model: intestinal pressure vents exponentially
across the syllable, a tension-tilted harmonic buzz is colored by a
two-formant terminal tract, and filtered noise adds the splat, the body hiss,
and a sputtering turbulence train. Knobs scale the existing onset classes
rather than replacing their character.

## Tune the voice

```bash
./zig-out/bin/kujamba render --phrase "kujamba karibu" --out shout.wav \
  --voice "intensity=2.5"
./zig-out/bin/kujamba render --phrase "kujamba karibu" --out low.wav \
  --voice "cents=-1200,noise=0.4,wobble=0.5"
./zig-out/bin/kujamba render --phrase "kujamba karibu" --out thunder.wav \
  --voice "pressure=1.3,tension=0.75,resonance=1.35,turbulence=1.8,decay=1.3"
```

| Knob | What it changes | Default |
|---|---|---|
| `attack` | Multiplier on each onset's attack time | `1` |
| `noise` | Multiplier on attack noise mix | `1` |
| `wobble` | Multiplier on flutter depth, not its rate | `1` |
| `intensity` | Effort: level, noise, and stress emphasis | `1` |
| `cents` | Vowel pitch offset; 100 cents is one semitone | `0` |
| `pressure` | Gut squeeze: level, pitch lift, sputter, plosive punch | `1` |
| `tension` | Sphincter tightness: buzz brightness, noise aperture | `1` |
| `resonance` | Terminal tract ring: formant Q and color | `1` |
| `decay` | Pitch-drop rate; 0 freezes the pitch flat | `1` |
| `turbulence` | Noise-burst sputter through the syllable | `1` |

Applied attack time is clamped to 0.5–200 ms; applied noise and wobble depth
are clamped to 0–1. Effort is clamped to 0.25–4 and pitch to ±1200 cents.
Pressure is clamped to 0.25–4, tension to 0–2, resonance to 0–3, the pitch
decay rate to 0–8, and turbulence to 0–4. These are effective synthesis
bounds, not all bounds on the raw multipliers. Silence and invalid
floating-point audio are not useful presets.

`intensity=0.4` whispers; `intensity=2.5` shouts. Effort changes the penultimate
syllable's stress emphasis too. `cents=-1200` lowers vowels one octave but does
not transpose the randomly pitched, wordless shuzi rumble.

The physical knobs shape texture rather than just level: `pressure` squeezes
the gut louder, sharper and sputterier (and lifts the pitch a little);
`tension=0.2` is loose and wet, `tension=1.8` tight and raspy; `resonance`
rings the tract — low is dry and flat, high is boomy; `decay=2` drops the
pitch hard as the pressure vents, `decay=0` holds it flat; `turbulence=3`
sputters noise bursts through the body of the syllable, `turbulence=0` is a
clean toot.

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
