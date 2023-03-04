//! Physical memory allocator, for user processes,
//! kernel stacks, page-table pages,
//! and pipe buffers. Allocates whole 4096-byte pages.

const std = @import("std");
const c = @import("c.zig");
const SpinLock = @import("SpinLock.zig");
pub const Page = *align(PGSIZE) [PGSIZE]u8;

const PGSIZE = 4096;
pub const KERNBASE = 0x80000000;
pub const PHYSTOP = KERNBASE + 128 * 1024 * 1024;

/// first address after kernel.
/// defined by kernel.ld.
extern const end: u1; // do not use u0..

const Run = extern struct {
    next: ?*align(PGSIZE) Run,
};

var lock: SpinLock = SpinLock.init("kmem");
var freelist: ?*align(PGSIZE) Run = null;

pub fn init() void {
    var addr = std.mem.alignForward(@ptrToInt(&end), PGSIZE);

    while (addr <= PHYSTOP - PGSIZE) : (addr += PGSIZE) {
        kfree(@intToPtr(Page, addr));
    }
}

/// Allocate one 4096-byte page of physical memory.
/// Returns a pointer that the kernel can use.
/// Returns null if the memory cannot be allocated.
pub export fn kalloc() ?Page {
    var page: Page = blk: {
        lock.acquire();
        defer lock.release();

        if (freelist) |r| {
            freelist = r.next;
            break :blk @ptrCast(Page, r);
        } else {
            return null;
        }
    };

    // clear the page
    std.mem.set(u8, page, 0);
    return page;
}

/// Free the page of physical memory pointed at by `page`,
/// which normally should have been returned by a
/// call to kalloc().  (The exception is when
/// initializing the allocator; see kinit above.)
pub export fn kfree(page: Page) void {
    const addr = @ptrToInt(page);
    if (addr < @ptrToInt(&end) or addr >= PHYSTOP) @panic("kfree");

    // Fill with junk to catch dangling refs.
    std.mem.set(u8, page, 1);

    lock.acquire();
    defer lock.release();

    var r = @ptrCast(*align(PGSIZE) Run, page);
    r.next = freelist;
    freelist = r;
}
