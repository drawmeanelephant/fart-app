---
title: Terminal spectacle
parent: guides/index
status: published
summary: The animated fart app and its Swahili phrase mode.
---

# A butt with stage presence

The `fart` executable is the animated terminal app. It uses the Flatlophone
synth for its rumbles, with ANSI colors, screen shake, and occasional nuclear
theatrics. It is not the NINJAM client.

## Run the spectacle

```bash
zig build run
```

It runs until you press **Ctrl+C**, then restores the cursor and terminal colors.
Use a terminal that supports ANSI escape sequences. Sound and voice are optional.

## Speak a phrase

```bash
zig build run -- kujamba habari yako
./zig-out/bin/fart kujamba "karibu kujamba"
```

This mode synthesizes a Swahili phrase and times the animation to its syllables,
then exits. *Kujamba* means “to fart.” This is a playful syllable synthesizer,
not a general speech engine or a pronunciation reference.

| Phrase | Syllables | Approximate duration |
|---|---|---|
| `habari yako` | ha · ba · ri · ya · ko | 1.52 s |
| `karibu kujamba` | ka · ri · bu · ku · ja · mba | 1.80 s |
| `asante` | a · sa · nte | 0.84 s |

## How sound reaches you

On macOS the visual app uses `afplay` for sound and `say` for voice lines.
On Linux it probes `paplay`, `aplay`, or `ffplay` for sound and `espeak` for voice.
Missing tools mean a silent spectacle, not a required install or a fake success
claim about audio.

The app writes synthesized temporary WAVs under `/tmp`, including
`fart_kujamba.wav` and the pre-rendered shuzi files. These are runtime outputs,
not a sample library you need to download.

For device-backed playback without terminal animation, use
[[guides/standalone|`kujamba play`]] instead.
