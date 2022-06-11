const std = @import("std");
const sys = @import("usys.zig");

fn write(fd: usize, string: []const u8) error{}!usize {
    return sys.write(fd, string.ptr, string.len);
}

const Writer = std.io.Writer(usize, error{}, write);

pub fn fprint(fd: usize, comptime format: []const u8, args: anytype) void {
    std.fmt.format(Writer{ .context = fd }, format, args) catch unreachable;
}

pub fn print(comptime format: []const u8, args: anytype) void {
    fprint(1, format, args);
}
