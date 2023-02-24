//! Buffer cache.
//!
//! The buffer cache is a linked list of buf structures holding
//! cached copies of disk block contents.  Caching disk blocks
//! in memory reduces the number of disk reads and also provides
//! a synchronization point for disk blocks used by multiple processes.
//!
//! Interface:
//! * To get a buffer for a particular disk block, call bread.
//! * After changing buffer data, call bwrite to write it to disk.
//! * When done with the buffer, call brelse.
//! * Do not use the buffer after calling brelse.
//! * Only one process at a time can use a buffer,
//!     so do not keep them longer than necessary.

// /// has data been read from disk?
valid: bool = false,
dev: u32 = 0,
lock: c.SleepLock = undefined,
refcnt: u32 = 0,

// /// does disk "own" buf?
// disk: bool = false,
// blockno: u32 = 0,
// data: [fs.BSIZE]u8 = undefined,

// TODO
c_buf: c.Buf = .{},

const c = @import("../c.zig");
const fs = @import("../fs.zig");
const std = @import("std");
const Buffer = @This();
const BufferList = std.TailQueue(Buffer);
const SpinLock = @import("../SpinLock.zig");

var lock: SpinLock = SpinLock.init("BCache");
var nodes: [fs.NBUF]BufferList.Node = undefined;

/// Linked list of all buffers.
/// Sorted by how recently the buffer was used.
/// list.first is most recent, list.last is least.
var list: BufferList = .{};

pub fn init() void {
    // Create linked list of buffers
    for (&nodes) |*node| {
        node.* = .{ .data = .{} };
        node.data.lock.init("buffer");
        list.append(node);
    }
}

/// Look through buffer cache for block on device dev.
/// If not found, allocate a buffer.
/// In either case, return locked buffer.
fn get(dev: u32, blockno: u32) *BufferList.Node {
    lock.acquire();

    // Is the block already cached?
    var it = list.first;
    while (it) |node| : (it = node.next) {
        if (node.data.dev == dev and node.data.c_buf.blockno == blockno) {
            node.data.refcnt += 1;

            lock.release();
            node.data.lock.acquire();
            return node;
        }
    }

    // Not cached.
    // Recycle the least recently used (LRU) unused buffer.
    it = list.last;
    while (it) |node| : (it = node.prev) {
        if (node.data.refcnt == 0) {
            node.data.dev = dev;
            node.data.c_buf.blockno = blockno;
            node.data.valid = false;
            node.data.refcnt = 1;

            lock.release();
            node.data.lock.acquire();
            return node;
        }
    }

    @panic("bget: no buffers");
}

/// Return a locked buf with the contents of the indicated block.
fn read(dev: u32, blockno: u32) *Buffer {
    var node = Buffer.get(dev, blockno);
    if (!node.data.valid) {
        c.virtio_disk_rw(&node.data.c_buf, false);
        node.data.valid = true;
    }

    return &node.data;
}

export fn bread(dev: c_uint, blockno: c_uint) *c.Buf {
    var buf = read(dev, blockno);
    return &buf.c_buf;
}

/// Write b's contents to disk.  Must be locked.
fn write(buf: *Buffer) void {
    if (!buf.lock.holding()) {
        @panic("Buffer.write");
    }
    c.virtio_disk_rw(&buf.c_buf, true);
}

export fn bwrite(c_buf: *c.Buf) void {
    var buf = @fieldParentPtr(Buffer, "c_buf", c_buf);
    buf.write();
}

/// Release a locked buffer.
/// Move to the head of the most-recently-used list.
fn release(buf: *Buffer) void {
    if (!buf.lock.holding()) {
        @panic("Buffer.release");
    }

    buf.lock.release();

    lock.acquire();
    defer lock.release();

    buf.refcnt -= 1;
    // no one is waiting for it.
    if (buf.refcnt == 0) {
        const node = @fieldParentPtr(BufferList.Node, "data", buf);
        list.remove(node);
        list.prepend(node);
    }
}

export fn brelse(c_buf: *c.Buf) void {
    var buf = @fieldParentPtr(Buffer, "c_buf", c_buf);
    buf.release();
}

fn pin(buf: *Buffer) void {
    lock.acquire();
    defer lock.release();
    buf.refcnt += 1;
}

export fn bpin(c_buf: *c.Buf) void {
    var buf = @fieldParentPtr(Buffer, "c_buf", c_buf);
    buf.pin();
}

fn unpin(buf: *Buffer) void {
    lock.acquire();
    defer lock.release();
    buf.refcnt -= 1;
}

export fn bunpin(c_buf: *c.Buf) void {
    var buf = @fieldParentPtr(Buffer, "c_buf", c_buf);
    buf.unpin();
}
