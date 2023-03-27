const c = @import("../c.zig");
const syscall = @import("../syscall.zig");
const proc = @import("../proc.zig");

pub fn exit() callconv(.C) isize {
    proc.exit(@intCast(i32, syscall.arg(0)));
    return 0;
}

pub fn getpid() callconv(.C) isize {
    return proc.myproc().?.pid;
}

pub fn fork() callconv(.C) isize {
    return proc.fork();
}

pub fn wait() callconv(.C) isize {
    var p: usize = syscall.argaddr(0);
    return proc.wait(p);
}

pub fn sbrk() callconv(.C) isize {
    var n = syscall.argint(0);
    var addr = proc.myproc().?.sz;
    if (proc.growproc(@intCast(i32, n)) == -1) return -1;
    return @intCast(isize, addr);
}

// trap.c
extern var ticks: u32;
extern var tickslock: c.SpinLock;

pub fn sleep() callconv(.C) isize {
    var n = syscall.argint(0);
    tickslock.acquire();
    defer tickslock.release();

    var ticks0 = ticks;

    while (ticks - ticks0 < n) {
        if (proc.killed(proc.myproc().?) != 0) return -1;
        proc.sleep(&ticks, &tickslock);
    }
    return 0;
}

pub fn kill() callconv(.C) isize {
    var pid = syscall.argint(0);
    return @intCast(isize, proc.kill(pid));
}

pub fn uptime() callconv(.C) isize {
    tickslock.acquire();
    defer tickslock.release();

    var xticks = ticks;
    return xticks;
}
