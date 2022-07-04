const std = @import("std");
const c = @cImport({
    @cInclude("kernel/param.h");
});

extern var stack0: [c.NCPU * 4096]u8 align(16);
extern fn start() void;

export fn _entry() linksection(".kernel_entry") callconv(.Naked) noreturn {
    asm volatile (
        \\  # set up a stack
        \\  # sp = stack0 + (hartid * 4096)
        \\      la sp, stack0
        \\      li a0, 1024*4
        \\	csrr a1, mhartid
        \\      addi a1, a1, 1
        \\      mul a0, a0, a1
        \\      add sp, sp, a0
        \\  # jump to start()
        \\      call start
        \\spin:
        \\      j spin
    );

    unreachable;
}
