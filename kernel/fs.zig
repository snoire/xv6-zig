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
