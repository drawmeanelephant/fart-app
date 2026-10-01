#!/usr/bin/env bash
# Hardware-free execution of the first-run, voice, pattern, and preset examples.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=${KUJAMBA_BIN:-"$ROOT/zig-out/bin/kujamba"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/flatlophone-doc-examples.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" # No automatic repository-local kujamba.toml affects the examples.
"$BIN" --help > help.txt 2>&1
"$BIN" render --phrase "kujamba karibu" --out karibu.wav
"$BIN" render --phrase "kujamba karibu" --out karibu.ogg --seed 42
"$BIN" check-ogg karibu.ogg
"$BIN" render --phrase "kujamba karibu" --out shout.wav --voice "intensity=2.5"
"$BIN" render --phrase "habari yako" --out pattern.ogg \
  --play loop --pattern 3+1 --bars 4 --bar-ms 500 --seed 42
"$BIN" check-ogg pattern.ogg
cat > voice.toml <<'EOF'
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
EOF
"$BIN" render --config voice.toml --out preset.ogg --seed 42
"$BIN" check-ogg preset.ogg
"$BIN" encode-silence silence.ogg
if "$BIN" check-ogg silence.ogg; then
  echo "silence negative control unexpectedly passed" >&2
  exit 1
fi
echo "Documentation examples and silence negative control pass (no audio device opened)."
