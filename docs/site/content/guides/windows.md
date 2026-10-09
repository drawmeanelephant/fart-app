---
title: Windows
parent: guides/index
status: published
summary: Native build, verified commands, and the honest limits on Windows.
---

# Windows is a real target now

The fart app and the NINJAM client run natively on Windows through a real
Winsock layer — `WSAStartup`, `WSAPoll`, and `ioctlsocket` in `net.zig`, not
POSIX emulation. CI builds and tests on `windows-latest`; the commands below
are verified on Windows x86_64 with Zig 0.17.0.

## Install and build

Install [Zig 0.17.0](https://ziglang.org/download/) and Git. The Windows
download is a zip: unzip it and put the extracted directory on `PATH`.
`zig version` should print `0.17.0`.

```powershell
git clone https://github.com/drawmeanelephant/fart-app.git
cd fart-app
zig build -Doptimize=ReleaseSafe
```

Binaries land in `zig-out\bin` as `fart.exe`, `kujamba.exe`, and `audit.exe`.
The `./zig-out/bin/...` examples throughout this manual run verbatim in Git
Bash; in PowerShell or cmd, spell them like the following.

```powershell
.\zig-out\bin\kujamba.exe render --phrase "kujamba karibu" --out karibu.wav
.\zig-out\bin\kujamba.exe render --phrase "kujamba karibu" --out karibu.ogg --seed 42
.\zig-out\bin\kujamba.exe check-ogg karibu.ogg
zig build test
```

## The terminal app

`fart.exe` animates in a real console. Classic conhost (cmd/PowerShell) gets
virtual-terminal output armed at startup, while Windows Terminal and MinTTY
already speak ANSI; a redirected stdout skips the escape codes. **Ctrl+C**
stops cleanly through a console control handler and restores the cursor.

## Sound and speech

Stock Windows ships none of `afplay`, `paplay`, `say`, or `espeak`, so the
app announces its fallback once and runs silent. The probe is `where`-based:
any `ffplay` (ffmpeg) or `espeak` binary on `PATH` answers it, no rebuild
required. Synthesized scratch WAVs land in `%TEMP%` rather than `/tmp`.

`kujamba play` and `trigger` use vendored miniaudio instead of those host
tools. `-Dlive=true` compiles on Windows; real-device playback there is not
yet covered by CI evidence, so treat it as opt-in rather than promised.

## Join a room

`kujamba join` is headless — it never opens a microphone or speaker — and its
socket path is the Winsock seam. The protocol and flags are unchanged;
bracketed IPv6 works as on POSIX.

```powershell
.\zig-out\bin\kujamba.exe join --host example.com:20531 `
  --user YOUR_USER --pass YOUR_ROOM_PASSWORD
```

(Line continuation is a backtick in PowerShell, `^` in cmd, or write it on
one line. Git Bash keeps the `\` form used elsewhere in this manual.)

## What is not proven on Windows

- `demo/run_demo.sh` stays POSIX: it builds the reference `ninjamsrv` and
  client core, which are not ported.
- Live-device playback is compile-verified only, as noted above.
- Everything else the CI smoke covers — build, `zig build test` in Debug and
  ReleaseSafe, render/`check-ogg`/`encode-silence`, and the fart app's silent
  run — is verified Windows evidence, not a claim by analogy.
