/// general-purpose register
pub const gpr = struct {
    pub inline fn read(comptime name: []const u8) usize {
        return asm volatile ("mv %[ret], " ++ name
            : [ret] "=r" (-> usize),
        );
    }

    pub inline fn write(comptime name: []const u8, value: usize) void {
        asm volatile ("mv " ++ name ++ ", %[value]"
            :
            : [value] "r" (value),
        );
    }
};

/// control and status register
pub const csr = struct {
    // Machine Status Register, mstatus
    pub const mstatus = struct {
        pub const mpp = 3 << 11;
        pub const mpp_m = 3 << 11;
        pub const mpp_s = 1 << 11;
        pub const mpp_u = 0 << 11;
        pub const spp = 1 << 8;
        pub const mpie = 1 << 7;
        pub const spie = 1 << 5;
        pub const upie = 1 << 4;
        pub const mie = 1 << 3;
        pub const sie = 1 << 1;
        pub const uie = 1 << 0;
    };

    // Machine-mode Interrupt Enable
    pub const mie = struct {
        pub const msie = 1 << 3; // software
        pub const mtie = 1 << 7; // timer
        pub const meie = 1 << 11; // external
    };

    // Supervisor Interrupt Enable
    pub const sie = struct {
        pub const ssie = 1 << 1; // software
        pub const stie = 1 << 5; // timer
        pub const seie = 1 << 9; // external
        pub const all = ssie | stie | seie;
    };

    pub inline fn read(comptime name: []const u8) usize {
        return asm volatile ("csrr %[ret], " ++ name
            : [ret] "=r" (-> usize),
        );
    }

    pub inline fn write(comptime name: []const u8, value: usize) void {
        asm volatile ("csrw " ++ name ++ ", %[value]"
            :
            : [value] "r" (value),
        );
    }

    pub inline fn set(comptime name: []const u8, mask: usize) void {
        asm volatile ("csrs " ++ name ++ ", %[mask]"
            :
            : [mask] "r" (mask),
        );
    }

    pub inline fn clear(comptime name: []const u8, mask: usize) void {
        asm volatile ("csrc " ++ name ++ ", %[mask]"
            :
            : [mask] "r" (mask),
        );
    }
};
