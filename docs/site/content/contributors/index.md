---
title: Under the hood
parent: index
status: published
summary: Contributor map for the synth, tests, vendored client, and audit utility.
---

# Serious machinery. Unserious output.

The main app has three binaries and a shared instrument layer:

| Location | Owns |
|---|---|
| `src/main.zig` | Terminal visuals and host-player/speech integration |
| `src/synth.zig` | Pure deterministic phrase/shuzi PCM and WAV synthesis |
| `src/kujamba_main.zig` | Instrument CLI, local playback, chat, stop wiring |
| `src/kujamba_config.zig` | Preset parsing |
| `src/ninjam_out.zig` | Phrase banks, patterns, modes, and generic-session adapters |
| `src/ninjam/` | Byte-identical upstream shared client subset |
| `src/audit.zig` | Source chunking and token-based risk manifest |

- [[contributors/synth|Synth internals]] explains the voice and determinism boundaries.
- [[contributors/testing|Testing and evidence]] explains the real socket/demo gates.
- [[contributors/vendoring|Vendoring]] records source ownership and pins.
- [[contributors/audit|Audit utility]] explains what its warnings do and do not prove.

The repository's [roadmap](https://github.com/drawmeanelephant/fart-app/blob/main/ROADMAP.md)
and [issue map](https://github.com/drawmeanelephant/fart-app/blob/main/ISSUES.md)
are contributor history, not the first-run tutorial.

To maintain this site, see the repository's
[docs workflow instructions](https://github.com/drawmeanelephant/fart-app/blob/main/docs/README.md).
