const std = @import("std");
const xv6 = @import("../xv6.zig");
const c = @import("../c.zig");
const vm = @import("../vm.zig");
const proc = @import("../proc.zig");
const Proc = proc.Proc;
const kalloc = @import("../kalloc.zig");
const PageTable = vm.PageTable;
const ElfHdr = std.elf.Elf64_Ehdr;
const ProgHdr = std.elf.Elf64_Phdr;
const PGSIZE = 4096;

/// Load a program segment into pagetable at virtual address va.
/// va must be page-aligned
/// and the pages from va to va+sz must already be mapped.
/// Returns 0 on success, -1 on failure.
fn loadseg(
    pagetable: vm.PageTable,
    va: vm.VirAddr,
    ip: *c.Inode,
    offset: usize,
    sz: usize,
) !void {
    var i: usize = 0;
    while (i < sz) : (i += vm.PGSIZE) {
        var pa = try pagetable.walkaddr(.{ .addr = va.addr + i });
        if (pa.addr == 0) return error.LoadSeg;

        var n = @min(sz - i, vm.PGSIZE);
        if (ip.read(false, pa.addr, offset + i, n) != n)
            return error.LoadSeg;
    }
}

fn flags2perm(flags: u32) vm.Pte.Flags {
    return .{
        .executable = if (flags & 0x1 != 0) true else false,
        .writable = if (flags & 0x2 != 0) true else false,
    };
}

const ELF_PROG_LOAD = 1;

pub fn exec(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) !isize {
    var sz: usize = 0;
    var elf: ElfHdr = undefined;
    var p = Proc.myproc().?;

    var pagetable = try p.createPagetable();
    errdefer {
        if (sz != 0) pagetable.free(sz);
    }

    {
        c.begin_op();
        defer c.end_op();

        var ip = c.namei(path) orelse return error.InvalidPath;

        ip.ilock();
        defer ip.unlockput();

        // Check ELF header
        if (ip.read(false, @intFromPtr(&elf), 0, @sizeOf(ElfHdr)) != @sizeOf(ElfHdr))
            return error.BadElf;

        if (!std.mem.eql(u8, elf.e_ident[0..4], std.elf.MAGIC))
            return error.InvalidElfMagic;

        // Load program into memory.
        var off = elf.e_phoff;
        for (0..elf.e_phnum) |_| {
            var ph: ProgHdr = undefined;
            if (ip.read(false, @intFromPtr(&ph), off, @sizeOf(ProgHdr)) != @sizeOf(ProgHdr))
                return error.BadProgHdr;

            if (ph.p_type != ELF_PROG_LOAD) return error.p_type;
            if (ph.p_memsz < ph.p_filesz) return error.p_memsz;
            if (ph.p_vaddr + ph.p_memsz < ph.p_vaddr) return error.p_vaddr;
            if (!std.mem.isAligned(ph.p_vaddr, kalloc.PGSIZE)) return error.NotAligned;

            sz = try pagetable.alloc(sz, ph.p_vaddr + ph.p_memsz, flags2perm(ph.p_flags));

            try loadseg(pagetable, .{ .addr = ph.p_vaddr }, ip, ph.p_offset, ph.p_filesz);
            off += @sizeOf(ProgHdr);
        }
    }

    p = Proc.myproc().?;
    var oldsz: usize = p.sz;

    // Allocate sixteen pages at the next page boundary.
    // Make the first inaccessible as a stack guard.
    // Use the rest as the user stack.
    sz = std.mem.alignForward(usize, sz, PGSIZE);
    var sz1 = try pagetable.alloc(sz, sz + 16 * PGSIZE, .{ .writable = true });

    sz = sz1;
    pagetable.clear(.{ .addr = sz - 16 * PGSIZE });
    var sp = sz;
    var stackbase = sp - PGSIZE;

    // Push argument strings, prepare rest of stack in ustack.
    var ustack: [xv6.MAXARG]usize = undefined;
    const args = std.mem.span(argv);

    for (args, ustack[0..args.len]) |*arg, *stack| {
        sp -= std.mem.len(arg.*.?) + 1;
        sp -= sp % 16; // riscv sp must be 16-byte aligned
        if (sp < stackbase) return error.stackbase;
        if (pagetable.copyout(.{ .addr = sp }, arg.*.?, std.mem.len(arg.*.?) + 1) < 0)
            return error.copyout;
        stack.* = sp;
    }

    ustack[args.len] = 0;

    // push the array of argv[] pointers.
    sp -= (args.len + 1) * @sizeOf(usize);
    sp -= sp % 16;

    if (sp < stackbase) return error.stackbase;
    if (pagetable.copyout(.{ .addr = sp }, @ptrCast(&ustack), (args.len + 1) * @sizeOf(usize)) < 0)
        return error.copyout;

    // arguments to user main(argc, argv)
    // argc is returned via the system call return
    // value, which goes in a0.
    p.trapframe.?.a1 = sp;

    // Save program name for debugging.
    const program_name: [:0]const u8 = blk: {
        const name1 = std.fs.path.basename(std.mem.span(path));
        break :blk @ptrCast(name1);
    };
    std.mem.copy(u8, &p.name, program_name[0 .. program_name.len + 1]);

    // Commit to the user image.
    var oldpagetable = p.pagetable;
    p.pagetable = pagetable;
    p.sz = sz;
    p.trapframe.?.epc = elf.e_entry;
    p.trapframe.?.sp = sp;
    oldpagetable.freepagetable(oldsz);

    const nargs: isize = @intCast(args.len);
    return nargs;
}
