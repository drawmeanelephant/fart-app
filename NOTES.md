# Astra: pressure, flutter, and wet thunder

## What changed

Replaced the four-sine buzz in `src/synth.zig` with an uneven, opening/closing
valve. Seeded cycle variation, a loose-valve subharmonic, and a low body
resonance give it more weight and rattle. Pressure drains exponentially,
pulling pitch down into a rumble instead of the old shallow linear glide.

Vowels now select two actual resonant bandpass filters. Plosives release
short pressure bursts, including stops inside `mb`, `mp`, `nk`, and `kw`.
Valve-gated turbulence adds intermittent spits rather than a constant hiss.
DC blocking, soft saturation, and a smooth final release keep the body full
without clicks at syllable boundaries. Phrase timing and stress are unchanged.

## New controls

Available through `--voice "key=value,..."` and preset `[voice]` tables,
including the headless NINJAM path:

| Parameter | Default | Applied range | Sound |
|---|---:|---:|---|
| `pressure` | 1 | 0.25–3 | Intestinal pressure: harder attack, fuller body, higher initial pitch. |
| `tension` | 0.5 | 0–1 | Sphincter tension: loose, low flutter through tight, bright rasp. |
| `resonance` | 0.65 | 0–1 | Terminal tract: dry/direct through hollow, wet vowel squelch. |
| `turbulence` | 0.55 | 0–2 | Extra clustered noise: smooth air through sputtering crackle. |
| `decay` | 2.4 | 0–6 | Exponential pressure loss per syllable: sustained through fast pitch dive. |

All reject negative/non-finite CLI or preset values and clamp large finite
values. `noise=0` mutes all air noise, including turbulence. `turbulence=0`
removes extra spits but keeps plosive noise. `decay=0` holds reservoir
pressure, not the brief plosive burst or the final amplitude fade.
Existing attack/noise/wobble/intensity/cents controls remain available.

## Defaults and determinism

**Deliberately changed default audio and refreshed all seven golden
fingerprints.** The two required no-knob renders should benefit too, rather
than hiding the improvements behind identity-default switches. No golden
assertions or tolerances were weakened.

An initial f32 implementation passed Debug but drifted in ReleaseSafe.
Double-precision DSP phase/filter state fixed that: all seven golden WAV
hashes match between Debug and ReleaseSafe on this machine. Same-build,
same-input renders remain byte-identical; cross-platform byte identity is
not claimed. Existing seed semantics are preserved: phrase text seeds its
sound, shuzi uses its supplied seed, and CLI `--seed` keys NINJAM IDs/Ogg
serials. No new dependencies or libc in the synth, and no vendor changes.

## Competition renders

Run from `/Users/tbuddy/dev/fart-app/t3-1d1f1610`, branch `fartoff/astra`:

```sh
./zig-out/bin/kujamba render --phrase "kujamba karibu" --out /tmp/fartoff/astra/baseline1.wav --seed 42
./zig-out/bin/kujamba render --phrase "shuzi kubwa sana" --out /tmp/fartoff/astra/baseline2.wav --seed 42
./zig-out/bin/kujamba render --phrase "pumba kubwa shuzi karibu" --out /tmp/fartoff/astra/showcase.wav --seed 42 --voice "pressure=2.1,tension=0.18,resonance=0.9,turbulence=1.25,decay=3,cents=-350"
```

The showcase is one unedited render: loose, chesty thunder with wet,
spluttering attacks. Files are mono 44.1 kHz, 16-bit PCM, respectively
1.800 / 1.920 / 2.880 seconds. Peaks are 0.865 / 0.828 / 0.874, with exact
zero endpoints. No postprocessing or normalization.

## Validation

- PASS: `zig build` and `zig build test` (Zig 0.17.0).
- PASS: `zig build test -Doptimize=ReleaseSafe`.
- PASS: `zig build -Dlive=false --prefix "$PWD/zig-out/headless"` and
  `zig build test -Dlive=false`.
- PASS: formatting and whitespace checks.
- New coverage: physical-control parsing, clamps and audible output changes,
  deterministic phrase/shuzi renders, exponential decay, independent vowel
  filtering, clustered plosives, silent gaps/endpoints, and noise muting.
- PASS: separate CLI processes reproduce `baseline1.wav` byte-for-byte.
- PASS: exactly three competition WAVs, valid headers, audible levels,
  headroom, and zero endpoints. Subjective judging remains by ear.

Final WAV SHA-256:

```text
21cf78e35d84bf76da8af487c2f59888df701d032bdf1414f898c840de9a434f  baseline1.wav
8c2c2b5affefaf82f5ff75e4d5d751bb6f2f9f1ea6c0db8375a0442554896af5  baseline2.wav
38c4675d3dd965e6de00c63d5403540366e4f9e8aadcd157d33b4a94ea731a7e  showcase.wav
```
