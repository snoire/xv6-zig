const std = @import("std");
const xv6 = @import("xv6.zig");
const gpr = xv6.register.gpr;
const c = @import("c.zig");
const SpinLock = @import("SpinLock.zig");
const vm = @import("vm.zig");
const PageTable = vm.PageTable;
const kalloc = xv6.kalloc;
const print = xv6.print;
const allocator = std.heap.page_allocator;

const TRAMPOLINE = vm.TRAMPOLINE;
const TRAPFRAME = vm.TRAPFRAME;
pub const PGSIZE = vm.PGSIZE;
pub const KSTACK_NUM = 4;

/// trampoline.S
extern const trampoline: u8;

var cpus: [xv6.NCPU]c.Cpu = undefined;
var proc: [xv6.NPROC]Proc = undefined;
var initproc: *Proc = undefined;

var nextpid: u32 = 1;
var pid_lock: SpinLock = SpinLock.init("nextpid");

/// helps ensure that wakeups of wait()ing
/// parents are not lost. helps obey the
/// memory model when using p->parent.
/// must be acquired before any p->lock.
var wait_lock: c.SpinLock = undefined; // TODO
// var wait_lock: SpinLock = SpinLock.init("wait_lock");

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

/// initialize the proc table.
pub fn init() void {
    wait_lock.init("wait_lock");

    for (&proc, 1..) |*p, i| {
        p.lock.init("proc");
        p.state = .unused;
        p.kstack = TRAMPOLINE - (i * (KSTACK_NUM + 1) - KSTACK_NUM) * PGSIZE;
    }
}

/// Per-process state
pub const Proc = extern struct {
    lock: c.SpinLock,

    // p->lock must be held when using these:
    /// Process state
    state: ProcState,
    /// If non-zero, sleeping on chan
    chan: ?*anyopaque,
    /// If non-zero, have been killed
    killed: c_int,
    /// Exit status to be returned to parent's wait
    xstate: c_int,
    /// Process ID
    pid: u32,

    // wait_lock must be held when using this:
    /// Parent process
    parent: ?*Proc,

    // these are private to the process, so p->lock need not be held.
    /// Virtual address of kernel stack
    kstack: usize,
    /// Size of process memory (bytes)
    sz: usize,
    /// User page table
    pagetable: PageTable,
    /// data page for trampoline.S
    trapframe: ?*align(PGSIZE) c.TrapFrame,
    /// swtch() here to run process
    context: c.Context,
    /// Open files
    ofile: [xv6.NOFILE]?*c.File,
    /// Current directory
    cwd: ?*c.Inode,
    /// (NUL-terminated) Process name (debugging)
    name: [16]u8,

    const ProcState = enum(c_int) {
        unused,
        used,
        sleeping,
        runnable,
        running,
        zombie,
    };

    /// Return the current struct proc *, or zero if none.
    pub fn myproc() ?*Proc {
        SpinLock.pushOff();
        defer SpinLock.popOff();

        return mycpu().proc;
    }

    /// Look in the process table for an UNUSED proc.
    /// If found, initialize state required to run in the kernel,
    /// and return with p->lock held.
    /// If there are no free procs, or a memory allocation fails, return 0.
    fn allocproc() !*Proc {
        const p: *Proc = for (&proc) |*p| {
            p.lock.acquire();

            if (p.state == .unused) {
                break p;
            } else {
                p.lock.release();
            }
        } else {
            return error.NotFound;
        };

        p.pid = allocpid();
        p.state = .used;

        // Allocate a trapframe page.
        const trap_frame = try allocator.create(c.TrapFrame);
        p.trapframe = @alignCast(trap_frame);

        // An empty user page table.
        p.pagetable = try createPagetable(p);

        // Set up new context to start executing at forkret,
        // which returns to user space.
        @memset(std.mem.asBytes(&p.context), 0);
        p.context.ra = @intFromPtr(&forkret);
        p.context.sp = p.kstack;

        return p;
    }

    /// Create a user page table for a given process, with no user memory,
    /// but with trampoline and trapframe pages.
    pub fn createPagetable(p: *Proc) !PageTable {
        // An empty page table.
        const pagetable = try PageTable.create();
        errdefer pagetable.freewalk();

        // map the trampoline code (for system call return)
        // at the highest user virtual address.
        // only the supervisor uses it, on the way
        // to/from user space, so not PTE_U.
        const trampoline_addr = @intFromPtr(&trampoline);
        try pagetable.mappages(@bitCast(TRAMPOLINE), PGSIZE, @bitCast(trampoline_addr), .{
            .readable = true,
            .executable = true,
        });
        errdefer pagetable.unmap(@bitCast(TRAMPOLINE), 1, false);

        // map the trapframe page just below the trampoline page, for
        // trampoline.S.
        const trapframe_addr = @intFromPtr(p.trapframe);
        try pagetable.mappages(@bitCast(TRAPFRAME), PGSIZE, @bitCast(trapframe_addr), .{
            .readable = true,
            .writable = true,
        });

        return pagetable;
    }

    /// free a proc structure and the data hanging from it,
    /// including user pages.
    /// p->lock must be held.
    fn freeproc(p: *Proc) void {
        if (p.trapframe != null) {
            allocator.destroy(p.trapframe.?);
            p.trapframe = null;
        }

        if (p.pagetable.ptes != null) {
            p.pagetable.free(p.sz);
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

    /// Pass p's abandoned children to init.
    /// Caller must hold wait_lock.
    fn reparent(p: *Proc) void {
        for (&proc) |*pp| {
            if (pp.parent == p) {
                pp.parent = initproc;
                wakeup(initproc);
            }
        }
    }

    pub fn setKilled(p: *Proc) void {
        p.lock.acquire();
        defer p.lock.release();

        p.killed = 1;
    }

    pub fn isKilled(p: *Proc) bool {
        p.lock.acquire();
        defer p.lock.release();

        return if (p.killed != 0) true else false;
    }
};

/// Return the current struct proc *, or zero if none.
export fn myproc() ?*Proc {
    return Proc.myproc();
}

export fn setkilled(p: *Proc) void {
    p.setKilled();
}

export fn killed(p: *Proc) c_int {
    return if (p.isKilled()) 1 else 0;
}

fn allocpid() u32 {
    pid_lock.acquire();
    defer pid_lock.release();

    const pid = nextpid;
    nextpid += 1;
    return pid;
}

/// a user program that calls exec("/init")
/// assembled from ../user/initcode.S
/// od -t xC ../user/initcode
const initcode = @embedFile("initcode");

pub fn userinit() void {
    const p = Proc.allocproc() catch unreachable;
    initproc = p;

    // allocate one user page and copy initcode's instructions
    // and data into it.
    p.pagetable.first(initcode);
    p.sz = PGSIZE;

    // prepare for the very first "return" from kernel to user.
    p.trapframe.?.epc = 0; // user program counter
    p.trapframe.?.sp = PGSIZE; // user stack pointer

    const name = "initcode";
    @memcpy(p.name[0 .. name.len + 1], name[0 .. name.len + 1]);

    p.cwd = c.namei("/");
    p.state = .runnable;

    p.lock.release();
}

/// Grow or shrink user memory by n bytes.
/// Return 0 on success, -1 on failure.
pub fn growproc(n: isize) !void {
    const p = Proc.myproc().?;
    var size = p.sz;

    if (n > 0) {
        size = try p.pagetable.alloc(size, @intCast(n), .{ .writable = true });
    } else if (n < 0) {
        size = p.pagetable.dealloc(size, @intCast(-n));
    }

    p.sz = size;
}

// Create a new process, copying the parent.
// Sets up child kernel stack to return as if from fork() system call.
pub fn fork() !u32 {
    // Allocate process.
    const p = Proc.myproc().?;
    const np = try Proc.allocproc();

    // Copy user memory from parent to child.
    try p.pagetable.copy(np.pagetable, p.sz);

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

    @memcpy(&np.name, &p.name);

    const pid = np.pid;

    np.lock.release();

    wait_lock.acquire();
    np.parent = p;
    wait_lock.release();

    np.lock.acquire();
    np.state = .runnable;
    np.lock.release();

    return pid;
}

/// Exit the current process.  Does not return.
/// An exited process remains in the zombie state
/// until its parent calls wait().
pub fn exit(status: i32) noreturn {
    const p = Proc.myproc().?;
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
    p.reparent();

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
/// Return error if this process has no children.
pub fn wait(addr: usize) !isize {
    const p = Proc.myproc().?;

    wait_lock.acquire();
    defer wait_lock.release();

    while (true) {
        var havekids: bool = false;

        for (&proc) |*pp| {
            if (pp.parent != p) continue;
            havekids = true;

            // make sure the child isn't still in exit() or swtch().
            pp.lock.acquire();
            defer pp.lock.release();

            if (pp.state != .zombie) continue;
            // Found one.
            const pid = pp.pid;
            if (addr != 0) {
                try p.pagetable.copyout(@bitCast(addr), @ptrCast(&pp.xstate), @sizeOf(c_int));
            }

            pp.freeproc();
            return pid;
        } else {
            // No point waiting if we don't have any children.
            if (!havekids or p.isKilled()) {
                return error.NoChildren;
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
    const cpu = mycpu();
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
pub fn sched() void {
    const p = Proc.myproc().?;

    if (!p.lock.holding()) @panic("sched p->lock");
    if (mycpu().noff != 1) @panic("sched locks");
    if (p.state == .running) @panic("sched running");
    if (SpinLock.intrGet()) @panic("sched interruptible");

    const intena = mycpu().intena;
    p.context.swtch(&mycpu().context);
    mycpu().intena = intena;
}

/// Give up the CPU for one scheduling round.
pub fn yield() void {
    const p = Proc.myproc().?;
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

    Proc.myproc().?.lock.release();

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
    const p = Proc.myproc().?;
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
pub export fn wakeup(chan: *anyopaque) void {
    for (&proc) |*p| {
        if (p == Proc.myproc()) continue;

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

/// Copy to either a user address, or kernel address,
/// depending on usr_dst.
/// Returns 0 on success, -1 on error.
export fn either_copyout(user_dst: bool, dst: usize, src: [*]const u8, len: usize) c_int {
    const p = Proc.myproc().?;
    if (user_dst) {
        p.pagetable.copyout(@bitCast(dst), src, len) catch return -1;
    } else {
        const ptr: [*]u8 = @ptrFromInt(dst);
        @memcpy(ptr[0..len], src[0..len]);
    }
    return 0;
}

/// Copy from either a user address, or kernel address,
/// depending on usr_src.
/// Returns 0 on success, -1 on error.
export fn either_copyin(dst: [*]u8, user_src: bool, src: usize, len: usize) c_int {
    const p = Proc.myproc().?;
    if (user_src) {
        p.pagetable.copyin(dst, @bitCast(src), len) catch return -1;
    } else {
        const ptr: [*]u8 = @ptrFromInt(src);
        @memcpy(dst[0..len], ptr[0..len]);
    }
    return 0;
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
