//! File system implementation.  Five layers:
//!   + Blocks: allocator for raw disk blocks.
//!   + Log: crash recovery for multi-step updates.
//!   + Files: inode allocator, reading, writing, metadata.
//!   + Directories: inode with special contents (list of other inodes!)
//!   + Names: paths like /usr/rtm/xv6/fs.c for convenient naming.
//!
//! This file contains the low-level file system manipulation
//! routines.  The (higher-level) system call implementations
//! are in sysfile.c.

const c = @import("c.zig");

/// root i-number
pub const ROOTINO = 1;
/// block/sector size
pub const BSIZE = 1024;

// +-----------+----------------->  direct (11)
// |           +-+--------------->  singly-indirect (1 * 256)
// |           | +-+------------->  doubly-indirect (1 * 256 * 256)
// +-----------+-+-+
//     11       1 1
pub const NDIRECT = 11;
pub const NINDIRECT = BSIZE / @sizeOf(c_uint);
pub const ND_INDIRECT = NINDIRECT * NINDIRECT;
pub const MAXFILE = (NDIRECT + NINDIRECT + ND_INDIRECT);

/// Inodes per block.
pub const IPB = (BSIZE / @sizeOf(c.Dinode));

/// max # of blocks any FS op writes
pub const MAXOPBLOCKS = 10;
/// max data blocks in on-disk log
pub const LOGSIZE = (MAXOPBLOCKS * 3);
/// size of disk block cache
pub const NBUF = (MAXOPBLOCKS * 3);
/// size of file system in blocks
pub const FSSIZE = 32000;
/// maximum file path name
pub const MAXPATH = 128;

// pub fn init() !void {}
