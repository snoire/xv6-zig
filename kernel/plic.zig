// memory map
// https://github.com/qemu/qemu/blob/master/hw/riscv/virt.c
const plic_base = 0x0c00_0000;

// https://github.com/qemu/qemu/blob/master/include/hw/riscv/virt.h
const priority_base = plic_base + 0x0;
const pending_base = plic_base + 0x1000;

const enable_base = plic_base + 0x2000;
const enable_stride = 0x80;

const context_base = plic_base + 0x20_0000;
const context_stride = 0x1000;

const threshold_base = context_base;
const @"claim/complete_base" = context_base + 0x4;

// proc.zig
extern fn cpuid() usize;

const IRQ = enum(u6) {
    virtio0 = 1,
    uart0 = 10,
    _,
};

/// interrupt target
pub const Target = struct {
    mode: Mode,
    hart: u3,

    // privilege mode
    const Mode = enum(u1) {
        machine = 0,
        supervisor = 1,
    };

    /// Enable/disable certain interrupt sources
    pub fn enable(target: Target, irq: IRQ) void {
        const id = @intFromEnum(irq);
        const enables: [*]volatile u32 = @ptrFromInt(
            enable_base + (@as(usize, 2) * target.hart + @intFromEnum(target.mode)) * enable_stride,
        );

        // require naturally aligned 32-bit memory accesses
        if (id < 32) {
            enables[0] |= @as(u32, 1) << @intCast(id);
        } else {
            enables[1] |= @as(u32, 1) << @intCast(id - 32);
        }
    }

    /// Sets the threshold that interrupts must meet before being able to trigger.
    pub fn threshold(target: Target, thr: u3) void {
        const ptr: *volatile u32 = @ptrFromInt(
            threshold_base + (@as(usize, 2) * target.hart + @intFromEnum(target.mode)) * context_stride,
        );
        ptr.* = thr;
    }

    /// Query the PLIC what interrupt we should serve.
    pub fn claim(target: Target) ?IRQ {
        const ptr: *volatile u32 = @ptrFromInt(
            @"claim/complete_base" + (@as(usize, 2) * target.hart + @intFromEnum(target.mode)) * context_stride,
        );
        const irq = ptr.*;
        return if (irq != 0) @as(IRQ, @enumFromInt(irq)) else null;
    }

    /// Writing the interrupt ID it received from the claim (irq) to the
    /// complete register would signal the PLIC we've served this IRQ.
    pub fn complete(target: Target, irq: IRQ) void {
        const ptr: *volatile u32 = @ptrFromInt(
            @"claim/complete_base" + (@as(usize, 2) * target.hart + @intFromEnum(target.mode)) * context_stride,
        );
        ptr.* = @intFromEnum(irq);
    }
};

pub fn init() void {
    // set desired IRQ priorities non-zero (otherwise disabled).
    priority(.uart0, 1);
    priority(.virtio0, 1);
}

pub fn inithart() void {
    const target = Target{ .mode = .supervisor, .hart = @intCast(cpuid()) };

    // set enable bits for this hart's S-mode
    // for the uart and virtio disk.
    target.enable(.uart0);
    target.enable(.virtio0);

    // set this hart's S-mode priority threshold to 0.
    target.threshold(0);
}

/// Sets the priority of a particular interrupt source
fn priority(irq: IRQ, pri: u3) void {
    const ptr: [*]volatile u32 = @ptrFromInt(priority_base);
    ptr[@intFromEnum(irq)] = pri;
}
