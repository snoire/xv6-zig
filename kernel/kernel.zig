const std = @import("std");
const xv6 = @import("xv6.zig");
const csr = xv6.register.csr;
const gpr = xv6.register.gpr;

export var stack0: [xv6.NCPU * 4096]u8 align(16) = undefined;
const main = @import("main.zig").main;
// assembly code in kernelvec.S for machine-mode timer interrupt.
extern fn timervec() void;

var timer_scratch: [xv6.NCPU][5]usize = undefined;

export fn _entry() linksection(".kernel_entry") callconv(.Naked) noreturn {
    asm volatile (
        \\  # set up a stack
        \\  # sp = stack0 + (hartid * 4096)
        \\      la sp, stack0
        \\      li a0, 1024*4
        \\	csrr a1, mhartid
        \\      addi a1, a1, 1
        \\      mul a0, a0, a1
        \\      add sp, sp, a0
        \\  # jump to start()
        \\      call start
        \\spin:
        \\      j spin
    );

    unreachable;
}

export fn start() callconv(.C) void {
    // set M Previous Privilege mode to Supervisor, for mret.
    var x = csr.read("mstatus");
    x &= ~@as(usize, csr.mstatus.mpp);
    x |= csr.mstatus.mpp_s;
    csr.write("mstatus", x);

    // set M Exception Program Counter to main, for mret.
    // requires gcc -mcmodel=medany
    csr.write("mepc", @ptrToInt(&main));

    // disable paging for now.
    csr.write("satp", 0);

    // delegate all interrupts and exceptions to supervisor mode.
    csr.write("medeleg", 0xffff);
    csr.write("mideleg", 0xffff);
    csr.set("sie", csr.sie.all);

    // configure Physical Memory Protection to give supervisor mode
    // access to all of physical memory.
    csr.write("pmpaddr0", 0x3fffffffffffff);
    csr.write("pmpcfg0", 0xf);

    // ask for clock interrupts.
    // each CPU has a separate source of timer interrupts.
    const id = csr.read("mhartid");
    timerinit(@intCast(u8, id));

    // keep each CPU's hartid in its tp register, for cpuid().
    gpr.write("tp", id);

    // switch to supervisor mode and jump to main().
    asm volatile ("mret");
}

fn timerinit(id: u8) void {
    // ask the CLINT for a timer interrupt.
    const interval = 1000000; // cycles; about 1/10th second in qemu.
    xv6.Clint.mtimecmp(id, xv6.Clint.mtime() + interval);

    // prepare information in scratch[] for timervec.
    // scratch[0..2] : space for timervec to save registers.
    // scratch[3] : address of CLINT MTIMECMP register.
    // scratch[4] : desired interval (in cycles) between timer interrupts.
    var scratch = &timer_scratch[id];
    scratch[3] = xv6.Clint.mtimecmp_addr(id);
    scratch[4] = interval;
    csr.write("mscratch", @ptrToInt(scratch));

    // set the machine-mode trap handler.
    csr.write("mtvec", @ptrToInt(&timervec));

    // enable machine-mode interrupts.
    csr.set("mstatus", csr.mstatus.mie);

    // enable machine-mode timer interrupts.
    csr.set("mie", csr.mie.mtie);
}

// for unused export functions
comptime {
    _ = @import("syscall.zig");
}
