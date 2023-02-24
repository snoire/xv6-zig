//! Inodes.
//!
//! An inode describes a single unnamed file.
//! The inode disk structure holds metadata: the file's type,
//! its size, the number of links referring to it, and the
//! list of blocks holding the file's content.
//!
//! The inodes are laid out sequentially on disk at block
//! sb.inodestart. Each inode has a number, indicating its
//! position on the disk.
//!
//! The kernel keeps a table of in-use inodes in memory
//! to provide a place for synchronizing access
//! to inodes used by multiple processes. The in-memory
//! inodes include book-keeping information that is
//! not stored on disk: ip->ref and ip->valid.
//!
//! An inode and its in-memory representation go through a
//! sequence of states before they can be used by the
//! rest of the file system code.
//!
//! * Allocation: an inode is allocated if its type (on disk)
//!   is non-zero. ialloc() allocates, and iput() frees if
//!   the reference and link counts have fallen to zero.
//!
//! * Referencing in table: an entry in the inode table
//!   is free if ip->ref is zero. Otherwise ip->ref tracks
//!   the number of in-memory pointers to the entry (open
//!   files and current directories). iget() finds or
//!   creates a table entry and increments its ref; iput()
//!   decrements ref.
//!
//! * Valid: the information (type, size, &c) in an inode
//!   table entry is only correct when ip->valid is 1.
//!   ilock() reads the inode from
//!   the disk and sets ip->valid, while iput() clears
//!   ip->valid if ip->ref has fallen to zero.
//!
//! * Locked: file system code may only examine and modify
//!   the information in an inode and its content if it
//!   has first locked the inode.
//!
//! Thus a typical sequence is:
//!   ip = iget(dev, inum)
//!   ilock(ip)
//!   ... examine and modify ip->xxx ...
//!   iunlock(ip)
//!   iput(ip)
//!
//! ilock() is separate from iget() so that system calls can
//! get a long-term reference to an inode (as for an open file)
//! and only lock it for short periods (e.g., in read()).
//! The separation also helps avoid deadlock and races during
//! pathname lookup. iget() increments ip->ref so that the inode
//! stays in the table and pointers to it remain valid.
//!
//! Many internal file system functions expect the caller to
//! have locked the inodes involved; this lets callers create
//! multi-step atomic operations.
//!
//! The itable.lock spin-lock protects the allocation of itable
//! entries. Since ip->ref indicates whether an entry is free,
//! and ip->dev and ip->inum indicate which i-node an entry
//! holds, one must hold itable.lock while using any of those fields.
//!
//! An ip->lock sleep-lock protects all ip-> fields other than ref,
//! dev, and inum.  One must hold ip->lock in order to
//! read or write that inode's ip->valid, ip->size, ip->type, &c.

const c = @import("c.zig");
const fs = @import("fs.zig");
const SpinLock = @import("SpinLock.zig");
const SleepLock = c.SleepLock;
const Self = @This();

/// Device number
dev: u32,
/// Inode number
inum: u32,
/// Reference count
ref: u32,
/// protects everything below here
lock: SleepLock,
/// inode has been read from disk?
valid: bool,

/// copy of disk inode
disk_inode: c.Dinode,

// Copy a modified in-memory inode to disk.
// Must be called after every change to an ip->xxx field
// that lives on disk.
// Caller must hold ip->lock.
fn update(inode: *Self) void {
}
