#!/usr/bin/env bash
# Amplified repro for #28 — the suspect window, stressed.
#
# The observed flake (#28): during demo/run_demo.sh, the second determinism
# session was dropped by the server (read failed: EndOfStream) at interval 2,
# in the window where the scenario-A refpeer disconnects as run 2 connects.
# That geometry (one teardown landing in another client's upload burst) occurs
# once per ~90s demo. This script compresses and multiplies it: a kujamba
# "victim" session uploads continuously while refpeer peers join, upload one
# interval, and tear down every few seconds — dozens of teardowns per victim
# session instead of one per demo, all landing somewhere in the victim's
# upload timeline.
#
#   N victims      (default 5)  — fresh kujamba session each, ~2 min at 4.8s bars
#   CHURN count    (default 12) — refpeer join/upload/drop cycles per victim
#   CHURN_DURATION (default 4)  — seconds each churner stays connected
#   CHURN_GAP      (default 3)  — seconds between churner launches
#
# A victim that dies (RESULT ok != true) fails the script. The server log and
# every transcript are kept under $RUNTIME so a reproduction can be autopsied:
# the interesting question is always *who hung up* — a victim transcript whose
# RESULT carries err="connection stalled..." is the client hanging up; a
# server-side "read failed: EndOfStream" against a clean victim RESULT is the
# server (or its view of the connection) giving up first.
#
# No refpeer involvement is *not* the point here (that is repro_double_run.sh);
# the churners ARE refpeer, because the incident happened in refpeer teardown.

set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
RUNTIME=${KUJ_RUNTIME:-/tmp/kujamba-demo}
SRV="$RUNTIME/srv-build/bin/ninjamsrv"
KUJ="$REPO/zig-out/bin/kujamba"
REFPEER="$RUNTIME/refpeer"
PORT=${CHURN_PORT:-20533}
N=${N:-5}
CHURN=${CHURN:-12}
CHURN_DURATION=${CHURN_DURATION:-4}
CHURN_GAP=${CHURN_GAP:-3}

[ -x "$SRV" ] || { echo "no server at $SRV"; exit 2; }
[ -x "$KUJ" ] || { echo "no kujamba at $KUJ (zig build first)"; exit 2; }
[ -x "$REFPEER" ] || { echo "no refpeer at $REFPEER (run demo/run_demo.sh once to build it)"; exit 2; }
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT busy"; exit 2; fi

mkdir -p "$RUNTIME"
cat > "$RUNTIME/churn.cfg" <<CFG
Port $PORT
MaxUsers 10
MaxChannels 8 2
AnonymousUsers multi
AnonymousUsersCanChat yes
AnonymousMaskIP no
User kujamba secret C
DefaultTopic "churn repro (#28)"
DefaultBPM 100
DefaultBPI 8
SetKeepAlive 3
CFG

LOG="$RUNTIME/churn-server.log"
"$SRV" "$RUNTIME/churn.cfg" -logfile "$LOG" &
SRVPID=$!
sleep 0.7
cleanup() { kill $SRVPID 2>/dev/null; wait $SRVPID 2>/dev/null; }
trap cleanup EXIT

fail=0
for i in $(seq 1 "$N"); do
  D="$RUNTIME/churn-payloads-$i"; O="$RUNTIME/churn-out-$i"
  rm -rf "$D" "$O"
  echo "== victim $i (seed 42, 24 intervals, churners: $CHURN x ${CHURN_DURATION}s every ${CHURN_GAP}s) =="

  "$KUJ" join --host 127.0.0.1:$PORT --user kujamba --pass secret \
    --phrase "kujamba karibu" --seed 42 --pattern "3+1" --intervals 24 \
    --duration 150 --out-dir "$O" --dump-dir "$D" \
    --transcript "$RUNTIME/churn-transcript-$i.txt" \
    > "$RUNTIME/churn-summary-$i.txt" 2>&1 &
  VICTIM=$!

  # Churn for the first stretch of the victim's session, then stop launching
  # and let the victim finish alone — a late-session death says the server
  # never recovered from teardown churn, which is its own finding.
  launched=0
  while kill -0 $VICTIM 2>/dev/null && [ "$launched" -lt "$CHURN" ]; do
    "$REFPEER" --host 127.0.0.1:$PORT --user "anonymous:churn$launched" --pass x \
      --duration "$CHURN_DURATION" --freq 660 --amp 0.3 \
      --report "$RUNTIME/churn-peer-$i-$launched.report" \
      > "$RUNTIME/churn-peer-$i-$launched.log" 2>&1 &
    launched=$((launched + 1))
    sleep "$CHURN_GAP"
  done

  wait $VICTIM
  rc=$?
  res=$(grep -o 'RESULT.*' "$RUNTIME/churn-summary-$i.txt" | tail -1)
  echo "victim exit=$rc  $res"
  [ "$rc" -eq 0 ] || { echo "VICTIM $i DIED"; fail=1; }
done

echo "== server log: disconnects and errors =="
grep -cE "Accepted" "$LOG" | sed 's/^/accepted connections: /'
grep -E "EndOfStream|read failed|disconnect|Disconnect" "$LOG" | sort | uniq -c | head -20 || true

[ "$fail" -eq 0 ] && echo "CHURN: all victims OK" || echo "CHURN: victim failures observed"
exit $fail
