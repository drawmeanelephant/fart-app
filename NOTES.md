# fartoff/grok47 — gut-physics voice

The old synth was a falling buzz, a noise splat, and a flutter. Same shape on every vowel, pitch down a flat 20%, texture only by how much noise you mixed in. This one is a short gut event. Pressure drives the body and the pitch. Tension decides whether the exit flutters or rasps. The vowel is a cavity, not a pitch label. A plosive is a held breath and a crack.

Deterministic: same phrase, same seed, same bytes. `--seed`, `--phrase`, `--out` are untouched. New axes go through the existing `--voice` parser. `src/ninjam/*` is untouched. The judged default is this voice with no flags; `src/golden.zig` is re-baselined for it. Phrase timing (syllable counts, durations, gaps) is unchanged, so the plan fingerprints still match on `items` and `samples`.

## Character

I bear down, I sag, and I do not apologize for the rasp on the way out.

## What changed, and why it sounds better

- **Intestinal pressure** sets the fatness of the body, the size of the plosive, and how long the syllable holds. A leak and a blast are no longer the same waveform at two gains.
- **Exponential pitch decay.** The fundamental falls as the tank empties, on its own clock from the amplitude, so you hear the note sag instead of a mute with a pitch label. `decay=0` keeps the old 20% linear glide.
- **Sphincter tension.** Low tension is a loose, deep flutter. High tension slams the aperture shut for part of each chatter cycle and forces air through the slit, which is the rasp.
- **Terminal-tract resonance.** Two formant bandpasses per vowel, excited by the buzz and by noise. /a/ booms, /i/ whistles, /u/ is a closed tube. `resonance=0` bypasses the cavity.
- **Turbulence.** A few filtered noise bursts, times drawn up front from the seed, clustered toward the attack. Wetness crossfades that texture from a low gurgle to a dry hiss.
- **Plosives.** `k` `p` `t` (and `ch`, which `classify` already calls a voiceless stop) choke the buzz, build pressure, and crack. `b` `d` `g` bloom softer. Nasals and fricatives do not pop, so the onset classes still mean what the voice table says.
- Soft clip with headroom, so a confident fart is not a square wave pinned at the rail. The last millisecond is forced to silence so a looped phrase still wraps through zero.

## New `--voice` keys

All six are amounts in 0..1, not multipliers. Omitting one keeps the default. A value past 1 is pinned at 1. Negatives are rejected, same as the old knobs.

| Key | Default | Sound |
|---|---|---|
| `pressure` | 0.72 | How hard the gas pushes. High: thunderous, fatter body, harder pop. Low: a thin leak. |
| `tension` | 0.55 | Sphincter. Low: loose flutter. High: raspy chatter, brighter edge. |
| `resonance` | 0.62 | Terminal tract. 0: dry close-miked buzz, formants bypassed. 1: the vowel cavity rings. |
| `turbulence` | 0.48 | Extra noise bursts while pressure holds. 0: clean tone. 1: a storm of texture. |
| `wetness` | 0.40 | Of that turbulence, how much gurgles (wet, under ~400 Hz) versus hisses (dry). |
| `decay` | 0.62 | Exponential pitch sag. 0: the old linear 20% glide. 1: about an octave down by the end of the syllable, still audible when it gets there. |

Old keys (`attack`, `noise`, `wobble`, `intensity`, `cents`) behave as before. Onset class still biases tension, wetness, and turbulence, so two syllables with the same knobs do not sound alike.

## Showcase

```
./zig-out/bin/kujamba render \
  --phrase "po po po" \
  --seed 42 \
  --voice "pressure=1,tension=0.3,resonance=0.8,turbulence=0.3,wetness=0.15,decay=0.85,intensity=1.3" \
  --out showcase.wav
```

Three voiceless pops, loose sphincter, long tract, a dry edge, and a deep sag. The judged baselines are the same binary with no `--voice` at all.
