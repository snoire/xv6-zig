const fs = @import("fs.zig");
const xv6 = @import("xv6.zig");
const Proc = @import("proc.zig").Proc;
const PGSIZE = 4096;
const c = @This();

/// Mutual exclusion lock.
pub const SpinLock = extern struct {
    /// Is the lock held?
    locked: c_uint,

    // For debugging:
    /// Name of lock.
    name: [*:0]u8,
    /// The cpu holding the lock.
    cpu: *Cpu,

    pub const init = c.initlock;
    pub const acquire = c.acquire;
    pub const release = c.release;
    pub const holding = c.holding;
};

pub extern fn initlock(lk: *SpinLock, name: [*:0]const u8) void;
pub extern fn acquire(lock: *SpinLock) void;
pub extern fn release(lock: *SpinLock) void;
pub extern fn holding(lock: *SpinLock) bool;

/// Long-term locks for processes
pub const SleepLock = extern struct {
    /// Is the lock held?
    locked: c_uint,
    /// spinlock protecting this sleep lock
    lk: SpinLock,

    // For debugging:
    /// Name of lock.
    name: [*:0]u8,
    /// Process holding lock
    pid: c_int,
};

pub const Pipe = extern struct {
    pub const SIZE = 512;

    lock: SpinLock,
    data: [SIZE]u8,
    /// number of bytes read
    nread: c_uint,
    /// number of bytes written
    nwrite: c_uint,
    /// read fd is still open
    readopen: c_int,
    /// write fd is still open
    writeopen: c_int,

    pub const alloc = pipealloc;
    pub const close = pipeclose;
};

// pipe.c
pub extern fn pipealloc(**File, **File) c_int;
pub extern fn pipeclose(*Pipe, c_int) void;

pub const Stat = extern struct {
    pub const Type = enum(u16) {
        dir = 1,
        file = 2,
        device = 3,
    };

    /// File system's disk device
    dev: c_int,
    /// Inode number
    ino: c_int,
    /// Type of file
    type: Type,
    /// Number of links to file
    nlink: c_short,
    /// Size of file in bytes
    size: usize,
};

pub const File = extern struct {
    type: enum(c_int) { none, pipe, inode, device },
    /// reference count
    ref: c_int,
    readable: u8,
    writable: u8,
    /// FD_PIPE
    pipe: *Pipe,
    /// FD_INODE and FD_DEVICE
    ip: *Inode,
    /// FD_INODE
    off: c_uint,
    /// FD_DEVICE
    major: c_short,

    pub const dup = filedup;
    pub const read = fileread;
    pub const write = filewrite;
    pub const close = fileclose;
    pub const stat = filestat;
    pub const alloc = filealloc;
};

// file.c
pub extern fn filedup(file: *File) *File;
pub extern fn fileread(file: *File, addr: usize, n: usize) c_int;
pub extern fn filewrite(file: *File, addr: usize, n: usize) c_int;
pub extern fn fileclose(file: *File) void;
pub extern fn filestat(file: *File, addr: usize) c_int;
pub extern fn filealloc() ?*File;

// log.c
pub extern fn begin_op() void;
pub extern fn end_op() void;

/// in-memory copy of an inode
pub const Inode = extern struct {
    /// Device number
    dev: c_uint,
    /// Inode number
    inum: c_uint,
    /// Reference count
    ref: c_int,
    /// protects everything below here
    lock: SleepLock,
    /// inode has been read from disk?
    valid: c_int,

    /// copy of disk inode
    type: Stat.Type,
    major: c_short,
    minor: c_short,
    nlink: c_short,
    size: c_uint,
    addrs: [fs.NDIRECT + 1 + 1]c_uint,

    pub const dup = idup;
    pub const ilock = c.ilock;
    pub const put = iput;
    pub const unlockput = iunlockput;
    pub const update = iupdate;
    pub const unlock = iunlock;
    pub const dirlink = c.dirlink;
    pub const dirlookup = c.dirlookup;
    pub const write = writei;
    pub const read = readi;
    pub const trunc = itrunc;
    pub const alloc = ialloc;
};

// fs.c
pub extern fn fsinit(c_int) void;
pub extern fn namei([*:0]const u8) ?*Inode;
pub extern fn nameiparent([*:0]const u8, [*]u8) ?*Inode;

pub extern fn idup(inode: *Inode) *Inode;
pub extern fn ilock(inode: *Inode) void;
pub extern fn iput(inode: *Inode) void;
pub extern fn iunlockput(inode: *Inode) void;
pub extern fn iupdate(inode: *Inode) void;
pub extern fn iunlock(inode: *Inode) void;
pub extern fn dirlink(inode: *Inode, name: [*]const u8, inum: usize) c_int;
pub extern fn dirlookup(inode: *Inode, name: [*]const u8, poff: ?*u32) ?*Inode;

pub extern fn writei(inode: *Inode, user_src: bool, src: usize, off: usize, n: usize) c_int;
pub extern fn readi(inode: *Inode, user_src: bool, dst: usize, off: usize, n: usize) c_int;
pub extern fn itrunc(inode: *Inode) void;
pub extern fn ialloc(dev: c_uint, type: Stat.Type) ?*Inode;

// Disk layout:
// [ boot block | super block | log | inode blocks | free bit map | data blocks]
//
// mkfs computes the super block and builds an initial file system. The
// super block describes the disk layout:
pub const SuperBlock = extern struct {
    pub const FSMAGIC = 0x10203040;

    /// Must be FSMAGIC
    magic: u32,
    /// Size of file system image (blocks)
    size: u32,
    /// Number of data blocks
    nblocks: u32,
    /// Number of inodes.
    ninodes: u32,
    /// Number of log blocks
    nlog: u32,
    /// Block number of first log block
    logstart: u32,
    /// Block number of first inode block
    inodestart: u32,
    /// Block number of first free map block
    bmapstart: u32,
};

// 64 bytes
pub const Dinode = extern struct {
    type: Stat.Type,
    major: c_short,
    minor: c_short,
    nlink: c_short,
    size: c_uint,
    addrs: [fs.NDIRECT + 1 + 1]c_uint,
};

/// Directory is a file containing a sequence of dirent structures.
pub const Dirent = extern struct {
    pub const DIRSIZ = 14;

    inum: c_ushort,
    name: [DIRSIZ]u8,
};

/// Saved registers for kernel context switches.
pub const Context = extern struct {
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

    pub const swtch = c.swtch;
};

pub extern fn swtch(old: *Context, new: *Context) void;

/// Per-CPU state.
pub const Cpu = extern struct {
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
pub const TrapFrame = extern struct {
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

// trap.c
pub extern fn usertrapret() void;

// virtio_disk.c
pub extern fn virtio_disk_intr() void;

// uart.c
pub extern fn uartintr() void;
