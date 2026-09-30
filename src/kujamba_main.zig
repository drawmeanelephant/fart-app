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

const std = @import("std");
const session = @import("ninjam/session.zig");
const vorbis = @import("ninjam/vorbis.zig");
const synth = @import("synth.zig");
const kujamba_out = @import("ninjam_out.zig");
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
        \\  kujamba render --phrase "..." --out FILE.wav|.ogg [--play MODE] [--voice SPEC]
        \\                       [--pattern P] [--bars N] [--bar-ms MS] [--seed N]
        \\      render a phrase offline, shaped as join would play it. A rest bar
        \\      is exact silence and freezes the phrase cursor, matching the room.
        \\  kujamba check-ogg FILE [--min-rms R]   analyze an interval; exit 1 if rms < R
        \\  kujamba encode-silence FILE [--seconds S]   write a silent interval
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
        return cmdRender(io, gpa, args[2..]);
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

fn cmdJoin(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, argv: []const []const u8) !void {
    var host: []const u8 = "127.0.0.1";
    var port: u16 = 20531;
    var user: []const u8 = "kujamba";
    var pass: []const u8 = "secret";
    var phrase: []const u8 = "kujamba karibu";
    var seed: u64 = 1;
    var pattern_str: []const u8 = "3+1";
    var play_mode: kujamba_out.Mode = .repeat;
    var knobs: synth.VoiceKnobs = .{};
    var intervals: u64 = 8;
    var duration_ms: i64 = 120_000;
    var out_dir: []const u8 = "dump";
    var dump_dir: ?[]const u8 = null;
    var transcript: ?[]const u8 = null;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        const next: ?[]const u8 = if (i + 1 < argv.len) argv[i + 1] else null;
        if (std.mem.eql(u8, a, "--host")) {
            const v = next orelse fail(io, "--host needs a value", .{});
            if (v.len > 0 and v[0] == '[') {
                // bracketed IPv6: [::1]:20531 or [::1]
                const close = std.mem.indexOfScalar(u8, v, ']') orelse
                    fail(io, "bad --host: missing ']'", .{});
                host = v[1..close];
                if (close + 1 < v.len) {
                    if (v[close + 1] != ':') fail(io, "bad --host after ']'", .{});
                    port = std.fmt.parseInt(u16, v[close + 2 ..], 10) catch fail(io, "bad port in --host", .{});
                }
            } else if (std.mem.indexOfScalar(u8, v, ':')) |colon| {
                if (std.mem.indexOfScalarPos(u8, v, colon + 1, ':') != null)
                    fail(io, "IPv6 host needs brackets: --host [::1]:port", .{});
                host = v[0..colon];
                port = std.fmt.parseInt(u16, v[colon + 1 ..], 10) catch fail(io, "bad port in --host", .{});
            } else {
                host = v;
            }
            i += 1;
        } else if (std.mem.eql(u8, a, "--play")) {
            play_mode = kujamba_out.parseMode(next orelse fail(io, "--play needs a value", .{})) catch
                fail(io, "bad --play '{s}' (want repeat, loop or once)", .{next.?});
            i += 1;
        } else if (std.mem.eql(u8, a, "--voice")) {
            knobs = synth.parseKnobs(next orelse fail(io, "--voice needs a value", .{})) catch |e|
                fail(io, "bad --voice '{s}': {s} (want attack=N,noise=N,wobble=N)", .{ next.?, @errorName(e) });
            i += 1;
        } else if (std.mem.eql(u8, a, "--user")) {
            user = next orelse fail(io, "--user needs a value", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--pass")) {
            pass = next orelse fail(io, "--pass needs a value", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--phrase")) {
            phrase = next orelse fail(io, "--phrase needs a value", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--seed")) {
            seed = std.fmt.parseInt(u64, next orelse fail(io, "--seed needs a value", .{}), 10) catch fail(io, "bad --seed", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--pattern")) {
            pattern_str = next orelse fail(io, "--pattern needs a value", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--intervals")) {
            intervals = std.fmt.parseInt(u64, next orelse fail(io, "--intervals needs a value", .{}), 10) catch fail(io, "bad --intervals", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--duration")) {
            const secs = std.fmt.parseFloat(f64, next orelse fail(io, "--duration needs a value", .{})) catch fail(io, "bad --duration", .{});
            // NaN/negative would panic in @intFromFloat
            if (!(secs > 0.0) or secs > 86400.0)
                fail(io, "--duration must be in (0, 86400] seconds", .{});
            duration_ms = @intFromFloat(secs * 1000.0);
            i += 1;
        } else if (std.mem.eql(u8, a, "--out-dir")) {
            out_dir = next orelse fail(io, "--out-dir needs a value", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--dump-dir")) {
            dump_dir = next orelse fail(io, "--dump-dir needs a value", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--transcript")) {
            transcript = next orelse fail(io, "--transcript needs a value", .{});
            i += 1;
        } else {
            fail(io, "unknown option '{s}'", .{a});
        }
    }

    const pattern = kujamba_out.parsePattern(pattern_str) catch fail(io, "bad --pattern '{s}' (want N or N+M)", .{pattern_str});
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern };

    // The synth is the capture device: render the phrase once (deterministic),
    // then read it out interval by interval.
    const phrase_samples = kujamba_out.renderPhraseF32With(gpa, phrase, knobs) catch |e| fail(io, "phrase render failed: {s}", .{@errorName(e)});
    defer gpa.free(phrase_samples);
    var fill = kujamba_out.Fill{ .samples = phrase_samples, .mode = play_mode };

    var opts = session.Options{
        .host = host,
        .port = port,
        .user = user,
        .pass = pass,
        .srate = synth.SAMPLE_RATE,
        .channel_names = &.{"kujamba"},
        .source = .{ .kujamba = &fill },
        .id_seed = seed,
        .plan = .{ .ctx = @ptrCast(&adapter), .broadcastFor = kujamba_out.PlanAdapter.broadcastForFn },
        .out_dir = out_dir,
        .payload_dump_dir = dump_dir,
        .stop_after_intervals = intervals,
        .duration_ms = duration_ms,
        .quality = 0.0,
    };
    if (transcript) |t| {
        opts.transcript_path = t;
    } else {
        opts.transcript_path = try std.fmt.allocPrint(arena, "{s}/transcript.log", .{out_dir});
    }

    var s = session.Session.init(gpa, io, opts) catch |e| fail(io, "init failed: {s}", .{@errorName(e)});
    defer s.deinit();

    const stats = s.run() catch s.stats;

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
            seed,
            @tagName(play_mode),
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
fn cmdRender(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) !void {
    var phrase: []const u8 = "kujamba karibu";
    var out_path: ?[]const u8 = null;
    var pattern_str: []const u8 = "1";
    var play_mode = kujamba_out.Mode.repeat;
    var bars: u32 = 1;
    var bar_ms: u64 = 0;
    var seed: u64 = 0;
    var knobs: synth.VoiceKnobs = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        const next = if (i + 1 < argv.len) argv[i + 1] else null;
        if (std.mem.eql(u8, a, "--phrase")) {
            phrase = next orelse fail(io, "--phrase needs a value", .{});
            i += 1;
        } else if (std.mem.eql(u8, a, "--play")) {
            play_mode = kujamba_out.parseMode(next orelse fail(io, "--play needs a value", .{})) catch
                fail(io, "bad --play '{s}' (want repeat, loop or once)", .{next.?});
            i += 1;
        } else if (std.mem.eql(u8, a, "--voice")) {
            knobs = synth.parseKnobs(next orelse fail(io, "--voice needs a value", .{})) catch |e|
                fail(io, "bad --voice '{s}': {s} (want attack=N,noise=N,wobble=N)", .{ next.?, @errorName(e) });
            i += 1;
        } else if (std.mem.eql(u8, a, "--pattern")) {
            pattern_str = next orelse fail(io, "--pattern needs a value", .{});
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

    const pattern = kujamba_out.parsePattern(pattern_str) catch
        fail(io, "bad --pattern '{s}' (want N or N+M)", .{pattern_str});
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
        p,                       bars,                   bar_ms, pattern_str, @tagName(play_mode), bytes.len, seconds,
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
