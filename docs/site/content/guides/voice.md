---
title: Voice and phrasing
parent: guides/index
status: published
summary: Tune the voice, choose a bar pattern, and keep rests honest.
---

# Find your inner bassoon

The voice is a buzzy oscillator driven by gut physics: a decaying intestinal
pressure that drags the pitch down with it, an attack splat, a fluttering
decay, and vowel-shaped tract resonance. Knobs scale the existing onset
classes and the physical axes rather than replacing their character.

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
| `pressure` | Intestinal pressure: loudness, thump, pitch sag | `1` |
| `tension` | Sphincter tension: wet/flappy vs dry/raspy | `1` |
| `tract` | Terminal tract resonance: vowel formant color | `1` |
| `turbulence` | Noise-burst grains: bubbly rasp over the body | `1` |

Applied attack time is clamped to 0.5–200 ms; applied noise and wobble depth
are clamped to 0–1. Effort is clamped to 0.25–4 and pitch to ±1200 cents.
Pressure is clamped to 0–4, tension to 0.25–4, tract to 0–2, and turbulence
to 0–4. These are effective synthesis bounds, not all bounds on the raw
multipliers. Silence and invalid floating-point audio are not useful presets.

`intensity=0.4` whispers; `intensity=2.5` shouts. Effort changes the penultimate
syllable's stress emphasis too. `cents=-1200` lowers vowels one octave but does
not transpose the randomly pitched, wordless shuzi rumble.

## Shape the body

The four physical axes multiply each syllable's own physics, so every phrase
has texture variety before a knob is touched. They combine into recognizable
characters:

| Preset | Voice string | Sound |
|---|---|---|
| Wet | `pressure=1.2,tension=0.5,turbulence=1.5` | Loose, flappy, bubbly |
| Dry | `pressure=1,tension=2.5,turbulence=0.3` | Tight, thin, clean |
| Raspy | `pressure=1.5,tension=2,turbulence=2.5` | Gritty, spitting, bright |
| Thunderous | `pressure=3,tension=1.2,tract=0.6` | Huge, boomy, sub-heavy |

`pressure` drives how hard the gas pushes: more pressure is louder, punches
harder plosive bursts, holds the pitch up longer before it sags (a real fart
drops in pitch as the tank empties), and deepens the sub-harmonic thump.
Zero is a weak forced-out pfft.

`tension` sets the opening. Low tension is wet and flappy — darker harmonics,
more low bubbling flap, deeper flutter. High tension is dry and raspy —
brighter harmonics, less flap, faster flutter.

`tract` is the terminal tract's resonance: the vowel's formant filters color
the gas. 0 is a bare unshaped buzz; 2 is a nasal honk where `i` and `u` are
clearly different shapes of the same fart.

`turbulence` is the train of grainy pops riding the body. 0 is smooth; 2+
is a bubbly wet rasp that also roughens the buzz itself.

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
The physical axes are the #23 "gut physics" model described there.
