const std = @import("std");
const xv6 = @import("xv6.zig");
const gpr = xv6.register.gpr;
const c = @import("c.zig");
const SpinLock = @import("SpinLock.zig");
const vm = xv6.vm;
const Address = vm.Address;
const kalloc = xv6.kalloc;
const TRAMPOLINE = vm.TRAMPOLINE;
const PGSIZE = vm.PGSIZE;

/// trampoline.S
extern const trampoline: u1;
extern fn forkret() void;

extern var cpus: [xv6.NCPU]c.Cpu;
extern var proc: [xv6.NPROC]c.Proc;
extern var initproc: *c.Proc;

extern var nextpid: c_int;
extern var pid_lock: c.SpinLock;
// var pid_lock: SpinLock = SpinLock.init("nextpid");

/// helps ensure that wakeups of wait()ing
/// parents are not lost. helps obey the
/// memory model when using p->parent.
/// must be acquired before any p->lock.
extern var wait_lock: c.SpinLock;
// var wait_lock: SpinLock = SpinLock.init("wait_lock");

/// Allocate a page for each process's kernel stack.
/// Map it high in memory, followed by an invalid
/// guard page.
pub fn mapstacks(pagetable: Address) void {
    for (proc, 1..) |_, i| {
        var pgtbl = Address{ .page = kalloc.kalloc().? };

        vm.kvmmap(pagetable, TRAMPOLINE - (i * 2 * PGSIZE), pgtbl.interger, PGSIZE, .{
            .readable = true,
            .writable = true,
        });
    }
}

/// Must be called with interrupts disabled,
/// to prevent race with process being moved
/// to a different CPU.
export fn cpuid() usize {
    return gpr.read(.tp);
}

/// Return this CPU's cpu struct.
/// Interrupts must be disabled.
export fn mycpu() *c.Cpu {
    return &cpus[cpuid()];
}

/// Return the current struct proc *, or zero if none.
pub export fn myproc() ?*c.Proc {
    SpinLock.pushOff();
    defer SpinLock.popOff();

    return mycpu().proc;
}

export fn allocpid() c_int {
    c.acquire(&pid_lock);
    defer c.release(&pid_lock);

    var pid = nextpid;
    nextpid += 1;
    return pid;
}

extern fn proc_pagetable(p: *c.Proc) ?Address.PageTable;

/// Look in the process table for an UNUSED proc.
/// If found, initialize state required to run in the kernel,
/// and return with p->lock held.
/// If there are no free procs, or a memory allocation fails, return 0.
export fn allocproc() ?*c.Proc {
    var p: *c.Proc = for (&proc) |*p| {
        c.acquire(&p.lock);

        if (p.state == .unused) {
            break p;
        } else {
            c.release(&p.lock);
        }
    } else {
        return null;
    };

    p.pid = allocpid();
    p.state = .used;

    // Allocate a trapframe page.
    p.trapframe = @ptrCast(*c.TrapFrame, kalloc.kalloc().?);

    // An empty user page table.
    p.pagetable = proc_pagetable(p).?;

    // Set up new context to start executing at forkret,
    // which returns to user space.
    std.mem.set(u8, std.mem.asBytes(&p.context), 0);
    p.context.ra = @ptrToInt(&forkret);
    p.context.sp = p.kstack + PGSIZE;

    return p;
}

/// a user program that calls exec("/init")
/// assembled from ../user/initcode.S
/// od -t xC ../user/initcode
// zig fmt: off
const initcode = [_]u8{
    0x17, 0x05, 0x00, 0x00, 0x13, 0x05, 0x45, 0x02,
    0x97, 0x05, 0x00, 0x00, 0x93, 0x85, 0x35, 0x02,
    0x93, 0x08, 0x70, 0x00, 0x73, 0x00, 0x00, 0x00,
    0x93, 0x08, 0x20, 0x00, 0x73, 0x00, 0x00, 0x00,
    0xef, 0xf0, 0x9f, 0xff, 0x2f, 0x69, 0x6e, 0x69,
    0x74, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00
};
// zig fmt: on

extern fn namei(name: [*:0]const u8) *c.Inode;

pub fn userinit() void {
    var p = allocproc().?;
    initproc = p;

    // allocate one user page and copy initcode's instructions
    // and data into it.
    vm.uvmfirst(Address{ .pagetable = p.pagetable }, &initcode);
    p.sz = PGSIZE;

    // prepare for the very first "return" from kernel to user.
    p.trapframe.epc = 0; // user program counter
    p.trapframe.sp = PGSIZE; // user stack pointer

    std.mem.copy(u8, p.name[0..], "initcode");
    p.cwd = namei("/");
    p.state = .runnable;

    c.release(&p.lock);
}
