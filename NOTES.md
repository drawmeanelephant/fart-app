# GPT-6.1 Sol / sol61

- Worktree: `/Users/tbuddy/dev/fart-app/t3-32e12e3c`
- Branch: `fartoff/sol61`
- Audio and test logs: `/tmp/fartoff/sol61/`

## What changed

Replaced the smooth four-harmonic buzz with an asymmetric valve pulse, a
strong bass fundamental, loose-tissue subharmonics, and seeded irregular
flutter. Pressure drains exponentially, taking pitch down into a rumble.
Intermittent turbulence splats replace constant attack-only hiss. A bass
cavity and two parallel vowel-formant filters add hollow, throaty color
without removing the fundamental. Stops release pressure suddenly, including
`k`, `p`, `b`, `kw`, and `mb`. Rounded tails, DC removal, and smooth saturation
avoid clicks and hard clipping.

The result has more body, changing resonant colors and uneven valve motion
instead of six similar little musical buzzes. Wordless shuzi uses the same
engine, with seeded tract colors. Its existing timing sequence is preserved.
Its `noise=0` and wobble controls now reach the entire source.

## New parameters

Available through `--voice "key=value,..."`, `[voice]`, and `voice.<key>`:

| Parameter | Default | Applied range | Audible effect |
|---|---:|---:|---|
| `pressure` | 1 | 0.25–3 | Intestinal pressure: more bass weight, louder body, stronger releases and higher starting pitch. |
| `tension` | 0.45 | 0–1 | Sphincter tension: low is loose/wet, irregular and subharmonic; high is tight, higher, dry and raspy. |
| `resonance` | 0.65 | 0–1 | Terminal tract: higher blends in a deeper bass cavity and narrower vowel formants for hollow, full-bodied resonance. |
| `turbulence` | 0.45 | 0–1 | More intermittent noisy splats and sputters. Zero removes body turbulence, not stop-release noise. |
| `decay` | 2.6 | 0–8 | Exponential pressure/pitch decay: zero holds pitch; high dives quickly into a low rumble. |

Existing attack/noise/wobble/intensity/cents flags remain supported.
`noise=0` removes all turbulence and release noise. Vowels select real formant
filters independently of pitch; the formant table and texture presets are
documented in the synth and voice guides.

## Golden decision and determinism

**Defaults deliberately sound different.** Identity-default additions would
leave the required baseline WAVs sounding like the old synth. Updated all
seven golden fingerprints instead, keeping their checks and tolerances
unchanged. Phrase and wordless sample counts remain unchanged.

An extra ReleaseSafe check exposed tiny f32 feedback drift. Using f64 DSP
state resolved it; the new golden WAV hashes and fingerprints agree exactly
between Debug and ReleaseSafe on this machine. No cross-platform bit-identity
claim is made. Randomness remains local and seeded, with no clock/device state.
Existing seed semantics are unchanged: phrase text seeds synthesis; `--seed`
keys instrument IDs. A repeated built-binary baseline1 render at seed 42 was
byte-identical.

## Competition renders

Run from the worktree using the final `zig build` binary:

```sh
./zig-out/bin/kujamba render --phrase "kujamba karibu" --out /tmp/fartoff/sol61/baseline1.wav --seed 42
./zig-out/bin/kujamba render --phrase "shuzi kubwa sana" --out /tmp/fartoff/sol61/baseline2.wav --seed 42
./zig-out/bin/kujamba render --phrase "paka kubwa kujamba shuzi kubwa sana" --out /tmp/fartoff/sol61/showcase.wav --seed 42 --voice "pressure=2.2,tension=0.18,resonance=0.92,turbulence=0.82,decay=2.2,cents=-180,noise=1.3,wobble=1.25"
```

The showcase was rendered once. Exactly three competition WAV files exist.
All are mono 44.1 kHz 16-bit PCM, non-silent, with zero endpoints and no hard
clipping. Durations are 1.800s / 1.920s / 4.240s; normalized peaks are
0.794 / 0.794 / 0.835.

## Validation

- `zig build`: PASS.
- `zig build test --summary all`: PASS, all suites.
- `zig build test -Doptimize=ReleaseSafe --summary all`: PASS, all suites.
- `zig build -Dlive=false` and `zig build test -Dlive=false --summary all`: PASS.
- `zig fmt --check` on all changed Zig files: PASS.
- 30 synth tests, including nine new physical/DSP tests; config coverage added.
- Full instrument tests include NINJAM, Ogg, sampler, and backpressure checks.
- WAV format/level checks and repeated seed-42 CLI byte check: PASS.
- No files under `src/ninjam/` or `vendor/` changed. New DSP is pure Zig,
  adds no dependencies, and passes the libc-free synth test target.

Character: chesty, hollow thunder with wet double-pulses and crackling releases.
