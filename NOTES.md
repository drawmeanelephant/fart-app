# NOTES.md — Fart-Off entry: kimi-k3 ("The Gut-Physics Engine")

## What I changed and why

The stock synth was a buzzy oscillator with a linear 20% pitch sag, a fixed
noise splat, and a flutter — every fart came out of the same mid-sized butt.
I replaced the per-sample core of `src/synth.zig` (`synthInto`) with a small
gut-physics model. Everything below is still a pure function of
(phrase, knobs, seed); the PRNG is the only randomness and its draw order is
fixed, so `--seed 42` is byte-identical on every run (verified by re-rendering
and diffing SHA-256, and by the determinism tests).

1. **Rectal pressure envelope.** Each syllable starts at full pressure, which
   collapses exponentially, `P(t) = exp(-t/tau)`, with `tau` shrinking as the
   `pressure` knob rises (a harder push empties faster). The amplitude decay
   and the harmonic brightness both ride `P(t)`: farts start bright and loud,
   then sag and dull as the gut runs out — the "deflating" arc the stock
   synth lacked.

2. **Exponential pitch decay.** The oscillator's pitch now rides the
   pressure: `f(t) = f0 * (1 - glide * (1 - P(t)))`, falling from `f0` toward
   `f0*(1-glide)` on the pressure's time constant instead of a straight line.
   Plosives add a short upward chirp on top, the pressure-spike "paH!" of a
   sudden release.

3. **Sphincter tension.** The flutter (wobble) rate and depth scale with
   `tension`, and tension lifts the held pitch slightly. Tight = a pinched,
   fast-flapping squeaker; loose = a slow, sloppy raspberry. The flutter also
   vibratos the pitch a little, because a flapping exit modulates the flow.

4. **Noise-burst turbulence.** A slow (11 Hz) random gate chops a mid-band
   (500 Hz) noise into intermittent sputters layered over the body hiss —
   the spluttering texture of turbulent flow, scaled by `turbulence`.
   `turbulence=0` is perfectly laminar.

5. **Terminal tract resonance.** A Chamberlin state-variable low-pass,
   tuned 95-170 Hz (the pipe lengthens as `resonance` rises), blended into
   the output: the chesty boom of the exit pipe. This is what makes a fart
   *thunderous* instead of merely loud.

6. **Vowel formants.** Each vowel drives a second SVF at a band-pass
   formant (`vowelFormantHz`: a=620, e=440, i=320, o=380, u=260 Hz), so
   "ka", "ki" and "ku" have genuinely different colours, not just different
   pitches. `formant` scales the blend; at 2 it is almost talkative.

7. **Plosive pressure bursts.** Stop onsets (k, p, t crack; b, d, g thump)
   slam the gate open: a sudden wideband pop in the first ~11 ms plus the
   pitch chirp above, both scaled by pressure.

8. **Pressure-driven soft clipper.** `y = (1+a)x / (1 + a|x|)` — pure
   arithmetic, so it is bit-exact across build modes — with `a` growing with
   pressure. A gentle push stays clean; a straining one audibly farts into
   the limiter. Measured on the default voice: peaks kiss the ceiling only
   on plosive transients (0.00% of samples pinned), RMS up ~3.7 dB over stock.

One subtlety worth recording: both IIR resonators are scaled by the amplitude
envelope (`* env`). Physically the pipe only booms while gas flows; and it
keeps every phrase ending at exactly sample 0, which the loop-seam invariant
in ninjam_out (#17) locks in — an unscaled IIR tail rings past the envelope
and clicks at the wrap.

## New `--voice` knobs (all multipliers, default 1.0 = the new default voice)

| knob         | range (clamped) | what it does to the sound |
|--------------|-----------------|---------------------------|
| `pressure`   | 0.25 – 4.0      | Intestinal pressure. Higher: harder splat, stronger plosive pops, brighter attack, faster pitch collapse, audible limiter drive — a straining push. Lower: a gentle, clean, sagging hiss. |
| `tension`    | 0.0 – 3.0       | Sphincter tension. Higher: faster, deeper flutter and a slightly higher held pitch — a pinched squeaker. Lower: slow, flappy raspberry. 0 is fully relaxed. |
| `resonance`  | 0.0 – 3.0       | Terminal tract resonance. The low boom of the exit pipe (95-170 Hz). 0 removes it; past 1 the fart gets chesty and thunderous. |
| `turbulence` | 0.0 – 3.0       | Stochastic sputter: a random gate chops mid-band noise into spatters over the body. 0 is laminar, 3 is a spluttering mess. |
| `formant`    | 0.0 – 2.0       | Vowel formant strength. 0 is colourless buzz; 2 is an almost vocal, talking fart. |

Wet/dry/raspy/thunderous cheat sheet:
`pressure=2.5,turbulence=2` (wet) · `turbulence=0,formant=0` (dry) ·
`tension=2.5,pressure=1.5` (raspy) · `resonance=2.8,pressure=2.2,cents=-150`
(thunderous).

## Competition renders

- `baseline1.wav` — `./zig-out/bin/kujamba render --phrase "kujamba karibu" --out baseline1.wav --seed 42`
- `baseline2.wav` — `./zig-out/bin/kujamba render --phrase "shuzi kubwa sana" --out baseline2.wav --seed 42`
- `showcase.wav` — `./zig-out/bin/kujamba render --phrase "kujamba mkubwa kabisa" --voice "pressure=2.6,tension=0.55,resonance=2.8,turbulence=2.2,formant=1.2,cents=-150" --out showcase.wav --seed 42`

The showcase is "the biggest fart ever" rendered as one: a deep-dropped,
loose-sphinctered monster that slams open with plosive pops, booms through a
long pipe, sputters turbulence all the way down, and deflates into the
limiter. SHA-256 `637abb2584b252d7d016cb8a2c228dde022e841cd662f6896c8d8946a5ccc106`
(re-render the recipe to check: determinism is the whole job).

## Character line (for the scorecard)

"I am the whole digestive tract rendered honestly: pressure that collapses, a
sphincter that flaps, a pipe that booms — every fart I make has eaten."
