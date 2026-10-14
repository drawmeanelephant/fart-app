//! gen_engine_goldens.zig — prints the `expected_engines` table body for
//! golden.zig (M9, #95).
//!
//!     zig run src/gen_engine_goldens.zig
//!
//! Each row is the machine-measured fingerprint of one fart-off engine on one
//! of `golden.expected`'s inputs, rendered with identity knobs. The table is
//! generated rather than hand-written so a re-baseline is one command — the
//! same role `formatBaseline` plays for the stock table.
//!
//! Not imported by anything; it exists so `zig run` can reach the sibling
//! modules, and so regenerating the table never needs a build step.

const std = @import("std");
const golden = @import("golden.zig");
const registry = @import("engine_registry.zig");

pub fn main() !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    const alloc = debug_alloc.allocator();
    var io_state: std.Io.Threaded = .init(alloc, .{});
    const io = io_state.io();
    defer io_state.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try out.appendSlice(alloc, "pub const expected_engines = [_]Fingerprint{\n");
    for (registry.all) |id| {
        if (id == .stock) continue; // stock rows are `expected`
        try out.print(alloc, "    // {s}\n", .{registry.name(id)});
        for (golden.expected) |fp| {
            try golden.formatRow(alloc, &out, .{
                .name = fp.name,
                .engine = id,
                .kind = fp.kind,
                .input = fp.input,
                // measured fields are replaced by formatRow's own measurement;
                // the placeholders below satisfy the struct, nothing more
                .items = 0,
                .samples = 0,
                .peak = 0,
                .zero_crossings = 0,
                .rms_milli = 0,
                .envelope_sha256 = "",
                .wav_sha256 = "",
            });
        }
    }
    try out.appendSlice(alloc, "};\n");
    try std.Io.File.stdout().writeStreamingAll(io, out.items);
}
