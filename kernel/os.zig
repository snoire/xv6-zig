const std = @import("std");
const PageAllocator = @import("PageAllocator.zig");

pub const panic = @import("print.zig").panicFn;
pub const system = struct {};

pub const heap = struct {
    // define std.heap.page_allocator
    pub const page_allocator = std.mem.Allocator{
        .ptr = undefined,
        .vtable = &PageAllocator.vtable,
    };
};
