const std = @import("std");
const EnumField = std.builtin.Type.EnumField;

const syscall = enum(u8) {
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

comptime {
    const info = @typeInfo(syscall).Enum;
    inline for (info.fields) |call| {
        asm (entry(call));
    }
}

fn entry(comptime call: EnumField) []const u8 {
    return std.fmt.comptimePrint(
        \\.global {0s}
        \\{0s}:
        \\ li a7, {1d}
        \\ ecall
        \\ ret
        \\
    , .{ call.name, call.value });
}

pub extern fn sleep(usize) usize;
pub extern fn exit(usize) noreturn;
pub extern fn write(usize, *const anyopaque, usize) usize;
