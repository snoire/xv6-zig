const c = @import("../c.zig");
const syscall = @import("../syscall.zig");
const proc = @import("../proc.zig");

pub fn exit() callconv(.C) usize {
    proc.exit(@intCast(i32, syscall.arg(0)));
    return 0;
}

pub fn getpid() callconv(.C) usize {
    return proc.myproc().?.pid;
}

pub fn fork() callconv(.C) usize {
    return proc.fork();
}

pub fn wait() callconv(.C) usize {
    var p: usize = syscall.argaddr(0);
    return proc.wait(p);
}

pub fn sbrk() callconv(.C) usize {
    var n = syscall.argint(0);
    var addr = proc.myproc().?.sz;
    if (proc.growproc(@intCast(i32, n)) == -1) return @truncate(usize, -1);
    return addr;
}

// trap.c
extern var ticks: u32;
extern var tickslock: c.SpinLock;

pub fn sleep() callconv(.C) usize {
    var n = syscall.argint(0);
    c.acquire(&tickslock);
    defer c.release(&tickslock);

    var ticks0 = ticks;

    while (ticks - ticks0 < n) {
        if (proc.killed(proc.myproc().?) != 0) return @truncate(usize, -1);
        proc.sleep(&ticks, &tickslock);
    }
    return 0;
}

pub fn kill() callconv(.C) usize {
    var pid = syscall.argint(0);
    return @intCast(usize, proc.kill(pid));
}

pub fn uptime() callconv(.C) usize {
    c.acquire(&tickslock);
    defer c.release(&tickslock);

    var xticks = ticks;
    return xticks;
}
