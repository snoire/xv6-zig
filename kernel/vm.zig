const std = @import("std");
const xv6 = @import("xv6.zig");
const csr = xv6.register.csr;
const kalloc = @import("kalloc.zig");
const assert = std.debug.assert;

// one beyond the highest possible virtual address.
// MAXVA is actually one bit less than the max allowed by
// Sv39, to avoid having to sign-extend virtual addresses
// that have the high bit set.
const MAXVA = 1 << (9 + 9 + 9 + 12 - 1);
const PGSIZE = 4096;
const TRAMPOLINE = MAXVA - PGSIZE;

const PageTable = *[512]Pte; // 512 PTEs

/// the kernel's page table.
var kernel_pagetable: PageTable = undefined;
/// kernel.ld sets this to end of kernel code.
extern const etext: u1;
/// trampoline.S
extern const trampoline: u1;

/// page-table entry
const Pte = packed struct {
    // flags
    valid: bool = false,
    readable: bool = false,
    writable: bool = false,
    executable: bool = false,
    user: bool = false,
    global: bool = false,
    accessed: bool = false,
    dirty: bool = false,

    @"8-9": u2 = 0,

    /// physical page number
    ppn: u44 = 0,

    _: u10 = 0,

    comptime {
        assert(@bitSizeOf(@This()) == 64);
    }

    fn toPageTable(self: @This()) PageTable {
        const physical_addr = self.ppn << 12;
        return @intToPtr(PageTable, physical_addr);
    }
};

/// virtual address
const Va = packed struct {
    offset: u12 = 0,
    l0: u9 = 0,
    l1: u9 = 0,
    l2: u9 = 0,

    _: u25 = 0,

    comptime {
        assert(@bitSizeOf(@This()) == 64);
    }
};

/// Allocate a page for each process's kernel stack.
/// Map it high in memory, followed by an invalid
/// guard page.
extern fn proc_mapstacks(pagetable: PageTable) void;

pub fn init() void {
    // Make a direct-map page table for the kernel.
    var page = kalloc.kalloc().?;
    std.mem.set(u8, page, 0);
    kernel_pagetable = @ptrCast(PageTable, page);
    const ETEXT = @ptrToInt(&etext);

    // uart registers
    kvmmap(kernel_pagetable, xv6.UART0, xv6.UART0, PGSIZE, .{ .readable = true, .writable = true });

    // virtio mmio disk interface
    kvmmap(kernel_pagetable, xv6.VIRTIO0, xv6.VIRTIO0, PGSIZE, .{ .readable = true, .writable = true });

    // PLIC
    kvmmap(kernel_pagetable, xv6.PLIC, xv6.PLIC, 0x400000, .{ .readable = true, .writable = true });

    // map kernel text executable and read-only.
    kvmmap(kernel_pagetable, kalloc.KERNBASE, kalloc.KERNBASE, ETEXT - kalloc.KERNBASE, .{ .readable = true, .executable = true });

    // map kernel data and the physical RAM we'll make use of.
    kvmmap(kernel_pagetable, ETEXT, ETEXT, kalloc.PHYSTOP - ETEXT, .{ .readable = true, .writable = true });

    // map the trampoline for trap entry/exit to
    // the highest virtual address in the kernel.
    kvmmap(kernel_pagetable, TRAMPOLINE, @ptrToInt(&trampoline), PGSIZE, .{ .readable = true, .executable = true });

    // allocate and map a kernel stack for each process.
    proc_mapstacks(kernel_pagetable);
}

// flush the TLB.
inline fn sfence_vma() void {
    // the zero, zero means flush all TLB entries.
    asm volatile ("sfence.vma zero, zero");
}

/// Switch h/w page table register to the kernel's page table,
/// and enable paging.
pub fn inithart() void {
    // wait for any previous writes to the page table memory to finish.
    sfence_vma();

    csr.satp.set(.{ .mode = .sv39, .ppn = @intCast(u44, @ptrToInt(kernel_pagetable)) >> 12 });

    // flush stale entries from the TLB.
    sfence_vma();
}

/// Return the address of the PTE in page table pagetable
/// that corresponds to virtual address va.  If alloc!=0,
/// create any required page-table pages.
export fn walk(pagetable: PageTable, va: Va, alloc: bool) ?*Pte {
    if (@bitCast(usize, va) >= MAXVA) @panic("walk");

    var pt = pagetable;

    inline for (.{ va.l2, va.l1 }) |index| {
        var pte = &pt[index];
        if (pte.valid) {
            pt = pte.toPageTable();
        } else {
            if (!alloc) return null;

            var page = kalloc.kalloc() orelse return null;
            std.mem.set(u8, page, 0);

            pt = @ptrCast(PageTable, page);
            pte.ppn = @intCast(u44, @ptrToInt(pt)) >> 12;
            pte.valid = true;
        }
    }

    return &pt[va.l0];
}

/// Look up a virtual address, return the physical address,
/// or 0 if not mapped.
/// Can only be used to look up user pages.
export fn walkaddr(pagetable: PageTable, va: Va) usize {
    if (@bitCast(usize, va) >= MAXVA) @panic("walk");

    var pte = walk(pagetable, va, false) orelse return 0;
    if (!pte.valid or !pte.user) return 0;

    return @ptrToInt(pte.toPageTable());
}

/// Create PTEs for virtual addresses starting at va that refer to
/// physical addresses starting at pa. va and size might not
/// be page-aligned. Returns 0 on success, -1 if walk() couldn't
/// allocate a needed page-table page.
export fn mappages(pagetable: PageTable, va: usize, size: usize, pa: usize, perm: usize) c_int {
    if (size == 0) @panic("mappages: size");

    var paddr = pa;
    var addr = std.mem.alignBackward(va, PGSIZE);
    const last = std.mem.alignBackward(va + size - 1, PGSIZE);

    while (true) {
        var pte = walk(pagetable, @bitCast(Va, addr), true).?;
        if (pte.valid) @panic("mappages: remap");

        @ptrCast(*usize, pte).* = perm;
        pte.ppn = @intCast(u44, paddr) >> 12;
        pte.valid = true;

        if (addr == last) break;
        addr += PGSIZE;
        paddr += PGSIZE;
    }

    return 0;
}

/// add a mapping to the kernel page table.
/// only used when booting.
/// does not flush TLB or enable paging.
export fn kvmmap(pagetable: PageTable, va: usize, pa: usize, size: usize, perm: Pte) void {
    if (mappages(pagetable, va, size, pa, @bitCast(usize, perm)) != 0) @panic("kvmmap");
}
