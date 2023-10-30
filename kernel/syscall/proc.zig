const c = @import("../c.zig");
const syscall = @import("../syscall.zig");
const proc = @import("../proc.zig");
const Proc = proc.Proc;
const trap = @import("../trap.zig");
const std = @import("std");

pub fn exit() isize {
    proc.exit(@intCast(syscall.arg(0)));
    return 0;
}

pub fn getpid() isize {
    return Proc.myproc().?.pid;
}

pub fn fork() !isize {
    return try proc.fork();
}

pub fn wait() !isize {
    const p: usize = syscall.argaddr(0);
    return proc.wait(p);
}

pub fn sbrk() usize {
    const n: isize = @bitCast(syscall.arg(0));
    const addr = Proc.myproc().?.sz;
    proc.growproc(n) catch return std.math.maxInt(usize);
    return addr;
}

pub fn sleep() !isize {
    const n = try syscall.argint(0);
    trap.tickslock.acquire();
    defer trap.tickslock.release();

    const ticks0 = trap.ticks;

    while (trap.ticks - ticks0 < n) {
        if (Proc.myproc().?.isKilled()) return -1;
        proc.sleep(&trap.ticks, &trap.tickslock);
    }
    return 0;
}

pub fn kill() !isize {
    const pid = try syscall.argint(0);
    return @intCast(proc.kill(pid));
}

pub fn uptime() isize {
    trap.tickslock.acquire();
    defer trap.tickslock.release();

    const xticks = trap.ticks;
    return xticks;
}
