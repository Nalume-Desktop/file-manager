const std = @import("std");
const Backend = enum { wayland, testing };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const app = appModule(b, "src/file_manager.zig", target, optimize, .wayland, false);
    const exe = b.addExecutable(.{ .name = "zfiler", .root_module = app, .use_llvm = true });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run zfiler").dependOn(&run.step);
    const test_step = b.step("test", "Run file manager state regressions");
    const state = b.createModule(.{ .root_source_file = b.path("src/file_manager_test.zig"), .target = target, .optimize = optimize, .link_libc = true });
    state.addImport("file_operations", b.dependency("file_operations", .{ .target = target, .optimize = optimize }).module("file_operations"));
    const state_tests = b.addTest(.{ .root_module = state, .use_llvm = true });
    test_step.dependOn(&b.addRunArtifact(state_tests).step);
}

fn appModule(b: *std.Build, root: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, backend: Backend, native_types: bool) *std.Build.Module {
    const options = .{ .target = target, .optimize = optimize, .backend = backend, .@"native-types" = native_types };
    const module = b.createModule(.{ .root_source_file = b.path(root), .target = target, .optimize = optimize, .link_libc = true });
    module.addImport("dvui", b.dependency("dvui", options).module("dvui"));
    module.addImport("views", b.dependency("views", options).module("views"));
    module.addImport("nalume_ui", b.dependency("nalume_ui", options).module("nalume_ui"));
    module.addImport("system_icons", b.dependency("system_icons", options).module("system_icons"));
    module.addImport("file_operations", b.dependency("file_operations", .{ .target = target, .optimize = optimize }).module("file_operations"));
    return module;
}
