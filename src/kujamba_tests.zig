//! Test root for the kujamba instrument plus the vendored NINJAM modules.
//! Aggregates: kujamba glue tests, kujamba CLI analysis, the config/preset
//! file parser, the protocol fuzz harness (#26), the M5 timing harness (#13,
//! #14), and every unit test shipped with the vendored zclient subset
//! (protocol, framing, vorbis, WAV, session engine). `zig build test` runs this
//! alongside the fart/audit suites; the fuzz harness's corpus runs as part of
//! it, and `zig build test --fuzz` coverage-guides the same path (see
//! src/proto_fuzz.zig).

const std = @import("std");

test {
    std.testing.refAllDecls(@import("ninjam_out.zig"));
    _ = @import("ninjam_out.zig");
    std.testing.refAllDecls(@import("kujamba_main.zig"));
    _ = @import("kujamba_main.zig");
    std.testing.refAllDecls(@import("kujamba_config.zig"));
    _ = @import("kujamba_config.zig");
    _ = @import("proto_fuzz.zig");
    std.testing.refAllDecls(@import("kujamba_timing.zig"));
    _ = @import("kujamba_timing.zig");
    _ = @import("kujamba_backpressure.zig");
    _ = @import("ninjam/tests.zig");
}
