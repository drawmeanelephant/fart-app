---
title: Testing and evidence
parent: contributors/index
status: published
summary: Unit matrices, hostile sockets, reference demos, and fresh phase receipts.
---

# A passing process is not a passing instrument

## Baseline matrix

```bash
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test -Dlive=false
zig build -Doptimize=ReleaseSafe
```

The #29 reconciliation baseline is **218 tests**, plus a standalone
null-backend C audio executable. This is a dated baseline, not an eternal
promise that future additions cannot change the count.

The suites cover synth/goldens, app glue, config, hostile protocol dispatch,
generic callbacks, real socket timing/reconnection/pressure, and codecs.
Null-backend tests never open real speakers or request microphone permission.

## Real reference demo

```bash
bash demo/run_demo.sh
```

This builds an **unmodified reference `ninjamsrv`** and a headless reference
client core. Six instrument intervals include five play bars and one rest.
The receiver decodes real audio with measured energy. Silence must fail
the negative control, and equal-input runs must produce equal upload hashes.

Reference `main` is resolved once to an exact SHA. `NINJAM_REF_SHA` selects an
explicit pin; `NINJAM_REPO` can supply a clean matching checkout. External
checkouts are not reset or deleted.

Fresh run evidence is written under `demo/evidence/run-<timestamp>-<pid>`.
`KUJ_EVIDENCE_DIR` can choose another fresh path. `receipt.json` records
phases and cache outcomes even when no demo runs.

The shared provisioner validates source/build fingerprints and artifact hashes
before using warm state. Transient network retries are bounded. Compilation
and demo assertion failures are not hidden behind generic retries.

Read the [provisioning policy](https://github.com/drawmeanelephant/fart-app/blob/main/demo/provisioning.md).

## Backpressure is measured, not narrated

```bash
zig build repro-backpressure -Doptimize=ReleaseSafe
```

The full session runs on a constrained stream socket. Its peer stops reading
for four seconds, keeps sending pings, then drains and decodes fresh uploads
on the same connection. Assertions cover clock progress, counted drops,
frame alignment, and non-silent recovery.

The recorded #14 reproduction ran 7.2 seconds, started ten bars, counted six
drops, and decoded three recovered uploads. This is a bounded fixture,
not a prediction of how many bars your network will drop.

[Before/after evidence](https://github.com/drawmeanelephant/fart-app/blob/main/demo/backpressure.md).

## Fuzzing and CI

`src/proto_fuzz.zig` drives full sessions with a fixed corpus and seeded random
server streams. Arithmetic consumers matter as much as parsers. The former
hostile channel-ID and zero-tempo crashes are fixed and covered.

Coverage-guided `zig build test --fuzz` has documented Zig 0.16 runner/linking
limitations; the ordinary corpus and seeded runs still execute in every test
run. Do not claim a coverage-guided campaign merely because that flag exists.

CI runs native Linux/macOS build and test matrices, render/energy/silence
smokes, and the macOS reference demo. `build-test` and `demo-e2e` are required
on main. Docs have their own validation/publishing workflow; a docs build
does not replace runtime evidence.
