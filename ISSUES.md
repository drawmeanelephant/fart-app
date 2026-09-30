# Issue map & sequencing

Companion to [ROADMAP.md](ROADMAP.md). The roadmap says *what* each milestone
builds; this file says **what order to build it in**, which issues block which,
and which decisions get made once instead of three times.

The dependency edges below are also encoded as GitHub `blocked-by` relations on
the issues themselves, so `gh issue view 12` shows them without reading this.

**State at time of writing:** 22 open issues (#8–#29), 4 milestones (M4–M8).
`zig build test` → **102/102 pass** in five suites, in both Debug and ReleaseSafe.
CI exists and gates pushes and PRs (build + test, `build-test`); it is not yet
required by `main`'s ruleset.

Tracking issue for this map: [#31](https://github.com/drawmeanelephant/fart-app/issues/31).

---

## The short version

Six issues are effectively unblocked and everything else is downstream of them.
Start there. The two things most likely to be picked up first from a
milestone-number ordering — #8 and #9 — are both **blocked**, and the one that
unblocks them (#11) is the smallest item in M4.

| Start here | Why it's unblocked | What it unblocks |
|---|---|---|
| **#11** Bar-accurate switching | The per-bar decision point already exists in `startIntervalEncoders`; widening its return type is the whole change | #8, #9 |
| **#10** Render caching | Depends only on `renderPhraseF32` | #8 |
| **#18** voiceSpec knobs | ✅ **done** — `--voice` multipliers, see below | #15, #16 |
| **#12** Re-anchor on config change | ✅ **done** — split the counters, see below | #24, #29 |
| **#19** Offline render | ✅ **done** — `kujamba render`, see below | verification harness for M6 |
| **#27** CI demo | Extends the existing `build-test` job with the live reference-server run | #28 (flake rate), the safety net for everything |

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

1. **#11 before #8 and #9.** `IntervalPlan.broadcastFor` returns `bool`. All three
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
| `src/ninjam/net.zig` | byte-identical | #23, #25 |
| `src/ninjam/proto.zig` | byte-identical | #26 — *only if* the harness lands in-tree |
| `src/ninjam/buf.zig` | byte-identical | #26 — *only if* the harness lands in-tree |
| `src/ninjam/audio.zig` | byte-identical (live path compiled out) | #20 (`-Dlive` toggle + miniaudio) |
| `src/ninjam_out.zig` | **new** (not vendored) | #10, #11, #12, #17, #22 |
| `src/kujamba_main.zig` | **new** (not vendored) | #8, #9, #19, #20, #21, #22, #25 |
| `src/synth.zig` | **new** (not vendored) | #15, #16, #18 |
| `src/golden.zig` | **new** (not vendored) | guards #15, #16, #17, #18 |

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
| **Where does the loop crossfade live?** | #17, #8 | In `Fill.copyInto` (`cursor % n` at `ninjam_out.zig:72`), **not** in `renderPhraseF32`. In the render it would double-fade and wrongly affect `repeat`/`once`. |
| **Golden hash for the synth** | #15, #16, #17, #18 | **Settled, and not a byte hash.** An exact WAV SHA-256 was tried and rejected on measurement: Debug and ReleaseSafe render different exact bytes from identical source, because LLVM contracts the synth's `@exp`/`@sin` differently per optimization level. Measured across all 7 baseline entries, the exact WAV hash differs between modes for **3 of them** (`kujamba karibu`, `asante sana kijiji`, `shuzi seed 0`) — the shorter, simpler renders happen to be stable, so a byte-hash guard would look fine locally and go red on CI. `src/golden.zig` instead asserts syllable count, sample count, peak, zero crossings, and a SHA-256 of the 10 ms windowed RMS envelope, which is bit-identical across modes on all 7. Expect it to fire on every M6 change; that is the point. |
| **CI gate strictness** | #27, #28 | Start report-only, flip to required after a green streak. That streak is the flake-rate data #28 needs. |
| **Offline `--pattern` semantics** | #19 | **Settled — silence bytes.** A rest bar uploads a NINJAM silence marker in a live session, so the room hears nothing and the cursor does not advance. Writing silence keeps the offline timeline identical to the live one; skipping the bars would produce a file that disagrees with what it previews. |

---

## Sequencing

### Wave 0 — the unblocked six
`#11` · `#10` · `#18`✅ · `#12`✅ · `#19`✅ · `#27`

Six independent items; in practice three or four people can work in parallel
with zero collisions. `#12` and `#19` are the two that paid off fastest and both
have landed: one was a bug fix, the other is the harness that makes M6
verifiable without a room.

### Wave 1 — milestone payoffs, once Wave 0 lands
- **M4:** #8, #9 (now unblocked together)
- **M5:** #13, #14
- **M6:** #15, #16, #17
- **M8:** #26 (fuzz — keep the harness out-of-tree)

### Wave 2 — standalone instrument + hardening
- **M7:** #21, #22, #20
- **M8:** #23, #24, #25

`#20` and `#25` share the `-Dlive` build option. `#25`'s Windows half is
honestly a separate job (Winsock shim + console handler) — consider splitting it
and landing Linux first.

### Wave 3 — investigation close-out
- **#28** — local repros can start immediately; the *close* waits on #27's rate.
  Do not close via #24: reconnect makes the symptom survivable, which masks a
  real server-side or local-side defect rather than fixing it.

### Wave 4 — vendored reconciliation
- **#29** — batched, last.

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
- **#26's realistic bug is downstream of the parser.** The parsers are
  length-checked with `catch`; the likely panic is a consumer (e.g. `parseChat`'s
  `get(0..4)` returning empty slices). Fuzz a dispatch step, not just the parser.
- **The `test` step description is stale.** ~~`build.zig:77` says "Run audit +
  synth unit tests" but it runs three suites (59 tests).~~ **Fixed** alongside
  the golden fingerprints: it now runs five suites (102 tests) and says so.
