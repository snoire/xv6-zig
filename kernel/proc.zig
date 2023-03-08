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
