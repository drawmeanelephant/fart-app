---
title: Platform and audio support
parent: reference/index
status: published
summary: Verified macOS, Linux, and Windows paths, headless builds, and honest limits.
---

# Know what is actually supported

| Path | macOS | Linux | Windows |
|---|---|---|---|
| Build/test and offline render | Verified | Verified in native CI and smoke runs | Verified in native CI and smoke runs |
| Headless NINJAM join | Verified | Verified | Verified; real Winsock sys seam, not POSIX emulation |
| ANSI terminal spectacle | Verified | Verified, including silent fallback | Verified; conhost VT output and clean Ctrl+C |
| Miniaudio playback | Compiled by default | Opt-in; backend dependencies apply | Opt-in; compiles, device playback not in CI evidence |

Windows support landed via
[#25](https://github.com/drawmeanelephant/fart-app/issues/25). See the
[[guides/windows|Windows guide]] for shell spellings, sound tooling, and what
is not proven there.

## Headless build

```bash
zig build -Doptimize=ReleaseSafe -Dlive=false
```

This removes production miniaudio device dependencies. It still supports
offline render and NINJAM join. `play` and `trigger` refuse to pretend an
output device exists.

Tests still compile a standalone **null-backend** audio ABI test. That is
hardware-independent and does not reintroduce real-device access.

## Audio-enabled build

```bash
zig build -Doptimize=ReleaseSafe -Dlive=true
```

macOS defaults to this with CoreAudio frameworks. Linux and Windows default
to false; an enabled Linux backend can require ALSA development packages and
an available device. On Windows `-Dlive=true` compiles through vendored
miniaudio, but real-device playback is not yet covered by CI evidence.
A headless VM is not a playback test.

`fart` uses host sound/speech commands independently of `-Dlive`; that flag
controls `kujamba`'s device path, not whether the terminal app finds `afplay`.

## Cross-build without claiming execution

```bash
# From any host — e.g. macOS cross-compiling for a headless Linux server.
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe \
  -Dlive=false --prefix zig-out-linux

# Windows, likewise. Produces fart.exe / kujamba.exe / audit.exe
# (plus .pdb debug files) without a Windows toolchain installed.
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe \
  -Dlive=false --prefix zig-out-windows
```

Both prove compilation and linking, not a native run. The native CI legs
(`build-test` on Linux, `build-test-macos`, `build-test-windows`) perform the
separate tests and render/energy/silence smoke checks that stand as the
cross-platform evidence. Cross-build outputs land under `zig-out-*/`, which
is gitignored; a `-Dlive=true` cross-build still only proves compilation —
device playback is a native, hardware-dependent claim.
