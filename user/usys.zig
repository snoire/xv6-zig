const std = @import("std");
const kernel = @import("kernel");
const print = std.fmt.comptimePrint;

const EnumField = std.builtin.Type.EnumField;
const Stat = kernel.Stat;
const SysCall = kernel.SysCall;

pub const fd_t = i32;
pub const pid_t = i32;

comptime {
    for (std.meta.fields(SysCall)) |call| {
        asm (entry(call));
    }
}

fn entry(comptime call: EnumField) []const u8 {
    return print(
        \\.global {0s}
        \\{0s}:
        \\ li a7, {1d}
        \\ ecall
        \\ ret
        \\
    , .{ call.name, call.value });
}

pub extern fn fork() c_int;
pub extern fn getpid() pid_t;
pub extern fn exit(code: c_int) noreturn;
pub extern fn wait(stat: ?*c_int) pid_t;
pub extern fn kill(pid: pid_t) c_int;
pub extern fn exec(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

pub extern fn open(path: [*:0]const u8, oflag: c_uint) c_int;
pub extern fn close(fd: fd_t) c_int;
pub extern fn read(fd: fd_t, buf: [*]u8, nbyte: usize) isize;
pub extern fn write(fd: fd_t, buf: [*]const u8, nbyte: usize) isize;
pub extern fn dup(fd: fd_t) c_int;
pub extern fn pipe(fds: *[2]fd_t) c_int;

pub extern fn mknod([*:0]const u8, u16, u16) isize;
pub extern fn link(oldpath: [*:0]const u8, newpath: [*:0]const u8) c_int;
pub extern fn unlink(path: [*:0]const u8) c_int;
pub extern fn mkdir(path: [*:0]const u8) c_int;
pub extern fn chdir(path: [*:0]const u8) c_int;
pub extern fn stat(noalias path: [*:0]const u8, noalias buf: *Stat) c_int;

pub extern fn sleep(ntick: usize) c_int;
pub extern fn uptime() usize;
pub extern fn sbrk(nbyte: usize) [*]u8;
