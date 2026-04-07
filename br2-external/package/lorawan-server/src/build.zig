const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sysroot = b.option([]const u8, "sysroot", "Target sysroot path used to resolve sqlite3");
    const resolved_sysroot: ?[]const u8 = if (sysroot) |sr| sr else if (builtin.os.tag == .linux) "/" else null;
    const exe = b.addExecutable(.{
        .name = "lorawan-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_llvm = true,
    });
    exe.linker_allow_shlib_undefined = true;

    if (resolved_sysroot) |sr| {
        const usr_lib = b.fmt("{s}/usr/lib", .{sr});
        const usr_lib64 = b.fmt("{s}/usr/lib64", .{sr});
        const lib = b.fmt("{s}/lib", .{sr});
        const lib64 = b.fmt("{s}/lib64", .{sr});
        const usr_include = b.fmt("{s}/usr/include", .{sr});
        exe.addLibraryPath(.{ .cwd_relative = usr_lib });
        exe.addLibraryPath(.{ .cwd_relative = usr_lib64 });
        exe.addLibraryPath(.{ .cwd_relative = lib });
        exe.addLibraryPath(.{ .cwd_relative = lib64 });
        exe.root_module.addIncludePath(.{ .cwd_relative = usr_include });
    }
    exe.root_module.linkSystemLibrary("sqlite3", .{ .needed = true });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the LoRaWAN UDP bridge");
    run_step.dependOn(&run_cmd.step);
}
