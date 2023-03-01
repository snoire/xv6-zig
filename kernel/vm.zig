const std = @import("std");
const kalloc = @import("kalloc.zig");
const assert = std.debug.assert;
// extern var kernel_pagetable

// one beyond the highest possible virtual address.
// MAXVA is actually one bit less than the max allowed by
// Sv39, to avoid having to sign-extend virtual addresses
// that have the high bit set.
const MAXVA = 1 << (9 + 9 + 9 + 12 - 1);
const PGSIZE = 4096;

const PageTable = *[512]Pte; // 512 PTEs

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
