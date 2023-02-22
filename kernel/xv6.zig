pub const c = @import("c.zig");
pub const fs = @import("fs.zig");
pub const register = @import("register.zig");
pub const SleepLock = @import("SleepLock.zig");
pub const SpinLock = @import("SpinLock.zig");
pub const syscall = @import("syscall.zig");
pub const print = @import("print.zig");

/// maximum number of processes
pub const NPROC = 64;
/// maximum number of CPUs
pub const NCPU = 8;
/// open files per process
pub const NOFILE = 16;
/// open files per system
pub const NFILE = 100;
/// maximum number of active i-nodes
pub const NINODE = 50;
/// maximum major device number
pub const NDEV = 10;
/// device number of file system root disk
pub const ROOTDEV = 1;
/// max exec arguments
pub const MAXARG = 32;
/// max # of blocks any FS op writes
pub const MAXOPBLOCKS = 10;
/// max data blocks in on-disk log
pub const LOGSIZE = (MAXOPBLOCKS * 3);
/// size of disk block cache
pub const NBUF = (MAXOPBLOCKS * 3);
/// size of file system in blocks
pub const FSSIZE = 32000;
/// maximum file path name
pub const MAXPATH = 128;

// Physical memory layout

// qemu -machine virt is set up like this,
// based on qemu's hw/riscv/virt.c:
//
// 00001000 -- boot ROM, provided by qemu
// 02000000 -- CLINT
// 0C000000 -- PLIC
// 10000000 -- uart0
// 10001000 -- virtio disk
// 80000000 -- boot ROM jumps here in machine mode
//             -kernel loads the kernel here
// unused RAM after 80000000.

// the kernel uses physical memory thus:
// 80000000 -- entry.S, then kernel text and data
// end -- start of kernel page allocation area
// PHYSTOP -- end RAM used by the kernel

// qemu puts UART registers here in physical memory.
pub const UART0 = 0x1000_0000;
pub const UART0_IRQ = 10;

// virtio mmio interface
pub const VIRTIO0 = 0x1000_1000;
pub const VIRTIO0_IRQ = 1;

/// core local interruptor (CLINT), which contains the timer.
pub const clint = struct {
    const base = 0x0200_0000;

    /// trigger a machine-level software interrupt
    pub fn msip(hart: u3, val: u1) void {
        const ptr = @intToPtr([*]volatile u32, base);
        ptr[hart] = val;
    }

    /// The machine time counter. QEMU increments this at a frequency of 10Mhz.
    pub fn mtime() u64 {
        return @intToPtr(*volatile u64, base + 0xbff8).*;
    }

    /// The machine time compare register
    pub const mtimecmp = struct {
        const offset = 0x4000;

        /// a timer interrupt is fired if mtimecmp >= mtime
        pub fn set(hart: u8, time: u64) void {
            const ptr = @intToPtr([*]volatile u64, base + offset);
            ptr[hart] = time;
        }

        /// get the machine time compare register address
        pub fn get(hart: u8) usize {
            return base + offset + 8 * @as(usize, hart);
        }
    };
};
