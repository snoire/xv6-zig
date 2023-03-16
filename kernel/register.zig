const std = @import("std");

/// general-purpose register
pub const gpr = struct {
    const Register = enum {
        // zig fmt: off

        /// Hard-wired zero
        zero,
        /// Return address
        ra,
        /// Stack pointer
        sp,
        /// Global pointer
        gp,
        /// Thread pointer
        tp,
        /// Temporary/alternate link register
        t0,
        /// Temporaries
        t1, t2,
        /// Saved register/frame pointer
        s0,
        /// Saved register
        s1,
        /// Function arguments/return values
        a0, a1,
        /// Function arguments
        a2, a3, a4, a5, a6, a7,
        /// Saved registers
        s2, s3, s4, s5, s6, s7, s8, s9, s10, s11,
        /// Temporaries
        t3, t4, t5, t6,

        // zig fmt: on

        // aliases
        /// Saved register/frame pointer
        const fp: @This() = .s0;
    };

    pub inline fn read(comptime register: Register) usize {
        const name = @tagName(register);
        return asm volatile ("mv %[ret], " ++ name
            : [ret] "=r" (-> usize),
        );
    }

    pub inline fn write(comptime register: Register, value: usize) void {
        const name = @tagName(register);
        asm volatile ("mv " ++ name ++ ", %[value]"
            :
            : [value] "r" (value),
        );
    }
};

/// control and status register
pub const csr = struct {
    const Register = enum {
        mhartid,
        mscratch,
        mstatus,
        mepc,
        mtvec,
        mip,
        mie,
        medeleg,
        mideleg,
        mret,

        sstatus,
        satp,
        sie,

        pmpaddr0,
        pmpcfg0,
    };

    // All the following packed structs must be 64bit.
    comptime {
        for (std.meta.fields(Register)) |field| {
            if (@hasDecl(csr, field.name)) {
                std.debug.assert(@bitSizeOf(@field(csr, field.name)) == 64);
            }
        }
    }

    /// Machine Status Register
    pub const mstatus = packed struct {
        const tag = .mstatus;
        pub usingnamespace Methods(@This());

        @"0": u1 = 0,
        sie: bool = false,

        @"2": u1 = 0,
        mie: bool = false,

        @"4": u1 = 0,
        spie: bool = false,
        ube: bool = false,
        mpie: bool = false,
        spp: bool = false,
        vs: u2 = 0,
        mpp: mpp = .user,

        _: u51 = 0,

        pub const mpp = enum(u2) {
            user = 0b00,
            supervisor = 0b01,
            hypervisor = 0b10,
            machine = 0b11,

            pub fn set(self: @This()) void {
                // reset to 0
                csr.mstatus.reset(.{ .mpp = .machine });
                // set to `self`
                csr.mstatus.set(.{ .mpp = self });
            }
        };
    };

    /// Supervisor Status Register
    pub const sstatus = packed struct {
        const tag = .sstatus;
        pub usingnamespace Methods(@This());

        @"0": u1 = 0,
        sie: bool = false,

        @"2-4": u3 = 0,
        spie: bool = false,
        ube: bool = false,

        @"7": u1 = 0,
        spp: bool = false,

        _: u55 = 0,
    };

    /// Machine-mode Interrupt Enable
    pub const mie = packed struct {
        const tag = .mie;
        pub usingnamespace Methods(@This());

        @"0": u1 = 0,
        ssie: bool = false,

        @"2": u1 = 0,
        msie: bool = false,

        @"4": u1 = 0,
        stie: bool = false,

        @"6": u1 = 0,
        mtie: bool = false,

        @"8": u1 = 0,
        seie: bool = false,

        @"10": u1 = 0,
        meie: bool = false,

        _: u52 = 0,
    };

    /// Supervisor Interrupt Enable
    pub const sie = packed struct {
        const tag = .sie;
        pub usingnamespace Methods(@This());

        @"0": u1 = 0,
        ssie: bool = false,

        @"2-4": u3 = 0,
        stie: bool = false,

        @"6-8": u3 = 0,
        seie: bool = false,

        _: u54 = 0,
    };

    /// Supervisor Address Translation and Protection Register
    pub const satp = packed struct {
        const tag = .satp;
        pub usingnamespace Methods(@This());

        /// Physical Page Number
        ppn: u44 = 0,

        /// Address Space Identifier (optional)
        asid: u16 = 0,

        mode: enum(u4) {
            none = 0,
            sv39 = 8,
            sv48 = 9,
        } = .none,
    };

    pub inline fn read(comptime register: Register) usize {
        const name = @tagName(register);
        return asm volatile ("csrr %[ret], " ++ name
            : [ret] "=r" (-> usize),
        );
    }

    pub inline fn write(comptime register: Register, value: usize) void {
        const name = @tagName(register);
        asm volatile ("csrw " ++ name ++ ", %[value]"
            :
            : [value] "r" (value),
        );
    }

    pub inline fn set(comptime register: Register, mask: usize) void {
        const name = @tagName(register);
        asm volatile ("csrs " ++ name ++ ", %[mask]"
            :
            : [mask] "r" (mask),
        );
    }

    pub inline fn clear(comptime register: Register, mask: usize) void {
        const name = @tagName(register);
        asm volatile ("csrc " ++ name ++ ", %[mask]"
            :
            : [mask] "r" (mask),
        );
    }

    fn Methods(comptime T: type) type {
        const register = @field(T, "tag");

        return struct {
            pub fn read() T {
                return @bitCast(T, csr.read(register));
            }

            pub fn set(self: T) void {
                csr.set(register, @bitCast(usize, self));
            }

            pub fn reset(self: T) void {
                csr.clear(register, @bitCast(usize, self));
            }
        };
    }
};
