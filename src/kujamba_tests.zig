//! Test root for the kujamba instrument plus the vendored NINJAM modules.
//! Aggregates: kujamba glue tests, kujamba CLI analysis, the config/preset
//! file parser, and every unit test shipped with the vendored zclient subset
//! (protocol, framing, vorbis, WAV, session engine). `zig build test` runs
//! this alongside the fart/audit suites.

const std = @import("std");

test {
    std.testing.refAllDecls(@import("ninjam_out.zig"));
    _ = @import("ninjam_out.zig");
    std.testing.refAllDecls(@import("kujamba_main.zig"));
    _ = @import("kujamba_main.zig");
    std.testing.refAllDecls(@import("kujamba_config.zig"));
    _ = @import("kujamba_config.zig");
    _ = @import("ninjam/tests.zig");
}
