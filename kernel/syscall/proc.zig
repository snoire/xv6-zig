const c = @import("../c.zig");
const syscall = @import("../syscall.zig");
const proc = @import("../proc.zig");
const Proc = proc.Proc;
const trap = @import("../trap.zig");

pub fn exit() callconv(.C) isize {
    proc.exit(@intCast(i32, syscall.arg(0)));
    return 0;
}

pub fn getpid() callconv(.C) isize {
    return Proc.myproc().?.pid;
}

pub fn fork() callconv(.C) isize {
    return proc.fork() catch |err| @panic(@errorName(err));
}

pub fn wait() callconv(.C) isize {
    var p: usize = syscall.argaddr(0);
    return proc.wait(p);
}

pub fn sbrk() callconv(.C) isize {
    var n = syscall.argint(0);
    var addr = Proc.myproc().?.sz;
    if (proc.growproc(@intCast(i32, n)) == -1) return -1;
    return @intCast(isize, addr);
}

pub fn sleep() callconv(.C) isize {
    var n = syscall.argint(0);
    trap.tickslock.acquire();
    defer trap.tickslock.release();

    var ticks0 = trap.ticks;

    while (trap.ticks - ticks0 < n) {
        if (Proc.myproc().?.isKilled()) return -1;
        proc.sleep(&trap.ticks, &trap.tickslock);
    }
    return 0;
}

pub fn kill() callconv(.C) isize {
    var pid = syscall.argint(0);
    return @intCast(isize, proc.kill(pid));
}

pub fn uptime() callconv(.C) isize {
    trap.tickslock.acquire();
    defer trap.tickslock.release();

    var xticks = trap.ticks;
    return xticks;
}
