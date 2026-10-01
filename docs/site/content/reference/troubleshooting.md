---
title: Troubleshooting
parent: reference/index
status: published
summary: Audio, command, connection, and evidence problems without magical fixes.
---

# When the butt is mute

## The build fails with unfamiliar Zig APIs

Use **Zig 0.16.0**, checked by `zig version`. The project uses its current I/O
and build APIs. “A recent Zig” is not a sufficient compatibility guarantee.

## The terminal animates but makes no sound

The visual app needs a host player: `afplay` on macOS, or `paplay`, `aplay`,
or `ffplay` on Linux. Speech lines use `say` or `espeak`. Missing programs
mean silent fallback. Check your host output routing and volume separately.

## Local play fails

Confirm `-Dlive=true`, an actual output device, and a valid `--device` index
or name substring. `join` needs none of these. An audio-enabled compile
does not guarantee the host has an accessible device.

## Offline rendering sounds different from an example

Look for an automatically loaded `kujamba.toml`. Command-line `--voice`
replaces its voice table; pattern and phrase can also come from the preset.
Exact synthesized bytes may differ across optimization modes and platforms.

## Room chat does nothing

Use `kujamba loop`, **not** `!kujamba loop`, on the reference server.
Check that the instrument is still running and the message reaches the room.
Selections apply at the next boundary, not instantly mid-bar. A phrase bank
selector must match an existing number or exact phrase text.

## The session exits before eight intervals

It may hit the duration cap, reject authentication, lose the connection,
or receive a stop request. Read `RESULT` and the transcript. `--reconnect`
is opt-in; enabling it is not a fix for an unidentified server defect.

## Intervals are dropped

Check `intervals_backpressured`, `upload_bytes_dropped`, and `UPLOAD DROPPED`
transcript lines. Socket pressure and reconnect loss are different events.
The clock can continue while a listener still hears a missing interval.

## The demo fails before the instrument starts

Check that run's `receipt.json` first. It separates reference resolution,
network fetch, compilation, cache verification, application build, tests,
and demo failure. See [[contributors/testing|testing and provisioning]].
Do not accept a historical fixture as evidence that the current attempt passed.

## Report a useful bug

Include OS/architecture, Zig version, app commit, exact redacted command,
exit status, and the relevant result/receipt phase. Share only the necessary
sanitized log excerpt. Do not attach credentials or an entire private
source manifest.

[Open an issue](https://github.com/drawmeanelephant/fart-app/issues).
