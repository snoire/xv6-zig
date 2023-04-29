const std = @import("std");
const kernel = @import("kernel");
const c = kernel.c;
const fs = kernel.fs;
const stdout = std.io.getStdOut().writer();
const assert = std.debug.assert;
const toLittle = std.mem.nativeToLittle; // convert to riscv byte order

const Dinode = c.Dinode;
const Dirent = c.Dirent;
const FileType = c.Stat.Type;
const SuperBlock = c.SuperBlock;

const NINODES = 200;

const nbitmap = kernel.FSSIZE / (fs.BSIZE * 8) + 1;
const ninodeblocks = NINODES / fs.IPB + 1;
const nlog = kernel.LOGSIZE;

// 1 fs block = 1 disk sector
const nmeta = 2 + nlog + ninodeblocks + nbitmap;
const nblocks = kernel.FSSIZE - nmeta;

const superblk: SuperBlock = .{
    .magic = SuperBlock.FSMAGIC,
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
    file: std.fs.File,
    freeinode: u16 = 1,
    /// the first free block that we can allocate
    freeblock: u32 = nmeta,

    fn init(path: []const u8) !Disk {
        const f = try std.fs.cwd().createFile(path, .{ .read = true });

        // allocate a sparse file
        try f.seekTo(kernel.FSSIZE * fs.BSIZE - 1);
        _ = try f.write("$");

        return Disk{ .file = f };
    }

    fn deinit(self: Disk) void {
        self.writeBitmap() catch unreachable;
        self.file.close();
    }

    /// buf must be little endian data
    fn writeSector(self: Disk, sector_number: usize, offset: usize, buf: []const u8) !usize {
        if (sector_number >= kernel.FSSIZE) return error.TOO_LARGE;
        try self.file.seekTo(sector_number * fs.BSIZE + offset);

        // make sure we don't write to the next sector
        const len = if (offset + buf.len > fs.BSIZE) fs.BSIZE - offset else buf.len;
        try self.file.writeAll(buf[0..len]);
        return len;
    }

    fn readSector(self: Disk, sector_number: usize, buf: *[fs.BSIZE]u8) !void {
        try self.file.seekTo(sector_number * fs.BSIZE);
        _ = try self.file.readAll(buf);
    }

    const Inode = struct {
        // host endian
        number: u16,
        type: FileType,
        nlink: u16 = 1,
        size: u32 = 0,
        addrs: [fs.NDIRECT + 1 + 1]u32 = .{0} ** (fs.NDIRECT + 1 + 1),

        /// convert to little endian
        fn dinode(self: Inode) Dinode {
            var node: Dinode = undefined;

            node.type = toLittle(FileType, self.type);
            node.nlink = @intCast(toLittle(u16, self.nlink));
            node.size = toLittle(u32, self.size);

            for (&node.addrs, 0..) |*addr, i| {
                addr.* = toLittle(u32, self.addrs[i]);
            }

            return node;
        }
    };

    /// Caller must call writeInode on result.
    fn allocInode(self: *Disk, @"type": FileType) Inode {
        defer self.freeinode += 1;
        return .{
            .number = self.freeinode,
            .type = @"type",
        };
    }

    fn writeInode(self: Disk, inode: Inode) void {
        const sector_number = inode.number / fs.IPB + superblk.inodestart;
        const offset = (inode.number % fs.IPB) * @sizeOf(Dinode);
        _ = self.writeSector(sector_number, offset, std.mem.asBytes(&inode.dinode())) catch |err| @panic(@errorName(err));
    }

    /// Return the disk block address of the nth block in inode.
    /// If there is no such block, bitmap allocates one.
    fn bitmap(self: *Disk, inode: *Inode, block_number: usize) !usize {
        var bn = block_number;

        // direct block
        if (bn < fs.NDIRECT) {
            if (inode.addrs[bn] == 0) {
                inode.addrs[bn] = self.freeblock;
                self.freeblock += 1;
            }
            return inode.addrs[bn];
        }

        // singly-indirect block
        bn -= fs.NDIRECT;
        if (bn < fs.NINDIRECT) {
            var singly_blk: [fs.NINDIRECT]u32 = .{0} ** fs.NINDIRECT;
            const idx = fs.NDIRECT; // the index of singly-indirect block

            if (inode.addrs[idx] == 0) {
                inode.addrs[idx] = self.freeblock;
                self.freeblock += 1;
            } else {
                try self.readSector(inode.addrs[idx], @ptrCast(&singly_blk));
            }

            if (singly_blk[bn] == 0) {
                singly_blk[bn] = toLittle(u32, self.freeblock);
                self.freeblock += 1;
                _ = try self.writeSector(inode.addrs[idx], bn * @sizeOf(u32), std.mem.asBytes(&singly_blk[bn]));
            }

            return singly_blk[bn];
        }

        // doubly-indirect block
        bn -= fs.NINDIRECT;
        if (bn < fs.ND_INDIRECT) {
            var doubly_blk: [fs.NINDIRECT]u32 = .{0} ** fs.NINDIRECT;
            const idx = fs.NDIRECT + 1; // the index of doubly-indirect block

            if (inode.addrs[idx] == 0) {
                inode.addrs[idx] = self.freeblock;
                self.freeblock += 1;
            } else {
                try self.readSector(inode.addrs[idx], @ptrCast(&doubly_blk));
            }

            var singly_blk: [fs.NINDIRECT]u32 = .{0} ** fs.NINDIRECT;
            const idx2 = bn / fs.NINDIRECT;

            if (doubly_blk[idx2] == 0) {
                doubly_blk[idx2] = toLittle(u32, self.freeblock);
                self.freeblock += 1;
                _ = try self.writeSector(inode.addrs[idx], idx2 * @sizeOf(u32), std.mem.asBytes(&doubly_blk[idx2]));
            } else {
                try self.readSector(doubly_blk[idx2], @ptrCast(&singly_blk));
            }

            const idx3 = bn % fs.NINDIRECT;
            if (singly_blk[idx3] == 0) {
                singly_blk[idx3] = toLittle(u32, self.freeblock);
                self.freeblock += 1;
                _ = try self.writeSector(doubly_blk[idx2], idx3 * @sizeOf(u32), std.mem.asBytes(&singly_blk[idx3]));
            }

            return singly_blk[idx3];
        }

        unreachable; // out of range
    }

    /// buf must be little endian data
    fn inodeAppend(self: *Disk, inode: *Inode, buf: []const u8) !void {
        var n: usize = 0;
        var filesize = inode.size;

        while (n < buf.len) {
            const fbn = filesize / fs.BSIZE;
            assert(fbn < fs.MAXFILE);

            const block = try self.bitmap(inode, fbn);
            const offset = filesize - (fbn * fs.BSIZE);
            const nbytes = try self.writeSector(block, offset, buf[n..]);

            filesize += @intCast(nbytes);
            n += nbytes;
        }

        inode.size = filesize;
    }

    /// write to bitmap
    fn writeBitmap(self: Disk) !void {
        try stdout.print("balloc: first {} blocks have been allocated\n", .{self.freeblock});
        assert(self.freeblock < fs.BSIZE * 8);

        var buf: [fs.BSIZE]u8 = .{0} ** fs.BSIZE;
        var i: usize = 0;
        while (i < self.freeblock) : (i += 1) {
            buf[i / 8] |= @as(u8, 0x1) << @intCast(i % 8);
        }

        try stdout.print("balloc: write bitmap block at sector {}\n", .{superblk.bmapstart});
        _ = try self.writeSector(superblk.bmapstart, 0, &buf);
    }
};

pub fn main() !void {
    comptime assert(fs.BSIZE % @sizeOf(Dinode) == 0);
    comptime assert(fs.BSIZE % @sizeOf(Dirent) == 0);

    const allocator = std.heap.page_allocator;
    var args = try std.process.argsAlloc(allocator);
    defer allocator.free(args);

    if (args.len < 2) {
        try stdout.print("Usage: {s} fs.img files...\n", .{args[0]});
        return;
    }

    try stdout.print(
        "nmeta {} (boot, super, log blocks {} inode blocks {}, bitmap blocks {}) blocks {} total {}\n",
        .{ nmeta, nlog, ninodeblocks, nbitmap, nblocks, kernel.FSSIZE },
    );

    var disk = try Disk.init(args[1]);
    defer disk.deinit();

    // write superblock
    _ = try disk.writeSector(1, 0, std.mem.asBytes(&superblk));

    // allocate root inode
    var rootino = disk.allocInode(.dir);
    defer disk.writeInode(rootino);

    assert(rootino.number == fs.ROOTINO);

    inline for (.{ ".", ".." }) |name| {
        try disk.inodeAppend(&rootino, std.mem.asBytes(&Dirent{
            .inum = toLittle(u16, rootino.number),
            .name = name.* ++ [_]u8{0} ** (Dirent.DIRSIZ - name.len), // .name = name[0..c.DIRSIZ],
        }));
    }

    for (args[2..]) |app| {
        const shortname: [:0]const u8 = blk: {
            const name1 = std.fs.path.basename(app);
            const name2 = std.mem.trimLeft(u8, name1, "_");
            break :blk @ptrCast(name2);
        };

        const file = try std.fs.cwd().openFile(app, .{});
        defer file.close();

        var fileino = disk.allocInode(.file);
        defer disk.writeInode(fileino);

        var dir_entry = Dirent{
            .inum = toLittle(u16, fileino.number),
            .name = undefined,
        };
        std.mem.copy(u8, &dir_entry.name, shortname[0 .. shortname.len + 1]);
        try disk.inodeAppend(&rootino, std.mem.asBytes(&dir_entry));

        var buf: [fs.BSIZE]u8 = undefined;
        while (true) {
            const amt = try file.read(&buf);
            if (amt == 0) break;
            try disk.inodeAppend(&fileino, buf[0..amt]);
        }
    }
}
