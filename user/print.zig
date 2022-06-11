const std = @import("std");
const sys = @import("usys.zig");

fn write(_: void, string: []const u8) error{}!usize {
    return sys.write(1, string.ptr, string.len);
}

const Writer = std.io.Writer(void, error{}, write);

pub fn print(comptime format: []const u8, args: anytype) void {
    std.fmt.format(Writer{ .context = {} }, format, args) catch unreachable;
}
