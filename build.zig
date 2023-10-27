const std = @import("std");
const xv6 = @import("kernel/xv6.zig");
const FileSource = std.build.FileSource;

const target: std.zig.CrossTarget = .{
    .cpu_arch = .riscv64,
    .os_tag = .freestanding,
    .abi = .none,
};

var kernel_module: *std.Build.Module = undefined;
var optimize: std.builtin.Mode = undefined;
var apps_step: *std.build.Step = undefined;
var strip: ?bool = false;

const capps = .{
    "cat",
    "echo",
    "forktest",
    "grep",
    "init",
    "kill",
    "ln",
    "ls",
    "mkdir",
    "rm",
    //"sh",
    "stressfs",
    "usertests",
    "grind",
    "wc",
    "zombie",
    "primes",
    "find",
    "xargs",
};

const zapps = .{
    "sleep",
    "pingpong",
    "sh",
};

const apps_linking_c = std.ComptimeStringMap(void, .{
    .{"sh"},
});

const kfiles = .{
    "swtch.S",
    "trampoline.S",
    "kernelvec.S",

    // "trap.c",
    // "kalloc.c",
    // "vm.c",
    // "proc.c",
    // "syscall.c",
    // "sysproc.c",
    // "sysfile.c",
    // "exec.c",

    // "bio.c",
    "fs.c",
    "log.c",
    "file.c",
    "pipe.c",
    // "plic.c",
    "virtio_disk.c",

    "string.c",
    "console.c",
    // "printf.c",
    "uart.c",
    "sleeplock.c",
    "spinlock.c",

    //"kcsan.c",
};

pub fn build(b: *std.Build) void {
    // compilation options
    optimize = b.standardOptimizeOption(.{});
    strip = b.option(bool, "strip", "Removes symbols and sections from file");

    // initcode
    const initcode_elf = b.addExecutable(.{
        .name = "initcode",
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
    });

    initcode_elf.addAssemblyFile(.{ .path = "user/initcode.S" });
    initcode_elf.addIncludePath(.{ .path = "kernel/" });
    initcode_elf.setLinkerScriptPath(.{ .path = "user/initcode.ld" });

    const initcode_bin = initcode_elf.addObjCopy(.{ .format = .bin });

    // build kernel
    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = .{ .path = "kernel/start.zig" },
        .target = target,
        .optimize = optimize,
    });

    kernel.addIncludePath(.{ .path = "kernel/" });
    kernel.setLinkerScriptPath(.{ .path = "kernel/kernel.ld" });

    inline for (kfiles) |f| {
        const path = "kernel/" ++ f;
        if (std.mem.endsWith(u8, f, ".S")) {
            kernel.addAssemblyFile(.{ .path = path });
        } else {
            kernel.addCSourceFile(.{
                .file = .{ .path = path },
                .flags = &.{},
            });
        }
    }

    kernel.addAnonymousModule("initcode", .{
        .source_file = initcode_bin.getOutputSource(),
    });

    kernel.strip = strip;
    kernel.code_model = .medium;
    kernel.omit_frame_pointer = false;
    kernel.disable_sanitize_c = true; // TODO: fix it

    const install_kernel = b.addInstallArtifact(kernel, .{
        .dest_dir = .{ .override = .{ .custom = "./" } },
    });
    b.getInstallStep().dependOn(&install_kernel.step);

    const kernel_tls = b.step("kernel", "Build kernel");
    kernel_tls.dependOn(&install_kernel.step);

    // build mkfs
    const mkfs = b.addExecutable(.{
        .name = "mkfs",
        .root_source_file = .{ .path = "mkfs/mkfs.zig" },
        .optimize = optimize,
    });

    mkfs.addIncludePath(.{ .path = "./" });
    kernel_module = b.createModule(.{
        .source_file = FileSource.relative("kernel/xv6.zig"),
    });
    mkfs.addModule("kernel", kernel_module);

    mkfs.strip = strip;
    mkfs.single_threaded = true;

    const mkfs_tls = b.step("mkfs", "Build mkfs");
    const install_mkfs = b.addInstallArtifact(mkfs, .{
        .dest_dir = .{ .override = .{ .custom = "./" } },
    });
    mkfs_tls.dependOn(&install_mkfs.step);

    // build user applications
    apps_step = b.step("apps", "Compiles apps");

    var all_apps: [capps.len + zapps.len]FileSource = undefined;

    inline for (capps, 0..) |app, i| {
        all_apps[i] = buildApp(b, app, .c);
    }
    inline for (zapps, capps.len..) |app, i| {
        all_apps[i] = buildApp(b, app, .zig);
    }

    // build fs.img
    // run mkfs to build the initial file system
    const run_mkfs = b.addRunArtifact(mkfs);
    const fs_img = run_mkfs.addOutputFileArg("fs.img");
    run_mkfs.addArg("README.md");

    for (all_apps) |app| {
        run_mkfs.addFileSourceArg(app);
    }

    // fs.img will be regenerated when README are modified.
    run_mkfs.extra_file_dependencies = &.{"README.md"};
    _ = run_mkfs.captureStdErr();

    const install_fs_img = b.addInstallFile(fs_img, "fs.img");
    b.getInstallStep().dependOn(&install_fs_img.step);

    const fs_tls = b.step("fs", "Build fs.img");
    fs_tls.dependOn(&install_fs_img.step);

    // runtime options
    const cpus = blk: {
        const description = b.fmt("Number of cpus (1-{})", .{xv6.NCPU});
        const option = b.option([]const u8, "cpus", description) orelse "3";

        const message = b.fmt("cpus must be in the range of [1-{}].", .{xv6.NCPU});
        const number = std.fmt.parseInt(u4, option, 0) catch @panic(message);
        if (number > xv6.NCPU or number == 0) @panic(message);

        break :blk option;
    };

    const fs_img_path = b.option([]const u8, "fs-path", "Path to the fs.img") orelse
        b.pathJoin(&.{ b.install_prefix, "fs.img" });

    // run xv6 in qemu
    const kernel_path = b.pathJoin(&.{ b.install_prefix, "kernel" });
    const qemu_cmd = "qemu-system-riscv64";
    const qemu_args = [_][]const u8{
        "-machine",   "virt",
        "-bios",      "none",
        "-kernel",    kernel_path,
        "-m",         "128M",
        "-smp",       cpus,
        "-global",    "virtio-mmio.force-legacy=false",
        "-drive",     b.fmt("file={s},if=none,format=raw,id=x0", .{fs_img_path}),
        "-device",    "virtio-blk-device,drive=x0,bus=virtio-mmio-bus.0",
        "-nographic",
    };

    const run_tls = b.step("run", "Run xv6 in QEMU");
    const run = b.addSystemCommand(&.{qemu_cmd});
    run.addArgs(&qemu_args);

    run.step.dependOn(&install_kernel.step);
    run.step.dependOn(&install_fs_img.step);
    run_tls.dependOn(&run.step);

    // run qemu with gdb server
    const qemu_tls = b.step("qemu", "Run xv6 in QEMU with gdb server");
    const qemu = b.addSystemCommand(&.{qemu_cmd});
    qemu.addArgs(&qemu_args);
    qemu.addArgs(&.{ "-gdb", "tcp::26002", "-S" });

    qemu.step.dependOn(&install_kernel.step);
    qemu.step.dependOn(&install_fs_img.step);
    qemu_tls.dependOn(&qemu.step);

    // debug with gdb
    const gdb_tls = b.step("gdb", "Debug with gdb");
    const gdb = b.addSystemCommand(&.{ "riscv64-unknown-elf-gdb", kernel_path, "-q", "-n", "-x", "gdbinit" });

    gdb.step.dependOn(&install_kernel.step);
    gdb_tls.dependOn(&gdb.step);

    // display code information
    const objdump_tls = b.step("code", "Display code information");
    const objdump = b.addSystemCommand(&.{ "riscv64-unknown-elf-objdump", "-SD", kernel_path });

    objdump.step.dependOn(&install_kernel.step);
    objdump_tls.dependOn(&objdump.step);

    // translates addresses of stack trace
    const addr2line_tls = b.step("addr2line", "Translates addresses of stack trace");
    const addr2line = b.addSystemCommand(&.{
        "addr2line",
        "-e",
        kernel_path,
    });

    if (b.args) |args| {
        addr2line.addArgs(args);
    }

    addr2line.step.dependOn(&install_kernel.step);
    addr2line_tls.dependOn(&addr2line.step);
}

fn buildApp(b: *std.Build, comptime appName: []const u8, comptime lang: enum { c, zig }) FileSource {
    const app = b.addExecutable(.{
        .name = appName,
        .root_source_file = if (lang == .zig)
            .{ .path = "user/" ++ appName ++ ".zig" }
        else
            null,
        .target = target,
        .optimize = optimize,
    });
    app.addModule("kernel", kernel_module);

    if (lang == .c) {
        app.addIncludePath(.{ .path = "./" });
        app.addObjectFile(.{ .path = "user/usys.zig" });
        app.addCSourceFiles(.{
            .files = &.{
                "user/" ++ appName ++ ".c",
                "user/ulib.c",
                "user/printf.c",
                "user/umalloc.c",
            },
        });
    } else {
        if (apps_linking_c.has(appName)) {
            app.addIncludePath(.{ .path = "./" });
            app.addCSourceFile(.{
                .file = .{ .path = "user/umalloc.c" },
                .flags = &.{},
            });
        }
    }

    app.strip = strip;
    app.code_model = .medium;
    app.omit_frame_pointer = false;
    app.setLinkerScriptPath(.{ .path = "user/app.ld" });

    const install_app = b.addInstallArtifact(app, .{
        .dest_dir = .{ .override = .{ .custom = "apps/" } },
    });
    apps_step.dependOn(&install_app.step);

    return app.getOutputSource();
}
