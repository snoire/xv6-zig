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

/// kernel.ld sets this to end of kernel code.
extern const etext: u1;
/// trampoline.S
extern const trampoline: u1;

/// the kernel's page table.
var kernel_pagetable: Address = undefined;

const Address = packed union {
    interger: usize,
    vaddr: VirtualAddr,
    paddr: PhysicalAddr,
    page: kalloc.Page,
    pagetable: PageTable,

    comptime {
        // Address must be 64bit.
        assert(@bitSizeOf(@This()) == 64);

        // And every field of it must be 64bit too.
        for (std.meta.fields(@This())) |field| {
            assert(@bitSizeOf(field.type) == 64);
        }
    }

    const PageTable = *[512]Pte; // 512 PTEs

    /// virtual address
    const VirtualAddr = packed struct {
        offset: u12 = 0,
        l0: u9 = 0,
        l1: u9 = 0,
        l2: u9 = 0,

        _: u25 = 0,
    };

    /// physical address
    const PhysicalAddr = packed struct {
        offset: u12 = 0,
        ppn: u44 = 0,

        _: u8 = 0,
    };
};

/// page-table entry
const Pte = packed struct {
    // flags
    flags: Flags = .{},

    @"8-9": u2 = 0,

    /// physical page number
    ppn: u44 = 0,

    _: u10 = 0,

    const Flags = packed struct {
        valid: bool = false,
        readable: bool = false,
        writable: bool = false,
        executable: bool = false,
        user: bool = false,
        global: bool = false,
        accessed: bool = false,
        dirty: bool = false,
    };

    comptime {
        assert(@bitSizeOf(@This()) == 64);
    }

    fn getAddr(self: @This()) Address {
        return Address{
            .paddr = .{ .ppn = self.ppn },
        };
    }
};

/// Allocate a page for each process's kernel stack.
/// Map it high in memory, followed by an invalid
/// guard page.
extern fn proc_mapstacks(pagetable: Address) void;

pub fn init() void {
    const etext_addr = @ptrToInt(&etext);
    const trampoline_addr = @ptrToInt(&trampoline);

    // Make a direct-map page table for the kernel.
    kernel_pagetable = .{ .page = kalloc.kalloc().? };

    // uart registers
    kvmmap(kernel_pagetable, xv6.UART0, xv6.UART0, PGSIZE, .{
        .readable = true,
        .writable = true,
    });

    // virtio mmio disk interface
    kvmmap(kernel_pagetable, xv6.VIRTIO0, xv6.VIRTIO0, PGSIZE, .{
        .readable = true,
        .writable = true,
    });

    // PLIC
    kvmmap(kernel_pagetable, xv6.PLIC, xv6.PLIC, 0x400000, .{
        .readable = true,
        .writable = true,
    });

    // map kernel text executable and read-only.
    kvmmap(kernel_pagetable, kalloc.KERNBASE, kalloc.KERNBASE, etext_addr - kalloc.KERNBASE, .{
        .readable = true,
        .executable = true,
    });

    // map kernel data and the physical RAM we'll make use of.
    kvmmap(kernel_pagetable, etext_addr, etext_addr, kalloc.PHYSTOP - etext_addr, .{
        .readable = true,
        .writable = true,
    });

    // map the trampoline for trap entry/exit to
    // the highest virtual address in the kernel.
    kvmmap(kernel_pagetable, TRAMPOLINE, trampoline_addr, PGSIZE, .{
        .readable = true,
        .executable = true,
    });

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

    csr.satp.set(.{
        .mode = .sv39,
        .ppn = kernel_pagetable.paddr.ppn,
    });

    // flush stale entries from the TLB.
    sfence_vma();
}

/// Return the address of the PTE in page table pagetable
/// that corresponds to virtual address va.  If alloc!=0,
/// create any required page-table pages.
export fn walk(pagetable: Address, va: Address, alloc: bool) ?*Pte {
    if (va.interger >= MAXVA) @panic("walk");

    var pt = pagetable;

    inline for (.{ va.vaddr.l2, va.vaddr.l1 }) |index| {
        var pte = &pt.pagetable[index];

        if (pte.flags.valid) {
            pt = pte.getAddr();
        } else {
            if (!alloc) return null;
            pt = .{ .page = kalloc.kalloc().? };
            pte.ppn = pt.paddr.ppn;
            pte.flags.valid = true;
        }
    }

    return &pt.pagetable[va.vaddr.l0];
}

/// Look up a virtual address, return the physical address,
/// or 0 if not mapped.
/// Can only be used to look up user pages.
export fn walkaddr(pagetable: Address, va: Address) Address {
    if (va.interger >= MAXVA) @panic("walk");

    var pte = walk(pagetable, va, false) orelse return .{ .interger = 0 };
    if (!pte.flags.valid or !pte.flags.user) return .{ .interger = 0 };

    return pte.getAddr();
}

/// Create PTEs for virtual addresses starting at va that refer to
/// physical addresses starting at pa. va and size might not
/// be page-aligned. Returns 0 on success, -1 if walk() couldn't
/// allocate a needed page-table page.
export fn mappages(pagetable: Address, vaddress: usize, size: usize, paddress: usize, perm: Pte.Flags) c_int {
    if (size == 0) @panic("mappages: size");

    var pa = Address{ .interger = paddress };
    var va = Address{ .interger = std.mem.alignBackward(vaddress, PGSIZE) };
    const last = Address{ .interger = std.mem.alignBackward(vaddress + size - 1, PGSIZE) };

    while (true) {
        var pte = walk(pagetable, va, true).?;
        if (pte.flags.valid) @panic("mappages: remap");

        pte.ppn = pa.paddr.ppn;
        pte.flags = perm;
        pte.flags.valid = true;

        if (va.interger == last.interger) break;
        va.interger += PGSIZE;
        pa.interger += PGSIZE;
    }

    return 0;
}

/// add a mapping to the kernel page table.
/// only used when booting.
/// does not flush TLB or enable paging.
export fn kvmmap(pagetable: Address, va: usize, pa: usize, size: usize, perm: Pte.Flags) void {
    if (mappages(pagetable, va, size, pa, perm) != 0) @panic("kvmmap");
}
