# #14: constrained-socket measurement

Run the complete session, not just a write or `finalizeInterval` unit test:

```bash
zig build repro-backpressure -Doptimize=ReleaseSafe
```

The rig in `src/kujamba_backpressure.zig` performs the real handshake and
drives `Session.run()`. A deterministic, non-silent noise source fills an
800 ms bar (300 BPM, 4 BPI, 48 kHz). The peer stops reading for four seconds
while sending keepalives every 50 ms, then resumes reading on the **same
connection**. It parses the upload frames and decodes completed Ogg intervals.
The client runs for 7.2 seconds. Its actual `SO_SNDBUF` is printed.

## Before the fix

Measured on macOS, Zig 0.16.0, ReleaseSafe, base `50a324e`, with only the
measurement rig/build target added, before changing the session/transport:

| Measurement | Result |
|---|---:|
| Requested / actual send buffer | 8192 / 8192 bytes |
| Session ended after | 803 ms |
| Bars started | 1 |
| Complete uploads / drops counted | 0 / 0 |
| Complete intervals received by peer | 0 |

The failure was `upload frame of 1104 bytes could not be written whole`.
The transport had already written part of the frame, then closed the
connection. This is a **lost interval and failed session**, not evidence of
an audible gap from a playback device. Rejoining would mask this outcome,
so the rig leaves reconnect disabled.

A first attempt with constrained loopback TCP completed normally: 9 uploads,
0 drops, maximum bar-start gap 806 ms. Darwin's loopback buffering still
absorbed the traffic despite `SO_SNDBUF=8192` and `SO_RCVBUF=4096`. That did
**not** exercise backpressure. The rig therefore uses a nonblocking Unix
stream socket pair with an exact small buffer. It still runs the actual
session clock, framing, encoder, and peer parser, rather than a mocked writer.

## After the fix

Observed on the same host, with the same stream socket/source/peer:

| Measurement | Result |
|---|---:|
| Session elapsed | 7200 ms |
| Bars started at 2 s / 4 s | 3 / 6 |
| Total bars started | 10 |
| Maximum bar-start gap | 794 ms |
| Complete uploads / dropped bars | 3 / 6 |
| Unsent encoded bytes discarded | 18842 |
| Maximum upload section time | 5 ms |
| Fresh, non-silent intervals decoded after draining | 3 |
| First recovered interval sequence | 6 |
| Framing or decode errors | 0 |

Timing/byte totals can vary slightly with scheduling. Acceptance asserts
progress during the blockage, bounded bar gaps and run duration, nonzero
drop/byte counters, and successful decoding of fresh guids after draining.
The first fresh bar after the dropped in-flight bar succeeds; stale bars are
not retried. `zig-cache/backpressure/session.log` records every lost bar.

## What changed

- All session writes are nonblocking, including keepalive/chat/registration.
- A short write retains **only the mandatory frame tail**. No new upload is
  queued behind it; the rest of that interval is dropped.
- The fixed 64 KiB control/tail queue preserves ordering and fails explicitly
  if full. It is not an unbounded queue of late audio.
- Incomplete inbound frames yield, input dispatch has a per-pass cap, and
  polling waits only until the next audio deadline (at most 20 ms).
- Dropped bars still advance the source/capture clock without retaining or
  encoding the remainder. The next interval starts with a new guid.
- `intervals_dropped`, `intervals_backpressured`, and
  `upload_bytes_dropped` are reported; unsent bytes count across all channels,
  while already-sent payload-dump bytes do not count as discarded.

The new `Stats.intervals_backpressured` field is a **conscious vendored
`session.zig` divergence**. The transport/session changes are recorded in
`ISSUES.md` for #29's upstream reconciliation.
