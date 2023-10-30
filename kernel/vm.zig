const std = @import("std");
const xv6 = @import("xv6.zig");
const csr = xv6.register.csr;
const proc = @import("proc.zig");
const allocator = std.heap.page_allocator;
const assert = std.debug.assert;
const mem = std.mem;

pub const PGSIZE = 4096;
pub const Page = [PGSIZE]u8;
pub const TRAMPOLINE: usize = VirAddr.MAXVA - PGSIZE;
pub const TRAPFRAME: usize = TRAMPOLINE - PGSIZE;

pub const TOTAL_BYTES = 128 * 1024 * 1024;
pub const KERNBASE = 0x80000000;
pub const PHYSTOP = KERNBASE + TOTAL_BYTES;
const KSTACK_NUM = 4;

/// kernel.ld sets this to end of kernel code.
extern const etext: u8;
/// trampoline.S
extern const trampoline: u8;

/// the kernel's page table.
var kernel_pagetable: PageTable = undefined;

/// virtual address
pub const VirAddr = packed struct {
    offset: u12 = 0,
    l0: u9 = 0,
    l1: u9 = 0,
    l2: u9 = 0,

    _: u25 = 0,

    // one beyond the highest possible virtual address. MAXVA is actually one bit less
    // than the max allowed by Sv39, to avoid having to sign-extend virtual addresses
    // that have the high bit set.
    const MAXVA = 1 << (9 + 9 + 9 + 12 - 1);

    comptime {
        assert(@bitSizeOf(@This()) == @bitSizeOf(usize));
    }
};

/// physical address
pub const PhyAddr = packed struct {
    offset: u12 = 0,
    ppn: u44 = 0,

    _: u8 = 0,

    comptime {
        assert(@bitSizeOf(@This()) == @bitSizeOf(usize));
    }

    fn toPtr(addr: PhyAddr) [*]u8 {
        const number: usize = @bitCast(addr);
        return @ptrFromInt(number);
    }
};

/// page-table entry
pub const Pte = packed struct {
    // flags
    flags: Flags = .{},

    @"8-9": u2 = 0,

    /// physical page number
    ppn: u44 = 0,

    _: u10 = 0,

    pub const Flags = packed struct {
        valid: bool = false,
        readable: bool = false,
        writable: bool = false,
        executable: bool = false,
        user: bool = false,
        global: bool = false,
        accessed: bool = false,
        dirty: bool = false,

        fn eql(a: Flags, b: Flags) bool {
            const x: u8 = @bitCast(a);
            const y: u8 = @bitCast(b);
            return x == y;
        }
    };

    comptime {
        assert(@bitSizeOf(@This()) == @bitSizeOf(usize));
    }

    fn getPhyAddr(pte: Pte) usize {
        return @bitCast(PhyAddr{ .ppn = pte.ppn });
    }

    fn getPageTable(pte: Pte) PageTable {
        return @bitCast(pte.getPhyAddr());
    }
};

pub const PageTable = packed union {
    ptes: ?*[512]Pte,

    // converts to other types
    page: *align(PGSIZE) Page,
    addr: PhyAddr,

    const Self = @This();
    const zero: usize = 0;

    comptime {
        assert(@bitSizeOf(Self) == @bitSizeOf(usize));
        @export(cwalkaddr, .{ .name = "walkaddr", .linkage = .Strong });
        @export(ccopyout, .{ .name = "copyout", .linkage = .Strong });
        @export(ccopyin, .{ .name = "copyin", .linkage = .Strong });
    }

    pub fn create() !Self {
        const page = try allocator.create(Page);
        @memset(page, 0);

        return .{
            .page = @alignCast(page),
        };
    }

    pub fn destroy(self: *const Self) void {
        allocator.destroy(self.page);
    }

    /// Return the address of the PTE in page table pagetable that corresponds to
    /// virtual address vir. If alloc==true, create any required page-table pages.
    fn walk(pagetable: PageTable, vir: VirAddr, comptime is_alloc: bool) !*Pte {
        const addr: usize = @bitCast(vir);
        if (addr >= VirAddr.MAXVA) @panic("walk");

        var pt = pagetable;
        const indices: [2]u9 = .{ vir.l2, vir.l1 };

        for (indices) |index| {
            const pte = &pt.ptes.?[index];

            if (pte.flags.valid) {
                pt = pte.getPageTable();
            } else {
                if (!is_alloc) return error.NotFound;
                pt = try PageTable.create();
                pte.ppn = pt.addr.ppn;
                pte.flags.valid = true;
            }
        }

        return &pt.ptes.?[vir.l0];
    }

    // Look up a virtual address, return the physical address, or 0 if not mapped.
    // Can only be used to look up user pages.
    fn cwalkaddr(pagetable: PageTable, vir: VirAddr) callconv(.C) usize {
        const phy = pagetable.walkaddr(vir) catch return 0;
        const addr: usize = @bitCast(phy);
        return addr - vir.offset;
    }

    /// Look up a virtual address, return the physical address, or error if not mapped.
    /// Can only be used to look up user pages.
    pub fn walkaddr(pagetable: PageTable, vir: VirAddr) !PhyAddr {
        const addr: usize = @bitCast(vir);
        if (addr >= VirAddr.MAXVA) return error.NotMapped;

        const pte = pagetable.walk(vir, false) catch return error.NotMapped;
        if (!pte.flags.valid or !pte.flags.user) return error.NotMapped;

        return .{
            .ppn = pte.ppn,
            .offset = vir.offset,
        };
    }

    /// Create PTEs for virtual addresses starting at vir that refer to physical addresses
    /// starting at pa. vir and size might not be page-aligned. Returns 0 on success, or
    /// panic if walk() couldn't allocate a needed page-table page.
    pub fn mappages(pagetable: PageTable, vir: VirAddr, size: usize, phy: PhyAddr, perm: Pte.Flags) void {
        if (size == 0) @panic("mappages: size");
        const vir_addr: usize = @bitCast(vir);
        const last = pageRoundDown(vir_addr + size - 1);

        var va = pageRoundDown(vir_addr);
        var pa: usize = @bitCast(phy);

        while (true) {
            const pte = pagetable.walk(@bitCast(va), true) catch unreachable;
            if (pte.flags.valid) @panic("mappages: remap");

            const phy_addr: PhyAddr = @bitCast(pa);
            pte.ppn = phy_addr.ppn;
            pte.flags = perm;
            pte.flags.valid = true;

            if (va == last) break;
            va += PGSIZE;
            pa += PGSIZE;
        }
    }

    /// Remove npages of mappings starting from vir. vir must be page-aligned. The mappings
    /// must exist. Optionally free the physical memory.
    pub fn unmap(pagetable: PageTable, vir: VirAddr, npages: usize, do_free: bool) void {
        const start: usize = @bitCast(vir);
        const end = start + npages * PGSIZE;
        assert(mem.isAligned(start, PGSIZE));

        var addr = start;
        while (addr < end) : (addr += PGSIZE) {
            const pte = pagetable.walk(@bitCast(addr), false) catch unreachable;
            if (!pte.flags.valid) @panic("uvmunmap: not mapped");
            if (pte.flags.eql(.{ .valid = true })) @panic("uvmunmap: not a leaf");

            if (do_free) {
                const page: *align(PGSIZE) Page = @ptrFromInt(pte.getPhyAddr());
                allocator.destroy(page);
            }
            pte.* = .{};
        }
    }

    /// Load the user initcode into address 0 of pagetable, for the very first process.
    /// code.len must be less than a page.
    pub fn first(pagetable: PageTable, comptime code: []const u8) void {
        comptime assert(code.len <= PGSIZE);
        const page = allocator.create(Page) catch unreachable;
        const addr: usize = @intFromPtr(page);

        pagetable.mappages(@bitCast(zero), PGSIZE, @bitCast(addr), .{
            .writable = true,
            .readable = true,
            .executable = true,
            .user = true,
        });

        @memcpy(page[0..code.len], code);
    }

    /// Allocate PTEs and physical memory to grow process from oldsz by increase, which
    /// need not be page aligned. Returns new size or error.OutOfMemory.
    pub fn alloc(pagetable: PageTable, oldsz: usize, increase: usize, xperm: Pte.Flags) error{OutOfMemory}!usize {
        var flags = xperm;
        flags.readable = true;
        flags.user = true;

        const newsz = oldsz + increase;
        var addr = pageRoundUp(oldsz);
        while (addr < newsz) : (addr += PGSIZE) {
            const page = allocator.create(Page) catch |err| {
                _ = pagetable.dealloc(addr, addr - oldsz);
                return err;
            };
            @memset(page, 0);
            const phy_addr: usize = @intFromPtr(page);
            pagetable.mappages(@bitCast(addr), PGSIZE, @bitCast(phy_addr), flags);
        }
        return newsz;
    }

    /// Deallocate user pages to shrink process size from oldsz by decrease. oldsz and
    /// newsz need not be page-aligned. oldsz can be larger than the actual process size.
    /// Returns the new process size.
    pub fn dealloc(pagetable: PageTable, oldsz: usize, decrease: usize) usize {
        const newsz = oldsz - decrease;

        const old = pageRoundUp(oldsz);
        const new = pageRoundUp(newsz);
        if (new < old) {
            const npages = (old - new) / PGSIZE;
            pagetable.unmap(@bitCast(new), npages, true);
        }

        return newsz;
    }

    /// Recursively free page-table pages. All leaf mappings must already have been removed.
    fn freewalk(pagetable: PageTable) void {
        // there are 2^9 = 512 PTEs in a page table.
        for (pagetable.ptes.?) |*pte| {
            if (!pte.flags.valid) continue;
            if (pte.flags.readable or pte.flags.writable or pte.flags.executable) {
                @panic("freewalk: leaf");
            }

            const child = pte.getPageTable();
            child.freewalk();
            pte.* = .{};
        }

        pagetable.destroy();
    }

    /// Free user memory pages, then free page-table pages.
    pub fn free(pagetable: PageTable, size: usize) void {
        if (size > 0) pagetable.unmap(@bitCast(zero), pageRoundUp(size) / PGSIZE, true);
        freewalk(pagetable);
    }

    /// Given a parent process's page table, copy its memory into a child's page table.
    /// Copies both the page table and the physical memory.
    pub fn copy(old: PageTable, new: PageTable, size: usize) !void {
        var i: usize = 0;
        while (i < size) : (i += PGSIZE) {
            const pte = walk(old, @bitCast(i), false) catch unreachable;
            if (!pte.flags.valid) @panic("uvmcopy: page not present");

            const source: *Page = @ptrFromInt(pte.getPhyAddr());
            const page = try allocator.create(Page);
            @memcpy(page, source);

            const addr: usize = @intFromPtr(page);
            new.mappages(@bitCast(i), PGSIZE, @bitCast(addr), pte.flags);
        }
    }

    /// mark a PTE invalid for user access. used by exec for the user stack guard page.
    pub fn clear(pagetable: PageTable, vir: VirAddr) void {
        const pte = pagetable.walk(vir, false) catch unreachable;
        pte.flags.user = false;
    }

    /// Copy from kernel to user. Copy length bytes from source to virtual address dest
    /// in a given page table.
    pub fn copyout(pagetable: PageTable, dest: VirAddr, source: [*]const u8, length: usize) !void {
        var n: usize = 0;
        var vir_addr: usize = @bitCast(dest);

        while (n < length) {
            const phy_addr = try pagetable.walkaddr(@bitCast(vir_addr));
            const ptr: [*]u8 = phy_addr.toPtr();

            const addr = pageRoundDown(vir_addr);
            const nbytes = @min(PGSIZE - (vir_addr - addr), length - n);
            @memcpy(ptr[0..nbytes], source[n .. n + nbytes]);

            n += nbytes;
            vir_addr = addr + PGSIZE;
        }
    }

    fn ccopyout(pagetable: PageTable, dest: VirAddr, source: [*]const u8, length: usize) callconv(.C) c_int {
        copyout(pagetable, dest, source, length) catch return -1;
        return 0;
    }

    /// Copy from user to kernel. Copy length bytes to dest from virtual address source
    /// in a given page table.
    pub fn copyin(pagetable: PageTable, dest: [*]u8, source: VirAddr, length: usize) !void {
        var n: usize = 0;
        var vir_addr: usize = @bitCast(source);

        while (n < length) {
            const phy_addr = try pagetable.walkaddr(@bitCast(vir_addr));
            const ptr: [*]u8 = phy_addr.toPtr();

            const addr = pageRoundDown(vir_addr);
            const nbytes = @min(PGSIZE - (vir_addr - addr), length - n);
            @memcpy(dest[n .. n + nbytes], ptr[0..nbytes]);

            n += nbytes;
            vir_addr = addr + PGSIZE;
        }
    }

    fn ccopyin(pagetable: PageTable, dest: [*]u8, source: VirAddr, length: usize) callconv(.C) c_int {
        copyin(pagetable, dest, source, length) catch return -1;
        return 0;
    }

    /// Copy a null-terminated string from user to kernel. Copy bytes to dest from virtual
    /// address source in a given page table, until a '\0', or return an error if the end
    /// is reached.
    pub fn copyinstr(pagetable: PageTable, dest: []u8, source: VirAddr) ![:0]const u8 {
        var n: usize = 0;
        var vir_addr: usize = @bitCast(source);
        var got_null: bool = false;

        while (n < dest.len) {
            const addr = pageRoundDown(vir_addr);
            var nbytes = @min(PGSIZE - (vir_addr - addr), dest.len - n);

            const phy_addr = try pagetable.walkaddr(@bitCast(vir_addr));
            const ptr: [*]u8 = phy_addr.toPtr();
            const data = ptr[0..nbytes];

            nbytes = blk: {
                const index_of_zero = mem.indexOfScalar(u8, data, 0);
                if (index_of_zero) |i| {
                    got_null = true;
                    break :blk i + 1;
                } else {
                    break :blk data.len;
                }
            };

            @memcpy(dest[n .. n + nbytes], data[0..nbytes]);
            n += nbytes;
            if (got_null) return dest[0 .. n - 1 :0];

            vir_addr = addr + PGSIZE;
        } else {
            return error.InvalidString;
        }
    }

    /// Free a process's page table, and free the physical memory it refers to.
    pub fn freepagetable(pagetable: PageTable, size: usize) void {
        pagetable.unmap(@bitCast(TRAMPOLINE), 1, false);
        pagetable.unmap(@bitCast(TRAPFRAME), 1, false);
        pagetable.free(size);
    }
};

pub fn init() void {
    const etext_addr = @intFromPtr(&etext);
    const trampoline_addr = @intFromPtr(&trampoline);

    kernel_pagetable = PageTable.create() catch unreachable;

    // virt test
    kvmmap(xv6.VIRT_TEST, 0x1000, .{ .readable = true, .writable = true });

    // uart registers
    kvmmap(xv6.UART0, PGSIZE, .{ .readable = true, .writable = true });

    // virtio mmio disk interface
    kvmmap(xv6.VIRTIO0, PGSIZE, .{ .readable = true, .writable = true });

    // PLIC
    kvmmap(xv6.PLIC, 0x400000, .{ .readable = true, .writable = true });

    // map kernel text executable and read-only.
    kvmmap(KERNBASE, etext_addr - KERNBASE, .{ .readable = true, .executable = true });

    // map kernel data and the physical RAM we'll make use of.
    kvmmap(etext_addr, PHYSTOP - etext_addr, .{ .readable = true, .writable = true });

    // map the trampoline for trap entry/exit to
    // the highest virtual address in the kernel.
    kernel_pagetable.mappages(@bitCast(TRAMPOLINE), PGSIZE, @bitCast(trampoline_addr), .{ .readable = true, .executable = true });

    // Allocate a page for each process's kernel stack.
    // Map it high in memory, followed by an invalid
    // guard page.
    for (1..xv6.NPROC) |i| {
        const pages = allocator.create([KSTACK_NUM * PGSIZE]u8) catch unreachable;
        @memset(pages, 0);
        const addr: usize = @intFromPtr(pages);
        const phy_addr: PhyAddr = @bitCast(addr);

        kernel_pagetable.mappages(
            @bitCast(TRAMPOLINE - (i * (KSTACK_NUM + 1) * PGSIZE)),
            KSTACK_NUM * PGSIZE,
            phy_addr,
            .{ .readable = true, .writable = true },
        );
    }
}

// flush the TLB.
inline fn sfence_vma() void {
    // the zero, zero means flush all TLB entries.
    asm volatile ("sfence.vma zero, zero");
}

/// Switch h/w page table register to the kernel's page table, and enable paging.
pub fn inithart() void {
    // wait for any previous writes to the page table memory to finish.
    sfence_vma();

    csr.satp.set(.{
        .mode = .sv39,
        .ppn = kernel_pagetable.addr.ppn,
    });

    // flush stale entries from the TLB.
    sfence_vma();
}

/// add a direct-mapping to the kernel page table. only used when booting.
/// does not flush TLB or enable paging.
pub fn kvmmap(addr: usize, size: usize, perm: Pte.Flags) void {
    kernel_pagetable.mappages(@bitCast(addr), size, @bitCast(addr), perm);
}

fn pageRoundUp(addr: usize) usize {
    return mem.alignForward(usize, addr, PGSIZE);
}

fn pageRoundDown(addr: usize) usize {
    return mem.alignBackward(usize, addr, PGSIZE);
}
