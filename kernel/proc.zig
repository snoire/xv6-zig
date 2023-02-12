const file = @import("file.zig");
const File = file.File;
const Inode = file.Inode;
const SpinLock = @import("spinlock.zig").SpinLock;

pub const PageTable = *usize; // 512 PTEs
/// open files per process
const NOFILE = 16;

/// Saved registers for kernel context switches.
const Context = extern struct {
    ra: usize,
    sp: usize,

    // callee-saved
    s0: usize,
    s1: usize,
    s2: usize,
    s3: usize,
    s4: usize,
    s5: usize,
    s6: usize,
    s7: usize,
    s8: usize,
    s9: usize,
    s10: usize,
    s11: usize,
};

/// Per-CPU state.
pub const Cpu = struct {
    /// The process running on this cpu, or null.
    proc: ?*Proc,
    /// swtch() here to enter scheduler().
    context: Context,
    /// Depth of push_off() nesting.
    noff: c_int,
    /// Were interrupts enabled before push_off()?
    intena: c_int,
};

/// per-process data for the trap handling code in trampoline.S.
/// sits in a page by itself just under the trampoline page in the
/// user page table. not specially mapped in the kernel page table.
/// uservec in trampoline.S saves user registers in the trapframe,
/// then initializes registers from the trapframe's
/// kernel_sp, kernel_hartid, kernel_satp, and jumps to kernel_trap.
/// usertrapret() and userret in trampoline.S set up
/// the trapframe's kernel_*, restore user registers from the
/// trapframe, switch to the user page table, and enter user space.
/// the trapframe includes callee-saved user registers like s0-s11 because the
/// return-to-user path via usertrapret() doesn't return through
/// the entire kernel call stack.
const TrapFrame = extern struct {
    /// kernel page table
    kernel_satp: usize, // 0
    /// top of process's kernel stack
    kernel_sp: usize, // 8
    /// usertrap()
    kernel_trap: usize, // 16
    /// saved user program counter
    epc: usize, // 24
    /// saved kernel tp
    kernel_hartid: usize, // 32

    ra: usize, //  40
    sp: usize, //  48
    gp: usize, //  56
    tp: usize, //  64
    t0: usize, //  72
    t1: usize, //  80
    t2: usize, //  88
    s0: usize, //  96
    s1: usize, // 104
    a0: usize, // 112
    a1: usize, // 120
    a2: usize, // 128
    a3: usize, // 136
    a4: usize, // 144
    a5: usize, // 152
    a6: usize, // 160
    a7: usize, // 168
    s2: usize, // 176
    s3: usize, // 184
    s4: usize, // 192
    s5: usize, // 200
    s6: usize, // 208
    s7: usize, // 216
    s8: usize, // 224
    s9: usize, // 232
    s10: usize, // 240
    s11: usize, // 248
    t3: usize, // 256
    t4: usize, // 264
    t5: usize, // 272
    t6: usize, // 280
};

/// Per-process state
pub const Proc = extern struct {
    lock: SpinLock,

    // p->lock must be held when using these:
    /// Process state
    state: ProcState,
    /// If non-zero, sleeping on chan
    chan: *anyopaque,
    /// If non-zero, have been killed
    killed: c_int,
    /// Exit status to be returned to parent's wait
    xstate: c_int,
    /// Process ID
    pid: c_int,

    // wait_lock must be held when using this:
    /// Parent process
    parent: *Proc,

    // these are private to the process, so p->lock need not be held.
    /// Virtual address of kernel stack
    kstack: usize,
    /// Size of process memory (bytes)
    sz: usize,
    /// User page table
    pagetable: PageTable,
    /// data page for trampoline.S
    trapframe: *TrapFrame,
    /// swtch() here to run process
    context: Context,
    /// Open files
    ofile: [NOFILE]*File,
    /// Current directory
    cwd: *Inode,
    /// Process name (debugging)
    name: [16]u8,

    const ProcState = enum(c_int) {
        unused,
        used,
        sleeping,
        runnable,
        running,
        zombie,
    };
};
