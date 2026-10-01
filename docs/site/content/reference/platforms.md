---
title: Platform and audio support
parent: reference/index
status: published
summary: Verified macOS/Linux paths, headless builds, and honest Windows limits.
---

# Know what is actually supported

| Path | macOS | Linux | Windows |
|---|---|---|---|
| Build/test and offline render | Verified | Verified in native CI and smoke runs | Deferred |
| Headless NINJAM join | Verified | Verified | Needs Winsock work |
| ANSI terminal spectacle | Verified | Verified, including silent fallback | Needs console/platform work |
| Miniaudio playback | Compiled by default | Opt-in; backend dependencies apply | Not an app support claim |

Windows remains [#25](https://github.com/drawmeanelephant/fart-app/issues/25),
not a hidden unchecked box under “cross-platform.” Existing upstream reference
C++ Windows CI does not prove this Zig app runs on Windows.

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

macOS defaults to this with CoreAudio frameworks. Linux defaults to false;
an enabled miniaudio backend can require ALSA development packages and an
available device. A headless VM is not a playback test.

`fart` uses host sound/speech commands independently of `-Dlive`; that flag
controls `kujamba`'s device path, not whether the terminal app finds `afplay`.

## Cross-build without claiming execution

```bash
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe \
  -Dlive=false --prefix zig-out-linux
```

This proves compilation and linking, not a native run. Native Linux CI
performs the separate tests and render/energy/silence smoke checks.
