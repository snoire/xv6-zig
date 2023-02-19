const c = @cImport({
    @cInclude("types.h");
    @cInclude("param.h");
    @cInclude("memlayout.h");
    @cInclude("riscv.h");
    @cInclude("defs.h");
});
const std = @import("std");
const kernel = @import("xv6.zig");
const print = kernel.print.print;
var started = std.atomic.Atomic(bool).init(false);

pub fn main() callconv(.C) void {
    const id = c.cpuid();
    if (id == 0) {
        c.consoleinit();
        kernel.print.init();

        print(
            \\
            \\xv6 kernel is booting
            \\
            \\
        , .{});

        c.kinit(); // physical page allocator
        c.kvminit(); // create kernel page table
        c.kvminithart(); // turn on paging
        c.procinit(); // process table
        c.trapinit(); // trap vectors
        c.trapinithart(); // install kernel trap vector
        c.plicinit(); // set up interrupt controller
        c.plicinithart(); // ask PLIC for device interrupts
        c.binit(); // buffer cache
        c.iinit(); // inode table
        c.fileinit(); // file table
        c.virtio_disk_init(); // emulated hard disk
        c.userinit(); // first user process

        started.store(true, .SeqCst);
    } else {
        while (!started.load(.SeqCst)) {}

        print("hart {} starting\n", .{id});
        c.kvminithart(); // turn on paging
        c.trapinithart(); // install kernel trap vector
        c.plicinithart(); // ask PLIC for device interrupts
    }

    c.scheduler();
}
