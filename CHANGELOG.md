# Changelog

All notable changes to fart-app / Flatlophone are documented here.

Format inspired by [Keep a Changelog](https://keepachangelog.com/).
`build.zig.zon`'s `.version` is the version source of truth; releases are
tagged `v<version>` and published on GitHub with CI-built binaries via
[`.github/workflows/release.yml`](.github/workflows/release.yml).

## [Unreleased]

### Changed

- **The default sound is now a physical fart model** (`synthFart` in
  `src/synth.zig`): exponentially draining pressure, two flapping sphincter
  lips with per-cycle jitter/shimmer/period doubling, pulse-gated turbulence,
  vowel-selected formant filters plus a low boom cavity, wet bubbles, and
  consonant-specific onsets (plosives are pressure bursts, fricatives hiss,
  nasals close, `w y l r` glide and roll). It is louder (about -12 dBFS) and
  much brighter than the old buzz. Output bytes of every phrase changed.
  `--voice legacy=1` renders the previous synth bit for bit.
- The physical model evaluates its own exp/sin/tan, so its WAV bytes are
  identical in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall.
- Wordless shuzi farts pick a random archetype (thunderous, squeaker, wet,
  raspy, dry), vowel and onset per syllable.

### Added

- `--voice` / `[voice]` knobs: `pressure`, `tension`, `resonance`,
  `turbulence`, `wetness`, `rasp`, `decay`, `burst`, `boom`, `seed` and
  `legacy`. Each is documented on `VoiceKnobs` and in the voice guide.
- Golden fingerprints for both engines: the old seven are kept as
  `(legacy)` rows, and seven new rows pin the default sound.

## [1.0.0] - 2026-10-11

The first tagged release of Flatlophone v2: a deterministic fart synthesizer
in Zig — `fart`, the animated terminal app; `kujamba`, a headless NINJAM
instrument that plays phrase-banked fart audio into a room on bar
boundaries; and `audit`, a source-manifest utility. Milestones M4–M8 plus
the Windows port (#25) are the shipped baseline; the post-milestone
hardening wave (#76–#83) closed the integer-overflow and float-cast panics
found in the CLI and WAV/RIFF paths before the tag.

### Added

- `fart` — the animated terminal app: speaks Flatlophone phrases, probes
  host sound/speech tools, and runs silently when none exist.
- `kujamba join` — headless NINJAM instrument over the vendored zclient
  subset: phrase banks (`--phrases`), bar patterns (`--pattern`), play
  modes (`--play repeat|loop|once`), a determinism `--seed`, per-interval
  upload dumps (`--dump-dir`), bounded reconnect/resume (`--reconnect`,
  #24), and live room-chat controls (`kujamba play|rest|loop|repeat|once|
  <n|name>|stop`) that all land on bar boundaries (#8–#11).
- `kujamba render` — offline phrase rendering to WAV or Ogg, shaped
  exactly as `join` plays it, rest bars as exact silence (#19).
- `kujamba play` / `kujamba trigger` — local playback through vendored
  miniaudio (`-Dlive`, default on for macOS) and the stdin/script note
  sampler with `[map]` note bindings (#20, #21).
- `kujamba check-ogg` / `kujamba encode-silence` — interval energy
  analysis and the silence negative control used by the demo and CI
  smoke gates.
- Voice shaping — `--voice` attack/noise/wobble multipliers and
  effort/dynamics, vowel-pitch, and seamless-loop synthesis controls
  (#15–#18).
- Timing discipline — monotonic interval identity across BPI/BPM
  changes, bounded clock skew handling, and nonblocking upload/drop
  recovery (#12–#14).
- Config presets — `kujamba.toml`-style defaults file shared by join,
  render, play, and trigger; flags always win over the file (#22).
- `audit` — the RAG manifest generator over the source tree.
- Windows support — a real Winsock sys seam, console control handler,
  conhost VT output, and a native `build-test-windows` CI leg (#25).
- The Boris-built field manual, published to GitHub Pages by the docs
  workflow; Markdown source lives in `docs/site/`.
- Ronny, the project mascot (`docs/assets/ronny.webp`).
- MIT license at the root (`LICENSE`) with vendored-component attribution
  in `NOTICE`; release archives carry both files.

### Fixed

- `check --bar-ms`/`--bars` multiplication overflow now errors instead of
  panicking (#80); `join --duration`/`--chat-delay` and
  `encode-silence --seconds` validate before `@intFromFloat` (#82);
  session-dump WAV paths disambiguate usernames that sanitize alike
  (#79); `synth.writeWavBytes` and the WavWriter PCM buffer cap at the
  RIFF 4 GiB limit without close-time panics (#77, #78); the device
  pull/push resampler actually delivers resampled audio (#76); zclient
  `check-wav` no longer panics on long paths (#83).

### Verification baseline

- `zig build test` — 218/218 in Debug, ReleaseSafe, and `-Dlive=false`,
  plus the standalone null-backend C audio shim test.
- `demo/run_demo.sh` — live session against the unmodified reference
  ninjamsrv: peer-decoded energy asserts, rest markers, the silence
  negative control, and equal-input upload-hash determinism.
- CI: native Linux/macOS build+test legs and the Windows build leg;
  `build-test` and `demo-e2e` are the required merge checks.
- Vendored provenance: the shared Zig subset and C deps track
  `drawmeanelephant/ninjam` per `vendor/README.md`; wire-safety work
  upstreamed via ninjam#38/#42.
