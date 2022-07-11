const std = @import("std");
const Builder = std.build.Builder;

const target: std.zig.CrossTarget = .{
    .cpu_arch = .riscv64,
    .os_tag = .freestanding,
    .abi = .none,
};

var mode: std.builtin.Mode = undefined;
var strip: bool = false;

var apps_step: *std.build.Step = undefined;

const Lang = enum {
    c,
    zig,
};

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

const kfiles = .{
    "kernel.zig",
    "swtch.S",
    "trampoline.S",
    "kernelvec.S",

    "kalloc.c",
    "string.c",
    "main.c",
    "vm.c",
    "proc.c",
    "trap.c",
    "syscall.c",
    "sysproc.c",
    "bio.c",
    "fs.c",
    "log.c",
    "sleeplock.c",
    "file.c",
    "pipe.c",
    "exec.c",
    "sysfile.c",
    "plic.c",
    "virtio_disk.c",

    "console.c",
    "printf.c",
    "uart.c",
    "spinlock.c",

    //"kcsan.c",
};

pub fn build(b: *Builder) void {
    mode = b.standardReleaseOptions();
    strip = b.option(bool, "strip", "Removes symbols and sections from file") orelse false;

    // build kernel
    const kernel = b.addExecutable("kernel", null);
    kernel.addIncludePath("./");

    inline for (kfiles) |f| {
        const path = "kernel/" ++ f;
        kernel.addObjectFile(path);
    }

    kernel.setLinkerScriptPath(.{ .path = "kernel/kernel.ld" });
    kernel.setBuildMode(mode);
    kernel.setTarget(target);

    kernel.code_model = .medium;
    kernel.strip = strip;

    kernel.omit_frame_pointer = false;
    kernel.disable_sanitize_c = true; // TODO: fix it

    kernel.override_dest_dir = .{ .custom = "./" };
    kernel.install();

    const kernel_tls = b.step("kernel", "Build kernel");
    kernel_tls.dependOn(&kernel.step);

    // build user applications
    apps_step = b.step("apps", "Compiles apps");

    inline for (capps) |app| {
        build_app(b, app, .c);
    }

    inline for (zapps) |app| {
        build_app(b, app, .zig);
    }

    // build mkfs
    const mkfs = b.addExecutable("mkfs", "mkfs/mkfs.zig");
    mkfs.addIncludePath("./");

    mkfs.setBuildMode(mode);
    mkfs.single_threaded = true;
    mkfs.override_dest_dir = .{ .custom = "./" };
    mkfs.install();

    const mkfs_tls = b.step("mkfs", "Build mkfs");
    mkfs_tls.dependOn(&b.addInstallArtifact(mkfs).step);

    // build fs.img
    const fs = mkfs.run();

    fs.addArg(b.pathJoin(&.{ b.install_prefix, "fs.img" }));
    fs.addArg("README.md");

    inline for (capps ++ zapps) |app| {
        fs.addArg(b.pathJoin(&.{ b.install_prefix, "apps", app }));
    }

    fs.step.dependOn(apps_step);
    b.getInstallStep().dependOn(&fs.step);

    const fs_tls = b.step("fs", "Build fs.img");
    fs_tls.dependOn(&fs.step);

    // run qemu
    const kernel_path = b.pathJoin(&.{ b.install_prefix, "kernel" });
    const fs_img_path = b.pathJoin(&.{ b.install_prefix, "fs.img" });
    const qemu_cmd = "qemu-system-riscv64";
    const qemu_args = [_][]const u8{ // zig fmt: off
        "-machine",     "virt",
        "-bios",        "none",
        //"-cpu", "rv64,pmp=false", // can't start?
        "-kernel",      kernel_path,
        "-m",           "128M",
        "-smp",         "3", // TODO
        "-nographic",
        "-drive",       b.fmt("file={s},if=none,format=raw,id=x0", .{fs_img_path}),
        "-device",      "virtio-blk-device,drive=x0,bus=virtio-mmio-bus.0",
        // TODO: netdev?
    }; // zig fmt: on

    var run_tls = b.step("run", "Run xv6 in QEMU");
    var run = b.addSystemCommand(&.{qemu_cmd});
    run.addArgs(&qemu_args);

    run.step.dependOn(&kernel.step);
    run_tls.dependOn(&run.step);

    // run qemu with gdb server
    var qemu_tls = b.step("qemu", "Run xv6 in QEMU with gdb server");
    var qemu = b.addSystemCommand(&.{qemu_cmd});
    qemu.addArgs(&qemu_args);
    qemu.addArgs(&.{ "-gdb", "tcp::26002", "-S" });

    qemu.step.dependOn(&kernel.step);
    qemu_tls.dependOn(&qemu.step);

    // debug with gdb
    var gdb_tls = b.step("gdb", "Debug with gdb");
    var gdb = b.addSystemCommand(&.{
        "riscv64-unknown-elf-gdb",
        kernel_path,
        "-q",
        "-n",
        "-x",
        "gdbinit",
    });

    gdb.step.dependOn(&kernel.step);
    gdb_tls.dependOn(&gdb.step);

    // display code information
    var objdump_tls = b.step("code", "Display code information");
    var objdump = b.addSystemCommand(&.{
        "riscv64-unknown-elf-objdump",
        "-SD",
        kernel_path,
    });

    objdump.step.dependOn(&b.addInstallArtifact(kernel).step);
    objdump_tls.dependOn(&objdump.step);
}

fn build_app(b: *Builder, comptime appName: []const u8, comptime lang: Lang) void {
    const app = b.addExecutable(appName, if (lang == .zig) "user/" ++ appName ++ ".zig" else null);

    if (lang == .c) {
        app.addIncludePath("./");
        app.addObjectFile("user/usys.zig");
        app.addCSourceFiles(&.{
            "user/" ++ appName ++ ".c",
            "user/ulib.c",
            "user/printf.c",
            "user/umalloc.c",
        }, &.{});
    }

    app.setBuildMode(.ReleaseSafe);
    app.setTarget(target);

    app.code_model = .medium;
    app.strip = true;

    app.setLinkerScriptPath(.{ .path = "user/app.ld" });
    app.omit_frame_pointer = false;

    app.setOutputDir(b.pathJoin(&.{ b.install_prefix, "apps/" }));

    apps_step.dependOn(&app.step);
}
