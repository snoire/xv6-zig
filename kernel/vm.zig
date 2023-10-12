const std = @import("std");
const xv6 = @import("xv6.zig");
const csr = xv6.register.csr;
const assert = std.debug.assert;
const proc = @import("proc.zig");
const alignBackward = std.mem.alignBackward;
const allocator = std.heap.page_allocator;

pub const PGSIZE = 4096;
pub const Page = [PGSIZE]u8;
pub const TRAMPOLINE = VirAddr.MAXVA - PGSIZE;
pub const TRAPFRAME = TRAMPOLINE - PGSIZE;

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

pub const Address = packed union {
    vir_addr: VirAddr,
    phy_addr: PhyAddr,
};

/// virtual address
pub const VirAddr = packed union {
    vir: Virtual,

    // converts to other types
    addr: usize,

    const Virtual = packed struct {
        offset: u12 = 0,
        l0: u9 = 0,
        l1: u9 = 0,
        l2: u9 = 0,

        _: u25 = 0,
    };

    // one beyond the highest possible virtual address.
    // MAXVA is actually one bit less than the max allowed by
    // Sv39, to avoid having to sign-extend virtual addresses
    // that have the high bit set.
    const MAXVA = 1 << (9 + 9 + 9 + 12 - 1);

    comptime {
        // Address must be 64bit.
        assert(@bitSizeOf(@This()) == 64);

        // And every field of it must be 64bit too.
        for (std.meta.fields(@This())) |field| {
            assert(@bitSizeOf(field.type) == 64);
        }
    }

    const Self = @This();

    fn roundDown(self: Self) Self {
        return .{ .addr = alignBackward(usize, self.addr, PGSIZE) };
    }
};

/// physical address
pub const PhyAddr = packed union {
    phy: Physical,

    // converts to other types
    addr: usize,
    page: *align(PGSIZE) Page,
    buffer: [*]u8,

    const Physical = packed struct {
        offset: u12 = 0,
        ppn: u44 = 0,

        _: u8 = 0,
    };

    comptime {
        // Address must be 64bit.
        assert(@bitSizeOf(@This()) == 64);

        // And every field of it must be 64bit too.
        for (std.meta.fields(@This())) |field| {
            assert(@bitSizeOf(field.type) == 64);
        }
    }

    const Self = @This();

    // TODO: maybe we don't need it
    pub fn create() !Self {
        const page = try allocator.create(Page);
        @memset(page, 0);

        return .{
            .page = @alignCast(page),
        };
    }
};

pub const PageTable = packed union {
    ptes: ?*[512]Pte,

    // converts to other types
    page: *align(PGSIZE) Page,
    phy: PhyAddr.Physical,

    const Self = @This();

    pub fn create() !Self {
        const page = try allocator.create(Page);
        @memset(page, 0);

        return .{
            .page = @alignCast(page),
        };
    }

    /// Return the address of the PTE in page table pagetable
    /// that corresponds to virtual address va. If alloc==true,
    /// create any required page-table pages.
    fn walk(pagetable: PageTable, va: VirAddr, comptime is_alloc: bool) !*Pte {
        if (va.addr >= VirAddr.MAXVA) @panic("walk");

        var pt = pagetable;
        const indices: [2]u9 = .{ va.vir.l2, va.vir.l1 };

        for (indices) |index| {
            var pte = &pt.ptes.?[index];

            if (pte.flags.valid) {
                pt = pte.getPageTable();
            } else {
                if (!is_alloc) return error.NotFound;
                pt = try PageTable.create();
                pte.ppn = pt.phy.ppn;
                pte.flags.valid = true;
            }
        }

        return &pt.ptes.?[va.vir.l0];
    }

    // Look up a virtual address, return the physical address,
    // or 0 if not mapped.
    // Can only be used to look up user pages.
    fn cwalkaddr(pagetable: PageTable, va: VirAddr) callconv(.C) usize {
        const phy_addr = pagetable.walkaddr(va) catch return 0;
        return phy_addr.addr - va.vir.offset;
    }

    comptime {
        @export(cwalkaddr, .{ .name = "walkaddr", .linkage = .Strong });
    }

    /// Look up a virtual address, return the physical address,
    /// or error.NotMapped if not mapped.
    /// Can only be used to look up user pages.
    pub fn walkaddr(pagetable: PageTable, va: VirAddr) !PhyAddr {
        if (va.addr >= VirAddr.MAXVA) return error.NotMapped;

        var pte = pagetable.walk(va, false) catch return error.NotMapped;
        if (!pte.flags.valid or !pte.flags.user) return error.NotMapped;

        return PhyAddr{
            .phy = .{
                .ppn = pte.ppn,
                .offset = va.vir.offset,
            },
        };
    }

    /// Create PTEs for virtual addresses starting at va that refer to
    /// physical addresses starting at pa. va and size might not
    /// be page-aligned. Returns 0 on success, or panic if walk() couldn't
    /// allocate a needed page-table page.
    pub fn mappages(pagetable: PageTable, vaddress: VirAddr, size: usize, paddress: PhyAddr, perm: Pte.Flags) void {
        if (size == 0) @panic("mappages: size");

        var pa = paddress;
        var va = vaddress.roundDown();
        const last = alignBackward(usize, vaddress.addr + size - 1, PGSIZE);

        while (true) {
            var pte = pagetable.walk(va, true) catch unreachable;
            if (pte.flags.valid) @panic("mappages: remap");

            pte.ppn = pa.phy.ppn;
            pte.flags = perm;
            pte.flags.valid = true;

            if (va.addr == last) break;
            va.addr += PGSIZE;
            pa.addr += PGSIZE;
        }
    }

    /// Remove npages of mappings starting from va. va must be
    /// page-aligned. The mappings must exist.
    /// Optionally free the physical memory.
    pub fn unmap(pagetable: PageTable, va: VirAddr, npages: usize, do_free: bool) void {
        if (!std.mem.isAligned(va.addr, PGSIZE)) @panic("uvmunmap: not aligned");

        var addr = va;
        while (addr.addr < va.addr + npages * PGSIZE) : (addr.addr += PGSIZE) {
            var pte = pagetable.walk(addr, false) catch unreachable;
            if (!pte.flags.valid) @panic("uvmunmap: not mapped");
            if (@as(u8, @bitCast(pte.flags)) == @as(u8, @bitCast(Pte.Flags{ .valid = true }))) {
                @panic("uvmunmap: not a leaf");
            }
            if (do_free) {
                allocator.destroy(pte.getPhy().page);
            }
            pte.* = .{};
        }
    }

    /// Load the user initcode into address 0 of pagetable,
    /// for the very first process.
    /// sz must be less than a page.
    pub fn first(pagetable: PageTable, src: []const u8) void {
        if (src.len >= PGSIZE) @panic("uvmfirst: more than a page");

        var mem = PhyAddr.create() catch unreachable;
        pagetable.mappages(.{ .addr = 0 }, PGSIZE, mem, .{
            .writable = true,
            .readable = true,
            .executable = true,
            .user = true,
        });

        std.mem.copy(u8, mem.page, src);
    }

    /// Allocate PTEs and physical memory to grow process from oldsz to newsz,
    /// which need not be page aligned.  Returns new size or 0 on error.
    pub fn alloc(pagetable: PageTable, oldsz: usize, newsz: usize, xperm: Pte.Flags) error{OutOfMemory}!usize {
        if (newsz < oldsz) return oldsz;

        var flags = xperm;
        flags.readable = true;
        flags.user = true;

        var addr = std.mem.alignForward(usize, oldsz, PGSIZE);
        while (addr < newsz) : (addr += PGSIZE) {
            var mem = PhyAddr.create() catch |err| {
                _ = pagetable.dealloc(addr, oldsz);
                return err;
            };
            pagetable.mappages(.{ .addr = addr }, PGSIZE, mem, flags);
        }
        return newsz;
    }

    /// Deallocate user pages to bring the process size from oldsz to
    /// newsz.  oldsz and newsz need not be page-aligned, nor does newsz
    /// need to be less than oldsz.  oldsz can be larger than the actual
    /// process size.  Returns the new process size.
    pub fn dealloc(pagetable: PageTable, oldsz: usize, newsz: usize) usize {
        if (newsz >= oldsz) return oldsz;

        var old = std.mem.alignForward(usize, oldsz, PGSIZE);
        var new = std.mem.alignForward(usize, newsz, PGSIZE);
        if (new < old) {
            var npages = (old - new) / PGSIZE;
            pagetable.unmap(.{ .addr = newsz }, npages, true);
        }

        return newsz;
    }

    /// Recursively free page-table pages.
    /// All leaf mappings must already have been removed.
    fn freewalk(pagetable: PageTable) void {
        // there are 2^9 = 512 PTEs in a page table.
        for (pagetable.ptes.?) |*pte| {
            if (!pte.flags.valid) continue;
            if (pte.flags.readable or pte.flags.writable or pte.flags.executable) {
                @panic("freewalk: leaf");
            }

            var child = pte.getPageTable();
            child.freewalk();
            pte.* = .{};
        }

        allocator.destroy(pagetable.page);
    }

    /// Free user memory pages,
    /// then free page-table pages.
    pub fn free(pagetable: PageTable, sz: usize) void {
        std.debug.assert(sz != 0);
        pagetable.unmap(.{ .addr = 0 }, std.mem.alignForward(usize, sz, PGSIZE) / PGSIZE, true);
        freewalk(pagetable);
    }

    /// Given a parent process's page table, copy
    /// its memory into a child's page table.
    /// Copies both the page table and the
    /// physical memory.
    pub fn copy(old_pagetable: PageTable, new_pagetable: PageTable, sz: usize) !void {
        var i: usize = 0;
        while (i < sz) : (i += PGSIZE) {
            var pte = walk(old_pagetable, .{ .addr = i }, false) catch unreachable;
            if (!pte.flags.valid) @panic("uvmcopy: page not present");

            var pa = pte.getPhy();
            var mem = try PhyAddr.create();

            std.mem.copy(u8, mem.page, pa.page);
            mappages(new_pagetable, .{ .addr = i }, PGSIZE, mem, pte.flags);
        }
    }

    /// mark a PTE invalid for user access.
    /// used by exec for the user stack guard page.
    pub fn clear(pagetable: PageTable, va: VirAddr) void {
        var pte = pagetable.walk(va, false) catch unreachable;
        pte.flags.user = false;
    }

    /// Copy from kernel to user.
    /// Copy len bytes from src to virtual address dstva in a given page table.
    /// Return 0 on success, -1 on error.
    pub export fn copyout(pagetable: PageTable, dstva: VirAddr, source: [*]const u8, length: usize) c_int {
        var n: usize = 0;
        var dst = dstva;

        while (n < length) {
            var pa = pagetable.walkaddr(dst) catch return -1;
            var nbytes = @min(PGSIZE - (dst.addr - dst.roundDown().addr), length - n);
            std.mem.copy(u8, pa.buffer[0..nbytes], source[n .. n + nbytes]);

            n += nbytes;
            dst.addr = dst.roundDown().addr + PGSIZE;
        }

        return 0;
    }

    /// Copy from user to kernel.
    /// Copy len bytes to dst from virtual address srcva in a given page table.
    /// Return 0 on success, -1 on error.
    pub export fn copyin(pagetable: PageTable, dst: [*]u8, srcva: VirAddr, length: usize) c_int {
        var n: usize = 0;
        var src = srcva;

        while (n < length) {
            var pa = pagetable.walkaddr(src) catch return -1;
            var nbytes = @min(PGSIZE - (src.addr - src.roundDown().addr), length - n);
            std.mem.copy(u8, dst[n .. n + nbytes], pa.buffer[0..nbytes]);

            n += nbytes;
            src.addr = src.roundDown().addr + PGSIZE;
        }

        return 0;
    }

    /// Copy a null-terminated string from user to kernel.
    /// Copy bytes to dst from virtual address srcva in a given page table,
    /// until a '\0', or return an error if the end is reached.
    pub fn copyinstr(pagetable: PageTable, dst: []u8, srcva: VirAddr) ![:0]const u8 {
        var n: usize = 0;
        var src = srcva;
        var got_null: bool = false;

        while (n < dst.len) {
            var pa = try pagetable.walkaddr(src);
            var nbytes = @min(PGSIZE - (src.addr - src.roundDown().addr), dst.len - n);
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
            n += nbytes;
            if (got_null) return dst[0 .. n - 1 :0];

            src.addr = src.roundDown().addr + PGSIZE;
        } else {
            return error.InvalidString;
        }
    }

    /// Free a process's page table, and free the
    /// physical memory it refers to.
    pub fn freepagetable(pagetable: PageTable, sz: usize) void {
        pagetable.unmap(.{ .addr = TRAMPOLINE }, 1, false);
        pagetable.unmap(.{ .addr = TRAPFRAME }, 1, false);
        pagetable.free(sz);
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
    };

    comptime {
        assert(@bitSizeOf(@This()) == 64);
    }

    fn getPhy(self: @This()) PhyAddr {
        return PhyAddr{
            .phy = .{ .ppn = self.ppn },
        };
    }

    fn getPageTable(self: @This()) PageTable {
        return @bitCast(PhyAddr{
            .phy = .{ .ppn = self.ppn },
        });
    }
};

pub fn init() void {
    const etext_addr = @intFromPtr(&etext);
    const trampoline_addr = @intFromPtr(&trampoline);

    kernel_pagetable = PageTable.create() catch unreachable;

    // virt test
    kvmmap(xv6.VIRT_TEST, 0x1000, .{
        .readable = true,
        .writable = true,
    });

    // uart registers
    kvmmap(xv6.UART0, PGSIZE, .{
        .readable = true,
        .writable = true,
    });

    // virtio mmio disk interface
    kvmmap(xv6.VIRTIO0, PGSIZE, .{
        .readable = true,
        .writable = true,
    });

    // PLIC
    kvmmap(xv6.PLIC, 0x400000, .{
        .readable = true,
        .writable = true,
    });

    // map kernel text executable and read-only.
    kvmmap(KERNBASE, etext_addr - KERNBASE, .{
        .readable = true,
        .executable = true,
    });

    // map kernel data and the physical RAM we'll make use of.
    kvmmap(etext_addr, PHYSTOP - etext_addr, .{
        .readable = true,
        .writable = true,
    });

    // map the trampoline for trap entry/exit to
    // the highest virtual address in the kernel.
    kernel_pagetable.mappages(.{ .addr = TRAMPOLINE }, PGSIZE, .{ .addr = trampoline_addr }, .{
        .readable = true,
        .executable = true,
    });

    // Allocate a page for each process's kernel stack.
    // Map it high in memory, followed by an invalid
    // guard page.
    for (1..xv6.NPROC) |i| {
        const pages = allocator.create([KSTACK_NUM * PGSIZE]u8) catch unreachable;
        @memset(pages, 0);
        const phy_addr = PhyAddr{ .addr = @intFromPtr(pages) };

        kernel_pagetable.mappages(
            .{ .addr = TRAMPOLINE - (i * (KSTACK_NUM + 1) * PGSIZE) },
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

/// Switch h/w page table register to the kernel's page table,
/// and enable paging.
pub fn inithart() void {
    // wait for any previous writes to the page table memory to finish.
    sfence_vma();

    csr.satp.set(.{
        .mode = .sv39,
        .ppn = kernel_pagetable.phy.ppn,
    });

    // flush stale entries from the TLB.
    sfence_vma();
}

/// add a direct-mapping to the kernel page table.
/// only used when booting.
/// does not flush TLB or enable paging.
pub fn kvmmap(addr: usize, size: usize, perm: Pte.Flags) void {
    kernel_pagetable.mappages(.{ .addr = addr }, size, .{ .addr = addr }, perm);
}
