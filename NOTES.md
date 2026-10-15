# fartoff/grok47 — gut-physics voice

The old synth was a falling buzz, a noise splat, and a flutter. Same shape on every vowel, pitch down a flat 20%, texture only by how much noise you mixed in. This one is a short gut event. Pressure drives the body and the pitch. Tension decides whether the exit flutters or rasps. The vowel is a cavity, not a pitch label. A plosive is a held breath and a crack.

Deterministic: same phrase, same seed, same bytes, in Debug and in ReleaseSafe. The sample loop does not call `@sin`, `@exp` or `std.math.pow` — those lower differently per optimization mode, and the noise/wobble accumulation was enough to push a rounded 10 ms RMS window across an integer (`shuzi seed 1234567`, windows 11 and 12). Sine comes from a comptime table, exp from a comptime table of `exp(-x)`, both interpolated with plain f32 arithmetic. `src/golden.zig` was re-baselined for that: peak and duration held, RMS moved by a few parts in a thousand. `--seed`, `--phrase`, `--out` are untouched. New axes go through the existing `--voice` parser. `src/ninjam/*` is untouched. The judged default is this voice with no flags; `src/golden.zig` is re-baselined for it. Phrase timing (syllable counts, durations, gaps) is unchanged, so the plan fingerprints still match on `items` and `samples`.

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

## Determinism fix

The polyfill rounds differently from the Debug libm the competition WAVs were rendered with, so those bytes moved. Re-rendered in Debug to `/tmp/fartoff/grok47/`. Same commands, same lengths, peak unchanged on all three.

| file | command | before | after |
|---|---|---|---|
| baseline1.wav | `--phrase "kujamba karibu" --seed 42` | `6e66e05c4273d7997ad16c22fd4141e23f065556d74d7d3ce55769c10fc19162` | `fe85069eada533f51fd4d8068a35b5f7289066c9946e51ad107416c32da0c686` |
| baseline2.wav | `--phrase "shuzi kubwa sana" --seed 42` | shipped Debug render | `3e27d435f0d0e53c14ecbbea2150ff344be1224dd1e5fd14039996fb51274ae6` |
| showcase.wav | `--phrase "po po po" --seed 42 --voice "pressure=1,tension=0.3,resonance=0.8,turbulence=0.3,wetness=0.15,decay=0.85,intensity=1.3"` | `915bcdc135ee932938786a9fba6cdfc12679b3f0a4cf142fad9132c196933a7b` | `4a2b0e9e64c2a567641c193a728b2760cd314d6c1eac4cb9fb424b27633dbb10` |

Peak held (0.847, and 0.853 on the showcase) and duration held (1.800 s, 1.920 s, 0.960 s). The new bytes are identical in Debug and ReleaseSafe, which the shipped ones were not.
