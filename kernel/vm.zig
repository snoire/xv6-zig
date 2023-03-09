const std = @import("std");
const xv6 = @import("xv6.zig");
const csr = xv6.register.csr;
const kalloc = @import("kalloc.zig");
const assert = std.debug.assert;
const proc = @import("proc.zig");

// one beyond the highest possible virtual address.
// MAXVA is actually one bit less than the max allowed by
// Sv39, to avoid having to sign-extend virtual addresses
// that have the high bit set.
const MAXVA = 1 << (9 + 9 + 9 + 12 - 1);
pub const PGSIZE = 4096;
pub const TRAMPOLINE = MAXVA - PGSIZE;
pub const TRAPFRAME = TRAMPOLINE - PGSIZE;

/// kernel.ld sets this to end of kernel code.
extern const etext: u1;
/// trampoline.S
extern const trampoline: u1;

/// the kernel's page table.
var kernel_pagetable: Address = undefined;

pub const Address = packed union {
    interger: usize,
    buffer: [*]u8,
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

    pub const PageTable = *[512]Pte; // 512 PTEs

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

    fn roundUp(self: Address) usize {
        return std.mem.alignForward(self.interger, PGSIZE);
    }

    fn roundDown(self: Address) usize {
        return std.mem.alignBackward(self.interger, PGSIZE);
    }

    fn add(self: Address, addr: Address) Address {
        return .{
            .interger = self.interger + addr.interger,
        };
    }

    fn sub(self: Address, addr: Address) Address {
        return .{
            .interger = self.interger - addr.interger,
        };
    }
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
    proc.mapstacks(kernel_pagetable);
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
/// or panic if not mapped.
/// Can only be used to look up user pages.
fn cwalkaddr(pagetable: Address, va: Address) callconv(.C) Address {
    if (va.interger >= MAXVA) @panic("walkaddr");

    var pte = walk(pagetable, va, false).?;
    if (!pte.flags.valid or !pte.flags.user) @panic("walkaddr");

    return pte.getAddr();
}

comptime {
    @export(cwalkaddr, .{ .name = "walkaddr", .linkage = .Strong });
}

fn walkaddr(pagetable: Address, va: Address) Address {
    if (va.interger >= MAXVA) @panic("walkaddr");

    var pte = walk(pagetable, va, false).?;
    if (!pte.flags.valid or !pte.flags.user) @panic("walkaddr");

    return Address{
        .paddr = .{
            .ppn = pte.ppn,
            .offset = va.vaddr.offset,
        },
    };
}

/// Create PTEs for virtual addresses starting at va that refer to
/// physical addresses starting at pa. va and size might not
/// be page-aligned. Returns 0 on success, -1 if walk() couldn't
/// allocate a needed page-table page.
pub export fn mappages(pagetable: Address, vaddress: usize, size: usize, paddress: usize, perm: Pte.Flags) c_int {
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
pub export fn kvmmap(pagetable: Address, va: usize, pa: usize, size: usize, perm: Pte.Flags) void {
    if (mappages(pagetable, va, size, pa, perm) != 0) @panic("kvmmap");
}

/// Remove npages of mappings starting from va. va must be
/// page-aligned. The mappings must exist.
/// Optionally free the physical memory.
pub export fn uvmunmap(pagetable: Address, va: Address, npages: usize, do_free: bool) void {
    if (!std.mem.isAligned(va.interger, PGSIZE)) @panic("uvmunmap: not aligned");

    var addr = va;
    while (addr.interger < va.interger + npages * PGSIZE) : (addr.interger += PGSIZE) {
        var pte = walk(pagetable, addr, false).?;
        if (!pte.flags.valid) @panic("uvmunmap: not mapped");
        if (@bitCast(u8, pte.flags) == @bitCast(u8, Pte.Flags{ .valid = true })) {
            @panic("uvmunmap: not a leaf");
        }
        if (do_free) {
            kalloc.kfree(pte.getAddr().page);
        }
        pte.* = .{};
    }
}

/// create an empty user page table.
/// panic if out of memory.
pub export fn uvmcreate() Address {
    return .{ .page = kalloc.kalloc().? };
}

/// Load the user initcode into address 0 of pagetable,
/// for the very first process.
/// sz must be less than a page.
pub fn uvmfirst(pagetable: Address, src: []const u8) void {
    if (src.len >= PGSIZE) @panic("uvmfirst: more than a page");

    var mem = Address{ .page = kalloc.kalloc().? };
    var ret = mappages(pagetable, 0, PGSIZE, mem.interger, .{
        .writable = true,
        .readable = true,
        .executable = true,
        .user = true,
    });
    if (ret != 0) @panic("uvmfirst");

    std.mem.copy(u8, mem.page, src);
}

/// Allocate PTEs and physical memory to grow process from oldsz to
/// newsz, which need not be page aligned.  Returns new size or panic on error.
export fn uvmalloc(pagetable: Address, oldsz: usize, newsz: usize, xperm: Pte.Flags) usize {
    if (newsz < oldsz) return oldsz;

    var flags = xperm;
    flags.readable = true;
    flags.user = true;

    var addr = std.mem.alignForward(oldsz, PGSIZE);
    while (addr < newsz) : (addr += PGSIZE) {
        var mem = Address{ .page = kalloc.kalloc().? };
        var ret = mappages(pagetable, addr, PGSIZE, mem.interger, flags);
        if (ret != 0) @panic("uvmalloc");
    }
    return newsz;
}

/// Deallocate user pages to bring the process size from oldsz to
/// newsz.  oldsz and newsz need not be page-aligned, nor does newsz
/// need to be less than oldsz.  oldsz can be larger than the actual
/// process size.  Returns the new process size.
export fn uvmdealloc(pagetable: Address, oldsz: usize, newsz: usize) usize {
    if (newsz < oldsz) return oldsz;

    var old = std.mem.alignForward(oldsz, PGSIZE);
    var new = std.mem.alignForward(newsz, PGSIZE);
    if (old < new) {
        var npages = (old - new) / PGSIZE;
        uvmunmap(pagetable, .{ .interger = newsz }, npages, true);
    }

    return newsz;
}

/// Recursively free page-table pages.
/// All leaf mappings must already have been removed.
export fn freewalk(pagetable: Address) void {
    // there are 2^9 = 512 PTEs in a page table.
    for (pagetable.pagetable) |*pte| {
        if (!pte.flags.valid) continue;
        if (pte.flags.readable or pte.flags.writable or pte.flags.executable) {
            @panic("freewalk: leaf");
        }

        var child = pte.getAddr();
        freewalk(child);
        pte.* = .{};
    }

    kalloc.kfree(pagetable.page);
}

/// Free user memory pages,
/// then free page-table pages.
pub export fn uvmfree(pagetable: Address, sz: usize) void {
    uvmunmap(pagetable, .{ .interger = 0 }, std.mem.alignForward(sz, PGSIZE) / PGSIZE, true);
    freewalk(pagetable);
}

/// Given a parent process's page table, copy
/// its memory into a child's page table.
/// Copies both the page table and the
/// physical memory.
/// panic on failure.
pub fn uvmcopy(old_pagetable: Address, new_pagetable: Address, sz: usize) void {
    var i: usize = 0;
    while (i < sz) : (i += PGSIZE) {
        var pte = walk(old_pagetable, .{ .interger = i }, false).?;
        if (!pte.flags.valid) @panic("uvmcopy: page not present");

        var pa = pte.getAddr();
        var mem = Address{ .page = kalloc.kalloc().? };

        std.mem.copy(u8, mem.page, pa.page);
        if (mappages(new_pagetable, i, PGSIZE, mem.interger, pte.flags) != 0) {
            @panic("mappages");
        }
    }
}

/// mark a PTE invalid for user access.
/// used by exec for the user stack guard page.
export fn uvmclear(pagetable: Address, va: Address) void {
    var pte = walk(pagetable, va, false).?;
    pte.flags.user = false;
}

/// Copy from kernel to user.
/// Copy len bytes from src to virtual address dstva in a given page table.
/// Return 0 on success, -1 on error.
pub export fn copyout(pagetable: Address, dstva: Address, source: [*]const u8, length: usize) c_int {
    var n: usize = 0;
    var dst = dstva;

    while (n < length) {
        var pa = walkaddr(pagetable, dst);
        var nbytes = @min(PGSIZE - (dst.interger - dst.roundDown()), length - n);
        std.mem.copy(u8, pa.buffer[0..nbytes], source[n .. n + nbytes]);

        n += nbytes;
        dst.interger = dst.roundDown() + PGSIZE;
    }

    return 0;
}

/// Copy from user to kernel.
/// Copy len bytes to dst from virtual address srcva in a given page table.
/// Return 0 on success, -1 on error.
pub export fn copyin(pagetable: Address, dst: [*]u8, srcva: Address, length: usize) c_int {
    var n: usize = 0;
    var src = srcva;

    while (n < length) {
        var pa = walkaddr(pagetable, src);
        var nbytes = @min(PGSIZE - (src.interger - src.roundDown()), length - n);
        std.mem.copy(u8, dst[n .. n + nbytes], pa.buffer[0..nbytes]);

        n += nbytes;
        src.interger = src.roundDown() + PGSIZE;
    }

    return 0;
}

/// Copy a null-terminated string from user to kernel.
/// Copy bytes to dst from virtual address srcva in a given page table,
/// until a '\0', or max.
/// Return 0 on success, -1 on error.
export fn copyinstr(pagetable: Address, dst: [*]u8, srcva: Address, max: usize) c_int {
    var n: usize = 0;
    var src = srcva;
    var got_null: bool = false;

    while (n < max) {
        var pa = walkaddr(pagetable, src);
        var nbytes = @min(PGSIZE - (src.interger - src.roundDown()), max - n);
        const data = pa.buffer[0..nbytes];

        nbytes = blk: {
            const index_of_zero = std.mem.indexOfScalar(u8, data, 0);
            if (index_of_zero) |i| {
                got_null = true;
                break :blk i + 1;
            } else {
                break :blk data.len;
            }
        };

        std.mem.copy(u8, dst[n .. n + nbytes], data[0..nbytes]);
        if (got_null) break;

        n += nbytes;
        src.interger = src.roundDown() + PGSIZE;
    }

    if (got_null) {
        return 0;
    } else {
        return -1;
    }
}
