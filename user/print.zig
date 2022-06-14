const std = @import("std");
const sys = @import("usys.zig");

fn write(fd: sys.fd_t, string: []const u8) error{}!usize {
    const nbyte = sys.write(fd, string.ptr, string.len);
    if (nbyte < 0) @panic("write error");
    return @intCast(usize, nbyte);
}

const Writer = std.io.Writer(sys.fd_t, error{}, write);

pub fn fprint(fd: sys.fd_t, comptime format: []const u8, args: anytype) void {
    std.fmt.format(Writer{ .context = fd }, format, args) catch unreachable;
}

pub fn print(comptime format: []const u8, args: anytype) void {
    fprint(1, format, args);
}
