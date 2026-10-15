---
title: Commands and defaults
parent: reference/index
status: published
summary: The three executables, six kujamba commands, and session counters.
---

# Command reference

Run from the repository root after `zig build`. Use `kujamba --help` or
`kujamba join --help` for the current help text. Flags belong after the command.

## Executables and build steps

| Command | Purpose |
|---|---|
| `zig build` | Install `fart`, `kujamba`, and `audit` |
| `zig build run` | Run the terminal spectacle |
| `zig build run -- kujamba habari yako` | Animate and speak a phrase |
| `zig build run-kujamba -- join ...` | Build and run the room instrument |
| `zig build audit -- --src src --out manifest.txt` | Generate a source manifest |
| `zig build test` | Run app, synth, audit, protocol, socket, and null-audio tests |
| `zig build repro-backpressure -Doptimize=ReleaseSafe` | Run the constrained-stream measurement |

## Kujamba commands

| Command | Required input | Output/device |
|---|---|---|
| `join` | Room address and usable credentials | Uploads; decoded-peer files and transcript |
| `render` | `--out FILE.wav` or `FILE.ogg` | Offline file, no device |
| `play` | Phrase via positional text or `--phrase` | Playback-only device |
| `trigger` | `[map]` preset, stdin or `--script FILE` | Playback-only device |
| `check-ogg FILE` | Encoded Ogg file | Decode/energy result |
| `encode-silence FILE` | Output path | Silent Ogg negative control |

## Join flags

| Flag | Default / behavior |
|---|---|
| `--host HOST[:PORT]` | IPv4, hostname, or bracketed IPv6; omitted port retains config, otherwise 20531 |
| `--user NAME`, `--pass PASS` | Room credentials; may also come from config |
| `--phrase TEXT` | `kujamba karibu` |
| `--phrases FILE` | Optional phrase bank; mutually exclusive with `--phrase` |
| `--wav FILE` | Play a pre-rendered WAV instead of synthesizing; mutually exclusive with `--phrase`/`--phrases` |
| `--wav-reload` | Re-stat `--wav` at every bar boundary and re-read it when it changed; see below |
| `--pattern N` or `N+M` | `3+1` |
| `--play repeat\|loop\|once` | `repeat` |
| `--voice SPEC` | Default multipliers and zero pitch offset; knob names are per-engine, and `engine=<slug>` may appear inside the spec |
| `--engine SLUG` | `stock`; one of `stock argon4 astra fable gemini38 gutphysics mistral4 opus sol61 sonnet swe2` — the fart-off engines (#95). Beats `engine=` inside `--voice` |
| `--seed N` | Deterministic upload GUID/serial seed |
| `--intervals N` | 8 completed intervals; tempo changes do not reset the count |
| `--duration S` | 120-second hard safety cap |
| `--reconnect [N]` | Off; enabling without N allows five redial attempts |
| `--out-dir DIR` | `dump`, for decoded-peer WAVs |
| `--transcript FILE` | `<out-dir>/transcript.log` |
| `--dump-dir DIR` | Optional interval payload dumps |
| `--config FILE` | Explicit preset; without it, optional `./kujamba.toml` |

## WAV input (`--wav`)

`--wav FILE` treats a rendered file as the phrase: it is decoded once into the
same mono f32 bank a synthesized phrase occupies, so `--pattern`, `--play`, and
the chat controls work unchanged. Accepted input is deliberately narrow — this
is an instrument input, not a media player:

- RIFF/WAVE, little-endian, PCM (format tag 1) only — float and extensible
  headers are rejected.
- 16-bit samples at 44.1 kHz (the session rate); other rates and depths fail.
- Mono as-is; stereo is downmixed `(L+R)/2` to mono. Other channel counts fail.
- `fmt ` must precede `data`; a `data` chunk declaring bytes past EOF is a
  truncated file.
- Decoded audio counts against the same 64 MiB bank budget as `--phrases`;
  over budget is a startup error.

Nothing is synthesized on this path, so `--voice`, `--engine`, and the
config-file `[voice]`/`engine` keys have no effect — `join` prints a warning
and proceeds. A short linear fade is applied to the file's tail at load (the
same one every synthesized phrase gets) so `--play loop` wraps without a
click.

`--wav-reload` re-stats the file at **every bar boundary** — play bars, rest
bars, and tempo-change re-anchors — and re-reads it only when size, mtime,
ctime, or inode changed, so an untouched file costs one stat call per bar. A
changed file is decoded synchronously on the audio path (keep reloads small);
a failed re-read — unreadable, unparseable, or over-budget — keeps the
previous audio, increments `wav_reload_failed`, writes one transcript line,
and never drops an interval. The play cursor resets on a successful reload:
a new file is a fresh sound (in `once`, a kept exhausted cursor would mute it).

Replace the file **atomically** — write a temp file and rename over the path.
An in-place rewrite can be observed half-written; the failed parse keeps the
old audio, but the torn file is what the room did not hear. mtime+size+ctime
+inode is the staleness check; a writer that preserves all of them on the same
inode can still slip through.

## Transcript contract

The transcript file (`--transcript`, default `<out-dir>/transcript.log`) is a
stable machine-readable channel. In particular the session writes

```text
S>C 0x02 CONFIG bpm=<n> bpi=<n>
```

on join and on every tempo-change re-anchor; consumers can rely on that exact
line shape to track the room grid. WAV reloads append `wav reload <file>` /
`wav reload failed <file>` lines in the same log.

## Offline and local flags

Render/play share `--phrase`, `--play`, `--voice`, `--engine`, `--pattern`,
`--bars`, `--bar-ms`, and config defaults. They default to one bar, pattern
`1`, and phrase-length bars. `--seed` selects render's Ogg stream serial.
`play` also accepts `--device NAME|INDEX`.

`trigger` accepts `--config`, `--device`, `--script`, `--voice`, and
`--engine`. It accepts `on N`, `off N`, and `q`; it is not a hardware MIDI
driver.

The config file's `engine = "<slug>"` key (top level, `[voice]`, or dotted
`voice.engine`) picks the engine everywhere a command would; `[voice]`
knobs are validated against the resolved engine, so an engine's own keys
like `wet` or `droop` are legal there.

`check-ogg FILE --min-rms R` chooses the energy threshold.
`encode-silence FILE --seconds S` chooses negative-control duration.

## Results and exit honesty

`join` prints a machine-readable `RESULT`. Important fields include:

- `ok`: whether the session met its success criterion.
- `intervals_uploaded` / `intervals_broadcast`: completed uploads and broadcast channels.
- `intervals_dropped`: lost intervals, including reconnect loss.
- `intervals_backpressured`: the socket-pressure subset of drops.
- `upload_bytes_dropped`: unsent encoded bytes, summed across channels.
- `reconnects` / `outage_ms`: observed recovery and outage duration.
- `drift_ms` / `max_drift_ms` / `clock_corrections`: clock-discipline telemetry.
- `phrase_rejected`: ignored phrase selections.
- `source`: `synth` or `wav` — what fed the phrase bank.
- `wav_reloads` / `wav_reload_failed`: successful re-reads and kept-old-audio
  failures under `--wav-reload` (both `0` without it).

A `--wav` bank is a single entry, so `phrase=` prints `0` — the same 0-based
index convention `phrase=0, phrases=1` uses for a default synth run.

`join` does not report success just because it connected: it exits zero only
on a successful session with at least one uploaded interval. `check-ogg`
exits nonzero when energy is below its threshold. Bare `kujamba` prints usage
and exits 2; `--help` exits zero.
