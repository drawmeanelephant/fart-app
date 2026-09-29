#!/usr/bin/env bash
# kujamba — NINJAM instrument end-to-end demo.
# No mocks: everything runs against the UNMODIFIED reference ninjamsrv built
# out-of-tree from a fresh checkout of the reference C++ sources.
#
# Scenario A (acceptance): kujamba joins, authenticates, streams 6 intervals
#   (pattern 3+1 => 5 fart bars + 1 rest bar), and the REFERENCE client core
#   (demo/refpeer.cpp — the same headless driver style as
#   ninjam/tests/e2e_test.cpp) receives and decodes the audio with measured
#   energy (REFPEER RESULT ok=1, remote_peak > 0). Every uploaded interval's
#   payload is dumped and must decode to real signal.
# Scenario B (determinism): a second run with the same seed + phrase + BPI
#   must produce byte-identical uploaded payloads (sha256 per interval).
# Negative control: the rest bar must emit silence markers (no payload), and
#   a synthesized silent interval must FAIL the energy check.
#
# Evidence lands in demo/evidence/<timestamp>/.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
RUNTIME=${KUJ_RUNTIME:-/tmp/kujamba-demo}
NINJAM_REPO=${NINJAM_REPO:-$RUNTIME/ninjam-src}
SRVBUILD=${KUJ_SRV_BUILD:-$RUNTIME/srv-build}
COREBUILD=${KUJ_CORE_BUILD:-$RUNTIME/core-build}
PORT=${DEMO_PORT:-20531}
EVDIR="$REPO/demo/evidence/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUNTIME" "$EVDIR"

fail() { echo "DEMO FAIL: $*"; exit 1; }

echo "== checking port $PORT is free =="
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then fail "port $PORT already in use"; fi

echo "== building kujamba (zig 0.16, ReleaseSafe) =="
( cd "$REPO" && zig build -Doptimize=ReleaseSafe ) || fail "zig build"
KUJ="$REPO/zig-out/bin/kujamba"

echo "== unit tests =="
( cd "$REPO" && zig build test --summary all ) > "$EVDIR/unit-tests.txt" 2>&1 || { cat "$EVDIR/unit-tests.txt"; fail "zig build test"; }

echo "== reference checkout (unmodified main) =="
if [ ! -d "$NINJAM_REPO/.git" ]; then
  git clone --depth 1 https://github.com/drawmeanelephant/ninjam "$NINJAM_REPO" || fail "clone ninjam"
fi
echo "ninjam checkout: $(git -C "$NINJAM_REPO" rev-parse HEAD)" | tee "$EVDIR/reference-sha.txt"

echo "== building reference server (out-of-tree, unmodified) =="
if [ ! -x "$SRVBUILD/bin/ninjamsrv" ]; then
  cmake -S "$NINJAM_REPO" -B "$SRVBUILD" -DCMAKE_BUILD_TYPE=Release -DNINJAM_BUILD_CLIENT=OFF -DNINJAM_BUILD_TESTS=OFF || fail "cmake server"
  cmake --build "$SRVBUILD" -j 8 || fail "build server"
fi
SRV="$SRVBUILD/bin/ninjamsrv"
shasum -a 256 "$SRV" | tee "$EVDIR/ninjamsrv.sha256"

echo "== building reference client core (for refpeer) =="
if [ ! -f "$COREBUILD/libninjam_core.a" ]; then
  cmake -S "$NINJAM_REPO" -B "$COREBUILD" -DCMAKE_BUILD_TYPE=Release -DNINJAM_BUILD_CLIENT=OFF -DNINJAM_BUILD_TESTS=OFF || fail "cmake core"
  cmake --build "$COREBUILD" -j 8 || fail "build core"
fi
if [ ! -x "$RUNTIME/refpeer" ]; then
  VOR=$COREBUILD/_deps/vorbis-src; OGGS=$COREBUILD/_deps/ogg-src
  clang++ -std=c++17 -O2 "$REPO/demo/refpeer.cpp" -I"$NINJAM_REPO" \
    -I"$OGGS/include" -I"$VOR/include" -I"$VOR/lib" \
    "$COREBUILD/libninjam_core.a" "$COREBUILD/libninjam_net.a" \
    "$COREBUILD/_deps/vorbis-build/lib/libvorbisenc.a" \
    "$COREBUILD/_deps/vorbis-build/lib/libvorbis.a" \
    "$COREBUILD/_deps/ogg-build/libogg.a" \
    -framework CoreFoundation -framework CoreServices \
    -o "$RUNTIME/refpeer" || fail "build refpeer"
fi

cat > "$RUNTIME/demo.cfg" <<CFG
Port $PORT
MaxUsers 10
MaxChannels 8 2
AnonymousUsers multi
AnonymousUsersCanChat yes
AnonymousMaskIP no
User kujamba secret C
DefaultTopic "kujamba (Flatlophone) instrument demo"
DefaultBPM 100
DefaultBPI 8
SetKeepAlive 3
CFG

"$SRV" "$RUNTIME/demo.cfg" -logfile "$EVDIR/server.log" &
SRVPID=$!
sleep 0.7
cleanup() { kill $SRVPID 2>/dev/null; wait $SRVPID 2>/dev/null; }
trap cleanup EXIT

D1="$RUNTIME/payloads-run1"; D2="$RUNTIME/payloads-run2"
O1="$RUNTIME/out-run1"; O2="$RUNTIME/out-run2"
rm -rf "$D1" "$D2" "$O1" "$O2"

echo "== scenario A: kujamba (6 intervals, pattern 3+1) + reference client core =="
"$RUNTIME/refpeer" --host 127.0.0.1:$PORT --user anonymous:refpeer --pass x \
  --duration 40 --freq 660 --amp 0.3 --report "$EVDIR/refpeer-report.txt" \
  > "$EVDIR/refpeer.log" 2>&1 &
R=$!
sleep 1.5
"$KUJ" join --host 127.0.0.1:$PORT --user kujamba --pass secret \
  --phrase "kujamba karibu" --seed 42 --pattern "3+1" --intervals 6 \
  --duration 90 --out-dir "$O1" --dump-dir "$D1" \
  --transcript "$EVDIR/kujamba-transcript.txt" \
  > "$EVDIR/kujamba-summary.txt" 2>&1
K=$?
wait $R; RP=$?
[ "$K" -eq 0 ] || fail "kujamba exit $K (see kujamba-summary.txt)"
[ "$RP" -eq 0 ] || fail "refpeer exit $RP (see refpeer-report.txt)"

echo "== scenario B: determinism — second run, same seed + phrase + BPI =="
"$KUJ" join --host 127.0.0.1:$PORT --user kujamba --pass secret \
  --phrase "kujamba karibu" --seed 42 --pattern "3+1" --intervals 6 \
  --duration 90 --out-dir "$O2" --dump-dir "$D2" \
  --transcript "$EVDIR/kujamba-transcript-run2.txt" \
  > "$EVDIR/kujamba-summary-run2.txt" 2>&1
K2=$?
[ "$K2" -eq 0 ] || fail "kujamba run2 exit $K2"

echo "== assertions =="
result_field() { grep -oE "(^|[[:space:]])$1=[^ ]*" "$2" | head -1 | sed -E 's/^[[:space:]]*//' | cut -d= -f2; }

S="$EVDIR/kujamba-summary.txt"
[ "$(result_field ok "$S")" = "true" ] || fail "scenario A: session not ok"
IU=$(result_field intervals_uploaded "$S"); [ "${IU:-0}" -ge 4 ] || fail "scenario A: uploaded=$IU <4"
IB=$(result_field intervals_broadcast "$S"); [ "${IB:-0}" -eq 5 ] || fail "scenario A: broadcast=$IB, want 5"
SM=$(result_field silence_markers "$S"); [ "${SM:-0}" -ge 1 ] || fail "scenario A: no silence markers"
PD=$(result_field payload_dumps "$S"); [ "${PD:-0}" -eq 5 ] || fail "scenario A: payload dumps=$PD, want 5"
grep -q "0x82 SET_CHANNEL_INFO n=1" "$EVDIR/kujamba-transcript.txt" || fail "did not announce exactly one channel"
grep -q "SILENCE_MARKER" "$EVDIR/kujamba-transcript.txt" || fail "no silence marker in transcript"

grep -q "REFPEER RESULT ok=1" "$EVDIR/refpeer-report.txt" || fail "reference client did not decode kujamba (see refpeer-report.txt)"
RPEAK=$(grep -o "remote_peak=[0-9.]*" "$EVDIR/refpeer-report.txt" | cut -d= -f2)
awk -v p="$RPEAK" 'BEGIN{exit !(p>0)}' || fail "reference client saw no energy from kujamba"

echo "-- per-interval payload energy (decoded with kujamba check-ogg) --"
nplay=0
for f in "$D1"/interval_*.ogg; do
  [ -e "$f" ] || continue
  "$KUJ" check-ogg "$f" --min-rms 0.02 >> "$EVDIR/ogg-analysis.txt" || fail "payload below threshold: $f"
  nplay=$((nplay+1))
done
[ "$nplay" -eq 5 ] || fail "expected 5 play payloads, got $nplay"
if [ -e "$D1/interval_0003.ogg" ]; then fail "rest bar (interval 3) produced an audio payload; it must be a silence marker"; fi
echo "rest bar interval_0003 has no payload (silence marker only): OK"

echo "-- negative control: silence must fail the energy check --"
"$KUJ" encode-silence "$EVDIR/negative-control-silence.ogg" --seconds 5 > /dev/null
if "$KUJ" check-ogg "$EVDIR/negative-control-silence.ogg" --min-rms 0.02 >> "$EVDIR/ogg-analysis.txt" 2>&1; then
  fail "silence passed the energy check (the test would be a lie)"
fi
echo "silence correctly rejected"

echo "-- determinism: sha256 of run1 vs run2 payloads --"
det_ok=1
for f in "$D1"/interval_*.ogg; do
  b=$(basename "$f")
  if [ ! -e "$D2/$b" ]; then det_ok=0; echo "missing in run2: $b"; continue; fi
  h1=$(shasum -a 256 "$f" | awk '{print $1}')
  h2=$(shasum -a 256 "$D2/$b" | awk '{print $1}')
  printf "%s %s %s\n" "$b" "$h1" "$h2" | tee -a "$EVDIR/determinism-shas.txt"
  [ "$h1" = "$h2" ] || det_ok=0
done
[ "$det_ok" -eq 1 ] || fail "payloads differ between runs (see determinism-shas.txt)"
echo "determinism verified: identical payload bytes across two runs"

echo "== evidence -> $EVDIR =="
for f in "$EVDIR"/*.txt "$EVDIR"/*.log; do
  [ -e "$f" ] || continue
  sed -e "s|$REPO/||g" -e "s|$EVDIR/||g" -e "s|$RUNTIME/||g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
grep -E "Incoming connection|login|accepted|disconnected" "$EVDIR/server.log" | head -20 || true

echo
echo "DEMO PASS"
exit 0
