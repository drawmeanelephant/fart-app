//! Ogg Vorbis codec bindings.
//!  - Encoder: vendored libvorbis (vorbisenc), one mono VBR stream per local
//!    channel, matching the reference client (WDL/vorbisencdec.h).
//!  - Decoder: vendored stb_vorbis (single file), memory-buffer decode of one
//!    interval's accumulated Ogg stream.

const std = @import("std");

// ---- libogg/libvorbis extern surface (vendor/vorbis_enc_shim.c) -------------
//
// Zig 0.17 removed @cImport. The five encode-state structs (vorbis_info,
// vorbis_comment, vorbis_dsp_state, vorbis_block, ogg_stream_state) are
// caller-allocated with no size query, so they live inside the shim's
// zc_venc — the same pattern miniaudio_impl.c uses for audio.zig. Only
// ogg_page/ogg_packet cross the boundary as out-params; their layouts are
// mirrored below (ogg.h:26-47, 89-102) and have been ABI-stable upstream for
// decades.

const OggPage = extern struct {
    header: [*]u8,
    header_len: c_long,
    body: [*]u8,
    body_len: c_long,
};

const OggPacket = extern struct {
    packet: [*]u8,
    bytes: c_long,
    b_o_s: c_long,
    e_o_s: c_long,
    granulepos: i64,
    packetno: i64,
};

const Venc = opaque {};

extern fn zc_venc_create(rate: c_long, quality: f32, serial: c_int) ?*Venc;
extern fn zc_venc_destroy(e: ?*Venc) void;
extern fn zc_venc_headers(e: *Venc) void;
extern fn zc_venc_buffer(e: *Venc, samples: c_int) [*]f32;
extern fn zc_venc_wrote(e: *Venc, samples: c_int) void;
extern fn zc_venc_blockout(e: *Venc) c_int;
extern fn zc_venc_analysis(e: *Venc) void;
extern fn zc_venc_addblock(e: *Venc) void;
extern fn zc_venc_flushpacket(e: *Venc, op: *OggPacket) c_int;
extern fn zc_venc_packetin(e: *Venc, op: *const OggPacket) void;
extern fn zc_venc_pageout(e: *Venc, og: *OggPage) c_int;
extern fn zc_venc_flushpage(e: *Venc, og: *OggPage) c_int;

pub const EncodeError = error{
    InitFailed,
    OutOfMemory,
};

// ---- stb_vorbis extern surface (implementation in vendor/stb_vorbis_impl.c) ----

pub const stb_vorbis = opaque {};

/// Mirrors `stb_vorbis_alloc` (vendor/stb_vorbis.c:118). With a buffer set,
/// stb_vorbis allocates nothing on its own: setup memory is bump-allocated
/// from the front of the buffer, decode scratch from the back, and
/// `setup_free` is a documented no-op (stb_vorbis.c:965). That disarms the
/// #63 error path, where `vorbis_deinit` calls `free()` on pointers that
/// setup never malloc'd when it bails out partway.
const StbVorbisAlloc = extern struct {
    alloc_buffer: ?[*]u8 = null,
    alloc_buffer_length_in_bytes: c_int = 0,
};

/// `VORBIS_outofmem` from stb_vorbis's error enum (vendor/stb_vorbis.c:381).
/// In buffer mode it is the only way an open can fail with a memory problem:
/// every allocation site checks for exhaustion and reports this code.
const vorbis_outofmem: c_int = 3;

/// First buffer size offered to stb_vorbis. Legitimate NINJAM streams are
/// mono libvorbis intervals whose setup fits far inside this; stb_vorbis
/// checks at open time that setup + handle + decode scratch all fit, and
/// fails cleanly with VORBIS_outofmem when they don't, so we grow and retry.
const initial_decode_buffer = 256 * 1024;

/// Refusal ceiling: no legitimate NINJAM peer encoder comes near this. A
/// stream whose setup claims more is refused outright instead of decoded.
const max_decode_buffer = 16 * 1024 * 1024;

pub const StbVorbisInfo = extern struct {
    sample_rate: c_uint,
    channels: c_uint,
    setup_memory_required: c_uint,
    setup_temp_memory_required: c_uint,
    temp_memory_required: c_uint,
    max_frame_size: c_uint,
};

pub extern fn stb_vorbis_open_memory(data: [*]const u8, len: c_int, error_ret: *c_int, alloc: ?*const anyopaque) ?*stb_vorbis;
pub extern fn stb_vorbis_close(f: *stb_vorbis) void;
pub extern fn stb_vorbis_get_info(f: *stb_vorbis) StbVorbisInfo;
pub extern fn stb_vorbis_get_frame_float(f: *stb_vorbis, channels: *c_int, output: *[*][*]f32) c_int;

pub const Decoded = struct {
    alloc: std.mem.Allocator,
    srate: u32,
    channels: u32,
    /// interleaved f32, frames * channels
    pcm: []f32,

    pub fn deinit(self: *Decoded) void {
        self.alloc.free(self.pcm);
    }

    pub fn frames(self: *const Decoded) usize {
        if (self.channels == 0) return 0;
        return self.pcm.len / self.channels;
    }

    pub fn rms(self: *const Decoded) f64 {
        if (self.pcm.len == 0) return 0;
        var acc: f64 = 0;
        for (self.pcm) |s| acc += @as(f64, s) * @as(f64, s);
        return @sqrt(acc / @as(f64, @floatFromInt(self.pcm.len)));
    }
};

pub const DecodeError = error{ OpenFailed, OutOfMemory };

/// Decode a complete Ogg Vorbis stream (one interval's accumulated bytes).
///
/// The bytes can be anything a server put on the wire, so stb_vorbis never
/// runs in its malloc-backed mode here (#63): every allocation — including
/// everything the error paths free — lives in a caller-owned buffer, and a
/// stream whose setup doesn't fit fails with error.OpenFailed, not a wild
/// free().
pub fn decodeMemory(alloc: std.mem.Allocator, ogg: []const u8) DecodeError!Decoded {
    var buf_len: usize = initial_decode_buffer;
    while (true) {
        const buf = try alloc.alignedAlloc(u8, .@"16", buf_len);
        const va = StbVorbisAlloc{
            .alloc_buffer = buf.ptr,
            .alloc_buffer_length_in_bytes = @intCast(buf_len),
        };
        var err: c_int = 0;
        const v = stb_vorbis_open_memory(ogg.ptr, @intCast(ogg.len), &err, &va) orelse {
            alloc.free(buf);
            if (err == vorbis_outofmem and buf_len < max_decode_buffer) {
                buf_len *= 2;
                continue;
            }
            return error.OpenFailed;
        };
        // the decoder points into buf for its whole life, so it must be
        // closed before the buffer is freed — declare free first
        defer alloc.free(buf);
        defer stb_vorbis_close(v);
        const info = stb_vorbis_get_info(v);

        var out: std.ArrayList(f32) = .empty;
        errdefer out.deinit(alloc);

        var chans: c_int = 0;
        var outputs: [*][*]f32 = undefined;
        while (true) {
            const n = stb_vorbis_get_frame_float(v, &chans, &outputs);
            if (n == 0) break;
            const ch: usize = @intCast(chans);
            var i: usize = 0;
            while (i < @as(usize, @intCast(n))) : (i += 1) {
                var k: usize = 0;
                while (k < ch) : (k += 1) {
                    try out.append(alloc, outputs[k][i]);
                }
            }
        }
        return .{
            .alloc = alloc,
            .srate = @intCast(info.sample_rate),
            .channels = @intCast(info.channels),
            .pcm = try out.toOwnedSlice(alloc),
        };
    }
}

// ---- encoder -----------------------------------------------------------------

/// One mono Vorbis encoder per local channel per interval — mirrors the
/// reference client (fresh stream + headers per interval, random serial).
/// The ogg/vorbis state lives behind the vendor shim: `impl` is the C-side
/// zc_venc, and the loops below are the same ones this file always ran.
pub const Encoder = struct {
    alloc: std.mem.Allocator,
    impl: *Venc,

    pub fn create(alloc: std.mem.Allocator, srate: c_int, quality: f32, serial: u32) EncodeError!*Encoder {
        const self = alloc.create(Encoder) catch return error.OutOfMemory;
        errdefer alloc.destroy(self);

        const impl = zc_venc_create(srate, quality, @intCast(serial & 0x7FFFFFFF)) orelse
            return error.InitFailed;
        self.* = .{
            .alloc = alloc,
            .impl = impl,
        };
        return self;
    }

    pub fn destroy(self: *Encoder) void {
        zc_venc_destroy(self.impl);
        self.alloc.destroy(self);
    }

    fn takePages(self: *Encoder, use_flush: bool, out: *std.ArrayList(u8)) !void {
        var og: OggPage = undefined;
        while (true) {
            const got = if (use_flush) zc_venc_flushpage(self.impl, &og) else zc_venc_pageout(self.impl, &og);
            if (got != 1) break;
            try out.appendSlice(self.alloc, og.header[0..@intCast(og.header_len)]);
            try out.appendSlice(self.alloc, og.body[0..@intCast(og.body_len)]);
        }
    }

    fn drainBlocks(self: *Encoder, out: *std.ArrayList(u8)) !void {
        var op: OggPacket = undefined;
        while (zc_venc_blockout(self.impl) == 1) {
            zc_venc_analysis(self.impl);
            zc_venc_addblock(self.impl);
            while (zc_venc_flushpacket(self.impl, &op) == 1) {
                zc_venc_packetin(self.impl, &op);
                try self.takePages(false, out);
            }
        }
    }

    /// Emit the 3 Vorbis header pages (id/comment/setup) into `out`.
    pub fn writeHeaders(self: *Encoder, out: *std.ArrayList(u8)) !void {
        zc_venc_headers(self.impl);
        try self.takePages(true, out);
    }

    /// Encode `samples` (one mono channel) into `out` as Ogg page bytes.
    pub fn encode(self: *Encoder, samples: []const f32, out: *std.ArrayList(u8)) !void {
        if (samples.len == 0) return;
        const buf = zc_venc_buffer(self.impl, @intCast(samples.len));
        @memcpy(buf[0..samples.len], samples);
        zc_venc_wrote(self.impl, @intCast(samples.len));
        try self.drainBlocks(out);
    }

    /// Flush encoder state; emits remaining pages including the EOS page.
    pub fn flush(self: *Encoder, out: *std.ArrayList(u8)) !void {
        zc_venc_wrote(self.impl, 0);
        try self.drainBlocks(out);
        try self.takePages(true, out);
    }
};

// ==================================================================================
// tests
// ==================================================================================

const testing = std.testing;

test "vorbis encode -> decode roundtrip, non-silent" {
    const alloc = testing.allocator;
    const srate = 48000;
    const nsamples = 48000; // 1 second

    const enc = try Encoder.create(alloc, srate, 0.0, 12345);
    defer enc.destroy();

    var ogg: std.ArrayList(u8) = .empty;
    defer ogg.deinit(alloc);
    try enc.writeHeaders(&ogg);

    // 440 Hz sine at 0.5 amplitude, encoded in 960-sample blocks
    var block: [960]f32 = undefined;
    var i: usize = 0;
    while (i < nsamples) : (i += block.len) {
        for (&block, 0..) |*s, k| {
            const t = @as(f32, @floatFromInt(i + k)) / @as(f32, srate);
            s.* = 0.5 * @sin(2.0 * std.math.pi * 440.0 * t);
        }
        try enc.encode(&block, &ogg);
    }
    try enc.flush(&ogg);

    // the stream must start with an OggS capture pattern
    try testing.expect(ogg.items.len > 1000);
    try testing.expectEqualSlices(u8, "OggS", ogg.items[0..4]);

    var dec = try decodeMemory(alloc, ogg.items);
    defer dec.deinit();
    try testing.expectEqual(@as(u32, srate), dec.srate);
    try testing.expectEqual(@as(u32, 1), dec.channels);
    // decoded ~1s of audio; allow vorbis padding slack
    try testing.expect(dec.frames() > nsamples - 4800);
    // real signal energy: 0.5-amp sine -> rms ~= 0.3535
    const r = dec.rms();
    try testing.expect(r > 0.3);
}

// #63: a hostile server can flip one byte of an Ogg interval download and
// abort the client (stb_vorbis's malloc-backed error path frees pointers it
// never allocated). This is the auditor's minimised repro: 3889 deterministic
// bytes, one byte at offset 164 flipped 0x00 -> 0x80.
test "a corrupted Ogg is refused, not freed twice" {
    const alloc = std.testing.allocator;
    const enc = try Encoder.create(alloc, 44100, 0.0, 999);
    defer enc.destroy();
    var ogg: std.ArrayList(u8) = .empty;
    defer ogg.deinit(alloc);
    try enc.writeHeaders(&ogg);
    var block: [960]f32 = undefined;
    for (0..8) |i| {
        for (&block, 0..) |*s, k| {
            s.* = 0.4 * @sin(2.0 * std.math.pi * 220.0 * @as(f32, @floatFromInt(i * 960 + k)) / 44100.0);
        }
        try enc.encode(&block, &ogg);
    }
    try enc.flush(&ogg);
    const bytes = try ogg.toOwnedSlice(alloc);
    defer alloc.free(bytes);
    try testing.expectEqual(@as(usize, 3889), bytes.len);
    bytes[164] = 0x80;
    // a refusal is the correct answer; a crash or a corrupted heap is not
    try testing.expectError(error.OpenFailed, decodeMemory(alloc, bytes));
}

/// The auditor's 8-block 44.1 kHz mono stream with the Vorbis comment
/// header's comment count replaced by `count`.
fn streamWithCommentCount(alloc: std.mem.Allocator, count: u32) ![]u8 {
    const enc = try Encoder.create(alloc, 44100, 0.0, 999);
    defer enc.destroy();
    var ogg: std.ArrayList(u8) = .empty;
    errdefer ogg.deinit(alloc);
    try enc.writeHeaders(&ogg);
    var block: [960]f32 = undefined;
    for (0..8) |i| {
        for (&block, 0..) |*s, k| {
            s.* = 0.4 * @sin(2.0 * std.math.pi * 220.0 * @as(f32, @floatFromInt(i * 960 + k)) / 44100.0);
        }
        try enc.encode(&block, &ogg);
    }
    try enc.flush(&ogg);
    // the comment header is "\x03vorbis", u32 vendor length, vendor string,
    // u32 comment count
    const magic = "\x03vorbis";
    const pos = std.mem.indexOf(u8, ogg.items, magic) orelse return error.TestUnexpectedResult;
    const vendor_len = std.mem.readInt(u32, ogg.items[pos + magic.len ..][0..4], .little);
    const count_pos = pos + magic.len + 4 + vendor_len;
    if (count_pos + 4 > ogg.items.len) return error.TestUnexpectedResult;
    std.mem.writeInt(u32, ogg.items[count_pos..][0..4], count, .little);
    return ogg.toOwnedSlice(alloc);
}

// #63 companions found while hardening the refusal path: the comment count is
// wire-controlled and stb_vorbis sized its slot array through an int, so a
// count of 2^29 truncated the array to nothing and the per-comment loop then
// marched out of it; a merely-large count exhausted the decoder's buffer
// mid-list, which used to crash deinit on the uninitialized/NULL tail. All of
// these must come back as clean refusals.
test "hostile comment counts are refused, not crashed on" {
    const alloc = std.testing.allocator;
    for ([_]u32{ 0x20000000, 0x20000001, 1_000_000, 0x7FFFFFF0 }) |count| {
        const bytes = try streamWithCommentCount(alloc, count);
        defer alloc.free(bytes);
        try testing.expectError(error.OpenFailed, decodeMemory(alloc, bytes));
    }
}
