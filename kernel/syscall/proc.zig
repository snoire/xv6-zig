const c = @import("../c.zig");
const syscall = @import("../syscall.zig");
const proc = @import("../proc.zig");
const Proc = proc.Proc;
const trap = @import("../trap.zig");

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

pub fn wait() isize {
    var p: usize = syscall.argaddr(0);
    return proc.wait(p);
}

pub fn sbrk() isize {
    var n = syscall.argint(0);
    var addr = Proc.myproc().?.sz;
    if (proc.growproc(@intCast(n)) == -1) return -1;
    return @intCast(addr);
}

pub fn sleep() isize {
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

pub fn kill() usize {
    var pid = syscall.argint(0);
    return @intCast(proc.kill(pid));
}

pub fn uptime() isize {
    trap.tickslock.acquire();
    defer trap.tickslock.release();

    var xticks = trap.ticks;
    return xticks;
}
