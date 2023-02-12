const kernel = @import("xv6.zig");
const SpinLock = kernel.spinlock.SpinLock;

/// Long-term locks for processes
pub const SleepLock = extern struct {
    /// Is the lock held?
    locked: c_uint,
    /// spinlock protecting this sleep lock
    lk: SpinLock,

    // For debugging:
    /// Name of lock.
    name: [*:0]u8,
    /// Process holding lock
    pid: c_int,
};
