---
title: Configuration and presets
parent: reference/index
status: published
summary: A small TOML-style defaults file, explicit precedence, and sampler mappings.
---

# Stop retyping your entire personality

`join`, `render`, `play`, and `trigger` load a small TOML-style preset:

```bash
./zig-out/bin/kujamba render --config myvoice.toml --out phrase.wav
```

Without `--config`, the optional `kujamba.toml` in your current directory is
auto-loaded. An explicit missing file fails. An absent automatic file is normal.
The parser is a supported subset, not a promise of every TOML feature.

## Precedence

**Built-in defaults → config file → command-line flags.**

A flag wins wherever it appears. `--voice` replaces the whole voice table,
not just the fields it mentions. A host override without a port retains the
configured port. `--phrases` overrides a configured single phrase.

## Instrument preset

```toml
phrase = "kujamba karibu"
pattern = "3+1"

[voice]
attack = 1.0
noise = 0.5
wobble = 1.0
intensity = 0.8
cents = -100

[map]
note60 = "habari yako"
note61 = "shuzi:3"
```

| Field | Meaning |
|---|---|
| `phrase` | Default phrase text |
| `pattern` | Bar pattern such as `"3+1"` |
| `host` | Room address, including optional port |
| `user`, `pass` | Join-only credentials |
| `[voice]` | `attack`, `noise`, `wobble`, `intensity`, `cents` |
| `[map]` | `noteN` bindings to phrase text or `"shuzi:SEED"` |

Connection keys are ignored by offline rendering. The note map is used by
`trigger`, not automatically converted into a NINJAM phrase bank.

Malformed input reports a file and line. Values use the same instrument
parsers as the command line. Unknown keys are not an extension mechanism.

## A room preset is private

Add `host`, `user`, and `pass` locally if you need them:

```bash
chmod 600 myroom.toml
./zig-out/bin/kujamba join --config myroom.toml
```

The file remains plaintext. Keep credentials out of commits, generated docs,
screenshots, and issue reports. The checked-in
[example preset](https://github.com/drawmeanelephant/fart-app/blob/main/examples/kujamba.toml)
contains demonstration values, not a public room invitation.

Next: [[guides/voice|voice controls]] and [[guides/standalone|the sampler]].
