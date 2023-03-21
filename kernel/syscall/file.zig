const std = @import("std");
const c = @import("../c.zig");
const xv6 = @import("../xv6.zig");
const syscall = @import("../syscall.zig");
const proc = @import("../proc.zig");

/// Fetch the nth word-sized system call argument as a file descriptor
/// and return the corresponding struct file.
fn argfile(n: u8) *c.File {
    var fd = syscall.argint(n);
    var f = proc.myproc().?.ofile[fd];

    if (fd < 0 or fd >= xv6.NOFILE or f == null)
        @panic("argfile");

    return f.?;
}

/// Allocate a file descriptor for the given file.
/// Takes over file reference from caller on success.
fn fdalloc(f: *c.File) u32 {
    var p = proc.myproc().?;

    return for (&p.ofile, 0..) |*ofile, i| {
        if (ofile.* == null) {
            ofile.* = f;
            break @intCast(u32, i);
        }
    } else @panic("fdalloc");
}

pub fn dup() callconv(.C) usize {
    var f = argfile(0);
    var fd = fdalloc(f);
    _ = f.dup();
    return fd;
}

pub fn read() callconv(.C) usize {
    var f = argfile(0);
    var p = syscall.argaddr(1);
    var n = syscall.argint(2);
    return f.read(p, n);
}

pub fn write() callconv(.C) usize {
    var f = argfile(0);
    var p = syscall.argaddr(1);
    var n = syscall.argint(2);
    return f.write(p, n);
}

pub fn close() callconv(.C) usize {
    var fd = syscall.argint(0);
    var f = argfile(0); // user pointer to struct stat
    proc.myproc().?.ofile[fd] = null;
    f.close();
    return 0;
}

pub fn fstat() callconv(.C) usize {
    var f = argfile(0);
    var st = syscall.argaddr(1);
    return f.stat(st);
}

/// Create the path new as a link to the same inode as old.
pub fn link() callconv(.C) usize {
    var old_buf: [xv6.MAXPATH]u8 = undefined;
    var new_buf: [xv6.MAXPATH]u8 = undefined;

    var old = syscall.argstr(0, &old_buf);
    var new = syscall.argstr(1, &new_buf);

    c.begin_op();
    defer c.end_op();

    var ip = c.namei(old).?;
    ip.ilock();

    if (ip.type == .dir) @panic("create the link of dir?");
    ip.nlink += 1;
    ip.update();
    ip.unlock();

    var name: [c.Dirent.DIRSIZ]u8 = undefined;
    var dp = c.nameiparent(new, &name).?;
    dp.ilock();

    if (dp.dev != ip.dev) @panic("dp.dev != ip.dev");
    if (dp.dirlink(&name, ip.inum) < 0) @panic("dirlink");

    dp.unlockput();
    ip.put();

    return 0;
}

/// Is the directory dp empty except for "." and ".." ?
fn isdirempty(dp: *c.Inode) bool {
    var de: c.Dirent = undefined;
    var off: usize = 2 * @sizeOf(c.Dirent); // skip "." and ".."

    while (off < dp.size) : (off += @sizeOf(c.Dirent)) {
        var nbytes = dp.read(false, @ptrToInt(&de), @intCast(u32, off), @sizeOf(c.Dirent));
        if (nbytes != @sizeOf(c.Dirent)) @panic("isdirempty: readi");
        if (de.inum != 0) return false;
    } else {
        return true;
    }
}

pub fn unlink() callconv(.C) usize {
    var path_buf: [xv6.MAXPATH]u8 = undefined;
    var path = syscall.argstr(0, &path_buf);

    c.begin_op();
    defer c.end_op();

    var name: [c.Dirent.DIRSIZ]u8 = undefined;
    var dp = c.nameiparent(path, &name).?;
    dp.ilock();

    if (std.mem.eql(u8, &name, ".") or std.mem.eql(u8, &name, "..")) {
        @panic("Cannot unlink `.` or `..`");
    }

    var off: u32 = undefined;
    var ip = dp.dirlookup(&name, &off).?;
    ip.ilock();

    if (ip.nlink < 1) {
        @panic("unlink: nlink < 1");
    }

    if (ip.type == .dir and !isdirempty(ip)) {
        @panic("ip.type == .dir and !isdirempty(ip)");
    }

    var de = std.mem.zeroes(c.Dirent);
    var nbytes = dp.write(false, @ptrToInt(&de), off, @sizeOf(c.Dirent));

    if (nbytes != @sizeOf(c.Dirent)) {
        @panic("unlink: writei");
    }

    if (ip.type == .dir) {
        dp.nlink -= 1;
        dp.update();
    }
    dp.unlockput();

    ip.nlink -= 1;
    ip.update();
    ip.unlockput();

    return 0;
}
