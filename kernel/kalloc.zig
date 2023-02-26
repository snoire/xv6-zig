const std = @import("std");
const c = @import("c.zig");
const PGSIZE = 4096;

const Run = extern struct {
    next: *Run,
};

extern var kmem: extern struct {
    lock: c.SpinLock,
    freelist: ?*Run,
};

// Allocate one 4096-byte page of physical memory.
// Returns a pointer that the kernel can use.
// Returns null if the memory cannot be allocated.
export fn kalloc() ?*[PGSIZE]u8 {
    var run: *[PGSIZE]u8 = blk: {
        c.acquire(&kmem.lock);
        defer c.release(&kmem.lock);

        if (kmem.freelist) |r| {
            kmem.freelist = r.next;
            break :blk @ptrCast(*[PGSIZE]u8, r);
        } else {
            return null;
        }
    };

    // fill with junk
    std.mem.set(u8, run, 5);
    return run;
}
