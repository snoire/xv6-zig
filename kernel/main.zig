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

        print(
            \\
            \\xv6 kernel is booting
            \\
            \\
        , .{});

        kernel.kalloc.init(); // physical page allocator
        kernel.vm.init(); // create kernel page table
        kernel.vm.inithart(); // turn on paging
        c.procinit(); // process table
        c.trapinit(); // trap vectors
        c.trapinithart(); // install kernel trap vector
        c.plicinit(); // set up interrupt controller
        c.plicinithart(); // ask PLIC for device interrupts
        c.binit(); // buffer cache
        c.iinit(); // inode table
        c.fileinit(); // file table
        c.virtio_disk_init(); // emulated hard disk
        kernel.proc.userinit();

        started.store(true, .Release);
    } else {
        while (!started.load(.Acquire)) {}

        print("hart {} starting\n", .{id});
        kernel.vm.inithart(); // turn on paging
        c.trapinithart(); // install kernel trap vector
        c.plicinithart(); // ask PLIC for device interrupts
    }

    c.scheduler();
}
