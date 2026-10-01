//! Compatibility entrypoint for the upstreamed full-session pressure/recovery rig.
const pressure = @import("ninjam/backpressure_test.zig");
pub const main = pressure.main;
pub const reproduce = pressure.reproduce;
