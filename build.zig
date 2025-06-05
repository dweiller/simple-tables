pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const mod = b.addModule("table", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const mod_unit_tests = b.addTest(.{
        .root_module = mod,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(mod_unit_tests).step);
}

const std = @import("std");
