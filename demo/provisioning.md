# Reference provisioning and evidence (#58)

CI and `demo/run_demo.sh` share `provision_reference.py`. This hardens
provisioning, not audio/session behavior or runtime flake #28. No cache ABI
or branch-race incident was reproduced by the original study; manifest and
SHA enforcement are preventive checks. Required contexts remain `build-test`
and `demo-e2e`. Windows is deferred, not a blocker for #58 or #29.

## Identity and cache policy

- Resolve exactly one nonempty 40-character `refs/heads/main` SHA, or
  validate `NINJAM_REF_SHA`. Fetch/check out that SHA, not a later branch tip.
- Verify actual HEAD and a clean source tree before building or running
  cached tools. An optional `NINJAM_REPO` must match; it is never reset,
  deleted, or built in place.
- Key/manifests include the SHA, refpeer/provisioner hashes, OS/architecture,
  CMake and both compiler versions, macOS SDK, build options, and a digest
  of build-affecting environment. CMake uses the fingerprinted Clang tools.
  Reference Ogg/Vorbis come from upstream's static dependency path, not
  host pkg-config libraries.
- Check all required library/tool hashes and executable bits on every warm
  use. Reject mismatched/dirty/corrupt state before executing cached tools.
  Build in fresh task-owned staging and publish only verified results.
- Cache restore/save are separate, each capped at three minutes. Restore
  uses a two-minute segment timeout and has no fallback keys. A restore
  error is recorded separately from a successful restore with an absent key.
  Ignore/preserve partial restore files and take the bounded cold path in a
  different directory. Save only a newly published, verified snapshot;
  never overwrite existing/partial restored state.

## Retry and time policy

Only recognized transient errors/timeouts in reference resolution and fetch
get retries: three attempts, 45 seconds each, with 1/3-second backoffs (at
most 139 seconds per operation). Permanent errors fail immediately. Each
build/tool command is capped at five minutes; subprocess provisioning has
a ten-minute overall deadline and kills timed-out process groups.

CMake/compiler, Zig tests, and demo assertions are not retried by the helper.
They stay red. The existing 30-minute CI job budget and demo assertions are
unchanged. Cache save failure is optional; reference verification and the
demo are not.

## Current-run evidence

Local runs initialize a fresh `demo/evidence/run-<timestamp>-<pid>/`, or the
caller-supplied `KUJ_EVIDENCE_DIR` (which must not already exist).
CI initializes `demo-runtime/evidence/run-<run-id>-<attempt>/` before
provisioning and uploads only that directory on success or failure.
Historical checked-in fixtures are not an upload source.

`receipt.json` contains phase/status, expected/actual SHA, cache restore/hit/
validation outcomes, network attempt, compilation/demo result, and event
history. The history retains cold compilation success when the shell
entrypoint subsequently re-verifies that same build. Failures before the
demo retain `demo: not-run`; compilation/assertion failures retain their
specific phase. `provision.log` contains command output and `reference.json`
is written only after successful verification. Payload/output/config files
are per-run too, so no old payload cleanup or historical result reuse is
needed.

## Validation

Offline injected cases run on both CI build/test OSes:

```bash
python3 -m unittest discover -s demo -p 'test_*.py' -v
shellcheck demo/run_demo.sh
actionlint .github/workflows/ci.yml
```

They cover absent cache vs failed/partial restore, one transient fetch
failure, persistent outage, deadline enforcement, permanent errors,
SHA/source/artifact/input mismatch, untouched external state, fresh evidence,
and compile/actual shell assertion failures without blanket retries.

For a genuine cold/warm check, use an unused runtime directory and different
evidence directories, pinning the same reference SHA for both:

```bash
NINJAM_REF_SHA='<40-character-sha>' KUJ_RUNTIME=/tmp/kujamba-reference-check \
  KUJ_EVIDENCE_DIR=/tmp/kujamba-cold-evidence bash demo/run_demo.sh
NINJAM_REF_SHA='<same-sha>' KUJ_RUNTIME=/tmp/kujamba-reference-check \
  KUJ_EVIDENCE_DIR=/tmp/kujamba-warm-evidence bash demo/run_demo.sh
```

Both must reach the existing energy/rest/negative-control/determinism
assertions. The warm receipt must say compilation skipped; its provision
log must have no `cmake --build` or refpeer compile command. To simulate a
clean CI job, provision with `--cache-directory`, copy only that verified
snapshot to a fresh runtime, initialize fresh evidence, then provision with
the same SHA/cache directory before running the demo with
`KUJ_EVIDENCE_INITIALIZED=1`. That variable is for already initialized
current-run CI evidence, not permission to reuse an old result directory.
