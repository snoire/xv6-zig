const std = @import("std");
const csr = @import("register.zig").csr;
const kernel = @import("xv6.zig");
const c = @import("c.zig");

const Atomic = std.atomic.Atomic;
const Cpu = c.Cpu;
const Proc = c.Proc;
const Self = @This();

/// Is the lock held?
locked: Atomic(bool) = Atomic(bool).init(false),

// For debugging:
/// Name of lock.
name: []const u8,
/// The cpu holding the lock.
cpu: ?*Cpu = null,

pub fn init(name: []const u8) Self {
    return .{ .name = name };
}

/// disable device interrupts
fn intrOff() void {
    csr.clear("sstatus", csr.mstatus.sie);
}

/// enable device interrupts
fn intrOn() void {
    csr.set("sstatus", csr.mstatus.sie);
}

// are device interrupts enabled?
fn intrGet() bool {
    const mstatus = csr.read("sstatus");
    return (mstatus & csr.mstatus.sie) != 0;
}

/// Check whether this cpu is holding the lock.
/// Interrupts must be off.
fn holding(self: *Self) bool {
    return self.locked.load(.Unordered) and self.cpu == mycpu();
}

/// Acquire the lock.
/// Loops (spins) until the lock is acquired.
pub fn acquire(self: *Self) void {
    pushOff(); // disable interrupts to avoid deadlock.

    if (self.holding()) @panic("acquire");

    // compare exchange is sorta semantically equivalent to the following atomically:
    // ```
    //   current = load(ptr, failure_ordering)
    //   if current != compare:
    //     return current
    //
    //   store(ptr, exchange, success_ordering)
    //   return null
    // ```
    while (self.locked.tryCompareAndSwap(false, true, .Monotonic, .Monotonic) == true) {}

    // Tell the zig compiler and the processor to not move loads or stores
    // past this point, to ensure that the critical section's memory
    // references happen strictly after the lock is acquired.
    // On RISC-V, this emits a fence instruction.
    @fence(.SeqCst);

    // Record info about lock acquisition for holding() and debugging.
    self.cpu = mycpu();
}

/// Release the lock.
pub fn release(self: *Self) void {
    if (!self.holding()) @panic("release");

    self.cpu = null;

    // Tell the zig compiler and the CPU to not move loads or stores
    // past this point, to ensure that all the stores in the critical
    // section are visible to other CPUs before the lock is released,
    // and that loads in the critical section occur strictly before
    // the lock is released.
    // On RISC-V, this emits a fence instruction.
    @fence(.SeqCst);

    // Release the lock, equivalent to self.locked = false.
    // This code doesn't use a C assignment, since the C standard
    // implies that an assignment might be implemented with
    // multiple store instructions.
    // On RISC-V, sync_lock_release turns into an atomic swap:
    //   s1 = &self.locked
    //   amoswap.w zero, zero, (s1)
    self.locked.store(false, .Unordered);
    popOff();
}

/// push_off/pop_off are like intr_off()/intr_on() except that they are matched:
/// it takes two pop_off()s to undo two push_off()s.  Also, if interrupts
/// are initially off, then push_off, pop_off leaves them off.
fn pushOff() void {
    intrOff();

    var cpu: *Cpu = mycpu();
    if (cpu.noff == 0) cpu.intena = if (intrGet()) 1 else 0;
    cpu.noff += 1;
}

fn popOff() void {
    var cpu: *Cpu = mycpu();

    if (intrGet()) @panic("pop_off - interruptible");
    if (cpu.noff < 1) @panic("pop_off");

    cpu.noff -= 1;
    if (cpu.noff == 0 and cpu.intena == 1) intrOn();
}

extern fn mycpu() *Cpu;
