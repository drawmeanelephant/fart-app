#!/usr/bin/env bash
# Isolation repro: does the determinism double-run (same seed -> same guids)
# against ONE server reproduce the run2 mid-session EOF? No refpeer involved.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
RUNTIME=${KUJ_RUNTIME:-/tmp/kujamba-demo}
SRV="$RUNTIME/srv-build/bin/ninjamsrv"
PORT=${REPRO_PORT:-20532}
KUJ="$REPO/zig-out/bin/kujamba"
N=${N:-3}   # how many back-to-back same-seed runs

[ -x "$SRV" ] || { echo "no server at $SRV"; exit 2; }
[ -x "$KUJ" ] || { echo "no kujamba at $KUJ (zig build first)"; exit 2; }
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT busy"; exit 2; fi

cat > "$RUNTIME/repro.cfg" <<CFG
Port $PORT
MaxUsers 10
MaxChannels 8 2
AnonymousUsers multi
AnonymousUsersCanChat yes
AnonymousMaskIP no
User kujamba secret C
DefaultTopic "repro"
DefaultBPM 100
DefaultBPI 8
SetKeepAlive 3
CFG

"$SRV" "$RUNTIME/repro.cfg" -logfile "$RUNTIME/repro-server.log" &
SRVPID=$!
sleep 0.7
cleanup() { kill $SRVPID 2>/dev/null; wait $SRVPID 2>/dev/null; }
trap cleanup EXIT

fail=0
for i in $(seq 1 "$N"); do
  D="$RUNTIME/repro-payloads-$i"; O="$RUNTIME/repro-out-$i"
  rm -rf "$D" "$O"
  echo "== run $i (seed 42, 6 intervals) =="
  "$KUJ" join --host 127.0.0.1:$PORT --user kujamba --pass secret \
    --phrase "kujamba karibu" --seed 42 --pattern "3+1" --intervals 6 \
    --duration 90 --out-dir "$O" --dump-dir "$D" \
    --transcript "$RUNTIME/repro-transcript-$i.txt" \
    > "$RUNTIME/repro-summary-$i.txt" 2>&1
  rc=$?
  res=$(grep -o 'RESULT.*' "$RUNTIME/repro-summary-$i.txt" | tail -1)
  echo "exit=$rc  $res"
  [ "$rc" -eq 0 ] || { echo "RUN $i FAILED"; fail=1; }
done

echo "== server log =="
grep -E "Accepted|disconnected|Incoming" "$RUNTIME/repro-server.log" || true
[ "$fail" -eq 0 ] && echo "REPRO: all runs OK" || echo "REPRO: FAILURES observed"
exit $fail
