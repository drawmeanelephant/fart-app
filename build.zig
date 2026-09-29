const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    // test: run audit.zig + synth.zig built-in test suites
    // -------------------------------------------------------------------------
    const audit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/audit.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(audit_tests);
    const test_step = b.step("test", "Run audit + synth unit tests");
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
}
