---
title: NINJAM rooms
parent: guides/index
status: published
summary: Join a real server, select phrases, and conduct the instrument from room chat.
---

# Join the band

`kujamba join` is a **headless NINJAM instrument**. Its synth replaces capture.
It uploads Ogg Vorbis on the server's interval grid without opening a microphone
or speaker. Listen through a separate NINJAM client.

## Join a server

Use a server address and credentials supplied by your room operator:

```bash
./zig-out/bin/kujamba join --host 127.0.0.1:20531 \
  --user YOUR_USER --pass YOUR_ROOM_PASSWORD \
  --phrase "kujamba karibu" --pattern 3+1 --seed 42 --intervals 6
```

The loopback address is an example, not a server bundled into this command.
An omitted port retains the configured port, or defaults to `20531` without
a configured port. IPv6 literals need brackets:
`--host "[::1]:20531"`. Hostnames can resolve to either address family.

The server supplies BPM and beats per interval. Pattern `3+1` plays three bars
then rests for one. Rest bars send silence markers, not encoded dead air.

By default the run stops after **eight completed intervals** or its
**120-second safety cap**. Select explicit limits for a longer performance.
There is no documented unlimited resident-service mode.

<Aside kind="warning">

Passwords passed as command-line arguments may be visible to other local
processes. A private preset avoids shell-history copies, but is still a
plaintext file. Restrict its permissions and never commit room credentials.
The NINJAM connection here is not a TLS connection.

</Aside>

## Load a phrase bank

Create `phrases.txt`:

```text
# Each full line is both a phrase and its name.
kujamba karibu
habari yako
asante sana
```

```bash
./zig-out/bin/kujamba join --host 127.0.0.1:20531 \
  --user YOUR_USER --pass YOUR_ROOM_PASSWORD --phrases phrases.txt
```

Do not combine `--phrase` and `--phrases`. Each phrase is rendered once at
startup. The bank has a 64 MiB rendered-audio budget, roughly six minutes at
the instrument's sample rate.

## Conduct from room chat

Send ordinary room messages **without a leading `!`**:

| Message | Effect |
|---|---|
| `kujamba 2` | Select the second bank phrase |
| `kujamba habari yako` | Select that exact phrase text |
| `kujamba play` | Force play bars |
| `kujamba rest` | Force silence-marker bars |
| `kujamba loop` | Continue through the phrase, wrapping |
| `kujamba repeat` | Restart at each play bar |
| `kujamba once` | Play one pass |
| `kujamba stop` | Request a clean stop |

Phrase/mode/broadcast changes apply at the next interval boundary. A bad
selector is ignored and counted as `phrase_rejected`, not turned into a dropped
bar. Names match the full phrase text case-insensitively; numeric selectors
are one-based. Any room participant whose message reaches this hook can control it;
there is no bandleader authorization layer.

<Aside kind="info">

The local parser accepts a leading `!`, but the reference `ninjamsrv` consumes
unknown bang-prefixed messages before broadcasting them. `!kujamba loop`
therefore does not reach the instrument on that server. Use `kujamba loop`.

</Aside>

## Drops, reconnection, and stopping

A full upload socket drops the unsent interval remainder while source generation
and the clock continue. The mandatory tail of a partly sent frame still finishes
before later messages. A counted drop is not a claim of uninterrupted audible
playback.

`--reconnect` enables bounded redial attempts (five by default);
`--reconnect 10` chooses a budget. It is off by default. Rejoining resumes a new
bar and keeps upload identity monotonic.

Ctrl+C, SIGTERM, and chat stop finalize the **generated portion** of the current
interval and exit. They do not wait for the unplayed remainder of the bar.
Read the final `RESULT`: a connection alone is not a successful performance.

For exact flags and counters, see [[reference/cli|the CLI reference]].
