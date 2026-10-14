---
title: Voice and phrasing
parent: guides/index
status: published
summary: Tune the voice, choose a bar pattern, and keep rests honest.
---

# Find your inner bassoon

The voice is a small physical model. Gas pressure builds up and drains away.
A sphincter valve flaps open and slaps shut once per cycle. The sound then
rings through the rectum and buttocks and is muffled by the trousers. Every
knob multiplies what the phrase already asks for: a "b" stays looser and
wetter than an "s" at any setting.

## Tune the voice

```bash
./zig-out/bin/kujamba render --phrase "kujamba karibu" --out shout.wav \
  --voice "intensity=2.5"
./zig-out/bin/kujamba render --phrase "kujamba karibu" --out low.wav \
  --voice "cents=-1200,noise=0.4,wobble=0.5"
./zig-out/bin/kujamba render --phrase "kujamba karibu" --out thunder.wav \
  --voice "pressure=2.5,tension=0.6,wetness=1.5"
./zig-out/bin/kujamba render --phrase "kujamba karibu" --out squeak.wav \
  --voice "pressure=0.6,tension=2.5"
```

| Knob | What it changes | Default |
|---|---|---|
| `pressure` | Intestinal pressure: louder, longer, harder bursts; low pressure sputters | `1` |
| `tension` | Sphincter tension: pitch (as √tension), buzzy/squeaky vs flabby | `1` |
| `tract` | Rectal/buttock resonance: 0 is a raw dry buzz, 3 honks and booms | `1` |
| `turbulence` | Rasp, spitting noise bursts, cycle-to-cycle jitter | `1` |
| `wetness` | Stick-slip splats, gurgling bubbles, sloppiness | `1` |
| `droop` | Depth of the exponential pitch fall as the gas runs out | `1` |
| `attack` | Multiplier on each onset's attack time | `1` |
| `noise` | Multiplier on the onset's noise: hiss, bursts, breath | `1` |
| `wobble` | Multiplier on flutter depth, not its rate | `1` |
| `intensity` | Effort: level, noise, push, and stress emphasis | `1` |
| `cents` | Vowel pitch offset; 100 cents is one semitone | `0` |
| `classic` | `1` selects the previous engine (v2), bit for bit | `0` |

Textures come from combinations rather than one knob each:

| Texture | Try |
|---|---|
| Thunderous | `pressure=2.5,tension=0.6` (high pressure through a loose valve) |
| Wet | `wetness=2.5,tension=0.8` |
| Dry and raspy | `wetness=0,turbulence=2.5,tension=1.4` |
| Squeaker | `pressure=0.6,tension=2.5` (tight valve, too little gas: it sputters) |
| Toy buzz | `turbulence=0,wetness=0,tract=0` |
| Deflating balloon | `droop=2.5` |

Pressure and tension are clamped to 0.25–4; tract, turbulence, wetness, and
droop to 0–4. Applied attack time is clamped to 0.5–200 ms; applied noise and
wobble depth are clamped to 0–1. Effort is clamped to 0.25–4 and pitch to
±1200 cents. These are effective synthesis bounds, not all bounds on the raw
multipliers. Silence and invalid floating-point audio are not useful presets.

`intensity=0.4` whispers; `intensity=2.5` shouts. Effort changes the penultimate
syllable's stress emphasis too. `cents=-1200` lowers vowels one octave but does
not transpose the randomly pitched, wordless shuzi rumble.

Defaults are an identity. A preset spelling out every default reproduces the
untuned voice in the same build. `classic=1` brings back the old buzzy
oscillator exactly; the physical knobs do nothing there.

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
