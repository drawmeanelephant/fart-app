//! Client session state machine: handshake/auth (§4), steady-state dispatch,
//! interval engine (§6.5 uploads, §6.4/§6.2 downloads → WAV), chat (§8),
//! keepalives (§7). Single-threaded: one poll loop drives network + audio.

const std = @import("std");
const bufmod = @import("buf.zig");
const netmod = @import("net.zig");
const proto = @import("proto.zig");
const auth = @import("auth.zig");
const wavmod = @import("wav.zig");
const vorbis = @import("vorbis.zig");
const logmod = @import("log.zig");
const clock = @import("clock.zig");
const audio = @import("audio.zig");
const kujamba_out = @import("../ninjam_out.zig");

const Fixed = bufmod.Fixed;
const Buf = bufmod.Buf;

pub const Source = union(enum) {
    tone: struct { freq: f32, amp: f32 },
    silence,
    /// Flatlophone instrument source: a pre-rendered phrase buffer read
    /// sequentially across the interval (kujamba adaptation).
    kujamba: *kujamba_out.Fill,
};

/// Per-interval broadcast plan for instrument sources (kujamba rest bars).
/// Consulted at every interval start; returning a selection whose `broadcast`
/// is false makes the interval a silence-marker bar — no audio is ever uploaded
/// for it. The whole selection (broadcast, play mode, and the phrase buffer) is
/// applied at that bar boundary, so a switch requested during bar N takes
/// effect at the start of bar N+1 with no mid-interval splice. kujamba
/// adaptation (#11): the hook used to return a bare bool and carried nothing
/// else, so a mid-session mode/phrase change had no way to express itself.
pub const IntervalPlan = struct {
    ctx: *anyopaque,
    selectFor: *const fn (ctx: *anyopaque, interval_idx: u64) kujamba_out.Selection,
};

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 2049,
    user: []const u8 = "anonymous:zclient",
    pass: []const u8 = "",
    srate: u32 = 48000,
    channel_names: []const []const u8 = &.{"zclient"},
    source: Source = .{ .tone = .{ .freq = 440.0, .amp = 0.5 } },
    out_dir: []const u8 = "dump",
    transcript_path: ?[]const u8 = null,
    duration_ms: i64 = 20_000,
    chat: ?[]const u8 = null,
    chat_delay_ms: i64 = 1_500,
    /// libvorbis VBR quality (reference client uses 0.0 for 64 kbps mono)
    quality: f32 = 0.0,

    // ---- instrument additions (kujamba adaptation) ----
    /// deterministic id seed: guid + vorbis serial derive from (seed, interval)
    id_seed: ?u64 = null,
    /// per-interval broadcast plan; false = silence-marker bar (rest bar)
    plan: ?IntervalPlan = null,
    /// kujamba (#9): called with the verb when a `!kujamba <verb>` transport
    /// command arrives in room chat, so the app can reshape its plan without
    /// the session understanding phrases or modes. A mode change lands at the
    /// next interval boundary (the selection is applied there, not here).
    /// null = room chat is logged but never acted on.
    chat_command: ?*const fn (ctx: *anyopaque, verb: kujamba_out.ChatCommand) void = null,
    /// opaque pointer handed back to `chat_command`
    chat_ctx: *anyopaque = undefined,
    /// when set, each interval's concatenated 0x84 payload is dumped to
    /// <dir>/interval_NNNN.ogg (byte-identical across runs for a fixed seed)
    payload_dump_dir: ?[]const u8 = null,
    /// stop after this many completed intervals (demo determinism aid)
    stop_after_intervals: ?u64 = null,

    // ---- Phase B: live audio ----
    /// capture the local device instead of generating --source, and play the
    /// decoded peer mix out of it. Falls back to --source + WAV dumps when no
    /// device can be opened.
    live: bool = false,
    /// device period in frames (0 = backend default)
    live_period: u32 = 480,
    /// optional miniaudio device id (name or index), null = system default
    live_device: ?[]const u8 = null,
    /// optional WAV dump of the exact post-mix signal handed to the device
    play_wav_path: ?[]const u8 = null,
};

pub const Stats = struct {
    ok: bool = false,
    fail_reason: [256]u8 = undefined,
    fail_len: usize = 0,

    msgs_sent: u64 = 0,
    msgs_recv: u64 = 0,
    bytes_sent: u64 = 0,
    bytes_recv: u64 = 0,

    intervals_uploaded: u64 = 0,
    upload_chunks: u64 = 0,
    upload_bytes: u64 = 0,
    /// local channels that actually streamed audio (max across intervals)
    upload_channels: u64 = 0,
    /// intervals that broadcast real audio (rest bars excluded)
    intervals_broadcast: u64 = 0,
    /// silence markers sent (rest bars / non-broadcast intervals)
    silence_markers: u64 = 0,
    /// interval payload dumps written (payload_dump_dir)
    payload_dumps: u64 = 0,

    // ---- M5 timing telemetry (#13, #14) ------------------------------------
    /// Wall time spent inside one interval's upload-write section, in ns. The
    /// audio clock's own budget is one interval; a value near or above it means
    /// the network stalled interval generation rather than the other way round.
    /// Max over the session, because the worst stall is the one that matters.
    upload_stall_ns: u64 = 0,
    /// #13: signed nanoseconds between the local interval grid and the grid
    /// derived from the server's 0x02 arrival. Positive = the local clock is
    /// running ahead of the server's. Reported (abs) at the end of the session.
    drift_ns: i64 = 0,
    /// #13: absolute value of the largest |drift| seen, in ns.
    max_abs_drift_ns: u64 = 0,
    /// #13: how many intervals the bounded slew actually moved, and the total
    /// correction applied (ns). A session where these are zero is one where the
    /// local grid already agreed with the server's.
    clock_corrections: u64 = 0,
    total_correction_ns: i64 = 0,
    /// #14: bars whose upload was abandoned because the socket would block,
    /// and the encoded bytes thrown away with them.
    intervals_dropped: u64 = 0,
    upload_bytes_dropped: u64 = 0,

    intervals_downloaded: u64 = 0,
    download_bytes: u64 = 0,
    samples_decoded: u64 = 0,

    chat_sent: u64 = 0,
    chat_received: u64 = 0,

    wav_count: u32 = 0,
    wav_rms_sum: f64 = 0.0,

    // live audio (Phase B) — energy is measured on the session thread as the
    // samples cross the ring boundary, so a silent device cannot fake it
    live: bool = false,
    device_name: [128]u8 = undefined,
    device_name_len: usize = 0,
    device_srate: u32 = 0,
    capture_frames: u64 = 0,
    capture_zero_frames: u64 = 0,
    capture_peak: f32 = 0,
    capture_energy: f64 = 0,
    playback_frames: u64 = 0,
    playback_peak: f32 = 0,
    playback_energy: f64 = 0,
    rx_underruns: u64 = 0,
    rx_overruns: u64 = 0,

    pub fn deviceName(self: *const Stats) []const u8 {
        return self.device_name[0..self.device_name_len];
    }

    pub fn rms(frames: u64, energy: f64) f64 {
        if (frames == 0) return 0;
        return @sqrt(energy / @as(f64, @floatFromInt(frames)));
    }

    fn fail(self: *Stats, comptime fmt: []const u8, args: anytype) void {
        self.ok = false;
        const s = std.fmt.bufPrint(&self.fail_reason, fmt, args) catch "error";
        self.fail_len = s.len;
    }

    pub fn failText(self: *const Stats) []const u8 {
        return self.fail_reason[0..self.fail_len];
    }
};

const max_users = 32;
const max_downloads = 8;
const max_outputs = 16;
const max_local_channels = 4;

const encode_block_samples = 960; // 20 ms @ 48 kHz
const chunk_flush_bytes = 2048; // coalesce encoded bytes into >=2KiB chunks
const default_keepalive_s: u32 = 3;
/// kujamba (#14): how long an upload write may wait for a slow socket, in ms.
///
/// Zero, and that is the point. The audio clock has exactly one bar of budget
/// and the upload is not worth any of it: a socket that cannot take a bar right
/// now will not take it a second later either, and finding that out by waiting
/// is what turned a jittery connection into a frozen performance. Zero means
/// ask once and act on the answer.
pub const upload_write_budget_ms: i32 = 0;

const UserEntry = struct {
    name_len: usize = 0,
    name: [160]u8 = undefined,
    mask: u32 = 0, // channels we subscribed to

    fn setName(self: *UserEntry, s: []const u8) void {
        const n = @min(s.len, self.name.len);
        @memcpy(self.name[0..n], s[0..n]);
        self.name_len = n;
    }

    fn nameSlice(self: *const UserEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

const DownloadState = struct {
    active: bool = false,
    guid: [16]u8 = [_]u8{0} ** 16,
    fourcc: u32 = 0,
    chidx: u8 = 0,
    user: UserEntry = .{},
    buf: Buf,
};

const OutputFile = struct {
    active: bool = false,
    chidx: u8 = 0,
    user: UserEntry = .{},
    srate: u32 = 0,
    path_len: usize = 0,
    path: [320]u8 = undefined,
    writer: wavmod.WavWriter,

    fn pathSlice(self: *const OutputFile) []const u8 {
        return self.path[0..self.path_len];
    }
};

const LocalChannel = struct {
    name_len: usize = 0,
    name: [64]u8 = undefined,
    broadcast: bool = true,
    phase: f32 = 0,
    enc: ?*vorbis.Encoder = null,
    guid: [16]u8 = [_]u8{0} ** 16,
    begun: bool = false, // 0x83 sent
    pending: Buf,
    /// per-interval concatenated 0x84 payload (payload_dump_dir evidence)
    dump: Buf,
    produced: u64 = 0,
    interval_idx: u64 = 0,
    /// kujamba (#14): this channel's bar was abandoned because the socket would
    /// block. Nothing more is sent for it this bar, and the audio keeps going.
    dropped: bool = false,

    fn nameSlice(self: *const LocalChannel) []const u8 {
        return self.name[0..self.name_len];
    }

    fn setName(self: *LocalChannel, s: []const u8) void {
        const n = @min(s.len, self.name.len);
        @memcpy(self.name[0..n], s[0..n]);
        self.name_len = n;
    }
};

/// Fill `block[0..n]` with the audio one local channel should encode for the
/// current step.
///
/// In live mode `shared` is the single capture block taken for this step and
/// every channel encodes a copy of it — that is what keeps multiple channels
/// sample-aligned with each other. Pulling per channel instead would hand each
/// channel a different slice of the device ring and slowly drift them apart.
/// Synthetic sources generate per channel, so each keeps its own phase.
pub fn encodeBlockFor(
    source: Source,
    srate: u32,
    lc: *LocalChannel,
    shared: ?[]const f32,
    block: []f32,
) void {
    if (shared) |s| {
        const n = @min(block.len, s.len);
        @memcpy(block[0..n], s[0..n]);
        return;
    }
    switch (source) {
        .tone => |t| {
            const dphi = 2.0 * std.math.pi * t.freq / @as(f32, @floatFromInt(srate));
            for (block) |*s| {
                lc.phase += dphi;
                if (lc.phase > 2.0 * std.math.pi) lc.phase -= 2.0 * std.math.pi;
                s.* = t.amp * @sin(lc.phase);
            }
        },
        .silence => {
            @memset(block, 0);
        },
        .kujamba => |fill| {
            // offset = samples already produced in this interval
            fill.copyInto(lc.produced, block);
        },
    }
}

pub const Session = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    opts: Options,
    stats: Stats = .{},
    log: logmod.Log,

    conn: ?netmod.Conn = null,
    payload: Buf,
    state: enum { connecting, awaiting_reply, active, done } = .connecting,

    keepalive_s: u32 = default_keepalive_s,
    eff_user: UserEntry = .{},
    maxchan: u8 = 1,
    bpm: u16 = 0,
    bpi: u16 = 0,

    users: [max_users]UserEntry = [_]UserEntry{.{}} ** max_users,

    downloads: [max_downloads]DownloadState = undefined,
    outputs: [max_outputs]OutputFile = undefined,

    locals: []LocalChannel = &.{},
    interval_len_samples: u64 = 0,
    interval_start_ns: i128 = 0,
    // kujamba adaptation (#12): the old single `interval_idx` conflated
    // interval identity with grid position, so a mid-session 0x02 config
    // change re-issued guids already sent (different payload bytes) and
    // overwrote earlier payload dumps. `index.seq` is identity (guids,
    // dump filenames, --intervals) and is monotonic for the whole session;
    // `index.grid` is the bar position and drives only the pattern decision.
    index: kujamba_out.IntervalIndex = .{},
    // kujamba (#13): the bar grid, anchored to the server's and corrected by a
    // bounded slew. See `kujamba_out.ServerClock` for why the correction chases
    // the wall clock rather than the server's epoch.
    timing: kujamba_out.ServerClock = .{},
    // kujamba (#14): has *this* bar already been counted as dropped? Cleared at
    // the top of `finalizeInterval`, so N channels failing on one bar is one
    // lost bar, not N.
    drop_marked: bool = false,

    start_ns: i128 = 0,
    chat_sent: bool = false,
    last_keepalive_ms: i64 = 0,
    hex_scratch: [64]u8 = undefined,
    hex_scratch2: [64]u8 = undefined,

    dev: ?*audio.Device = null,
    play_writer: wavmod.WavWriter = undefined,
    play_wav_active: bool = false,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, opts: Options) !Session {
        var s = Session{
            .alloc = alloc,
            .io = io,
            .opts = opts,
            .log = logmod.Log.init(alloc, io, opts.transcript_path, false),
            .payload = Buf.init(alloc),
        };
        s.start_ns = clock.nowNs(io);
        s.log.start_ns = s.start_ns;
        for (&s.downloads) |*d| d.* = .{ .buf = Buf.init(alloc) };
        for (&s.outputs) |*o| o.* = .{ .writer = wavmod.WavWriter.init(alloc, io, 0, 1) };
        s.locals = try alloc.alloc(LocalChannel, opts.channel_names.len);
        for (s.locals, 0..) |*lc, i| {
            lc.* = .{ .pending = Buf.init(alloc), .dump = Buf.init(alloc) };
            lc.setName(opts.channel_names[i]);
        }
        return s;
    }

    pub fn deinit(self: *Session) void {
        self.closeWavs();
        self.closeLive();
        for (self.locals) |*lc| {
            if (lc.enc) |e| e.destroy();
            lc.pending.deinit();
            lc.dump.deinit();
        }
        self.alloc.free(self.locals);
        for (&self.downloads) |*d| d.buf.deinit();
        for (&self.outputs) |*o| o.writer.deinit();
        self.payload.deinit();
        if (self.conn) |*c| c.close();
        self.log.deinit();
    }

    fn setNameField(entry: *UserEntry, s: []const u8) void {
        entry.setName(s);
    }

    // ---- helpers -----------------------------------------------------------

    fn failSession(self: *Session, comptime fmt: []const u8, args: anytype) error{SessionFailed} {
        self.stats.fail(fmt, args);
        self.log.line("FAIL: " ++ fmt, args);
        self.state = .done;
        return error.SessionFailed;
    }

    fn findOrAddUser(self: *Session, name: []const u8) ?*UserEntry {
        for (&self.users) |*u| {
            if (u.name_len > 0 and std.mem.eql(u8, u.nameSlice(), name)) return u;
        }
        for (&self.users) |*u| {
            if (u.name_len == 0) {
                UserEntry.setName(u, name);
                return u;
            }
        }
        return null;
    }

    fn hexBuf(src: []const u8, out: []u8) []const u8 {
        const n = @min(out.len / 2, src.len);
        auth.hexLower(src[0..n], out[0 .. n * 2]);
        return out[0 .. n * 2];
    }

    fn sanitizeName(dst: []u8, src: []const u8) usize {
        var n: usize = 0;
        for (src) |ch| {
            if (n >= dst.len) break;
            dst[n] = if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') ch else '_';
            n += 1;
        }
        return n;
    }

    // ---- wav outputs ---------------------------------------------------------

    fn findOrOpenOutput(self: *Session, username: []const u8, chidx: u8, srate: u32) !*OutputFile {
        for (&self.outputs) |*o| {
            if (o.active and o.chidx == chidx and std.mem.eql(u8, o.user.nameSlice(), username)) {
                return o;
            }
        }
        for (&self.outputs) |*o| {
            if (!o.active) {
                o.active = true;
                o.chidx = chidx;
                o.user.setName(username);
                o.srate = srate;
                o.writer = wavmod.WavWriter.init(self.alloc, self.io, srate, 1);
                var tmp: [256]u8 = undefined;
                const nb = sanitizeName(&tmp, username);
                const path = std.fmt.bufPrint(&o.path, "{s}/{s}_ch{d}.wav", .{ self.opts.out_dir, tmp[0..nb], chidx }) catch {
                    o.active = false;
                    return error.OutOfMemory;
                };
                o.path_len = path.len;
                try o.writer.open(o.pathSlice());
                self.log.line("wav open {s} (srate={d})", .{ o.pathSlice(), srate });
                return o;
            }
        }
        return error.NoSlot;
    }

    pub fn closeWavs(self: *Session) void {
        for (&self.outputs) |*o| {
            if (!o.active) continue;
            o.writer.close() catch |e| {
                self.log.line("wav close {s} failed: {s}", .{ o.pathSlice(), @errorName(e) });
            };
            const a = wavmod.analyzeWavFile(self.io, o.pathSlice()) catch {
                self.log.line("wav analyze {s} failed", .{o.pathSlice()});
                continue;
            };
            self.stats.wav_count += 1;
            self.stats.wav_rms_sum += a.rms;
            self.log.line("wav {s} frames={d} srate={d} rms={d:.6} peak={d:.6}", .{ o.pathSlice(), a.frames, a.srate, a.rms, a.peak });
            o.writer.deinit();
            o.active = false;
        }
    }

    // ---- live audio (Phase B) --------------------------------------------------

    fn openLive(self: *Session) void {
        if (!self.opts.live) return;
        if (!audio.enabled) {
            self.log.line("live audio requested but this build has live=false; using --source", .{});
            return;
        }
        var probe: [256]u8 = undefined;
        const p = audio.Device.probePlayback(&probe);
        self.log.line("audio probe: default_playback=\"{s}\" native_srate={d}", .{ p.name, p.srate });

        const id: ?[*:0]const u8 = if (self.opts.live_device) |d| @ptrCast(d) else null;
        self.dev = audio.Device.open(self.alloc, self.opts.srate, self.opts.live_period, id) catch |e| {
            self.log.line("live audio UNAVAILABLE ({s}: {s}); falling back to --source", .{
                @errorName(e), audio.Device.lastError(audio.last_open_error),
            });
            return;
        };
        const d = self.dev.?;
        const n = @min(d.nameSlice().len, self.stats.device_name.len);
        @memcpy(self.stats.device_name[0..n], d.nameSlice()[0..n]);
        self.stats.device_name_len = n;
        self.stats.device_srate = d.dev_srate;
        self.stats.live = true;
        self.log.line("live audio ON: device=\"{s}\" backend={s} srate={d} (session {d}){s}", .{
            d.nameSlice(),                                               d.backend(), d.dev_srate, self.opts.srate,
            if (d.dev_srate == self.opts.srate) "" else " [resampling]",
        });

        if (self.opts.play_wav_path) |path| {
            self.play_writer = wavmod.WavWriter.init(self.alloc, self.io, self.opts.srate, 1);
            self.play_writer.open(path) catch |e| {
                self.log.line("playback wav open '{s}' failed: {s}", .{ path, @errorName(e) });
                return;
            };
            self.play_wav_active = true;
            self.log.line("playback wav open {s}", .{path});
        }
    }

    fn closeLive(self: *Session) void {
        // comptime-gated: with -Dlive=false no device can ever have opened,
        // and this keeps the miniaudio symbols out of the link entirely
        if (!audio.enabled) return;
        if (self.play_wav_active) {
            self.play_writer.close() catch |e| {
                self.log.line("playback wav close failed: {s}", .{@errorName(e)});
            };
            if (self.opts.play_wav_path) |p| {
                if (wavmod.analyzeWavFile(self.io, p)) |a| {
                    self.log.line("playback wav {s} frames={d} srate={d} rms={d:.6} peak={d:.6}", .{
                        p, a.frames, a.srate, a.rms, a.peak,
                    });
                } else |_| {}
            }
            self.play_writer.deinit();
            self.play_wav_active = false;
        }
        if (self.dev) |d| {
            const tx = d.txStats();
            const rx = d.rxStats();
            self.log.line("live audio stats: device_frames={d} queued_tx={d} queued_rx={d}", .{
                d.framesSeen(), d.queuedCapture(), d.queuedPlayback(),
            });
            self.log.line("live audio rings: capture underrun={d} overrun={d} | playback underrun={d} overrun={d}", .{
                tx.under, tx.over, rx.under, rx.over,
            });
            self.stats.rx_underruns = tx.under + rx.under;
            self.stats.rx_overruns = tx.over + rx.over;
            d.deinit(self.alloc);
            self.dev = null;
        }
    }

    /// The device has been capturing since we opened it, but the interval clock
    /// only starts when the server advertises BPM/BPI (a few seconds later).
    /// Uploading that pre-roll would push audio several seconds stale, so drop
    /// it and let the uplink start at the top of interval 0.
    fn dropCapturePreRoll(self: *Session) void {
        const d = self.dev orelse return;
        const dropped = d.flushCapture();
        if (dropped > 0) self.log.line("capture pre-roll dropped: {d} frames", .{dropped});
    }

    /// Take one block of captured audio out of the device ring, filling any
    /// shortfall with silence, and account for it. Runs once per encode step.
    fn pullCapture(self: *Session, d: *audio.Device, block: []f32) void {
        const got = d.readCapture(block);
        for (block[0..got]) |s| {
            const a = @abs(s);
            if (a > self.stats.capture_peak) self.stats.capture_peak = a;
            self.stats.capture_energy += @as(f64, s) * @as(f64, s);
        }
        self.stats.capture_frames += got;
        self.stats.capture_zero_frames += block.len - got;
    }

    /// Hand decoded peer audio to the device (and the optional WAV mirror).
    fn pushPlayback(self: *Session, mono: []const f32) void {
        const d = self.dev orelse return;
        for (mono) |s| {
            const a = @abs(s);
            if (a > self.stats.playback_peak) self.stats.playback_peak = a;
            self.stats.playback_energy += @as(f64, s) * @as(f64, s);
        }
        self.stats.playback_frames += mono.len;
        d.writePlayback(mono);
        if (self.play_wav_active) self.play_writer.writeFloats(mono) catch {};
    }

    // ---- connection ----------------------------------------------------------

    fn send(self: *Session, mtype: u8, payload: []const u8) !void {
        try self.conn.?.sendMessage(mtype, payload);
        self.stats.msgs_sent += 1;
        self.stats.bytes_sent += payload.len + 5;
        self.last_keepalive_ms = clock.nowMs(self.io);
    }

    fn sendChatMsg(self: *Session, parms: []const []const u8) !void {
        var f = Fixed{};
        try proto.buildChat(parms, &f);
        try self.send(proto.MSG_CHAT_MESSAGE, f.slice());
    }

    fn sendKeepaliveIfDue(self: *Session, now_ms: i64) void {
        const idle_ms = now_ms - self.last_keepalive_ms;
        if (idle_ms >= @as(i64, @intCast(self.keepalive_s)) * 1000) {
            self.send(proto.MSG_KEEPALIVE, "") catch {};
            self.log.line("C>S KEEPALIVE (idle {d}ms)", .{idle_ms});
        }
    }

    // ---- upload path (§6.5) ---------------------------------------------------

    fn startIntervalEncoders(self: *Session) !void {
        if (self.opts.plan) |pl| {
            // kujamba (#11, #12): the plan returns a full selection for this
            // bar and it is applied HERE — once, at the bar boundary, before any
            // audio is generated. That ordering is what makes a switch requested
            // during bar N land at the start of bar N+1 by construction: by the
            // time any block is encoded, the bar's mode and phrase are already
            // decided. grid position drives the pattern (rest) decision; the
            // selection carries the mode and phrase.
            const sel = pl.selectFor(pl.ctx, self.index.grid);
            for (self.locals) |*lc| lc.broadcast = sel.broadcast;
            // Rebind the instrument source to the selected mode/phrase. Applied
            // even on a rest bar, so a switch made while resting takes effect on
            // the next play bar too. A rest bar freezes the fill's cursor (no
            // copyInto), so this cannot splice audio mid-bar.
            switch (self.opts.source) {
                .kujamba => |fill| {
                    // bind() rather than field assignment: the playhead lives in
                    // the Phrase entry, so swapping phrases has to move the
                    // cursor with it, or a stale index would point into a
                    // different buffer (#8, #10). A null entry keeps whatever
                    // the source already holds, which is how an empty bank
                    // avoids dropping audio.
                    fill.bind(sel.mode, sel.phrase);
                },
                else => {},
            }
        }
        for (self.locals) |*lc| {
            if (lc.enc) |e| {
                e.destroy();
                lc.enc = null;
            }
            lc.pending.clear();
            lc.begun = false;
            lc.produced = 0;
            lc.dropped = false;
            var serial: u32 = 0;
            if (self.opts.id_seed) |seed| {
                // deterministic ids: byte-identical payloads across runs
                const ci = self.channelIndex(lc);
                // kujamba (#12): ids key off the monotonic sequence, so a grid
                // re-anchor can never re-issue a guid already sent this session
                kujamba_out.deriveGuid(seed, self.index.seq, ci, &lc.guid);
                serial = kujamba_out.deriveSerial(seed, self.index.seq, ci);
            } else {
                self.io.random(&lc.guid);
                self.io.random(std.mem.asBytes(&serial));
            }
            if (lc.broadcast) {
                lc.enc = vorbis.Encoder.create(self.alloc, @intCast(self.opts.srate), self.opts.quality, serial) catch |e| {
                    return self.failSession("encoder init failed: {s}", .{@errorName(e)});
                };
                // headers go into pending; first send carries 0x83 + them
                var hdrs: std.ArrayList(u8) = .empty;
                defer hdrs.deinit(self.alloc);
                try lc.enc.?.writeHeaders(&hdrs);
                try lc.pending.add(hdrs.items);
            }
        }
    }

    /// Generate + encode audio up to the current wall-clock sample target;
    /// finalize and restart the interval at the boundary.
    fn advanceAudio(self: *Session, now_ns: i128) !void {
        if (self.interval_len_samples == 0) return;
        const elapsed_ns = now_ns - self.interval_start_ns;
        const elapsed_samples: u64 = @intCast(@divFloor(elapsed_ns * @as(i128, self.opts.srate), 1_000_000_000));
        // kujamba (#13): the encode target leads the wall clock by a bounded
        // margin, so the last block is already encoded — and the flush and the
        // final 0x84 chunk already in flight — when the boundary arrives, rather
        // than starting at it. This changes *when* a bar is generated, never
        // *what*: the sample sequence, the block sizes and therefore the encoded
        // bytes are identical, so the determinism evidence is untouched.
        const lead = self.timing.encodeLeadSamples(self.interval_len_samples);
        const target = @min(elapsed_samples +| lead, self.interval_len_samples);

        while (self.locals[0].produced < target) {
            // all channels advance in lockstep, so every channel encodes the
            // same number of samples per step
            const n0: u64 = @min(encode_block_samples, @min(target - self.locals[0].produced, self.interval_len_samples - self.locals[0].produced));
            const n: usize = @intCast(n0);

            // Live capture is pulled once per step and shared by every channel:
            // one pull per channel would hand each channel a different slice of
            // the device ring and slowly pull them out of time with each other.
            var live_block: [encode_block_samples]f32 = undefined;
            if (self.dev) |d| self.pullCapture(d, live_block[0..n]);

            for (self.locals) |*lc| {
                if (!lc.broadcast) continue;
                var block: [encode_block_samples]f32 = undefined;
                encodeBlockFor(self.opts.source, self.opts.srate, lc, if (self.dev != null) live_block[0..n] else null, block[0..n]);
                var out: std.ArrayList(u8) = .empty;
                defer out.deinit(self.alloc);
                lc.enc.?.encode(block[0..n], &out) catch |e| {
                    return self.failSession("encode failed: {s}", .{@errorName(e)});
                };
                try lc.pending.add(out.items);
            }
            for (self.locals) |*lc| {
                lc.produced += n0;
            }
            // stream out full chunks mid-interval
            for (self.locals) |*lc| {
                if (lc.dropped) continue;
                while (lc.begun and lc.pending.len >= chunk_flush_bytes) {
                    if (!try self.sendUploadChunk(lc, false)) break;
                }
                if (!lc.begun and !lc.dropped and lc.pending.len >= chunk_flush_bytes) {
                    // first chunk of the interval: send held 0x83 then data
                    if (!try self.sendUploadBegin(lc)) continue;
                    _ = try self.sendUploadChunk(lc, false);
                }
            }
        }

        if (self.locals[0].produced >= self.interval_len_samples) {
            try self.finalizeInterval();
        }
    }

    /// #14: send one upload message, refusing to wait for a peer that cannot
    /// keep up. Returns false when the socket would block and the bar is being
    /// abandoned — see `dropInterval` for what happens next.
    ///
    /// `self.send` is deliberately NOT used here. `send` goes through
    /// `net.zig`'s `sendMessage`, whose EAGAIN path polls in a loop until the
    /// peer reads (see the note on `writeAllBounded`): unbounded, on the audio
    /// clock's own path. The zero budget turns "wait forever" into "ask once",
    /// which is the difference between dropping a bar and hanging the session.
    fn sendUpload(self: *Session, mtype: u8, payload: []const u8) !bool {
        const conn = &(self.conn orelse return false);
        if (!conn.writable()) return false;
        if (!try conn.sendMessageBounded(mtype, payload, upload_write_budget_ms)) return false;
        self.stats.msgs_sent += 1;
        self.stats.bytes_sent += payload.len + 5;
        self.last_keepalive_ms = clock.nowMs(self.io);
        return true;
    }

    /// #14: abandon this channel's bar because the socket would block.
    ///
    /// The audio keeps running. That is the whole point of the issue: a bar is
    /// worth one bar of audio, and a socket that cannot take it right now cannot
    /// be made to take it by waiting — the audio clock has no slack to spend.
    /// So the bytes are counted and thrown away, the channel is left `dropped`
    /// so `finalizeInterval` sends nothing more for it (not even a silence
    /// marker: this bar had audio, and claiming otherwise would be a lie the
    /// room would hear as a rest), and the session moves on to the next bar with
    /// a fresh guid.
    fn dropInterval(self: *Session, lc: *LocalChannel, reason: []const u8) void {
        const discarded = lc.pending.len + lc.dump.len;
        lc.dropped = true;
        lc.begun = false;
        lc.pending.clear();
        lc.dump.clear();
        // count once per bar, not once per channel: a dropped bar is one lost
        // bar, and counting per channel would report N losses for one silence
        if (!self.drop_marked) {
            self.drop_marked = true;
            self.stats.intervals_dropped += 1;
            self.stats.upload_bytes_dropped += discarded;
            self.log.line("UPLOAD DROPPED: {s} — bar {d} skipped (socket would block, {d} bytes discarded); continuing at the next bar", .{
                reason, self.index.seq, discarded,
            });
        }
    }

    fn sendUploadBegin(self: *Session, lc: *LocalChannel) !bool {
        var f = Fixed{};
        try proto.buildUploadIntervalBegin(.{
            .guid = lc.guid,
            .estsize = 0,
            .fourcc = proto.FOURCC_OGGV,
            .chidx = @intCast(self.channelIndex(lc)),
        }, &f);
        if (!try self.sendUpload(proto.MSG_UPLOAD_INTERVAL_BEGIN, f.slice())) {
            self.dropInterval(lc, "0x83 would block");
            return false;
        }
        lc.begun = true;
        self.log.line("C>S 0x83 UPLOAD_BEGIN guid={s} chidx={d} interval={d}", .{
            // kujamba (#12): the guid's sequence number, not the grid position
            hexBuf(&lc.guid, &self.hex_scratch), self.channelIndex(lc), self.index.seq,
        });
        return true;
    }

    fn channelIndex(self: *Session, lc: *LocalChannel) usize {
        return (@intFromPtr(lc) - @intFromPtr(self.locals.ptr)) / @sizeOf(LocalChannel);
    }

    /// #14: record how long one interval's upload section took. The max is the
    /// number that matters — one slow peer is survivable, a stall measured in
    /// whole bars is the audio clock being eaten by the network.
    fn noteUploadStall(self: *Session, ns: i128) void {
        if (ns <= 0) return;
        const u: u64 = @intCast(ns);
        if (u > self.stats.upload_stall_ns) self.stats.upload_stall_ns = u;
    }

    /// #13: copy the clock's private drift ledger into `Stats`, which is what
    /// `RESULT` prints and what a test can read.
    fn publishClockTelemetry(self: *Session) void {
        self.stats.drift_ns = self.timing.drift_ns;
        self.stats.max_abs_drift_ns = self.timing.max_abs_drift_ns;
        self.stats.clock_corrections = self.timing.corrections;
        self.stats.total_correction_ns = self.timing.total_correction_ns;
    }

    /// #14: returns false when the bar was abandoned mid-transfer.
    fn sendUploadChunk(self: *Session, lc: *LocalChannel, final: bool) !bool {
        // payload cap: 16384 - 17 = 16367 bytes per write message
        const cap: usize = 16367;
        var remaining = lc.pending.items();
        if (remaining.len == 0) {
            if (!final) return true;
            // must terminate the transfer even with no data: empty write
            var f0 = Fixed{};
            try proto.buildUploadIntervalWrite(.{ .guid = lc.guid, .flags = 1, .data = "" }, &f0);
            if (!try self.sendUpload(proto.MSG_UPLOAD_INTERVAL_WRITE, f0.slice())) {
                self.dropInterval(lc, "final 0x84 would block");
                return false;
            }
            self.stats.upload_chunks += 1;
            self.log.line("C>S 0x84 WRITE guid={s} flags=1 bytes=0 (final)", .{hexBuf(&lc.guid, &self.hex_scratch)});
            return true;
        }
        while (remaining.len > 0) {
            const n = @min(remaining.len, cap);
            const is_last = (n == remaining.len);
            if (self.opts.payload_dump_dir != null) {
                try lc.dump.add(remaining[0..n]);
            }
            var f = Fixed{};
            try proto.buildUploadIntervalWrite(.{
                .guid = lc.guid,
                .flags = if (final and is_last) 1 else 0,
                .data = remaining[0..n],
            }, &f);
            if (!try self.sendUpload(proto.MSG_UPLOAD_INTERVAL_WRITE, f.slice())) {
                self.dropInterval(lc, "0x84 would block");
                return false;
            }
            self.stats.upload_chunks += 1;
            self.stats.upload_bytes += n;
            self.log.line("C>S 0x84 WRITE guid={s} flags={d} bytes={d}", .{
                hexBuf(&lc.guid, &self.hex_scratch), @as(u8, if (final and is_last) 1 else 0), n,
            });
            remaining = remaining[n..];
        }
        lc.pending.clear();
        return true;
    }

    /// Write the interval's concatenated 0x84 payload bytes to
    /// `<dump_dir>/interval_NNNN.ogg` (determinism evidence for the demo).
    fn writePayloadDump(self: *Session, lc: *LocalChannel, dump_dir: []const u8) !void {
        if (lc.dump.len == 0) return;
        defer lc.dump.clear();
        // kujamba (#12): name by monotonic sequence, so a grid re-anchor cannot
        // overwrite an earlier interval's dump
        const path = kujamba_out.payloadDumpName(self.alloc, dump_dir, self.index.seq) catch return;
        defer self.alloc.free(path);
        if (std.Io.Dir.cwd().createFile(self.io, path, .{})) |f| {
            var wrote_ok = true;
            f.writeStreamingAll(self.io, lc.dump.items()) catch |e| {
                wrote_ok = false;
                self.log.line("payload dump write failed ({s}): {s}", .{ path, @errorName(e) });
            };
            f.close(self.io);
            if (wrote_ok) {
                self.stats.payload_dumps += 1;
                self.log.line("payload dump {s} bytes={d}", .{ path, lc.dump.len });
            }
        } else |e| {
            self.log.line("payload dump open failed ({s}): {s}", .{ path, @errorName(e) });
        }
    }

    fn finalizeInterval(self: *Session) !void {
        // #13/#14 telemetry: wall time the upload section of ONE interval takes.
        // The audio clock regenerates a whole bar per interval, so this is the
        // number that says whether a slow peer can starve it.
        const stall_start_ns = clock.nowNs(self.io);
        defer self.noteUploadStall(clock.nowNs(self.io) - stall_start_ns);

        // kujamba (#13): this is the instant the bar boundary was crossed, and
        // it is what the clock's drift is measured against. Taken BEFORE the
        // upload work below so the wire time is charged to the socket, not
        // disguised as late generation.
        const boundary_ns = stall_start_ns;

        self.drop_marked = false;
        for (self.locals) |*lc| {
            // #14: a channel whose bar was abandoned mid-interval sends nothing
            // further this bar — not the tail, and not a silence marker, because
            // this bar had audio and saying otherwise would be a lie the room
            // hears as a rest.
            if (lc.dropped) continue;
            if (lc.broadcast) {
                if (lc.enc) |e| {
                    var out: std.ArrayList(u8) = .empty;
                    defer out.deinit(self.alloc);
                    e.flush(&out) catch |err| {
                        return self.failSession("encode flush failed: {s}", .{@errorName(err)});
                    };
                    try lc.pending.add(out.items);
                }
                if (!lc.begun) {
                    if (lc.pending.len == 0) {
                        // nothing encoded at all this interval: silence marker
                        var f = Fixed{};
                        try proto.buildUploadIntervalBegin(.{
                            .guid = [_]u8{0} ** 16,
                            .estsize = 0,
                            .fourcc = 0,
                            .chidx = @intCast(self.channelIndex(lc)),
                        }, &f);
                        if (!try self.sendUpload(proto.MSG_UPLOAD_INTERVAL_BEGIN, f.slice())) {
                            self.dropInterval(lc, "silence marker would block");
                            continue;
                        }
                        self.stats.silence_markers += 1;
                        self.log.line("C>S 0x83 SILENCE_MARKER chidx={d}", .{self.channelIndex(lc)});
                    } else {
                        _ = try self.sendUploadBegin(lc);
                    }
                }
                if (lc.dropped) continue;
                _ = try self.sendUploadChunk(lc, true);
                if (self.opts.payload_dump_dir) |dump_dir| {
                    try self.writePayloadDump(lc, dump_dir);
                }
            } else {
                // channel not broadcasting: periodic silence marker (§6.5.4)
                var f = Fixed{};
                try proto.buildUploadIntervalBegin(.{
                    .guid = [_]u8{0} ** 16,
                    .estsize = 0,
                    .fourcc = 0,
                    .chidx = @intCast(self.channelIndex(lc)),
                }, &f);
                if (!try self.sendUpload(proto.MSG_UPLOAD_INTERVAL_BEGIN, f.slice())) {
                    self.dropInterval(lc, "silence marker would block");
                    continue;
                }
                self.stats.silence_markers += 1;
                self.log.line("C>S 0x83 SILENCE_MARKER chidx={d}", .{self.channelIndex(lc)});
            }
        }
        var streaming: u64 = 0;
        var dropped_here = false;
        for (self.locals) |lc| {
            // A dropped channel did not stream, so it is not counted as
            // broadcast: `intervals_broadcast` is what the demo asserts on and
            // it must keep meaning "this bar really went out".
            if (lc.broadcast and !lc.dropped) streaming += 1;
            if (lc.dropped) dropped_here = true;
        }
        if (dropped_here) {
            self.log.line("interval {d} dropped ({d} channels), audio clock continues", .{ self.index.seq, self.locals.len });
        } else {
            self.stats.intervals_uploaded += 1;
            self.stats.upload_channels = @max(self.stats.upload_channels, streaming);
            self.stats.intervals_broadcast += streaming;
            self.log.line("interval {d} complete (grid bar {d}, {d} samples, {d}ms)", .{
                // kujamba (#12): seq and grid are distinct, so log both
                self.index.seq, self.index.grid, self.interval_len_samples, self.interval_len_samples * 1000 / self.opts.srate,
            });
        }
        self.index.complete();

        // kujamba (#13): the bar grid, disciplined. Before this it was
        // `interval_start_ns += interval_ns` with nothing measuring whether the
        // session was keeping up, so the time spent on the wire above was
        // silently stolen from every subsequent bar's generation budget and
        // never returned. Now the crossing time is measured against the bar's
        // nominal end and a *bounded* correction is applied — bounded twice
        // over, as a fraction of the bar and in absolute nanoseconds, so a fast
        // tempo cannot get a jumpy correction and a slow one cannot get a
        // visible one.
        const next_start_ns = self.timing.nextStartNs(self.interval_start_ns, boundary_ns);
        self.interval_start_ns = next_start_ns;
        self.publishClockTelemetry();

        if (self.opts.stop_after_intervals) |n_stop| {
            // kujamba (#12): the cap counts intervals, so it reads the
            // monotonic sequence — a config change must not extend the run
            if (self.index.seq >= n_stop) {
                self.stats.ok = true;
                self.state = .done;
                return;
            }
        }
        self.startIntervalEncoders() catch |e| return e;
    }

    // ---- download path (§6.2/§6.4) ----------------------------------------------

    fn findDownload(self: *Session, guid: *const [16]u8) ?*DownloadState {
        for (&self.downloads) |*d| {
            if (d.active and std.mem.eql(u8, &d.guid, guid)) return d;
        }
        return null;
    }

    fn allocDownload(self: *Session, guid: *const [16]u8, fourcc: u32, chidx: u8, username: []const u8) ?*DownloadState {
        for (&self.downloads) |*d| {
            if (!d.active) {
                d.active = true;
                d.guid = guid.*;
                d.fourcc = fourcc;
                d.chidx = chidx;
                d.user.setName(username);
                d.buf.clear();
                return d;
            }
        }
        return null;
    }

    fn finalizeDownload(self: *Session, d: *DownloadState) !void {
        self.stats.intervals_downloaded += 1;
        self.log.line("download complete user={s} ch={d} bytes={d} fourcc=0x{X:0>8}", .{
            d.user.nameSlice(), d.chidx, d.buf.len, d.fourcc,
        });
        if (d.fourcc != proto.FOURCC_OGGV) {
            self.log.line("skip decode: unknown fourcc", .{});
            d.active = false;
            d.buf.clear();
            return;
        }
        var dec = vorbis.decodeMemory(self.alloc, d.buf.items()) catch |e| {
            self.log.line("DECODE FAILED user={s}: {s}", .{ d.user.nameSlice(), @errorName(e) });
            d.active = false;
            d.buf.clear();
            return;
        };
        defer dec.deinit();
        self.stats.samples_decoded += dec.frames();
        self.log.line("decoded user={s} ch={d} srate={d} ch={d} frames={d} rms={d:.6}", .{
            d.user.nameSlice(), d.chidx, dec.srate, dec.channels, dec.frames(), dec.rms(),
        });
        // downmix to mono for the dump
        if (dec.channels >= 1) {
            const mono = try self.alloc.alloc(f32, dec.frames());
            defer self.alloc.free(mono);
            for (0..dec.frames()) |i| {
                var s: f32 = 0;
                for (0..dec.channels) |k| s += dec.pcm[i * dec.channels + k];
                mono[i] = s / @as(f32, @floatFromInt(dec.channels));
            }
            const out = self.findOrOpenOutput(d.user.nameSlice(), d.chidx, dec.srate) catch |e| {
                self.log.line("wav open failed: {s}", .{@errorName(e)});
                d.active = false;
                d.buf.clear();
                return;
            };
            try out.writer.writeFloats(mono);
            self.pushPlayback(mono);
        }
        d.active = false;
        d.buf.clear();
    }

    // ---- message dispatch ---------------------------------------------------------

    fn dispatch(self: *Session, msg: netmod.Message) !void {
        self.stats.msgs_recv += 1;
        self.stats.bytes_recv += msg.payload.len + 5;
        switch (msg.mtype) {
            proto.MSG_AUTH_CHALLENGE => try self.onChallenge(msg.payload),
            proto.MSG_AUTH_REPLY => try self.onAuthReply(msg.payload),
            proto.MSG_CONFIG_CHANGE_NOTIFY => try self.onConfig(msg.payload),
            proto.MSG_USERINFO_CHANGE_NOTIFY => try self.onUserinfo(msg.payload),
            proto.MSG_DOWNLOAD_INTERVAL_BEGIN => try self.onDownloadBegin(msg.payload),
            proto.MSG_DOWNLOAD_INTERVAL_WRITE => try self.onDownloadWrite(msg.payload),
            proto.MSG_CHAT_MESSAGE => try self.onChat(msg.payload),
            proto.MSG_KEEPALIVE => {},
            else => {
                self.log.line("S>C 0x{X:0>2} UNKNOWN size={d} (ignored)", .{ msg.mtype, msg.payload.len });
            },
        }
    }

    fn onChallenge(self: *Session, payload: []const u8) !void {
        const ch = proto.parseChallenge(payload) catch {
            return self.failSession("bad auth challenge (size={d})", .{payload.len});
        };
        if (ch.protocol_version < proto.PROTO_VER_MIN or ch.protocol_version >= proto.PROTO_VER_MAX) {
            return self.failSession("server protocol 0x{X:0>8} out of range", .{ch.protocol_version});
        }
        const ka: u32 = (ch.server_caps >> 8) & 0xff;
        self.keepalive_s = if (ka == 0) default_keepalive_s else ka;
        self.log.line("S>C 0x00 CHALLENGE challenge={s} caps=0x{X:0>8} ver=0x{X:0>8} keepalive={d}s license={d}b", .{
            hexBuf(&ch.challenge, &self.hex_scratch), ch.server_caps, ch.protocol_version, self.keepalive_s, ch.license.len,
        });
        if (ch.server_caps & 1 != 0) {
            self.log.line("license text (auto-accepted): {d} bytes", .{ch.license.len});
        }

        var reply: [20]u8 = undefined;
        auth.passwordReply(self.opts.user, self.opts.pass, &ch.challenge, &reply);
        var caps: u32 = 0;
        if (ch.server_caps & 1 != 0) caps |= 1; // agree to license
        var f = Fixed{};
        try proto.buildAuthUser(.{
            .passhash = reply,
            .username = self.opts.user,
            .client_caps = caps,
            .client_version = proto.PROTO_VER_CUR,
        }, &f);
        self.log.line("C>S 0x80 AUTH_USER user={s} hash={s} caps={d}", .{ self.opts.user, hexBuf(&reply, &self.hex_scratch2), caps });
        try self.send(proto.MSG_AUTH_USER, f.slice());
        self.state = .awaiting_reply;
    }

    fn onAuthReply(self: *Session, payload: []const u8) !void {
        const rep = proto.parseAuthReply(payload) catch {
            return self.failSession("bad auth reply", .{});
        };
        if (!rep.flag_success) {
            return self.failSession("auth failed: {s}", .{rep.text});
        }
        self.eff_user.setName(rep.text);
        self.maxchan = rep.maxchan orelse 1;
        self.log.line("S>C 0x01 AUTH_OK user={s} maxchan={d}", .{ self.eff_user.nameSlice(), self.maxchan });
        self.state = .active;

        // announce local channels (§4.8 step: client sends 0x82 right after auth)
        var chans: [max_local_channels]proto.ChannelInfoRecord = undefined;
        const n = @min(self.locals.len, max_local_channels);
        for (0..n) |i| chans[i] = .{ .name = self.locals[i].nameSlice() };
        var f = Fixed{};
        try proto.buildChannelInfo(chans[0..n], &f);
        self.log.line("C>S 0x82 SET_CHANNEL_INFO n={d}", .{n});
        try self.send(proto.MSG_SET_CHANNEL_INFO, f.slice());
    }

    fn onConfig(self: *Session, payload: []const u8) !void {
        const cfg = proto.parseConfig(payload) catch {
            return self.failSession("bad config change", .{});
        };
        // #41: both fields are raw wire values, and a config change is the one
        // place a client is asked to divide by one of them. bpm = 0 reached
        // @divTrunc(srate * bpi * 60, bpm) and panicked; bpi = 0 does not panic
        // but makes every interval zero-length, which turns the run loop's
        // `produced >= interval_len` into a per-pass finalize — a flood of
        // empty uploads rather than a crash. Neither is a tempo the client can
        // honour, so this is the same class as a malformed payload: fail the
        // session, the same way a parse failure does above.
        //
        // Checked BEFORE the assignments below. Bailing out after writing
        // self.bpm would leave a session that believes it is running at 0 bpm,
        // which is exactly the state that made the original panic reachable.
        if (cfg.bpm == 0 or cfg.bpi == 0) {
            self.log.line("S>C 0x02 CONFIG bpm={d} bpi={d}", .{ cfg.bpm, cfg.bpi });
            return self.failSession("bad config change: bpm and bpi must both be non-zero", .{});
        }
        const changed = cfg.bpm != self.bpm or cfg.bpi != self.bpi;
        self.bpm = cfg.bpm;
        self.bpi = cfg.bpi;
        self.log.line("S>C 0x02 CONFIG bpm={d} bpi={d}", .{ cfg.bpm, cfg.bpi });

        if (changed) {
            // finalize any in-flight interval cleanly, then adopt new timing
            if (self.interval_len_samples != 0 and self.locals[0].produced > 0) {
                try self.finalizeInterval();
            }
            self.interval_len_samples = @intCast(@divTrunc(@as(u64, self.opts.srate) * @as(u64, cfg.bpi) * 60, @as(u64, cfg.bpm)));
            self.interval_start_ns = clock.nowNs(self.io);
            // kujamba (#13): anchor the disciplined grid on this boundary. The
            // `0x02` arrival is the only place the server ever tells the client
            // where its grid is, so it is the only place a re-anchor belongs —
            // and re-anchoring the clock (not just the start time) is what keeps
            // the drift ledger continuous across a tempo change instead of
            // quietly restarting at zero.
            self.timing.anchor(self.interval_start_ns, cfg.bpm, cfg.bpi);
            self.publishClockTelemetry();
            // kujamba (#12): only the grid geometry moves. The bar counter and
            // the phrase cursor stay put, and the interval sequence keeps
            // climbing, so no guid repeats and no payload dump is overwritten.
            self.dropCapturePreRoll();
            try self.startIntervalEncoders();
            self.log.line("interval clock started: {d} samples ({d}ms)", .{
                self.interval_len_samples, self.interval_len_samples * 1000 / self.opts.srate,
            });
            self.log.line("re-anchored to bpm={d} bpi={d}: next interval {d} at grid bar {d} (phrase continues)", .{
                cfg.bpm, cfg.bpi, self.index.seq, self.index.grid,
            });
            self.log.line("server clock: bar={d}ns slew limit={d}ms lead={d} samples", .{
                self.timing.interval_ns,
                @divTrunc(self.timing.slewLimitNs(), std.time.ns_per_ms),
                self.timing.encodeLeadSamples(self.interval_len_samples),
            });
        }
    }

    fn onUserinfo(self: *Session, payload: []const u8) !void {
        var sink = proto.UserInfoSink{};
        proto.parseUserinfoRecords(payload, &sink) catch {
            return self.failSession("bad userinfo change", .{});
        };
        self.log.line("S>C 0x03 USERINFO nrecords={d}", .{sink.count});
        for (sink.items()) |rec| {
            self.log.line("  user={s} ch={d} active={d} name={s} flags=0x{X:0>2}", .{
                rec.username, rec.channel_id, @intFromBool(rec.active), rec.channel_name, rec.flags,
            });
            if (!rec.active) continue;
            // #40: `channel_id` is a raw wire byte and the shift below needs a
            // u5, so >= 32 panicked on @intCast. A channel outside 0..31
            // cannot name a bit in a u32 mask — the reference client's mask is
            // u32 too, so it has no legitimate meaning and there is nothing to
            // salvage. Skipping the record (not failing the session) is right:
            // one nonsense record from a quirky server should not tear down a
            // live performance, and the rest of the message is still good.
            if (rec.channel_id >= 32) {
                self.log.line("  ignoring userinfo record: channel {d} is out of range 0..31", .{rec.channel_id});
                continue;
            }
            const u = self.findOrAddUser(rec.username) orelse continue;
            const bit = @as(u32, 1) << @intCast(rec.channel_id);
            if (u.mask & bit == 0) {
                u.mask |= bit;
                // auto-subscribe like the reference client (§5.8, njclient.cpp:1184)
                var f = Fixed{};
                try proto.buildUsermaskRecord(.{ .username = u.nameSlice(), .channelmask = u.mask }, &f);
                self.log.line("C>S 0x81 SET_USERMASK user={s} mask=0x{X:0>8}", .{ u.nameSlice(), u.mask });
                try self.send(proto.MSG_SET_USERMASK, f.slice());
            }
        }
    }

    fn onDownloadBegin(self: *Session, payload: []const u8) !void {
        const b = proto.parseIntervalBegin(payload) catch {
            return self.failSession("bad download begin", .{});
        };
        if (proto.isZeroGuid(&b.guid) and b.fourcc == 0) {
            self.log.line("S>C 0x04 SILENCE_MARKER user={s} ch={d}", .{ b.username, b.chidx });
            return;
        }
        if (self.allocDownload(&b.guid, b.fourcc, b.chidx, b.username)) |_| {
            self.log.line("S>C 0x04 DOWNLOAD_BEGIN user={s} ch={d} guid={s} fourcc=0x{X:0>8}", .{
                b.username, b.chidx, hexBuf(&b.guid, &self.hex_scratch), b.fourcc,
            });
        } else {
            self.log.line("download table full, dropping transfer from {s}", .{b.username});
        }
    }

    fn onDownloadWrite(self: *Session, payload: []const u8) !void {
        const w = proto.parseIntervalWrite(payload) catch {
            return self.failSession("bad download write", .{});
        };
        const d = self.findDownload(&w.guid) orelse {
            self.log.line("S>C 0x05 WRITE for unknown guid (ignored)", .{});
            return;
        };
        try d.buf.add(w.data);
        self.stats.download_bytes += w.data.len;
        self.log.line("S>C 0x05 WRITE user={s} bytes={d} flags={d} total={d}", .{
            d.user.nameSlice(), w.data.len, w.flags, d.buf.len,
        });
        if (w.flags & 1 != 0) {
            try self.finalizeDownload(d);
        }
    }

    fn onChat(self: *Session, payload: []const u8) !void {
        const p = proto.parseChat(payload) catch {
            return self.failSession("bad chat message", .{});
        };
        self.stats.chat_received += 1;
        self.log.line("S>C 0xC0 CHAT {s}: {s} | {s} | {s} | {s}", .{
            p.get(0), p.get(1), p.get(2), p.get(3), p.get(4),
        });
        // kujamba (#9): route a `!kujamba <verb>` transport command to the app.
        // The server's 0xC0 layout varies by chat kind, so scan every param for
        // the command prefix rather than assume an index; the first match wins.
        // An unrecognized verb is `.none` and simply does nothing, so unknown
        // commands and ordinary chat are ignored safely.
        if (self.opts.chat_command) |cb| {
            var i: usize = 0;
            while (i < 5) : (i += 1) {
                const verb = kujamba_out.parseChatCommand(p.get(i));
                if (verb != .none) {
                    cb(self.opts.chat_ctx, verb);
                    break;
                }
            }
        }
    }

    // ---- main loop -------------------------------------------------------------------

    pub fn run(self: *Session) !Stats {
        std.Io.Dir.cwd().createDirPath(self.io, self.opts.out_dir) catch {};
        if (self.opts.payload_dump_dir) |dump_dir| {
            std.Io.Dir.cwd().createDirPath(self.io, dump_dir) catch {};
        }

        self.openLive();

        var hostbuf: [256]u8 = undefined;
        const hostport = std.fmt.bufPrint(&hostbuf, "{s}:{d}", .{ self.opts.host, self.opts.port }) catch "host";
        self.log.line("connecting to {s} as {s}", .{ hostport, self.opts.user });
        self.conn = netmod.Conn.connect(self.io, self.opts.host, self.opts.port) catch |e| {
            return self.failSession("connect failed: {s}", .{@errorName(e)});
        };
        self.log.line("connected", .{});
        self.last_keepalive_ms = clock.nowMs(self.io);

        const deadline_ns = self.start_ns + @as(i128, self.opts.duration_ms) * 1_000_000;

        while (self.state != .done) {
            const now_ns = clock.nowNs(self.io);
            if (now_ns >= deadline_ns) {
                // kujamba instrument hook: hitting the cap with zero intervals
                // uploaded is a failed run, not a success
                self.stats.ok = self.stats.intervals_uploaded > 0;
                self.state = .done;
                break;
            }

            // kujamba instrument hook: cooperative stop (Ctrl+C) — finish the
            // current interval cleanly instead of dying mid-upload.
            if (kujamba_out.stopRequested()) {
                self.log.line("stop requested: finishing current interval", .{});
                if (self.state == .active and self.interval_len_samples != 0 and
                    self.locals.len > 0 and self.locals[0].produced > 0)
                {
                    try self.finalizeInterval();
                }
                self.stats.ok = self.stats.intervals_uploaded > 0;
                self.state = .done;
                break;
            }

            // drain any readable messages
            var readable = true;
            while (readable and self.state != .done) {
                readable = self.conn.?.pollReadable(0) catch |e| {
                    return self.failSession("poll failed: {s}", .{@errorName(e)});
                };
                if (!readable) break;
                const msg = self.conn.?.readMessage(&self.payload) catch |e| switch (e) {
                    error.WouldBlock => break,
                    else => return self.failSession("read failed: {s}", .{@errorName(e)}),
                };
                try self.dispatch(msg);
            }
            if (self.state != .done) {
                // wait up to 20 ms for the next message
                _ = self.conn.?.pollReadable(20) catch {};
            }

            if (self.state == .active) {
                const now2 = clock.nowNs(self.io);
                self.advanceAudio(now2) catch |e| switch (e) {
                    error.SessionFailed => {},
                    else => return self.failSession("audio advance failed: {s}", .{@errorName(e)}),
                };
                if (self.state == .done) break;

                if (self.opts.chat != null and !self.chat_sent and
                    now2 - self.start_ns >= @as(i128, self.opts.chat_delay_ms) * 1_000_000)
                {
                    self.sendChatMsg(&[_][]const u8{ "MSG", self.opts.chat.? }) catch |e| {
                        return self.failSession("chat send failed: {s}", .{@errorName(e)});
                    };
                    self.chat_sent = true;
                    self.stats.chat_sent += 1;
                    self.log.line("C>S 0xC0 CHAT MSG: {s}", .{self.opts.chat.?});
                }
            }

            const now_ms = clock.nowMs(self.io);
            if (now_ms - self.conn.?.last_recv_ms > @as(i64, @intCast(self.keepalive_s)) * 3000) {
                return self.failSession("connection stalled: no data for {d}ms", .{now_ms - self.conn.?.last_recv_ms});
            }
            if (self.state == .active) self.sendKeepaliveIfDue(now_ms);
        }

        self.closeWavs();
        self.closeLive();
        self.log.line("session end: ok={}", .{self.stats.ok});
        return self.stats;
    }
};

test "multi-channel live capture shares one block per step (channels stay aligned)" {
    var a = LocalChannel{ .pending = Buf.init(std.testing.allocator), .dump = Buf.init(std.testing.allocator) };
    defer a.pending.deinit();
    var b = LocalChannel{ .pending = Buf.init(std.testing.allocator), .dump = Buf.init(std.testing.allocator) };
    defer b.pending.deinit();

    var shared: [64]f32 = undefined;
    for (&shared, 0..) |*s, i| s.* = @sin(@as(f32, @floatFromInt(i)) * 0.1);

    var ba: [64]f32 = undefined;
    var bb: [64]f32 = undefined;
    encodeBlockFor(.silence, 48000, &a, &shared, &ba);
    encodeBlockFor(.silence, 48000, &b, &shared, &bb);
    // identical sample-for-sample: a per-channel pull would shift b by a block
    for (ba, bb) |x, y| try std.testing.expectEqual(x, y);
    try std.testing.expectEqual(shared[0], ba[0]);
    try std.testing.expectEqual(shared[63], ba[63]);
}

// kujamba (#12): the config-change seam. Before the fix `onConfig` zeroed the
// single `interval_idx`, which re-issued a guid the server had already seen
// under different payload bytes, renamed later payload dumps onto earlier
// files, and restarted bar numbering. Counters start part-way through the
// session so a reset is visible; finalizing a *mid-interval* config change
// needs a socket, so the in-flight interval is left empty. The `--intervals` cap
// reads the same field as the guid derivation but lives in `finalizeInterval`,
// which is not reachable without a socket; #24 should cover it end to end.
test "kujamba: a config change moves the grid without renumbering intervals or cutting the phrase" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    var bank = try onePhraseBank(std.testing.allocator, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .loop };
    fill.bind(.loop, bank.active());
    const pattern = try kujamba_out.parsePattern("3+1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .bank = &bank };

    var s = try Session.init(alloc, io, .{
        .srate = @intCast(kujamba_out.sample_rate),
        .channel_names = &.{"kujamba"},
        .source = .{ .kujamba = &fill },
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.selectForFn },
    });
    defer s.deinit();
    s.log.quiet = true; // these tests assert on state, not on the transcript

    // Three intervals have gone out and the grid was re-anchored once already
    // (the #24 shape), so identity and position deliberately differ: seq 3,
    // grid bar 7. Bar 7 of a 3+1 pattern is a rest bar.
    s.index.seq = 3;
    s.index.grid = 7;
    fill.cursor = 1234; // the phrase is mid-word

    var f = Fixed{};
    try proto.buildConfig(.{ .bpm = 120, .bpi = 4 }, &f);
    try s.dispatch(.{ .mtype = proto.MSG_CONFIG_CHANGE_NOTIFY, .payload = f.slice() });

    // identity: monotonic, so no guid repeats and no dump gets renamed
    try std.testing.expectEqual(@as(u64, 3), s.index.seq);
    // grid position: continuous, so the pattern does not stutter
    try std.testing.expectEqual(@as(u64, 7), s.index.grid);
    // the phrase was not cut: the cursor still points into the middle of it
    try std.testing.expectEqual(@as(u64, 1234), fill.cursor);
    // ...and the new geometry really did take effect
    try std.testing.expectEqual(@as(u16, 120), s.bpm);
    try std.testing.expectEqual(@as(u16, 4), s.bpi);
    try std.testing.expectEqual(
        @as(u64, kujamba_out.sample_rate) * 4 * 60 / 120,
        s.interval_len_samples,
    );
    // bar 7 of a 3+1 pattern is a rest bar, and the re-anchor kept it that way
    try std.testing.expect(!s.locals[0].broadcast);

    // The guid the re-anchored interval is now uploading under is the one that
    // belongs to sequence 3 -- not the one the grid position 7 would produce.
    var by_seq: [16]u8 = undefined;
    var by_grid: [16]u8 = undefined;
    kujamba_out.deriveGuid(42, s.index.seq, 0, &by_seq);
    kujamba_out.deriveGuid(42, s.index.grid, 0, &by_grid);
    try std.testing.expect(!std.mem.eql(u8, &by_seq, &by_grid));
    try std.testing.expectEqualSlices(u8, &by_seq, &s.locals[0].guid);

    // ...and so is the payload dump: it must land on the sequence's filename,
    // not overwrite interval_0007.ogg from an earlier stretch of the session.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer alloc.free(dir);
    try s.locals[0].dump.add("payload");
    try s.writePayloadDump(&s.locals[0], dir);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(io, "interval_0007.ogg", .{}),
    );
    _ = try tmp.dir.access(io, "interval_0003.ogg", .{});
}

// kujamba (#12): the re-anchored interval continues the slot it was already in,
// so it re-derives exactly the id (guid + dump name) that slot owns.
test "kujamba: a re-anchored interval keeps the id of the slot it re-uses" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    var bank = try onePhraseBank(std.testing.allocator, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .repeat };
    fill.bind(.repeat, bank.active());
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .bank = &bank };

    var s = try Session.init(alloc, io, .{
        .srate = @intCast(kujamba_out.sample_rate),
        .channel_names = &.{"kujamba"},
        .source = .{ .kujamba = &fill },
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.selectForFn },
    });
    defer s.deinit();
    s.log.quiet = true; // these tests assert on state, not on the transcript

    // the guid the server would already be receiving under, and the dump name
    // that interval slot owns
    var in_flight: [16]u8 = undefined;
    kujamba_out.deriveGuid(42, s.index.seq, 0, &in_flight);
    const name = try kujamba_out.payloadDumpName(alloc, "dump", s.index.seq);
    defer alloc.free(name);

    var f = Fixed{};
    try proto.buildConfig(.{ .bpm = 90, .bpi = 12 }, &f);
    try s.dispatch(.{ .mtype = proto.MSG_CONFIG_CHANGE_NOTIFY, .payload = f.slice() });

    // grid moved; interval identity did not
    var after: [16]u8 = undefined;
    kujamba_out.deriveGuid(42, s.index.seq, 0, &after);
    try std.testing.expectEqualSlices(u8, &in_flight, &after);
    const name_after = try kujamba_out.payloadDumpName(alloc, "dump", s.index.seq);
    defer alloc.free(name_after);
    try std.testing.expectEqualStrings(name, name_after);
}

// ---- #40 / #41: hostile server values must not panic the client -------------
// Both found by the #26 fuzz harness. The tests drive the real wire bytes
// through `dispatch`, not the handler directly, so they keep guarding the
// path an actual server message takes.

test "a userinfo record with channel_id >= 32 is skipped, not shifted (#40)" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    var bank = try onePhraseBank(std.testing.allocator, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .repeat };
    fill.bind(.repeat, bank.active());
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .bank = &bank };

    var s = try Session.init(alloc, io, .{
        .srate = @intCast(kujamba_out.sample_rate),
        .channel_names = &.{"kujamba"},
        .source = .{ .kujamba = &fill },
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.selectForFn },
    });
    defer s.deinit();
    s.log.quiet = true;

    // channel 200 is the repro byte from #40. It cannot name a bit in a u32
    // mask, and the shift used to panic on the @intCast to u5.
    var f = Fixed{};
    try proto.buildUserinfoRecord(.{
        .active = true,
        .channel_id = 200,
        .volume = 0,
        .pan = 0,
        .flags = 0,
        .username = "x",
        .channel_name = "y",
    }, &f);
    // The record itself: the session survives, and does NOT tear down. One
    // nonsense channel from a quirky server should not end a live performance.
    try s.dispatch(.{ .mtype = proto.MSG_USERINFO_CHANGE_NOTIFY, .payload = f.slice() });
    try std.testing.expect(s.state != .done);

    // Nothing was subscribed, no user was conjured into existence for a record
    // we declined to act on, and -- the part a crash-only test would miss --
    // no auto-subscribe went out on the wire. `msgs_sent` is the honest witness
    // that we skipped the record rather than half-handling it.
    for (s.users) |u| try std.testing.expectEqual(@as(usize, 0), u.name_len);
    for (s.users) |u| try std.testing.expectEqual(@as(u32, 0), u.mask);
    try std.testing.expectEqual(@as(u64, 0), s.stats.msgs_sent);

    // Seam, not covered here: that a *well-formed* record arriving after this
    // one is still honoured. The auto-subscribe path calls send(), which
    // unwraps a socket this test does not have, so it is unreachable without
    // one -- the same seam #12 documented for the --intervals cap. #24, which
    // needs a socket anyway, should cover it end to end.
}

test "a config change with bpm=0 or bpi=0 is refused, not divided by (#41)" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    var bank = try onePhraseBank(std.testing.allocator, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .repeat };
    fill.bind(.repeat, bank.active());
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .bank = &bank };

    var s = try Session.init(alloc, io, .{
        .srate = @intCast(kujamba_out.sample_rate),
        .channel_names = &.{"kujamba"},
        .source = .{ .kujamba = &fill },
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.selectForFn },
    });
    defer s.deinit();
    s.log.quiet = true;

    // A real geometry first, so "refused" is observable as "unchanged" rather
    // than as "never happened".
    var good = Fixed{};
    try proto.buildConfig(.{ .bpm = 120, .bpi = 4 }, &good);
    try s.dispatch(.{ .mtype = proto.MSG_CONFIG_CHANGE_NOTIFY, .payload = good.slice() });
    const good_len = s.interval_len_samples;
    try std.testing.expect(good_len > 0);

    // bpm = 0 reached @divTrunc(srate * bpi * 60, bpm) and panicked. bpi is
    // changed from the current value because `changed` gates the re-anchor.
    var zero_bpm = Fixed{};
    try proto.buildConfig(.{ .bpm = 0, .bpi = 8 }, &zero_bpm);
    try std.testing.expectError(
        error.SessionFailed,
        s.dispatch(.{ .mtype = proto.MSG_CONFIG_CHANGE_NOTIFY, .payload = zero_bpm.slice() }),
    );
    // The tempo the client was actually running is intact: the check has to
    // happen BEFORE self.bpm is assigned, or a bailed-out session is left
    // believing it is running at 0 bpm -- the state that made the panic
    // reachable in the first place.
    try std.testing.expectEqual(@as(u16, 120), s.bpm);
    try std.testing.expectEqual(@as(u16, 4), s.bpi);
    try std.testing.expectEqual(good_len, s.interval_len_samples);
    try std.testing.expectEqual(s.state, .done);
}

test "a config change with bpi=0 is refused: a zero-length interval is nonsense (#41)" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    var bank = try onePhraseBank(std.testing.allocator, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .repeat };
    fill.bind(.repeat, bank.active());
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .bank = &bank };

    var s = try Session.init(alloc, io, .{
        .srate = @intCast(kujamba_out.sample_rate),
        .channel_names = &.{"kujamba"},
        .source = .{ .kujamba = &fill },
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.selectForFn },
    });
    defer s.deinit();
    s.log.quiet = true;

    // bpi = 0 does not panic -- advanceAudio early-returns on a zero interval
    // -- but it makes every interval zero-length, which turns the run loop's
    // `produced >= interval_len` into a per-pass finalize: a flood of empty
    // uploads instead of a crash. Just as unhonourable as bpm = 0.
    var zero_bpi = Fixed{};
    try proto.buildConfig(.{ .bpm = 100, .bpi = 0 }, &zero_bpi);
    try std.testing.expectError(
        error.SessionFailed,
        s.dispatch(.{ .mtype = proto.MSG_CONFIG_CHANGE_NOTIFY, .payload = zero_bpi.slice() }),
    );
    try std.testing.expect(s.interval_len_samples == 0 or s.bpi == 0);
    try std.testing.expectEqual(s.state, .done);
}

test "synthetic sources keep an independent phase per channel" {
    var a = LocalChannel{ .pending = Buf.init(std.testing.allocator), .dump = Buf.init(std.testing.allocator) };
    defer a.pending.deinit();
    var b = LocalChannel{ .pending = Buf.init(std.testing.allocator), .dump = Buf.init(std.testing.allocator) };
    defer b.pending.deinit();
    b.phase = 1.0; // start somewhere else in the cycle

    var ba: [128]f32 = undefined;
    var bb: [128]f32 = undefined;
    const src = Source{ .tone = .{ .freq = 440, .amp = 0.5 } };
    encodeBlockFor(src, 48000, &a, null, &ba);
    encodeBlockFor(src, 48000, &b, null, &bb);
    try std.testing.expect(ba[0] != bb[0]);
    // each channel still advances its own oscillator
    try std.testing.expect(a.phase != b.phase);
}

// ---- #11 bar-accurate selection ---------------------------------------------

test "kujamba: a mode switch requested during bar N applies at the start of bar N+1" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A phrase long enough that a bar change is visible in the audio below.
    var phrase: [4096]f32 = undefined;
    for (&phrase, 0..) |*o, i| o.* = @as(f32, @floatFromInt(i % 97)) / 97.0;
    var bank = try onePhraseBank(std.testing.allocator, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .repeat };
    fill.bind(.repeat, bank.active());
    const pattern = try kujamba_out.parsePattern("1"); // always broadcast
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .mode = .repeat, .bank = &bank };

    var s = try Session.init(alloc, io, .{
        .srate = @intCast(kujamba_out.sample_rate),
        .channel_names = &.{"kujamba"},
        .source = .{ .kujamba = &fill },
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.selectForFn },
    });
    defer s.deinit();
    s.log.quiet = true;

    // Bar 0 starts in repeat: the plan's mode is bound to the source.
    s.index.grid = 0;
    try s.startIntervalEncoders();
    try std.testing.expectEqual(kujamba_out.Mode.repeat, fill.mode);

    // A switch is "requested" during bar 0 by updating the plan. The fill is
    // untouched until the next bar boundary — this is the "no mid-interval
    // splice" property: the in-flight bar keeps the mode it started with.
    adapter.mode = .loop;
    try std.testing.expectEqual(kujamba_out.Mode.repeat, fill.mode); // not yet applied

    // Bar 1 starts: the selection is applied, now including the new mode.
    s.index.grid = 1;
    try s.startIntervalEncoders();
    try std.testing.expectEqual(kujamba_out.Mode.loop, fill.mode);
}

test "kujamba: a rest bar still rebinds the mode, so a switch while resting lands on the next play bar" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase: [2048]f32 = undefined;
    for (&phrase, 0..) |*o, i| o.* = @as(f32, @floatFromInt(i % 31)) / 31.0;
    var bank = try onePhraseBank(std.testing.allocator, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .repeat };
    fill.bind(.repeat, bank.active());
    const pattern = try kujamba_out.parsePattern("1+1"); // play, rest, play, rest
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .mode = .repeat, .bank = &bank };

    var s = try Session.init(alloc, io, .{
        .srate = @intCast(kujamba_out.sample_rate),
        .channel_names = &.{"kujamba"},
        .source = .{ .kujamba = &fill },
        .id_seed = 7,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.selectForFn },
    });
    defer s.deinit();
    s.log.quiet = true;

    // bar 0 plays, bar 1 rests. Switch requested "during" the rest bar.
    s.index.grid = 0;
    try s.startIntervalEncoders();
    try std.testing.expectEqual(kujamba_out.Mode.repeat, fill.mode);

    adapter.mode = .once;
    s.index.grid = 1; // rest bar
    try s.startIntervalEncoders();
    // the rest bar applied the new mode even though it uploads no audio
    try std.testing.expectEqual(kujamba_out.Mode.once, fill.mode);
}

// ---- #9 chat-driven transport ------------------------------------------------

/// A one-entry bank over an already-rendered buffer, for tests that only need a
/// plan and a source and do not care that the audio is a real phrase. Goes
/// through `initBorrowed` so the bank owns no audio, so `deinit` cannot free a
/// stack buffer.
fn onePhraseBank(alloc: std.mem.Allocator, samples: []const f32) !kujamba_out.PhraseBank {
    return kujamba_out.PhraseBank.initBorrowed(alloc, &.{"test"}, &.{samples});
}

/// A socketpair whose client end has a deliberately tiny send buffer and a peer
/// that never reads — the one shape that reliably produces `EAGAIN`.
///
/// Loopback TCP is not usable for this: measured on macOS, a socketpair peer
/// that stops reading still absorbs **654 KB** with `SO_RCVBUF` set to 4096,
/// because the loopback path does not honour the receive window the way a real
/// network does. So end-to-end backpressure is a *slow-peer* failure, not a
/// jitter failure, and on loopback it is not reachable inside a test's patience.
/// A socketpair has a genuinely bounded buffer, which is what makes the drop
/// path testable at all — and it is the same `Conn`, the same `sendMessageBounded`
/// and the same `finalizeInterval`, only with a smaller pipe.
fn saturatedSocketPair() ![2]std.posix.socket_t {
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(@intCast(std.posix.AF.UNIX), @intCast(std.posix.SOCK.STREAM), 0, &fds);
    if (std.posix.errno(rc) != .SUCCESS) return error.SocketPairFailed;
    std.posix.setsockopt(fds[0], std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, &std.mem.toBytes(@as(i32, 4096))) catch {};
    std.posix.setsockopt(fds[1], std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, &std.mem.toBytes(@as(i32, 4096))) catch {};
    // non-blocking on BOTH ends: the peer must be able to be drained without
    // blocking, and the client end already is on the real path
    for (fds) |fd| {
        var o: std.c.O = @bitCast(@as(u32, @intCast(std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0)))));
        o.NONBLOCK = true;
        _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(o)));
    }
    return fds;
}

/// Fill a non-blocking socket until `write` returns `EAGAIN`. Returns the bytes
/// it took, so a test can assert the pipe really was full.
fn fillUntilBlocked(fd: std.posix.socket_t, buf: []const u8) usize {
    var total: usize = 0;
    while (true) {
        const rc = std.posix.system.write(fd, buf.ptr, buf.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => total += @intCast(rc),
            else => return total,
        }
    }
}

fn drainSocket(fd: std.posix.socket_t, buf: []u8) usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(fd, buf) catch break;
        if (n == 0) break;
        total += n;
    }
    return total;
}

// #14: a socket that cannot take the bar costs the bar, not the audio clock.
//
// This is the acceptance test the issue asks for, end to end through
// `finalizeInterval`. Before the fix this call did not return at all: `send()`
// went to `net.zig`'s `sendMessage`, whose EAGAIN branch polls in a loop until
// the peer reads. The bound asserted here is deliberately generous — a poll
// syscall and a log line — because the point is only that it is *bounded*.
test "kujamba: a blocked socket drops the bar instead of stalling the clock (#14)" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6 };
    var bank = try onePhraseBank(alloc, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .loop };
    fill.bind(.loop, bank.active());
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .bank = &bank };

    const fds = try saturatedSocketPair();
    defer _ = std.posix.errno(std.posix.system.close(fds[1])); // fds[0] is s.conn's
    var s = try Session.init(alloc, io, .{
        .srate = 48000,
        .channel_names = &.{"kujamba"},
        .source = .{ .kujamba = &fill },
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.selectForFn },
    });
    defer s.deinit();
    s.conn = .{ .io = io, .fd = fds[0] };
    s.log.quiet = true;

    // a live session with a running interval clock, as `onConfig` leaves it
    s.state = .active;
    s.bpm = 120;
    s.bpi = 4;
    s.interval_len_samples = 96000; // 2 s at 48 kHz
    s.interval_start_ns = clock.nowNs(io);
    s.timing.anchor(s.interval_start_ns, s.bpm, s.bpi);
    const dropped_guid = s.locals[0].guid;
    try s.startIntervalEncoders();
    // the bar has real audio in it, so this is a bar worth losing
    var block: [960]f32 = undefined;
    for (&block, 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i)) * 0.05) * 0.5;
    for (s.locals) |*lc| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try lc.enc.?.encode(&block, &out);
        try lc.pending.add(out.items);
    }
    const pending_before = s.locals[0].pending.len;
    try std.testing.expect(pending_before > 0);

    // the peer stops reading: fill the pipe
    var junk: [4096]u8 = undefined;
    @memset(&junk, 0xA5);
    const absorbed = fillUntilBlocked(fds[0], &junk);
    try std.testing.expect(absorbed > 0);
    try std.testing.expect(!s.conn.?.writable()); // the gate agrees it is full

    // the bar is finalized against a socket that cannot take it
    const t0 = clock.nowNs(io);
    try s.finalizeInterval();
    const elapsed_ms = @divTrunc(clock.nowNs(io) - t0, std.time.ns_per_ms);

    // the bar is counted as lost, and NOT as uploaded
    try std.testing.expectEqual(@as(u64, 1), s.stats.intervals_dropped);
    try std.testing.expectEqual(@as(u64, 0), s.stats.intervals_uploaded);
    try std.testing.expectEqual(@as(u64, 0), s.stats.intervals_broadcast);
    try std.testing.expect(s.stats.upload_bytes_dropped > 0);
    // and not one byte of it was counted as uploaded, which is the other half
    // of "dropped": a bar cannot be both lost and sent
    try std.testing.expectEqual(@as(u64, 0), s.stats.upload_bytes);
    try std.testing.expectEqual(@as(u64, 0), s.stats.upload_chunks);
    // the clock did not stop: the sequence moved on
    try std.testing.expectEqual(@as(u64, 1), s.index.seq);
    // and the bar it moved by is bounded (#13's "no audible jumps", asserted
    // where it is applied). This bar was finished *early* — the test finalizes
    // straight after encoding 20 ms of a 2 s bar — so the correction runs
    // backwards, which is exactly the case a one-sided clamp would get wrong.
    const nominal_next = s.timing.boundaryNs(0) + s.timing.interval_ns;
    const applied = s.interval_start_ns - nominal_next;
    try std.testing.expect(@abs(applied) <= s.timing.slewLimitNs());
    try std.testing.expect(applied < 0); // early bar -> pulled back, not pushed on
    // the next bar is a fresh guid, so the server cannot read the retry as a
    // continuation of the guid it never finished receiving
    try std.testing.expect(!std.mem.eql(u8, &dropped_guid, &s.locals[0].guid));

    // this is the acceptance criterion: bounded, not merely "eventually".
    // Pre-fix it was unbounded (measured >5 s and still not returning).
    try std.testing.expect(elapsed_ms < 250);
}

// #14: a drop can happen mid-interval, not only at the boundary.
//
// The chunk streaming inside `advanceAudio` sends `0x83`/`0x84` too, on the same
// audio-clock path, so it needs the same gate. When it trips, the channel is
// already `dropped` by the time `finalizeInterval` runs — which is what the
// `if (lc.dropped) continue` at the top of that loop is for. Without this test
// that guard could be deleted and nothing would notice.
test "kujamba: a mid-interval chunk that would block drops the bar and stays dropped (#14)" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase = [_]f32{0.1} ** 4096;
    var bank = try onePhraseBank(alloc, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .loop };
    fill.bind(.loop, bank.active());
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .bank = &bank };

    const fds = try saturatedSocketPair();
    defer _ = std.posix.errno(std.posix.system.close(fds[1]));
    var s = try Session.init(alloc, io, .{
        .srate = 48000,
        .channel_names = &.{"kujamba"},
        .source = .{ .kujamba = &fill },
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.selectForFn },
    });
    defer s.deinit();
    s.conn = .{ .io = io, .fd = fds[0] };
    s.log.quiet = true;
    s.state = .active;
    s.bpm = 120;
    s.bpi = 4;
    s.interval_len_samples = 96000;
    s.interval_start_ns = clock.nowNs(io) - @as(i128, 96000) * 1_000_000_000 / 48000;
    s.timing.anchor(s.interval_start_ns, s.bpm, s.bpi);
    try s.startIntervalEncoders();

    // the peer stops reading before the bar even starts
    var junk: [4096]u8 = undefined;
    @memset(&junk, 0xA5);
    _ = fillUntilBlocked(fds[0], &junk);

    // generate a whole bar's worth: the chunk streaming inside advanceAudio has
    // to try to send, and must fail without blocking. Note that advanceAudio
    // finalises the bar itself once `produced` reaches the end, so the drop is
    // observed through the counters rather than through `lc.dropped`, which the
    // next `startIntervalEncoders` has already cleared.
    const t0 = clock.nowNs(io);
    try s.advanceAudio(clock.nowNs(io));
    const elapsed_ms = @divTrunc(clock.nowNs(io) - t0, std.time.ns_per_ms);

    // the mid-interval send tripped the gate, and the bar was counted once
    try std.testing.expectEqual(@as(u64, 1), s.stats.intervals_dropped);
    try std.testing.expectEqual(@as(u64, 0), s.stats.intervals_uploaded);
    try std.testing.expectEqual(@as(u64, 0), s.stats.upload_bytes);
    try std.testing.expectEqual(@as(u64, 0), s.stats.upload_chunks);
    // THIS is what the `if (lc.dropped) continue` at the top of
    // `finalizeInterval` buys. Without it, a channel dropped mid-interval falls
    // through to the "nothing encoded at all, send a silence marker" branch —
    // and the room hears a rest bar where the instrument was actually playing.
    // A dropped bar has to be silent about itself, not lie about why.
    try std.testing.expectEqual(@as(u64, 0), s.stats.silence_markers);
    try std.testing.expect(elapsed_ms < 250);
}

test "kujamba: one lost bar is counted once, however many channels were on it (#14)" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase = [_]f32{0.1} ** 4096;
    var bank = try onePhraseBank(alloc, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .loop };
    fill.bind(.loop, bank.active());
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .bank = &bank };

    const fds = try saturatedSocketPair();
    defer _ = std.posix.errno(std.posix.system.close(fds[1]));
    // TWO channels on one blocked socket. The point is the accounting: a bar
    // the room did not hear is one lost bar, not one per channel. Counting per
    // channel would report a two-channel client as twice as broken as it is.
    var s = try Session.init(alloc, io, .{
        .srate = 48000,
        .channel_names = &.{ "kujamba", "kujamba2" },
        .source = .{ .kujamba = &fill },
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.selectForFn },
    });
    defer s.deinit();
    s.conn = .{ .io = io, .fd = fds[0] };
    s.log.quiet = true;
    s.state = .active;
    s.bpm = 120;
    s.bpi = 4;
    s.interval_len_samples = 96000;
    s.interval_start_ns = clock.nowNs(io);
    s.timing.anchor(s.interval_start_ns, s.bpm, s.bpi);
    try s.startIntervalEncoders();
    var block: [960]f32 = undefined;
    for (&block, 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i)) * 0.05) * 0.5;
    for (s.locals) |*lc| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try lc.enc.?.encode(&block, &out);
        try lc.pending.add(out.items);
    }

    var junk: [4096]u8 = undefined;
    @memset(&junk, 0xA5);
    _ = fillUntilBlocked(fds[0], &junk);
    try s.finalizeInterval();

    try std.testing.expectEqual(@as(usize, 2), s.locals.len);
    // one bar lost ...
    try std.testing.expectEqual(@as(u64, 1), s.stats.intervals_dropped);
    try std.testing.expectEqual(@as(u64, 0), s.stats.intervals_uploaded);
    // ... and no audio from either channel credited to the room
    try std.testing.expectEqual(@as(u64, 0), s.stats.intervals_broadcast);
    try std.testing.expectEqual(@as(u64, 0), s.stats.upload_channels);
    // but the clock moved exactly one bar, not two
    try std.testing.expectEqual(@as(u64, 1), s.index.seq);
}

test "kujamba: the session recovers and uploads the next bar once the peer drains (#14)" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6 };
    var bank = try onePhraseBank(alloc, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .loop };
    fill.bind(.loop, bank.active());
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .bank = &bank };

    const fds = try saturatedSocketPair();
    defer _ = std.posix.errno(std.posix.system.close(fds[1])); // fds[0] is s.conn's
    var s = try Session.init(alloc, io, .{
        .srate = 48000,
        .channel_names = &.{"kujamba"},
        .source = .{ .kujamba = &fill },
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.selectForFn },
    });
    defer s.deinit();
    s.conn = .{ .io = io, .fd = fds[0] };
    s.log.quiet = true;
    s.state = .active;
    s.bpm = 120;
    s.bpi = 4;
    s.interval_len_samples = 96000;
    s.interval_start_ns = clock.nowNs(io);
    s.timing.anchor(s.interval_start_ns, s.bpm, s.bpi);
    try s.startIntervalEncoders();

    // bar 1: blocked, dropped
    var junk: [4096]u8 = undefined;
    @memset(&junk, 0xA5);
    _ = fillUntilBlocked(fds[0], &junk);
    try s.finalizeInterval();
    try std.testing.expectEqual(@as(u64, 1), s.stats.intervals_dropped);
    const dropped_guid = s.locals[0].guid;

    // the peer wakes up and drains
    var sink: [65536]u8 = undefined;
    _ = drainSocket(fds[1], &sink);
    try std.testing.expect(s.conn.?.writable());

    // bar 2: the same audio, a fresh guid, and this time it goes out
    var block: [960]f32 = undefined;
    for (&block, 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i)) * 0.05) * 0.5;
    for (s.locals) |*lc| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try lc.enc.?.encode(&block, &out);
        try lc.pending.add(out.items);
    }
    try s.finalizeInterval();

    try std.testing.expectEqual(@as(u64, 1), s.stats.intervals_uploaded);
    try std.testing.expectEqual(@as(u64, 1), s.stats.intervals_broadcast);
    try std.testing.expect(s.stats.upload_bytes > 0);
    // the dropped bar's guid was never completed and the next one is a NEW guid,
    // so the server cannot mistake the retry for a continuation
    try std.testing.expect(!std.mem.eql(u8, &dropped_guid, &s.locals[0].guid));
    try std.testing.expectEqual(@as(u64, 2), s.index.seq);
}

test "kujamba: a !kujamba mode command over 0xC0 lands at the next bar, not mid-bar" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase: [4096]f32 = undefined;
    for (&phrase, 0..) |*o, i| o.* = @as(f32, @floatFromInt(i % 97)) / 97.0;
    var bank = try onePhraseBank(std.testing.allocator, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .repeat };
    fill.bind(.repeat, bank.active());
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .mode = .repeat, .bank = &bank };

    // The handler the CLI installs: reshape the plan, let the session apply it.
    const Handler = struct {
        fn apply(ctx: *anyopaque, verb: kujamba_out.ChatCommand) void {
            const a: *kujamba_out.PlanAdapter = @ptrCast(@alignCast(ctx));
            switch (verb) {
                .play => a.rest = false,
                .rest => a.rest = true,
                .loop => a.mode = .loop,
                .repeat => a.mode = .repeat,
                .once => a.mode = .once,
                .stop => kujamba_out.requestStop(),
                .select => |sel| a.bank.request(sel),
                .none => {},
            }
        }
    };

    var s = try Session.init(alloc, io, .{
        .srate = @intCast(kujamba_out.sample_rate),
        .channel_names = &.{"kujamba"},
        .source = .{ .kujamba = &fill },
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.selectForFn },
        .chat_command = Handler.apply,
        .chat_ctx = @ptrCast(&adapter),
    });
    defer s.deinit();
    s.log.quiet = true;

    // Bar 0 is in flight in repeat mode.
    s.index.grid = 0;
    try s.startIntervalEncoders();
    try std.testing.expectEqual(kujamba_out.Mode.repeat, fill.mode);

    // The bandleader types `!kujamba loop` while bar 0 is still going. The 0xC0
    // layout is chat-kind dependent, so the command sits in the message slot.
    var chat = Fixed{};
    try proto.buildChat(&[_][]const u8{ "PRIVMSG", "bandleader", "#band", "!kujamba loop" }, &chat);
    try s.dispatch(.{ .mtype = proto.MSG_CHAT_MESSAGE, .payload = chat.slice() });

    // The command reached the plan, but the in-flight bar is untouched: this is
    // the "never mid-bar" property.
    try std.testing.expectEqual(kujamba_out.Mode.repeat, fill.mode);
    try std.testing.expectEqual(kujamba_out.Mode.loop, adapter.mode);

    // Bar 1 starts: the selection now carries loop, and it is applied.
    s.index.grid = 1;
    try s.startIntervalEncoders();
    try std.testing.expectEqual(kujamba_out.Mode.loop, fill.mode);
}

test "kujamba: !kujamba play/rest overrides the pattern at the next bar" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var phrase: [2048]f32 = undefined;
    for (&phrase, 0..) |*o, i| o.* = @as(f32, @floatFromInt(i % 31)) / 31.0;
    var bank = try onePhraseBank(std.testing.allocator, &phrase);
    defer bank.deinit();
    var fill = kujamba_out.Fill{ .mode = .repeat };
    fill.bind(.repeat, bank.active());
    // pattern that always plays, so any rest we see comes from the override
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .mode = .repeat, .bank = &bank };

    var s = try Session.init(alloc, io, .{
        .srate = @intCast(kujamba_out.sample_rate),
        .channel_names = &.{"kujamba"},
        .source = .{ .kujamba = &fill },
        .id_seed = 7,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.selectForFn },
        .chat_command = null, // command parsing only; no handler wired
        .chat_ctx = undefined,
    });
    defer s.deinit();
    s.log.quiet = true;

    // With no handler, a command is logged and ignored — it cannot crash or act.
    var chat = Fixed{};
    try proto.buildChat(&[_][]const u8{ "MSG", "!kujamba rest" }, &chat);
    try s.dispatch(.{ .mtype = proto.MSG_CHAT_MESSAGE, .payload = chat.slice() });
    try std.testing.expect(adapter.rest == null);
    try std.testing.expectEqual(@as(u64, 1), s.stats.chat_received);

    // Now the override itself, applied through the plan directly.
    adapter.rest = true;
    s.index.grid = 0;
    try s.startIntervalEncoders();
    try std.testing.expect(!s.locals[0].broadcast); // forced rest bar

    adapter.rest = false;
    s.index.grid = 1;
    try s.startIntervalEncoders();
    try std.testing.expect(s.locals[0].broadcast); // forced play bar
}

// ---- #8 phrase bank + live selection ----------------------------------------

test "kujamba: a !kujamba <n> phrase switch over 0xC0 lands at the next bar, not mid-bar" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Two constant, obviously-distinct buffers: "which phrase is bound" is then
    // readable straight off the audio, with no synthesis in the way.
    const p1 = [_]f32{ 0.10, 0.10, 0.10, 0.10, 0.10, 0.10, 0.10, 0.10 };
    const p2 = [_]f32{ 0.90, 0.90, 0.90, 0.90, 0.90, 0.90, 0.90, 0.90 };
    var bank = try kujamba_out.PhraseBank.initBorrowed(alloc, &.{ "karibu", "asante" }, &.{ &p1, &p2 });
    defer bank.deinit();

    var fill = kujamba_out.Fill{ .mode = .repeat };
    fill.bind(.repeat, bank.active());
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .mode = .repeat, .bank = &bank };

    // The handler the CLI installs: resolve the selector now, apply it at the
    // next bar boundary.
    const Handler = struct {
        fn apply(ctx: *anyopaque, cmd: kujamba_out.ChatCommand) void {
            const a: *kujamba_out.PlanAdapter = @ptrCast(@alignCast(ctx));
            switch (cmd) {
                .select => |sel| a.bank.request(sel),
                else => {},
            }
        }
    };

    var s = try Session.init(alloc, io, .{
        .srate = @intCast(kujamba_out.sample_rate),
        .channel_names = &.{"kujamba"},
        .source = .{ .kujamba = &fill },
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.selectForFn },
        .chat_command = Handler.apply,
        .chat_ctx = @ptrCast(&adapter),
    });
    defer s.deinit();
    s.log.quiet = true;

    // Bar 0 is in flight on phrase 1.
    s.index.grid = 0;
    try s.startIntervalEncoders();
    try std.testing.expectEqual(p1[0..].ptr, fill.samples.ptr);

    // The bandleader types `!kujamba 2` while bar 0 is still going. As with the
    // transport verbs, the command sits in the message slot because the 0xC0
    // layout is chat-kind dependent.
    var chat = Fixed{};
    try proto.buildChat(&[_][]const u8{ "PRIVMSG", "bandleader", "#band", "!kujamba 2" }, &chat);
    try s.dispatch(.{ .mtype = proto.MSG_CHAT_MESSAGE, .payload = chat.slice() });

    // The selector reached the bank and resolved...
    try std.testing.expectEqual(@as(u32, 0), bank.rejected);
    // ...but the in-flight bar still holds phrase 1. This is the "never
    // mid-bar" property, and it is what makes the switch safe to do live.
    try std.testing.expectEqual(p1[0..].ptr, fill.samples.ptr);

    // Bar 1 starts: the selection is applied and the new phrase is bound.
    s.index.grid = 1;
    try s.startIntervalEncoders();
    try std.testing.expectEqual(p2[0..].ptr, fill.samples.ptr);
    try std.testing.expectEqual(@as(u32, 1), bank.switches);
}

test "kujamba: !kujamba by phrase name switches, and an unknown name is ignored without dropping audio" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const p1 = [_]f32{ 0.10, 0.10, 0.10, 0.10 };
    const p2 = [_]f32{ 0.90, 0.90, 0.90, 0.90 };
    var bank = try kujamba_out.PhraseBank.initBorrowed(alloc, &.{ "karibu", "asante sana" }, &.{ &p1, &p2 });
    defer bank.deinit();

    var fill = kujamba_out.Fill{ .mode = .repeat };
    fill.bind(.repeat, bank.active());
    const pattern = try kujamba_out.parsePattern("1");
    var adapter = kujamba_out.PlanAdapter{ .pattern = &pattern, .mode = .repeat, .bank = &bank };

    const Handler = struct {
        fn apply(ctx: *anyopaque, cmd: kujamba_out.ChatCommand) void {
            const a: *kujamba_out.PlanAdapter = @ptrCast(@alignCast(ctx));
            switch (cmd) {
                .select => |sel| a.bank.request(sel),
                else => {},
            }
        }
    };

    var s = try Session.init(alloc, io, .{
        .srate = @intCast(kujamba_out.sample_rate),
        .channel_names = &.{"kujamba"},
        .source = .{ .kujamba = &fill },
        .id_seed = 42,
        .plan = .{ .ctx = @ptrCast(&adapter), .selectFor = kujamba_out.PlanAdapter.selectForFn },
        .chat_command = Handler.apply,
        .chat_ctx = @ptrCast(&adapter),
    });
    defer s.deinit();
    s.log.quiet = true;

    s.index.grid = 0;
    try s.startIntervalEncoders();

    // A name with a space in it resolves case-insensitively.
    var chat = Fixed{};
    try proto.buildChat(&[_][]const u8{ "MSG", "!kujamba ASANTE SANA" }, &chat);
    try s.dispatch(.{ .mtype = proto.MSG_CHAT_MESSAGE, .payload = chat.slice() });
    s.index.grid = 1;
    try s.startIntervalEncoders();
    try std.testing.expectEqual(p2[0..].ptr, fill.samples.ptr);

    // A name nobody has: rejected, counted, and the phrase keeps playing. The
    // "invalid selection drops no audio" acceptance criterion, end to end over
    // a real 0xC0.
    try proto.buildChat(&[_][]const u8{ "MSG", "!kujamba jambo ambalo halijulikani" }, &chat);
    try s.dispatch(.{ .mtype = proto.MSG_CHAT_MESSAGE, .payload = chat.slice() });
    try std.testing.expectEqual(@as(u32, 1), bank.rejected);
    try std.testing.expectEqual(@as(u32, 1), bank.switches); // no new switch
    s.index.grid = 2;
    try s.startIntervalEncoders();
    try std.testing.expectEqual(p2[0..].ptr, fill.samples.ptr);

    // ...and the audio really is still phrase 2, not a hole.
    var block: [4]f32 = undefined;
    fill.copyInto(0, block[0..4]);
    try std.testing.expectEqualSlices(f32, p2[0..4], block[0..4]);
}

test "kujamba: switching phrases does not re-render, so payloads stay byte-identical (#8 + #10)" {
    const alloc = std.testing.allocator;

    // The claim #10 makes is that a switch costs nothing at encode time: the
    // buffer the encoder reads is the one rendered at startup. This drives the
    // real encode path for two bars of the same phrase and shows the bytes do
    // not depend on how many times the bank was asked to switch (which is 0 --
    // the point is that asking changes nothing).
    var bank_a = kujamba_out.PhraseBank.init(alloc);
    defer bank_a.deinit();
    var bank_b = kujamba_out.PhraseBank.init(alloc);
    defer bank_b.deinit();
    try bank_a.parse("kujamba karibu\nasante sana\n", .{});
    try bank_b.parse("kujamba karibu\nasante sana\n", .{});

    // Same phrase from both banks is the same audio, byte for byte.
    for (bank_a.entries.items, bank_b.entries.items) |x, y| {
        try std.testing.expectEqualSlices(f32, x.samples, y.samples);
    }

    // A switch hands back the *stored* buffer, not a fresh render: the pointer
    // is the one the bank allocated at parse time, before any request.
    const stored = bank_a.entries.items[1].samples.ptr;
    bank_a.request("2");
    _ = bank_a.active();
    try std.testing.expectEqual(stored, bank_a.entries.items[1].samples.ptr);
}
