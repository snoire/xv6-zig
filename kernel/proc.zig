const std = @import("std");
const xv6 = @import("xv6.zig");
const gpr = xv6.register.gpr;
const c = @import("c.zig");
const SpinLock = @import("SpinLock.zig");
const vm = xv6.vm;
const PageTable = vm.PageTable;
const Address = vm.Address;
const kalloc = xv6.kalloc;
const print = xv6.print;
const TRAMPOLINE = vm.TRAMPOLINE;
const TRAPFRAME = vm.TRAPFRAME;
const PGSIZE = vm.PGSIZE;

/// trampoline.S
extern const trampoline: u1;

var cpus: [xv6.NCPU]c.Cpu = undefined;
var proc: [xv6.NPROC]c.Proc = undefined;
var initproc: *c.Proc = undefined;

var nextpid: u32 = 1;
var pid_lock: SpinLock = SpinLock.init("nextpid");

/// helps ensure that wakeups of wait()ing
/// parents are not lost. helps obey the
/// memory model when using p->parent.
/// must be acquired before any p->lock.
var wait_lock: c.SpinLock = undefined; // TODO
// var wait_lock: SpinLock = SpinLock.init("wait_lock");

/// initialize the proc table.
pub fn init() void {
    wait_lock.init("wait_lock");

    for (&proc, 1..) |*p, i| {
        p.lock.init("proc");
        p.state = .unused;
        p.kstack = TRAMPOLINE - (i * 2 * PGSIZE);
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

fn allocpid() u32 {
    pid_lock.acquire();
    defer pid_lock.release();

    var pid = nextpid;
    nextpid += 1;
    return pid;
}

/// Look in the process table for an UNUSED proc.
/// If found, initialize state required to run in the kernel,
/// and return with p->lock held.
/// If there are no free procs, or a memory allocation fails, return 0.
fn allocproc() ?*c.Proc {
    var p: *c.Proc = for (&proc) |*p| {
        p.lock.acquire();

        if (p.state == .unused) {
            break p;
        } else {
            p.lock.release();
        }
    } else {
        return null;
    };

    p.pid = allocpid();
    p.state = .used;

    // Allocate a trapframe page.
    p.trapframe = @ptrCast(*c.TrapFrame, kalloc.kalloc());

    // An empty user page table.
    p.pagetable = proc_pagetable(p);

    // Set up new context to start executing at forkret,
    // which returns to user space.
    std.mem.set(u8, std.mem.asBytes(&p.context), 0);
    p.context.ra = @ptrToInt(&forkret);
    p.context.sp = p.kstack + PGSIZE;

    return p;
}

/// Create a user page table for a given process, with no user memory,
/// but with trampoline and trapframe pages.
export fn proc_pagetable(p: *c.Proc) PageTable {
    // An empty page table.
    var pagetable = PageTable.create();

    // map the trampoline code (for system call return)
    // at the highest user virtual address.
    // only the supervisor uses it, on the way
    // to/from user space, so not PTE_U.
    pagetable.mappages(.{ .addr = TRAMPOLINE }, PGSIZE, .{ .addr = @ptrToInt(&trampoline) }, .{
        .readable = true,
        .executable = true,
    });

    // map the trapframe page just below the trampoline page, for
    // trampoline.S.
    pagetable.mappages(.{ .addr = TRAPFRAME }, PGSIZE, .{ .addr = @ptrToInt(p.trapframe) }, .{
        .readable = true,
        .writable = true,
    });

    return pagetable;
}

/// free a proc structure and the data hanging from it,
/// including user pages.
/// p->lock must be held.
fn freeproc(p: *c.Proc) void {
    if (p.trapframe != null) {
        kalloc.kfree(@ptrCast(*align(PGSIZE) kalloc.Page, p.trapframe.?));
        p.trapframe = null;
    }

    if (p.pagetable.ptes != null) {
        proc_freepagetable(p.pagetable, p.sz);
        p.pagetable.ptes = null;
    }
    p.sz = 0;
    p.pid = 0;
    p.parent = null;
    p.name[0] = 0;
    p.chan = null;
    p.killed = 0;
    p.xstate = 0;
    p.state = .unused;
}

/// Free a process's page table, and free the
/// physical memory it refers to.
export fn proc_freepagetable(pagetable: PageTable, sz: usize) void {
    pagetable.unmap(.{ .addr = TRAMPOLINE }, 1, false);
    pagetable.unmap(.{ .addr = TRAPFRAME }, 1, false);
    pagetable.free(sz);
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
    p.pagetable.first(&initcode);
    p.sz = PGSIZE;

    // prepare for the very first "return" from kernel to user.
    p.trapframe.?.epc = 0; // user program counter
    p.trapframe.?.sp = PGSIZE; // user stack pointer

    std.mem.copy(u8, p.name[0..], "initcode");
    p.cwd = namei("/");
    p.state = .runnable;

    p.lock.release();
}

/// Grow or shrink user memory by n bytes.
/// Return 0 on success, -1 on failure.
pub fn growproc(n: i32) c_int {
    var p = myproc().?;
    var sz = p.sz;

    if (n > 0) {
        sz = p.pagetable.uvmalloc(sz, sz + @intCast(usize, n), .{
            .writable = true,
        });
        if (sz < 0) @panic("growproc");
    } else {
        sz = p.pagetable.dealloc(sz, sz + @intCast(usize, n));
    }

    p.sz = sz;
    return 0;
}

// Create a new process, copying the parent.
// Sets up child kernel stack to return as if from fork() system call.
pub fn fork() u32 {
    // Allocate process.
    var p = myproc().?;
    var np = allocproc().?;

    // Copy user memory from parent to child.
    p.pagetable.copy(np.pagetable, p.sz);

    np.sz = p.sz;

    // copy saved user registers.
    np.trapframe.?.* = p.trapframe.?.*;

    // Cause fork to return 0 in the child.
    np.trapframe.?.a0 = 0;

    // increment reference counts on open file descriptors.
    for (p.ofile, &np.ofile) |old_ofile, *new_ofile| {
        if (old_ofile) |old_file| {
            new_ofile.* = old_file.dup();
        }
    }

    np.cwd = p.cwd.?.dup();

    std.mem.copy(u8, np.name[0..], p.name[0..]);

    var pid = np.pid;

    np.lock.release();

    wait_lock.acquire();
    np.parent = p;
    wait_lock.release();

    np.lock.acquire();
    np.state = .runnable;
    np.lock.release();

    return pid;
}

/// Pass p's abandoned children to init.
/// Caller must hold wait_lock.
fn reparent(p: *c.Proc) void {
    for (&proc) |*pp| {
        if (pp.parent == p) {
            pp.parent = initproc;
            wakeup(initproc);
        }
    }
}

/// Exit the current process.  Does not return.
/// An exited process remains in the zombie state
/// until its parent calls wait().
pub export fn exit(status: i32) void {
    var p = myproc().?;
    if (p == initproc) @panic("init exiting");

    // Close all open files.
    var i: usize = 0;
    while (i < p.ofile.len) : (i += 1) {
        if (p.ofile[i]) |ofile| {
            ofile.close();
            p.ofile[i] = null;
        }
    }

    c.begin_op();
    p.cwd.?.put();
    c.end_op();
    p.cwd = null;

    wait_lock.acquire();

    // Give any children to init.
    reparent(p);

    // Parent might be sleeping in wait().
    wakeup(p.parent.?);

    p.lock.acquire();

    p.xstate = status;
    p.state = .zombie;

    wait_lock.release();

    // Jump into the scheduler, never to return.
    sched();
    @panic("zombie exit");
}

/// Wait for a child process to exit and return its pid.
/// Return -1 if this process has no children.
pub fn wait(addr: usize) u32 {
    var p = myproc().?;

    wait_lock.acquire();
    defer wait_lock.release();

    while (true) {
        var havekids: bool = false;

        for (&proc) |*pp| {
            if (pp.parent != p) continue;

            // make sure the child isn't still in exit() or swtch().
            pp.lock.acquire();
            defer pp.lock.release();
            havekids = true;

            if (pp.state != .zombie) continue;
            // Found one.
            var pid = pp.pid;
            var ret = p.pagetable.copyout(
                .{ .addr = addr },
                @ptrCast([*]const u8, &pp.xstate),
                @sizeOf(c_int),
            );

            if (addr > 0 and ret != 0) @panic("wait");

            freeproc(pp);
            return pid;
        } else {
            // No point waiting if we don't have any children.
            if (!havekids or killed(p) != 0) {
                @panic("have no children");
            }

            // Wait for a child to exit.
            sleep(p, &wait_lock);
        }
    }
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
            p.lock.acquire();
            defer p.lock.release();

            if (p.state == .runnable) {
                // Switch to chosen process.  It is the process's job
                // to release its lock and then reacquire it
                // before jumping back to us.
                p.state = .running;
                cpu.proc = p;
                cpu.context.swtch(&p.context);

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

    if (!p.lock.holding()) @panic("sched p->lock");
    if (mycpu().noff != 1) @panic("sched locks");
    if (p.state == .running) @panic("sched running");
    if (SpinLock.intrGet()) @panic("sched interruptible");

    var intena = mycpu().intena;
    p.context.swtch(&mycpu().context);
    mycpu().intena = intena;
}

/// Give up the CPU for one scheduling round.
export fn yield() void {
    var p = myproc().?;
    p.lock.acquire();
    defer p.lock.release();

    p.state = .runnable;
    sched();
}

/// A fork child's very first scheduling by scheduler()
/// will swtch to forkret.
fn forkret() void {
    // static local variable
    const S = struct {
        var first: bool = true;
    };

    myproc().?.lock.release();

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
pub export fn sleep(chan: *anyopaque, lk: *c.SpinLock) void {

    // Must acquire p->lock in order to
    // change p->state and then call sched.
    // Once we hold p->lock, we can be
    // guaranteed that we won't miss any wakeup
    // (wakeup locks p->lock),
    // so it's okay to release lk.
    var p = myproc().?;
    p.lock.acquire();
    lk.release();

    // Go to sleep.
    p.chan = chan;
    p.state = .sleeping;

    sched();

    // Tidy up.
    p.chan = null;

    p.lock.release();
    lk.acquire();
}

/// Wake up all processes sleeping on chan.
/// Must be called without any p->lock.
export fn wakeup(chan: *anyopaque) void {
    for (&proc) |*p| {
        if (p == myproc()) continue;

        p.lock.acquire();
        defer p.lock.release();

        if (p.state == .sleeping and p.chan == chan) {
            p.state = .runnable;
        }
    }
}

/// Kill the process with the given pid.
/// The victim won't exit until it tries to return
/// to user space (see usertrap() in trap.c).
pub export fn kill(pid: u32) c_int {
    for (&proc) |*p| {
        p.lock.acquire();
        defer p.lock.release();

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

export fn setkilled(p: *c.Proc) void {
    p.lock.acquire();
    defer p.lock.release();

    p.killed = 1;
}

pub export fn killed(p: *c.Proc) c_int {
    p.lock.acquire();
    defer p.lock.release();

    var k = p.killed;
    return k;
}

/// Copy to either a user address, or kernel address,
/// depending on usr_dst.
/// Returns 0 on success, -1 on error.
export fn either_copyout(user_dst: bool, dst: Address, src: [*]const u8, len: usize) c_int {
    var p = myproc().?;
    if (user_dst) {
        return p.pagetable.copyout(dst.vir_addr, src, len);
    } else {
        std.mem.copy(u8, dst.phy_addr.buffer[0..len], src[0..len]);
        return 0;
    }
}

/// Copy from either a user address, or kernel address,
/// depending on usr_src.
/// Returns 0 on success, -1 on error.
export fn either_copyin(dst: [*]u8, user_src: bool, src: Address, len: usize) c_int {
    var p = myproc().?;
    if (user_src) {
        return p.pagetable.copyin(dst, src.vir_addr, len);
    } else {
        std.mem.copy(u8, dst[0..len], src.phy_addr.buffer[0..len]);
        return 0;
    }
}

/// Print a process listing to console.  For debugging.
/// Runs when user types ^P on console.
/// No lock to avoid wedging a stuck machine further.
export fn procdump() void {
    print("\n", .{});

    // We iterate over array by reference because
    // this will take less memory on stack.
    for (&proc) |*p| {
        if (p.state == .unused) continue;
        print(
            "{} {s} {s}\n",
            .{ p.pid, @tagName(p.state), std.mem.sliceTo(&p.name, 0) },
        );
    }
}
