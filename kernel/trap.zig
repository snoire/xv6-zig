const std = @import("std");
const xv6 = @import("xv6.zig");
const csr = xv6.register.csr;
const gpr = xv6.register.gpr;
const print = xv6.print;
const proc = @import("proc.zig");
const Proc = proc.Proc;
const SpinLock = @import("SpinLock.zig");
const intrOn = SpinLock.intrOn;
const intrOff = SpinLock.intrOff;
const intrGet = SpinLock.intrGet;
const vm = @import("vm.zig");
const plic = @import("plic.zig");

const TRAMPOLINE = vm.TRAMPOLINE;
const PGSIZE = proc.PGSIZE;
const KSTACK_NUM = proc.KSTACK_NUM;

// in kernelvec.S, calls kerneltrap().
extern fn kernelvec() void;
extern fn yield() void;
extern fn syscall() void; // TODO
extern fn exit(i32) void; // TODO

/// set up to take exceptions and traps while in the kernel.
pub fn inithart() void {
    csr.write(.stvec, @ptrToInt(&kernelvec));
}

// extern fn devintr() u32;

/// handle an interrupt, exception, or system call from user space.
/// called from trampoline.S
export fn usertrap() void {
    if (csr.sstatus.read().spp) {
        @panic("usertrap: not from user mode");
    }

    // send interrupts and exceptions to kerneltrap(),
    // since we're now in the kernel.
    csr.write(.stvec, @ptrToInt(&kernelvec));

    var p = Proc.myproc().?;

    // save user program counter.
    p.trapframe.?.epc = csr.read(.sepc);

    // const scause = csr.scause.read();

    // if (!scause.interrupt) {
    //     const exception_code = @intToEnum(csr.scause.Exception, scause.code);
    //     switch (exception_code) {
    //         .@"Environment call from U-mode" => {
    //             if (p.isKilled()) exit(-1);

    //             // sepc points to the ecall instruction,
    //             // but we want to return to the next instruction.
    //             p.trapframe.?.epc += 4;

    //             // an interrupt will change sepc, scause, and sstatus,
    //             // so enable only now that we're done with those registers.
    //             intrOn();

    //             syscall();
    //         },
    //         else => {
    //             print(
    //                 \\usertrap(): unexpected exception {s} pid={}
    //                 \\            sepc={} stval={}
    //                 \\
    //             , .{ @tagName(exception_code), p.pid, csr.read(.sepc), csr.read(.stval) });

    //             p.setKilled();
    //         },
    //     }
    // }

    var which_dev: u32 = undefined;
    if (csr.read(.scause) == 8) {
        if (p.isKilled()) exit(-1);

        // sepc points to the ecall instruction,
        // but we want to return to the next instruction.
        p.trapframe.?.epc += 4;

        // an interrupt will change sepc, scause, and sstatus,
        // so enable only now that we're done with those registers.
        intrOn();

        syscall();
    } else {
        which_dev = devintr();

        if (which_dev == 0) {
            print("unexpected scause\n", .{});
            p.setKilled();
        }
    }

    if (p.isKilled()) exit(-1);

    // // give up the CPU if this is a timer interrupt.
    // if (scause.interrupt) {
    //     const interrupt_code = @intToEnum(csr.scause.Interrupt, scause.code);
    //     if (interrupt_code == .@"Supervisor software interrupt") {
    //         yield();
    //     }
    // }
    if (which_dev == 2) yield();

    usertrapret();
}

/// trampoline.S
extern const trampoline: u1;
extern const uservec: u1;
extern const userret: u1;

// extern fn usertrap() void;

/// return to user space
export fn usertrapret() void {
    var p: *Proc = Proc.myproc().?;

    // we're about to switch the destination of traps from
    // kerneltrap() to usertrap(), so turn off interrupts until
    // we're back in user space, where usertrap() is correct.
    intrOff();

    // send syscalls, interrupts, and exceptions to uservec in trampoline.S
    const uservec_addr = @ptrToInt(&uservec);
    const trampoline_addr = @ptrToInt(&trampoline);

    const trampoline_uservec = TRAMPOLINE + (uservec_addr - trampoline_addr);
    csr.write(.stvec, trampoline_uservec);

    // set up trapframe values that uservec will need when
    // the process next traps into the kernel.
    p.trapframe.?.kernel_satp = csr.read(.satp); // kernel page table
    p.trapframe.?.kernel_sp = p.kstack + KSTACK_NUM * PGSIZE; // process's kernel stack
    p.trapframe.?.kernel_trap = @ptrToInt(&usertrap);
    p.trapframe.?.kernel_hartid = gpr.read(.tp); // hartid for cpuid()

    // set up the registers that trampoline.S's sret will use
    // to get to user space.

    // set S Previous Privilege mode to User.
    csr.sstatus.reset(.{ .spp = true }); // clear SPP to 0 for user mode
    csr.sstatus.set(.{ .spie = true }); // enable interrupts in user mode

    // set S Exception Program Counter to the saved user pc.
    csr.write(.sepc, p.trapframe.?.epc);

    // tell trampoline.S the user page table to switch to.
    const satp = .{
        .mode = .sv39,
        .ppn = p.pagetable.phy.ppn,
    };

    // jump to userret in trampoline.S at the top of memory, which
    // switches to the user page table, restores user registers,
    // and switches to user mode with sret.
    const userret_addr = @ptrToInt(&userret);
    const trampoline_userret = TRAMPOLINE + (userret_addr - trampoline_addr);
    const userret_fn = @intToPtr(*const fn (csr.satp) void, trampoline_userret);
    userret_fn(satp);
}

/// interrupts and exceptions from kernel code go here via kernelvec,
/// on whatever the current kernel stack is.
export fn kerneltrap() void {
    const sepc = csr.read(.sepc);
    const sstatus = csr.sstatus.read();

    if (!sstatus.spp) {
        @panic("kerneltrap: not from supervisor mode");
    }

    if (intrGet()) {
        @panic("kerneltrap: interrupts enabled");
    }

    var which_dev = devintr();
    if (which_dev == 0) {
        print("scause {}\n", .{csr.read(.scause)});
        print("sepc={} stval={}\n", .{ sepc, csr.read(.stval) });
        @panic("kerneltrap");
    }

    // give up the CPU if this is a timer interrupt.
    if (Proc.myproc()) |p| {
        if (p.state == .running and which_dev == 2) {
            yield();
        }
    }

    // the yield() may have caused some traps to occur,
    // so restore trap registers for use by kernelvec.S's sepc instruction.
    csr.write(.sepc, sepc);
    csr.write(.sstatus, @bitCast(usize, sstatus));
}

extern fn cpuid() usize;
extern fn virtio_disk_intr() void;
extern fn uartintr() void;
extern fn clockintr() void;

/// check if it's an external interrupt or software interrupt,
/// and handle it.
/// returns 2 if timer interrupt,
/// 1 if other device,
/// 0 if not recognized.
fn devintr() u32 {
    const scause = csr.scause.read();

    if (scause.interrupt) {
        const interrupt_code = @intToEnum(csr.scause.Interrupt, scause.code);
        switch (interrupt_code) {
            .@"Supervisor external interrupt" => {
                // this is a supervisor external interrupt, via PLIC.

                const target = plic.Target{
                    .mode = .supervisor,
                    .hart = @intCast(u3, cpuid()),
                };

                // irq indicates which device interrupted.
                const irq = target.claim() orelse @panic("irq is 0");

                switch (irq) {
                    .virtio0 => virtio_disk_intr(),
                    .uart0 => uartintr(),
                    else => print("unexpected interrupt irq={}\n", .{@enumToInt(irq)}),
                }

                // the PLIC allows each device to raise at most one
                // interrupt at a time; tell the PLIC the device is
                // now allowed to interrupt again.
                target.complete(irq);

                return 1;
            },
            .@"Supervisor software interrupt" => {
                // software interrupt from a machine-mode timer interrupt,
                // forwarded by timervec in kernelvec.S.

                if (cpuid() == 0) {
                    clockintr();
                }

                // acknowledge the software interrupt by clearing
                // the SSIP bit in sip.
                csr.sip.reset(.{ .ssip = true });

                return 2;
            },
            else => {},
        }
    }

    return 0;
}
