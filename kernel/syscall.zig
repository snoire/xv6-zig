const std = @import("std");
const kernel = @import("xv6.zig");
const Proc = kernel.proc.Proc;
const PageTable = kernel.proc.PageTable;

extern fn copyin(pagetable: PageTable, dst: [*:0]u8, srcva: usize, len: usize) c_int;

/// Fetch the uint64 at addr from the current process.
export fn fetchaddr(addr: usize, ip: *usize) c_int {
    var p: *Proc = myproc().?;
    if (addr >= p.sz or addr + @sizeOf(usize) > p.sz) {
        return -1;
    }

    if (copyin(p.pagetable, @ptrCast([*:0]u8, ip), addr, @sizeOf(@TypeOf(ip.*))) != 0) {
        return -1;
    }

    return 0;
}

fn argraw(n: u8) usize {
    var p: *Proc = myproc().?;

    return switch (n) {
        0 => p.trapframe.a0,
        1 => p.trapframe.a1,
        2 => p.trapframe.a2,
        3 => p.trapframe.a3,
        4 => p.trapframe.a4,
        5 => p.trapframe.a5,
        else => @panic("argraw"),
    };
}

/// Fetch the nth 32-bit system call argument.
export fn argint(n: c_int, ip: *c_int) void {
    ip.* = @intCast(c_int, argraw(@intCast(u8, n)));
}

/// Retrieve an argument as a pointer.
/// Doesn't check for legality, since
/// copyin/copyout will do that.
export fn argaddr(n: c_int, ip: *usize) void {
    ip.* = argraw(@intCast(u8, n));
}

/// Fetch the nth word-sized system call argument as a null-terminated string.
/// Copies into buf, at most max.
/// Returns string length if OK (including nul), -1 if error.
export fn argstr(n: c_int, buf: [*:0]u8, max: usize) c_int {
    var addr: usize = undefined;
    argaddr(n, &addr);
    return fetchstr(addr, buf, max);
}

/// Copy a null-terminated string from user to kernel.
/// Copy bytes to dst from virtual address srcva in a given page table,
/// until a '\0', or max.
/// Return 0 on success, -1 on error.
extern fn copyinstr(pagetable: PageTable, dst: [*:0]u8, srcva: usize, max: usize) c_int;

/// Fetch the nul-terminated string at addr from the current process.
/// Returns length of string, not including nul, or -1 for error.
export fn fetchstr(addr: usize, buf: [*:0]u8, max: usize) c_int {
    var p: *Proc = myproc().?;
    if (copyinstr(p.pagetable, buf, addr, max) != 0) {
        return -1;
    }
    return @intCast(c_int, std.mem.len(buf));
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

extern fn sys_fork() usize;
extern fn sys_exit() usize;
extern fn sys_wait() usize;
extern fn sys_pipe() usize;
extern fn sys_read() usize;
extern fn sys_kill() usize;
extern fn sys_exec() usize;
extern fn sys_fstat() usize;
extern fn sys_chdir() usize;
extern fn sys_dup() usize;
extern fn sys_getpid() usize;
extern fn sys_sbrk() usize;
extern fn sys_sleep() usize;
extern fn sys_uptime() usize;
extern fn sys_open() usize;
extern fn sys_write() usize;
extern fn sys_mknod() usize;
extern fn sys_unlink() usize;
extern fn sys_link() usize;
extern fn sys_mkdir() usize;
extern fn sys_close() usize;

/// An array mapping syscall numbers from `SYS`
/// to the function that handles the system call.
const syscalls = blk: {
    const sys_fields = std.meta.fields(SYS);

    // Note that syscalls[0] doesn't contain any function pointer since syscall starts from 1.
    var sys_calls: [sys_fields.len + 1]*const fn () callconv(.C) usize = undefined;
    for (sys_fields) |call| {
        sys_calls[call.value] = @field(@This(), "sys_" ++ call.name);
    }

    break :blk sys_calls;
};

extern fn myproc() ?*Proc;

pub export fn syscall() void {
    var p: *Proc = myproc().?;
    var num = p.trapframe.a7;

    if (num > 0 and num < syscalls.len) {
        // Use num to lookup the system call function for num, call it,
        // and store its return value in p.trapframe.a0
        p.trapframe.a0 = syscalls[num]();
    } else {
        kernel.print("{} {s}: unknown sys call {}\n", .{ p.pid, &p.name, num });
        p.trapframe.a0 = std.math.maxInt(usize);
    }
}
