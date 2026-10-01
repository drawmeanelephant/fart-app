//! kujamba — the Flatlophone fart synth as a headless NINJAM instrument.
//!
//! No mic, no speaker: the deterministic synth replaces the capture device
//! and each interval is uploaded as Ogg Vorbis to a NINJAM server, in time on
//! the BPI grid the server announces. Rest bars emit NINJAM silence markers —
//! no dead air is ever uploaded as audio.
//!
//! Commands:
//!   kujamba join --host 127.0.0.1:20531 --user kujamba --pass secret \
//!       [--phrase "kujamba karibu"] [--seed N] [--pattern P] [--intervals N]
//!       [--out-dir DIR] [--dump-dir DIR] [--transcript FILE] [--duration S]
//!   kujamba render --phrase "kujamba karibu" --out karibu.wav
//!       [--play repeat|loop|once] [--pattern N+M] [--bars N] [--bar-ms MS] [--seed N]
//!       [--voice "attack=1,noise=0,wobble=2"]
//!       render a phrase to WAV/OGG offline, shaped as `join` would play it
//!   kujamba check-ogg FILE [--min-rms R]   decode a raw interval; exit 1 if silent
//!   kujamba encode-silence FILE [--seconds S]
//!       write one silent interval as Ogg (the negative control for check-ogg)
//!
//! Config / presets (#22): a TOML-style defaults file supplies join + instrument
//! settings (host, user, pass, phrase, pattern, [voice] knobs). `--config FILE`
//! names it explicitly; without that, ./kujamba.toml is used when present.
//! Values apply defaults <- config <- flags, so a flag always wins over the
//! file. See examples/kujamba.toml.

const std = @import("std");
const session = @import("ninjam/session.zig");
const audio = @import("ninjam/audio.zig");
const vorbis = @import("ninjam/vorbis.zig");
const synth = @import("synth.zig");
const kujamba_out = @import("ninjam_out.zig");
const kujamba_config = @import("kujamba_config.zig");
const libc = @cImport({
    @cInclude("signal.h");
    @cInclude("unistd.h"); // usleep — the drain loops' 10 ms ticks (#20)
});

/// The playback device period kujamba's local path opens with (#20): 480
/// frames at 44.1 kHz is ~10.9 ms, the same default the live session uses.
const play_period_frames: u32 = 480;
/// Extra silence queued after the rendered audio so its final samples are
/// still in the ring when the drain loop's grace period ends (#20).
const play_tail_seconds: f64 = 0.15;
/// How long the drain loop waits after the ring first reports empty before
/// declaring playback done (#20).
const play_grace_ms: u64 = 120;

fn handleStop(sig: c_int) callconv(.c) void {
    _ = sig;
    kujamba_out.requestStop();
}

fn printUsage(io: std.Io) void {
    const usage =
        \\usage:
        \\  kujamba join --host 127.0.0.1[:port] --user NAME --pass PASS [options]
        \\    --config FILE      TOML defaults file (see CONFIG below); without
        \\                       it, ./kujamba.toml is used when present
        \\    --phrase TEXT      Swahili phrase the butt speaks in fart
        \\                       (default "kujamba karibu")
        \\    --phrases FILE     a bank of phrases, one per line ('#' comments
        \\                       and blank lines skipped), any of which the room
        \\                       can pick live with !kujamba <n|name>. Mutually
        \\                       exclusive with --phrase. Every phrase is
        \\                       rendered once at startup, so switching is instant
        \\                       -- and so the whole bank is resident in memory at
        \\                       once (64 MiB of audio, ~6 min, is the ceiling)
        \\    --seed N           determinism seed: ids + payloads derive from it
        \\    --pattern P        bar pattern, e.g. 3+1 = 3 fart bars + 1 rest bar
        \\                       (default 3+1)
        \\    --voice SPEC       synth voice knobs (#18), e.g. "noise=0,wobble=2".
        \\                       Multipliers on each onset class's attack, noise mix
        \\                       and wobble depth; 1 is today's sound exactly.
        \\    --play MODE        how the phrase maps onto bars:
        \\                       repeat  restart at every fart bar (default)
        \\                       loop    play continuously, wrapping at the end
        \\                       once    play one pass, then silence
        \\                       (rest bars freeze the phrase position)
        \\    --intervals N      stop after N completed intervals (default 8); a
        \\                       mid-session BPI/BPM change does not restart this
        \\    --dump-dir DIR     write each interval's uploaded payload bytes to
        \\                       DIR/interval_NNNN.ogg (determinism evidence),
        \\                       numbered by a monotonic per-session sequence
        \\                       that survives a BPI/BPM change
        \\    --duration S       hard safety cap in seconds (default 120)
        \\    --reconnect [N]    on a lost connection, re-dial with bounded
        \\                       backoff and resume at the next bar (#24);
        \\                       N is the dial budget (default 5). Off by
        \\                       default; the RESULT line reports reconnects
        \\                       and the total outage either way
        \\    --out-dir DIR      directory for decoded peer WAVs (default dump)
        \\    --transcript FILE  transcript log (default <out-dir>/transcript.log)
        \\  kujamba render --phrase "..." --out FILE.wav|.ogg [--config FILE]
        \\                       [--play MODE] [--voice SPEC]
        \\                       [--pattern P] [--bars N] [--bar-ms MS] [--seed N]
        \\      render a phrase offline, shaped as join would play it. A rest bar
        \\      is exact silence and freezes the phrase cursor, matching the room.
        \\  kujamba play [<phrase>|--phrase TEXT] [--config FILE] [--play MODE]
        \\                       [--pattern P] [--bars N] [--bar-ms MS] [--seed N]
        \\                       [--voice SPEC] [--device NAME|INDEX]
        \\      render like `render` and play it on the local output device
        \\      (#20, vendored miniaudio — no afplay shell-out). A bare phrase
        \\      is shorthand for --phrase; give one, not both. Exits 1 with a
        \\      clear message when no output device is available.
        \\  kujamba trigger [--config FILE] [--device NAME|INDEX] [--script FILE]
        \\      the #21 sampler: stdin lines drive it — `on <N>` plays the sound
        \\      [map] binds to note N (phrase or shuzi:<seed>), `off <N>` is
        \\      accepted and ignored, `q` or EOF exits. With --script FILE the
        \\      lines come from a file instead (same protocol), which is how
        \\      headless runs and tests drive it. Renders happen on the note-on
        \\      itself (<50 ms), so a sound starts within one bar of its note-on.
        \\  kujamba check-ogg FILE [--min-rms R]   analyze an interval; exit 1 if rms < R
        \\  kujamba encode-silence FILE [--seconds S]   write a silent interval
        \\
        \\CHAT (#9, #8): a `kujamba ...` command in room chat shapes the
        \\performance live, and every one of them lands on the next bar, so
        \\nothing ever splices mid-phrase:
        \\  kujamba play|rest       force a play bar / a silence-marker bar
        \\  kujamba loop|repeat|once how the phrase maps onto bars (--play)
        \\  kujamba <n>|<name>      play another phrase from --phrases
        \\  kujamba stop            finish the current interval and exit
        \\An unknown <n>/<name> is ignored and counted, never a dropped bar.
        \\A leading "!" is accepted but NOT required: ninjamsrv swallows any
        \\"!"-prefixed room message as an unknown command, so "!kujamba loop"
        \\never reaches the room. Say it without the sigil.
        \\
        \\CONFIG (#22): a TOML-style file of defaults for join, render, play
        \\and trigger —
        \\  host (same syntax as --host, so "name:port" / "[::1]:port"), user,
        \\  pass, phrase, pattern, a [voice] table with attack/noise/wobble
        \\  multipliers, and a [map] table binding `noteN = phrase|shuzi:seed`
        \\  for `trigger` (#21). Values apply defaults <- config <- flags, so a flag
        \\  always wins over the file; a --voice flag replaces the whole
        \\  [voice] table. Example: examples/kujamba.toml in the repo.
        \\
        \\join exits 0 only if at least one interval was uploaded; Ctrl+C finishes
        \\the current interval cleanly and reports the same way.
        \\
    ;
    std.Io.File.stderr().writeStreamingAll(io, usage) catch {};
}

fn fail(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "error: " ++ fmt ++ "\n", args) catch "error\n";
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    // Ctrl+C finishes the current interval cleanly (see session run loop).
    _ = libc.signal(libc.SIGINT, handleStop);
    _ = libc.signal(libc.SIGTERM, handleStop);
    const args = try std.process.Args.toSlice(init.minimal.args, arena);

    if (args.len < 2) {
        printUsage(io);
        std.process.exit(2);
    }
    if (std.mem.eql(u8, args[1], "join")) {
        if (args.len > 2 and (std.mem.eql(u8, args[2], "--help") or std.mem.eql(u8, args[2], "help"))) {
            printUsage(io);
            return;
        }
        return cmdJoin(io, gpa, arena, args[2..]);
    } else if (std.mem.eql(u8, args[1], "render")) {
        return cmdRender(io, gpa, arena, args[2..]);
    } else if (std.mem.eql(u8, args[1], "play")) {
        return cmdPlay(io, gpa, arena, args[2..]);
    } else if (std.mem.eql(u8, args[1], "trigger")) {
        return cmdTrigger(io, gpa, arena, args[2..]);
    } else if (std.mem.eql(u8, args[1], "check-ogg")) {
        return cmdCheckOgg(io, args[2..]);
    } else if (std.mem.eql(u8, args[1], "encode-silence")) {
        return cmdEncodeSilence(io, gpa, args[2..]);
    } else if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "help")) {
        printUsage(io);
        return;
    }
    printUsage(io);
    std.process.exit(2);
}

// ---- config / preset file (#22) ---------------------------------------------

/// File loaded when `--config` is not given; its absence is fine.
const config_file_name = kujamba_config.default_file;
/// A hand-edited defaults file should never be big; this is just a guard
/// against pointing --config at a log file by mistake.
const max_config_bytes: u64 = 1024 * 1024;

/// Find and parse the config file for a join/render run: `--config FILE` names
/// it explicitly (missing or malformed is an error), otherwise `./kujamba.toml`
/// is used when it exists (its absence is the normal no-config case). Returns
/// null when no file applies. Any failure exits via fail().
fn loadConfigFile(io: std.Io, arena: std.mem.Allocator, argv: []const []const u8) ?kujamba_config.Config {
    // the pre-scan means --config works wherever it appears, even before the
    // flags it must not lose to
    var path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        if (!std.mem.eql(u8, argv[i], "--config")) continue;
        if (path != null) fail(io, "--config given twice", .{});
        if (i + 1 >= argv.len) fail(io, "--config needs a value", .{});
        path = argv[i + 1];
        i += 1;
    }

    const opened: ?std.Io.File = if (path) |p|
        std.Io.Dir.cwd().openFile(io, p, .{}) catch |e|
            fail(io, "cannot open config '{s}': {s}", .{ p, @errorName(e) })
    else
        std.Io.Dir.cwd().openFile(io, config_file_name, .{}) catch |e| switch (e) {
            error.FileNotFound => null,
            else => fail(io, "cannot open ./{s}: {s}", .{ config_file_name, @errorName(e) }),
        };
    const f = opened orelse return null;
    defer f.close(io);

    const size = f.length(io) catch fail(io, "cannot stat config '{s}'", .{path orelse config_file_name});
    if (size > max_config_bytes)
        fail(io, "config '{s}' is larger than 1 MiB — is this the right file?", .{path orelse config_file_name});
    const data = arena.alloc(u8, @intCast(size)) catch fail(io, "out of memory reading config", .{});
    const got = f.readPositionalAll(io, data, 0) catch
        fail(io, "cannot read config '{s}'", .{path orelse config_file_name});

    // The strings in the Config point into `data`, which lives in the arena
    // for the rest of the run — as long as the settings that use them.
    var diag = kujamba_config.Diag{ .file = path orelse config_file_name };
    return kujamba_config.parse(data[0..got], &diag) catch
        fail(io, "{s}:{d}: {s}", .{ diag.file, diag.line, diag.message() });
}

/// Read a whole text file into the arena, for `--phrases` (#8). The arena keeps
/// the text alive for the run, and the bank's `Phrase.name` slices borrow from
/// it, so no per-name copy is needed.
///
/// The size cap is the same 1 MiB as the config file, and for the same reason:
/// these are hand-written files, and `--phrases /var/log/thing` should say so
/// rather than try to render a few hundred thousand phrases.
fn readTextFile(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.ReadFailed;
    defer f.close(io);
    const size = f.length(io) catch return error.ReadFailed;
    if (size > max_config_bytes) return error.Rejected;
    const data = arena.alloc(u8, @intCast(size)) catch return error.OutOfMemory;
    const got = f.readPositionalAll(io, data, 0) catch return error.ReadFailed;
    return data[0..got];
}

/// Canonical "N" / "N+M" text for a parsed pattern — what `render`'s summary
/// line prints when the pattern came from the config file rather than a flag.
fn formatPattern(arena: std.mem.Allocator, p: kujamba_out.Pattern) ![]const u8 {
    if (p.rest == 0) return std.fmt.allocPrint(arena, "{d}", .{p.play});
    return std.fmt.allocPrint(arena, "{d}+{d}", .{ p.play, p.rest });
}

/// The `join` option set: built-in defaults, then the config file
/// (applyConfig), then flags — each layer overwrites the previous one, so a
/// flag always wins over the config file and the file always wins over the
/// defaults (#22).
const JoinSettings = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 20531,
    user: []const u8 = "kujamba",
    pass: []const u8 = "secret",
    phrase: []const u8 = "kujamba karibu",
    seed: u64 = 1,
    /// "3+1"
    pattern: kujamba_out.Pattern = .{ .play = 3, .rest = 1 },
    play_mode: kujamba_out.Mode = .repeat,
    knobs: synth.VoiceKnobs = .{},
    intervals: u64 = 8,
    duration_ms: i64 = 120_000,
    /// --reconnect [#24]: reconnect dial budget on a lost connection. 0 = off
    /// (a connection death ends the session, as it always has).
    reconnect_attempts: u32 = 0,
    out_dir: []const u8 = "dump",
    dump_dir: ?[]const u8 = null,
    transcript: ?[]const u8 = null,
    /// --phrases FILE: a phrase bank to pick from live (#8). Mutually exclusive
    /// with --phrase, and the flag wins over a config-file phrase (#22's rule).
    phrases_file: ?[]const u8 = null,

    /// Lay the config file's values over the defaults. Runs BEFORE the flag
    /// loop, which overwrites the same fields — that ordering *is* the
    /// "flags win" rule. Absent keys are null/identity, so an untouched
    /// setting keeps its default.
    fn applyConfig(self: *JoinSettings, cfg: *const kujamba_config.Config) void {
        if (cfg.host) |h| self.host = h;
        if (cfg.port) |p| self.port = p;
        if (cfg.user) |v| self.user = v;
        if (cfg.pass) |v| self.pass = v;
        if (cfg.phrase) |v| self.phrase = v;
        if (cfg.pattern) |p| self.pattern = p;
        self.knobs = cfg.knobs;
    }
};

/// Apply a `!kujamba <verb>` command from room chat to the plan (#9, #8).
/// Mode/rest/phrase changes reshape the plan here; the session picks them up at
/// the next bar boundary (the selection is applied there), so nothing splices
/// mid-bar. `stop` reuses the same cooperative-stop path as Ctrl+C.
fn applyChatCommand(ctx: *anyopaque, cmd: kujamba_out.ChatCommand) void {
    const adapter: *kujamba_out.PlanAdapter = @ptrCast(@alignCast(ctx));
    switch (cmd) {
        .play => adapter.rest = false,
        .rest => adapter.rest = true,
        .loop => adapter.mode = .loop,
        .repeat => adapter.mode = .repeat,
        .once => adapter.mode = .once,
        .stop => kujamba_out.requestStop(),
        // #8: resolve the selector now, apply it at the next bar boundary. An
        // unresolvable one is counted in the bank and leaves audio untouched.
        .select => |sel| adapter.bank.request(sel),
        .none => {},
    }
}

fn receiveChat(ctx: *anyopaque, message: @import("ninjam/proto.zig").ChatParms) void {
    applyChatCommand(ctx, kujamba_out.commandFromChat(message));
}

fn cmdJoin(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, argv: []const []const u8) !void {
    var s = JoinSettings{};

    // config file first, flags second: the loop below overwrites, so a flag
    // always wins over the file wherever it appears (#22)
    const cfg = loadConfigFile(io, arena, argv);
    if (cfg) |*c| s.applyConfig(c);

    // --phrase and --phrases are two ways to fill the same slot (which phrases
    // the instrument can play), so giving both on one command line is a mistake
    // worth reporting rather than silently resolving. This is the "flag-over-
    // file precedence" question #8's body flagged: against the *config* file
    // the usual rule applies unchanged (a flag wins), and only a flag-vs-flag
    // collision is an error.
    var phrase_flag = false;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        const next: ?[]const u8 = if (i + 1 < argv.len) argv[i + 1] else null;
        if (std.mem.eql(u8, a, "--host")) {
            const v = next orelse fail(io, "--host needs a value", .{});
            const p = kujamba_config.splitHostPort(v, &s.host) catch |e| switch (e) {
                // the same wording --host has always used
                error.MissingBracket => fail(io, "bad --host: missing ']'", .{}),
                error.BadHostAfterBracket => fail(io, "bad --host after ']'", .{}),
                error.BadPort => fail(io, "bad port in --host", .{}),
                error.Ipv6NeedsBrackets => fail(io, "IPv6 host needs brackets: --host [::1]:port", .{}),
            };
            if (p) |pp| s.port = pp;
            i += 1;
        } else if (std.mem.eql(u8, a, "--config")) {
            i += 1; // consumed by loadConfigFile; skip the value here
        } else if (std.mem.eql(u8, a, "--play")) {
            s.play_mode = kujamba_out.parseMode(next orelse fail(io, "--play needs a value", .{})) catch
                fail(io, "bad --play '{s}' (want repeat, loop or once)", .{next.?});
            i += 1;
        } else if (std.mem.eql(u8, a, "--voice")) {
            s.knobs = synth.parseKnobs(next orelse fail(io, "--voice needs a value", .{})) catch |e|
                fail(io, "bad --voice '{s}': {s} (want attack=N,noise=N,wobble=N)", .{ next.?, @errorName(e) });
            i += 1;
        } else if (std.mem.eql(u8, a, "--user")) {
            s.user = next orelse fail(io, "--user needs a value", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--pass")) {
            s.pass = next orelse fail(io, "--pass needs a value", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--phrase")) {
            s.phrase = next orelse fail(io, "--phrase needs a value", .{});
            phrase_flag = true;
            i += 1;
        } else if (std.mem.eql(u8, a, "--seed")) {
            s.seed = std.fmt.parseInt(u64, next orelse fail(io, "--seed needs a value", .{}), 10) catch fail(io, "bad --seed", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--pattern")) {
            const v = next orelse fail(io, "--pattern needs a value", .{});
            s.pattern = kujamba_out.parsePattern(v) catch fail(io, "bad --pattern '{s}' (want N or N+M)", .{v});
            i += 1;
        } else if (std.mem.eql(u8, a, "--intervals")) {
            s.intervals = std.fmt.parseInt(u64, next orelse fail(io, "--intervals needs a value", .{}), 10) catch fail(io, "bad --intervals", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--reconnect")) {
            // #24: on a lost connection, re-dial with bounded backoff instead of
            // ending the session. Bare flag = a default budget of 5 attempts;
            // `--reconnect N` prices the budget explicitly. Off by default: the
            // live demo must keep reporting connection deaths verbatim, because
            // a reconnect that papers over the #28 flake would blind the very
            // gate that is measuring it. Flip the default after #28 closes.
            s.reconnect_attempts = if (next) |v| blk: {
                if (v.len > 0 and v[0] != '-') {
                    i += 1;
                    break :blk std.fmt.parseInt(u32, v, 10) catch fail(io, "bad --reconnect '{s}' (want a count >= 0)", .{v});
                }
                break :blk 5;
            } else 5;
        } else if (std.mem.eql(u8, a, "--duration")) {
            const secs = std.fmt.parseFloat(f64, next orelse fail(io, "--duration needs a value", .{})) catch fail(io, "bad --duration", .{});
            // NaN/negative would panic in @intFromFloat
            if (!(secs > 0.0) or secs > 86400.0)
                fail(io, "--duration must be in (0, 86400] seconds", .{});
            s.duration_ms = @intFromFloat(secs * 1000.0);
            i += 1;
        } else if (std.mem.eql(u8, a, "--out-dir")) {
            s.out_dir = next orelse fail(io, "--out-dir needs a value", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--dump-dir")) {
            s.dump_dir = next orelse fail(io, "--dump-dir needs a value", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--transcript")) {
            s.transcript = next orelse fail(io, "--transcript needs a value", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--phrases")) {
            s.phrases_file = next orelse fail(io, "--phrases needs a value", .{});
            i += 1;
        } else {
            fail(io, "unknown option '{s}'", .{a});
        }
    }

    // The synth is the capture device: render every phrase once, up front, then
    // read them out interval by interval. With no --phrases that is a bank of
    // one, so a live switch and the single-phrase case are the same code path
    // (#8).
    if (s.phrases_file != null and phrase_flag)
        fail(io, "--phrase and --phrases both given: pick one", .{});

    var bank = kujamba_out.PhraseBank.init(gpa);
    defer bank.deinit();
    if (s.phrases_file) |path| {
        const text = readTextFile(io, arena, path) catch |e| switch (e) {
            error.OutOfMemory => fail(io, "out of memory reading {s}", .{path}),
            error.Rejected => fail(io, "refusing to read {s} as a phrase bank", .{path}),
            error.ReadFailed => fail(io, "cannot read phrases file '{s}'", .{path}),
        };
        bank.parse(text, s.knobs) catch |e| switch (e) {
            // The budget is on rendered audio, not file size, so this is the
            // one failure a user reaches by having *too many good phrases* —
            // worth saying what to do about it rather than naming an error set.
            error.BankTooLarge => fail(io, "phrase bank '{s}' renders to more than {d} MiB of audio across {d} phrases — split the file or drop some", .{
                path,
                // Ceiling division: a budget that is not a whole number of MiB
                // would otherwise floor to "0 MiB" and name no limit at all.
                (kujamba_out.max_bank_samples * @sizeOf(f32) + 1024 * 1024 - 1) / (1024 * 1024),
                bank.entries.items.len,
            }),
            // Anything else is attributable to a line, the same way a config
            // error is: `file:line: why` is the convention the loader sets.
            else => if (bank.fail_line) |ln|
                fail(io, "{s}:{d}: {s}", .{ path, ln, @errorName(e) })
            else
                fail(io, "phrase bank '{s}' failed: {s}", .{ path, @errorName(e) }),
        };
        if (bank.entries.items.len == 0)
            fail(io, "phrases file '{s}' has no phrases (only comments or blank lines?)", .{path});
    } else {
        bank.add(s.phrase, s.knobs) catch |e| fail(io, "phrase render failed: {s}", .{@errorName(e)});
    }

    // The first phrase is live before the first bar; bind it into the fill so
    // the very first interval is not silent.
    var fill = kujamba_out.Fill{ .mode = s.play_mode };
    fill.bind(s.play_mode, bank.active());
    // kujamba (#11): the plan owns the selection — the pattern (rest bars) plus
    // the mode and phrase the session should bind each bar. A live switch just
    // updates the adapter; the session picks it up at the next bar boundary.
    var adapter = kujamba_out.PlanAdapter{ .pattern = &s.pattern, .mode = s.play_mode, .bank = &bank, .fill = &fill };

    var opts = session.Options{
        .host = s.host,
        .port = s.port,
        .user = s.user,
        .pass = s.pass,
        .srate = synth.SAMPLE_RATE,
        .channel_names = &.{"kujamba"},
        .source = fill.source(),
        .id_seed = s.seed,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.broadcastForFn },
        .on_chat = .{ .ctx = @ptrCast(&adapter), .receive = receiveChat },
        .stop = .{ .requested = kujamba_out.sessionStopRequested },
        .out_dir = s.out_dir,
        .payload_dump_dir = s.dump_dir,
        .stop_after_intervals = s.intervals,
        .duration_ms = s.duration_ms,
        .reconnect_attempts = s.reconnect_attempts,
        .quality = 0.0,
    };
    if (s.transcript) |t| {
        opts.transcript_path = t;
    } else {
        opts.transcript_path = try std.fmt.allocPrint(arena, "{s}/transcript.log", .{s.out_dir});
    }

    var sess = session.Session.init(gpa, io, opts) catch |e| fail(io, "init failed: {s}", .{@errorName(e)});
    defer sess.deinit();

    const stats = sess.run() catch sess.stats;

    // exit-code honesty: a run that uploaded nothing is a failure even if the
    // duration cap was reached without an error
    var err_text: []const u8 = stats.failText();
    var ok = stats.ok;
    if (ok and stats.intervals_uploaded == 0) {
        ok = false;
        err_text = "no intervals uploaded";
    }

    var out_buf: [2048]u8 = undefined;
    const line = std.fmt.bufPrint(
        &out_buf,
        "RESULT ok={} err=\"{s}\" seed={d} play={s} phrases={d} phrase={d} phrase_switches={d} phrase_rejected={d} intervals_uploaded={d} intervals_broadcast={d} silence_markers={d} payload_dumps={d} upload_chunks={d} upload_bytes={d} intervals_downloaded={d} msgs_sent={d} msgs_recv={d} intervals_dropped={d} intervals_backpressured={d} upload_bytes_dropped={d} upload_stall_ms={d} drift_ms={d} max_drift_ms={d} clock_corrections={d} reconnects={d} outage_ms={d}\n",
        .{
            ok,
            err_text,
            s.seed,
            @tagName(s.play_mode),
            bank.entries.items.len,
            bank.current,
            bank.switches,
            bank.rejected,
            stats.intervals_uploaded,
            stats.intervals_broadcast,
            stats.silence_markers,
            stats.payload_dumps,
            stats.upload_chunks,
            stats.upload_bytes,
            stats.intervals_downloaded,
            stats.msgs_sent,
            stats.msgs_recv,
            // M5 timing telemetry (#13, #14). `intervals_dropped` is the one a
            // user should ever notice: a non-zero value means the room heard
            // gaps, and the transcript names which bars and why.
            stats.intervals_dropped,
            stats.intervals_backpressured,
            stats.upload_bytes_dropped,
            @divTrunc(stats.upload_stall_ns, std.time.ns_per_ms),
            @divTrunc(stats.drift_ns, std.time.ns_per_ms),
            @divTrunc(stats.max_abs_drift_ns, std.time.ns_per_ms),
            stats.clock_corrections,
            // #24: the cost of the connection the room never had to think
            // about. reconnects counts the rejoins that landed; outage_ms is
            // everything the audience actually missed, backoff included.
            stats.reconnects,
            stats.outage_ms,
        },
    ) catch return;
    std.Io.File.stdout().writeStreamingAll(io, line) catch {};

    if (!ok) std.process.exit(1);
}

fn peakOf(pcm: []const f32) f64 {
    var peak: f64 = 0;
    for (pcm) |s| {
        const a = @abs(s);
        if (a > peak) peak = a;
    }
    return peak;
}

fn cmdCheckOgg(io: std.Io, argv: []const []const u8) !void {
    var path: ?[]const u8 = null;
    var min_rms: f64 = 0.001;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--min-rms")) {
            i += 1;
            if (i >= argv.len) fail(io, "--min-rms needs a value", .{});
            min_rms = std.fmt.parseFloat(f64, argv[i]) catch fail(io, "bad --min-rms", .{});
        } else {
            path = a;
        }
    }
    const p = path orelse fail(io, "check-ogg needs a file path", .{});

    var f = std.Io.Dir.cwd().openFile(io, p, .{}) catch fail(io, "cannot open '{s}'", .{p});
    defer f.close(io);
    const size = f.length(io) catch fail(io, "cannot stat '{s}'", .{p});
    const data = std.heap.page_allocator.alloc(u8, @intCast(size)) catch fail(io, "oom", .{});
    defer std.heap.page_allocator.free(data);
    const got = f.readPositionalAll(io, data, 0) catch fail(io, "cannot read '{s}'", .{p});

    var dec = vorbis.decodeMemory(std.heap.page_allocator, data[0..got]) catch fail(io, "decode failed '{s}'", .{p});
    defer dec.deinit();

    const rms = dec.rms();
    const peak = peakOf(dec.pcm);

    const pass = rms >= min_rms;
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "OGG {s} frames={d} srate={d} ch={d} rms={d:.6} peak={d:.6} pass={}", .{ p, dec.frames(), dec.srate, dec.channels, rms, peak, pass }) catch return;
    std.Io.File.stdout().writeStreamingAll(io, line) catch {};
    std.Io.File.stdout().writeStreamingAll(io, "\n") catch {};
    if (!pass) {
        var ebuf: [256]u8 = undefined;
        const emsg = std.fmt.bufPrint(&ebuf, "FAIL: rms {d:.6} < {d:.6}", .{ rms, min_rms }) catch "FAIL";
        std.Io.File.stderr().writeStreamingAll(io, emsg) catch {};
        std.Io.File.stderr().writeStreamingAll(io, "\n") catch {};
        std.process.exit(1);
    }
}

/// Offline render: a phrase to a WAV or OGG file, shaped exactly as `join`
/// would have played it, with no server and no room in the way.
fn cmdRender(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, argv: []const []const u8) !void {
    var phrase: []const u8 = "kujamba karibu";
    var out_path: ?[]const u8 = null;
    var pattern: kujamba_out.Pattern = .{ .play = 1, .rest = 0 }; // "1"
    var pattern_label: []const u8 = "1";
    var play_mode = kujamba_out.Mode.repeat;
    var bars: u32 = 1;
    var bar_ms: u64 = 0;
    var seed: u64 = 0;
    var knobs: synth.VoiceKnobs = .{};

    // config first, flags second — the same rule join follows. Render takes
    // the instrument keys (phrase, pattern, [voice]); the connection keys are
    // simply not read here.
    const cfg = loadConfigFile(io, arena, argv);
    if (cfg) |*c| {
        if (c.phrase) |v| phrase = v;
        if (c.pattern) |p| {
            pattern = p;
            pattern_label = try formatPattern(arena, p);
        }
        knobs = c.knobs;
    }

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        const next = if (i + 1 < argv.len) argv[i + 1] else null;
        if (std.mem.eql(u8, a, "--phrase")) {
            phrase = next orelse fail(io, "--phrase needs a value", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--config")) {
            i += 1; // consumed by loadConfigFile; skip the value here
        } else if (std.mem.eql(u8, a, "--play")) {
            play_mode = kujamba_out.parseMode(next orelse fail(io, "--play needs a value", .{})) catch
                fail(io, "bad --play '{s}' (want repeat, loop or once)", .{next.?});
            i += 1;
        } else if (std.mem.eql(u8, a, "--voice")) {
            knobs = synth.parseKnobs(next orelse fail(io, "--voice needs a value", .{})) catch |e|
                fail(io, "bad --voice '{s}': {s} (want attack=N,noise=N,wobble=N)", .{ next.?, @errorName(e) });
            i += 1;
        } else if (std.mem.eql(u8, a, "--pattern")) {
            const v = next orelse fail(io, "--pattern needs a value", .{});
            pattern = kujamba_out.parsePattern(v) catch fail(io, "bad --pattern '{s}' (want N or N+M)", .{v});
            pattern_label = v;
            i += 1;
        } else if (std.mem.eql(u8, a, "--bars")) {
            bars = std.fmt.parseInt(u32, next orelse fail(io, "--bars needs a value", .{}), 10) catch fail(io, "bad --bars", .{});
            if (bars == 0) fail(io, "--bars must be at least 1", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--bar-ms")) {
            bar_ms = std.fmt.parseInt(u64, next orelse fail(io, "--bar-ms needs a value", .{}), 10) catch fail(io, "bad --bar-ms", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--seed")) {
            seed = std.fmt.parseInt(u64, next orelse fail(io, "--seed needs a value", .{}), 10) catch fail(io, "bad --seed", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--out")) {
            out_path = next orelse fail(io, "--out needs a value", .{});
            i += 1;
        } else {
            fail(io, "render: unexpected argument '{s}'", .{a});
        }
    }
    const p = out_path orelse fail(io, "render needs --out FILE", .{});

    const opts = kujamba_out.OfflineOpts{
        .mode = play_mode,
        .pattern = pattern,
        .bars = bars,
        .bar_samples = if (bar_ms == 0)
            0
        else
            @as(u64, kujamba_out.sample_rate) * bar_ms / 1000,
        .knobs = knobs,
    };

    const pcm = kujamba_out.renderOfflineF32(gpa, phrase, opts) catch |e|
        fail(io, "phrase render failed: {s}", .{@errorName(e)});
    defer gpa.free(pcm);

    // The container is chosen by extension, and the Ogg serial comes from the
    // same seed derivation a session would use, so --seed is reproducible.
    const is_ogg = std.ascii.endsWithIgnoreCase(p, ".ogg");
    const is_wav = std.ascii.endsWithIgnoreCase(p, ".wav");
    if (!is_ogg and !is_wav) fail(io, "--out must end in .wav or .ogg (got '{s}')", .{p});

    const bytes = if (is_ogg)
        kujamba_out.renderOfflineOgg(gpa, phrase, opts, kujamba_out.deriveSerial(seed, 0, 0)) catch |e|
            fail(io, "ogg encode failed: {s}", .{@errorName(e)})
    else
        kujamba_out.renderOfflineWav(gpa, phrase, opts) catch |e|
            fail(io, "wav encode failed: {s}", .{@errorName(e)});
    defer gpa.free(bytes);

    const f = std.Io.Dir.cwd().createFile(io, p, .{}) catch fail(io, "cannot create '{s}'", .{p});
    defer f.close(io);
    f.writeStreamingAll(io, bytes) catch fail(io, "cannot write '{s}'", .{p});

    const seconds = @as(f64, @floatFromInt(pcm.len)) / @as(f64, @floatFromInt(kujamba_out.sample_rate));
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "wrote {s}: {d} bars x {d}ms pattern {s} play {s} -> {d} bytes, {d:.3}s, peak {d:.3} rms {d:.4}\n", .{
        p,                       bars,                   bar_ms, pattern_label, @tagName(play_mode), bytes.len, seconds,
        kujamba_out.peakOf(pcm), kujamba_out.rmsOf(pcm),
    }) catch return;
    std.Io.File.stdout().writeStreamingAll(io, line) catch {};
}

/// #20: local audition. Render exactly like `render` (same OfflineOpts, same
/// config file), then queue the PCM on the vendored miniaudio playback device
/// and wait for the ring to drain. No afplay, no shell-out: the same path the
/// live session uses, minus the capture side. Exits 1 with a clear message
/// when the build has live audio off or the host has no output device.
fn cmdPlay(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, argv: []const []const u8) !void {
    if (comptime !audio.enabled) {
        fail(io, "play: this build has live audio disabled — rebuild with -Dlive", .{});
    }
    var phrase: []const u8 = "kujamba karibu";
    var phrase_flagged = false;
    var positional: ?[]const u8 = null;
    var pattern: kujamba_out.Pattern = .{ .play = 1, .rest = 0 };
    var pattern_label: []const u8 = "1";
    var play_mode = kujamba_out.Mode.repeat;
    var bars: u32 = 1;
    var bar_ms: u64 = 0;
    var knobs: synth.VoiceKnobs = .{};
    var device: ?[]const u8 = null;

    const cfg = loadConfigFile(io, arena, argv);
    if (cfg) |*c| {
        if (c.phrase) |v| phrase = v;
        if (c.pattern) |pat| {
            pattern = pat;
            pattern_label = try formatPattern(arena, pat);
        }
        knobs = c.knobs;
    }

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        const next = if (i + 1 < argv.len) argv[i + 1] else null;
        if (std.mem.eql(u8, a, "--phrase")) {
            phrase = next orelse fail(io, "--phrase needs a value", .{});
            phrase_flagged = true;
            i += 1;
        } else if (std.mem.eql(u8, a, "--config")) {
            i += 1; // consumed by loadConfigFile
        } else if (std.mem.eql(u8, a, "--play")) {
            play_mode = kujamba_out.parseMode(next orelse fail(io, "--play needs a value", .{})) catch
                fail(io, "bad --play '{s}' (want repeat, loop or once)", .{next.?});
            i += 1;
        } else if (std.mem.eql(u8, a, "--voice")) {
            knobs = synth.parseKnobs(next orelse fail(io, "--voice needs a value", .{})) catch |e|
                fail(io, "bad --voice '{s}': {s} (want attack=N,noise=N,wobble=N)", .{ next.?, @errorName(e) });
            i += 1;
        } else if (std.mem.eql(u8, a, "--pattern")) {
            const v = next orelse fail(io, "--pattern needs a value", .{});
            pattern = kujamba_out.parsePattern(v) catch fail(io, "bad --pattern '{s}' (want N or N+M)", .{v});
            pattern_label = v;
            i += 1;
        } else if (std.mem.eql(u8, a, "--bars")) {
            bars = std.fmt.parseInt(u32, next orelse fail(io, "--bars needs a value", .{}), 10) catch fail(io, "bad --bars", .{});
            if (bars == 0) fail(io, "--bars must be at least 1", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--bar-ms")) {
            bar_ms = std.fmt.parseInt(u64, next orelse fail(io, "--bar-ms needs a value", .{}), 10) catch fail(io, "bad --bar-ms", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--seed")) {
            // accepted for render parity; the local render is deterministic
            // regardless, and the OGG serial has no meaning here
            _ = std.fmt.parseInt(u64, next orelse fail(io, "--seed needs a value", .{}), 10) catch fail(io, "bad --seed", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--device")) {
            device = next orelse fail(io, "--device needs a name or index", .{});
            i += 1;
        } else if (std.mem.startsWith(u8, a, "-")) {
            fail(io, "play: unexpected argument '{s}'", .{a});
        } else if (positional != null) {
            fail(io, "play: unexpected argument '{s}' (the phrase is already '{s}')", .{ a, positional.? });
        } else {
            positional = a;
        }
    }
    if (positional) |p| {
        if (phrase_flagged)
            fail(io, "play: both '{s}' and --phrase given — use one", .{p});
        phrase = p;
    }

    const opts = kujamba_out.OfflineOpts{
        .mode = play_mode,
        .pattern = pattern,
        .bars = bars,
        .bar_samples = if (bar_ms == 0)
            0
        else
            @as(u64, kujamba_out.sample_rate) * bar_ms / 1000,
        .knobs = knobs,
    };
    const pcm = kujamba_out.renderOfflineF32(gpa, phrase, opts) catch |e|
        fail(io, "phrase render failed: {s}", .{@errorName(e)});
    defer gpa.free(pcm);

    var probe_buf: [256]u8 = undefined;
    const probe = audio.Device.probePlayback(&probe_buf);
    const dev_id: ?[*:0]const u8 = if (device) |d|
        (arena.dupeZ(u8, d) catch fail(io, "out of memory", .{})).ptr
    else
        null;
    const dev = audio.Device.openPlayback(gpa, kujamba_out.sample_rate, play_period_frames, dev_id) catch |e| {
        var why_buf: [320]u8 = undefined;
        const why = if (device) |d|
            std.fmt.bufPrint(&why_buf, "cannot open output device '{s}' ({s}: {s})", .{
                d, @errorName(e), audio.Device.lastError(audio.last_open_error),
            }) catch "cannot open output device"
        else
            std.fmt.bufPrint(&why_buf, "no output device available ({s}: {s})", .{
                @errorName(e), audio.Device.lastError(audio.last_open_error),
            }) catch "no output device available";
        fail(io, "play: {s}", .{why});
    };
    defer dev.deinit(gpa);

    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "playing {d:.3}s on \"{s}\" ({s}, {d} Hz)\n", .{
        @as(f64, @floatFromInt(pcm.len)) / @as(f64, @floatFromInt(kujamba_out.sample_rate)),
        dev.nameSlice(),
        dev.backend(),
        dev.dev_srate,
    }) catch return;
    std.Io.File.stdout().writeStreamingAll(io, line) catch {};
    _ = probe;

    // queuedPlayback() reaching 0 means every sample (audio + the silent tail
    // that keeps the last period audible) was handed to the hardware callback.
    dev.writePlayback(pcm);
    const tail: usize = @intFromFloat(play_tail_seconds * @as(f64, @floatFromInt(kujamba_out.sample_rate)));
    const tail_zeros = try gpa.alloc(f32, @min(tail, 1 << 16));
    defer gpa.free(tail_zeros);
    @memset(tail_zeros, 0);
    var tail_left = tail;
    var grace: u64 = 0;
    while (grace < play_grace_ms) : (grace += 10) {
        if (kujamba_out.stopRequested()) break;
        while (tail_left > 0) {
            const chunk = @min(tail_zeros.len, tail_left);
            dev.writePlayback(tail_zeros[0..chunk]);
            tail_left -= chunk;
        }
        if (dev.queuedPlayback() == 0) break;
        _ = libc.usleep(10 * 1000);
    }
    // let the hardware pull the last queued period before the device closes
    _ = libc.usleep(@intCast((play_period_frames * 1000 * 1000) / kujamba_out.sample_rate + 10 * 1000));
    const done = "done\n";
    std.Io.File.stdout().writeStreamingAll(io, done) catch {};
}

fn sinkWritePlayback(ctx: *anyopaque, samples: []const f32) void {
    const dev: *audio.Device = @ptrCast(@alignCast(ctx));
    dev.writePlayback(samples);
}

/// #21: the sampler. stdin lines (or --script FILE) drive it: `on <N>` renders
/// the sound [map] binds to note N and queues it on the local playback device,
/// `off <N>` is accepted and ignored (one-shot sounds), `q`/EOF exits cleanly.
/// Unknown lines/notes are warned about and ignored — a live player hits wrong
/// keys. Rendering happens on the note-on itself (these renders are <50 ms),
/// so the sound starts after one device period, well inside a bar.
fn cmdTrigger(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, argv: []const []const u8) !void {
    if (comptime !audio.enabled) {
        fail(io, "trigger: this build has live audio disabled — rebuild with -Dlive", .{});
    }
    var device: ?[]const u8 = null;
    var script: ?[]const u8 = null;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        const next = if (i + 1 < argv.len) argv[i + 1] else null;
        if (std.mem.eql(u8, a, "--config")) {
            i += 1; // consumed by loadConfigFile below
        } else if (std.mem.eql(u8, a, "--device")) {
            device = next orelse fail(io, "--device needs a name or index", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--script")) {
            script = next orelse fail(io, "--script needs a file path", .{});
            i += 1;
        } else {
            fail(io, "trigger: unexpected argument '{s}'", .{a});
        }
    }
    const cfg = loadConfigFile(io, arena, argv);
    const map = if (cfg) |*c| c.map else [_]kujamba_config.NoteSound{.none} ** 128;

    const dev_id: ?[*:0]const u8 = if (device) |d|
        (arena.dupeZ(u8, d) catch fail(io, "out of memory", .{})).ptr
    else
        null;
    const dev = audio.Device.openPlayback(gpa, kujamba_out.sample_rate, play_period_frames, dev_id) catch |e| {
        var why_buf: [320]u8 = undefined;
        const why = if (device) |d|
            std.fmt.bufPrint(&why_buf, "cannot open output device '{s}' ({s}: {s})", .{
                d, @errorName(e), audio.Device.lastError(audio.last_open_error),
            }) catch "cannot open output device"
        else
            std.fmt.bufPrint(&why_buf, "no output device available ({s}: {s})", .{
                @errorName(e), audio.Device.lastError(audio.last_open_error),
            }) catch "no output device available";
        fail(io, "trigger: {s}", .{why});
    };
    defer dev.deinit(gpa);

    var engine = TriggerEngine.init(gpa, .{
        .map = &map,
        .sink = &sinkWritePlayback,
        .sink_ctx = dev,
    });

    var buf: [256]u8 = undefined;
    const ready = std.fmt.bufPrint(&buf, "trigger ready: {d} mapped notes; send `on <N>`, `off <N>`, `q`\n", .{engine.mappedCount()}) catch return;
    std.Io.File.stdout().writeStreamingAll(io, ready) catch {};

    if (script) |path| {
        const text = readTextFile(io, arena, path) catch
            fail(io, "trigger: cannot read script '{s}'", .{path});
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (!engine.handleLine(line)) break; // q / stop
        }
    } else {
        const stdin = std.Io.File.stdin();
        var rbuf: [1024]u8 = undefined;
        var rd = stdin.reader(io, &rbuf);
        const all = rd.interface.allocRemaining(gpa, .unlimited) catch
            fail(io, "trigger: cannot read stdin", .{});
        defer gpa.free(all);
        var it = std.mem.splitScalar(u8, all, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (!engine.handleLine(line)) break; // q / stop
        }
    }
    // let the last note-on finish sounding, then leave
    var grace: u64 = 0;
    while (grace < 2000 and dev.queuedPlayback() > 0 and !kujamba_out.stopRequested()) : (grace += 10) {
        _ = libc.usleep(10 * 1000);
    }
}

/// The note-on engine behind `kujamba trigger` (#21), device-free by
/// construction: notes map to renders, renders go to any f32 sink. This is
/// what the unit tests exercise with a recording sink.
const TriggerEngine = struct {
    const Sink = *const fn (ctx: *anyopaque, samples: []const f32) void;

    gpa: std.mem.Allocator,
    map: []const kujamba_config.NoteSound,
    sink: Sink,
    sink_ctx: *anyopaque,
    /// notes played since start (stats / tests)
    triggered: usize = 0,
    ignored: usize = 0,

    fn init(gpa: std.mem.Allocator, opts: struct {
        map: []const kujamba_config.NoteSound,
        sink: Sink,
        sink_ctx: *anyopaque,
    }) TriggerEngine {
        return .{ .gpa = gpa, .map = opts.map, .sink = opts.sink, .sink_ctx = opts.sink_ctx };
    }

    fn mappedCount(self: *const TriggerEngine) usize {
        var n: usize = 0;
        for (self.map) |binding| {
            if (binding != .none) n += 1;
        }
        return n;
    }

    /// One protocol line. Returns false when the engine should stop (`q`, or
    /// the session stop flag — the same Ctrl+C path `join` uses).
    fn handleLine(self: *TriggerEngine, line: []const u8) bool {
        if (kujamba_out.stopRequested()) return false;
        if (std.mem.eql(u8, line, "q") or std.mem.eql(u8, line, "quit")) return false;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const cmd = it.next() orelse return true;
        if (std.mem.eql(u8, cmd, "off")) return true; // one-shot sounds: note-off is a no-op
        if (!std.mem.eql(u8, cmd, "on")) {
            warnLine("trigger: unknown line '{s}' (want `on <N>`, `off <N>`, `q`)", .{line});
            return true;
        }
        const note_text = it.next() orelse {
            warnLine("trigger: `on` needs a note number", .{});
            return true;
        };
        const note = std.fmt.parseInt(u8, note_text, 10) catch {
            warnLine("trigger: bad note '{s}' (want 0..127)", .{note_text});
            return true;
        };
        if (note > 127) {
            warnLine("trigger: bad note '{s}' (want 0..127)", .{note_text});
            return true;
        }
        self.noteOn(note);
        return true;
    }

    /// Render the note's sound and queue it. Unmapped notes are ignored and
    /// counted; rendering happens right here, so latency is one device period.
    fn noteOn(self: *TriggerEngine, note: u8) void {
        switch (self.map[note]) {
            .none => {
                self.ignored += 1;
                warnLine("trigger: note {d} has no mapping", .{note});
            },
            .shuzi => |seed| {
                const wav = synth.renderShuziWavWith(self.gpa, seed, .{}) catch return;
                defer self.gpa.free(wav);
                self.queueWav(wav);
                self.triggered += 1;
            },
            .phrase => |phrase| {
                const pcm = kujamba_out.renderOfflineF32(self.gpa, phrase, .{
                    .mode = .once,
                    .pattern = .{ .play = 1, .rest = 0 },
                    .bars = 1,
                }) catch {
                    warnLine("trigger: phrase render failed for note {d}", .{note});
                    return;
                };
                defer self.gpa.free(pcm);
                self.sink(self.sink_ctx, pcm);
                self.triggered += 1;
            },
        }
    }

    /// Decode a rendered shuzi WAV's data chunk back to f32 and queue it.
    fn queueWav(self: *TriggerEngine, wav: []const u8) void {
        const data = wavDataChunk(wav) orelse {
            warnLine("trigger: rendered wav has no data chunk", .{});
            return;
        };
        const n = data.len / 2;
        const f32s = self.gpa.alloc(f32, n) catch return;
        defer self.gpa.free(f32s);
        for (f32s, 0..n) |*out, k| {
            const s16 = std.mem.readInt(i16, data[k * 2 ..][0..2], .little);
            out.* = @as(f32, @floatFromInt(s16)) / 32768.0;
        }
        self.sink(self.sink_ctx, f32s);
    }
};

/// A rendered shuzi WAV is canonical 44-byte-header PCM (synth.writeWavBytes),
/// so the data chunk starts at a fixed offset; the RIFF tags are verified anyway.
fn wavDataChunk(wav: []const u8) ?[]const u8 {
    if (wav.len < 46) return null;
    if (!std.mem.eql(u8, wav[0..4], "RIFF") or !std.mem.eql(u8, wav[8..12], "WAVE")) return null;
    const data_len = std.mem.readInt(u32, wav[40..44], .little);
    if (44 + @as(usize, data_len) > wav.len) return null;
    return wav[44 .. 44 + data_len];
}

// ---- trigger engine tests (#21) ---------------------------------------------

const testing = std.testing;

const RecordingSink = struct {
    total_samples: usize = 0,
    pushes: usize = 0,
    last_peak: f32 = 0,

    fn push(ctx: *anyopaque, samples: []const f32) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ctx));
        self.pushes += 1;
        self.total_samples += samples.len;
        for (samples) |v| self.last_peak = @max(self.last_peak, @abs(v));
    }

    fn sink() TriggerEngine.Sink {
        return &push;
    }
};

test "trigger engine: note-on renders the mapped phrase into the sink" {
    var map = [_]kujamba_config.NoteSound{.none} ** 128;
    map[60] = .{ .phrase = "po" };
    var sink_state = RecordingSink{};
    var engine = TriggerEngine.init(testing.allocator, .{
        .map = &map,
        .sink = RecordingSink.sink(),
        .sink_ctx = &sink_state,
    });
    try testing.expectEqual(@as(usize, 1), engine.mappedCount());
    _ = engine.handleLine("on 60");
    try testing.expectEqual(@as(usize, 1), engine.triggered);
    try testing.expectEqual(@as(usize, 1), sink_state.pushes);
    try testing.expect(sink_state.total_samples > 0);
    try testing.expect(sink_state.last_peak > 0.05); // real audio, not silence
    try testing.expect(engine.handleLine("q") == false);
}

test "trigger engine: shuzi seeds render real audio via the wav decode" {
    var map = [_]kujamba_config.NoteSound{.none} ** 128;
    map[61] = .{ .shuzi = 3 };
    var sink_state = RecordingSink{};
    var engine = TriggerEngine.init(testing.allocator, .{
        .map = &map,
        .sink = RecordingSink.sink(),
        .sink_ctx = &sink_state,
    });
    _ = engine.handleLine("on 61");
    try testing.expectEqual(@as(usize, 1), engine.triggered);
    // a shuzi is 1-3 rumble syllables: at least ~160 ms of 44.1 kHz audio
    try testing.expect(sink_state.total_samples > kujamba_out.sample_rate / 6);
    try testing.expect(sink_state.last_peak > 0.05);
}

test "trigger engine: unmapped notes and bad lines are tolerated" {
    var map = [_]kujamba_config.NoteSound{.none} ** 128;
    var sink_state = RecordingSink{};
    var engine = TriggerEngine.init(testing.allocator, .{
        .map = &map,
        .sink = RecordingSink.sink(),
        .sink_ctx = &sink_state,
    });
    _ = engine.handleLine("on 42"); // unmapped: counted, no push
    try testing.expectEqual(@as(usize, 1), engine.ignored);
    try testing.expectEqual(@as(usize, 0), engine.triggered);
    try testing.expectEqual(@as(usize, 0), sink_state.pushes);
    _ = engine.handleLine("off 42"); // note-off is a no-op
    _ = engine.handleLine("jump 42"); // unknown verb: warned, keep going
    _ = engine.handleLine("on"); // missing note
    _ = engine.handleLine("on abc"); // bad note
    _ = engine.handleLine("on 200"); // out of range
    try testing.expectEqual(@as(usize, 1), engine.ignored);
    try testing.expectEqual(@as(usize, 0), engine.triggered);
    // the engine is still alive
    try testing.expect(engine.handleLine("q") == false);
}

test "trigger engine: same seed renders the same bytes (deterministic)" {
    var map = [_]kujamba_config.NoteSound{.none} ** 128;
    map[61] = .{ .shuzi = 3 };
    var s1 = RecordingSink{};
    var s2 = RecordingSink{};
    var e1 = TriggerEngine.init(testing.allocator, .{ .map = &map, .sink = RecordingSink.sink(), .sink_ctx = &s1 });
    var e2 = TriggerEngine.init(testing.allocator, .{ .map = &map, .sink = RecordingSink.sink(), .sink_ctx = &s2 });
    _ = e1.handleLine("on 61");
    _ = e2.handleLine("on 61");
    try testing.expectEqual(s1.total_samples, s2.total_samples);
}

test "wavDataChunk: rejects garbage, accepts a rendered shuzi" {
    try testing.expect(wavDataChunk("nope") == null);
    try testing.expect(wavDataChunk("RIFFxxxxWAVEjunkjunk") == null);
    const wav = try synth.renderShuziWav(testing.allocator, 3);
    defer testing.allocator.free(wav);
    const data = wavDataChunk(wav) orelse return error.TestUnexpectedResult;
    try testing.expect(data.len >= kujamba_out.sample_rate / 8 * 2); // >= ~125ms of i16
}

fn warnLine(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    std.debug.print("{s}", .{msg});
}

/// Write one interval of pure silence as a decodable Ogg Vorbis stream — the
/// negative control: `check-ogg` must reject it at any sane min-rms.
fn cmdEncodeSilence(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) !void {
    var path: ?[]const u8 = null;
    var seconds: f64 = 5.0;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--seconds")) {
            i += 1;
            if (i >= argv.len) fail(io, "--seconds needs a value", .{});
            seconds = std.fmt.parseFloat(f64, argv[i]) catch fail(io, "bad --seconds", .{});
        } else {
            path = a;
        }
    }
    const p = path orelse fail(io, "encode-silence needs a file path", .{});

    const n: usize = @intFromFloat(seconds * @as(f64, @floatFromInt(synth.SAMPLE_RATE)));
    const samples = try gpa.alloc(f32, n);
    defer gpa.free(samples);
    @memset(samples, 0);

    const enc = vorbis.Encoder.create(gpa, @intCast(synth.SAMPLE_RATE), 0.0, 7) catch fail(io, "encoder init failed", .{});
    defer enc.destroy();
    var ogg: std.ArrayList(u8) = .empty;
    defer ogg.deinit(gpa);
    enc.writeHeaders(&ogg) catch fail(io, "encode failed", .{});

    const block_samples: usize = 960;
    var off: usize = 0;
    while (off < n) {
        const take = @min(block_samples, n - off);
        enc.encode(samples[off..][0..take], &ogg) catch fail(io, "encode failed", .{});
        off += take;
    }
    enc.flush(&ogg) catch fail(io, "encode failed", .{});

    const f = std.Io.Dir.cwd().createFile(io, p, .{}) catch fail(io, "cannot create '{s}'", .{p});
    defer f.close(io);
    f.writeStreamingAll(io, ogg.items) catch fail(io, "cannot write '{s}'", .{p});

    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "wrote silent interval: {s} bytes={d} seconds={d:.3}\n", .{ p, ogg.items.len, seconds }) catch return;
    std.Io.File.stdout().writeStreamingAll(io, line) catch {};
}

// ---- config / preset tests (#22) --------------------------------------------

/// Parse a config file for a test, failing with the diagnostic on error.
fn parseConfigForTest(text: []const u8) kujamba_config.Config {
    var diag = kujamba_config.Diag{ .file = "test.toml" };
    return kujamba_config.parse(text, &diag) catch |e| {
        std.debug.print("config parse failed: {s}:{d}: {s}\n", .{ diag.file, diag.line, diag.message() });
        @panic(@errorName(e));
    };
}

test "join settings keep the flag defaults when no config file applies" {
    const s = JoinSettings{};
    try std.testing.expectEqualStrings("127.0.0.1", s.host);
    try std.testing.expectEqual(@as(u16, 20531), s.port);
    try std.testing.expectEqualStrings("kujamba", s.user);
    try std.testing.expectEqualStrings("secret", s.pass);
    try std.testing.expectEqualStrings("kujamba karibu", s.phrase);
    try std.testing.expectEqual(@as(u64, 1), s.seed);
    try std.testing.expectEqual(kujamba_out.Pattern{ .play = 3, .rest = 1 }, s.pattern);
    try std.testing.expectEqual(kujamba_out.Mode.repeat, s.play_mode);
    try std.testing.expectEqual(synth.VoiceKnobs{}, s.knobs);
    try std.testing.expectEqual(@as(u64, 8), s.intervals);
    try std.testing.expectEqual(@as(i64, 120_000), s.duration_ms);
    try std.testing.expectEqualStrings("dump", s.out_dir);
    try std.testing.expectEqual(@as(?[]const u8, null), s.dump_dir);
    try std.testing.expectEqual(@as(?[]const u8, null), s.transcript);
}

test "config supplies join defaults; flags overwrite them (#22)" {
    const cfg = parseConfigForTest(
        \\host = "nas.example.com:20531"
        \\user = "dj"
        \\pass = "pw"
        \\phrase = "habari yako"
        \\pattern = "2+2"
        \\
        \\[voice]
        \\attack = 2
        \\noise = 0.5
        \\wobble = 3
        \\
    );

    var s = JoinSettings{};
    s.applyConfig(&cfg);
    try std.testing.expectEqualStrings("nas.example.com", s.host);
    try std.testing.expectEqual(@as(u16, 20531), s.port);
    try std.testing.expectEqualStrings("dj", s.user);
    try std.testing.expectEqualStrings("pw", s.pass);
    try std.testing.expectEqualStrings("habari yako", s.phrase);
    try std.testing.expectEqual(kujamba_out.Pattern{ .play = 2, .rest = 2 }, s.pattern);
    try std.testing.expectEqual(@as(f32, 2.0), s.knobs.attack);
    try std.testing.expectEqual(@as(f32, 0.5), s.knobs.noise);
    try std.testing.expectEqual(@as(f32, 3.0), s.knobs.wobble);

    // The flag loop assigns the very same fields through the very same
    // helpers, so "flags win over the config file" is literally this:
    const p = try kujamba_config.splitHostPort("127.0.0.1:9", &s.host);
    s.port = p.?;
    s.knobs = try synth.parseKnobs("noise=0");
    s.pattern = try kujamba_out.parsePattern("1");
    try std.testing.expectEqualStrings("127.0.0.1", s.host);
    try std.testing.expectEqual(@as(u16, 9), s.port);
    try std.testing.expectEqual(kujamba_out.Pattern{ .play = 1, .rest = 0 }, s.pattern);
    // --voice replaces the whole table, not just the axes it names
    try std.testing.expectEqual(@as(f32, 1.0), s.knobs.attack);
    try std.testing.expectEqual(@as(f32, 0.0), s.knobs.noise);
    try std.testing.expectEqual(@as(f32, 1.0), s.knobs.wobble);
}

test "config sets only the keys it names" {
    const cfg = parseConfigForTest("user = \"dj\"\n");

    var s = JoinSettings{};
    s.applyConfig(&cfg);
    try std.testing.expectEqualStrings("dj", s.user);
    // everything else keeps its built-in default
    try std.testing.expectEqualStrings("127.0.0.1", s.host);
    try std.testing.expectEqual(@as(u16, 20531), s.port);
    try std.testing.expectEqual(synth.VoiceKnobs{}, s.knobs);
}

test "a config host without a port keeps the default port" {
    const cfg = parseConfigForTest("host = \"nas.example.com\"\n");

    var s = JoinSettings{};
    s.applyConfig(&cfg);
    try std.testing.expectEqualStrings("nas.example.com", s.host);
    try std.testing.expectEqual(@as(u16, 20531), s.port);
}

test "a config host port survives a flag that names a bare host" {
    const cfg = parseConfigForTest("host = \"nas.example.com:20531\"\n");

    var s = JoinSettings{};
    s.applyConfig(&cfg);
    // --host without its own port replaces the host name, not the configured port
    const p = try kujamba_config.splitHostPort("127.0.0.1", &s.host);
    try std.testing.expectEqual(@as(?u16, null), p);
    try std.testing.expectEqualStrings("127.0.0.1", s.host);
    try std.testing.expectEqual(@as(u16, 20531), s.port);
}
