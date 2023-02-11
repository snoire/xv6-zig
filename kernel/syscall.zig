const std = @import("std");
const proc = @import("proc.zig");

const c = @cImport({
    @cInclude("types.h");
    @cInclude("param.h");
    @cInclude("memlayout.h");
    @cInclude("riscv.h");
    @cInclude("defs.h");
});

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

extern fn myproc() ?*proc.Proc;

pub export fn syscall() void {
    var p: *proc.Proc = myproc().?;
    var num = p.trapframe.a7;

    if (num > 0 and num < syscalls.len) {
        // Use num to lookup the system call function for num, call it,
        // and store its return value in p.trapframe.a0
        p.trapframe.a0 = syscalls[num]();
    } else {
        c.printf("%d %s: unknown sys call %d\n", p.pid, &p.name, num);
        p.trapframe.a0 = std.math.maxInt(usize);
    }
}
