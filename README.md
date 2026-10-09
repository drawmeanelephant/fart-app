# fart-app / Flatlophone v2

**Bad manners. Good engineering.**

A deterministic fart synthesizer written in Zig. An animated terminal butt.
And `kujamba`, an actual headless NINJAM instrument with phrase banks, bar
patterns, room-chat controls, and offline rendering. There is also an
independent source-audit utility, because apparently this project has range.

**[Read the field manual](https://drawmeanelephant.github.io/fart-app/)** ·
[Start here](docs/site/content/getting-started.md) ·
[Commands](docs/site/content/reference/cli.md) ·
[Contributing](docs/site/content/contributors/index.md)

The manual is built with [Boris](https://github.com/drawmeanelephant/boris)
and published by GitHub Actions after changes reach `main`. Its Markdown
source remains readable in this repository.

## Make your first noise

Requires **Zig 0.17.0** and **macOS or Linux**:

```bash
git clone https://github.com/drawmeanelephant/fart-app.git
cd fart-app
zig build -Doptimize=ReleaseSafe
./zig-out/bin/kujamba render --phrase "kujamba karibu" --out karibu.wav
```

That creates a real WAV without a server or audio device.

| You want | Run / read |
|---|---|
| Terminal chaos | `zig build run` |
| The butt speaks a phrase | `zig build run -- kujamba habari yako` |
| An offline Ogg file | `./zig-out/bin/kujamba render --phrase "kujamba karibu" --out karibu.ogg --seed 42` |
| Local playback | `./zig-out/bin/kujamba play "kujamba karibu"` |
| A room instrument | [NINJAM guide](docs/site/content/guides/rooms.md) |
| A stdin/script sampler | [Standalone guide](docs/site/content/guides/standalone.md) |

Local `play`/`trigger` need an audio-enabled build: `-Dlive=true` defaults on
for macOS and off for Linux. `join` is headless and never opens a microphone
or speaker. The terminal app separately probes host sound/speech tools and
can run silently. [Platform support](docs/site/content/reference/platforms.md)
records the actual boundaries; Windows remains deferred under #25.

## Build and verify

```bash
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Dlive=false
bash demo/run_demo.sh
```

Tests use real local sockets and a null audio backend, not your microphone.
The reference demo verifies peer-decoded energy, rest markers, a silence
negative control, and exact equal-input upload hashes. See
[testing and evidence](docs/site/content/contributors/testing.md).

## Source ownership

Application synthesis and policies live in `src/synth.zig`,
`src/ninjam_out.zig`, and `src/kujamba_main.zig`.
All **15 shared Zig files** in `src/ninjam/`, plus the C dependency subset,
match `drawmeanelephant/ninjam` commit
**`ae9a4d4325addd42d844047c080b9e1c0d6080d4`** (PR #38 into `agent/zclient`).
See [vendor provenance and exact comparison](vendor/README.md).

This is a native source build, not a dependency-free claim: Ogg, Vorbis,
stb_vorbis, and optional miniaudio are vendored with their licenses.

## Maintain the docs

[docs/README.md](docs/README.md) describes the pinned Boris build,
local preview, validation, theme provenance, and Pages deployment.
Generated HTML and raw audit/demo evidence are not committed as documentation.

[ROADMAP.md](ROADMAP.md) and [ISSUES.md](ISSUES.md) preserve engineering
status/history. User instructions live in the field manual.
