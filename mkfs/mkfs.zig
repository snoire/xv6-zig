const std = @import("std");
const kernel = @import("kernel");
const fs = kernel.fs;
const print = std.debug.print;
const assert = std.debug.assert;
const toLittle = std.mem.nativeToLittle; // convert to riscv byte order

const Dinode = fs.Dinode;
const Dirent = fs.Dirent;
const FileType = kernel.stat.Stat.Type;

const NINODES = 200;

const nbitmap = kernel.FSSIZE / (fs.BSIZE * 8) + 1;
const ninodeblocks = NINODES / fs.IPB + 1;
const nlog = kernel.LOGSIZE;

// 1 fs block = 1 disk sector
const nmeta = 2 + nlog + ninodeblocks + nbitmap;
const nblocks = kernel.FSSIZE - nmeta;

const superblk: fs.SuperBlock = .{
    .magic = fs.SuperBlock.FSMAGIC,
    .size = toLittle(u32, kernel.FSSIZE),
    .nblocks = toLittle(u32, nblocks),
    .ninodes = toLittle(u32, NINODES),
    .nlog = toLittle(u32, nlog),
    .logstart = toLittle(u32, 2),
    .inodestart = toLittle(u32, 2 + nlog),
    .bmapstart = toLittle(u32, 2 + nlog + ninodeblocks),
};

/// Disk layout:
/// [ boot block (not used) | superblock | log | inode blocks | free bit map | data blocks ]
const Disk = struct {
    const Self = @This();

    file: std.fs.File,
    freeinode: u16 = 1,
    freeblock: u32 = nmeta,

    fn init(path: []const u8) !Self {
        const f = try std.fs.cwd().createFile(path, .{ .read = true });

        // allocate a sparse file
        try f.seekTo(kernel.FSSIZE * fs.BSIZE - 1);
        _ = try f.write("$");

        return Self{ .file = f };
    }

    fn deinit(self: Self) void {
        self.file.close();
    }

    /// buf must be little endian data
    fn wsect(self: Self, sec: usize, offset: usize, buf: []const u8) !usize {
        if (sec >= kernel.FSSIZE) return error.TOO_LARGE;
        try self.file.seekTo(sec * fs.BSIZE + offset);

        // make sure we don't write to the next sector
        const len = if (offset + buf.len > fs.BSIZE) fs.BSIZE - offset else buf.len;
        try self.file.writeAll(buf[0..len]);
        return len;
    }

    fn rsect(self: Self, sec: usize, buf: *[fs.BSIZE]u8) !void {
        try self.file.seekTo(sec * fs.BSIZE);
        _ = try self.file.readAll(buf);
    }

    const Inode = struct {
        // host endian
        inum: u16,
        type: u16,
        nlink: u16 = 1,
        size: u32 = 0,
        addrs: [fs.NDIRECT + 1 + 1]u32 = .{0} ** (fs.NDIRECT + 1 + 1),

        /// convert to little endian
        fn dinode(self: Inode) Dinode {
            var node: Dinode = undefined;

            node.type = @intCast(i16, toLittle(u16, self.type));
            node.nlink = @intCast(i16, toLittle(u16, self.nlink));
            node.size = toLittle(u32, self.size);

            for (node.addrs) |*addr, i| {
                addr.* = toLittle(u32, self.addrs[i]);
            }

            return node;
        }
    };

    /// Caller must call winode on result.
    fn ialloc(self: *Self, @"type": FileType) Inode {
        defer self.freeinode += 1;
        return .{
            .inum = self.freeinode,
            .type = @enumToInt(@"type"),
        };
    }

    fn winode(self: Self, ino: Inode) void {
        const sec = ino.inum / fs.IPB + superblk.inodestart;
        const offset = (ino.inum % fs.IPB) * @sizeOf(Dinode);
        _ = self.wsect(sec, offset, std.mem.asBytes(&ino.dinode())) catch @panic("winode error");
    }

    /// Return the disk block address of the nth block in inode.
    /// If there is no such block, bmap allocates one.
    fn bmap(self: *Self, ino: *Inode, blk_num: usize) !usize {
        var bn = blk_num;

        // direct block
        if (bn < fs.NDIRECT) {
            if (ino.addrs[bn] == 0) {
                ino.addrs[bn] = self.freeblock;
                self.freeblock += 1;
            }
            return ino.addrs[bn];
        }

        // singly-indirect block
        bn -= fs.NDIRECT;
        if (bn < fs.NINDIRECT) {
            var singly_blk: [fs.NINDIRECT]u32 = .{0} ** fs.NINDIRECT;
            const idx = fs.NDIRECT; // the index of singly-indirect block

            if (ino.addrs[idx] == 0) {
                ino.addrs[idx] = self.freeblock;
                self.freeblock += 1;
            } else {
                try self.rsect(ino.addrs[idx], @ptrCast(*[fs.BSIZE]u8, &singly_blk));
            }

            if (singly_blk[bn] == 0) {
                singly_blk[bn] = toLittle(u32, self.freeblock);
                self.freeblock += 1;
                _ = try self.wsect(ino.addrs[idx], bn * @sizeOf(u32), std.mem.asBytes(&singly_blk[bn]));
            }

            return singly_blk[bn];
        }

        // doubly-indirect block
        bn -= fs.NINDIRECT;
        if (bn < fs.ND_INDIRECT) {
            var doubly_blk: [fs.NINDIRECT]u32 = .{0} ** fs.NINDIRECT;
            const idx = fs.NDIRECT + 1; // the index of doubly-indirect block

            if (ino.addrs[idx] == 0) {
                ino.addrs[idx] = self.freeblock;
                self.freeblock += 1;
            } else {
                try self.rsect(ino.addrs[idx], @ptrCast(*[fs.BSIZE]u8, &doubly_blk));
            }

            var singly_blk: [fs.NINDIRECT]u32 = .{0} ** fs.NINDIRECT;
            const idx2 = bn / fs.NINDIRECT;

            if (doubly_blk[idx2] == 0) {
                doubly_blk[idx2] = toLittle(u32, self.freeblock);
                self.freeblock += 1;
                _ = try self.wsect(ino.addrs[idx], idx2 * @sizeOf(u32), std.mem.asBytes(&doubly_blk[idx2]));
            } else {
                try self.rsect(doubly_blk[idx2], @ptrCast(*[fs.BSIZE]u8, &singly_blk));
            }

            const idx3 = bn % fs.NINDIRECT;
            if (singly_blk[idx3] == 0) {
                singly_blk[idx3] = toLittle(u32, self.freeblock);
                self.freeblock += 1;
                _ = try self.wsect(doubly_blk[idx2], idx3 * @sizeOf(u32), std.mem.asBytes(&singly_blk[idx3]));
            }

            return singly_blk[idx3];
        }

        unreachable; // out of range
    }

    /// buf must be little endian data
    fn iappend(self: *Self, ino: *Inode, buf: []const u8) !void {
        var n: usize = 0;
        var filesize = ino.size;

        while (n < buf.len) {
            const fbn = filesize / fs.BSIZE;
            assert(fbn < fs.MAXFILE);

            const block = try self.bmap(ino, fbn);
            const offset = filesize - (fbn * fs.BSIZE);
            const nbytes = try self.wsect(block, offset, buf[n..]);

            filesize += @intCast(u32, nbytes);
            n += nbytes;
        }

        ino.size = filesize;
    }

    fn balloc(self: *Self) !void {
        print("balloc: first {} blocks have been allocated\n", .{self.freeblock});
        assert(self.freeblock < fs.BSIZE * 8);

        var buf: [fs.BSIZE]u8 = .{0} ** fs.BSIZE;
        var i: usize = 0;
        while (i < self.freeblock) : (i += 1) {
            buf[i / 8] |= @as(u8, 0x1) << @intCast(u3, i % 8);
        }

        print("balloc: write bitmap block at sector {}\n", .{superblk.bmapstart});
        _ = try self.wsect(superblk.bmapstart, 0, &buf);
    }
};

pub fn main() !void {
    comptime assert(fs.BSIZE % @sizeOf(Dinode) == 0);
    comptime assert(fs.BSIZE % @sizeOf(Dirent) == 0);

    const allocator = std.heap.page_allocator;
    var args = try std.process.argsAlloc(allocator);
    defer allocator.free(args);

    if (args.len < 2) {
        print("Usage: {s} fs.img files...\n", .{args[0]});
        return;
    }

    print(
        "nmeta {} (boot, super, log blocks {} inode blocks {}, bitmap blocks {}) blocks {} total {}\n",
        .{ nmeta, nlog, ninodeblocks, nbitmap, nblocks, kernel.FSSIZE },
    );

    var disk = try Disk.init(args[1]);
    defer disk.deinit();

    // write superblock
    _ = try disk.wsect(1, 0, std.mem.asBytes(&superblk));

    // allocate root inode
    var rootino = disk.ialloc(.dir);
    defer disk.winode(rootino);

    assert(rootino.inum == fs.ROOTINO);

    inline for (.{ ".", ".." }) |name| {
        try disk.iappend(&rootino, std.mem.asBytes(&Dirent{
            .inum = toLittle(u16, rootino.inum),
            .name = name.* ++ [_]u8{0} ** (fs.Dirent.DIRSIZ - name.len), // .name = name[0..c.DIRSIZ],
        }));
    }

    for (args[2..]) |app| {
        const shortname = blk: {
            const name1 = std.fs.path.basename(app);
            const name2 = std.mem.trimLeft(u8, name1, "_");
            break :blk @ptrCast([:0]const u8, name2);
        };

        const file = try std.fs.cwd().openFile(app, .{});
        defer file.close();

        var fileino = disk.ialloc(.file);
        defer disk.winode(fileino);

        var de = Dirent{
            .inum = toLittle(u16, fileino.inum),
            .name = undefined,
        };
        std.mem.copy(u8, &de.name, shortname[0 .. shortname.len + 1]);
        try disk.iappend(&rootino, std.mem.asBytes(&de));

        var buf: [fs.BSIZE]u8 = undefined;
        while (true) {
            const amt = try file.read(&buf);
            if (amt == 0) break;
            try disk.iappend(&fileino, buf[0..amt]);
        }
    }

    // fix size of root inode dir
    rootino.size = (rootino.size / fs.BSIZE + 1) * fs.BSIZE;

    // write to bitmap
    try disk.balloc();
}
