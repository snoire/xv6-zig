const std = @import("std");
const kernel = @import("xv6.zig");
const SpinLock = kernel.spinlock.SpinLock;

extern fn consputc(char: u8) void;
extern fn initlock(lk: *SpinLock, name: [*:0]const u8) void;
extern fn acquire(lk: *SpinLock) void;
extern fn release(lk: *SpinLock) void;

extern var pr: struct {
    lock: SpinLock,
    locking: bool,
};

fn write(_: void, string: []const u8) error{}!usize {
    for (string) |char| {
        consputc(char);
    }
    return string.len;
}

const Writer = std.io.Writer(void, error{}, write);

pub fn print(comptime format: []const u8, args: anytype) void {
    const locking = pr.locking;
    if (locking) acquire(&pr.lock);

    std.fmt.format(Writer{ .context = {} }, format, args) catch unreachable;

    if (locking) release(&pr.lock);
}

// workaround for https://github.com/ziglang/zig/issues/12533
export fn putchar(c: c_int) c_int {
    consputc(@intCast(u8, c));
    return 1;
}
export fn puts(s: [*:0]const u8) c_int {
    var i: usize = 0;
    while (s[i] > 0) : (i += 1) {
        consputc(@intCast(u8, s[i]));
    }

    return @intCast(c_int, i);
}
