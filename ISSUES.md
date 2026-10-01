# Issue map & sequencing

Companion to [ROADMAP.md](ROADMAP.md). The roadmap says *what* each milestone
builds; this file says **what order to build it in**, which issues block which,
and which decisions get made once instead of three times.

The dependency edges below are also encoded as GitHub `blocked-by` relations on
the issues themselves, so `gh issue view 12` shows them without reading this.

**State at time of writing:** 4 milestones (M4–M8), M4 complete and M5 complete
(#13 + #14 landed together). `zig build test` → **180/180 pass** in five suites,
in Debug, ReleaseSafe and `-Dlive=false`. CI gates pushes and PRs (build + test,
`build-test`, on Linux); it is not yet required by `main`'s ruleset, and it does
not yet run the live demo (#27).

Two open issues (#40, #41) are crash bugs the #26 fuzzer found in the client:
a wire-controlled `channel_id >= 32` and a `bpm=0` config both panic. Both are
small, and both belong in `src/ninjam/session.zig` — so they cannot be picked up
in parallel with each other, or with #8's branch, which also edits that file.

Tracking issue for this map: [#31](https://github.com/drawmeanelephant/fart-app/issues/31).

---

## The short version

Six issues are effectively unblocked and everything else is downstream of them.
Start there. The two things most likely to be picked up first from a
milestone-number ordering — #8 and #9 — are both **blocked**, and the one that
unblocks them (#11) is the smallest item in M4.

| Start here | Why it's unblocked | What it unblocks |
|---|---|---|
| **#11** Bar-accurate switching | ✅ **done** — one-time hook reshape, `Selection{broadcast,mode,samples}` | #8, #9 |
| **#10** Render caching | ✅ **done** — folded into #8's `PhraseBank` | #8 |
| **#18** voiceSpec knobs | ✅ **done** — `--voice` multipliers, see below | #15, #16 |
| **#12** Re-anchor on config change | ✅ **done** — split the counters, see below | #24, #29 |
| **#19** Offline render | ✅ **done** — `kujamba render`, see below | verification harness for M6 |
| **#8** Phrase bank | ✅ **done** — `--phrases FILE` + `!kujamba <n\|name>` | M4 complete |
| **#27** CI demo | Extends the existing `build-test` job with the live reference-server run | #28 (flake rate), the safety net for everything |
| **#13** Server-clock discipline | ✅ **done** — `ServerClock`, bounded slew, encode lead | M5 complete |
| **#14** Upload backpressure | ✅ **done** — measured, then bounded write + drop-and-continue | M5 complete |

Everything else is Wave 2+ and can proceed in parallel once the above land.

---

## Dependency graph

```
        #11 ──┬──> #8 <── #10          #18 ──┬──> #15
              └──> #9                  #12 ──> #24
        #8 ──┬──> #21
              └──> #22                  #19  (no deps — also the M6 test harness)

        #27 ──> #28

        #12 #13 #14 #23 #24 #25 #26 ──> #29   (final vendored reconciliation)
```

### The four edges that matter most

1. **#11 before #8 and #9.** ✅ Done — the hook is now `selectFor(...) -> Selection{broadcast, mode, samples}`,
   consulted once per interval and applied at the bar boundary. **#8 and #9 no longer need to
   reshape the vendored hook.** The original note: `IntervalPlan.broadcastFor` returned `bool`. All three
   issues need it to carry *which phrase* and *which mode*. Doing #8 or #9 first
   means reshaping this vendored hook twice. The hook is consulted exactly once
   per interval, *before* any audio is generated — which is what makes
   "applies at the start of bar N+1" true by construction rather than by a latch.
   Preserve that if you touch it.

2. **#10 before #8.** ROADMAP.md listed #8 first; #8's own body defers to #10.
   Fixed in ROADMAP.md.

3. **#18 before #15 and #16.** All of M6 threads parameters through the same two
   functions. Doing them separately means that threading three times.

4. **#29 last, and batched.** See the vendored-file ledger.

---

## ⚠️ Latent bug found while reading #12 — **fixed**

`#12` was filed as an *enhancement* ("re-anchor on BPI/BPM change without cutting
the phrase"), but it was sitting on top of a correctness bug:

- `onConfig` sets `self.interval_idx = 0` (`src/ninjam/session.zig:950`)
- but `deriveGuid` / `deriveSerial` key off `interval_idx` (`src/ninjam/session.zig:572-573`)

So a mid-session BPM/BPI change **re-issues guids already sent this session,
carrying different payload bytes**. Separately, `writePayloadDump` names files
`interval_{interval_idx:0>4}.ogg` (`src/ninjam/session.zig:705`), so it
**silently overwrites** earlier dumps — quietly corrupting the determinism
evidence the demo depends on.

**Fix shipped.** The two roles are now split as suggested, in `IntervalIndex`
(`src/ninjam_out.zig`):

| Field | Drives | Property |
|---|---|---|
| `index.seq` | guid/serial derivation, dump filename, `--intervals` cap | **monotonic** across config changes |
| `index.grid` | pattern / broadcast decision only | grid position, may re-anchor |

A `0x02` config change now moves the grid geometry and nothing else. This makes
#24's "resume at the next bar" meaningful, and keeps determinism intact across a
reconnect.

Config changes are now covered by tests, including a seam test that drives a
real `0x02` through `Session.dispatch`. The one path not covered is the
`--intervals` cap, which lives in `finalizeInterval` and is unreachable without a
socket — #24 should pick that up.

---

## Vendored-file ledger

`src/ninjam/` is vendored from `drawmeanelephant/ninjam` branch `agent/zclient`
(commit `f428caf`). The "12 of 12 byte-identical" invariant in #29 is only
maintainable if new divergence is batched, not dripped in per-issue.

| File | Status | Diverged by |
|---|---|---|
| `src/ninjam/session.zig` | **already diverged** (kujamba hooks) | #12, #13, #14, #24, #25 |
| `src/ninjam/net.zig` | **already diverged** (bounded legacy writes; #14 nonblocking frame-tail/control queue, yielding reads, platform-correct `O_NONBLOCK`) | #14, #23, #25 |
| `src/ninjam/proto.zig` | byte-identical | #26 — *only if* the harness lands in-tree |
| `src/ninjam/buf.zig` | byte-identical | #26 — *only if* the harness lands in-tree |
| `src/ninjam/audio.zig` | byte-identical (live path compiled out) | #20 (`-Dlive` toggle + miniaudio) |
| `src/ninjam_out.zig` | **new** (not vendored) | #10, #11, #12, #13, #17, #22, #24 |
| `src/kujamba_main.zig` | **new** (not vendored) | #8, #9, #19, #20, #21, #22, #25 |
| `src/kujamba_timing.zig` | **new** (not vendored) | #13, #14, #24 — the M5 timing harness + the reconnect test rig |
| `src/synth.zig` | **new** (not vendored) | #15, #16, #18 |
| `src/golden.zig` | **new** (not vendored) | guards #15, #16, #17, #18 |

> **`net.zig` had to be touched, and it is worth being honest about why.** The
> rule above is "push down into `src/ninjam/` only when there's no choice", and
> for #14 there was not one. The stall is *inside* `writeAllRaw`: the socket is
> non-blocking, so a peer that stops reading turns `write` into EAGAIN, and the
> EAGAIN branch polls for 1000 ms in a loop while discarding the result. No
> caller can bound that from outside — the only lever a caller has is whether to
> call, and "don't call" is not the same as "call and give up". The original
> bounded-write API is retained for its existing measurements, but the #14
> follow-up moves **every session write**, including control messages, to a
> nonblocking writer. A partial frame's mandatory tail stays in a fixed-size
> queue, never abandoned or interleaved with another frame. Reads also yield
> on incomplete frames. `SO_SNDBUF` minus queue depth is advisory, not an
> atomic-write guarantee.

**#14 follow-up (2026-10-01):** the constrained `Session.run()` reproduction
failed after ~803 ms with zero complete uploads: a short write closed the
connection, rather than merely dropping one interval. After the fix it walks
the interval grid throughout the four-second blockage and decodes new bars
on the same connection once the peer drains. See `demo/backpressure.md`.
`Stats.intervals_backpressured` is a conscious additional vendored field for
#29: it separates write pressure from #24's reconnect losses. Byte accounting
now counts every channel's unsent bytes once, excludes already-sent dump
bytes, and keeps the per-bar drop latch across mid-bar and final writes.

**Rule of thumb:** if a change can live in `ninjam_out.zig` or
`kujamba_main.zig`, it should. Push down into `src/ninjam/` only when there's no
choice, and batch those pushes into #29.

#29 is therefore best reframed as a **feature PR upstream** (instrument hooks +
IPv6 + any net fixes, in one go) rather than a local-hygiene chore. That's a
much easier ask of the upstream repo than "take our local edits."

---

## Decisions to make once, not per-issue

These recur across issues. Settling them early avoids rework; each has a
recommended answer.

| Decision | Blocks | Recommendation |
|---|---|---|
| **Is the voice preset part of the render key?** There is no render key today — `synth.zig:408` seeds the PRNG from `Wyhash.hash(0x5EED_F00D, phrase)`, text only. | #15, #16 | Decide once, document as a determinism claim. Keeping intensity *out* of the seed gives two intensities of one phrase identical noise — arguably better for A/B. |
| **`interval_seq` vs `interval_idx`** | #12, #24, #29 | **Settled** — split as `IntervalIndex{seq, grid}`. See the bug section above. |
| **Is the bar grid open or closed loop?** | #13, #24, #29 | **Settled — closed loop, correcting toward the wall clock.** `interval_start_ns += interval_ns` silently inherited every stall into the next bar. `ServerClock` measures each crossing and applies a correction bounded by both a fraction of the bar and 40 ms absolute. Deliberately *not* locked to the server's epoch: that offset is a constant of unknown one-way latency and the server re-times on arrival anyway. See "What drift actually is" above. |
| **How long may a socket write wait?** | #14, #24 | **Settled — zero for every session write.** Uploads use `trySendMessage`; keepalive, chat, and registration use the bounded control queue. All flushes return on EAGAIN without polling. Small control messages are not exempt: they can block on a full socket too. |
| **May a write be half-done and then abandoned?** | #14, #31 | **Settled — no, never.** Frames have no resync marker. A short write's mandatory tail stays owned by `Conn` and finishes asynchronously, ahead of later control/upload frames. The rest of the bar is dropped. Free-space estimates are advisory; correctness comes from tail ownership, not an assumed atomic TCP write. Real connection errors still go through #24. |
| **Where does the loop crossfade live?** | #17, #8 | In `Fill.copyInto` (`cursor % n` at `ninjam_out.zig:72`), **not** in `renderPhraseF32`. In the render it would double-fade and wrongly affect `repeat`/`once`. |
| **Golden hash for the synth** | #15, #16, #17, #18 | **Settled, and not a byte hash.** An exact WAV SHA-256 was tried and rejected on measurement: Debug and ReleaseSafe render different exact bytes from identical source, because LLVM contracts the synth's `@exp`/`@sin` differently per optimization level. Measured across all 7 baseline entries, the exact WAV hash differs between modes for **3 of them** (`kujamba karibu`, `asante sana kijiji`, `shuzi seed 0`) — the shorter, simpler renders happen to be stable, so a byte-hash guard would look fine locally and go red on CI. `src/golden.zig` instead asserts syllable count, sample count, peak, zero crossings, and a SHA-256 of the 10 ms windowed RMS envelope, which is bit-identical across modes on all 7. Expect it to fire on every M6 change; that is the point. |
| **CI gate strictness** | #27, #28 | Start report-only, flip to required after a green streak. That streak is the flake-rate data #28 needs. |
| **Offline `--pattern` semantics** | #19 | **Settled — silence bytes.** A rest bar uploads a NINJAM silence marker in a live session, so the room hears nothing and the cursor does not advance. Writing silence keeps the offline timeline identical to the live one; skipping the bars would produce a file that disagrees with what it previews. |

---

## Sequencing

### Wave 0 — the unblocked six
`#11`✅ · `#10`✅ · `#18`✅ · `#12`✅ · `#19`✅ · `#27`

Six independent items; in practice three or four people can work in parallel
with zero collisions. Five have landed; `#27` is the last one standing. `#12`
and `#19` are the two that paid off fastest and both have landed: one was a bug
fix, the other is the harness that makes M6 verifiable without a room.

### Wave 1 — milestone payoffs, once Wave 0 lands
- **M4:** #8, #9 — ✅ **M4 is complete.** A bandleader can now shape the
  performance entirely from room chat: `!kujamba <verb>` for transport,
  `!kujamba <n|name>` for the phrase, every one of them landing on a bar line.
- **M5:** #13, #14 — ✅ **M5 is complete.** Both landed together because they are
  the same defect seen from two sides: a bar's audio is generated on a wall
  clock, and the upload of that bar happens inline on the same path. #13 makes
  the clock honest about being late; #14 stops it being late on a peer's
  schedule. Fixing either alone leaves the other half of the stall.
- **M6:** #15, #16, #17
- **M8:** #26 (fuzz — keep the harness out-of-tree) — ✅ **landed**

### Wave 2 — standalone instrument + hardening
- **M7:** #21, #22, #20
- **M8:** #23 ✅, #24 ✅, #25 — #23 landed the family-agnostic connect path
  (IPv6 literal fast path, `AF.UNSPEC` hints, per-entry socket family; see the
  findings below). #24's `--reconnect` is off by default on purpose (see Wave
  3): flipping the demo/default to reconnect-on belongs to the same change
  that closes #28.

`#20` and `#25` share the `-Dlive` build option. `#25`'s Windows half is
honestly a separate job (Winsock shim + console handler) — consider splitting it
and landing Linux first.

### Wave 3 — investigation close-out

- **#28** — local repros can start immediately; the *close* waits on #27's rate.
  Do not close via #24: reconnect makes the symptom survivable, which masks a
  real server-side or local-side defect rather than fixing it.
- **Measured 2026-09-30, still zero reproductions.** Three lines of evidence,
  all clean:
  - **Isolation** (`demo/repro_double_run.sh`, no refpeer): **30/30** same-seed
    sessions OK — 30 more on top of the issue's original 3, same result.
  - **Teardown churn** (`demo/repro_teardown_churn.sh`, new): the incident
    geometry — a refpeer teardown landing inside another client's upload burst —
    amplified from once per ~90 s demo to **60 teardowns across 5 victim
    sessions** (a refpeer joins, uploads one interval, and drops every ~7 s
    while the victim streams continuously). All 5 victims completed
    `intervals_uploaded=24`, `intervals_dropped=0`, `ok=true`. The server log
    shows every teardown handled normally.
  - **CI**: the `demo-e2e` job has run the exact original scenario on every
    PR since #45 — **18 completed runs, 18 green** (skips, where an earlier
    job failed first, are not demo outcomes).
  The suspected window has therefore been hit on the order of a hundred times
  without a recurrence. What would still reproduce it: the real network (the
  incident's latency/timeout profile is not reachable on loopback), or a
  server build other than the reference one. #28 stays open as the umbrella
  for the required-gate's flake rate; with the gate now required (#27), every
  merge is another data point.

### Wave 4 — vendored reconciliation
- **#29** — batched, last.

---

- **`accept()` does not inherit `O_NONBLOCK`, and on Linux it visibly does not.**
  Caught by CI, not by reading: the M5 timing harness set the *listener*
  non-blocking and assumed the accepted socket came that way. It did not. The
  server thread parked in `read` waiting for data that could not arrive — it
  was waiting to send the auth reply, which was queued behind its own reader —
  so the session timed out with `bars=0` and nothing else to go on. Two fixes
  worth carrying forward: set the flag on the accepted fd, and **assert that a
  session went live before asserting anything it produced**, so the next
  platform difference fails naming its cause instead of three assertions later.
  `proto_fuzz.zig` had been relying on the same false assumption and only got
  away with it because a blocking read still returns when the client writes or
  hangs up — it worked by luck, and its comment asserted something untrue.

## Mutation testing

`./mutate.sh` breaks one guard at a time and reports which tests went red. It
exists because **a test that passes whether or not the guard is present is worse
than no test** — it reads as coverage and is not — and because "I wrote a test
for it" is not evidence that the test *bites*. All twenty-one mutations are
caught. It reports four outcomes
(`CAUGHT` / `SURVIVED` / `NO-OP` / `BUILD ERROR`), restores every file
afterwards, and ends with a clean `zig build test` so the evidence ends where it
should: reverted, still green.

Three things it caught that reading the code did not:

- The first sweep reported **8 of 12 survivors**, and every one was real. Two
  were harness bugs (`sed -i ''` on BSD swallowing the expression as the backup
  extension; a test-failure grep that missed `ninjam.session.test....` because
  the module name contains a dot). The rest were tests that passed for the wrong
  reason: the timing tests passed a literal `0` instead of the session's own
  `upload_write_budget_ms`, so turning the budget back into a second changed
  nothing they measured.
- The #14 drop tests all used **one channel**, which made `if (lc.broadcast and
  !lc.dropped)` invisible — both conjuncts agreed on every input the tests could
  produce. The two-channel test is what closes it, and it exists now for the
  accounting: a bar the room did not hear is one lost bar, not one per channel.
- The **loopback** measurement turned out to be asserting the runner's encode
  throughput rather than the code's behaviour: the same code produced 4 bars in
  4 s on a workstation and 1 on a loaded macOS runner, and the first two floors I
  picked (`>= 3`, then `>= 2`) were both really fitting the test to the machine.
  The property it was standing in for — *the clock keeps walking through
  refused bars* — is now asserted deterministically by driving `finalizeInterval`
  twelve times against a blocked socket and counting: no wall clock, no runner,
  and a claim strong enough to mutate.
- One survivor turned out to be **redundant code**, not a test gap:
  `intervals_broadcast` is only accumulated on the `else` of `if (dropped_here)`,
  so `!lc.dropped` in the line above can never matter. It stays — a correct local
  expression beats one that is correct only in context — and `mutate.sh` says so
  next to the entry rather than leaving a reader to rediscover it.
- The **first cut of the #14 fix was wrong in a way that read as a feature.** It
  reported a torn frame as a plain `false`, with a comment saying that was benign
  because "both ends frame by the declared length, so the server simply never
  completes that guid". Backwards: the server *does* complete it, with the next
  bar's bytes as the missing payload, and then parses the bytes after that as a
  header from mid-stream. The fresh guid does not save it, because the server
  never sees those bytes as a guid — they are the tail of the frame before. So
  the first drop cost the rest of the session's uploads, silently, which is the
  dead performance the issue exists to prevent minus the honesty of a
  disconnect. Measured on that code: a half-full socket, a 16 KiB frame, a zero
  budget — `false` returned, **6000 bytes on the wire**. The test that caught it
  asserts on bytes, not on a return value, for the same reason.

`NO-OP` and `BUILD ERROR` are failures of the *script*, not of the code, and they
are reported separately for that reason: an entry that does not compile tells you
nothing about the guard it meant to break.

**A `SURVIVED` is only as interesting as the mutation that produced it.** Entry 19
reported a survivor on its first run and the entry was worthless, not the test:
it *inserted* a dead `if (room < 0)` in front of the real gate and left the real
gate in place, so it broke nothing and the "hole" said nothing about coverage.
Zig accepts `room < 0` on a `usize` and folds it away, which is exactly why the
result looked plausible. Rewritten to remove the thing it claims to break
(`if (room >= 0) return .declined;`), it is caught by four tests. A mutation has
to remove the thing it claims to break.

---

## Non-obvious findings worth keeping

- **#17's crossfade would make the loop seam worse, not better.** The wrap is
  already *exactly* click-free (step 0.000000 on every phrase) because the synth
  is zero at both ends: the attack term `min(1, t/attack_s)` is 0 at t=0 and the
  decay term `pow(1-u, 1.3)` is 0 at u=1. A crossfade blends the already-zero tail
  into the head, so the loop ends mid-head and then jumps back to head[0]:
  measured wrap step 0.000 (none) → 0.080 (5 ms) → 0.250 (2 ms), the last larger
  than the file's biggest natural step. Correctly placed in `Fill.copyInto` it
  still double-fades against the synth's own zero-termination. Lesson: a test or
  a "fix" for a perceived click should measure the actual discontinuity first —
  here the click the issue was filed against does not exist.
- **#18's knobs need clamps, and both bounds come from arithmetic that breaks.**
  `synthInto` computes `attack = min(1, t / attack_s)`, so `attack_s = 0` makes
  sample 0 evaluate `0/0` — and `@intFromFloat(NaN)` is a panic, not a quiet
  zero. And `wob = 1 - wobble_depth * (0.5 + 0.5·sin)`, so any `wobble_depth`
  above 2 drives `wob` negative and **flips the waveform's polarity**: that is
  distortion, not the chaos `--voice wobble=3` sounds like it should be.
- **The breath syllable is a second, separate spec path.** A consonant-only
  syllable (the *m* of *mtu*) has no vowel, so it renders from a literal rather
  than from `voiceSpec`. Knobs that miss it leave `--voice noise=0` hissing on
  exactly the syllable that is nothing but a hiss. A whole-word test cannot
  catch this, because the word's vowel syllable responds either way — the test
  has to drive `renderSyllableInto` with `vowel = 0` directly.

- **#8's bank cost is audio, not text — so the 1 MiB file cap bounds nothing
  that matters.** `--phrases` is capped at 1 MiB of *text*, but every line is
  synthesized to f32 and stays resident for the whole run. A one-word line is
  ~8 bytes and ~0.5 s of audio, so text-to-audio passes 20 000:1: a 900 KB file
  of short lines clears the text cap and then asks for gigabytes. The landed fix
  budgets `rendered` samples (64 MiB ≈ 6 min at 44.1 kHz) and refuses the phrase
  that would cross it, checked *after* the render because the length is only
  known then — a pre-flight estimate would have to model syllable timing, and
  being wrong permissively is the failure being fixed. Same shape as #18's
  clamps: the cheap-looking check (bytes) is the wrong one; measure the resource
  (samples). The bank also reports the failing *line*, because `failed:
  BankTooLarge` on a 500-line file tells the user nothing.
- **#19's default bar length is a trap, not a detail.** The obvious default —
  one bar = one second — silently truncates any phrase longer than a second, and
  `kujamba karibu` is 1.8s. The landed default is "one bar exactly as long as
  the phrase", so the no-flags case is "the phrase, untouched". Caught by
  mutation-testing the new guards, not by reading the code.
- **The offline WAV is not byte-identical to `synth.renderPhraseWav`, by
  design.** It routes through the f32 stage a live session uses, and carries the
  8 ms tail fade that stops loop wraps clicking. Measured on `kujamba karibu`:
  78 699 of 79 380 samples identical, 415 differ by 1 LSB (i16 → f32 → i16), and
  all 266 samples differing by 2–6 LSB sit inside the final 352 — the fade
  window. A test pins the relationship.
- **#20's real first step is a build option, not an `un-if`.** `build.zig:120`
  hardcodes `live = false` with no `-Dlive` flag, so the live path cannot be
  compiled from the CLI at all. And `miniaudio` is *not vendored*, so this issue
  needs a vendoring step the issue body doesn't mention.
- **#23 is a rewrite, not a flag.** `net.zig` hardcodes `AF.INET` in
  `openStreamSocket` and types `connectSockaddr` as
  `*const std.posix.sockaddr.in` — the IPv4 struct. The CLI already parses
  `[::1]:port` correctly.
  ✅ **Landed, and the rewrite was three small things, not one.** (1) An IPv6
  literal fast path beside the IPv4 one — `std.Io.net.Ip6Address.parse` builds
  a `sockaddr_in6`, and `%zone` scopes are deliberately *not* handled there:
  `Ip6Address.parse` refuses them, and getaddrinfo owns scoped forms, so
  duplicating `if_nametoindex` would be a second copy of one job. (2)
  `openStreamSocket(family)` — the socket must be created *in the candidate's
  own family*, because an `AF.INET` socket cannot even be constructed against
  a v6 peer and an `AF.INET` hints struct returns no v6 results to iterate at
  all; both bugs are invisible to any test that does not cross a real socket.
  (3) The load-bearing property of the hostname loop: **one failed entry is
  not a failed host.** With `AF.UNSPEC` the resolver returns both families in
  its own preference order (RFC 6724), so a v6-first resolver reaches a
  v4-only server by falling through the refused v6 connect — happy-eyeballs by
  construction, not by taking the first entry and hoping. Covered by loopback
  tests on both families plus a `localhost`-against-a-v4-listener test, and
  smoke-tested end-to-end: the real binary joined the reference `ninjamsrv`
  through an `[::1]` listener and uploaded its intervals (`session end:
  ok=true`), and a refused `[::1]` port fails in 0 ms with a clean
  `ConnectionRefused`, not a hang.
- **#25 is under-scoped.** `net.zig` uses `std.posix` in five places and
  `kujamba_main.zig:21-23` does `@cInclude("signal.h")` for Ctrl+C. Windows
  needs a shim and a console handler, not a build-flag flip.
- **#14's backpressure is already observable.** The run loop's
  `pollReadable(20)` already eats up to 20 ms of the audio budget per pass, and
  `send()` runs inline from `finalizeInterval`. Measure before fixing.
  ✅ **Measured, and worse than "observable".** `net.zig`'s `writeAllRaw` answers
  EAGAIN with `poll(&fds, 1000)` **inside a loop, discarding the return value** —
  so it does not wait "up to a second", it waits a second, wakes, retries, and
  waits again, indefinitely, until the peer reads or the socket dies. One 16 KiB
  `sendMessage` against a socket whose peer had stopped reading **did not return
  after 5000 ms** and would not have returned at all. `finalizeInterval` called
  it inline. The fix is a bounded write (`writeAllBounded`, deadline not
  per-attempt timeout) plus a **zero** millisecond budget on the upload path.
  Same shape as #17's crossfade and #18's clamps: the guard that looked like a
  nicety was hiding an unbounded wait.

- **"Would block" is only reachable on a socket with a bounded buffer, and
  macOS loopback has none.** A loopback peer that stops reading still absorbs
  **654 KB** with `SO_RCVBUF` pinned to 4096 — measured, twice, at two different
  request sizes — so `write` never returns EAGAIN on loopback and the whole drop
  path is unreachable inside a test's patience. It is also why the hazard is a
  *slow-peer* failure measured in seconds, not a jitter failure. A Unix
  `socketpair` has a genuinely bounded buffer (measured: full at exactly the
  requested `SO_SNDBUF`), so `src/kujamba_timing.zig` and the `session.zig`
  backpressure tests use one and feed a `net.Conn` its fd. The lesson for the
  next agent: **on macOS, reach for a socketpair before concluding a network
  condition cannot be tested.** A related trap, already hit once here: on this
  platform `poll(POLLOUT)` stays *false* on a socketpair that has room for a
  few hundred bytes, so `Conn.writable()` is a reliable "is this wide open"
  check but not a reliable "could this frame fit" check — which is exactly why
  `sendUpload` needs both.

- **What drift actually is (and why the correction does not chase the server's
  clock).** The local bar grid and the server's grid both advance by one bar and
  both start at the `0x02` arrival, so the difference between them is a
  **constant** — the one-way latency of the config message — and a constant the
  client cannot measure and does not need to: the server re-times an upload on
  arrival. What actually accumulated was **execution lag**: the run loop's 20 ms
  poll granularity plus whatever `finalizeInterval` spent on the wire, stolen from
  every subsequent bar's generation budget and never given back, which
  `advanceAudio` then repaid as one catch-up burst. So `ServerClock` corrects
  toward the **wall clock**, not toward the server's epoch. Correcting toward the
  epoch would have looked more faithful and been wrong.

- **The bar's nanosecond length was truncated twice.** The session derived a bar
  as `@divTrunc(interval_len_samples * 1e9 / srate)` from a sample count that had
  itself been truncated from `srate * bpi * 60 / bpm`. At 48 kHz / 5 bpi / 137 bpm
  that is 2 189 770 833 ns against the exact 2 189 781 021 ns — 10.2 us short,
  every bar, forever, with nothing measuring it. One division from the wire
  values (`kujamba_out.intervalNsFor`) has no such error. Small, systematic, and
  entirely invisible: the kind of thing #13 exists to notice.

- **A bar shorter than the run loop's poll cannot be sustained, and #13's slew
  cannot rescue it.** Found by choosing a 10 ms bar (6000 bpm, 1 bpi) to make a
  test faster: the run loop spends up to 20 ms per pass in `pollReadable(20)`,
  and `advanceAudio` finalizes **at most one interval per pass**, so a bar
  shorter than the poll can never be caught up. Measured: 126 bars in a 4 s run
  against ~400 available, **2231 ms of accumulated drift**, and a bounded slew
  firing on every single one of them and still losing ground — which is correct
  behaviour, since a 1%-of-a-bar correction is *supposed* to be small, and
  closing a 2.2 s gap at 1 ms per bar would take 2200 bars. Worth knowing, not
  fixed here: no musical tempo has a sub-20 ms bar, and doing it properly means
  restructuring `advanceAudio` to generate *and* finalize several intervals per
  pass, which is a bigger change than #13/#14 should carry. If it ever matters,
  it is a fresh issue with this measurement already in it.

- **A test that asserts a wall-clock count is a test that measures the machine.**
  The M5 timing harness asserted "at least 3 bars in a 4 s session", CI failed
  it, it became "at least 2", CI failed it again with 1, then with 0 — same
  code, three runners. The bar count is the machine's encode throughput, not the
  client's behaviour, and no floor fixes that. The harness now asserts what is
  machine-independent (the handshake completed, the upload section stayed
  bounded, the session *came back* inside a generous cap) and **reports** the
  bar count, while the claim it was reaching for — the clock keeps walking
  through refused uploads — is asserted deterministically by driving
  `finalizeInterval` twelve times against a blocked socket and counting. Same
  lesson as the `sendMessageBounded` literal, one level up: prefer a test whose
  result depends on the code to one whose result depends on the weather.

- **An encode lead longer than the bar is a silent, permanent stall.** If the
  encoder is asked to run more than one bar ahead, then `produced < target` in
  `advanceAudio` is false before the bar begins, `finalizeInterval` never fires,
  and the session sits there uploading nothing forever. It is not reachable at
  `max_slew_div = 100` — `lead_ns ≤ interval_ns / 100`, so `lead_samples ≤
  bar / 100` — which is why the explicit `@min(..., interval_len_samples)` is
  defence-in-depth rather than logic, and why the test sweeps the tempo range
  and asserts the property instead of trusting the algebra. Two related shapes
  from the same sweep: `per_sample` is `1e9 / srate` (20.8 us at 48 kHz) for
  *every* tempo, so a bar of a few tens of samples cannot carry a lead worth
  naming and it correctly rounds to zero; and at 48 kHz / 1 bpi / 65535 bpm the
  bar is 43 samples, so a guard written as "the lead is small" is meaningless
  there and only `lead < bar` is a real property.
- **#26's realistic bug is downstream of the parser.** The parsers are
  length-checked with `catch`; the likely panic is a consumer (e.g. `parseChat`'s
  `get(0..4)` returning empty slices). Fuzz a dispatch step, not just the parser.
- **The `test` step description is stale.** ~~`build.zig:77` says "Run audit +
  synth unit tests" but it runs three suites (59 tests).~~ **Fixed** alongside
  the golden fingerprints: it now runs five suites (102 tests) and says so.
- **Darwin does not implement `TIOCOUTQ` for sockets, and the replacement is not
  obvious.** Linux answers "how full is the send queue" with `ioctl(TIOCOUTQ)`.
  On macOS that returns `ENOTSUP` — for *both* the `'t'` spelling from its own
  `<sys/ttycom.h>` and the `'f'` spelling you find on FreeBSD, on a socketpair
  and on loopback TCP alike. The same number is available as the **`SO_NWRITE`
  socket option** (0x1024, "APPLE: Get number of bytes currently in send socket
  buffer"). `net.zig`'s `sendRoom` asks per target and returns null where neither
  is available, which is what makes the frame-fit pre-check skippable rather
  than a portability lie.
- **But on a Darwin *unix socket*, `SO_NWRITE` on the writer is always 0.** The
  send buffer belongs to the receiving end, so the writer cannot see its own
  queue at all. Consequence for tests: **a socketpair cannot exercise the send
  buffer accounting on macOS** — the gate would read as "the whole capacity is
  free" and pass every write. The frame-alignment test uses a real TCP pair for
  exactly this reason. The byte-level test does use a socketpair, but only
  because it does not need the queue depth: it makes the buffer's *capacity*
  smaller than one frame, which no accounting can argue its way out of.
- **A unix socketpair's `SO_SNDBUF` is exact; a TCP one is not.** Requested 512 →
  512, 65536 → 65536 on `AF_UNIX`; on `AF_INET` every request up to 16384 comes
  back as 65328, and 65536 comes back as 81660. So a socketpair is the only
  socket whose send-buffer size is a test *knob* on both platforms, and the only
  one where "half full" is a state you can construct by arithmetic rather than by
  waiting for a kernel to do it. On TCP the half-full state has to be waited for,
  and even then it moves: the room settled at 16332 free on one run and at the
  full 81660 on the next, with nothing different in between.
- **Zig resolves an `extern` declaration by name, so a renamed libc call links on
  one platform and not another.** `net.zig` needed `ioctl` for `TIOCOUTQ`, and
  the natural-looking `extern "c" fn ioctlTIOCOUTQ(...)` compiles and links
  perfectly on macOS — because macOS takes the `SO_NWRITE` branch and never
  references the Linux one, so the declaration is dead code and the linker never
  sees it. On Linux it fails at link time with `undefined symbol:
  ioctlTIOCOUTQ`. Nothing in the macOS test suite, in any optimisation mode, can
  see this: it is a *build* failure on the one target that takes that path.
  `zig build -Dtarget=x86_64-linux-gnu -Dlive=false` cross-compiles **and links**
  from a Mac, catches it in about a minute, and is now part of how this was
  checked. Worth more than it sounds: the alternative is another round trip
  through a 10-minute CI job.
- **A harness that sleeps where it could wait is a test that measures the
  runner.** The timing harness's scripted server answered each handshake step by
  sleeping a fixed 200 ms rather than by waiting for the message it needed, so
  the handshake cost 400 ms before the client could go live, inside a session
  capped at 4 s. On the macOS runner that failed roughly half the time with
  `msgs_recv=2` and `bars=0` — the client never received the `0x02` — and no
  error text anywhere, because the symptom was a *missing* config rather than a
  wrong one. It now waits for the `0x80` and then the `0x82`, which is both
  faster (a loopback round trip, ~1 ms rather than 400) and an assertion: the
  old code sent the config whether or not the client had registered its channel,
  so a client that never sent `0x82` still looked healthy.
  Honest caveat: this could not be reproduced on a workstation, with or without
  the change, even under 8x CPU load — the runner is slower than the machine it
  would have to be reproduced on, and the only fixed delay on that path was the
  200 ms sleep. It is the most plausible cause and it cannot be worse, but the
  evidence that it fixed it is CI going green, not a local reproduction.
- **The frame walk needs two checks, and testing one of them is easy to mistake
  for testing both.** `walkFrames` stops on a declared length that cannot be
  believed, and separately on a frame that runs past the end of the bytes. Every
  case the first version of the torn-frame test used tripped the *first* check —
  the garbage behind a tear reads as a length of `0x7E7E7E7E` — so the second
  check had no test at all, and a mutation removing it survived while the suite
  stayed green. It needed its own input: a stream that ends in the middle of a
  frame whose header is entirely believable. That case is not contrived, by the
  way; it is exactly what a truncated read looks like, and it is exactly what the
  alignment test's filler leaves behind, so the residue that test accounts for
  *is* this one. Without the check the walk then steps past the end of the buffer
  and the residue underflows.
- **A test can be correct on the machine that wrote it and wrong everywhere
  else, and the fix is to make the divergence impossible rather than to patch
  each platform.** The frame-alignment test takes three attempts to get right on
  two platforms, and every failure was a platform assumption rather than a code
  bug:
  - `fillUntilBlocked` stops on a *short* write, so the junk stream was whole
    frames followed by a remainder, and the parser reported a tail — of the
    test's own making. It now accounts for the remainder exactly.
  - `writable()` was asserted to prove "the cheap gate lies here". POLLOUT is a
    coarse signal and how coarse is the kernel's business: Linux will not
    report a socket with 4096 bytes free out of 16384 as writable, macOS will.
    Printed, not asserted; the property is stated in bytes.
  - The helper drained the peer a byte at a time and checked the room *first*,
    so it consumed nothing on a platform where one byte of room appears at once
    and a few bytes on one where it does not. A leftover `copyForwards` was then
    a harmless self-copy on macOS and a clobber on Linux, and the test read a
    length of `0x01010000` out of the middle of the stream on one platform while
    passing on the other. Draining first makes the count non-zero everywhere.
  - `SO_SNDBUF` is exact on a Darwin socketpair and **doubled** on a Linux one,
    so "half the requested size" is a different buffer on each.
  The general lesson: a test whose correctness depends on a *kernel's* opinion
  is a test with a per-platform failure mode, and the fix is to assert the
  property you care about in units you control. `mutate.sh` entry 20 exists so
  the last of these cannot come back silently.
- **#24's reconnect semantics rest on three load-bearing subtleties.** The
  fresh handshake's `0x02` must re-anchor the grid **even when bpm/bpi are
  unchanged** — a reconnect to the same server gets the same config, and
  `onConfig`'s re-anchor branch only fires on a *difference*. The session
  returns the learned config to zero before dialling, which forces that branch
  and is semantically honest: a fresh server session knows nothing. The reset
  deliberately does NOT touch `index.seq` (identity is monotonic — the resumed
  bar re-sends the abandoned bar's guid, and the `--intervals` cap keeps
  counting across rejoins; that is the #12 seam, now covered end to end), the
  phrase cursor (the room lost contact, not the instrument), or the drift
  ledger. And the budget-exhausted path must close the open outage ledger
  before failing — the first cut reported a 0 ms outage for a session that had
  spent 30 ms dialling in vain.
- **A reconnect changes the encode rhythm, and libvorbis notices.** The
  resumed session's bars re-encode from the phrase start (repeat mode is
  bar-aligned), but an outage shifts the run loop's bar-boundary phase, so the
  final encode block of a bar splits at a different point — and libvorbis then
  packs a slightly different packet from the same PCM: measured at **one to
  eight bytes per bar** (same serial, same granule totals, same guid). The
  resume tests therefore pin identity where it actually lives — guid and
  serial derive from `(seed, seq)` and are untouched — and assert the serial
  straight out of each dump's ogg page header plus that every dump decodes.
  Cross-run byte-for-byte dump comparison is not asserted at all: even the
  pre-outage bar 0 differed across two runs on a slow ReleaseSafe runner,
  because the session's first partial encode block is scheduling jitter. Two
  consequences worth keeping: the demo's determinism evidence is unaffected
  (it compares two healthy runs and the demo never reconnects), and — more
  interesting — a direct `vorbis_analysis` experiment showed chunk splits
  under `encode_block_samples` (960) are byte-safe while one 20 000-sample
  call is not, so the sensitivity lives at the packet-packing boundary, not in
  the 960-sample rhythm itself.
- **A test can manufacture the desynchronisation it is looking for.** The first
  version of the frame-alignment test failed intermittently with a 1–4 byte tail,
  for a reason that had nothing to do with the code: the helper that drives the
  socket into its half-full state drains the peer one byte at a time, and those
  bytes came off the *front* of the stream the parser then walked. The parser
  started mid-frame and reported a torn frame that never existed. Two lessons, in
  order of how much they cost: keep the bytes a helper consumed, and **do not stop
  reading a non-blocking socket on `EAGAIN`** — that means "not right now", not
  "no more data", and breaking there truncates the stream mid-frame.
