const std = @import("std");
const assert = std.debug.assert;
const maxInt = std.math.maxInt;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const SpinLock = @import("SpinLock.zig");

pub const PGSIZE = 4096;
pub const Page = [PGSIZE]u8;

pub const TOTAL_BYTES = 128 * 1024 * 1024;
pub const KERNBASE = 0x80000000;
pub const PHYSTOP = KERNBASE + TOTAL_BYTES;

pub const vtable = Allocator.VTable{
    .alloc = alloc,
    .resize = resize,
    .free = free,
};

/// first address after kernel.
/// defined by kernel.ld.
extern const heap_start: u8;

const Run = extern struct {
    next: ?*align(PGSIZE) Run,
};

var lock: SpinLock = SpinLock.init("PageAllocator");
var freelist: ?*align(PGSIZE) Run = null;

pub fn init() void {
    const heap_addr = @ptrToInt(&heap_start);
    const heap = @intToPtr([*]align(PGSIZE) Page, heap_addr);
    const pages = heap[0 .. (PHYSTOP - heap_addr) / PGSIZE];

    // the first page
    freelist = @ptrCast(*align(PGSIZE) Run, &pages[0]);

    var ptr = freelist;
    for (pages[1..]) |*page| {
        var r = @ptrCast(*align(PGSIZE) Run, page);
        ptr.?.next = r;
        ptr = r;
    }

    // the last page
    ptr.?.next = null;
}

/// previous -> [start ... end] -> next
/// allocate pages[start..end]
fn alloc(_: *anyopaque, n: usize, log2_align: u8, ra: usize) ?[*]u8 {
    _ = ra;
    _ = log2_align;
    assert(n > 0);

    if (n > maxInt(usize) - (PGSIZE - 1)) return null;
    const aligned_len = mem.alignForward(n, PGSIZE);
    const npages = aligned_len / PGSIZE;

    lock.acquire();
    defer lock.release();

    var start = freelist;
    var previous = freelist;
    var next: *align(PGSIZE) Run = undefined;

    // searches for n consecutive nodes that are physically adjacent in memory
    {
        var i: usize = 0;
        var prev = freelist;
        var ptr = freelist;

        while (i < npages) : (i += 1) {
            var p = ptr orelse return null;

            if (@ptrToInt(p) > @ptrToInt(start.?) + PGSIZE * i) {
                start = p;
                previous = prev;
                i = 0;
            }

            prev = p;
            ptr = p.next;
        }

        next = ptr.?;
    }

    if (start == freelist) { // `start` is the first page
        freelist = next;
    } else {
        previous.?.next = next;
    }

    return @ptrCast([*]u8, start.?);
}

/// unsupported
fn resize(
    _: *anyopaque,
    buf_unaligned: []u8,
    log2_buf_align: u8,
    new_size: usize,
    return_address: usize,
) bool {
    _ = return_address;
    _ = new_size;
    _ = log2_buf_align;
    _ = buf_unaligned;

    return false;
}

/// previous -> [start ... end] -> next
fn free(_: *anyopaque, slice: []u8, log2_buf_align: u8, return_address: usize) void {
    _ = log2_buf_align;
    _ = return_address;

    const addr = @ptrToInt(slice.ptr);
    const buf_aligned_len = mem.alignForward(slice.len, PGSIZE);
    const npages = buf_aligned_len / PGSIZE;

    lock.acquire();
    defer lock.release();

    // update linked list
    var next: ?*align(PGSIZE) Run = undefined;
    var start = @ptrCast(*align(PGSIZE) Run, @alignCast(PGSIZE, slice.ptr));

    if (freelist == null or addr < @ptrToInt(freelist.?)) {
        next = freelist orelse null;
        freelist = start;
    } else {
        var previous = blk: {
            var ptr = freelist;
            var prev = freelist;

            while (@ptrToInt(ptr.?) <= addr - PGSIZE) {
                prev = ptr;

                ptr = ptr.?.next;
                if (ptr == null) break;
            }

            break :blk prev.?;
        };

        next = previous.next;
        previous.next = start;
    }

    var ptr = start;
    for (1..npages) |i| {
        const r = @intToPtr(*align(PGSIZE) Run, addr + PGSIZE * i);
        ptr.next = r;
        ptr = r;
    }

    ptr.next = next;
}
