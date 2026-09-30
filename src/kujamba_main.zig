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
const vorbis = @import("ninjam/vorbis.zig");
const synth = @import("synth.zig");
const kujamba_out = @import("ninjam_out.zig");
const kujamba_config = @import("kujamba_config.zig");
const libc = @cImport({
    @cInclude("signal.h");
});

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
        \\    --out-dir DIR      directory for decoded peer WAVs (default dump)
        \\    --transcript FILE  transcript log (default <out-dir>/transcript.log)
        \\  kujamba render --phrase "..." --out FILE.wav|.ogg [--config FILE]
        \\                       [--play MODE] [--voice SPEC]
        \\                       [--pattern P] [--bars N] [--bar-ms MS] [--seed N]
        \\      render a phrase offline, shaped as join would play it. A rest bar
        \\      is exact silence and freezes the phrase cursor, matching the room.
        \\  kujamba check-ogg FILE [--min-rms R]   analyze an interval; exit 1 if rms < R
        \\  kujamba encode-silence FILE [--seconds S]   write a silent interval
        \\
        \\CONFIG (#22): a TOML-style file of defaults for join and render —
        \\  host (same syntax as --host, so "name:port" / "[::1]:port"), user,
        \\  pass, phrase, pattern, and a [voice] table with attack/noise/wobble
        \\  multipliers. Values apply defaults <- config <- flags, so a flag
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
    out_dir: []const u8 = "dump",
    dump_dir: ?[]const u8 = null,
    transcript: ?[]const u8 = null,

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

fn cmdJoin(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, argv: []const []const u8) !void {
    var s = JoinSettings{};

    // config file first, flags second: the loop below overwrites, so a flag
    // always wins over the file wherever it appears (#22)
    const cfg = loadConfigFile(io, arena, argv);
    if (cfg) |*c| s.applyConfig(c);

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
        } else {
            fail(io, "unknown option '{s}'", .{a});
        }
    }

    // The synth is the capture device: render the phrase once (deterministic),
    // then read it out interval by interval.
    const phrase_samples = kujamba_out.renderPhraseF32With(gpa, s.phrase, s.knobs) catch |e| fail(io, "phrase render failed: {s}", .{@errorName(e)});
    defer gpa.free(phrase_samples);
    var fill = kujamba_out.Fill{ .samples = phrase_samples, .mode = s.play_mode };
    // kujamba (#11): the plan owns the selection — the pattern (rest bars) plus
    // the mode and phrase the session should bind each bar. A live switch just
    // updates the adapter; the session picks it up at the next bar boundary.
    var adapter = kujamba_out.PlanAdapter{ .pattern = &s.pattern, .mode = s.play_mode, .samples = phrase_samples };

    var opts = session.Options{
        .host = s.host,
        .port = s.port,
        .user = s.user,
        .pass = s.pass,
        .srate = synth.SAMPLE_RATE,
        .channel_names = &.{"kujamba"},
        .source = .{ .kujamba = &fill },
        .id_seed = s.seed,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.selectForFn },
        .out_dir = s.out_dir,
        .payload_dump_dir = s.dump_dir,
        .stop_after_intervals = s.intervals,
        .duration_ms = s.duration_ms,
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
        "RESULT ok={} err=\"{s}\" seed={d} play={s} intervals_uploaded={d} intervals_broadcast={d} silence_markers={d} payload_dumps={d} upload_chunks={d} upload_bytes={d} intervals_downloaded={d} msgs_sent={d} msgs_recv={d}\n",
        .{
            ok,
            err_text,
            s.seed,
            @tagName(s.play_mode),
            stats.intervals_uploaded,
            stats.intervals_broadcast,
            stats.silence_markers,
            stats.payload_dumps,
            stats.upload_chunks,
            stats.upload_bytes,
            stats.intervals_downloaded,
            stats.msgs_sent,
            stats.msgs_recv,
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
