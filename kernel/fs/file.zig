const c = @import("c.zig");
const kernel = @import("xv6.zig");
const SpinLock = @import("SpinLock.zig");
const Self = @This();

var ftable: struct {
    lock: SpinLock,
    files: [kernel.NFILE]Self,
} = .{ .lock = SpinLock.init("ftable"), .file = undefined };

type: enum(c_int) { none, pipe, inode, device },
/// reference count
ref: c_int,
readable: u8,
writable: u8,
/// FD_PIPE
pipe: *c.Pipe,
/// FD_INODE and FD_DEVICE
ip: *c.Inode,
/// FD_INODE
off: c_uint,
/// FD_DEVICE
major: c_short,

/// Allocate a file structure.
pub fn alloc() ?*Self {
    ftable.lock.acquire();
    defer ftable.lock.release();

    for (&ftable.files) |*file| {
        if (file.ref == 0) {
            file.ref = 1;
            return file;
        }
    }

    return null;
}

/// Increment ref count for file.
pub fn dup(file: *Self) void {
    ftable.lock.acquire();
    defer ftable.lock.release();

    if (file.ref < 1) @panic("filedup");

    file.ref += 1;
    return file;
}

// Close file.  (Decrement ref count, close when reaches 0.)
pub fn close(file: *Self) !void {
    {
        ftable.lock.acquire();
        defer ftable.lock.release();

        if (file.ref < 1) @panic("filedup");

        file.ref -= 1;
        if (file.ref > 0) return;
    }

    // close this file
}
