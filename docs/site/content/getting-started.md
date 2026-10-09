---
title: Start here
parent: index
status: published
summary: Build once, render a phrase, and choose how much chaos you want.
---

# Make your first noise

Start with an offline render. It proves the instrument works without requiring
an audio device, a room account, or a willing audience.

## 1. Get the source

Install [Zig 0.17.0](https://ziglang.org/download/) and Git on macOS, Linux,
or Windows. Run these commands in a terminal:

```bash
git clone https://github.com/drawmeanelephant/fart-app.git
cd fart-app
zig version
zig build -Doptimize=ReleaseSafe
```

`zig version` should print `0.17.0`. The build installs three executables in
`zig-out/bin`: `fart`, `kujamba`, and `audit` (`.exe` on Windows). Ogg/Vorbis
sources are vendored; there is no npm install step.

## 2. Render something unreasonable

```bash
./zig-out/bin/kujamba render --phrase "kujamba karibu" --out karibu.wav
./zig-out/bin/kujamba render --phrase "kujamba karibu" --out karibu.ogg --seed 42
./zig-out/bin/kujamba check-ogg karibu.ogg
```

The render commands print their output path and measured audio statistics.
`check-ogg` decodes the Ogg file and rejects silence. Open the WAV in your
usual player, or use local audition on an audio-enabled build:

```bash
./zig-out/bin/kujamba play "kujamba karibu"
```

On macOS, device support is compiled by default. Linux and Windows builds
default to headless device support; see
[[reference/platforms|Platform support]] before using `play` or `trigger`.
For Windows shell spellings and sound tooling, see the
[[guides/windows|Windows guide]].

## 3. Choose your level of commitment

| You want | Next step |
|---|---|
| An animated terminal butt | [[guides/terminal|The fart app]] |
| Files, local playback, or a sampler | [[guides/standalone|Standalone instrument]] |
| Other people to hear this in a room | [[guides/rooms|NINJAM guide]] |
| A different voice | [[guides/voice|Voice and phrasing]] |

## Verify the build

```bash
zig build test
```

Tests include real local sockets and a deliberately blocked peer, so they take
longer than a handful of pure unit tests. They do not need real audio hardware.
See [[contributors/testing|Testing and evidence]] for the full matrix.

<Aside kind="tip">

All examples assume your shell is in the repository root. An existing
`kujamba.toml` in that directory supplies defaults, even for offline commands.
Check [[reference/configuration|configuration precedence]] if an example sounds
different from what you expected.

</Aside>
