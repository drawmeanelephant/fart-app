---
title: Voice and phrasing
parent: guides/index
status: published
summary: Tune the voice, choose a bar pattern, and keep rests honest.
---

# Find your inner bassoon

The voice is a small physical model of a fart. Gas pressure drains
exponentially, so the pitch falls fast and then settles. The pressure forces a
pair of sphincter lips into a ragged, nearly periodic flap. The flow rings a
terminal cavity whose formants come from the syllable's vowel. The consonant
decides how the fart starts: a `k` is a pressure crack, a `b` a wet thump, an
`s` a thin hiss, an `r` a rolled raspberry. Knobs scale that physical state;
they never replace it.

## Tune the voice

```bash
./zig-out/bin/kujamba render --phrase "kujamba karibu" --out shout.wav \
  --voice "intensity=2.5"
./zig-out/bin/kujamba render --phrase "kujamba karibu" --out low.wav \
  --voice "cents=-1200,noise=0.4,wobble=0.5"
./zig-out/bin/kujamba render --phrase "kujamba karibu" --out thunder.wav \
  --voice "pressure=1.6,tension=0.6,boom=2.2,decay=0.7"
```

### Physical axes

| Knob | Physical meaning | What you hear | Default |
|---|---|---|---|
| `pressure` | Intestinal pressure | Louder, higher start, stays clean longer; low is a timid squeak-and-putter. Clamped 0.1–3 | `1` |
| `tension` | Sphincter tension | Higher pitch, narrower pulses, more hiss and higher formants; slack is a deep loose flap. Clamped 0–3 | `1` |
| `resonance` | Terminal tract resonance | Mix of the vowel's three formant filters against the dry buzz; 0 is bare, 3 rings. Clamped 0–3 | `1` |
| `turbulence` | Noise-burst turbulence | Pulse-gated air noise plus a steady leak; tails get hissier. Clamped 0–4 | `1` |
| `wetness` | Bubbles and pulse dropouts | Gurgling chirps (150–1000 Hz) and a spluttering tail; 0 is dry. Clamped 0–4 | `1` |
| `rasp` | Sphincter instability | Period jitter, shimmer, period doubling; 0 is a steady synthetic buzz. Clamped 0–4 | `1` |
| `decay` | Exponential pitch decay | How far the pitch sags as pressure drains; 0 holds it flat. Clamped 0–3 | `1` |
| `burst` | Plosive pressure burst | Crack, pitch spike and voiced "bwomp" on p t k b d g j ch; 0 softens them. Clamped 0–4 | `1` |
| `boom` | Low cavity resonance | Chest-thumping ~100–150 Hz weight; 0 is thin. Clamped 0–4 | `1` |
| `seed` | Re-roll of the random fingerprint | The same phrase, a different fart (integer 0–16777216) | `0` |
| `legacy` | The pre-physics synth | Anything above 0 renders the original buzz, bit for bit | `0` |

Vowels pick the formants (`a` open, `e` mid, `i` pinched, `o` and `u` hollow).
Consonants pick the onset: `p t k c` crack, `b d g j` thump, `s z f v h th dh
gh sh` hiss, `m n ng'` closed murmur, `mb nd ng nj nz` murmur then the stop's
burst, `w y` glide, `r` roll, `l` bubble.

Recipes that sound like something:

| Name | `--voice` |
|---|---|
| wet | `wetness=2.5,tension=0.8` |
| dry | `wetness=0,rasp=0.4,turbulence=0.5,resonance=0.7` |
| raspy | `rasp=2.5,turbulence=1.6,tension=1.2` |
| thunderous | `pressure=1.6,tension=0.6,boom=2.2,decay=0.7` |
| squeaker | `tension=2,pressure=0.7,decay=1.5,boom=0.3` |

Wordless shuzi farts (`shuzi:SEED` in a config `[map]`) draw a random
archetype from the same table (thunderous, squeaker, wet, raspy, dry), so they
vary in character as well as in length.

### Envelope axes

| Knob | What it changes | Default |
|---|---|---|
| `attack` | Multiplier on each onset's attack time | `1` |
| `noise` | Multiplier on every noise source (onset crack, hiss, leak) | `1` |
| `wobble` | Multiplier on flutter depth, not its rate | `1` |
| `intensity` | Effort: level, noise, and stress emphasis | `1` |
| `cents` | Vowel pitch offset; 100 cents is one semitone | `0` |

Applied attack time is clamped to 0.5–200 ms; applied noise and wobble depth
are clamped to 0–1. Effort is clamped to 0.25–4 and pitch to ±1200 cents.
These are effective synthesis bounds, not all bounds on the raw multipliers.
Silence and invalid floating-point audio are not useful presets.

`intensity=0.4` whispers; `intensity=2.5` shouts. Effort changes the penultimate
syllable's stress emphasis too. `cents=-1200` lowers vowels one octave but does
not transpose the randomly pitched, wordless shuzi rumble.

Defaults are an identity. A preset spelling out every default reproduces the
untuned voice in the same build.

The default sound changed when the physical model landed. To hear the old
buzz, add `legacy=1`; its bytes, and its golden fingerprints, are unchanged.
The physical axes do nothing under `legacy=1`. The physical model's output
is the same bytes in Debug and Release builds and on every platform.

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
