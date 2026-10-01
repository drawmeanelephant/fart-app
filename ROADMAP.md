# Roadmap / engineering status

As of **2026-10-01**, the filed macOS/Linux instrument build-out is complete.
The user manual now lives in [the Boris documentation site](docs/README.md),
not in milestone notes. [ISSUES.md](ISSUES.md) retains the sequencing history
and source-ownership ledger.

## Landed milestones

| Milestone | Delivered | Issues |
|---|---|---|
| M4 / Playable in a room | Once-per-boundary phrase/mode changes, render caching, phrase banks, room-chat transport | #8, #9, #10, #11 |
| M5 / Timing | Monotonic interval identity across tempo changes, bounded clock discipline, nonblocking upload/drop recovery | #12, #13, #14 |
| M6 / Voice | Effort/dynamics, vowel pitch, measured seamless-loop invariant, onset/noise/wobble controls | #15, #16, #17, #18 |
| M7 / Standalone | WAV/Ogg rendering, playback-only audition, stdin/script note sampler, config presets | #19, #20, #21, #22 |
| M8 / Hardening | IPv6, reconnect/backoff, full-dispatch fuzz corpus, native Linux/macOS CI, reference demo gate | #23, #24, #26, #27 |
| Follow-through | Flake investigation closeout, measured partial-frame ownership/recovery, verified reference provisioning, upstream reconciliation | #28, #14 follow-up, #58, #29 |

The older R-series product ladder (#2–#5) motivated these engineering
milestones. A completed engineering milestone does not imply an unlimited
resident-service mode, hardware MIDI support, or an untested platform.

## Remaining portability work

**#25: Windows**, deferred until native validation is available. Required work
includes Winsock integration and console handling; audio/speech behavior also
needs a native check. Linux builds, tests, and smoke runs are already verified.
Do not count upstream reference C++ Windows CI as evidence for this Zig app.

Any future shared transport change must follow the upstream-first source
contract in [vendor/README.md](vendor/README.md), not silently diverge.

## Verification baseline

- **218/218** tests after #29, in Debug, ReleaseSafe, and `-Dlive=false`,
  plus the standalone null-backend C ABI executable.
- Native Linux/macOS CI, with `build-test` and `demo-e2e` required on main.
- Real unmodified-reference demo: decoded audio energy, rest markers, silence
  rejection, and equal-input deterministic upload payloads.
- All five #29 upload hashes matched the pre-refactor #58 baseline.
- Constrained-session reproduction: continued clock progress through a
  four-second blocked peer, counted drops, aligned frames, and decoded recovery
  on the same connection.
- The #28 investigation is **closed**; the required demo remains the standing
  recurrence monitor. A new occurrence should reopen investigation, not be
  concealed by reconnect retries.

These are recorded baselines, not fixed test counts for all future changes.
Current verification instructions are in
[Testing and evidence](docs/site/content/contributors/testing.md).

## What is not a pending bug

- Default join limits are deliberate safety caps; choose explicit limits for
  longer sessions.
- Chat controls have no authorization layer; room messages that reach the hook
  can control the instrument.
- Synthesized bytes are reproducible in the same build/configuration, not
  guaranteed across optimization modes/platforms. Goldens use stable energy
  fingerprints; equal-input demo runs separately compare exact upload hashes.
- A dropped upload is not a no-audible-gap promise. The clock and source advance,
  but a listener may hear a missing interval.

Future product work should be filed and scoped explicitly, rather than inferred
from stale unchecked boxes. #31 is the historical issue-map tracker; the docs
closeout PR completes that bookkeeping.
