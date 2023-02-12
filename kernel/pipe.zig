const kernel = @import("xv6.zig");
const SpinLock = kernel.spinlock.SpinLock;

const PIPESIZE = 512;

pub const Pipe = extern struct {
    lock: SpinLock,
    data: [PIPESIZE]u8,
    /// number of bytes read
    nread: c_uint,
    /// number of bytes written
    nwrite: c_uint,
    /// read fd is still open
    readopen: c_int,
    /// write fd is still open
    writeopen: c_int,
};
