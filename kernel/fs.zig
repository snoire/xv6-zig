/// root i-number
pub const ROOTINO = 1;
/// block size
pub const BSIZE = 1024;

// Disk layout:
// [ boot block | super block | log | inode blocks | free bit map | data blocks]
//
// mkfs computes the super block and builds an initial file system. The
// super block describes the disk layout:
pub const SuperBlock = extern struct {
    pub const FSMAGIC = 0x10203040;

    /// Must be FSMAGIC
    magic: c_uint,
    /// Size of file system image (blocks)
    size: c_uint,
    /// Number of data blocks
    nblocks: c_uint,
    /// Number of inodes.
    ninodes: c_uint,
    /// Number of log blocks
    nlog: c_uint,
    /// Block number of first log block
    logstart: c_uint,
    /// Block number of first inode block
    inodestart: c_uint,
    /// Block number of first free map block
    bmapstart: c_uint,
};

// +-----------+----------------->  direct (11)
// |           +-+--------------->  singly-indirect (1 * 256)
// |           | +-+------------->  doubly-indirect (1 * 256 * 256)
// +-----------+-+-+
//     11       1 1
pub const NDIRECT = 11;
pub const NINDIRECT = BSIZE / @sizeOf(c_uint);
pub const ND_INDIRECT = NINDIRECT * NINDIRECT;
pub const MAXFILE = (NDIRECT + NINDIRECT + ND_INDIRECT);

pub const Dinode = extern struct {
    type: c_short,
    major: c_short,
    minor: c_short,
    nlink: c_short,
    size: c_uint,
    addrs: [NDIRECT + 1 + 1]c_uint,
};

/// Inodes per block.
pub const IPB = (BSIZE / @sizeOf(Dinode));

/// Directory is a file containing a sequence of dirent structures.
pub const Dirent = extern struct {
    pub const DIRSIZ = 14;

    inum: c_ushort,
    name: [DIRSIZ]u8,
};
