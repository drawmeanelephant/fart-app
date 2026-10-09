//! kujamba config / preset files (#22).
//!
//! A small TOML-style file supplies `join` + `render` defaults so connection
//! settings and a tuned voice can be saved and reused instead of retyped as
//! flags on every run. kujamba_main loads it and lays it over the built-in
//! defaults BEFORE the flag loop runs (defaults <- config <- flags), which is
//! what makes "command-line flags win" true by construction rather than by a
//! per-flag check.
//!
//! Schema — every key optional, order free:
//!
//!     # connection (join)
//!     host    = "127.0.0.1:20531"   # exactly --host's syntax: the port and
//!                                   # [IPv6 brackets] belong right here
//!     user    = "kujamba"
//!     pass    = "secret"
//!     # instrument (join + render)
//!     phrase  = "kujamba karibu"
//!     pattern = "3+1"               # exactly --pattern's syntax
//!     [voice]                       # the #18 knobs, as multipliers
//!     attack = 1.0                  # 1 on every axis is the stock sound
//!     noise  = 0.5
//!     wobble = 2
//!     intensity = 1.5               # #15: whisper 0.25 .. shout 4
//!     cents = -700                  # #16: shift the vowel pitches a fifth down
//!     [map]                         # the #21 sampler: note -> sound
//!     note60 = "kujamba karibu"     # a phrase (quotes required for spaces)
//!     note64 = shuzi:3              # a single wordless fart by seed
//!
//! `[voice] attack = x` and a dotted `voice.attack = x` are the same thing.
//! In `[map]`, `noteN = sound` (N in 0..127) binds MIDI note N to a phrase or
//! a `shuzi:<seed>`; `kujamba trigger` reads this table.
//! Values are double-quoted literals (no escape sequences) or bare scalars up
//! to a `#` comment. Every value is validated HERE with the same parsers the
//! flags use, so a bad file fails at load time with a `file:line: message`
//! (see Diag) instead of a CLI-shaped error after half the options are applied.
//!
//! Strings in the returned Config point into the parsed text; the caller must
//! keep that buffer alive (in practice: the arena that read the file).

const std = @import("std");
const synth = @import("synth.zig");
const kujamba_out = @import("ninjam_out.zig");

/// The file loaded when `--config` is not given. Its absence is the normal
/// no-config case, not an error.
pub const default_file = "kujamba.toml";

// ---- --host value splitting -------------------------------------------------
// Shared by the --host flag and the config `host` key so both spell the port
// and IPv6 brackets the same way and the two parsers cannot drift apart.

pub const HostError = error{
    /// "[::1" — no closing bracket
    MissingBracket,
    /// "[::1]x" — text after the bracket that is not ":port"
    BadHostAfterBracket,
    /// the part after ':' is not a port number
    BadPort,
    /// "::1:20531" — an IPv6 literal without brackets
    Ipv6NeedsBrackets,
};

/// Split a `--host` value into host name and optional port. The port result is
/// null when the value carried none, so the caller can leave its own port
/// setting untouched — exactly the flag's old behavior.
pub fn splitHostPort(v: []const u8, host: *[]const u8) HostError!?u16 {
    if (v.len > 0 and v[0] == '[') {
        // bracketed IPv6: [::1] or [::1]:20531
        const close = std.mem.indexOfScalar(u8, v, ']') orelse return error.MissingBracket;
        host.* = v[1..close];
        if (close + 1 < v.len) {
            if (v[close + 1] != ':') return error.BadHostAfterBracket;
            return std.fmt.parseInt(u16, v[close + 2 ..], 10) catch error.BadPort;
        }
        return null;
    } else if (std.mem.indexOfScalar(u8, v, ':')) |colon| {
        if (std.mem.indexOfScalarPos(u8, v, colon + 1, ':') != null)
            return error.Ipv6NeedsBrackets;
        host.* = v[0..colon];
        return std.fmt.parseInt(u16, v[colon + 1 ..], 10) catch error.BadPort;
    }
    host.* = v;
    return null;
}

/// The `--host`-shaped wording for each split failure, reused by the config
/// parser so `host = ...` reads like the flag error it mirrors.
pub fn hostErrorText(e: HostError) []const u8 {
    return switch (e) {
        error.MissingBracket => "missing ']'",
        error.BadHostAfterBracket => "unexpected text after ']'",
        error.BadPort => "bad port",
        error.Ipv6NeedsBrackets => "IPv6 needs brackets: \"[::1]:port\"",
    };
}

// ---- the parsed file --------------------------------------------------------

/// One parsed config file. A field left at its default (null / identity knobs)
/// means "not set by the file", so applying a Config never clobbers a value the
/// file did not mention.
pub const Config = struct {
    /// host NAME only — a port embedded in the value is split out into `port`
    host: ?[]const u8 = null,
    /// the port from `host = "name:port"`; null when the value carried none
    port: ?u16 = null,
    user: ?[]const u8 = null,
    pass: ?[]const u8 = null,
    phrase: ?[]const u8 = null,
    pattern: ?kujamba_out.Pattern = null,
    /// the [voice] table: axes the file leaves alone stay at 1 (the identity),
    /// so applying it keeps the stock sound everywhere the file is silent
    knobs: synth.VoiceKnobs = .{},
    /// the [map] table (#21): note -> sound for `kujamba trigger`. Slots the
    /// file leaves alone stay `.none`. Phrase slices point into the file text.
    map: [128]NoteSound = @splat(.none),
};

/// One [map] binding: MIDI note N plays a wordless shuzi by seed, or a whole
/// phrase (owned by the config text's allocator).
pub const NoteSound = union(enum) {
    none,
    shuzi: u64,
    phrase: []const u8,
};

pub const ParseError = error{
    /// a line that is neither comment nor section has no '='
    MissingEquals,
    /// `key =` with nothing (or only a comment) after the '='
    MissingValue,
    /// a quoted value never closes on its line
    UnterminatedString,
    /// text after a closed quoted value that is not whitespace/comment
    TrailingText,
    /// a key or [section] not in the schema
    UnknownKey,
    /// the same key (or [voice] knob) set twice
    DuplicateKey,
    /// the same [table] header twice
    DuplicateSection,
    /// a malformed [section] header
    BadSectionHeader,
    /// `host` does not parse as a --host value
    BadHost,
    /// `pattern` does not parse as N or N+M
    BadPattern,
    /// a [map] value is neither a phrase nor shuzi:<u64>
    BadMapValue,
    /// a [voice] value is not a finite non-negative number
    BadVoiceValue,
};

/// Where and why a parse failed. `parse` fills it before every error return;
/// callers print `<file>:<line>: <message>` with their own prefix.
pub const Diag = struct {
    /// caller-chosen file name, printed as-is
    file: []const u8 = "config",
    line: usize = 0,
    buf: [256]u8 = undefined,
    len: usize = 0,

    fn fail(self: *Diag, line_no: usize, e: ParseError, comptime fmt: []const u8, args: anytype) ParseError {
        self.line = line_no;
        const msg = std.fmt.bufPrint(&self.buf, fmt, args) catch "message too long";
        self.len = msg.len;
        return e;
    }

    fn dup(self: *Diag, line_no: usize, key: []const u8) ParseError {
        return self.fail(line_no, error.DuplicateKey, "'{s}' appears twice", .{key});
    }

    /// the human message only (callers prepend file:line)
    pub fn message(self: *const Diag) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Parse a whole config file. Every value is validated here — pattern with
/// `parsePattern`, voice knobs with parseKnobs' own rules (finite, >= 0; the
/// synth clamps to the spec bounds when they are applied), host with the same
/// splitter the `--host` flag uses — so a Config that comes back is safe to
/// apply without further checks.
pub fn parse(text_in: []const u8, diag: *Diag) ParseError!Config {
    // a UTF-8 BOM from a helpful editor would otherwise poison the first key
    const text = if (std.mem.startsWith(u8, text_in, "\xEF\xBB\xBF")) text_in[3..] else text_in;

    var cfg = Config{};

    var in_voice = false;
    var in_map = false;
    var seen_voice = false;
    var seen_map = false;
    var seen_notes: [128]bool = @splat(false);
    var seen_host = false;
    var seen_user = false;
    var seen_pass = false;
    var seen_phrase = false;
    var seen_pattern = false;
    var seen_knobs: u8 = 0; // one bit per knob, for duplicate detection

    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        var line = raw;
        if (std.mem.endsWith(u8, line, "\r")) line = line[0 .. line.len - 1];
        const t = std.mem.trim(u8, line, " \t");
        if (t.len == 0 or t[0] == '#') continue;

        if (t[0] == '[') {
            const close = std.mem.indexOfScalar(u8, t, ']') orelse
                return diag.fail(line_no, error.BadSectionHeader, "section header is missing ']'", .{});
            const tail = std.mem.trim(u8, t[close + 1 ..], " \t");
            if (tail.len > 0 and tail[0] != '#')
                return diag.fail(line_no, error.BadSectionHeader, "unexpected text after ']' (want a comment)", .{});
            const name = std.mem.trim(u8, t[1..close], " \t");
            if (std.mem.eql(u8, name, "voice")) {
                if (seen_voice)
                    return diag.fail(line_no, error.DuplicateSection, "'[voice]' appears twice", .{});
                seen_voice = true;
                in_voice = true;
                in_map = false;
                continue;
            }
            if (std.mem.eql(u8, name, "map")) {
                if (seen_map)
                    return diag.fail(line_no, error.DuplicateSection, "'[map]' appears twice", .{});
                seen_map = true;
                in_map = true;
                in_voice = false;
                continue;
            }
            return diag.fail(line_no, error.UnknownKey, "unknown section '[{s}]' (want [voice] or [map])", .{name});
        }

        const eq = std.mem.indexOfScalar(u8, t, '=') orelse
            return diag.fail(line_no, error.MissingEquals, "expected 'key = value'", .{});
        const key = std.mem.trim(u8, t[0..eq], " \t");
        if (key.len == 0)
            return diag.fail(line_no, error.MissingEquals, "expected 'key = value' (nothing before '=')", .{});
        for (key) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.')
                return diag.fail(line_no, error.UnknownKey, "unknown key '{s}'", .{key});
        }
        const value = try parseValue(t[eq + 1 ..], diag, line_no);

        if (in_voice) {
            try setKnob(&cfg, key, value, line_no, &seen_knobs, diag);
            continue;
        }
        if (in_map) {
            if (!std.mem.startsWith(u8, key, "note") or key.len == 4)
                return diag.fail(line_no, error.UnknownKey, "unknown key '{s}' (want noteN, N in 0..127)", .{key});
            const note = std.fmt.parseInt(u8, key[4..], 10) catch
                return diag.fail(line_no, error.UnknownKey, "unknown key '{s}' (note number must be 0..127)", .{key});
            if (note > 127)
                return diag.fail(line_no, error.UnknownKey, "unknown key '{s}' (note number must be 0..127)", .{key});
            if (seen_notes[note])
                return diag.fail(line_no, error.DuplicateKey, "note{d} appears twice", .{note});
            seen_notes[note] = true;
            if (std.mem.startsWith(u8, value, "shuzi:")) {
                const seed_text = value["shuzi:".len..];
                cfg.map[note] = .{ .shuzi = std.fmt.parseInt(u64, seed_text, 10) catch
                    return diag.fail(line_no, error.BadMapValue, "bad shuzi seed '{s}' (want shuzi:<u64>)", .{seed_text}) };
            } else {
                cfg.map[note] = .{ .phrase = value };
            }
            continue;
        }
        if (std.mem.eql(u8, key, "host")) {
            if (seen_host) return diag.dup(line_no, key);
            seen_host = true;
            var h: []const u8 = undefined;
            cfg.port = splitHostPort(value, &h) catch |e|
                return diag.fail(line_no, error.BadHost, "bad host: {s}", .{hostErrorText(e)});
            cfg.host = h;
        } else if (std.mem.eql(u8, key, "user")) {
            if (seen_user) return diag.dup(line_no, key);
            seen_user = true;
            cfg.user = value;
        } else if (std.mem.eql(u8, key, "pass")) {
            if (seen_pass) return diag.dup(line_no, key);
            seen_pass = true;
            cfg.pass = value;
        } else if (std.mem.eql(u8, key, "phrase")) {
            if (seen_phrase) return diag.dup(line_no, key);
            seen_phrase = true;
            cfg.phrase = value;
        } else if (std.mem.eql(u8, key, "pattern")) {
            if (seen_pattern) return diag.dup(line_no, key);
            seen_pattern = true;
            cfg.pattern = kujamba_out.parsePattern(value) catch
                return diag.fail(line_no, error.BadPattern, "bad pattern '{s}' (want N or N+M)", .{value});
        } else if (std.mem.eql(u8, key, "voice")) {
            return diag.fail(line_no, error.UnknownKey, "unknown key 'voice' (set [voice] attack/noise/wobble/intensity/cents)", .{});
        } else if (std.mem.startsWith(u8, key, "voice.")) {
            const knob = key["voice.".len..];
            if (knob.len == 0 or std.mem.indexOfScalar(u8, knob, '.') != null)
                return diag.fail(line_no, error.UnknownKey, "unknown key '{s}'", .{key});
            try setKnob(&cfg, knob, value, line_no, &seen_knobs, diag);
        } else {
            return diag.fail(line_no, error.UnknownKey, "unknown key '{s}' (want host, user, pass, phrase, pattern or voice.attack/noise/wobble/intensity/cents)", .{key});
        }
    }
    return cfg;
}

const Knob = enum(u3) { attack, noise, wobble, intensity, cents };

fn knobBit(k: Knob) u8 {
    return @as(u8, 1) << @intCast(@backingInt(k));
}

/// One voice knob from config text, with parseKnobs' own rules for --voice:
/// a finite, non-negative multiplier — except `cents` (#16), which is an
/// offset in cents and the one knob a negative value is meaningful for. The
/// synth clamps to the spec bounds when the knobs are applied, so no range
/// check is needed here.
fn setKnob(cfg: *Config, key: []const u8, value: []const u8, line_no: usize, seen: *u8, diag: *Diag) ParseError!void {
    const k: Knob = if (std.mem.eql(u8, key, "attack"))
        .attack
    else if (std.mem.eql(u8, key, "noise"))
        .noise
    else if (std.mem.eql(u8, key, "wobble"))
        .wobble
    else if (std.mem.eql(u8, key, "intensity"))
        .intensity
    else if (std.mem.eql(u8, key, "cents"))
        .cents
    else
        return diag.fail(line_no, error.UnknownKey, "unknown [voice] key '{s}' (want attack, noise, wobble, intensity or cents)", .{key});

    const bit = knobBit(k);
    if (seen.* & bit != 0) return diag.dup(line_no, key);
    seen.* |= bit;

    const v = std.fmt.parseFloat(f32, value) catch
        return diag.fail(line_no, error.BadVoiceValue, "voice.{s} must be a number (got '{s}')", .{ key, value });
    if (!std.math.isFinite(v))
        return diag.fail(line_no, error.BadVoiceValue, "voice.{s} must be finite (got '{s}')", .{ key, value });
    if (v < 0 and k != .cents)
        return diag.fail(line_no, error.BadVoiceValue, "voice.{s} must be >= 0 (got '{s}'; knobs are multipliers)", .{ key, value });

    switch (k) {
        .attack => cfg.knobs.attack = v,
        .noise => cfg.knobs.noise = v,
        .wobble => cfg.knobs.wobble = v,
        .intensity => cfg.knobs.intensity = v,
        .cents => cfg.knobs.cents = v,
    }
}

/// The value half of a `key = value` line: a double-quoted literal (no escape
/// sequences) or a bare scalar ending at a `#` comment.
fn parseValue(rest: []const u8, diag: *Diag, line_no: usize) ParseError![]const u8 {
    const v = std.mem.trim(u8, rest, " \t");
    if (v.len == 0) return diag.fail(line_no, error.MissingValue, "missing value after '='", .{});
    if (v[0] == '"') {
        const close = std.mem.indexOfScalarPos(u8, v, 1, '"') orelse
            return diag.fail(line_no, error.UnterminatedString, "unterminated string (missing '\"')", .{});
        const tail = std.mem.trim(u8, v[close + 1 ..], " \t");
        if (tail.len > 0 and tail[0] != '#')
            return diag.fail(line_no, error.TrailingText, "unexpected text after the closing quote", .{});
        return v[1..close];
    }
    const end = std.mem.indexOfScalar(u8, v, '#') orelse v.len;
    const bare = std.mem.trim(u8, v[0..end], " \t");
    if (bare.len == 0) return diag.fail(line_no, error.MissingValue, "missing value after '='", .{});
    return bare;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

fn parseOk(text: []const u8) Config {
    var diag = Diag{ .file = "test.toml" };
    return parse(text, &diag) catch |e| {
        std.debug.print("parse failed at {s}:{d}: {s}\n", .{ diag.file, diag.line, diag.message() });
        @panic(@errorName(e));
    };
}

fn expectParseError(expected: ParseError, text: []const u8, want_line: usize, want_msg_part: []const u8) !void {
    var diag = Diag{ .file = "test.toml" };
    try testing.expectError(expected, parse(text, &diag));
    try testing.expectEqual(want_line, diag.line);
    if (std.mem.indexOf(u8, diag.message(), want_msg_part) == null) {
        std.debug.print("expected '{s}' in message '{s}'\n", .{ want_msg_part, diag.message() });
        return error.TestUnexpectedResult;
    }
}

test "a full config file parses into typed values" {
    const cfg = parseOk(
        \\# saved session — comments anywhere, order free
        \\host = "nas.example.com:20531"   # trailing comments work too
        \\user = kujamba                   # bare values are fine
        \\pass = "pw"
        \\phrase = "habari yako"
        \\pattern = "2+2"
        \\
        \\[voice]
        \\attack = 2
        \\noise = 0.5
        \\wobble = 3
        \\intensity = 1.5
        \\cents = -700
        \\
    );
    try testing.expectEqualStrings("nas.example.com", cfg.host.?);
    try testing.expectEqual(@as(?u16, 20531), cfg.port);
    try testing.expectEqualStrings("kujamba", cfg.user.?);
    try testing.expectEqualStrings("pw", cfg.pass.?);
    try testing.expectEqualStrings("habari yako", cfg.phrase.?);
    try testing.expectEqual(kujamba_out.Pattern{ .play = 2, .rest = 2 }, cfg.pattern.?);
    try testing.expectEqual(@as(f32, 2.0), cfg.knobs.attack);
    try testing.expectEqual(@as(f32, 0.5), cfg.knobs.noise);
    try testing.expectEqual(@as(f32, 3.0), cfg.knobs.wobble);
    try testing.expectEqual(@as(f32, 1.5), cfg.knobs.intensity);
    try testing.expectEqual(@as(f32, -700.0), cfg.knobs.cents);
}

test "host carries the port and IPv6 brackets exactly like --host" {
    // port embedded -> split out, name kept whole
    var cfg = parseOk("host = \"[::1]:20531\"\n");
    try testing.expectEqualStrings("::1", cfg.host.?);
    try testing.expectEqual(@as(?u16, 20531), cfg.port);

    // no port -> port stays null, so the applying layer keeps its default
    cfg = parseOk("host = \"nas.example.com\"\n");
    try testing.expectEqualStrings("nas.example.com", cfg.host.?);
    try testing.expectEqual(@as(?u16, null), cfg.port);

    cfg = parseOk("host = nas.example.com:9999\n");
    try testing.expectEqualStrings("nas.example.com", cfg.host.?);
    try testing.expectEqual(@as(?u16, 9999), cfg.port);
}

test "dotted voice keys are the same as the [voice] table" {
    const cfg = parseOk(
        \\voice.attack = 0.5
        \\voice.noise = 2
        \\voice.wobble = 0
        \\
    );
    try testing.expectEqual(@as(f32, 0.5), cfg.knobs.attack);
    try testing.expectEqual(@as(f32, 2.0), cfg.knobs.noise);
    try testing.expectEqual(@as(f32, 0.0), cfg.knobs.wobble);
}

test "knobs the file leaves alone stay at 1 (the identity)" {
    const cfg = parseOk("[voice]\nnoise = 0\n");
    try testing.expectEqual(@as(f32, 1.0), cfg.knobs.attack);
    try testing.expectEqual(@as(f32, 0.0), cfg.knobs.noise);
    try testing.expectEqual(@as(f32, 1.0), cfg.knobs.wobble);
    // the #15/#16 axes share the identity rule: intensity 1, cents 0
    try testing.expectEqual(@as(f32, 1.0), cfg.knobs.intensity);
    try testing.expectEqual(@as(f32, 0.0), cfg.knobs.cents);
}

test "intensity and cents ride the same [voice] table (#15, #16)" {
    const table = parseOk("[voice]\nintensity = 0.5\ncents = -700\n");
    try testing.expectEqual(@as(f32, 0.5), table.knobs.intensity);
    try testing.expectEqual(@as(f32, -700.0), table.knobs.cents);

    const dotted = parseOk("voice.intensity = 2\nvoice.cents = 1200\n");
    try testing.expectEqual(@as(f32, 2.0), dotted.knobs.intensity);
    try testing.expectEqual(@as(f32, 1200.0), dotted.knobs.cents);

    // cents is an offset, so a negative value is fine — but intensity is a
    // multiplier and negative is rejected like every other knob
    try expectParseError(error.BadVoiceValue, "[voice]\nintensity = -1\n", 2, "voice.intensity must be >= 0");
    try expectParseError(error.BadVoiceValue, "[voice]\ncents = nan\n", 2, "voice.cents must be finite");
    try expectParseError(error.BadVoiceValue, "[voice]\ncents = quiet\n", 2, "voice.cents must be a number (got 'quiet')");
    try expectParseError(error.DuplicateKey, "[voice]\ncents = 1\ncents = 2\n", 3, "'cents' appears twice");
}

test "comments, blank lines and CRLF line endings are ignored" {
    const cfg = parseOk("\xEF\xBB\xBF\r\n# comment\r\n\r\nuser = \"dj\"\r\n   \r\n# trailing\r\n");
    try testing.expectEqualStrings("dj", cfg.user.?);
    try testing.expectEqual(@as(?u16, null), cfg.port);
}

test "an empty config is valid and sets nothing" {
    for ([_][]const u8{ "", "\n", "# only comments\n\n" }) |text| {
        const cfg = parseOk(text);
        try testing.expectEqual(@as(?[]const u8, null), cfg.host);
        try testing.expectEqual(@as(?u16, null), cfg.port);
        try testing.expectEqual(@as(?[]const u8, null), cfg.user);
        try testing.expectEqual(@as(?[]const u8, null), cfg.pass);
        try testing.expectEqual(@as(?[]const u8, null), cfg.phrase);
        try testing.expectEqual(@as(?kujamba_out.Pattern, null), cfg.pattern);
        try testing.expectEqual(synth.VoiceKnobs{}, cfg.knobs);
    }
}

test "unknown keys and sections are rejected with file and line" {
    try expectParseError(error.UnknownKey, "user = a\npass = b\nusr = oops\n", 3, "unknown key 'usr'");
    try expectParseError(error.UnknownKey, "seed = 5\n", 1, "unknown key 'seed'");
    try expectParseError(error.UnknownKey, "[voice]\nwobble_hz = 30\n", 2, "unknown [voice] key 'wobble_hz'");
    try expectParseError(error.UnknownKey, "[connection]\nhost = \"x\"\n", 1, "unknown section '[connection]'");
}

test "duplicate keys and a repeated [voice] table are rejected" {
    try expectParseError(error.DuplicateKey, "user = a\nuser = b\n", 2, "'user' appears twice");
    try expectParseError(error.DuplicateKey, "voice.attack = 1\nvoice.attack = 2\n", 2, "'attack' appears twice");
    try expectParseError(error.DuplicateKey, "[voice]\nattack = 1\nattack = 2\n", 3, "'attack' appears twice");
    try expectParseError(error.DuplicateSection, "[voice]\n[voice]\n", 2, "'[voice]' appears twice");
    // the same knob via both spellings is still a duplicate
    try expectParseError(error.DuplicateKey, "voice.noise = 1\n[voice]\nnoise = 2\n", 3, "'noise' appears twice");
}

test "bad pattern, host and voice values are rejected like their flags" {
    try expectParseError(error.BadPattern, "pattern = \"x+y\"\n", 1, "bad pattern 'x+y' (want N or N+M)");
    try expectParseError(error.BadPattern, "pattern = \"0+1\"\n", 1, "bad pattern '0+1'");
    try expectParseError(error.BadHost, "host = \"[::1\"\n", 1, "bad host: missing ']'");
    try expectParseError(error.BadHost, "host = \"a:b:c\"\n", 1, "bad host: IPv6 needs brackets");
    try expectParseError(error.BadHost, "host = \"srv:notaport\"\n", 1, "bad host: bad port");
    try expectParseError(error.BadVoiceValue, "[voice]\nattack = fast\n", 2, "voice.attack must be a number (got 'fast')");
    try expectParseError(error.BadVoiceValue, "[voice]\nnoise = -1\n", 2, "voice.noise must be >= 0");
    try expectParseError(error.BadVoiceValue, "[voice]\nwobble = nan\n", 2, "voice.wobble must be finite");
}

test "malformed lines are rejected" {
    try expectParseError(error.MissingEquals, "just some text\n", 1, "expected 'key = value'");
    try expectParseError(error.MissingValue, "user =\n", 1, "missing value");
    try expectParseError(error.MissingValue, "user = # only a comment\n", 1, "missing value");
    try expectParseError(error.UnterminatedString, "phrase = \"no end\n", 1, "unterminated string");
    try expectParseError(error.TrailingText, "user = \"a\" junk\n", 1, "unexpected text after the closing quote");
    try expectParseError(error.BadSectionHeader, "[voice\n", 1, "missing ']'");
    try expectParseError(error.BadSectionHeader, "[voice] trailing junk\n", 1, "unexpected text after ']'");
}

test "quoted values are literal; empty strings are allowed" {
    const cfg = parseOk("phrase = \"a\\b\"\npass = \"\"\n");
    // no escape processing: what is between the quotes is the value
    try testing.expectEqualStrings("a\\b", cfg.phrase.?);
    try testing.expectEqualStrings("", cfg.pass.?);
}

test "splitHostPort matches the --host flag semantics" {
    var host: []const u8 = "sentinel";
    try testing.expectEqual(@as(?u16, null), try splitHostPort("example.com", &host));
    try testing.expectEqualStrings("example.com", host);

    try testing.expectEqual(@as(?u16, 20531), try splitHostPort("example.com:20531", &host));
    try testing.expectEqualStrings("example.com", host);

    try testing.expectEqual(@as(?u16, null), try splitHostPort("[::1]", &host));
    try testing.expectEqualStrings("::1", host);

    try testing.expectEqual(@as(?u16, 20531), try splitHostPort("[2001:db8::1]:20531", &host));
    try testing.expectEqualStrings("2001:db8::1", host);

    try testing.expectError(error.MissingBracket, splitHostPort("[::1", &host));
    try testing.expectError(error.BadHostAfterBracket, splitHostPort("[::1]x", &host));
    try testing.expectError(error.BadPort, splitHostPort("example.com:notaport", &host));
    try testing.expectError(error.BadPort, splitHostPort("example.com:99999", &host));
    try testing.expectError(error.Ipv6NeedsBrackets, splitHostPort("::1:20531", &host));
}

test "[map] binds notes to phrases and shuzi seeds" {
    const cfg = parseOk(
        \\phrase = "kujamba karibu"
        \\[map]
        \\note60 = "kujamba karibu"
        \\note61 = shuzi:3
        \\note0 = bare-phrase
    );
    try testing.expectEqualStrings("kujamba karibu", cfg.map[60].phrase);
    try testing.expectEqual(@as(u64, 3), cfg.map[61].shuzi);
    try testing.expectEqualStrings("bare-phrase", cfg.map[0].phrase);
    try testing.expect(cfg.map[62] == .none);
}

test "[map] rejects unknown keys, bad notes, duplicates and bad seeds" {
    try expectParseError(error.UnknownKey,
        \\[map]
        \\note = "x"
    , 2, "want noteN");
    try expectParseError(error.UnknownKey,
        \\[map]
        \\note999 = "x"
    , 2, "0..127");
    try expectParseError(error.DuplicateKey,
        \\[map]
        \\note60 = "x"
        \\note60 = "y"
    , 3, "note60 appears twice");
    try expectParseError(error.BadMapValue,
        \\[map]
        \\note60 = shuzi:abc
    , 2, "bad shuzi seed");
}

test "[map] coexists with [voice] and keeps sections separate" {
    const cfg = parseOk(
        \\[voice]
        \\attack = 0.5
        \\[map]
        \\note60 = shuzi:1
        \\note61 = "habari yako"
    );
    try testing.expect(cfg.map[60] == .shuzi);
    try testing.expectEqual(@as(f64, 0.5) * 0 + cfg.knobs.attack, cfg.knobs.attack);
    try testing.expect(cfg.map[61] == .phrase);
}
