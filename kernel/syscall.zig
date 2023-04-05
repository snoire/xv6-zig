const std = @import("std");
const c = @import("c.zig");
const kernel = @import("xv6.zig");
const proc = @import("proc.zig");
const vm = @import("vm.zig");
const print = kernel.print;
const Proc = proc.Proc;
const PageTable = vm.PageTable;

/// Fetch the uint64 at addr from the current process.
export fn fetchaddr(addr: usize, ip: *usize) c_int {
    var p: *Proc = Proc.myproc().?;
    if (addr >= p.sz or addr + @sizeOf(usize) > p.sz) {
        return -1;
    }

    return p.pagetable.copyin(@ptrCast([*]u8, ip), .{ .addr = addr }, @sizeOf(@TypeOf(ip.*)));
}

pub fn fetchAddr(addr: usize) usize {
    var p: *Proc = Proc.myproc().?;
    if (addr >= p.sz or addr + @sizeOf(usize) > p.sz) {
        @panic("fetchAddr");
    }

    var ip: usize = undefined;
    _ = p.pagetable.copyin(@ptrCast([*]u8, &ip), .{ .addr = addr }, @sizeOf(usize));
    return ip;
}

/// Fetch the nul-terminated string at addr from the current process.
/// Returns length of string, not including nul, or -1 for error.
export fn fetchstr(addr: usize, buf: [*:0]u8, max: usize) c_int {
    var p: *Proc = Proc.myproc().?;
    var str = p.pagetable.copyinstr(buf[0..max], .{ .addr = addr }) catch return -1;
    return @intCast(c_int, str.len);
}

pub fn fetchStr(addr: usize, buf: []u8) [:0]const u8 {
    var p: *Proc = Proc.myproc().?;
    return p.pagetable.copyinstr(buf, .{ .addr = addr }) catch unreachable;
}

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

/// Fetch the nth word-sized system call argument as a null-terminated string.
/// Copies into buf, at most max.
/// Returns string length if OK (including nul), panic if error.
pub fn argstr(n: u8, buf: []u8) [:0]const u8 {
    var addr = argaddr(n);
    return fetchStr(addr, buf);
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
