const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const SpinLock = @import("SpinLock.zig");

pub const PGSIZE = 4096;
pub const Page = [PGSIZE]u8;

pub const TOTAL_BYTES = 128 * 1024 * 1024;
pub const KERNBASE = 0x80000000;
pub const PHYSTOP = KERNBASE + TOTAL_BYTES;

pub const vtable = Allocator.VTable{
    .alloc = alloc,
    .resize = Allocator.noResize,
    .free = free,
};

/// first address after kernel.
/// defined by kernel.ld.
extern const heap_start: u8;

/// a singly linked list of memory pages, each node
/// represents one or more contiguous memory pages
const Run = struct {
    /// next points to the next node in the linked list
    next: ?*align(PGSIZE) Run = null,
    /// len is the number of pages in this node
    len: usize,
};

var lock = SpinLock.init("PageAllocator");
var freelist: ?*align(PGSIZE) Run = null;

pub fn init() void {
    const heap_addr = @intFromPtr(&heap_start);
    const heap: [*]align(PGSIZE) Page = @ptrFromInt(heap_addr);
    const pages = heap[0 .. (PHYSTOP - heap_addr) / PGSIZE];

    freelist = @ptrCast(&pages[0]);
    freelist.?.* = .{ .len = pages.len };
}

fn alloc(_: *anyopaque, n: usize, log2_align: u8, ra: usize) ?[*]u8 {
    _ = ra;
    _ = log2_align;
    std.debug.assert(n > 0);

    if (n > std.math.maxInt(usize) - (PGSIZE - 1)) return null;
    const aligned_len = mem.alignForward(usize, n, PGSIZE);
    const npages = aligned_len / PGSIZE;

    lock.acquire();
    defer lock.release();

    // ?previous -> target -> ?next
    var previous: ?*align(PGSIZE) Run = null;

    // target points to a node with enough pages
    const target = blk: {
        var it = freelist;
        break :blk while (it) |node| : (it = node.next) {
            if (node.len >= npages) break node;
            previous = node;
        } else return null;
    };

    // if target is exact size, remove it from freelist
    if (target.len == npages) {
        if (previous) |prev| {
            prev.next = target.next;
        } else {
            freelist = target.next;
        }
    } else { // otherwise split target into two nodes
        const rest: *align(PGSIZE) Run = blk: {
            const addr: [*]align(PGSIZE) Page = @ptrCast(target);
            break :blk @ptrCast(&addr[npages]);
        };
        rest.* = .{
            .next = target.next,
            .len = target.len - npages,
        };

        if (previous) |prev| {
            prev.next = rest;
        } else {
            freelist = rest;
        }
    }

    return @ptrCast(target);
}

fn free(_: *anyopaque, slice: []u8, log2_buf_align: u8, return_address: usize) void {
    _ = log2_buf_align;
    _ = return_address;

    const addr = @intFromPtr(slice.ptr);
    const buf_aligned_len = mem.alignForward(usize, slice.len, PGSIZE);
    const npages = buf_aligned_len / PGSIZE;

    lock.acquire();
    defer lock.release();

    // ?previous -> target -> ?next
    var target: *align(PGSIZE) Run = @ptrFromInt(addr);
    target.len = npages;
    var next: ?*align(PGSIZE) Run = undefined;

    // insert target into freelist
    if (freelist == null or addr < @intFromPtr(freelist.?)) {
        // insert at head
        next = freelist;
        freelist = target;
    } else {
        // find insert position
        var it = freelist;
        var previous: *align(PGSIZE) Run = while (true) {
            if (it.?.next) |n| {
                if (@intFromPtr(n) > addr) break it.?;
                it = n;
            } else {
                break it.?;
            }
        } else unreachable;

        next = previous.next;

        // try merging with previous
        if (@intFromPtr(previous) + previous.len * PGSIZE == @intFromPtr(target)) {
            previous.len += target.len;
            target = previous;
        } else {
            previous.next = target;
        }
    }

    // try merging with next
    if (next != null and @intFromPtr(target) + target.len * PGSIZE == @intFromPtr(next.?)) {
        target.len += next.?.len;
        target.next = next.?.next;
    } else {
        target.next = next;
    }
}
