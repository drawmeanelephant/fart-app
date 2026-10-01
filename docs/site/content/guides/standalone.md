---
title: Standalone instrument
parent: guides/index
status: published
summary: Render files, audition through a playback device, or trigger a note map.
---

# No room required

`kujamba render`, `play`, and `trigger` use the instrument without connecting
to a server. Only `play` and `trigger` require an audio-enabled build and
an output device.

## Render WAV or Ogg

```bash
./zig-out/bin/kujamba render --phrase "kujamba karibu" --out karibu.wav
./zig-out/bin/kujamba render --phrase "kujamba karibu" --out bars.ogg \
  --play loop --pattern 3+1 --bars 4 --bar-ms 500 --seed 42
```

The extension chooses the container. With no `--bar-ms`, a bar is as long as
the rendered phrase. Render defaults to one bar and pattern `1` unless your
config supplies another pattern.

A rest bar is an equal-length stretch of silence, not a missing segment.
It freezes the phrase position. That keeps the offline timeline aligned
with what the room instrument would play.

The Ogg seed selects the stream serial, not the waveform. The synth seeds
its noise from phrase text. Repeatability assumes the same build and inputs;
exact synthesized bytes are not promised across optimization modes or platforms.

## Audition locally

```bash
./zig-out/bin/kujamba play "kujamba karibu" --play once
./zig-out/bin/kujamba play --phrase "po" --device 1
```

`--device` accepts a zero-based index or a case-insensitive name substring.
Playback uses vendored miniaudio, not the visual app's external audio players.
It opens **playback only**, never a capture device.

A missing device, an invalid device selection, or `-Dlive=false` produces a
clear failure. See [[reference/platforms|audio build options]].

## Trigger a note map

Create a local preset, for example `sampler.toml`:

```toml
[map]
note60 = "kujamba karibu"
note61 = "shuzi:3"
```

Then start the sampler:

```bash
./zig-out/bin/kujamba trigger --config sampler.toml
```

Type `on 60` or `on 61`, followed by Enter. `off 60` is accepted but currently
does not gate or release the sound. `q` or EOF exits. Notes are numbers in
`0..127`; unknown notes and malformed lines are warned about and ignored.

For a repeatable input sequence, `--script FILE` reads the same line protocol.
This is a **stdin/script sampler**, not hardware MIDI support. Do not assume
that plugging in a MIDI keyboard supplies those lines automatically.

Next: [[guides/voice|tune the voice]] or [[reference/configuration|save a preset]].
