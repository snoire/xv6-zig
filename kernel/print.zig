const std = @import("std");
const kernel = @import("xv6.zig");
const c = @import("c.zig");
const SpinLock = c.SpinLock;

extern fn consputc(char: u8) void;
extern fn initlock(lk: *SpinLock, name: [*:0]const u8) void;
extern fn acquire(lk: *SpinLock) void;
extern fn release(lk: *SpinLock) void;

export var panicked: c_int = 0;

var pr: struct {
    lock: SpinLock,
    locking: bool,
} = undefined;

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

export fn printf(format: [*:0]const u8, ...) void {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);

    var state: enum { normal, wait_for_specifier } = .normal;

    for (std.mem.span(format)) |char| {
        if (state == .normal) {
            if (char == '%') {
                state = .wait_for_specifier;
            } else {
                print("{c}", .{char});
            }
        } else { // conversion specifiers
            switch (char) {
                'd' => print("{d}", .{@cVaArg(&ap, c_int)}),
                'x' => print("{x}", .{@cVaArg(&ap, c_int)}),
                'p' => print("{p}", .{@cVaArg(&ap, *usize)}),
                's' => print("{s}", .{@cVaArg(&ap, [*:0]const u8)}),
                '%' => print("%", .{}),
                // Print unknown % sequence to draw attention.
                else => print("%{c}", .{char}),
            }
            state = .normal;
        }
    }
}

pub fn init() void {
    initlock(&pr.lock, "pr");
    pr.locking = true;
}

fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, return_addr: ?usize) noreturn {
    @setCold(true);
    pr.locking = false;
    print("PANIC: {s}!\n", .{msg});

    const first_ret_addr = return_addr orelse @returnAddress();
    var it = std.debug.StackIterator.init(first_ret_addr, null);

    print("Stack Trace:\n", .{});
    while (it.next()) |ret_addr| {
        print(" 0x{x}\n", .{ret_addr});
    }

    panicked = 1; // freeze uart output from other CPUs
    while (true) {}
}

fn cpanic(msg: [*:0]const u8) callconv(.C) noreturn {
    panic(std.mem.span(msg), null, null);
}

comptime {
    @export(cpanic, .{ .name = "panic", .linkage = .Strong });
}

// workaround for https://github.com/ziglang/zig/issues/12533
export fn putchar(char: c_int) c_int {
    consputc(@intCast(u8, char));
    return 1;
}
export fn puts(s: [*:0]const u8) c_int {
    var i: usize = 0;
    while (s[i] > 0) : (i += 1) {
        consputc(@intCast(u8, s[i]));
    }

    return @intCast(c_int, i);
}
