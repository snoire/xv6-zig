const std = @import("std");
const xv6 = @import("kernel/xv6.zig");
const BuildApps = @import("Build/Apps.zig");
const BuildFs = @import("Build/Fs.zig");

const apps = [_]BuildApps.App{
    .{ .name = "cat", .type = .c },
    .{ .name = "echo", .type = .c },
    .{ .name = "forktest", .type = .c },
    .{ .name = "grep", .type = .c },
    .{ .name = "init", .type = .c },
    .{ .name = "kill", .type = .c },
    .{ .name = "ln", .type = .c },
    .{ .name = "ls", .type = .c },
    .{ .name = "mkdir", .type = .c },
    .{ .name = "rm", .type = .c },
    .{ .name = "stressfs", .type = .c },
    .{ .name = "usertests", .type = .c },
    .{ .name = "grind", .type = .c },
    .{ .name = "wc", .type = .c },
    .{ .name = "zombie", .type = .c },
    .{ .name = "primes", .type = .c },
    .{ .name = "find", .type = .c },
    .{ .name = "xargs", .type = .c },

    .{ .name = "sleep", .type = .{ .link_c = false } },
    .{ .name = "pingpong", .type = .{ .link_c = false } },
    .{ .name = "sh", .type = .{ .link_c = true } },
};

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

    "bio.c",
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
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Removes symbols and sections from file");

    // initcode
    const initcode_elf = b.addExecutable(.{
        .name = "initcode",
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });

    initcode_elf.addAssemblyFile(.{ .path = "user/initcode.S" });
    initcode_elf.addIncludePath(.{ .path = "kernel/" });
    initcode_elf.entry = .{ .symbol_name = "start" };
    initcode_elf.setLinkerScript(.{ .path = "user/initcode.ld" });

    const initcode_bin = initcode_elf.addObjCopy(.{ .format = .bin });

    // build kernel
    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = .{ .path = "kernel/start.zig" },
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = false,
    });

    kernel.addIncludePath(.{ .path = "kernel/" });
    kernel.entry = .{ .symbol_name = "_entry" };
    kernel.setLinkerScript(.{ .path = "kernel/kernel.ld" });

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

    kernel.root_module.addAnonymousImport("initcode", .{
        .root_source_file = initcode_bin.getOutput(),
    });

    kernel.root_module.code_model = .medium;

    const install_kernel = b.addInstallArtifact(kernel, .{
        .dest_dir = .{ .override = .{ .custom = "./" } },
    });
    b.getInstallStep().dependOn(&install_kernel.step);

    const kernel_tls = b.step("kernel", "Build kernel");
    kernel_tls.dependOn(&install_kernel.step);

    const kernel_module = b.createModule(.{
        .root_source_file = .{ .path = "kernel/xv6.zig" },
    });

    // build user applications
    const apps_step = b.step("apps", "Compiles apps");
    const build_apps = BuildApps.create(b, &apps, .{
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .kernel_module = kernel_module,
    });
    apps_step.dependOn(&build_apps.step);

    // build fs.img
    const build_fs = BuildFs.create(b, "fs.img", build_apps.getOutput(), &.{"README.md"});
    const install_fs_img = b.addInstallFile(build_fs.getOutput(), "fs.img");
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
