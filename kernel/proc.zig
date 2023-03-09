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
fn allocproc() ?*c.Proc {
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

// Create a new process, copying the parent.
// Sets up child kernel stack to return as if from fork() system call.
export fn fork() c_int {
    // Allocate process.
    var p = myproc().?;
    var np = allocproc().?;

    // Copy user memory from parent to child.
    vm.uvmcopy(
        .{ .pagetable = p.pagetable },
        .{ .pagetable = np.pagetable },
        p.sz,
    );

    np.sz = p.sz;

    // copy saved user registers.
    np.trapframe.* = p.trapframe.*;

    // Cause fork to return 0 in the child.
    np.trapframe.a0 = 0;

    // increment reference counts on open file descriptors.
    for (p.ofile, &np.ofile) |old_ofile, *new_ofile| {
        if (old_ofile) |old_file| {
            new_ofile.* = c.filedup(old_file);
        }
    }

    np.cwd = c.idup(p.cwd);

    std.mem.copy(u8, np.name[0..], p.name[0..]);

    var pid = np.pid;

    c.release(&np.lock);

    c.acquire(&wait_lock);
    np.parent = p;
    c.release(&wait_lock);

    c.acquire(&np.lock);
    np.state = .runnable;
    c.release(&np.lock);

    return pid;
}

/// Per-CPU process scheduler.
/// Each CPU calls scheduler() after setting itself up.
/// Scheduler never returns.  It loops, doing:
///  - choose a process to run.
///  - swtch to start running that process.
///  - eventually that process transfers control
///    via swtch back to the scheduler.
pub fn scheduler() void {
    var cpu = mycpu();
    cpu.proc = null;

    while (true) {
        // Avoid deadlock by ensuring that devices can interrupt.
        SpinLock.intrOn();

        for (&proc) |*p| {
            c.acquire(&p.lock);
            defer c.release(&p.lock);

            if (p.state == .runnable) {
                // Switch to chosen process.  It is the process's job
                // to release its lock and then reacquire it
                // before jumping back to us.
                p.state = .running;
                cpu.proc = p;
                c.swtch(&cpu.context, &p.context);

                // Process is done running for now.
                // It should have changed its p->state before coming back.
                cpu.proc = null;
            }
        }
    }
}

/// Switch to scheduler.  Must hold only p->lock
/// and have changed proc->state. Saves and restores
/// intena because intena is a property of this
/// kernel thread, not this CPU. It should
/// be proc->intena and proc->noff, but that would
/// break in the few places where a lock is held but
/// there's no process.
export fn sched() void {
    var p = myproc().?;

    if (!c.holding(&p.lock)) @panic("sched p->lock");
    if (mycpu().noff != 1) @panic("sched locks");
    if (p.state == .running) @panic("sched running");
    if (SpinLock.intrGet()) @panic("sched interruptible");

    var intena = mycpu().intena;
    c.swtch(&p.context, &mycpu().context);
    mycpu().intena = intena;
}

/// Give up the CPU for one scheduling round.
export fn yield() void {
    var p = myproc().?;
    c.acquire(&p.lock);
    defer c.release(&p.lock);

    p.state = .runnable;
    sched();
}

/// A fork child's very first scheduling by scheduler()
/// will swtch to forkret.
export fn forkret() void {
    // static local variable
    const S = struct {
        var first: bool = true;
    };

    c.release(&myproc().?.lock);

    if (S.first) {
        S.first = false;
        // File system initialization must be run in the context of a
        // regular process (e.g., because it calls sleep), and thus cannot
        // be run from main().
        c.fsinit(xv6.ROOTDEV);
    }

    c.usertrapret();
}

/// Atomically release lock and sleep on chan.
/// Reacquires lock when awakened.
export fn sleep(chan: *anyopaque, lk: *c.SpinLock) void {

    // Must acquire p->lock in order to
    // change p->state and then call sched.
    // Once we hold p->lock, we can be
    // guaranteed that we won't miss any wakeup
    // (wakeup locks p->lock),
    // so it's okay to release lk.
    var p = myproc().?;
    c.acquire(&p.lock);
    c.release(lk);

    // Go to sleep.
    p.chan = chan;
    p.state = .sleeping;

    sched();

    // Tidy up.
    p.chan = null;

    c.release(&p.lock);
    c.acquire(lk);
}

/// Wake up all processes sleeping on chan.
/// Must be called without any p->lock.
export fn wakeup(chan: *anyopaque) void {
    for (&proc) |*p| {
        if (p == myproc()) continue;

        c.acquire(&p.lock);
        defer c.release(&p.lock);

        if (p.state == .sleeping and p.chan == chan) {
            p.state = .runnable;
        }
    }
}

/// Kill the process with the given pid.
/// The victim won't exit until it tries to return
/// to user space (see usertrap() in trap.c).
export fn kill(pid: c_int) c_int {
    for (&proc) |*p| {
        c.acquire(&p.lock);
        defer c.release(&p.lock);

        if (p.pid == pid) {
            p.killed = 1;
            if (p.state == .sleeping) {
                p.state = .runnable;
            }
            return 0;
        }
    }

    return -1;
}
