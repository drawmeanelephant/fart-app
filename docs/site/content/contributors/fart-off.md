---
title: The Great Fart-Off
parent: contributors/index
status: published
summary: Nine frontier models, one synth, one brief. An LLM bake-off judged strictly by ear.
---

<p class="eyebrow">Milestone M9 · <a href="https://github.com/drawmeanelephant/fart-app/issues/95">#95</a></p>

# The Great Fart-Off

Nine frontier language models were each handed the same repository, the same
brief, and a private git worktree. Their job: make the farts better. Their
code is real, their tests pass, and every entry renders a deterministic WAV
you can rebuild byte-for-byte. Judging is by ear, because a fart is not a
specification.

Three late entries arrived by different routes. [PR
#99](https://github.com/drawmeanelephant/fart-app/pull/99) was MiMo Pro 2.6
running under the Codebuff agent — same physics brief (#23), opened on a
branch too stale to merge, absorbed as `gutphysics`. **Grok 4.7** and
**Kimi K3** then ran the same protocol in isolated worktrees as entries
11 and 12 — `grok47` and `kimi3`. All three sets of competition renders
are in the tables below.

## The rules

Every contestant received an identical brief, verbatim:

> Make better farts.
>
> You're improving the deterministic fart synthesizer in `src/synth.zig`
> (fart-app / Flatlophone v2). The synth must stay deterministic — same seed,
> same output — and must keep working as a headless NINJAM instrument
> (kujamba).
>
> Goal: Fatter, richer, more varied farts. The current synth works but the
> farts are mid. Make them good.
>
> What to improve:
>
> - Add physical parameters: intestinal pressure, sphincter tension, terminal
>   tract resonance. These should produce audible texture differences (wet,
>   dry, raspy, thunderous).
> - Add exponential pitch decay — pitch drops as pressure drops, like a real
>   fart.
> - Add noise-burst turbulence for texture, controllable by a parameter.
> - Expand phrase-to-synthesis mapping: vowels → resonant formant filters,
>   plosives (k, b, p) → sudden pressure bursts.
> - Keep it deterministic. Same `--seed 42`, same WAV.
>
> Constraints:
>
> - Pure Zig, no external deps, no libc.
> - Must not break existing CLI flags (`--seed`, `--phrase`, `--out`).
> - Must pass existing tests.
> - Document each new parameter and what it does to the sound.
>
> Deliverable: Updated `src/synth.zig` plus a short note on what you changed
> and why it makes the farts better.

On top of the brief, the ground rules: `zig build test` must pass (including
the `src/golden.zig` fingerprints), the vendored `src/ninjam/` tree stays
untouched, and each entry renders three competition WAVs:

- **baseline1** — `kujamba render --phrase "kujamba karibu" --seed 42`
- **baseline2** — `kujamba render --phrase "shuzi kubwa sana" --seed 42`
- **showcase** — one render of the contestant's choosing, flags unlimited

The baselines are the controlled comparison: same phrase, same seed, no
knobs, judged against every other entry. The showcase is freestyle.

## The field

| Entry | Model | Branch | New `--voice` keys | In its own words |
|---|---|---|---|---|
| argon4 | Gemini 4 Argon | `fartoff/argon4` | `pressure`, `tension`, `resonance`, `turbulence` | Thunderous, sub-heavy mucosal reed slap with plosive cheek-pops |
| astra | GPT-6 Astra | `fartoff/astra` | `pressure`, `tension`, `resonance`, `turbulence`, `decay` | Chesty thunder with wet, sputtering attacks and a descending rumble |
| sol61 | GPT-6.1 Sol | `fartoff/sol61` | `pressure`, `tension`, `resonance`, `turbulence`, `decay` | Chesty, hollow thunder with wet double-pulses and crackling releases |
| gemini38 | Gemini 3.8 Flash | `fartoff/gemini38` | `pressure`, `tension`, `resonance`, `turbulence`, `decay`, `wetness` | Earth-shattering, wet, decompressing sub-bass blast |
| swe2 | SWE-2 | `fartoff/swe2` | `pressure`, `tension`, `resonance`, `turbulence`, `wet`, `drop` | A deep, wet, sub-heavy wallop — 92% of showcase energy below 100 Hz |
| sonnet | Claude Sonnet 5.5 | `fartoff/sonnet` | `pressure`, `tension`, `resonance`, `turbulence`, `decay`, `wetness`, `rasp`, `boom` | A fat, ragged rumble that rings with its vowel and sputters out wet |
| fable | Claude Fable 5.1 | `fartoff/fable` | `pressure`, `tension`, `resonance`, `turbulence` | A draining gas reservoir behind a flap-pulse sphincter |
| opus | Claude Opus 5.5 | `fartoff/opus` | `pressure`, `tension`, `wetness`, `tract`, `droop` (+ `classic`) | Wet, rumbling physical-model farts that sputter out as the gas runs dry |
| mistral4 | Mistral Large 4 | `fartoff/mistral4` | `pressure`, `tension`, `resonance`, `turbulence`, `decay` | A wet, thunderous brrrap that drops pitch like a disappointed trombone |
| gutphysics | MiMo Pro 2.6 (Codebuff) | PR #99 → `src/engines/` | `pressure`, `tension`, `tract`, `turbulence` | A pressure-driven body where the pitch sags as the gas runs out and grainy pops ride the buzz |
| grok47 | Grok 4.7 | `fartoff/grok47` | `pressure`, `tension`, `resonance`, `turbulence`, `wetness`, `decay` (0–1 amounts) | "I bear down, I sag, and I do not apologize for the rasp on the way out" |
| kimi3 | Kimi K3 | `fartoff/kimi3` | `pressure`, `tension`, `resonance`, `turbulence`, `formant` | "The whole digestive tract rendered honestly: pressure that collapses, a sphincter that flaps, a pipe that booms" |

## The one decision everyone made the same way

The `src/golden.zig` fingerprints pin the default voice's exact sound.
Changing the default means re-baselining them; keeping them means hiding the
new engine behind flags. Because the judged baselines render with **no**
`--voice` flags, the brief quietly forced the real question: *is your new
sound good enough to be the default?*

All nine contestants answered yes — new engine as default, goldens
re-baselined with the documented `formatBaseline` mechanism. Opus deserves a
footnote: it kept every old fingerprint passing by adding a `classic=1`
voice flag that reproduces the original engine byte-for-byte, then added
seven new fingerprints on top. And two entries — Fable and Mistral,
independently — replaced `@sin`/`@exp`/`std.math.pow` with deterministic
math throughout the DSP so WAV bytes are bit-identical across optimization
modes, something the original synth explicitly could not do.

## The scorecard — listen for yourself

Every render below is the deterministic output of its entry's branch, encoded
to AAC for the page. The baselines are the controlled comparison — same
phrase, same seed, no knobs — and the showcase is freestyle.

### Baseline 1 · "kujamba karibu" · default voice · seed 42

| Entry | Model | Listen |
|---|---|---|
| argon4 | Gemini 4 Argon | <audio controls preload="none" src="fart-off.assets/argon4-baseline1.m4a"></audio> |
| astra | GPT-6 Astra | <audio controls preload="none" src="fart-off.assets/astra-baseline1.m4a"></audio> |
| sol61 | GPT-6.1 Sol | <audio controls preload="none" src="fart-off.assets/sol61-baseline1.m4a"></audio> |
| gemini38 | Gemini 3.8 Flash | <audio controls preload="none" src="fart-off.assets/gemini38-baseline1.m4a"></audio> |
| swe2 | SWE-2 | <audio controls preload="none" src="fart-off.assets/swe2-baseline1.m4a"></audio> |
| sonnet | Claude Sonnet 5.5 | <audio controls preload="none" src="fart-off.assets/sonnet-baseline1.m4a"></audio> |
| fable | Claude Fable 5.1 | <audio controls preload="none" src="fart-off.assets/fable-baseline1.m4a"></audio> |
| opus | Claude Opus 5.5 | <audio controls preload="none" src="fart-off.assets/opus-baseline1.m4a"></audio> |
| mistral4 | Mistral Large 4 | <audio controls preload="none" src="fart-off.assets/mistral4-baseline1.m4a"></audio> |
| gutphysics | MiMo Pro 2.6 (Codebuff) | <audio controls preload="none" src="fart-off.assets/gutphysics-baseline1.m4a"></audio> |
| grok47 | Grok 4.7 | <audio controls preload="none" src="fart-off.assets/grok47-baseline1.m4a"></audio> |
| kimi3 | Kimi K3 | <audio controls preload="none" src="fart-off.assets/kimi3-baseline1.m4a"></audio> |

### Baseline 2 · "shuzi kubwa sana" · default voice · seed 42

| Entry | Model | Listen |
|---|---|---|
| argon4 | Gemini 4 Argon | <audio controls preload="none" src="fart-off.assets/argon4-baseline2.m4a"></audio> |
| astra | GPT-6 Astra | <audio controls preload="none" src="fart-off.assets/astra-baseline2.m4a"></audio> |
| sol61 | GPT-6.1 Sol | <audio controls preload="none" src="fart-off.assets/sol61-baseline2.m4a"></audio> |
| gemini38 | Gemini 3.8 Flash | <audio controls preload="none" src="fart-off.assets/gemini38-baseline2.m4a"></audio> |
| swe2 | SWE-2 | <audio controls preload="none" src="fart-off.assets/swe2-baseline2.m4a"></audio> |
| sonnet | Claude Sonnet 5.5 | <audio controls preload="none" src="fart-off.assets/sonnet-baseline2.m4a"></audio> |
| fable | Claude Fable 5.1 | <audio controls preload="none" src="fart-off.assets/fable-baseline2.m4a"></audio> |
| opus | Claude Opus 5.5 | <audio controls preload="none" src="fart-off.assets/opus-baseline2.m4a"></audio> |
| mistral4 | Mistral Large 4 | <audio controls preload="none" src="fart-off.assets/mistral4-baseline2.m4a"></audio> |
| gutphysics | MiMo Pro 2.6 (Codebuff) | <audio controls preload="none" src="fart-off.assets/gutphysics-baseline2.m4a"></audio> |
| grok47 | Grok 4.7 | <audio controls preload="none" src="fart-off.assets/grok47-baseline2.m4a"></audio> |
| kimi3 | Kimi K3 | <audio controls preload="none" src="fart-off.assets/kimi3-baseline2.m4a"></audio> |

### Showcase · freestyle, flags unlimited

| Entry | Model | Listen | Recipe |
|---|---|---|---|
| argon4 | Gemini 4 Argon | <audio controls preload="none" src="fart-off.assets/argon4-showcase.m4a"></audio> | `pressure=1.9,tension=0.75,resonance=1.8,turbulence=1.5,wobble=1.35,intensity=1.6,cents=-250` |
| astra | GPT-6 Astra | <audio controls preload="none" src="fart-off.assets/astra-showcase.m4a"></audio> | `pressure=2.1,tension=0.18,resonance=0.9,turbulence=1.25,decay=3,cents=-350` |
| sol61 | GPT-6.1 Sol | <audio controls preload="none" src="fart-off.assets/sol61-showcase.m4a"></audio> | `pressure=2.2,tension=0.18,resonance=0.92,turbulence=0.82,decay=2.2,cents=-180,noise=1.3,wobble=1.25` |
| gemini38 | Gemini 3.8 Flash | <audio controls preload="none" src="fart-off.assets/gemini38-showcase.m4a"></audio> | `pressure=2.0,tension=0.75,resonance=1.8,turbulence=1.6,decay=1.2,wetness=2.2,cents=-250,wobble=1.4,intensity=1.5` |
| swe2 | SWE-2 | <audio controls preload="none" src="fart-off.assets/swe2-showcase.m4a"></audio> | `pressure=1.8,tension=0.45,resonance=1.6,turbulence=1.4,wet=1.3,drop=1.6,cents=-350,intensity=1.3` |
| sonnet | Claude Sonnet 5.5 | <audio controls preload="none" src="fart-off.assets/sonnet-showcase.m4a"></audio> | `pressure=1.5,tension=0.7,boom=1.8,decay=1.2,wetness=1.8,rasp=1.4,turbulence=1.2` |
| fable | Claude Fable 5.1 | <audio controls preload="none" src="fart-off.assets/fable-showcase.m4a"></audio> | `pressure=2.5,resonance=2.5,tension=0.8,cents=-500` |
| opus | Claude Opus 5.5 | <audio controls preload="none" src="fart-off.assets/opus-showcase.m4a"></audio> | `pressure=2,tension=0.7,wetness=1.6,tract=1.4,droop=1.4,intensity=0.8` |
| mistral4 | Mistral Large 4 | <audio controls preload="none" src="fart-off.assets/mistral4-showcase.m4a"></audio> | `pressure=1.3,tension=0.75,resonance=1.35,turbulence=1.8,decay=1.3,intensity=1.1` |
| gutphysics | MiMo Pro 2.6 (Codebuff) | <audio controls preload="none" src="fart-off.assets/gutphysics-showcase.m4a"></audio> | `pressure=3,tension=1.2,tract=0.6` (its own "thunderous" preset) |
| grok47 | Grok 4.7 | <audio controls preload="none" src="fart-off.assets/grok47-showcase.m4a"></audio> | `po po po` with `pressure=1,tension=0.3,resonance=0.8,turbulence=0.3,wetness=0.15,decay=0.85,intensity=1.3` |
| kimi3 | Kimi K3 | <audio controls preload="none" src="fart-off.assets/kimi3-showcase.m4a"></audio> | `kujamba mkubwa kabisa` with `pressure=2.6,tension=0.55,resonance=2.8,turbulence=2.2,formant=1.2,cents=-150` |

Ballots go on
[#95](https://github.com/drawmeanelephant/fart-app/issues/95) — say which
entry owns baseline and which owns showcase.

## Play every entry from one binary

All twelve engines shipped into the tree as `src/engines/<slug>.zig` behind an
`--engine` selector (#95). Nothing was crowned: `stock` is still the default
voice until judging closes.

```bash
./zig-out/bin/kujamba render --engine swe2 \
  --voice "wet=1.3,drop=1.6" --phrase "kujamba karibu" --out swe2.wav
```

- `--engine <slug>` works on `join`, `render`, `play`, and `trigger`.
- `engine=<slug>` inside `--voice` is a shortcut; a real `--engine` flag
  beats it, and both beat the config file's `engine = "<slug>"` key.
- Each engine parses its own `--voice` spec — `wet` is swe2-only, `glide`
  is fable-only — and a foreign knob name fails with that engine's knob
  list. See the field table above for each entry's keys.
- Every engine carries its own `src/golden.zig` fingerprints, so a drift in
  any single engine fails the suite without touching the others.

## Reproduce any entry exactly

The selector is the easy path, but every entry also exists as a
`fartoff/<slug>` branch off the same base commit — the historical record of
what each model actually wrote:

```bash
git fetch origin fartoff/argon4   # any entry slug
git worktree add /tmp/entry fartoff/argon4
cd /tmp/entry && zig build
./zig-out/bin/kujamba render --phrase "kujamba karibu" --out baseline1.wav --seed 42
```

The exact showcase commands and parameter write-ups live in `NOTES.md` on
each branch.

## Verdict

Judging is open. The winner — and how the keepers land — will be recorded
here.
