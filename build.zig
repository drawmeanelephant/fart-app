const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // #20: the Phase-B live audio path (vendored miniaudio + the zc_* shim).
    // Defaults on for macOS (CoreAudio) and off everywhere else, so the Linux
    // build stays ALSA-free unless the flag asks for it.
    const live = b.option(bool, "live", "Phase B live audio via miniaudio (default: on when targeting macOS)") orelse
        (target.result.os.tag == .macos);
    const live_option = b.addOptions();
    live_option.addOption(bool, "live", live);

    // -------------------------------------------------------------------------
    // fart: the app itself
    // -------------------------------------------------------------------------
    const fart_exe = b.addExecutable(.{
        .name = "fart",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fart_exe.root_module.link_libc = true;
    b.installArtifact(fart_exe);

    const run_fart = b.addRunArtifact(fart_exe);
    run_fart.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_fart.addArgs(args);
    const run_step = b.step("run", "Run the fart app");
    run_step.dependOn(&run_fart.step);

    // -------------------------------------------------------------------------
    // audit: the RAG manifest generator
    // -------------------------------------------------------------------------
    const audit_exe = b.addExecutable(.{
        .name = "audit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/audit.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(audit_exe);

    const run_audit = b.addRunArtifact(audit_exe);
    run_audit.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_audit.addArgs(args);
    const audit_step = b.step("audit", "Run the RAG audit manifest generator");
    audit_step.dependOn(&run_audit.step);

    // -------------------------------------------------------------------------
    // kujamba: Flatlophone as a headless NINJAM instrument
    // -------------------------------------------------------------------------
    const kujamba_exe = b.addExecutable(.{
        .name = "kujamba",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kujamba_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    kujambaDeps(b, kujamba_exe.root_module, live, live_option);
    b.installArtifact(kujamba_exe);

    const run_kujamba = b.addRunArtifact(kujamba_exe);
    run_kujamba.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_kujamba.addArgs(args);
    const kujamba_run_step = b.step("run-kujamba", "Run the kujamba NINJAM instrument");
    kujamba_run_step.dependOn(&run_kujamba.step);

    // -------------------------------------------------------------------------
    // test: audit + synth + golden + kujamba
    // -------------------------------------------------------------------------
    const audit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/audit.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(audit_tests);
    const test_step = b.step("test", "Run audit, synth, golden and kujamba test suites");
    test_step.dependOn(&run_tests.step);

    // synth.zig is libc-free, so its test module links no libc either.
    const synth_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/synth.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_synth_tests = b.addRunArtifact(synth_tests);
    test_step.dependOn(&run_synth_tests.step);

    // Golden fingerprints: the byte-level guard on what the synth actually
    // renders. Its own target so the check keeps running even while synth.zig's
    // test module is being rewritten. libc-free, like synth.
    const golden_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/golden.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_golden_tests = b.addRunArtifact(golden_tests);
    test_step.dependOn(&run_golden_tests.step);

    // kujamba: the instrument + every unit test in the vendored NINJAM subset
    // (framing, protocol, auth, vorbis encode/decode, WAV, session engine).
    const kujamba_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kujamba_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    kujambaDeps(b, kujamba_tests.root_module, live, live_option);
    const run_kujamba_tests = b.addRunArtifact(kujamba_tests);
    test_step.dependOn(&run_kujamba_tests.step);

    // fart app platform glue (#25): the audio player probe and sound command
    // builder are testable without a display, so they join `zig build test`
    const fart_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fart_tests.root_module.link_libc = true;
    const run_fart_tests = b.addRunArtifact(fart_tests);
    test_step.dependOn(&run_fart_tests.step);

    // #20: report the live-audio build state (same idea as zclient's step).
    const live_step = b.step("live", "Report live-audio build state");
    live_step.dependOn(&live_option.step);
}

// ---------------------------------------------------------------------------
// kujamba instrument wiring: vendored C deps + build options
// ---------------------------------------------------------------------------

/// libogg + libvorbis (encode) + stb_vorbis (decode), compiled exactly like
/// zclient's build does. miniaudio (the Phase-B live device, #20) compiles in
/// only when `live` is on: the default for macOS builds, `-Dlive` elsewhere.
fn kujambaDeps(b: *std.Build, mod: *std.Build.Module, live: bool, live_option: *std.Build.Step.Options) void {
    mod.link_libc = true;
    mod.addIncludePath(b.path("vendor"));
    mod.addIncludePath(b.path("vendor/libogg/include"));
    mod.addIncludePath(b.path("vendor/libvorbis/include"));
    mod.addIncludePath(b.path("vendor/libvorbis/lib"));
    mod.addCSourceFiles(.{ .root = b.path("vendor"), .files = &kujamba_c_sources, .flags = &kujamba_c_flags });
    if (live) {
        // miniaudio.h is 4 MB of macro soup and does not survive translate-c,
        // so it compiles in exactly one C TU behind the zc_* shim.
        const miniaudio_sources = [_][]const u8{"miniaudio_impl.c"};
        mod.addCSourceFiles(.{ .root = b.path("vendor"), .files = &miniaudio_sources, .flags = &kujamba_c_flags });
        switch (mod.resolved_target.?.result.os.tag) {
            .macos => {
                // Apple frameworks miniaudio's CoreAudio backend needs.
                const frameworks = [_][]const u8{ "CoreAudio", "AudioToolbox", "AudioUnit", "CoreFoundation", "CoreServices" };
                for (frameworks) |fw| mod.linkFramework(fw, .{});
            },
            .linux => {
                mod.linkSystemLibrary("asound", .{});
                mod.linkSystemLibrary("pthread", .{});
                mod.linkSystemLibrary("dl", .{});
                mod.linkSystemLibrary("m", .{});
            },
            else => {},
        }
    }
    mod.addOptions("build_options", live_option);
}

const kujamba_c_flags = [_][]const u8{
    "-std=gnu99",
    // libvorbis relies on wrapping shift semantics (psy.c); zig cc's UBSan
    // turns that into a runtime panic, so opt the vendored C out of UBSan.
    "-fno-sanitize=undefined",
};

const kujamba_c_sources = [_][]const u8{
    "libogg/src/bitwise.c",
    "libogg/src/framing.c",
    "libvorbis/lib/analysis.c",
    "libvorbis/lib/bitrate.c",
    "libvorbis/lib/block.c",
    "libvorbis/lib/codebook.c",
    "libvorbis/lib/envelope.c",
    "libvorbis/lib/floor0.c",
    "libvorbis/lib/floor1.c",
    "libvorbis/lib/info.c",
    "libvorbis/lib/lookup.c",
    "libvorbis/lib/lpc.c",
    "libvorbis/lib/lsp.c",
    "libvorbis/lib/mapping0.c",
    "libvorbis/lib/mdct.c",
    "libvorbis/lib/psy.c",
    "libvorbis/lib/registry.c",
    "libvorbis/lib/res0.c",
    "libvorbis/lib/sharedbook.c",
    "libvorbis/lib/smallft.c",
    "libvorbis/lib/synthesis.c",
    "libvorbis/lib/vorbisenc.c",
    "libvorbis/lib/window.c",
    "stb_vorbis_impl.c",
};
