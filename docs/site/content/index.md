---
title: Flatlophone
status: published
summary: A fart synthesizer. A terminal spectacle. An actual room instrument.
---

<p class="eyebrow">Field manual / Flatlophone v2</p>

# Bad manners.<br>Good engineering. {#welcome .hero-heading}

A deterministic fart synthesizer written in Zig. A terminal butt with stage
presence. And, somehow, a real instrument you can take into a NINJAM room.

<div class="home-actions">
<a href="getting-started.html">Make your first noise</a>
<a href="guides/rooms.html">Join the band</a>
</div>

<div class="specimen-card">
<div class="specimen-card__header">One native build. Three questionable decisions.</div>
<div class="specimen-card__body">

```bash
zig build
./zig-out/bin/kujamba render --phrase "kujamba karibu" --out karibu.wav
```

No room, microphone, or speaker needed to render. Your dignity is optional.

</div>
</div>

## Pick your instrument

<div class="feature-grid">
<div class="feature-card"><span class="edition-card__tag">01 / Terminal</span><h3 id="the-original-spectacle">The original spectacle</h3><p>Animated ASCII, synthesized rumbles, and a butt that speaks in syllables.</p><a href="guides/terminal.html">Run the fart app</a></div>
<div class="feature-card"><span class="edition-card__tag">02 / Standalone</span><h3 id="a-useful-noise-machine">A useful noise machine</h3><p>Render WAV or Ogg, audition locally, or trigger a phrase from a note map.</p><a href="guides/standalone.html">Play without a room</a></div>
<div class="feature-card"><span class="edition-card__tag">03 / NINJAM</span><h3 id="resident-bad-influence">Resident bad influence</h3><p>Phrase banks, bar patterns, chat controls, and clock-aware room uploads.</p><a href="guides/rooms.html">Play with other people</a></div>
</div>

## The joke is not the specification

This is source-first software for **macOS and Linux**, built with **Zig 0.17.0**.
The headless room instrument never opens a microphone or speaker. Local audition
is a separate, playback-only path.

The synth has deterministic inputs. Rest bars are real silence. Slow uploads
drop intervals instead of freezing the audio clock. The demo checks actual
decoded audio, not whether a process happened to exit.

- [[getting-started|Start here]] for a working first run.
- [[reference/index|Reference]] for commands, presets, platforms, and troubleshooting.
- [[contributors/index|Under the hood]] for tests, synthesis, audit tooling, and upstream provenance.

No tracking, remote fonts, or application framework. This manual is compiled
to static files by [Boris](https://github.com/drawmeanelephant/boris).
