const std = @import("std");
const c = @import("c.zig");

const PGSIZE = 4096;
const KERNBASE = 0x80000000;
const PHYSTOP = KERNBASE + 128 * 1024 * 1024;

/// first address after kernel.
/// defined by kernel.ld.
extern const end: u1; // do not use u0..

const Run = extern struct {
    next: ?*align(PGSIZE) Run,
};

extern var kmem: extern struct {
    lock: c.SpinLock,
    freelist: ?*align(PGSIZE) Run,
};

/// Allocate one 4096-byte page of physical memory.
/// Returns a pointer that the kernel can use.
/// Returns null if the memory cannot be allocated.
export fn kalloc() ?*align(PGSIZE) [PGSIZE]u8 {
    var run: *align(PGSIZE) [PGSIZE]u8 = blk: {
        c.acquire(&kmem.lock);
        defer c.release(&kmem.lock);

        if (kmem.freelist) |r| {
            kmem.freelist = r.next;
            break :blk @ptrCast(*align(PGSIZE) [PGSIZE]u8, r);
        } else {
            return null;
        }
    };

    // fill with junk
    std.mem.set(u8, run, 5);
    return run;
}

/// Free the page of physical memory pointed at by pa,
/// which normally should have been returned by a
/// call to kalloc().  (The exception is when
/// initializing the allocator; see kinit above.)
export fn kfree(pa: *align(PGSIZE) [PGSIZE]u8) void {
    const addr = @ptrToInt(pa);
    if (addr < @ptrToInt(&end) or addr >= PHYSTOP) @panic("kfree");

    // Fill with junk to catch dangling refs.
    std.mem.set(u8, pa, 1);

    c.acquire(&kmem.lock);
    defer c.release(&kmem.lock);

    var r = @ptrCast(*align(PGSIZE) Run, pa);
    r.next = kmem.freelist;
    kmem.freelist = r;
}
