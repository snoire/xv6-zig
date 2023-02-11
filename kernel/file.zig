const Pipe = @import("pipe.zig").Pipe;
const SleepLock = @import("sleeplock.zig").SleepLock;
const NDIRECT = @import("fs.zig").NDIRECT;

pub const File = extern struct {
    type: enum(c_int) { none, pipe, inode, device },
    /// reference count
    ref: c_int,
    readable: u8,
    writable: u8,
    /// FD_PIPE
    pipe: *Pipe,
    /// FD_INODE and FD_DEVICE
    ip: *Inode,
    /// FD_INODE
    off: c_uint,
    /// FD_DEVICE
    major: c_short,
};

/// in-memory copy of an inode
pub const Inode = extern struct {
    /// Device number
    dev: c_uint,
    /// Inode number
    inum: c_uint,
    /// Reference count
    ref: c_int,
    /// protects everything below here
    lock: SleepLock,
    /// inode has been read from disk?
    valid: c_int,

    /// copy of disk inode
    type: c_short,
    major: c_short,
    minor: c_short,
    nlink: c_short,
    size: c_uint,
    addrs: [NDIRECT + 1 + 1]c_uint,
};
