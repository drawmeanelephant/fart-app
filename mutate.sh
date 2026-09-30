#!/usr/bin/env bash
# Mutation testing for the M5 timing guards (#13, #14).
#
#   ./mutate.sh          run every mutation
#   ./mutate.sh <n>      run just mutation n
#
# Why this file exists: a test that passes whether or not the guard is present
# is worse than no test, because it reads as coverage and is not. Each entry
# below breaks exactly one guard and reports which tests went red. Three
# outcomes, all meaningful:
#
#   CAUGHT       a test failed — the guard is covered
#   SURVIVED     the whole suite still passed — a hole in the tests
#   NO-OP        the mutation did not apply — a hole in this script
#   BUILD ERROR  the mutation does not compile — also a hole, but in the entry
#
# Mutations are applied by exact substring replacement (python, not sed: BSD sed
# needs an explicit -i extension, and a partial match silently mutates nothing)
# and every file is restored from a pristine copy afterwards. The final run is a
# clean `zig build test` so the evidence ends with "reverted, still green".
set -u
cd "$(dirname "$0")"

FILES=(src/ninjam_out.zig src/ninjam/session.zig src/ninjam/net.zig src/kujamba_timing.zig src/kujamba_main.zig)
BK=$(mktemp -d)
for f in "${FILES[@]}"; do mkdir -p "$BK/$(dirname "$f")"; cp "$f" "$BK/$f"; done
restore() { for f in "${FILES[@]}"; do cp "$BK/$f" "$f"; done; }
trap 'restore; rm -rf "$BK"' EXIT

# $1 file, $2 python-escaped old text, $3 python-escaped new text
apply() {
python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
if old not in src:
    sys.exit(3)
open(path, "w").write(src.replace(old, new, 1))
PY
}

mutate() { # file  old  new  label
  local file="$1" old="$2" new="$3" label="$4"
  restore
  if ! apply "$file" "$old" "$new"; then
    echo "MUTATION $label"
    echo "    NO-OP: the exact text to replace was not found <-- gap in this script"
    return
  fi
  local out summary
  out=$(zig build test --summary all 2>&1)
  summary=$(echo "$out" | grep -E "^Build Summary:" | tail -1)
  # Compile errors are always reported as `file.zig:LINE:COL: error:`. Matching
  # on a bare `^error:` instead also catches zig's own trailer, "error: the
  # following build command failed", and every mutation then reads as a build
  # error rather than as what it did to the tests.
  if echo "$out" | grep -qE "\.zig:[0-9]+:[0-9]+: error:"; then
    echo "MUTATION $label"
    echo "    BUILD ERROR: the mutation does not compile <-- gap in this entry"
    return
  fi
  local failed
  failed=$(echo "$out" | grep -oE "error: '[A-Za-z0-9_.]+\.test\.[^']+' failed" \
           | sed "s/error: '//; s/' failed//" | sort -u)
  if [ -n "$failed" ]; then
    echo "MUTATION $label"
    echo "$failed" | sed 's/^/    CAUGHT by /'
  elif echo "$summary" | grep -qE "crashed|failed"; then
    echo "MUTATION $label"
    echo "    CAUGHT (suite aborted: $summary)"
  elif echo "$summary" | grep -q "12/12 steps succeeded"; then
    echo "MUTATION $label"
    echo "    *** SURVIVED *** <-- no test depends on this guard"
  else
    echo "MUTATION $label"
    echo "    INCONCLUSIVE: $summary"
  fi
}

ONLY="${1:-}"
n=0
run() {
  n=$((n + 1))
  if [ -n "$ONLY" ] && [ "$ONLY" != "$n" ]; then return; fi
  echo "--- [$n] $4"
  mutate "$1" "$2" "$3" "$4"
  echo
}

echo "=== mutation testing: M5 timing guards (#13, #14) ==="
echo

# ============ #13 ServerClock: the two halves of the slew bound ==============

run src/ninjam_out.zig \
'        const fractional = @divTrunc(self.interval_ns, @as(i128, self.max_slew_div));
        return @max(0, @min(self.max_slew_ns, fractional));' \
'        const fractional = @divTrunc(self.interval_ns, @as(i128, self.max_slew_div));
        return @max(0, fractional);' \
"#13 slew: drop the ABSOLUTE cap (a 10 s bar could jump 100 ms)" 1

run src/ninjam_out.zig \
'        const fractional = @divTrunc(self.interval_ns, @as(i128, self.max_slew_div));
        return @max(0, @min(self.max_slew_ns, fractional));' \
'        return @max(0, self.max_slew_ns);' \
"#13 slew: drop the FRACTIONAL cap (a 200 ms bar could jump 40 ms)" 2

# ============ #13 ServerClock: the correction itself =========================

run src/ninjam_out.zig \
'        return std.math.clamp(want_ns, -limit, limit);' \
'        _ = limit;
        return want_ns;' \
"#13 slew: do not clamp the correction to the limit" 3

run src/ninjam_out.zig \
'        return nominal + correction;' \
'        return nominal - correction;' \
"#13 slew: apply the correction backwards" 4

run src/ninjam_out.zig \
'        const correction = self.clampCorrection(drift);' \
'        _ = drift;
        const correction: i128 = 0;' \
"#13 slew: measure the drift but never correct for it" 5

# ============ #13 encode lead =================================================

run src/ninjam_out.zig \
'        const lead_ns = @min(self.slewLimitNs(), 50 * std.time.ns_per_ms);' \
'        const lead_ns = 50 * std.time.ns_per_ms;' \
"#13 lead: ignore the slew bound when opening the upload window" 6

# NOT MUTATED, DELIBERATELY: the trailing
#   @min(@as(u64, @intCast(@divTrunc(lead_ns, per_sample))), interval_len_samples)
# in `encodeLeadSamples` is provably unreachable at max_slew_div = 100 (lead_ns
# <= interval_ns/100, so lead_samples <= bar/100), and the tempo sweep in
# ninjam_out.zig covers the *property* the clamp protects instead. Removing the
# clamp survives, and that is the honest result: it is insurance, not logic.

# ============ #13 telemetry ==================================================

run src/ninjam_out.zig \
'        if (mag > self.max_abs_drift_ns) self.max_abs_drift_ns = mag;' \
'        if (mag < 0) self.max_abs_drift_ns = mag;' \
"#13 telemetry: stop remembering the worst bar" 8

# ============ #14 the write budget ===========================================

run src/ninjam/session.zig \
'pub const upload_write_budget_ms: i32 = 0;' \
'pub const upload_write_budget_ms: i32 = 1000;' \
"#14: give the upload write a one-second budget again" 9

run src/ninjam/net.zig \
'        const deadline_ms = clock.nowMs(self.io) + budget_ms;' \
'        const deadline_ms = clock.nowMs(self.io) + budget_ms + 1000;' \
"#14: ignore the caller's write budget in net.zig" 10

# ============ #14 counting ===================================================

run src/ninjam/session.zig \
'            self.stats.intervals_uploaded += 1;' \
'            self.stats.intervals_uploaded += 1;
            self.stats.intervals_dropped -= 1;' \
"#14: a dropped bar also counts as uploaded" 11

run src/ninjam/session.zig \
'            if (lc.dropped) dropped_here = true;' \
'            dropped_here = dropped_here;' \
"#14: a dropped bar is not recognised as dropped" 12

run src/ninjam/session.zig \
'            self.stats.upload_bytes_dropped += discarded;' \
'            self.stats.upload_bytes_dropped += discarded - discarded;' \
"#14: stop counting the discarded bytes" 13

run src/ninjam/session.zig \
'        if (!self.drop_marked) {' \
'        if (true) {' \
"#14: count one drop per channel instead of per bar" 14

# NOT MUTATED, DELIBERATELY: the `and !lc.dropped` in
#     if (lc.broadcast and !lc.dropped) streaming += 1;
# is redundant. `intervals_broadcast` is only accumulated on the `else` of
# `if (dropped_here)`, so by the time `streaming` reaches it, nothing was
# dropped. Dropping the conjunct therefore survives, which is the honest
# result. It stays because it makes the local expression correct on its own
# terms rather than correct only in the context of the branch above it; the
# decision that actually matters is mutation 12.

# ============ #14: a dropped channel must stay silent ========================

run src/ninjam/session.zig \
'            if (lc.dropped) continue;
            if (lc.broadcast) {' \
'            if (lc.broadcast) {' \
"#14: keep sending after a channel was dropped" 15

echo "=== reverted: the suite must be green again ==="
restore
zig build test --summary all 2>&1 | grep -E "^Build Summary:" | tail -1
