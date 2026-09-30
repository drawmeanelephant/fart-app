# Issue map & sequencing

Companion to [ROADMAP.md](ROADMAP.md). The roadmap says *what* each milestone
builds; this file says **what order to build it in**, which issues block which,
and which decisions get made once instead of three times.

The dependency edges below are also encoded as GitHub `blocked-by` relations on
the issues themselves, so `gh issue view 12` shows them without reading this.

**State at time of writing:** 4 milestones (M4–M8), M4 complete and M5 complete
(#13 + #14 landed together). `zig build test` → **176/176 pass** in five suites,
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
| `src/ninjam/net.zig` | **already diverged** (`writeAllBounded` / `sendMessageBounded` / `writable`) | #14, #23, #25 |
| `src/ninjam/proto.zig` | byte-identical | #26 — *only if* the harness lands in-tree |
| `src/ninjam/buf.zig` | byte-identical | #26 — *only if* the harness lands in-tree |
| `src/ninjam/audio.zig` | byte-identical (live path compiled out) | #20 (`-Dlive` toggle + miniaudio) |
| `src/ninjam_out.zig` | **new** (not vendored) | #10, #11, #12, #13, #17, #22 |
| `src/kujamba_main.zig` | **new** (not vendored) | #8, #9, #19, #20, #21, #22, #25 |
| `src/kujamba_timing.zig` | **new** (not vendored) | #13, #14 — the M5 timing harness |
| `src/synth.zig` | **new** (not vendored) | #15, #16, #18 |
| `src/golden.zig` | **new** (not vendored) | guards #15, #16, #17, #18 |

> **`net.zig` had to be touched, and it is worth being honest about why.** The
> rule above is "push down into `src/ninjam/` only when there's no choice", and
> for #14 there was not one. The stall is *inside* `writeAllRaw`: the socket is
> non-blocking, so a peer that stops reading turns `write` into EAGAIN, and the
> EAGAIN branch polls for 1000 ms in a loop while discarding the result. No
> caller can bound that from outside — the only lever a caller has is whether to
> call, and "don't call" is not the same as "call and give up". The change is
> purely additive: `writeAllRaw`/`sendMessage` are untouched and still used by
> every non-upload message, and three new functions sit beside them.

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
| **How long may a socket write wait?** | #14, #24 | **Settled — zero, on the audio-clock path.** A bar is worth one bar of audio and the socket is not worth any of it. Uploads get `sendMessageBounded(..., 0)`; control messages (keepalive, chat, registration) keep using the unbounded `sendMessage`, because losing those ends the session rather than skipping a bar, and they are a handful of bytes against a socket with room. |
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
- **M8:** #23, #24, #25

`#20` and `#25` share the `-Dlive` build option. `#25`'s Windows half is
honestly a separate job (Winsock shim + console handler) — consider splitting it
and landing Linux first.

### Wave 3 — investigation close-out- **#28** — local repros can start immediately; the *close* waits on #27's rate.
  Do not close via #24: reconnect makes the symptom survivable, which masks a
  real server-side or local-side defect rather than fixing it.

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
for it" is not evidence that the test *bites*. All sixteen mutations are
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

`NO-OP` and `BUILD ERROR` are failures of the *script*, not of the code, and they
are reported separately for that reason: an entry that does not compile tells you
nothing about the guard it meant to break.

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
