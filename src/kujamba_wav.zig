//! kujamba_wav.zig — the `kujamba join --wav` input path (#98).
//!
//! A pre-rendered WAV stands in for the synth phrase: parsed once at startup
//! into the same mono-f32 bank entry a phrase render produces, then played
//! through the same `Fill`/`PhraseBank` grid machinery — `repeat`/`loop`/`once`
//! and `--pattern` behave exactly as they do for a synthesized phrase.
//! `--wav-reload` re-stats the file at every bar boundary and re-reads it when
//! it changed, so a studio pipeline can re-render the loop while a session is
//! running.
//!
//! Input contract — deliberately narrow; this is an instrument input, not a
//! media player:
//!
//!  - RIFF/WAVE (little-endian RIFF; RIFX/RF64 rejected by the tag check)
//!  - PCM only (format tag 1 — float tag 3, extensible 0xFFFE, and everything
//!    else are rejected)
//!  - 16-bit samples, the session's 44.1 kHz
//!  - one or two channels; stereo is downmixed (L+R)/2 into mono f32
//!  - canonical chunk order: `fmt ` before `data` — a `data` chunk that
//!    arrives before `fmt ` cannot be interpreted anyway, so it is an error
//!    rather than a guess
//!  - a `data` chunk that declares bytes past EOF is a truncated file
//!
//! Chunks this parser does not know (LIST, cue, bext, ...) are skipped, as
//! RIFF requires. The RIFF size field is advisory and ignored — the real
//! bound is the buffer's own length.

const std = @import("std");
const kujamba_out = @import("ninjam_out.zig");
const logmod = @import("ninjam/log.zig");

/// The session's sample rate — the only rate --wav accepts. Re-exported so
/// this file's contract is readable without reaching through imports.
pub const sample_rate: u32 = kujamba_out.sample_rate;

/// The largest file `loadFile` will read. Stereo 16-bit costs 4 bytes of file
/// per bank sample, so a data chunk past `4 * max_bank_samples` could never
/// fit the audio budget anyway — failing fast keeps a multi-GB accidental
/// `--wav` from being slurped just to be rejected.
pub const max_file_bytes: u64 = 4 * @as(u64, kujamba_out.max_bank_samples) + 4096;

pub const Error = error{
    /// smaller than a RIFF header, or the RIFF/WAVE tags are wrong
    NotWav,
    /// ran off the end of the file mid-chunk, or a chunk (including `data`)
    /// declares bytes past EOF
    Truncated,
    /// a `fmt ` chunk too short to hold the fixed PCM fields (< 16 bytes)
    BadFmt,
    /// no `fmt ` chunk at all
    MissingFmt,
    /// a `data` chunk arrived before `fmt ` — canonical writers emit fmt
    /// first, and decoding without the format would be a guess
    DataBeforeFmt,
    /// not PCM (format tag 1): float (3), extensible (0xFFFE), ADPCM, ...
    NotPcm,
    /// not 16-bit samples
    BadBitDepth,
    /// not mono or stereo
    BadChannels,
    /// not 44.1 kHz
    BadSampleRate,
    /// fmt was fine but no `data` chunk ever arrived
    MissingData,
    /// the file is bigger than `max_file_bytes` — guaranteed over budget
    FileTooLarge,
    /// open/stat/read failed; `Diag` carries the underlying error name
    ReadFailed,
    OutOfMemory,
};

/// Human-readable detail for the last error. Same shape as the config
/// loader's Diag: every failing return fills it, and the caller prints
/// `<file>: <message>`.
pub const Diag = struct {
    buf: [192]u8 = undefined,
    len: usize = 0,

    fn fail(self: *Diag, e: Error, comptime fmt: []const u8, args: anytype) Error {
        const msg = std.fmt.bufPrint(&self.buf, fmt, args) catch "message too long";
        self.len = msg.len;
        return e;
    }

    pub fn message(self: *const Diag) []const u8 {
        return self.buf[0..self.len];
    }
};

/// The error text for a failed `parse`/`loadFile`: the Diag's message when it
/// was filled, else the bare error name (OOM and friends need no prose).
pub fn describe(diag: *const Diag, e: Error) []const u8 {
    return if (diag.len > 0) diag.message() else @errorName(e);
}

/// What the file looked like when it was last read. `check` compares stat
/// results against it, so the common case — an untouched file — costs one
/// stat call per bar and nothing else.
///
/// `inode`/`ctime` ride along because they are free (same `statFile` result)
/// and catch the one case mtime+size can miss: an atomic temp+rename whose
/// writer carried the old mtime over. The documented limitation stands either
/// way — a writer that preserves mtime *and* ctime on the same inode
/// (in-place writes with a restored timestamp) can still slip through.
/// Callers replace atomically, so this is belt-and-braces, not a promise.
pub const Stamp = struct {
    size: u64,
    mtime_ns: i96,
    ctime_ns: i96,
    /// INode is platform-typed (i64 on Windows, u64 on POSIX, void on bare
    /// targets); storing it raw keeps every platform's identity check sound.
    inode: std.Io.File.INode,

    pub fn of(st: std.Io.File.Stat) Stamp {
        return .{
            .size = st.size,
            .mtime_ns = st.mtime.nanoseconds,
            .ctime_ns = st.ctime.nanoseconds,
            .inode = st.inode,
        };
    }

    pub fn eql(a: Stamp, b: Stamp) bool {
        return a.size == b.size and a.mtime_ns == b.mtime_ns and
            a.ctime_ns == b.ctime_ns and a.inode == b.inode;
    }
};

/// The result of `loadFile`: decoded mono f32 plus the stamp of the file as
/// it was actually read (from `fstat` on the open handle, not a second
/// `statFile` — the stamp describes these very bytes, even if the file was
/// swapped again a microsecond later).
pub const Loaded = struct {
    samples: []f32,
    stamp: Stamp,
};

/// Decode a RIFF/WAVE PCM s16le buffer into mono f32 at session rate.
///
/// `parse` is deliberately raw: it does NOT apply the loop-tail fade — that
/// is a playback policy, baked in by `loadFile`, so a caller comparing
/// decoded samples sees exactly what the file held.
pub fn parse(alloc: std.mem.Allocator, bytes: []const u8, diag: *Diag) Error![]f32 {
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or
        !std.mem.eql(u8, bytes[8..12], "WAVE"))
        return diag.fail(error.NotWav, "not a RIFF/WAVE file", .{});

    var pos: usize = 12;
    var fmt_seen = false;
    var tag: u16 = 0;
    var channels: u16 = 0;
    var rate: u32 = 0;
    var bits: u16 = 0;
    var data: ?[]const u8 = null;
    while (pos + 8 <= bytes.len) {
        const id = bytes[pos..][0..4];
        const size: usize = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
        pos += 8;
        if (size > bytes.len - pos)
            return diag.fail(error.Truncated, "chunk '{s}' declares {d} bytes, only {d} remain", .{ id, size, bytes.len - pos });
        const payload = bytes[pos .. pos + size];
        pos += size + (size & 1); // RIFF payloads pad to even
        if (std.mem.eql(u8, id, "fmt ")) {
            if (payload.len < 16)
                return diag.fail(error.BadFmt, "fmt chunk is {d} bytes (want >= 16)", .{payload.len});
            tag = std.mem.readInt(u16, payload[0..2], .little);
            channels = std.mem.readInt(u16, payload[2..4], .little);
            rate = std.mem.readInt(u32, payload[4..8], .little);
            bits = std.mem.readInt(u16, payload[14..16], .little);
            fmt_seen = true;
        } else if (std.mem.eql(u8, id, "data")) {
            if (!fmt_seen)
                return diag.fail(error.DataBeforeFmt, "data chunk before fmt — format unknown", .{});
            // first data chunk wins; a second one is not a file this
            // instrument has a meaning for
            if (data == null) data = payload;
        }
        // every other chunk id is skipped, as RIFF requires
    }
    if (!fmt_seen) return diag.fail(error.MissingFmt, "no fmt chunk", .{});
    if (tag != 1) return diag.fail(error.NotPcm, "not PCM (format tag {d})", .{tag});
    if (bits != 16) return diag.fail(error.BadBitDepth, "{d}-bit samples (want 16)", .{bits});
    if (channels != 1 and channels != 2)
        return diag.fail(error.BadChannels, "{d} channels (want mono or stereo)", .{channels});
    if (rate != sample_rate)
        return diag.fail(error.BadSampleRate, "{d} Hz (want {d})", .{ rate, sample_rate });
    const d = data orelse return diag.fail(error.MissingData, "no data chunk", .{});

    // Decode whole frames only: a trailing partial frame (odd byte count on
    // stereo) is dropped rather than half-read.
    const frame_bytes: usize = @as(usize, channels) * 2;
    const out = try alloc.alloc(f32, d.len / frame_bytes);
    errdefer alloc.free(out);
    if (channels == 1) {
        for (out, 0..) |*o, i| {
            const s = std.mem.readInt(i16, d[2 * i ..][0..2], .little);
            o.* = @as(f32, @floatFromInt(s)) / 32768.0;
        }
    } else {
        for (out, 0..) |*o, i| {
            const l = std.mem.readInt(i16, d[4 * i ..][0..2], .little);
            const r = std.mem.readInt(i16, d[4 * i + 2 ..][0..2], .little);
            o.* = (@as(f32, @floatFromInt(l)) + @as(f32, @floatFromInt(r))) / 65536.0;
        }
    }
    return out;
}

/// Read `path` (relative to `dir`) and decode it. The tail fade is applied
/// here — the same `applyTailFade` every synth render gets — so a loop wrap
/// or an interval tail lands on silence instead of clicking on a WAV whose
/// edges were not recorded to zero.
pub fn loadFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    diag: *Diag,
) Error!Loaded {
    const f = dir.openFile(io, path, .{}) catch |e|
        return diag.fail(error.ReadFailed, "cannot open: {s}", .{@errorName(e)});
    defer f.close(io);
    const st = f.stat(io) catch |e|
        return diag.fail(error.ReadFailed, "cannot stat: {s}", .{@errorName(e)});
    if (st.size > max_file_bytes)
        return diag.fail(error.FileTooLarge, "{d} bytes — past the {d}-byte sanity cap", .{ st.size, max_file_bytes });
    const data = alloc.alloc(u8, @intCast(st.size)) catch return error.OutOfMemory;
    defer alloc.free(data);
    const got = f.readPositionalAll(io, data, 0) catch |e|
        return diag.fail(error.ReadFailed, "cannot read: {s}", .{@errorName(e)});
    const samples = try parse(alloc, data[0..got], diag);
    kujamba_out.applyTailFade(samples);
    return .{ .samples = samples, .stamp = .of(st) };
}

/// The `--wav-reload` driver (#98). The plan adapter calls `check` once per
/// bar through its `boundary_hook` — before any audio for the bar, rest bars
/// and tempo-change re-anchors included — so a changed file takes effect on a
/// grid boundary, never mid-bar.
///
/// The check is stat-first: an untouched file costs one `statFile` call and
/// nothing else. A changed file is re-read and parsed *synchronously on the
/// audio path* — it can eat into the encode-lead margin, which is fine for
/// the studio use case (reloaded files are small) and is why the flag is
/// opt-in. A failed re-read — unreadable, unparseable, or over-budget — keeps
/// the previous buffer, counts `reload_failed`, writes one transcript line,
/// and never drops the interval.
///
/// Callers must replace the file atomically (write a temp file, rename over
/// the path). An in-place rewrite can be observed halfway through; the failed
/// parse keeps the old audio but the torn file is what the room did not hear.
pub const Reloader = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    /// borrowed — argv or the arena outlives the session
    path: []const u8,
    bank: *kujamba_out.PhraseBank,
    /// which entry holds the wav (0 for the normal one-file bank)
    index: usize,
    /// fingerprint of the file as last successfully loaded
    stamp: Stamp,
    /// re-reads that produced new audio (RESULT `wav_reloads`)
    reloads: u32 = 0,
    /// changed-or-lost files that failed to (re)load; previous audio kept
    /// (RESULT `wav_reload_failed`)
    reload_failed: u32 = 0,
    /// file reads actually attempted — so a test can see that an unchanged
    /// file cost its one stat and no re-read
    reads: u32 = 0,
    /// transcript sink; null in tests means count-only
    log: ?*logmod.Log = null,
    diag: Diag = .{},

    /// `PlanAdapter.BoundaryHook` entry point.
    pub fn boundaryHook(ctx: *anyopaque, fill: ?*kujamba_out.Fill) void {
        const self: *Reloader = @ptrCast(@alignCast(ctx));
        self.check(fill);
    }

    /// One bar-boundary check: stat, and re-read only if the fingerprint
    /// moved. Never fails — every outcome leaves the session with a playable
    /// buffer and a counters bump at most.
    pub fn check(self: *Reloader, fill: ?*kujamba_out.Fill) void {
        const st = self.dir.statFile(self.io, self.path, .{}) catch |e| {
            // Cannot even say whether it changed — the safe reading is that a
            // reload was due and failed. This is what a deleted file reports.
            self.noteFailure("cannot stat: {s}", .{@errorName(e)});
            return;
        };
        const stamp = Stamp.of(st);
        if (stamp.eql(self.stamp)) return;

        self.reads += 1;
        self.diag.len = 0;
        const loaded = loadFile(self.alloc, self.io, self.dir, self.path, &self.diag) catch |e| {
            self.noteFailure("{s}", .{describe(&self.diag, e)});
            return;
        };
        self.bank.replaceBuffer(self.index, loaded.samples, fill) catch {
            // the only failure is BankTooLarge; the new buffer was already
            // freed and the old audio still stands
            self.noteFailure("{d} samples would exceed the audio budget", .{loaded.samples.len});
            return;
        };
        self.stamp = loaded.stamp;
        self.reloads += 1;
        if (self.log) |l| {
            const secs = @as(f64, @floatFromInt(loaded.samples.len)) / @as(f64, @floatFromInt(sample_rate));
            l.line("wav reload {s}: {d} samples ({d:.3}s)", .{ self.path, loaded.samples.len, secs });
        }
    }

    fn noteFailure(self: *Reloader, comptime fmt: []const u8, args: anytype) void {
        self.reload_failed += 1;
        if (self.log) |l|
            l.line("wav reload failed {s}: " ++ fmt ++ " — keeping previous audio", .{self.path} ++ args);
    }
};

// --------------------------------------------------------------------------
// tests
// --------------------------------------------------------------------------

const testing = std.testing;
const synth = @import("synth.zig");

/// Build a WAV byte buffer with the given fmt fields — the tests drive every
/// rejection through real bytes, not through the parser's own helpers.
fn wavBytes(
    buf: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    tag: u16,
    channels: u16,
    rate: u32,
    bits: u16,
    pcm: []const u8,
) !void {
    try buf.appendSlice(alloc, "RIFF");
    try buf.appendSlice(alloc, std.mem.asBytes(&@as(u32, @intCast(36 + pcm.len))));
    try buf.appendSlice(alloc, "WAVE");
    try buf.appendSlice(alloc, "fmt ");
    try buf.appendSlice(alloc, std.mem.asBytes(&@as(u32, 16)));
    const bytes_per: u32 = @intCast(@divExact(bits, 8));
    const byte_rate: u32 = rate * @as(u32, channels) * bytes_per;
    const block_align: u16 = channels * @as(u16, @intCast(bytes_per));
    try buf.appendSlice(alloc, std.mem.asBytes(&tag));
    try buf.appendSlice(alloc, std.mem.asBytes(&channels));
    try buf.appendSlice(alloc, std.mem.asBytes(&rate));
    try buf.appendSlice(alloc, std.mem.asBytes(&byte_rate));
    try buf.appendSlice(alloc, std.mem.asBytes(&block_align));
    try buf.appendSlice(alloc, std.mem.asBytes(&bits));
    try buf.appendSlice(alloc, "data");
    try buf.appendSlice(alloc, std.mem.asBytes(&@as(u32, @intCast(pcm.len))));
    try buf.appendSlice(alloc, pcm);
}

test "parse: a mono s16 WAV decodes sample-for-sample" {
    const alloc = testing.allocator;
    const pcm = [_]i16{ 0, 16384, -16384, 32767, -32768 };
    const pcm_bytes = std.mem.sliceAsBytes(&pcm);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(alloc);
    try wavBytes(&bytes, alloc, 1, 1, 44100, 16, pcm_bytes);

    var diag = Diag{};
    const out = try parse(alloc, bytes.items, &diag);
    defer alloc.free(out);
    try testing.expectEqual(@as(usize, 5), out.len);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.5), out[2], 1e-6);
    // full-scale ends land on ±(32767|32768)/32768 — the same scaling the
    // synth render path uses
    try testing.expectApproxEqAbs(@as(f32, 32767.0 / 32768.0), out[3], 1e-7);
    try testing.expectEqual(@as(f32, -1.0), out[4]);
}

test "parse: stereo is downmixed (L+R)/2" {
    const alloc = testing.allocator;
    // interleaved L,R pairs
    const frames = [_]i16{ 2000, 1000, -2000, -1000, 0, 32767 };
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(alloc);
    try wavBytes(&bytes, alloc, 1, 2, 44100, 16, std.mem.sliceAsBytes(&frames));

    var diag = Diag{};
    const out = try parse(alloc, bytes.items, &diag);
    defer alloc.free(out);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectApproxEqAbs(@as(f32, 1500.0 / 32768.0), out[0], 1e-7);
    try testing.expectApproxEqAbs(@as(f32, -1500.0 / 32768.0), out[1], 1e-7);
    try testing.expectApproxEqAbs(@as(f32, 32767.0 / 65536.0), out[2], 1e-7);
}

test "parse: rejects other rates, bit depths, channel counts and float" {
    const alloc = testing.allocator;
    const pcm: [4]i16 = @splat(0);
    const pcm_bytes = std.mem.sliceAsBytes(&pcm);
    var diag = Diag{};

    for ([_]u32{ 22050, 48000 }) |rate| {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(alloc);
        try wavBytes(&bytes, alloc, 1, 1, rate, 16, pcm_bytes);
        diag.len = 0;
        try testing.expectError(error.BadSampleRate, parse(alloc, bytes.items, &diag));
    }
    inline for (.{ .{ 8, 1 }, .{ 24, 1 }, .{ 32, 1 } }) |cfg| {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(alloc);
        try wavBytes(&bytes, alloc, 1, cfg[1], 44100, cfg[0], pcm_bytes);
        diag.len = 0;
        try testing.expectError(error.BadBitDepth, parse(alloc, bytes.items, &diag));
    }
    {
        // float WAV (format tag 3, 32-bit)
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(alloc);
        try wavBytes(&bytes, alloc, 3, 1, 44100, 32, pcm_bytes);
        diag.len = 0;
        try testing.expectError(error.NotPcm, parse(alloc, bytes.items, &diag));
    }
    {
        // quadraphonic is not a phrase
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(alloc);
        try wavBytes(&bytes, alloc, 1, 4, 44100, 16, pcm_bytes);
        diag.len = 0;
        try testing.expectError(error.BadChannels, parse(alloc, bytes.items, &diag));
    }
}

test "parse: truncated header and missing pieces are named, not crashed" {
    const alloc = testing.allocator;
    var diag = Diag{};

    try testing.expectError(error.NotWav, parse(alloc, "", &diag));
    diag.len = 0;
    try testing.expectError(error.NotWav, parse(alloc, "RIFF", &diag));
    diag.len = 0;
    try testing.expectError(error.NotWav, parse(alloc, "RIFX\x00\x00\x00\x00WAVE", &diag));
    diag.len = 0;
    try testing.expectError(error.NotWav, parse(alloc, "RIFF\x00\x00\x00\x00AVI ", &diag));

    // a fmt chunk and nothing else
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(alloc);
    try bytes.appendSlice(alloc, "RIFF\x00\x00\x00\x00WAVE");
    try bytes.appendSlice(alloc, "fmt ");
    try bytes.appendSlice(alloc, std.mem.asBytes(&@as(u32, 16)));
    try bytes.appendSlice(alloc, std.mem.asBytes(&@as(u16, 1)));
    try bytes.appendSlice(alloc, std.mem.asBytes(&@as(u16, 1)));
    try bytes.appendSlice(alloc, std.mem.asBytes(&@as(u32, 44100)));
    try bytes.appendSlice(alloc, std.mem.asBytes(&@as(u32, 88200)));
    try bytes.appendSlice(alloc, std.mem.asBytes(&@as(u16, 2)));
    try bytes.appendSlice(alloc, std.mem.asBytes(&@as(u16, 16)));
    diag.len = 0;
    try testing.expectError(error.MissingData, parse(alloc, bytes.items, &diag));

    // data declares bytes past EOF
    bytes.clearRetainingCapacity();
    try bytes.appendSlice(alloc, "RIFF\x00\x00\x00\x00WAVE");
    try bytes.appendSlice(alloc, "fmt ");
    try bytes.appendSlice(alloc, std.mem.asBytes(&@as(u32, 16)));
    try bytes.appendSlice(alloc, std.mem.asBytes(&@as(u16, 1)));
    try bytes.appendSlice(alloc, std.mem.asBytes(&@as(u16, 1)));
    try bytes.appendSlice(alloc, std.mem.asBytes(&@as(u32, 44100)));
    try bytes.appendSlice(alloc, std.mem.asBytes(&@as(u32, 88200)));
    try bytes.appendSlice(alloc, std.mem.asBytes(&@as(u16, 2)));
    try bytes.appendSlice(alloc, std.mem.asBytes(&@as(u16, 16)));
    try bytes.appendSlice(alloc, "data");
    try bytes.appendSlice(alloc, std.mem.asBytes(&@as(u32, 1000)));
    try bytes.appendSlice(alloc, "\x01\x02");
    diag.len = 0;
    try testing.expectError(error.Truncated, parse(alloc, bytes.items, &diag));

    // data before fmt: the format the data needs has not been seen
    bytes.clearRetainingCapacity();
    try bytes.appendSlice(alloc, "RIFF\x00\x00\x00\x00WAVE");
    try bytes.appendSlice(alloc, "data");
    try bytes.appendSlice(alloc, std.mem.asBytes(&@as(u32, 2)));
    try bytes.appendSlice(alloc, "\x01\x02\x00\x00"); // padded to even
    try bytes.appendSlice(alloc, "fmt ");
    try bytes.appendSlice(alloc, std.mem.asBytes(&@as(u32, 16)));
    try bytes.appendSlice(alloc, std.mem.asBytes(&@as(u16, 1)));
    try bytes.appendSlice(alloc, std.mem.asBytes(&@as(u16, 1)));
    try bytes.appendSlice(alloc, std.mem.asBytes(&@as(u32, 44100)));
    try bytes.appendSlice(alloc, std.mem.asBytes(&@as(u32, 88200)));
    try bytes.appendSlice(alloc, std.mem.asBytes(&@as(u16, 2)));
    try bytes.appendSlice(alloc, std.mem.asBytes(&@as(u16, 16)));
    diag.len = 0;
    try testing.expectError(error.DataBeforeFmt, parse(alloc, bytes.items, &diag));
}

test "parse: unknown chunks are skipped and a synth WAV round-trips" {
    const alloc = testing.allocator;
    const rendered = try synth.renderPhraseWav(alloc, "kujamba karibu");
    defer alloc.free(rendered);

    // a LIST chunk between fmt and data must not hide the data
    var with_list: std.ArrayList(u8) = .empty;
    defer with_list.deinit(alloc);
    try with_list.appendSlice(alloc, rendered[0..36]); // through fmt payload
    try with_list.appendSlice(alloc, "LIST");
    try with_list.appendSlice(alloc, std.mem.asBytes(&@as(u32, 5)));
    try with_list.appendSlice(alloc, "INFOx"); // 5 bytes + pad
    try with_list.appendSlice(alloc, "\x00");
    try with_list.appendSlice(alloc, rendered[36..]);

    var diag = Diag{};
    const a = try parse(alloc, rendered, &diag);
    defer alloc.free(a);
    const b = try parse(alloc, with_list.items, &diag);
    defer alloc.free(b);
    try testing.expectEqualSlices(f32, a, b);
    try testing.expect(a.len > 44100);
    try testing.expect(kujamba_out.rmsOf(a) > 0.01);
}

test "loadFile applies the loop-tail fade; parse does not" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // constant-loud WAV: without the fade the last sample would be full scale
    const pcm: [4096]i16 = @splat(16384);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(alloc);
    try wavBytes(&bytes, alloc, 1, 1, 44100, 16, std.mem.sliceAsBytes(&pcm));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(io, "loud.wav", .{});
    try f.writeStreamingAll(io, bytes.items);
    f.close(io);

    var diag = Diag{};
    const loaded = try loadFile(alloc, io, tmp.dir, "loud.wav", &diag);
    defer alloc.free(loaded.samples);
    try testing.expectEqual(@as(usize, 4096), loaded.samples.len);
    // the fade bakes the tail down; the head is untouched
    try testing.expectApproxEqAbs(@as(f32, 0.5), loaded.samples[0], 1e-6);
    try testing.expectApproxEqAbs(
        @as(f32, 0.5) * @as(f32, 1.0 / @as(f32, @floatFromInt(kujamba_out.tail_fade_samples))),
        loaded.samples[loaded.samples.len - 1],
        1e-6,
    );

    const raw = try parse(alloc, bytes.items, &diag);
    defer alloc.free(raw);
    try testing.expectApproxEqAbs(@as(f32, 0.5), raw[raw.len - 1], 1e-6);
}

test "loadFile: missing file reports, never panics" {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    var diag = Diag{};
    try testing.expectError(
        error.ReadFailed,
        loadFile(alloc, threaded.io(), std.Io.Dir.cwd(), "no-such-wav-file.wav", &diag),
    );
    try testing.expect(diag.message().len > 0);
}
