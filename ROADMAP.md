# Roadmap — Flatlophone / `kujamba` as a real instrument

Where the NINJAM instrument is today: a **headless** client that authenticates to
a real `ninjamsrv`, reads one Swahili fart phrase onto the server's BPI grid,
encodes each interval to Ogg Vorbis, and uploads it in time — with rest bars as
silence markers and byte-deterministic payloads per `(seed, phrase, BPI, BPM)`.
It passes a live end-to-end demo against the unmodified reference server
(`demo/run_demo.sh`) including a reference client core that decodes and measures
the audio energy.

That is a solid *tech demo*. This roadmap turns it into a **usable instrument** —
first in a NINJAM room, then as a standalone instrument people can actually
play. Each milestone is scoped so it can land, be tested, and be demoed on its
own.

> **Build order lives in [ISSUES.md](ISSUES.md)** — which issues block
> which, the recommended sequencing, and the vendored-file ledger. Short version:
> **#8, #9, #10, #11, #12, #17, #18, #19, #22, #25, #26 are landed**; **M4 is
> complete** and **M5 is now complete too** (#13 and #14 landed together — they
> share the same code path). Everything else is downstream.
> The `blocked-by` edges are encoded on the issues themselves. Tracked as
> [#31](https://github.com/drawmeanelephant/fart-app/issues/31).

> **How this relates to the product roadmap.** The R-series issues
> ([#2](https://github.com/drawmeanelephant/fart-app/issues/2)–
> [#5](https://github.com/drawmeanelephant/fart-app/issues/5)) are the *product*
> ladder; **M4–M8 below are the *engineering* build-out that underpins
> [R3 — Resident bandmates](https://github.com/drawmeanelephant/fart-app/issues/4)
> (always-on room instruments).** Each M is filed as a GitHub milestone with
> one issue per bullet, and each issue notes that it supports R3 — so the two
> taxonomies stay linked instead of drifting apart.

---

## M4 — Playable in a room (make the phrase an *instrument*)

Right now one phrase maps onto bars with `repeat`/`loop`/`once`. The gap to a
real instrument is **control while it runs**.

- [x] **Bar-accurate phrase switching.** (#11) ✅ **Landed.** A chat command takes effect at the
      next interval boundary, not mid-bar (the `IntervalPlan` hook already
      gives us a per-bar decision point). **Do this first** — widen the hook to
      carry *which phrase* and *which mode*, not just broadcast-or-not, or the
      next two both reshape it.
- [x] **Per-phrase render caching.** (#10) ✅ **Landed**, folded into #8's bank:
      every phrase is synthesized once at load and never again, and each entry
      owns its own `loop`/`once` cursor, so switching back resumes rather than
      restarts. The whole bank stays resident, so it is budgeted by rendered
      audio (64 MiB, ~6 min) rather than by file size — see ISSUES.md.
- [x] **Phrase bank + live selection.** (#8) ✅ **Landed** as `--phrases FILE`
      plus `!kujamba <n|name>` in room chat. The selector resolves when it is
      typed and is applied at the next bar boundary, reusing #11's
      once-per-interval hook, so a switch can never splice a phrase mid-bar. A
      selector that names nothing is counted (`phrase_rejected` in `RESULT`) and
      leaves the audio alone rather than dropping a bar. `name == phrase text`,
      so `<n>` and `<name>` are the same vocabulary. Mutually exclusive with
      `--phrase`, which is the same code path with a bank of one.
- [x] **Chat-driven transport.** (#9) ✅ **Landed.** `!kujamba play|rest|loop|repeat|once|stop`
      lets a bandleader shape the performance from the room without restarting
      the process. Blocked by #11.

## M5 — Timing that survives a real room

> ⚠️ **#12 was filed as an enhancement but contained a latent correctness bug**:
> a mid-session BPM/BPI change re-issued guids already sent (the id and the grid
> counter were the same field) and silently overwrote earlier payload dumps.
> **Fixed** — the monotonic sequence is now split from the grid position. See
> [ISSUES.md](ISSUES.md).

- [x] **Re-anchor on BPI/BPM changes without cutting the phrase.** (#12) `interval_idx`
      is split into `interval_seq` (monotonic identity: guids, serials, payload
      dump names, `--intervals`) and `interval_idx` (grid bar position: the
      pattern decision only). A `0x02` config change now moves the grid geometry
      and nothing else — the bar counter, the interval sequence, and the phrase
      cursor all run through it.
- [x] **Server-clock discipline.** (#13) ✅ **Landed.** `kujamba_out.ServerClock`
      anchors the bar grid on the `0x02` arrival and measures every boundary
      crossing against its own nominal end. The correction is bounded **twice** —
      as a fraction of the bar (1%) *and* in absolute nanoseconds (40 ms) — so a
      fast tempo cannot get a jumpy correction and a slow one cannot get a
      visible one. The encode target leads the wall clock by the same fraction,
      so the final flush and its `0x84` are in flight when the boundary arrives
      instead of starting at it; it changes *when* a bar is generated, never
      *what*, so the encoded bytes and the determinism evidence are untouched.
      Telemetry (`drift_ms`, `max_drift_ms`, `clock_corrections`) is in `RESULT`.
      See "What drift actually is" in ISSUES.md — the correction deliberately
      chases execution lag, not the server's epoch.
- [x] **Upload backpressure.** (#14) ✅ **Landed, measured first.** The socket
      write that stalled the audio clock was `net.zig`'s `writeAllRaw`, whose
      EAGAIN branch polls for 1000 ms in a loop and discards the return value —
      so it does not wait "up to a second", it waits a second, wakes, tries
      again, and never stops. Measured: one 16 KiB `sendMessage` against a socket
      whose peer had stopped reading **did not return after 5000 ms** and would
      not have returned at all. `finalizeInterval` called it inline, on the
      interval-generation path. Now `net.zig` has `sendMessageBounded`, the
      upload path uses it with a **zero** millisecond budget, and a socket that
      cannot take a bar costs the bar: `intervals_dropped` /
      `upload_bytes_dropped` are counted, the transcript names the bar and why,
      and the session continues at the next one with a fresh guid. A dropped
      channel sends nothing further — not even a silence marker, which would
      tell the room the instrument was resting when it was playing.

      > A dropped bar is only safe because **nothing** of its frame reaches the
      > wire, and the first cut of this did not guarantee that. The NINJAM frame
      > is `[u8 type][u32 LE len][payload]` on a byte stream with no resync
      > marker, so a torn frame is not one lost message: the server completes it
      > with the *next* bar's bytes and then reads a header from mid-stream, and
      > every message after that is garbage. A fresh guid does not save it —
      > the server never sees those bytes as a guid, they are the tail of the
      > frame before. Measured on that code: a half-full socket, a 16 KiB frame,
      > a zero budget — refused, and **6000 bytes on the wire**. So the drop is
      > now atomic: `net.zig` measures the send buffer's real free space
      > (`SO_SNDBUF` − queue depth, per target) against the whole frame *before*
      > touching the wire, and `sendMessageBounded` returns a three-valued
      > `SendOutcome`. `declined` carries a promise that not one byte went out and
      > is the only outcome that may drop a bar; `partial` fails the session,
      > because by then the stream cannot be framed again. `POLLOUT` is not that
      > question — it means "at least one byte free" and is true of a socket with
      > 6 KiB of room and a 16 KiB frame to put there.

## M6 — Sounds like an instrument (the synth as a playable voice)

- [ ] **Velocity / dynamics input.** (#15) Map a per-phrase or per-word intensity to
      `STRESS_LEVEL_BOOST` and the noise mix so phrases can be shouted or
      whispered.
- [ ] **Controllable vowel pitch table.** (#16) Let a preset shift the base freqs
      (`vowelBaseFreq`) up/down in cents for different "instruments."
- [x] **Loop seam crossfade.** (#17) ✅ **Already satisfied — no crossfade
      needed, and adding one regresses.** Measured: the loop wrap is already
      *exactly* click-free (wrap step 0.000000 on every phrase) because the synth
      is zero at both ends — the attack term is 0 at t=0 and the decay term is 0
      at u=1. A crossfade blends the already-zero tail into the head, so the loop
      ends mid-head then jumps back to head[0]: the wrap step grows to 0.080
      (5 ms) and 0.250 (2 ms), the latter larger than the biggest natural step in
      the file. A test now locks in the zero-at-both-ends invariant that makes
      `loop` seamless.
- [x] **Onset/decay knobs** (#18) exposed from `voiceSpec` (attack, noise, wobble) so
      the fart can be tuned from clean to chaotic without editing tables. ✅
      **Landed** as `--voice "attack=N,noise=N,wobble=N"` on `join` and `render`:
      multipliers, not absolutes, so each onset class keeps its character. The
      default `1` is a true bit-level identity — all 7 golden fingerprints pass
      unchanged — and each axis is clamped, because `attack=0` makes sample 0
      compute `0/0` and `wobble>2` drives the flutter term negative, flipping the
      waveform's polarity. Unblocks #15 and #16.

## M7 — Standalone instrument (not just a NINJAM client)

- [x] **`kujamba render`** (#19) — ✅ **landed.** Offline: phrase → WAV/OGG to
      disk, with `--play`/`--pattern`/`--bars`/`--bar-ms`/`--seed`, so people can
      use the synth outside a server. Drives the same `Fill`/`Pattern` the
      session plays, so the file is what a listener would have heard.
- [x] **Local audition** (#20) — ✅ **landed** (PR #48 + close-out): `kujamba play
      <phrase>` renders like `render` and plays through the vendored miniaudio
      device in `src/ninjam/audio.zig` — no `afplay` shell-out. `--device
      NAME|INDEX` picks the output; a missing device (or a build without
      `-Dlive`) exits 1 with a clear message. The bare positional phrase the
      issue names parses now too (`--phrase` still works, one or the other).
- [ ] **Real-time trigger input** (#21) — a keyboard/MIDI note maps to a phrase or a
      single syllable (`shuzi`) so it can be played like a sampler.
- [ ] **Config file** (#22) — `kujamba.toml`-style presets for host/user/pattern/
      phrase bank, so a session is a one-word command.

## M8 — Hardening & portability

> Two scope corrections found while reading these: **#20/#25** need a `-Dlive`
> build option (`build.zig` hardcodes `live = false`) and `miniaudio` is *not*
> vendored; **#25** is a Winsock shim plus a Windows console handler, not a
> build-flag flip. Also, **#26**'s fuzz harness belongs in a new non-vendored
> file — putting it inside `proto.zig`/`buf.zig` re-breaks the byte-identical
> invariant that #29 restores. See [ISSUES.md](ISSUES.md).

- [x] **IPv6 transport.** (#23) ✅ **Landed.** `net.zig` is family-agnostic: IPv6
      literals take a `sockaddr_in6` fast path, the getaddrinfo hint is
      `AF.UNSPEC` and the loop opens each candidate's own socket and falls
      through a refused connect to the next family, so v6-first resolvers still
      reach v4-only servers (and vice versa). Verified end-to-end against the
      reference `ninjamsrv` over `[::1]` and covered by loopback tests.
- [x] **Reconnect with backoff.** (#24) ✅ On `EndOfStream`/stall, rejoin and
      resume from the next bar instead of exiting (the run loop's stall detector
      already notices). Unblocked by #12: the bar counter is now independent of
      interval identity, and `IntervalIndex.reanchor` is the hook for a resume.
      The `--intervals` cap counts the monotonic sequence, so it now demonstrably
      spans reconnects — the seam test #12 could not reach without a socket is
      in, driven against a scripted server that kills the connection mid-bar.
      The `--reconnect [N]` flag turns it on; it is deliberately **off by
      default** so the CI demo keeps reporting connection deaths verbatim while
      #28 is open — a reconnect that papers over the flake would blind the gate
      measuring it. The `RESULT` line reports `reconnects=` and the total
      `outage_ms=` either way.
- [ ] **Cross-platform builds.** (#25) `kujamba` is mostly portable (posix sockets);
      verify on Linux and Windows (Winsock) and drop the macOS-only assumption
      that lives in `src/main.zig`, not the instrument.
- [ ] **Fuzz the protocol parsers.** (#26) `proto.zig`/`buf.zig` are length-checked
      but feed a network — add a fuzz target over `parseIntervalBegin/Write`,
      `parseUserinfoRecords`, `parseChat`.
- [ ] **CI demo.** (#27) Run `demo/run_demo.sh` on a macOS runner so the live
      reference-server test gates merges, not just the unit tests.

---

## Testing status (this pass)

- Unit suites: **180/180 pass** (`zig build test`) — audit + synth + **golden
  fingerprints** + kujamba glue + the vendored NINJAM modules + the M5 timing
  harness, in five targets. Synth tests are fail-against-silence enforced. Also
  green under `-Doptimize=ReleaseSafe`, which is the mode the demo builds in,
  and under `-Dlive=false`.
- **Mutation testing** (`./mutate.sh`): **21 mutations, 21 caught, zero
  survivors**, ending reverted-and-green. A guard with no test that bites it is
  worse than no guard, because it reads as coverage. The two guards added for
  the frame-atomicity fix are both covered: deleting the frame-fit check is
  caught by the half-full-socket test, and halving its threshold is caught by
  the same test.
- **Synth golden fingerprints** (`src/golden.zig`, own test target): four
  phrases and three shuzi seeds, each pinned on syllable count, sample count,
  peak, zero crossings, and a SHA-256 of the 10 ms windowed RMS energy
  envelope. Any unintended change to the voice tables, syllable timing, wobble
  or the PRNG salt fails `zig build test` before it can reach the demo, and a
  mismatch prints a ready-to-paste re-baseline block.

  > It deliberately does **not** assert on a SHA-256 of the WAV bytes. That was
  > tried first and measured: the same source on the same machine renders
  > different exact bytes in Debug vs ReleaseSafe, because LLVM contracts the
  > synth's `@exp`/`@sin` differently at different optimization levels. A guard
  > that goes red on `ReleaseSafe` — and would go red again on Linux and on CI —
  > is worse than no guard. The windowed-energy envelope is bit-stable across
  > optimization modes and still catches every mutation tested. See the header
  > of `src/golden.zig`.
- Config changes are covered end to end (#12): a real `0x02` is driven through
  `Session.dispatch`, and the test fails if the counters are reset, if the guid
  is re-keyed onto the grid position, or if the payload dump is named after the
  grid position instead of the sequence.
- Live demo: **DEMO PASS** against the unmodified reference `ninjamsrv` +
  `demo/refpeer.cpp` (reference client core) — 6 intervals, 5 fart bars decoded
  with measured energy, 1 rest bar as a silence marker, negative control
  (silence) correctly rejected, and **byte-identical payloads across two runs**
  (and across every change since: the recorded shas have not moved).
- Isolation harness `demo/repro_double_run.sh` runs N back-to-back same-seed
  sessions against one server to stress the deterministic-id path.

### Known flake (documented, not a regression)

> Tracked as [#28](https://github.com/drawmeanelephant/fart-app/issues/28).
> It now also has a sharper local-side hypothesis to test before the server-side
> one — see [ISSUES.md](ISSUES.md). Do not close it via #24; reconnect makes the
> symptom survivable but would mask the real cause.
>
> Measured 2026-09-30: 30/30 isolation runs clean, 60 refpeer teardowns across
> 5 victim sessions clean (`demo/repro_teardown_churn.sh` — the incident
> geometry, amplified), and 18/18 green in the CI demo job that runs the
> original scenario on every PR. Still zero reproductions; still open.

On one run the second determinism session was dropped by the server
(`read failed: EndOfStream`) at interval 2 with no server-side log entry, in the
window where `refpeer` disconnects as run 2 connects. The evidence strongly
suggests it is **not** caused by these changes — scenario A passed, three
same-seed runs pass in isolation, and a full re-run passed cleanly — but three
isolation runs and one clean re-run is strong evidence, not proof. The
server-side interaction between one client tearing down and another bursting
uploads in the same second is the suspected cause. M8's reconnect work would
make this a non-event even if it recurs. Tracking it as an open question rather
than a closed one.

---

## What already works (don't redo)

- Deterministic transport ids (`deriveGuid`/`deriveSerial`) → byte-identical
  payload bytes per `(seed, phrase, BPI, BPM)`.
- Rest bars as NINJAM silence markers; dead air is never uploaded as audio.
- Single channel registered as `kujamba` (`0x82`), auto-subscribe (`0x81`),
  keepalive (`0xFD`).
- `repeat`/`loop`/`once` phrase-to-grid mapping + `check-ogg` / `encode-silence`
  analysis and negative-control commands.
- Graceful `Ctrl+C`/`SIGTERM`: finishes the current interval, prints `RESULT`,
  exit code reflects whether anything was uploaded.
- Exit-code honesty: `join` exits 0 only if ≥1 interval was uploaded.
