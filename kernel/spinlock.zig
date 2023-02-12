const kernel = @import("xv6.zig");
const Cpu = kernel.proc.Cpu;

// Mutual exclusion lock.
pub const SpinLock = extern struct {
    /// Is the lock held?
    locked: c_uint,

    // For debugging:
    /// Name of lock.
    name: [*:0]u8,
    /// The cpu holding the lock.
    cpu: *Cpu,
};
