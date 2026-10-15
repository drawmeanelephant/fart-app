# Changelog

All notable changes to fart-app / Flatlophone are documented here.

Format inspired by [Keep a Changelog](https://keepachangelog.com/).
`build.zig.zon`'s `.version` is the version source of truth; releases are
tagged `v<version>` and published on GitHub with CI-built binaries via
[`.github/workflows/release.yml`](.github/workflows/release.yml).

## [Unreleased]

### Added

- `kujamba join --wav FILE` (#98) — upload a pre-rendered WAV on the interval
  grid instead of a synthesized phrase: RIFF/WAVE PCM s16le at 44.1 kHz, mono
  or stereo downmixed `(L+R)/2`, decoded once into the phrase bank so
  `--pattern`, `--play`, and chat controls work unchanged. `--wav-reload`
  re-stats the file at every bar boundary and swaps in a changed file's audio
  mid-set (callers replace atomically via temp+rename); failed re-reads keep
  the previous audio and are counted as `wav_reload_failed` on the `RESULT`
  line, alongside new `source=synth|wav` and `wav_reloads` fields. `--wav` is
  mutually exclusive with `--phrase`/`--phrases`; `--voice`/`--engine` warn
  rather than fail, since nothing is synthesized.
- Fart-off engine selector (#95, M9) — all nine Great Fart-Off entries ship
  as `src/engines/<slug>.zig` modules behind one registry, plus `gutphysics`
  (the MiMo Pro 2.6 / Codebuff entry absorbed from stale PR #99). `--engine
  SLUG` on `join`/`render`/`play`/`trigger`, `engine=<slug>` inside `--voice`, and
  a config `engine` key (top-level, `[voice]`, or `voice.engine`) all
  resolve through the same precedence: flag > in-spec > config > `stock`.
  Each engine parses its own `--voice` spec — foreign knob names fail with
  that engine's vocabulary — and carries its own `src/golden.zig`
  fingerprints. `stock` remains the default until judging closes; no winner
  has been picked.

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
