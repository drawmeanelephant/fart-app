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
> start with **#11, #10, #18, #12, #19, #27**; everything else is downstream.
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

- [ ] **Bar-accurate phrase switching.** (#11) A chat command takes effect at the
      next interval boundary, not mid-bar (the `IntervalPlan` hook already
      gives us a per-bar decision point). **Do this first** — widen the hook to
      carry *which phrase* and *which mode*, not just broadcast-or-not, or the
      next two both reshape it.
- [ ] **Per-phrase render caching.** (#10) Rendering a phrase is cheap but do it once
      per phrase up front so live switching is instant and deterministic.
- [ ] **Phrase bank + live selection.** (#8) `--phrases FILE` loads many phrases;
      `!kujamba <n>` in room chat selects the next one (the client already
      receives `0xC0` chat — parse it and act on it). Blocked by #10 and #11.
- [ ] **Chat-driven transport.** (#9) `!kujamba play|rest|loop|repeat|once|stop`
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
- [ ] **Server-clock discipline.** (#13) Track drift against the server's interval
      boundary (the `0x02` config arrival + local clock) and nudge the encode
      target so uploads land in the window even on a jittery connection.
- [ ] **Upload backpressure.** (#14) If `write` would block, don't stall the audio
      clock — drop to the next interval and note it in the transcript (the
      `Stats` struct has room for a counter).

## M6 — Sounds like an instrument (the synth as a playable voice)

- [ ] **Velocity / dynamics input.** (#15) Map a per-phrase or per-word intensity to
      `STRESS_LEVEL_BOOST` and the noise mix so phrases can be shouted or
      whispered.
- [ ] **Controllable vowel pitch table.** (#16) Let a preset shift the base freqs
      (`vowelBaseFreq`) up/down in cents for different "instruments."
- [ ] **Loop seam crossfade.** (#17) The 8 ms end fade stops clicks; a short
      crossfade at the wrap point would make `loop` mode seamless.
- [ ] **Onset/decay knobs** (#18) exposed from `voiceSpec` (attack, noise, wobble) so
      the fart can be tuned from clean to chaotic without editing tables.

## M7 — Standalone instrument (not just a NINJAM client)

- [x] **`kujamba render`** (#19) — ✅ **landed.** Offline: phrase → WAV/OGG to
      disk, with `--play`/`--pattern`/`--bars`/`--bar-ms`/`--seed`, so people can
      use the synth outside a server. Drives the same `Fill`/`Pattern` the
      session plays, so the file is what a listener would have heard.
- [ ] **Local audition** (#20) — `kujamba play <phrase>` renders and plays through
      the platform audio path (reuse the compiled-out miniaudio `live` path in
      `src/ninjam/audio.zig` instead of `afplay`).
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

- [ ] **IPv6 transport.** (#23) The CLI parses `[::1]:port`, but `net.zig` resolves
      via `AF.INET` only — add IPv6 resolution and dual-stack sockets.
- [ ] **Reconnect with backoff.** (#24) On `EndOfStream`/stall, rejoin and resume
      from the next bar instead of exiting (the run loop's stall detector
      already notices). Unblocked by #12: the bar counter is now independent of
      interval identity, and `IntervalIndex.reanchor` is the hook for a resume.
      Still needs a test of the `--intervals` cap across a reconnect, which
      #12 could not reach without a socket.
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

- Unit suites: **84/84 pass** (`zig build test`) — audit + synth + **golden
  fingerprints** + kujamba glue + the vendored NINJAM modules, in five targets.
  Synth tests are fail-against-silence enforced. Also green under
  `-Doptimize=ReleaseSafe`, which is the mode the demo builds in.
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
