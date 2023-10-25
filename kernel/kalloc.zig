//! Physical memory allocator, for user processes,
//! kernel stacks, page-table pages,
//! and pipe buffers. Allocates whole 4096-byte pages.

const std = @import("std");
const c = @import("c.zig");
const SpinLock = @import("SpinLock.zig");
const PageAllocator = @import("PageAllocator.zig");
const allocator = std.heap.page_allocator;

pub const PGSIZE = 4096;
pub const Page = [PGSIZE]u8;

pub const TOTAL_BYTES = 128 * 1024 * 1024;
pub const KERNBASE = 0x80000000;
pub const PHYSTOP = KERNBASE + TOTAL_BYTES;

pub fn init() void {
    PageAllocator.init();
}

/// Allocate one 4096-byte page of physical memory.
/// Returns a pointer that the kernel can use.
/// Panic if the memory cannot be allocated.
export fn kalloc() *align(PGSIZE) Page {
    const page = allocator.create(Page) catch |err| @panic(@errorName(err));

    // clear the page
    @memset(page, 0);

    return @alignCast(page);
}

/// Free the page of physical memory pointed at by `page`,
/// which normally should have been returned by a
/// call to kalloc().  (The exception is when
/// initializing the allocator; see kinit above.)
export fn kfree(page: *align(PGSIZE) Page) void {
    // Fill with junk to catch dangling refs.
    @memset(page, 1);

    allocator.destroy(page);
}
