//! engine_registry.zig — the fart-off engine selector (M9, #95).
//!
//! Nine frontier models each rewrote `synth.zig` on a `fartoff/*` branch with
//! the same brief: physical pressure/tension/resonance/turbulence parameters,
//! exponential pitch sag, formant vowels, plosive bursts — deterministic,
//! headless-safe, pure Zig. A tenth, `gutphysics` (MiMo Pro 2.6 under the
//! Codebuff agent), arrived as PR #99 on a branch too stale to merge and was
//! absorbed the same way. Grok 4.7 and Kimi K3 joined as entries 11 and 12
//! under the same protocol. All twelve
//! are keepers, so their DSP lives here as `src/engines/<slug>.zig` (each
//! file is that branch's `synth.zig` verbatim) and this module dispatches
//! between them.
//!
//! `stock` is the pre-fart-off synth (`src/synth.zig`) and stays the default
//! until a winner is crowned by ear — the selector makes the engines
//! addressable without picking one.
//!
//! Selecting an engine:
//!
//!     --engine swe2                          # flag
//!     --voice "engine=swe2,pressure=2"       # inside the voice spec
//!     engine = "swe2"                        # config file (top level)
//!     [voice] engine = "swe2"                # or inside the table
//!
//! Precedence: --engine > engine= in --voice > config `engine` > `stock`.
//!
//! Knobs are per-engine: a `--voice` spec is validated by the *resolved*
//! engine's own parseKnobs, so each engine keeps exactly the parameter set it
//! documented on its branch (`stock` takes only the five stock axes). The
//! `Knobs` union carries whichever struct was parsed — there is no common
//! canonical knob set, on purpose: flattening "wetness" vs "wet" vs "droop"
//! into shared axes would silently re-tune sounds that were judged by ear.
//!
//! Determinism is per-engine: same engine, same spec, same seed, same WAV.

const std = @import("std");

const stock = @import("synth.zig");
const argon4 = @import("engines/argon4.zig");
const astra = @import("engines/astra.zig");
const fable = @import("engines/fable.zig");
const gemini38 = @import("engines/gemini38.zig");
const grok47 = @import("engines/grok47.zig");
const gutphysics = @import("engines/gutphysics.zig");
const kimi3 = @import("engines/kimi3.zig");
const mistral4 = @import("engines/mistral4.zig");
const opus = @import("engines/opus.zig");
const sol61 = @import("engines/sol61.zig");
const sonnet = @import("engines/sonnet.zig");
const swe2 = @import("engines/swe2.zig");

/// Engine identifiers. The enum tag IS the slug — `name`/`fromName` are the
/// same table, so a new engine is one variant in four places (Id, the union,
/// `engineModule`, the docs table).
pub const Id = enum {
    /// the pre-fart-off synth: `src/synth.zig`
    stock,
    /// Gemini 4 Argon — pressure/tension/resonance/turbulence
    argon4,
    /// GPT-6 Astra — + decay
    astra,
    /// Claude Fable 5.1 — + glide; bit-identical across build modes
    fable,
    /// Gemini 3.8 Flash — + decay, wetness, seed
    gemini38,
    /// MiMo Pro 2.6 via Codebuff (PR #99, #23) — gut physics; + tract.
    /// Absorbed from an unmergeable stale-branch PR: same brief, different
    /// contestant.
    gutphysics,
    /// Grok 4.7 (late entry #11) — 0..1 amounts, not multipliers; + wetness,
    /// decay. "I bear down, I sag, and I do not apologize for the rasp."
    grok47,
    /// Kimi K3 (late entry #12) — + formant; collapsing-pressure gut model
    /// with an SVF tract boom. "Every fart I make has eaten."
    kimi3,
    /// Mistral Large 4 — + decay; bit-identical across build modes
    mistral4,
    /// Claude Opus 5.5 — + tract, wetness, droop, classic
    opus,
    /// GPT-6.1 Sol — + decay
    sol61,
    /// Claude Sonnet 5.5 — + wetness, rasp, decay, burst, boom, seed, legacy
    sonnet,
    /// SWE-2 — + wet, drop
    swe2,
};

/// The engine nothing explicit selects. `stock`, by design, until the fart-off
/// judging picks a winner — flipping this is the crowning commit.
pub const default_id: Id = .stock;

/// Every id, for `--engine` help text and per-engine test loops.
pub const all: []const Id = std.enums.values(Id);

/// "stock,argon4,..." — the valid `--engine` values, for error messages.
pub const names_csv: []const u8 = blk: {
    var out: []const u8 = "";
    for (all, 0..) |id, i| {
        out = if (i == 0) @tagName(id) else out ++ "," ++ @tagName(id);
    }
    break :blk out;
};

pub fn name(id: Id) []const u8 {
    return @tagName(id);
}

pub fn fromName(s: []const u8) ?Id {
    return std.meta.stringToEnum(Id, s);
}

/// Comptime list of the engines' module files, keyed by Id.
fn engineModule(comptime id: Id) type {
    return switch (id) {
        .stock => stock,
        .argon4 => argon4,
        .astra => astra,
        .fable => fable,
        .gemini38 => gemini38,
        .gutphysics => gutphysics,
        .grok47 => grok47,
        .kimi3 => kimi3,
        .mistral4 => mistral4,
        .opus => opus,
        .sol61 => sol61,
        .sonnet => sonnet,
        .swe2 => swe2,
    };
}

/// All sample rates are 44.1 kHz; re-exported so callers keep one import.
pub const SAMPLE_RATE = stock.SAMPLE_RATE;

/// Whichever engine's `VoiceKnobs` a spec resolved to. The tag is the Id, so
/// dispatch is a plain switch and a misparsed spec cannot reach the wrong DSP.
pub const Knobs = union(Id) {
    stock: stock.VoiceKnobs,
    argon4: argon4.VoiceKnobs,
    astra: astra.VoiceKnobs,
    fable: fable.VoiceKnobs,
    gemini38: gemini38.VoiceKnobs,
    gutphysics: gutphysics.VoiceKnobs,
    grok47: grok47.VoiceKnobs,
    kimi3: kimi3.VoiceKnobs,
    mistral4: mistral4.VoiceKnobs,
    opus: opus.VoiceKnobs,
    sol61: sol61.VoiceKnobs,
    sonnet: sonnet.VoiceKnobs,
    swe2: swe2.VoiceKnobs,
};

/// Identity knobs for one engine — the documented default voice of each entry,
/// and what plain `--engine <slug>` renders with.
pub fn defaultKnobs(id: Id) Knobs {
    return switch (id) {
        inline else => |tag| @unionInit(Knobs, @tagName(tag), .{}),
    };
}

pub fn engineOf(knobs: Knobs) Id {
    return std.meta.activeTag(knobs);
}

/// "attack,noise,wobble,..." for one engine, for error and help text. Derived
/// from the engine's own `VoiceKnobs` so it cannot drift from the parser.
/// Only f32 fields count as knobs: gemini38's `seed: u64` is a field but not
/// a `key=value` knob its parseKnobs accepts.
pub fn knobNames(comptime id: Id) []const u8 {
    return comptime blk: {
        const info = @typeInfo(engineModule(id).VoiceKnobs).@"struct";
        var out: []const u8 = "";
        for (info.field_names, info.field_types) |f, t| {
            if (t != f32) continue;
            out = if (out.len == 0) f else out ++ "," ++ f;
        }
        break :blk out;
    };
}

/// Comma-joined knob list for a runtime id — resolved through the comptime
/// table, so a `--engine` value the user typed prints its own knob set.
pub fn knobNamesFor(id: Id) []const u8 {
    return switch (id) {
        inline else => |tag| knobNames(tag),
    };
}

pub const ParseError = error{
    /// `engine=<name>` in a spec did not match any Id
    UnknownEngine,
    /// the engine-stripped spec exceeded the peel buffer (4 KiB is far past
    /// any real voice spec — this only trips on abuse)
    VoiceSpecTooLong,
} || UnionKnobsError();

fn UnionKnobsError() type {
    // the merged error set of every engine's parseKnobs, so a bad key fails
    // with the engine's own error name (UnknownKnob, NotFinite, ...)
    var set = error{};
    for (all) |id| {
        const E = engineModule(id);
        set = set || @typeInfo(@typeInfo(@TypeOf(E.parseKnobs)).@"fn".return_type.?).error_union.error_set;
    }
    return set;
}

pub const Parsed = struct {
    /// the engine actually selected: `forced` if given, else an `engine=` pair
    /// inside the spec, else `fallback`
    engine: Id,
    knobs: Knobs,
};

/// Which engine a spec resolves to, without parsing the knobs. Same peel
/// order as `parseKnobs` (`forced` > in-spec `engine=` > `fallback`); exists
/// so an error message can name the engine whose parser rejected a key.
pub fn resolveId(spec: []const u8, forced: ?Id, fallback: Id) ParseError!Id {
    var id = fallback;
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |pair_raw| {
        const pair = std.mem.trim(u8, pair_raw, " \t");
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, pair[0..eq], " \t"), "engine")) {
            const v = std.mem.trim(u8, pair[eq + 1 ..], " \t");
            id = fromName(v) orelse return error.UnknownEngine;
        }
    }
    return if (forced) |f| f else id;
}

/// Parse a `--voice`-shaped spec for the resolved engine. `engine=<slug>`
/// pairs are peeled off and select the engine; the rest goes to that engine's
/// own parseKnobs, so knob names and validation rules are always the entry's
/// own. `forced` (a `--engine` flag) beats an in-spec `engine=` pair; both
/// beat `fallback` (the config file's engine, or `default_id`).
///
/// An empty spec — or one that named only an engine — yields that engine's
/// identity knobs without touching its parser, so `parseKnobs("")` is safe.
pub fn parseKnobs(spec: []const u8, forced: ?Id, fallback: Id) ParseError!Parsed {
    var id = fallback;
    var buf: [4096]u8 = undefined;
    var w: usize = 0;
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |pair_raw| {
        const pair = std.mem.trim(u8, pair_raw, " \t");
        if (pair.len == 0) continue;
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            const key = std.mem.trim(u8, pair[0..eq], " \t");
            if (std.mem.eql(u8, key, "engine")) {
                const v = std.mem.trim(u8, pair[eq + 1 ..], " \t");
                id = fromName(v) orelse return error.UnknownEngine;
                continue;
            }
        }
        if (w + pair.len + 1 > buf.len) return error.VoiceSpecTooLong;
        if (w != 0) {
            buf[w] = ',';
            w += 1;
        }
        @memcpy(buf[w .. w + pair.len], pair);
        w += pair.len;
    }
    if (forced) |f| id = f;
    const rest = buf[0..w];
    const knobs: Knobs = if (rest.len == 0) defaultKnobs(id) else switch (id) {
        inline else => |tag| blk: {
            const E = engineModule(tag);
            break :blk @unionInit(Knobs, @tagName(tag), try E.parseKnobs(rest));
        },
    };
    return .{ .engine = id, .knobs = knobs };
}

// ---- render dispatch ---------------------------------------------------------
// Every engine exposes the same four entry points with its own VoiceKnobs, so
// dispatch is a mechanical switch. `inline else` keeps each arm typed to the
// matching module — a tag/knob mismatch is a compile error, not a bad render.

/// Phrase -> mono i16 PCM at SAMPLE_RATE, for the session/phrase-bank path.
pub fn renderPhraseSamplesWith(
    alloc: std.mem.Allocator,
    phrase: []const u8,
    knobs: Knobs,
) ![]i16 {
    return switch (knobs) {
        inline else => |v, tag| engineModule(tag).renderPhraseSamplesWith(alloc, phrase, v),
    };
}

/// Phrase -> canonical WAV bytes (used by golden fingerprints and tools that
/// want the rendered file, not the stream).
pub fn renderPhraseWavWith(
    alloc: std.mem.Allocator,
    phrase: []const u8,
    knobs: Knobs,
) ![]u8 {
    return switch (knobs) {
        inline else => |v, tag| engineModule(tag).renderPhraseWavWith(alloc, phrase, v),
    };
}

/// Phrase render on the default engine's identity voice.
pub fn renderPhraseWav(alloc: std.mem.Allocator, phrase: []const u8) ![]u8 {
    return renderPhraseWavWith(alloc, phrase, defaultKnobs(default_id));
}

/// A wordless fart by seed (the [map] shuzi:N binding and `fart shuzi`).
pub fn renderShuziWavWith(alloc: std.mem.Allocator, seed: u64, knobs: Knobs) ![]u8 {
    return switch (knobs) {
        inline else => |v, tag| engineModule(tag).renderShuziWavWith(alloc, seed, v),
    };
}

/// Shuzi render on the default engine's identity voice.
pub fn renderShuziWav(alloc: std.mem.Allocator, seed: u64) ![]u8 {
    return renderShuziWavWith(alloc, seed, defaultKnobs(default_id));
}

/// Syllable count for a phrase under one engine — the golden fingerprint's
/// `items` field. The plan itself is engine-shaped, so only the count comes
/// out; callers that need the plan use the module directly.
pub fn planItemCount(alloc: std.mem.Allocator, phrase: []const u8, id: Id) !usize {
    return switch (id) {
        inline else => |tag| blk: {
            var plan = try engineModule(tag).planPhrase(alloc, phrase);
            defer plan.deinit(alloc);
            break :blk plan.items.len;
        },
    };
}

/// Canonical WAV writer shared by every engine's file-format needs.
pub const writeWavBytes = stock.writeWavBytes;

// ---- tests -------------------------------------------------------------------

const testing = std.testing;

test "every engine id round-trips through its name" {
    for (all) |id| {
        try testing.expectEqual(id, fromName(name(id)).?);
    }
    try testing.expectEqual(@as(?Id, null), fromName("bert"));
    try testing.expectEqual(@as(?Id, null), fromName(""));
    try testing.expectEqual(@as(?Id, null), fromName("STOCK")); // slugs are case-exact
}

test "default is stock until the fart-off is judged" {
    try testing.expectEqual(Id.stock, default_id);
    try testing.expectEqual(Id.stock, engineOf(defaultKnobs(default_id)));
}

test "parseKnobs: engine= inside the spec selects the engine" {
    const p = try parseKnobs("engine=swe2,pressure=2,wet=1.5", null, .stock);
    try testing.expectEqual(Id.swe2, p.engine);
    try testing.expectEqual(Id.swe2, engineOf(p.knobs));
    try testing.expectEqual(@as(f32, 2.0), p.knobs.swe2.pressure);
    try testing.expectEqual(@as(f32, 1.5), p.knobs.swe2.wet);
}

test "parseKnobs: forced --engine beats an in-spec engine=" {
    const p = try parseKnobs("engine=swe2,attack=2", .fable, .stock);
    try testing.expectEqual(Id.fable, p.engine);
    try testing.expectEqual(@as(f32, 2.0), p.knobs.fable.attack);
}

test "parseKnobs: a spec with no engine= uses the fallback" {
    const p = try parseKnobs("noise=0", null, .opus);
    try testing.expectEqual(Id.opus, p.engine);
    try testing.expectEqual(@as(f32, 0.0), p.knobs.opus.noise);
}

test "parseKnobs: empty spec gives identity knobs for the resolved engine" {
    for (all) |id| {
        const p = try parseKnobs("", null, id);
        try testing.expectEqual(id, p.engine);
        try testing.expectEqual(id, engineOf(p.knobs));
    }
}

test "parseKnobs: unknown engine names and foreign knobs are rejected" {
    try testing.expectError(error.UnknownEngine, parseKnobs("engine=bert", null, .stock));
    // 'wet' is a swe2 knob; on stock it must fail with the engine's own error
    try testing.expectError(error.UnknownKnob, parseKnobs("engine=stock,wet=2", null, .stock));
    try testing.expectError(error.UnknownKnob, parseKnobs("engine=fable,drop=2", null, .stock));
}

test "every engine renders a phrase and a shuzi" {
    const alloc = testing.allocator;
    for (all) |id| {
        const wav = try renderPhraseWavWith(alloc, "kujamba karibu", defaultKnobs(id));
        defer alloc.free(wav);
        try testing.expect(wav.len > 44);
        try testing.expectEqualStrings("RIFF", wav[0..4]);

        const shuzi = try renderShuziWavWith(alloc, 42, defaultKnobs(id));
        defer alloc.free(shuzi);
        try testing.expect(shuzi.len > 44);
        try testing.expectEqualStrings("RIFF", shuzi[0..4]);

        // determinism: the same engine + phrase renders the same byte count
        // twice. (Byte-exactness across build modes is engine-dependent —
        // fable and mistral4 replaced the math intrinsics to get it.)
        const wav2 = try renderPhraseWavWith(alloc, "kujamba karibu", defaultKnobs(id));
        defer alloc.free(wav2);
        try testing.expectEqual(wav.len, wav2.len);
        try testing.expectEqualSlices(u8, wav, wav2);

        // items>0 for a known-phrase on every engine
        try testing.expect(try planItemCount(alloc, "kujamba karibu", id) > 0);
    }
}
