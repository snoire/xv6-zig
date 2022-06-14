const std = @import("std");
const Builder = std.build.Builder;

const target: std.zig.CrossTarget = .{
    .cpu_arch = .riscv64,
    .os_tag = .freestanding,
    .abi = .none,
};

var mode: std.builtin.Mode = undefined;
var is_strip: bool = false;

var usys_step: *std.build.Step = undefined;
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
    "sh",
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
};

const kfiles = .{
    "entry.S",
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

    "start.c",
    "console.c",
    "printf.c",
    "uart.c",
    "spinlock.c",

    //"kcsan.c",
};

pub fn build(b: *Builder) void {
    mode = b.standardReleaseOptions();
    is_strip = b.option(bool, "strip", "Removes symbols and sections from file") orelse false;

    // build kernel
    const kernel = b.addExecutable("kernel", null);

    inline for (kfiles) |f| {
        const path = "kernel/" ++ f;

        if (std.mem.eql(u8, ".S", std.fs.path.extension(f))) {
            kernel.addAssemblyFile(path);
        } else {
            kernel.addCSourceFile(path, &.{});
        }
    }

    kernel.setLinkerScriptPath(.{ .path = "kernel/kernel.ld" });
    kernel.setBuildMode(mode);
    kernel.setTarget(target);

    kernel.code_model = .medium;
    kernel.strip = is_strip;

    kernel.omit_frame_pointer = false;
    kernel.disable_sanitize_c = true; // TODO: fix it

    kernel.override_dest_dir = .{ .custom = "./" };
    kernel.install();

    const kernel_tls = b.step("kernel", "Build kernel");
    kernel_tls.dependOn(&kernel.step);

    // generate usys.S
    const usys = b.addSystemCommand(&.{ "sh", "-c", "./user/usys.pl > user/usys.S" });
    usys_step = &usys.step;

    // build user applications
    apps_step = b.step("apps", "Compiles apps");

    inline for (capps) |app| {
        build_app(b, app, .c);
    }

    inline for (zapps) |app| {
        build_app(b, app, .zig);
    }

    // build mkfs
    const mkfs = b.addExecutable("mkfs", null);

    mkfs.addIncludePath("./");
    mkfs.addCSourceFile("mkfs/mkfs.c", &.{"-fno-sanitize=undefined"});
    mkfs.linkLibC();

    mkfs.override_dest_dir = .{ .custom = "./" };
    mkfs.install();

    // build fs.img
    const fs = mkfs.run();
    //fs.print = true;

    fs.addArg(b.pathJoin(&.{ b.install_prefix, "fs.img" }));
    fs.addArg("README");

    inline for (capps ++ zapps) |app| {
        fs.addArg(b.pathJoin(&.{ b.install_prefix, "apps", app }));
    }

    fs.step.dependOn(b.getInstallStep());

    const fs_tls = b.step("fs", "Build fs.img");
    fs_tls.dependOn(&fs.step);

    // run qemu
    var qemu_tls = b.step("run", "Run xv6 in QEMU");
    var qemu = b.addSystemCommand(&.{
        // zig fmt: off
        "qemu-system-riscv64",
        "-machine", "virt",
        "-bios", "none",
        //"-cpu", "rv64,pmp=false", // can't start?
        "-kernel", b.pathJoin(&.{ b.install_prefix, "kernel" }),
        "-m", "128M",
        "-smp", "3", // TODO
        "-nographic",
        "-drive", b.fmt("file={s},if=none,format=raw,id=x0", .{b.pathJoin(&.{ b.install_prefix, "fs.img" })}),
        "-device", "virtio-blk-device,drive=x0,bus=virtio-mmio-bus.0",
        // TODO: netdev?
        // zig fmt: on
    });

    qemu.step.dependOn(b.getInstallStep());
    qemu_tls.dependOn(&qemu.step);
}

fn build_app(b: *Builder, comptime appName: []const u8, comptime lang: Lang) void {
    const app = b.addExecutable(appName, if (lang == .zig) "user/" ++ appName ++ ".zig" else null);

    if (lang == .c) {
        app.addIncludePath("./");
        app.addAssemblyFile("user/usys.S");
        app.addCSourceFiles(&.{
            "user/" ++ appName ++ ".c",
            "user/ulib.c",
            "user/printf.c",
            "user/umalloc.c",
        }, &.{});

        app.step.dependOn(usys_step);
    }

    app.setBuildMode(mode);
    app.setTarget(target);

    app.code_model = .medium;
    app.strip = is_strip;

    app.setLinkerScriptPath(.{ .path = "linker.ld" });
    app.omit_frame_pointer = false;

    app.override_dest_dir = .{ .custom = "apps/" };
    app.install();

    apps_step.dependOn(&app.step);
}
