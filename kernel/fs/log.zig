// Simple logging that allows concurrent FS system calls.
//
// A log transaction contains the updates of multiple FS system
// calls. The logging system only commits when there are
// no FS system calls active. Thus there is never
// any reasoning required about whether a commit might
// write an uncommitted system call's updates to disk.
//
// A system call should call begin_op()/end_op() to mark
// its start and end. Usually begin_op() just increments
// the count of in-progress FS system calls and returns.
// But if it thinks the log is close to running out, it
// sleeps until the last outstanding end_op() commits.
//
// The log is a physical re-do log containing disk blocks.
// The on-disk log format:
//   header block, containing block #s for block A, B, C, ...
//   block A
//   block B
//   block C
//   ...
// Log appends are synchronous.

const std = @import("std");
const c = @import("../c.zig");
const fs = @import("../fs.zig");
const proc = @import("../proc.zig");

const Header = struct {
    comptime {
        std.debug.assert(@sizeOf(@This()) < fs.BSIZE);
    }

    n: usize,
    block: [fs.LOGSIZE]u32,
};

var lock: c.SpinLock = undefined;
var dev: u32 = undefined;
var start: u32 = undefined;
var size: usize = undefined;

/// how many FS sys calls are executing.
var outstanding: usize = 0;
/// in commit(), please wait.
var committing: bool = false;
var header: Header = undefined;

export fn initlog(devno: c_uint, sb: *c.SuperBlock) void {
    lock.init("log");
    start = sb.logstart;
    size = sb.nlog;
    dev = devno;

    // recover from log

    readLogHeader();
    installTrans(true); // if committed, copy from log to disk
    header.n = 0;
    writeLogHeader(); // clear the log
}

/// called at the start of each FS system call.
export fn begin_op() void {
    lock.acquire();
    defer lock.release();

    while (true) {
        if (committing) {
            proc.sleep(&lock, &lock);
        } else if (header.n + (outstanding + 1) * fs.MAXOPBLOCKS > fs.LOGSIZE) {
            proc.sleep(&lock, &lock);
        } else {
            outstanding += 1;
            break;
        }
    }
}

/// called at the end of each FS system call.
/// commits if this was the last outstanding operation.
export fn end_op() void {
    lock.acquire();

    outstanding -= 1;

    if (committing) @panic("log.committing");

    var do_commit = false;
    if (outstanding == 0) {
        do_commit = true;
        committing = true;
    } else {
        // begin_op() may be waiting for log space,
        // and decrementing log.outstanding has decreased
        // the amount of reserved space.
        proc.wakeup(&lock);
    }

    lock.release();

    if (do_commit) {
        // call commit w/o holding locks, since not allowed
        // to sleep with locks.
        commit();
        lock.acquire();
        defer lock.release();

        committing = false;
        proc.wakeup(&lock);
    }
}

/// Caller has modified b->data and is done with the buffer.
/// Record the block number and pin in the cache by increasing refcnt.
/// commit()/write_log() will do the disk write.
///
/// log_write() replaces bwrite(); a typical use is:
///   bp = bread(...)
///   modify bp->data[]
///   log_write(bp)
///   brelse(bp)
export fn log_write(c_buf: *c.Buf) void {
    lock.acquire();
    defer lock.release();

    if (header.n >= fs.LOGSIZE or header.n >= size - 1)
        @panic("too big a transaction");

    if (outstanding < 1)
        @panic("log_write outside of trans");

    for (0..header.n) |i| {
        if (header.block[i] == c_buf.blockno) break; // log absorption
    } else { // Add new block to log?
        header.block[header.n] = c_buf.blockno;
        bpin(c_buf);
        header.n += 1;
    }
}

fn commit() void {
    if (header.n > 0) {
        writeLog(); // Write modified blocks from cache to log
        writeLogHeader(); // Write header to disk -- the real commit
        installTrans(false); // Now install writes to home locations
        header.n = 0;
        writeLogHeader(); // Erase the transaction from the log
    }
}

/// Copy committed blocks from log to their home location
fn installTrans(comptime recovering: bool) void {
    for (0..header.n) |i| {
        var lbuf = bread(dev, @intCast(start + i + 1)); // read log block
        var dbuf = bread(dev, header.block[i]); // read dst

        std.mem.copy(u8, &dbuf.data, &lbuf.data);
        bwrite(dbuf); // write dst to disk
        if (recovering) bunpin(dbuf);
        brelse(lbuf);
        brelse(dbuf);
    }
}

/// Read the log header from disk into the in-memory log header
fn readLogHeader() void {
    var c_buf = bread(dev, start);
    var lh: *align(1) Header = @ptrCast(&c_buf.data);
    header.n = lh.n;

    for (0..header.n) |i| {
        header.block[i] = lh.block[i];
    }
    brelse(c_buf);
}

/// Write in-memory log header to disk.
/// This is the true point at which the
/// current transaction commits.
fn writeLogHeader() void {
    var c_buf = bread(dev, start);
    var hb: *align(1) Header = @ptrCast(&c_buf.data);
    hb.n = header.n;

    for (0..header.n) |i| {
        hb.block[i] = header.block[i];
    }
    bwrite(c_buf);
    brelse(c_buf);
}

/// Copy modified blocks from cache to log.
fn writeLog() void {
    for (0..header.n) |i| {
        var to = bread(dev, @intCast(start + i + 1)); // log block
        var from = bread(dev, header.block[i]); // cache block

        std.mem.copy(u8, &to.data, &from.data);
        bwrite(to); // write the log
        brelse(from);
        brelse(to);
    }
}

extern fn bread(dev: c_uint, blockno: c_uint) *c.Buf;
extern fn bwrite(c_buf: *c.Buf) void;
extern fn bpin(c_buf: *c.Buf) void;
extern fn bunpin(c_buf: *c.Buf) void;
extern fn brelse(c_buf: *c.Buf) void;
