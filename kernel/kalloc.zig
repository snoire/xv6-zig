//! Physical memory allocator, for user processes,
//! kernel stacks, page-table pages,
//! and pipe buffers. Allocates whole 4096-byte pages.

const std = @import("std");
const c = @import("c.zig");
const SpinLock = @import("SpinLock.zig");
const Page = *align(PGSIZE) [PGSIZE]u8;

const PGSIZE = 4096;
const KERNBASE = 0x80000000;
const PHYSTOP = KERNBASE + 128 * 1024 * 1024;

/// first address after kernel.
/// defined by kernel.ld.
extern const end: u1; // do not use u0..

const Run = extern struct {
    next: ?*align(PGSIZE) Run,
};

var kmem: struct {
    lock: SpinLock = SpinLock.init("kmem"),
    freelist: ?*align(PGSIZE) Run = null,
} = .{};

pub fn init() void {
    var addr = std.mem.alignForward(@ptrToInt(&end), PGSIZE);

    while (addr <= PHYSTOP - PGSIZE) : (addr += PGSIZE) {
        kfree(@intToPtr(Page, addr));
    }
}

/// Allocate one 4096-byte page of physical memory.
/// Returns a pointer that the kernel can use.
/// Returns null if the memory cannot be allocated.
export fn kalloc() ?Page {
    var page: Page = blk: {
        kmem.lock.acquire();
        defer kmem.lock.release();

        if (kmem.freelist) |r| {
            kmem.freelist = r.next;
            break :blk @ptrCast(Page, r);
        } else {
            return null;
        }
    };

    // fill with junk
    std.mem.set(u8, page, 5);
    return page;
}

/// Free the page of physical memory pointed at by `page`,
/// which normally should have been returned by a
/// call to kalloc().  (The exception is when
/// initializing the allocator; see kinit above.)
export fn kfree(page: Page) void {
    const addr = @ptrToInt(page);
    if (addr < @ptrToInt(&end) or addr >= PHYSTOP) @panic("kfree");

    // Fill with junk to catch dangling refs.
    std.mem.set(u8, page, 1);

    kmem.lock.acquire();
    defer kmem.lock.release();

    var r = @ptrCast(*align(PGSIZE) Run, page);
    r.next = kmem.freelist;
    kmem.freelist = r;
}
