const xv6 = @import("xv6.zig");
const csr = xv6.register.csr;
const gpr = xv6.register.gpr;
const clint = xv6.clint;
const main = @import("main.zig").main;

export var stack0: [xv6.NCPU * 1024 * 16]u8 align(16) = undefined;
// assembly code in kernelvec.S for machine-mode timer interrupt.
extern fn timervec() void;

var timer_scratch: [xv6.NCPU][5]usize = undefined;

export fn _entry() linksection(".kernel_entry") callconv(.Naked) noreturn {
    asm volatile (
        \\  # set up a stack
        \\  # sp = stack0 + (hartid * 1024 * 16)
        \\      la sp, stack0
        \\      li a0, 1024*16
        \\      csrr a1, mhartid
        \\      addi a1, a1, 1
        \\      mul a0, a0, a1
        \\      add sp, sp, a0
        \\  # jump to start()
        \\      call start
        \\spin:
        \\      j spin
    );
}

export fn start() void {
    // set M Previous Privilege mode to Supervisor, for mret.
    csr.mstatus.mpp.set(.supervisor);

    // set M Exception Program Counter to main, for mret.
    // requires code_model = .medium
    csr.write(.mepc, @intFromPtr(&main));

    // disable paging for now.
    csr.satp.set(.{ .mode = .none });

    // delegate all interrupts and exceptions to supervisor mode.
    csr.write(.medeleg, 0xffff);
    csr.write(.mideleg, 0xffff);
    csr.sie.set(.{ .ssie = true, .stie = true, .seie = true });

    // configure Physical Memory Protection to give supervisor mode
    // access to all of physical memory.
    csr.write(.pmpaddr0, 0x3f_ffff_ffff_ffff);
    csr.write(.pmpcfg0, 0xf);

    // ask for clock interrupts.
    timerinit();

    // keep each CPU's hartid in its tp register, for cpuid().
    gpr.write(.tp, csr.read(.mhartid));

    // switch to supervisor mode and jump to main().
    asm volatile ("mret");
}

fn timerinit() void {
    // each CPU has a separate source of timer interrupts.
    const id: u8 = @intCast(csr.read(.mhartid));

    // ask the CLINT for a timer interrupt.
    const interval = 100_0000; // cycles; about 1/10th second in qemu.
    clint.mtimecmp.set(id, clint.mtime() + interval);

    // prepare information in scratch[] for timervec.
    // scratch[0..2] : space for timervec to save registers.
    // scratch[3] : address of CLINT MTIMECMP register.
    // scratch[4] : desired interval (in cycles) between timer interrupts.
    var scratch = &timer_scratch[id];
    scratch[3] = clint.mtimecmp.get(id);
    scratch[4] = interval;
    csr.write(.mscratch, @intFromPtr(scratch));

    // set the machine-mode trap handler.
    csr.write(.mtvec, @intFromPtr(&timervec));

    // enable machine-mode interrupts.
    csr.mstatus.set(.{ .mie = true });

    // enable machine-mode timer interrupts.
    csr.mie.set(.{ .mtie = true });
}

// force unused export functions to be compiled
comptime {
    _ = @import("fs/log.zig");
}

pub const os = @import("os.zig");
