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
| `--pattern N` or `N+M` | `3+1` |
| `--play repeat\|loop\|once` | `repeat` |
| `--voice SPEC` | Default multipliers and zero pitch offset |
| `--seed N` | Deterministic upload GUID/serial seed |
| `--intervals N` | 8 completed intervals; tempo changes do not reset the count |
| `--duration S` | 120-second hard safety cap |
| `--reconnect [N]` | Off; enabling without N allows five redial attempts |
| `--out-dir DIR` | `dump`, for decoded-peer WAVs |
| `--transcript FILE` | `<out-dir>/transcript.log` |
| `--dump-dir DIR` | Optional interval payload dumps |
| `--config FILE` | Explicit preset; without it, optional `./kujamba.toml` |

## Offline and local flags

Render/play share `--phrase`, `--play`, `--voice`, `--pattern`, `--bars`,
`--bar-ms`, and config defaults. They default to one bar, pattern `1`,
and phrase-length bars. `--seed` selects render's Ogg stream serial.
`play` also accepts `--device NAME|INDEX`.

`trigger` accepts `--config`, `--device`, and `--script`. It accepts `on N`,
`off N`, and `q`; it is not a hardware MIDI driver.

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

`join` does not report success just because it connected: it exits zero only
on a successful session with at least one uploaded interval. `check-ogg`
exits nonzero when energy is below its threshold. Bare `kujamba` prints usage
and exits 2; `--help` exits zero.
