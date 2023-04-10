const std = @import("std");
const print = @import("xv6.zig").print;
const Proc = @import("proc.zig").Proc;

pub fn arg(n: u8) usize {
    var p: *Proc = Proc.myproc().?;

    return switch (n) {
        0 => p.trapframe.?.a0,
        1 => p.trapframe.?.a1,
        2 => p.trapframe.?.a2,
        3 => p.trapframe.?.a3,
        4 => p.trapframe.?.a4,
        5 => p.trapframe.?.a5,
        else => @panic("argraw"),
    };
}

/// Fetch the nth 32-bit system call argument.
pub fn argint(n: u8) u32 {
    return @intCast(u32, arg(n));
}

/// Retrieve an argument as a pointer.
/// Doesn't check for legality, since
/// copyin/copyout will do that.
pub fn argaddr(n: u8) usize {
    return arg(n);
}

pub const SYS = enum(u8) {
    fork = 1,
    exit = 2,
    wait = 3,
    pipe = 4,
    read = 5,
    kill = 6,
    exec = 7,
    fstat = 8,
    chdir = 9,
    dup = 10,
    getpid = 11,
    sbrk = 12,
    sleep = 13,
    uptime = 14,
    open = 15,
    write = 16,
    mknod = 17,
    unlink = 18,
    link = 19,
    mkdir = 20,
    close = 21,
};

const sys = struct {
    usingnamespace @import("syscall/proc.zig");
    usingnamespace @import("syscall/file.zig");
};

/// An array mapping syscall numbers from `SYS`
/// to the function that handles the system call.
const syscalls = blk: {
    const sys_fields = std.meta.fields(SYS);

    // Note that syscalls[0] doesn't contain any function pointer since syscall starts from 1.
    var sys_calls: [sys_fields.len + 1]*const fn () callconv(.C) isize = undefined;
    for (sys_fields) |call| {
        sys_calls[call.value] = @field(sys, call.name);
    }

    break :blk sys_calls;
};

export fn syscall() void {
    var p: *Proc = Proc.myproc().?;
    var num = p.trapframe.?.a7;

    if (num > 0 and num < syscalls.len) {
        // Use num to lookup the system call function for num, call it,
        // and store its return value in p.trapframe.a0
        p.trapframe.?.a0 = @bitCast(usize, syscalls[num]());
    } else {
        print("{} {s}: unknown sys call {}\n", .{ p.pid, &p.name, num });
        p.trapframe.?.a0 = std.math.maxInt(usize);
    }
}
