---
title: Vendoring and provenance
parent: contributors/index
status: published
summary: Shared upstream ownership, the merged pin, and local application policy.
---

# Borrowed code. Honest receipts.

All **15 files** in `src/ninjam/` match
[`drawmeanelephant/ninjam`](https://github.com/drawmeanelephant/ninjam),
`agent/zclient`, at merged commit
`ae9a4d4325addd42d844047c080b9e1c0d6080d4` (upstream PR #38).
Downstream PR #61 completed the reconciliation.

The Ogg/Vorbis trees, generated Ogg type header, miniaudio/stb sources and
shims, and null-audio ABI test also match. The test's location differs
(`src/audio_shim_test.c` here, `zclient/tests/audio_shim_test.c` upstream),
not its contents.

## What stays local

The shared engine provides source-fill, interval-selection, raw-chat, and
stop callbacks. It owns transport framing, encoding, monotonic identity,
clock discipline, reconnect behavior, and drop accounting.

The app owns synthesis, phrase banks, patterns, modes, chat vocabulary,
configuration, and stop wiring. App-specific integration tests live outside
the vendored directory.

Send shared changes upstream first. Do not quietly fix a vendored file and
leave the provenance claiming it is identical.

## Dependency versions

| Dependency | Version / purpose |
|---|---|
| libogg | 1.3.6, Ogg container |
| libvorbis | 1.3.7, encode |
| stb_vorbis | Pinned source, decode |
| miniaudio | 0.11.25, playback-only audition |

The source trees retain their license notices. Native audio frameworks are
system dependencies; “no npm” does not mean “no dependencies.”

The exact subset comparison and third-party provenance live in
[vendor/README.md](https://github.com/drawmeanelephant/fart-app/blob/main/vendor/README.md).

## Docs compiler is a separate pin

This site uses Boris commit `2eb2c915b37ff0eecd7ea0778d6e481a8aea60c7`,
with its own content-hashed dependencies. It is a build-time tool, not a
new dependency of the fart app executables.

The local theme adapts Boris's documentation shell and first-party inline
search. Its MIT notice ships with the static theme assets.
