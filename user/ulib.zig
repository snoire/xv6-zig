const std = @import("std");
const sys = @import("usys.zig");

pub const Reader = std.io.Reader(sys.fd_t, error{}, read);

pub fn getStdIn() Reader {
    return Reader{ .context = 0 };
}

fn read(fd: sys.fd_t, buffer: []u8) error{}!usize {
    const nbyte = sys.read(fd, buffer.ptr, buffer.len);
    if (nbyte < 0) @panic("read error");
    return @intCast(usize, nbyte);
}

pub fn gets(buffer: []u8) !?[]u8 {
    const reader = getStdIn();
    return reader.readUntilDelimiterOrEof(buffer, '\n');
}

pub const Writer = std.io.Writer(sys.fd_t, error{}, write);

pub fn getStdOut() Writer {
    return Writer{ .context = 1 };
}

pub fn getStdErr() Writer {
    return Writer{ .context = 2 };
}

fn write(fd: sys.fd_t, string: []const u8) error{}!usize {
    const nbyte = sys.write(fd, string.ptr, string.len);
    if (nbyte < 0) @panic("write error");
    return @intCast(usize, nbyte);
}

pub fn print(comptime format: []const u8, args: anytype) void {
    getStdOut().print(format, args) catch return;
}

pub fn fprint(fd: sys.fd_t, comptime format: []const u8, args: anytype) void {
    const writer = Writer{ .context = fd };
    writer.print(format, args) catch return;
}
