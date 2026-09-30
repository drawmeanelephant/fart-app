const std = @import("std");
const builtin = @import("builtin");
const synth = @import("synth.zig");
const libc = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("time.h");
    @cInclude("signal.h");
});

const butt_frames = [_][]const u8{
    \\       _.._  _.._
    \\     /   _ \/ _  \
    \\    |   / \||/ \  |
    \\    |   | |||| |  |
    \\    \   \_/||\_/  /
    \\     \____/||\___/
    ,
    \\        _.._  _.._
    \\      /   _ \/ _  \
    \\     |   / \||/ \  |
    \\     |   | |||| |  |
    \\     \   \_/||\_/  /
    \\      \____/||\___/
    ,
    \\      _.._  _.._
    \\    /   _ \/ _  \
    \\   |   / \||/ \  |
    \\   |   | |||| |  |
    \\   \   \_/||\_/  /
    \\    \____/||\___/
};

const fart_clouds = [_][]const u8{
    \\
    \\
    \\
    \\
    \\
    \\
    ,
    \\
    \\
    \\
    \\          o
    \\         O
    \\
    ,
    \\
    \\
    \\         O  o
    \\        o O  
    \\      * pfft *
    \\
    ,
    \\
    \\       O   o
    \\     o  O    o
    \\   * PFFFFT! *
    \\      o   O
    \\
};

const colors = [_][]const u8{
    "\x1b[31m", "\x1b[32m", "\x1b[33m", "\x1b[34m",
    "\x1b[35m", "\x1b[36m", "\x1b[91m", "\x1b[92m",
    "\x1b[93m",
};

const bg_colors = [_][]const u8{
    "\x1b[41m",  "\x1b[42m", "\x1b[43m",  "\x1b[44m",
    "\x1b[45m",  "\x1b[46m", "\x1b[101m", "\x1b[102m",
    "\x1b[103m",
};

var is_running = std.atomic.Value(bool).init(true);

// Flatlophone v2: fixed seeds for the six pre-rendered shuzi (wordless farts)
// that replace the retired Basso.aiff library. Deterministic per seed.
const shuzi_seeds = [_]u64{ 0xF4277D01, 0xF4277D02, 0xF4277D03, 0xF4277D04, 0xF4277D05, 0xF4277D06 };

// ---- platform: sound + speech (#25) --------------------------------------------
// The butt is visual anywhere a terminal is; the sounds are shell-outs to
// whatever the host offers. macOS ships afplay + say; Linux uses paplay /
// aplay / ffplay (whichever is found first) and espeak. With none of them the
// app still runs — it says so once and goes silent.

const AudioPlayer = enum { afplay, paplay, aplay, ffplay, none };

var audio_player: AudioPlayer = .none; // probed once in main()
var speech_available: bool = false; // probed once in main()

fn haveCommand(cmd: []const u8) bool {
    var buf: [128]u8 = undefined;
    const probe = std.fmt.bufPrintZ(&buf, "command -v {s} >/dev/null 2>&1", .{cmd}) catch return false;
    return libc.system(probe.ptr) == 0;
}

fn probeAudio() AudioPlayer {
    if (builtin.os.tag == .macos) {
        return if (haveCommand("afplay")) .afplay else .none;
    }
    if (haveCommand("paplay")) return .paplay;
    if (haveCommand("aplay")) return .aplay;
    if (haveCommand("ffplay")) return .ffplay;
    return .none;
}

fn probeSpeech() bool {
    return haveCommand(if (builtin.os.tag == .macos) "say" else "espeak");
}

/// The shell line that plays `path` at `volume` (afplay and paplay have a
/// volume knob; aplay and ffplay play at their default), or null when there is
/// nothing to play with.
fn soundCommand(buf: []u8, player: AudioPlayer, path: []const u8, volume: u8) ?[:0]const u8 {
    return switch (player) {
        .afplay => std.fmt.bufPrintZ(buf, "afplay -v {d} {s} &", .{ volume, path }) catch null,
        .paplay => std.fmt.bufPrintZ(buf, "paplay --volume={d} {s} &", .{ volume, path }) catch null,
        .aplay => std.fmt.bufPrintZ(buf, "aplay -q {s} &", .{path}) catch null,
        .ffplay => std.fmt.bufPrintZ(buf, "ffplay -loglevel quiet -nodisp -autoexit {s} &", .{path}) catch null,
        .none => null,
    };
}

fn playSound(path: [:0]const u8, volume: u8) void {
    var buf: [160]u8 = undefined;
    if (soundCommand(&buf, audio_player, path, volume)) |cmd| {
        _ = libc.system(cmd.ptr);
    }
}

/// The voice lines. macOS keeps its `say` voices (the jokes are
/// voice-specific); Linux falls back to espeak's default voice when installed.
fn speak(voice: []const u8, text: []const u8) void {
    var buf: [256]u8 = undefined;
    const cmd = if (builtin.os.tag == .macos)
        std.fmt.bufPrintZ(&buf, "say -v '{s}' '{s}' &", .{ voice, text }) catch return
    else if (speech_available)
        std.fmt.bufPrintZ(&buf, "espeak '{s}' &", .{text}) catch return
    else
        return;
    _ = libc.system(cmd.ptr);
}

fn writeWavFile(path: [*:0]const u8, bytes: []const u8) bool {
    const f = libc.fopen(path, "wb") orelse return false;
    _ = libc.fwrite(bytes.ptr, 1, bytes.len, f);
    _ = libc.fclose(f);
    return true;
}

/// kujamba mode: the butt speaks a Swahili phrase in fart.
/// Syllable-timed animation frames while the synthesized phrase WAV plays.
fn runKujamba(phrase: []const u8) void {
    const alloc = std.heap.page_allocator;

    var plan = synth.planPhrase(alloc, phrase) catch {
        _ = libc.printf("kujamba: nothing speakable in that phrase\n");
        return;
    };
    defer plan.deinit(alloc);
    if (plan.items.len == 0) {
        _ = libc.printf("kujamba: nothing speakable in that phrase\n");
        return;
    }

    const wav = synth.renderPhraseWav(alloc, phrase) catch {
        _ = libc.printf("kujamba: synthesis failed\n");
        return;
    };
    defer alloc.free(wav);
    if (!writeWavFile("/tmp/fart_kujamba.wav", wav)) {
        _ = libc.printf("kujamba: could not write /tmp/fart_kujamba.wav\n");
        return;
    }

    _ = libc.printf("\x1b[?25l");
    playSound("/tmp/fart_kujamba.wav", 1);

    var i: usize = 0;
    while (i < plan.items.len) : (i += 1) {
        const item = plan.items[i];
        const shake_x = getRand(5) - 2;
        const shake_y = getRand(5) - 2;

        _ = libc.printf("\x1b[2J\x1b[H");
        _ = libc.printf("%s", bg_colors[getRandU(bg_colors.len)].ptr);

        var j: usize = 0;
        const num_emojis = getRandU(14);
        while (j < num_emojis) : (j += 1) {
            const rx = clamp(getRand(80) + 1 + shake_x);
            const ry = clamp(getRand(24) + 1 + shake_y);
            const emojis = [_][]const u8{ "💨", "💩", "🤮", "🤢", "🍑", "💥" };
            _ = libc.printf("\x1b[%d;%dH%s", ry, rx, emojis[getRandU(emojis.len)].ptr);
        }

        _ = libc.printf("\x1b[3;%dH\x1b[93m kujamba: %.*s \x1b[0m", clamp(26), @as(c_int, @intCast(phrase.len)), phrase.ptr);

        const current_butt = butt_frames[i % butt_frames.len];
        var lines = std.mem.splitScalar(u8, current_butt, '\n');
        var row = clamp(8 + shake_y);
        while (lines.next()) |line| {
            _ = libc.printf("\x1b[%d;%dH%.*s\n", row, clamp(30 + shake_x), @as(c_int, @intCast(line.len)), line.ptr);
            row += 1;
        }

        const syl_text = item.syl.text();
        _ = libc.printf("%s", colors[getRandU(colors.len)].ptr);
        if (item.syl.vowel == 0) {
            _ = libc.printf("\x1b[%d;%dH* %.*s (whisper) *\n", clamp(16 + shake_y), clamp(38 + shake_x), @as(c_int, @intCast(syl_text.len)), syl_text.ptr);
        } else {
            _ = libc.printf("\x1b[%d;%dH* %.*s *\n", clamp(16 + shake_y), clamp(38 + shake_x), @as(c_int, @intCast(syl_text.len)), syl_text.ptr);
        }

        _ = libc.fflush(null);
        _ = libc.usleep(@intCast(item.len * 1000000 / synth.SAMPLE_RATE));
    }

    restoreTerminal();
    const dur_s = @as(f64, @floatFromInt(plan.total_samples)) / @as(f64, @floatFromInt(synth.SAMPLE_RATE));
    _ = libc.printf("\n💨 %.*s — %zu syllables, %.2f s of pure kujamba.\n", @as(c_int, @intCast(phrase.len)), phrase.ptr, plan.items.len, dur_s);
}

fn restoreTerminal() void {
    _ = libc.printf("\x1b[2J\x1b[H");
    _ = libc.printf("\x1b[0m");
    _ = libc.printf("\x1b[?25h");
    _ = libc.fflush(null);
}

fn handleSigInt(sig: c_int) callconv(.c) void {
    _ = sig;
    is_running.store(false, .release);
}

fn clamp(val: i32) c_int {
    return if (val < 1) 1 else @intCast(val);
}

fn getRand(max: u32) i32 {
    const r = @as(u32, @intCast(libc.rand()));
    return @as(i32, @intCast(r % max));
}

fn getRandU(max: usize) usize {
    const r = @as(usize, @intCast(libc.rand()));
    return r % max;
}

pub fn main(init: std.process.Init) !void {
    _ = libc.signal(libc.SIGINT, handleSigInt);
    _ = libc.srand(@as(u32, @intCast(libc.time(null))) ^ @as(u32, @intCast(libc.getpid())));

    // probe the host's sound + speech once; every playSound/speak after this
    // is a no-op when the host has nothing to offer (#25)
    audio_player = probeAudio();
    speech_available = probeSpeech();
    if (audio_player == .none) {
        _ = libc.printf("💨 no audio player found — running silent (want afplay, paplay, aplay or ffplay)\n");
    } else if (!speech_available) {
        _ = libc.printf("💨 no speech synth found — the butt is mute (want say or espeak)\n");
    }

    // kujamba mode: fart kujamba <swahili phrase> — the butt speaks.
    var args_iter = init.minimal.args.iterate();
    _ = args_iter.skip(); // program name
    if (args_iter.next()) |first| {
        if (std.mem.eql(u8, first, "kujamba")) {
            var phrase_list = std.ArrayList(u8).initCapacity(std.heap.page_allocator, 64) catch unreachable;
            defer phrase_list.deinit(std.heap.page_allocator);
            var first_word = true;
            while (args_iter.next()) |a| {
                if (!first_word) try phrase_list.append(std.heap.page_allocator, ' ');
                first_word = false;
                try phrase_list.appendSlice(std.heap.page_allocator, a);
            }
            if (phrase_list.items.len == 0) {
                _ = libc.printf("usage: fart kujamba <swahili phrase>\n");
                return;
            }
            runKujamba(phrase_list.items);
            return;
        }
    }

    _ = libc.printf("\x1b[?25l");

    // Flatlophone v2: Basso.aiff is retired. Pre-render the deterministic
    // shuzi library and open with one; the say voice line stays.
    for (shuzi_seeds, 0..) |seed, idx| {
        const wav = synth.renderShuziWav(std.heap.page_allocator, seed) catch continue;
        defer std.heap.page_allocator.free(wav);
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/tmp/fart_shuzi_{d}.wav", .{idx}) catch continue;
        _ = writeWavFile(path, wav);
    }
    playSound("/tmp/fart_shuzi_0.wav", 3);
    speak("Bad News", "Pfffffft!");

    var frame: usize = 0;
    while (is_running.load(.acquire)) {
        _ = libc.printf("\x1b[2J\x1b[H");

        const rand_val = getRandU(100000);

        const shake_x = getRand(5) - 2;
        const shake_y = getRand(5) - 2;

        if (rand_val % 300 == 0) {
            _ = libc.printf("\x1b[41m\x1b[93m");
            _ = libc.printf("\x1b[2J\x1b[H");

            _ = libc.printf("\x1b[%d;%dH", clamp(12 + shake_y), clamp(30 + shake_x));
            _ = libc.printf("      _.-^^---....,,--\n");
            _ = libc.printf("\x1b[%d;%dH", clamp(13 + shake_y), clamp(30 + shake_x));
            _ = libc.printf(" _--                  --_\n");
            _ = libc.printf("\x1b[%d;%dH", clamp(14 + shake_y), clamp(30 + shake_x));
            _ = libc.printf("<       NUCLEAR FART     >)\n");
            _ = libc.printf("\x1b[%d;%dH", clamp(15 + shake_y), clamp(30 + shake_x));
            _ = libc.printf(" |._                   _./\n");
            _ = libc.printf("\x1b[%d;%dH", clamp(16 + shake_y), clamp(30 + shake_x));
            _ = libc.printf("    ```--. . , ; .--'''  \n");
            _ = libc.fflush(null);

            if (builtin.os.tag == .macos) {
                _ = libc.system("say -v 'Bad News' 'TACTICAL NUKE INCOMING' & afplay -v 5 /System/Library/Sounds/Blow.aiff &");
            } else {
                // no Blow.aiff outside macOS; the loudest shuzi steps in
                speak("Bad News", "TACTICAL NUKE INCOMING");
                playSound("/tmp/fart_shuzi_0.wav", 5);
            }
            _ = libc.usleep(1000 * 1000);
            frame += 1;
            continue;
        }

        if (rand_val % 4 == 0) {
            const bg = bg_colors[getRandU(bg_colors.len)];
            _ = libc.printf("%s", bg.ptr);
        } else {
            _ = libc.printf("\x1b[40m");
        }

        var j: usize = 0;
        const num_emojis = getRandU(30);
        while (j < num_emojis) : (j += 1) {
            const rx = clamp(getRand(80) + 1 + shake_x);
            const ry = clamp(getRand(24) + 1 + shake_y);
            const emojis = [_][]const u8{ "💨", "💩", "🤮", "🤢", "🍑", "💥" };
            const emoji = emojis[getRandU(emojis.len)];
            _ = libc.printf("\x1b[%d;%dH%s", ry, rx, emoji.ptr);
        }

        if (rand_val % 2 == 0) {
            const rx = clamp(getRand(80) + 1 + shake_x);
            const ry = clamp(getRand(24) + 1 + shake_y);
            _ = libc.printf("\x1b[%d;%dH✨", ry, rx);
        }
        if (rand_val % 3 == 0) {
            const rx = clamp(getRand(80) + 1 + shake_x);
            const ry = clamp(getRand(24) + 1 + shake_y);
            _ = libc.printf("\x1b[%d;%dH\x1b[32m~ ~ ~\x1b[0m", ry, rx);
        }
        if (rand_val % 4 == 0) {
            const rx = clamp(getRand(80) + 1 + shake_x);
            const ry = clamp(getRand(24) + 1 + shake_y);
            _ = libc.printf("\x1b[%d;%dH\x1b[36mo O ◦\x1b[0m", ry, rx);
        }
        if (rand_val % 5 == 0) {
            const rx = clamp(getRand(80) + 1 + shake_x);
            const ry = clamp(getRand(24) + 1 + shake_y);
            _ = libc.printf("\x1b[%d;%dH\x1b[42m  \x1b[0m", ry, rx);
        }
        if (rand_val % 6 == 0) {
            const rx = clamp(getRand(80) + 1 + shake_x);
            const ry = clamp(getRand(24) + 1 + shake_y);
            _ = libc.printf("\x1b[%d;%dH\x1b[93m☢️\x1b[0m", ry, rx);
        }

        const c_col = colors[getRandU(colors.len)];
        _ = libc.printf("%s", c_col.ptr);

        const current_butt = butt_frames[frame % butt_frames.len];
        var lines = std.mem.splitScalar(u8, current_butt, '\n');
        var row = clamp(10 + shake_y);
        while (lines.next()) |line| {
            const col = clamp(30 + shake_x);
            _ = libc.printf("\x1b[%d;%dH%.*s\n", row, col, @as(c_int, @intCast(line.len)), line.ptr);
            row += 1;
        }

        const cloud_col = colors[getRandU(colors.len)];
        _ = libc.printf("%s", cloud_col.ptr);
        const current_cloud = fart_clouds[(frame / 2) % fart_clouds.len];
        var cloud_lines = std.mem.splitScalar(u8, current_cloud, '\n');
        row = clamp(14 + shake_y);
        while (cloud_lines.next()) |line| {
            const col = clamp(45 + shake_x);
            _ = libc.printf("\x1b[%d;%dH%.*s\n", row, col, @as(c_int, @intCast(line.len)), line.ptr);
            row += 1;
        }

        if (getRandU(15) == 0) {
            var path_buf: [32]u8 = undefined;
            const shuzi_path = std.fmt.bufPrintZ(&path_buf, "/tmp/fart_shuzi_{d}.wav", .{getRandU(shuzi_seeds.len)}) catch continue;
            playSound(shuzi_path, 2);
        }

        if (getRandU(20) == 0) {
            speak("Ralph", "pfffffft");
        }

        var dummy_var: i32 = 42;
        const dummy_ptr: *anyopaque = @ptrFromInt(@intFromPtr(&dummy_var));
        _ = dummy_ptr;

        _ = libc.fflush(null);

        frame += 1;
        _ = libc.usleep(80 * 1000);
    }

    restoreTerminal();
    _ = libc.printf("\n💨 PFFFFFT! DONE.\n");
}

// ---- tests ---------------------------------------------------------------------

const testing = std.testing;

test "sound command per player" {
    var buf: [160]u8 = undefined;
    try testing.expectEqualStrings("afplay -v 3 /tmp/fart.wav &", soundCommand(&buf, .afplay, "/tmp/fart.wav", 3).?);
    try testing.expectEqualStrings("paplay --volume=3 /tmp/fart.wav &", soundCommand(&buf, .paplay, "/tmp/fart.wav", 3).?);
    try testing.expectEqualStrings("aplay -q /tmp/fart.wav &", soundCommand(&buf, .aplay, "/tmp/fart.wav", 3).?);
    try testing.expectEqualStrings("ffplay -loglevel quiet -nodisp -autoexit /tmp/fart.wav &", soundCommand(&buf, .ffplay, "/tmp/fart.wav", 3).?);
    try testing.expectEqual(@as(?[:0]const u8, null), soundCommand(&buf, .none, "/tmp/fart.wav", 3));
}

test "command probe finds sh and misses nonsense" {
    try testing.expect(haveCommand("sh"));
    try testing.expect(!haveCommand("definitely-not-a-command-xyzzy"));
}
