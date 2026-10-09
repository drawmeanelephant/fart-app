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
# Evidence is a fresh per-run directory, never the historical fixtures.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
RUNTIME=${KUJ_RUNTIME:-/tmp/kujamba-demo}
PORT=${DEMO_PORT:-20531}
EVDIR=${KUJ_EVIDENCE_DIR:-"$REPO/demo/evidence/run-$(date +%Y%m%d-%H%M%S)-$$"}
PROVISION="$REPO/demo/provision_reference.py"
if [ "${KUJ_EVIDENCE_INITIALIZED:-0}" != 1 ]; then
  python3 "$PROVISION" init --evidence "$EVDIR"
fi
EVDIR=$(cd "$EVDIR" && pwd)
phase() { python3 "$PROVISION" phase --evidence "$EVDIR" --phase "$1" --status "$2"; }
CURRENT_PHASE=provisioning
SRVPID=""; R=""
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$R" ]; then kill "$R" 2>/dev/null || true; wait "$R" 2>/dev/null || true; fi
  if [ -n "$SRVPID" ]; then kill "$SRVPID" 2>/dev/null || true; wait "$SRVPID" 2>/dev/null || true; fi
  if [ "$rc" -ne 0 ]; then phase "$CURRENT_PHASE" failed || true; fi
  exit "$rc"
}
trap cleanup EXIT

fail() { echo "DEMO FAIL: $*"; exit 1; }

echo "== checking port $PORT is free =="
if lsof -nP "-iTCP:$PORT" -sTCP:LISTEN >/dev/null 2>&1; then fail "port $PORT already in use"; fi

echo "== pinned reference provisioning =="
# "$@" safely expands to zero arguments under nounset even in macOS Bash 3.2,
# unlike an empty array. Keep optional checkout paths as one quoted argument.
set --
if [ -n "${NINJAM_REPO:-}" ]; then set -- --source "$NINJAM_REPO"; fi
python3 "$PROVISION" provision --evidence "$EVDIR" --runtime "$RUNTIME" \
  --sha "${NINJAM_REF_SHA:-}" "$@"
REFERENCE_ROOT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["root"])' "$EVDIR/reference.json")
SRV="$REFERENCE_ROOT/srv-build/bin/ninjamsrv"
REFPEER="$REFERENCE_ROOT/refpeer"
CURRENT_PHASE=application-build
phase "$CURRENT_PHASE" running
echo "== building kujamba (zig 0.17, ReleaseSafe) =="
( cd "$REPO" && zig build -Doptimize=ReleaseSafe ) || fail "zig build"
KUJ="$REPO/zig-out/bin/kujamba"
phase "$CURRENT_PHASE" passed

CURRENT_PHASE=unit-tests
phase "$CURRENT_PHASE" running
echo "== unit tests =="
( cd "$REPO" && zig build test --summary all ) > "$EVDIR/unit-tests.txt" 2>&1 || { cat "$EVDIR/unit-tests.txt"; fail "zig build test"; }
phase "$CURRENT_PHASE" passed
shasum -a 256 "$SRV" | tee "$EVDIR/ninjamsrv.sha256"
CURRENT_PHASE=demo
phase demo running

cat > "$EVDIR/demo.cfg" <<CFG
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

"$SRV" "$EVDIR/demo.cfg" -logfile "$EVDIR/server.log" &
SRVPID=$!

# Wait for the server to actually listen instead of a blind sleep (#27): on a
# cold CI runner a fixed 0.7s can race process startup, and both clients fail
# with an instant loopback ECONNREFUSED — a false red, not a real one.
echo "== waiting for ninjamsrv to listen on $PORT =="
server_up=0
for _ in $(seq 1 50); do
  if ! kill -0 $SRVPID 2>/dev/null; then fail "ninjamsrv exited during startup (see server.log)"; fi
  if lsof -nP "-iTCP:$PORT" -sTCP:LISTEN >/dev/null 2>&1; then server_up=1; break; fi
  sleep 0.2
done
[ "$server_up" -eq 1 ] || fail "ninjamsrv did not listen on $PORT within 10s (see server.log)"

D1="$EVDIR/payloads-run1"; D2="$EVDIR/payloads-run2"
O1="$EVDIR/out-run1"; O2="$EVDIR/out-run2"

echo "== scenario A: kujamba (6 intervals, pattern 3+1) + reference client core =="
"$REFPEER" --host "127.0.0.1:$PORT" --user anonymous:refpeer --pass x \
  --duration 40 --freq 660 --amp 0.3 --report "$EVDIR/refpeer-report.txt" \
  > "$EVDIR/refpeer.log" 2>&1 &
R=$!
sleep 1.5
K=0
"$KUJ" join --host "127.0.0.1:$PORT" --user kujamba --pass secret \
  --phrase "kujamba karibu" --seed 42 --pattern "3+1" --intervals 6 \
  --duration 90 --out-dir "$O1" --dump-dir "$D1" \
  --transcript "$EVDIR/kujamba-transcript.txt" \
  > "$EVDIR/kujamba-summary.txt" 2>&1 || K=$?
RP=0
wait "$R" || RP=$?
R=""
[ "$K" -eq 0 ] || fail "kujamba exit $K (see kujamba-summary.txt)"
[ "$RP" -eq 0 ] || fail "refpeer exit $RP (see refpeer-report.txt)"

echo "== scenario B: determinism — second run, same seed + phrase + BPI =="
K2=0
"$KUJ" join --host "127.0.0.1:$PORT" --user kujamba --pass secret \
  --phrase "kujamba karibu" --seed 42 --pattern "3+1" --intervals 6 \
  --duration 90 --out-dir "$O2" --dump-dir "$D2" \
  --transcript "$EVDIR/kujamba-transcript-run2.txt" \
  > "$EVDIR/kujamba-summary-run2.txt" 2>&1 || K2=$?
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
phase demo passed
echo "DEMO PASS"
exit 0
